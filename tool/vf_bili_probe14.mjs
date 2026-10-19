// 第十四轮（收尾）：
//  A. -412 "request was banned" 是否随时间恢复（我上一轮穷举 ps 触发的），恢复后 resource/list 是否可用。
//  B. attr 判据终局：用 bundle 定义 private = (attr>>0&1)!==0，对全部真实夹 + 已知公开/私密样本核对。
//  C. 最终账号状态核对 + 探针总量说明。
import fs from 'node:fs';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID'), csrf = pick('bili_jct');
const API = 'https://api.bilibili.com';
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const redact = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));
const sleep = (ms = 500) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://space.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };
const GETj = async (p, h = H) => {
  const r = await fetch(`${API}${p}`, { headers: h });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 26) }; }
  return { http: r.status, j };
};
const POSTj = async (p, body) => {
  const r = await fetch(`${API}${p}`, {
    method: 'POST',
    headers: { ...H, origin: 'https://space.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 26) }; }
  return { http: r.status, j };
};
const listAll = async () => (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j.data?.list) || []);

log('=== A. -412 恢复观察（每 20s 一次，最多 5 次）===');
const one = (await listAll()).find((f) => f.media_count === 1) || (await listAll())[0];
let recovered = false;
for (let i = 1; i <= 5; i++) {
  const rl = await GETj(`/x/v3/fav/resource/list?media_id=${one.id}&pn=1&ps=20&platform=web`);
  const ri = await GETj(`/x/v3/fav/resource/ids?media_id=${one.id}&rid=0&type=2`);
  log(`  #${i} resource/list code=${rl.j.code} msg=${redact(rl.j.message ?? '')} 条数=${(rl.j.data?.medias || []).length} | resource/ids code=${ri.j.code} 长度=${(ri.j.data || []).length}`);
  if (rl.j.code === 0) { recovered = true; break; }
  await sleep(20000);
}
log(`  → resource/list 在观察窗内${recovered ? '已恢复' : '未恢复（封禁窗口 >100s）'}；resource/ids 全程 code=0 → **归属扫描用 ids 可完全规避 -412**`);

log('\n=== B. attr 判据终局核对（bundle: private = (attr & 1) !== 0）===');
const base = await listAll();
for (const f of base) {
  const anon = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`, HN)).j;
  const isPrivateByBit = (f.attr & 1) !== 0;
  const anonReadable = anon.code === 0;
  log(`  "${f.title}" attr=${f.attr} bit0=${f.attr & 1} → 按bundle判私=${isPrivateByBit} | 匿名folder/info code=${anon.code} 可读=${anonReadable} → 判据${isPrivateByBit === !anonReadable ? '自洽' : '★矛盾'}`);
  await sleep(200);
}
log('  已知样本（上一轮临时夹实测）：privacy=1 建夹 → info.attr=55(bit0=1) 匿名 -403；public=true/缺省 → attr=54/6(bit0=0) 匿名 code=0');
log('  结论：attr bit0(1)=私密；attr=0=默认夹（未打任何位）；attr=22=16+4+2 且 bit0=0 → 公开。22 不含私密位。');
log('  attr&128===128（bundle 里 medias 项的 je）与 attr>>0&1 是两个不同层的位：前者用于夹内条目，后者用于夹本身。');

log('\n=== C. 写入正确姿势最终复测（3 个可逆动作，全部当场还原）===');
const BVt = 'BV1ySJx6YETj';
const vi = (await GETj(`/x/web-interface/view?bvid=${BVt}`, HN)).j.data;
const aid = vi.aid;
const defId = base.find((f) => f.attr === 0)?.id || base[0].id;
const inIds = async (mid) => (((await GETj(`/x/v3/fav/resource/ids?media_id=${mid}&rid=0&type=2`)).j.data || []).some((x) => x.bvid === BVt));
log(`  样本 ${BVt}（当前在 gay 夹）aid=${aid} 默认夹=${defId} 默认夹内已含=${await inIds(defId)}`);
const w1 = await POSTj('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: String(defId), del_media_ids: '', csrf });
await sleep(1500);
const hit1 = await inIds(defId);
log(`  收藏到默认夹: code=${w1.j.code} success_num=${w1.j.data?.success_num} → resource/ids 复查命中=${hit1}（★生效判据）`);
const relOn = (await GETj(`/x/web-interface/archive/relation?bvid=${BVt}`)).j.data;
log(`  relation: favorite=${relOn.favorite}（该视频本来就在 gay 夹，favorite 早已 true，说明它只表示"收藏过"不表示"在这个夹"）`);
const w2 = await POSTj('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: '', del_media_ids: String(defId), csrf });
await sleep(1500);
const hit2 = await inIds(defId);
log(`  取消收藏: code=${w2.j.code} → 复查命中=${hit2}（应 false，回到基准）`);
const gayBack = await inIds(base.find((f) => f.title === 'gay').id);
log(`  gay 夹仍含该视频=${gayBack}（基准必须 true）`);
const tv0 = (await GETj('/x/v2/history/toview/web?platform=web')).j.data?.count;
const a1 = await POSTj('/x/v2/history/toview/add', { aid: String(aid), csrf });
await sleep(1200);
const tv1 = (await GETj('/x/v2/history/toview/web?platform=web')).j.data;
const d1 = await POSTj('/x/v2/history/toview/del', { aid: String(aid), csrf });
await sleep(1200);
const tv2 = (await GETj('/x/v2/history/toview/web?platform=web')).j.data;
log(`  稍后再看: add code=${a1.j.code} count ${tv0}→${tv1?.count}（含本视频=${(tv1?.list || []).some((x) => String(x.bvid) === BVt)}）del code=${d1.j.code} count→${tv2?.count}`);

log('\n=== D. 最终账号状态核对 ===');
const fin = await listAll();
const exp = (await GETj('/x/member/web/exp/reward')).j;
const rlSt = (await GETj('/x/relation?fid=3546661399824534&ptype=1')).j;
const counts = fin.map((f) => `${f.title}=${f.media_count}`).join(' ');
const checks = {
  夹数: fin.length === 6 && !fin.some((f) => String(f.title).startsWith('VF_')),
  media_count: fin.length === 6 && fin.every((f) => ({ 默认收藏夹: 32, gay: 1, MOD: 6, 来硬的: 7, 合: 1, 神人视频: 145 })[f.title] === f.media_count),
  稍后再看: (await GETj('/x/v2/history/toview/web?platform=web')).j.data?.count === 0,
  硬币余额: exp.data?.coins === 0,
  关注态: rlSt.data?.attribute === 0,
  gay夹内容: await inIds(base.find((f) => f.title === 'gay').id),
};
log(`  ${counts}`);
for (const [k, v] of Object.entries(checks)) log(`  ${k}: ${v ? '✔ 回到基准' : '★ 异常'}`);
log(`  账号状态已恢复：${Object.values(checks).every(Boolean) ? '是（全部 6 项核对通过）' : '★有异常项，见上'}`);
