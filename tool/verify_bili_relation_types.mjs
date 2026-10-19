// 复核两条与本地实测冲突的契约说法（授权测试小号，只读为主）。
//
// 冲突 1：archive/relation 的 like/attention 到底是 bool 还是数字？
//   本地实测（tool/verify_bili_fav_state.mjs）得到：
//     {"attention":false,"favorite":true,"season_fav":false,"like":false,"dislike":false,"coin":0}
//     types: attention=boolean, like=boolean, dislike=boolean, coin=number
//   上游代理给的样例是：
//     {"attention":0,"favorite":false,"season_fav":false,"like":1,"dislike":18335,"coin":0}
//   → 两种形态不可能同时是"同一请求"的结果，必须查清是**哪个视频/什么状态**导致的，
//     解析代码要同时扛住两种，且不能抛 TypeError。
//
// 冲突 2：/x/v2/history/toview/aid 是否存在？
//   本地实测返回 HTTP 404；上游说 code=0 可用。→ 复查（带 Cookie、换参数名）。
//
// 原则：两种说法都记录，以本次可复现输出为准；解析按"两者都兼容"写。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (
  process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')
).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID');
const API = 'https://api.bilibili.com';
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const red = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const say = (t, o) => console.log(t + ' | ' + red(typeof o === 'string' ? o : JSON.stringify(o)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };

const raw = async (p) => {
  const r = await fetch(`${API}${p}`, { headers: H });
  const text = await r.text();
  let j = null;
  try { j = JSON.parse(text); } catch {}
  return { http: r.status, code: j?.code, msg: j?.message ?? j?.status_msg, j, body: text.slice(0, 90) };
};
const typesOf = (o) => Object.fromEntries(Object.entries(o || {}).map(([k, v]) => [k, Array.isArray(v) ? 'array' : typeof v]));

// 412 风控很凶（实测第 6 个请求起触发），这里串行 + 间隔 1.2s，最多退避一次
let gap = 1200;
const slow = async (p) => {
  await sleep(gap);
  let r = await raw(p);
  if (r.http === 412 || r.code === -70103112) {
    say('  限流，退避 6s 重试一次', { http: r.http, code: r.code, msg: r.msg });
    await sleep(6000);
    r = await raw(p);
  }
  return r;
};

// ── 样本 A：已知在收藏夹里的视频（本地实测 favorite=true, like=false） ──
const A = 'BV1ySJx6YETj';
const ra = await slow(`/x/web-interface/archive/relation?bvid=${A}`);
say('A relation http=', { http: ra.http, code: ra.code });
say('A data  ', ra.j?.data);
say('A types ', typesOf(ra.j?.data));

// 带 platform=web 的变体（有些接口按此切口径）
const ra2 = await slow(`/x/web-interface/archive/relation?bvid=${A}&platform=web`);
say('A+web types', typesOf(ra2.j?.data), ra2.code);

// 用 aid 传（不是 bvid）—— 官方前端另一种调用形态
const va = await slow(`/x/web-interface/view?bvid=${A}`);
const aidA = va.j?.data?.aid;
const statA = va.j?.data?.stat;
say('A view aid=', aidA, ' like_total=', statA?.like, ' fav=', statA?.favorite);
if (aidA) {
  const ra3 = await slow(`/x/web-interface/archive/relation?aid=${aidA}`);
  say('A by-aid types', typesOf(ra3.j?.data), ra3.code);
  say('A by-aid data ', ra3.j?.data);
}

// ── 样本 B：一个热门、明确"未点赞"的视频，看 like 是否给总赞数 ──
const B = 'BV1GJ411x7h7';
const rb = await slow(`/x/web-interface/archive/relation?bvid=${B}`);
say('B relation', { http: rb.http, code: rb.code, data: rb.j?.data });
say('B types   ', typesOf(rb.j?.data));
const vb = await slow(`/x/web-interface/view?bvid=${B}`);
say('B view stat.like=', vb.j?.data?.stat?.like, ' (对照：relation.like 是否等于它)');

// ── 冲突 2：稍后再看单条直查端点 ──
for (const p of [
  `/x/v2/history/toview/aid?aid=${aidA}`,
  `/x/v2/history/toview/aid?aid=${aidA}&platform=web`,
  `/x/v2/history/toview/web?platform=web&pn=1&ps=20`,
]) {
  const r = await slow(p);
  say('toview ' + p.split('?')[0] + (p.includes('platform') ? '[web]' : ''), {
    http: r.http, code: r.code, msg: r.msg, dataNull: r.j ? r.j.data === null : 'nonjson',
    dataKeys: r.j?.data ? Object.keys(r.j.data).slice(0, 8).join(',') : '-',
    body: r.j ? undefined : r.body,
  });
}

// ── 冲突 3：收藏夹 attr 的 bit0 是否等于"私密" ──
const fl = await slow(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`);
for (const f of fl.j?.data?.list || []) {
  say(`folder ${f.title}`, { id: f.id, attr: f.attr, attr_bit0: (f.attr ?? 0) & 1, media_count: f.media_count });
}
const someFolder = (fl.j?.data?.list || []).find((f) => f.attr === 22);
if (someFolder) {
  const fi = await slow(`/x/v3/fav/folder/info?media_id=${someFolder.id}&platform=web`);
  const d = fi.j?.data || {};
  say('folder/info ' + someFolder.title, {
    attr: d.attr, totals: d.totals?.media_count ?? d.media_count, priv_reason: d.priv_reason ?? d.private_reason,
    keys: Object.keys(d).join(','),
  });
}
