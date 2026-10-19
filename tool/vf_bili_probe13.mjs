// 第十三轮（定论轮）：
//  A. -412 风控：resource/list 与 resource/ids 谁受限、是否随时间恢复、并发/串行触发点。
//  B. attr 位语义终局：匿名 folder/info 交叉验证 attr&1 = 私密；bundle 里反解 private 判定函数。
//  C. fav_state 终局复证：collected/list=1 vs created/list-all=0（夹维度，非视频维度）。
//  D. 最终 Dart 契约所需：resource/ids 单次全量、登录/匿名差异、判等字段。
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
const J = (v, n = 150) => redact(JSON.stringify(v)).slice(0, n);
const sleep = (ms = 500) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://space.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };
const GETj = async (p, h = H) => {
  const r = await fetch(`${API}${p}`, { headers: h });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 26) }; }
  return { http: r.status, j };
};
const listAll = async () => (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j.data?.list) || []);
const bits = (n) => (n == null ? 'n/a' : `${n}=0b${(n >>> 0).toString(2)}[${[1, 2, 4, 8, 16, 32, 64, 128, 256].filter((b) => n & b).join('+')}]`);

const base = await listAll();
log(`基准夹=${base.length}：${base.map((f) => `${f.title}${bits(f.attr)}`).join(' ')}`);

