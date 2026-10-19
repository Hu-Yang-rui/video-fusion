// 判别：resource/list 的 medias[i].id 与 view 的 aid 是否同一数值形态。
// 若能证实二者不等，则归属比对必须只能用 bvid（否则必然漏判）。
import fs from 'node:fs';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID');
const API = 'https://api.bilibili.com';
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const red = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const say = (t, o) => console.log(t + ' | ' + red(typeof o === 'string' ? o : JSON.stringify(o)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const get = async (p) => { await sleep(1300); const r = await fetch(`${API}${p}`, { headers: H }); const t = await r.text(); try { return { http: r.status, j: JSON.parse(t) }; } catch { return { http: r.status, j: null, body: t.slice(0, 60) }; } };

const fl = await get(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`);
const folders = fl.j?.data?.list || [];

// 取几个小夹，把 medias[i].id / bvid 与各自 view 的 aid 对照
for (const f of folders.filter((x) => (x.media_count ?? 0) > 0).sort((a, b) => a.media_count - b.media_count).slice(0, 3)) {
  const rl = await get(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`);
  const medias = rl.j?.data?.medias || [];
  for (const m of medias.slice(0, 2)) {
    const v = await get(`/x/web-interface/view?bvid=${m.bvid}`);
    const viewAid = v.j?.data?.aid;
    say(`夹「${f.title}」`, {
      bvid: m.bvid,
      media_id_in_list: m.id,
      aid_from_view: viewAid,
      equal: m.id === viewAid,
      hitBvid: medias.some((x) => x.bvid === m.bvid),
      hitAid: medias.some((x) => x.id === viewAid),
    });
  }
}

// ps 上限复核
const big = folders.find((f) => (f.media_count ?? 0) > 20);
if (big) {
  for (const ps of [20, 100, 200]) {
    const r = await get(`/x/v3/fav/resource/list?media_id=${big.id}&pn=1&ps=${ps}&platform=web`);
    say(`ps=${ps}`, { returned: (r.j?.data?.medias || []).length, has_more: r.j?.data?.has_more, totals: r.j?.data?.info?.totals, media_count: big.media_count });
  }
}

// toview/aid 直查端点复核（上游说可用，本地此前实测 404）
const t1 = await get(`/x/v2/history/toview/aid?aid=116745046065481`);
say('GET /x/v2/history/toview/aid', { http: t1.http, code: t1.j?.code, body: t1.body });

// 稍后再看列表里到底有没有 bvid 字段（决定 fetchWatchLater 能否免 aid）
const tw = await get(`/x/v2/history/toview/web?platform=web&pn=1&ps=20`);
const it = (tw.j?.data?.list || [])[0];
say('toview/web 首条 keys', it ? Object.keys(it).join(',') : '（列表为空，无法确认字段）');
say('count=', tw.j?.data?.count);

// exp/reward 的 coins 类型 + tags.enable_payment_qrcode
const er = await get(`/x/member/web/exp/reward`);
say('exp/reward', { coins: er.j?.data?.coins, coinsType: typeof er.j?.data?.coins, enable_payment_qrcode: er.j?.data?.tags?.enable_payment_qrcode, code: er.j?.code });

// 关注状态权威读法
const rel = await get(`/x/relation?fid=9871&ptype=1`);
say('/x/relation attribute=', { code: rel.j?.code, attribute: rel.j?.data?.attribute, mid: rel.j?.data?.mid });

// attr 位形态汇总
say('attr 汇总', folders.map((f) => `${f.title}:${f.attr}(${(f.attr ?? 0) & 1})`).join(' '));