log('\n=== A. -412 风控边界（resource/list vs resource/ids）===');
const big = base.sort((a, b) => b.media_count - a.media_count)[0];
const small = base.find((f) => f.media_count === 1);
let rec = [];
for (let i = 1; i <= 6; i++) {
  const rl = await GETj(`/x/v3/fav/resource/list?media_id=${small.id}&pn=1&ps=20&platform=web`);
  rec.push(rl.j.code);
  await sleep(300);
}
log(`  resource/list 连续 6 次（小夹 ${small.title}）: code=[${rec.join(',')}]`);
const idsSeries = [];
for (let i = 1; i <= 4; i++) {
  const ri = await GETj(`/x/v3/fav/resource/ids?media_id=${big.id}&rid=0&type=2`);
  idsSeries.push(`${ri.j.code}/${(ri.j.data || []).length}`);
  await sleep(250);
}
log(`  resource/ids 连续 4 次（${big.title}）: code/长度=[${idsSeries.join(' , ')}] → ${idsSeries.every((s) => s.startsWith('0/')) ? 'ids 未受 -412 影响' : 'ids 也被限'}`);
log('  等待 5s 后重试 resource/list：');
await sleep(5000);
const after = await GETj(`/x/v3/fav/resource/list?media_id=${small.id}&pn=1&ps=20&platform=web`);
log(`    resource/list → code=${after.j.code} msg=${redact(after.j.message ?? '')} 条数=${(after.j.data?.medias || []).length}`);
log(`    resource/ids  → code=${(await GETj(`/x/v3/fav/resource/ids?media_id=${small.id}&rid=0&type=2`)).j.code}`);
log('  并发 6 个 resource/list（模拟 Future.wait）：');
const par = await Promise.all(base.map((f) => GETj(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`)));
log(`    codes=[${par.map((r) => r.j.code).join(',')}]`);
const parIds = await Promise.all(base.map((f) => GETj(`/x/v3/fav/resource/ids?media_id=${f.id}&rid=0&type=2`)));
log(`  并发 6 个 resource/ids codes=[${parIds.map((r) => r.j.code).join(',')}] 长度=[${parIds.map((r) => (r.j.data || []).length).join(',')}]`);
log(`    对照 media_count=[${base.map((f) => f.media_count).join(',')}] → 全量一致=${parIds.every((r, i) => (r.j.data || []).length === base[i].media_count)}`);
const anonIds = await GETj(`/x/v3/fav/resource/ids?media_id=${big.id}&rid=0&type=2`, HN);
log(`  resource/ids 匿名: code=${anonIds.j.code} msg=${redact(anonIds.j.message ?? '')} 长度=${(anonIds.j.data || []).length}（必须登录）`);

log('\n=== B. attr 位语义终局 ===');
log('  B1 bundle 反解 private 判定：');
const bt = await (await fetch('https://s1.hdslb.com/bfs/static/shanks/fresh-space/assets/index-76bd2e5f.js', { headers: { 'user-agent': UA } })).text();
const p0 = bt.indexOf('private:T(G.attr)');
log(`    "private:T(G.attr)" 位置=${p0}`);
// 在附近找 T 的定义
const win = bt.slice(Math.max(0, p0 - 4200), p0 + 200);
for (const m of win.matchAll(/(?:const|let|var|function)\s+(T|[\w$]{1,3})\s*=?\s*(?:function)?\s*\(?([^)]{0,10})\)?\s*=>?\s*\{?[^;{]{0,120}attr[^;{}]{0,120}/g))
  log('      定义候选 …' + redact(m[0].replace(/\s+/g, ' ')).slice(0, 240) + '…');
for (const m of bt.matchAll(/.{0,60}attr\s*&\s*(\d+).{0,60}/g)) log('      [全局] …' + redact(m[0].replace(/\s+/g, ' ')) + '…');
for (const m of bt.matchAll(/.{0,50}(?:1\s*<<\s*0|&\s*1\)|%2\s*===?\s*1|attr\s*>>).{0,50}/g)) log('      [bit0] …' + redact(m[0].replace(/\s+/g, ' ')) + '…');
log('  B2 匿名 folder/info 交叉验证（公开=可读，私密=-403）：');
for (const f of base) {
  const ai = await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`, HN);
  log(`    "${f.title}" attr=${bits(f.attr)} → 匿名info code=${ai.j.code} msg=${redact(ai.j.message ?? ai.j.body ?? '')} 匿名attr=${bits(ai.j.data?.attr)} attr&1=${ai.j.data ? (ai.j.data.attr & 1) : 'n/a'}`);
  await sleep(200);
}
log('    陌生人夹（collected/list 里的，一定公开）：');
const col = (await GETj(`/x/v3/fav/folder/collected/list?pn=1&ps=20&up_mid=${uid}&platform=web`)).j;
for (const f of (col.data?.list || []).slice(0, 3)) {
  const ai = await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`, HN);
  log(`      "${f.title}" list-all.attr=${bits(f.attr)} info.attr=${bits((await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`)).j.data?.attr)} 匿名info code=${ai.j.code}`);
  await sleep(200);
}
log('  B3 已知公开/私密对照（上一轮临时夹结论复述）：公开新夹 info.attr=54 匿名 code=0；privacy=1 新夹 info.attr=55 匿名 code=-403 → bit0(1)=私密');

log('\n=== C. fav_state 终局复证 ===');
log(`  collected/list（我收藏的别人的夹，"确实收藏过"）：${(col.data?.list || []).map((f) => `${f.title}:${f.fav_state}`).join(' ')}`);
const mine = await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=BV1ySJx6YETj&platform=web`);
log(`  created/list-all（自建夹，带已知在夹内的 bvid）：${(mine.j.data?.list || []).map((f) => `${f.title}:${f.fav_state}`).join(' ')}`);
log(`  → fav_state 只在【收藏了某个夹】时为 1；与"某视频在某夹"无关。视频归属请用 resource/ids`);
const createdList = (await GETj(`/x/v3/fav/folder/created/list?up_mid=${uid}&pn=1&ps=20&bvid=BV1ySJx6YETj`)).j;
log(`  created/list(分页版) 首项 recent_fav=${J(createdList.data?.list?.[0]?.recent_fav, 60)} bvid=${createdList.data?.list?.[0]?.bvid} view_count=${createdList.data?.list?.[0]?.view_count}`);

log('\n=== D. 最终契约数据（判等字段 + 全量能力）===');
const ids = (await GETj(`/x/v3/fav/resource/ids?media_id=${big.id}&rid=0&type=2`)).j.data || [];
log(`  resource/ids ${big.title}: 条数=${ids.length} media_count=${big.media_count} 项=${J(ids[0], 120)}`);
log(`  含 aid 字段 id=${ids[0]?.id} 与 view 反查一致：`);
const vv = await GETj(`/x/web-interface/view?bvid=${ids[0].bvid}`, HN);
log(`    view.bvid=${vv.j.data?.bvid} view.aid=${vv.j.data?.aid} → id==aid? ${String(ids[0].id) === String(vv.j.data?.aid)} bvid==bvid? ${ids[0].bvid === vv.j.data?.bvid}`);
const bvids = new Set(ids.map((x) => x.bvid));
log(`    bvid 与 bv_id 完全相同=${ids.every((x) => x.bvid === x.bv_id)}（用哪个都行，bvid 更直观）`);
log(`  一次判定"某视频在哪些夹"的总请求数 = 夹数（每个夹 1 次 resource/ids），本机 6 夹 = 6 次 GET`);
const target = 'BV1ySJx6YETj';
const hit = [];
for (const f of base) {
  const d = (await GETj(`/x/v3/fav/resource/ids?media_id=${f.id}&rid=0&type=2`)).j.data || [];
  if (d.some((x) => x.bvid === target)) hit.push(f.title);
  await sleep(150);
}
log(`  完整扫描"${target}"（gay 夹内那条）命中夹=[${hit.join(',')}]（期望仅 gay）`);

log('\n=== E. 状态核对（本轮零写入）===');
const fin = await listAll();
const exp = (await GETj('/x/member/web/exp/reward')).j;
const tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
const rlSt = (await GETj('/x/relation?fid=3546661399824534&ptype=1')).j;
log(`  夹数=${fin.length}（应6）VF_残留=${fin.filter((f) => String(f.title).startsWith('VF_')).length}（应0）`);
log(`  media_count: ${fin.map((f) => `${f.title}=${f.media_count}`).join(' ')}（基准 32/1/6/7/1/145）`);
log(`  coins=${exp.data?.coins} toview.count=${tv.data?.count} 关注attribute=${rlSt.data?.attribute}`);
const ok = fin.length === 6 && exp.data?.coins === 0 && tv.data?.count === 0 && rlSt.data?.attribute === 0 && fin.every((f) => !String(f.title).startsWith('VF_'));
log(`  账号状态已恢复：${ok ? '是（夹数/内容/硬币/稍后再看/关注态全部回到基准）' : '★需核对'}`);
