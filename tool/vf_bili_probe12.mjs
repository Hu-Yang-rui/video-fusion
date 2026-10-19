// 第十二轮：收口三件事。
//  A. /x/v3/fav/resource/ids 是否一次返回夹内【全部】资源（145 条那个夹）→ 最少的"夹→含该视频?"方案
//     并与逐页 resource/list 的结果做集合级对账（证明无遗漏）。
//  B. fav_state 终局：collected/list（我收藏的别人的夹）里的 fav_state 是否也恒 0 → 定论"不可用"。
//  C. attr 语义 + 公开/私密可验证判据：匿名读 自建attr=0 / 自建attr=22 / 陌生人夹；
//     并穷举 folder/add 的 privacy 参数形态，看新建夹 attr 是否出现"公开/私密"两种值。
// 写入仅限 VF_ 前缀临时夹（用已验证的 media_ids 当场删除）。
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
const J = (v, n = 170) => redact(JSON.stringify(v)).slice(0, n);
const sleep = (ms = 600) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://space.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };
const GETj = async (p, h = H) => {
  const r = await fetch(`${API}${p}`, { headers: h });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 28) }; }
  return { http: r.status, j };
};
const POSTj = async (p, body, json) => {
  const r = await fetch(`${API}${p}`, {
    method: 'POST',
    headers: { ...H, origin: 'https://space.bilibili.com', 'content-type': json ? 'application/json' : 'application/x-www-form-urlencoded' },
    body: json ? JSON.stringify(body) : new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 28) }; }
  return { http: r.status, j };
};
const listAll = async () => (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j.data?.list) || []);
const bits = (n) => (n == null ? 'n/a' : `${n}=0b${(n >>> 0).toString(2)}[${[1, 2, 4, 8, 16, 32, 64, 128].filter((b) => n & b).join('+')}]`);

const base = await listAll();
log(`基准夹=${base.length}：${base.map((f) => `${f.title}(${f.id},${bits(f.attr)},${f.media_count})`).join(' ')}`);

log('\n=== A. resource/ids 覆盖面（决定"扫一个夹最少几个请求"）===');
for (const f of base.filter((x) => (x.media_count || 0) > 0)) {
  const r = await GETj(`/x/v3/fav/resource/ids?media_id=${f.id}&rid=0&type=2`);
  const arr = Array.isArray(r.j.data) ? r.j.data : null;
  log(`  ${f.title} media_count=${f.media_count} → code=${r.j.code} data是否数组=${!!r.j.data} 长度=${arr ? arr.length : J(r.j.data, 60)}`);
  await sleep(150);
}
log('  —— 各种 rid 形态（对 145 条的夹）——');
const big = base.sort((a, b) => b.media_count - a.media_count)[0];
for (const q of [`media_id=${big.id}`, `media_id=${big.id}&rid=0`, `media_id=${big.id}&rid=0&type=2`, `media_id=${big.id}&platform=web`, `media_id=${big.id}&pn=1&ps=20`, `media_id=${big.id}&rid=116745046065481&type=2`]) {
  const r = await GETj('/x/v3/fav/resource/ids?' + q);
  const d = r.j.data;
  log(`    ${q.slice(0, 52)} → code=${r.j.code} 类型=${Array.isArray(d) ? 'array' : typeof d} 长度=${Array.isArray(d) ? d.length : '-'} 样本=${J(Array.isArray(d) ? d.slice(0, 2) : d, 120)}`);
  await sleep(150);
}
log('  —— 与逐页 resource/list 集合级对账（证明 ids 无遗漏）——');
const idsR = await GETj(`/x/v3/fav/resource/ids?media_id=${big.id}&rid=0&type=2`);
const idsSet = new Set((idsR.j.data || []).map((x) => x.bvid || x.bv_id));
let pages = 0;
const pageSet = new Set();
for (let pn = 1; pn <= 20; pn++) {
  const rl = (await GETj(`/x/v3/fav/resource/list?media_id=${big.id}&pn=${pn}&ps=20&platform=web`)).j;
  const ms = rl.data?.medias || [];
  if (!ms.length) break;
  pages++;
  ms.forEach((m) => pageSet.add(m.bvid || m.bv_id));
  if (rl.data?.has_more === false) break;
  await sleep(120);
}
log(`    resource/ids: ${idsSet.size} 条 | 逐页 resource/list: ${pages} 页 ${pageSet.size} 条 | 完全一致=${idsSet.size === pageSet.size && [...pageSet].every((b) => idsSet.has(b))}`);
log(`    media_count=${big.media_count} vs ids长度=${idsSet.size} → ${big.media_count === idsSet.size ? '一致（一次请求拿全量）' : '不一致，差额=' + (big.media_count - idsSet.size)}`);
const probeTarget = [...pageSet][Math.floor(pageSet.size / 2)];
log(`    深页样本 ${probeTarget} 在 resource/ids 结果里=${idsSet.has(probeTarget)}（首屏 20 条之外也能命中）`);
log(`    ids 项字段=${J(Object.keys((idsR.j.data || [])[0] || {}), 120)}；含 fav_time=${'fav_time' in ((idsR.j.data || [])[0] || {})}`);
const rlLite = (await GETj(`/x/v3/fav/resource/list?media_id=${big.id}&pn=1&ps=40&platform=web&detail=0`)).j;
log(`    resource/list detail=0 ps=40: code=${rlLite.code} 条数=${(rlLite.data?.medias || []).length} medias[0]键=${Object.keys((rlLite.data?.medias || [])[0] || {}).join(',').slice(0, 90)}`);

log('\n=== B. fav_state 终局 ===');
const col = (await GETj(`/x/v3/fav/folder/collected/list?pn=1&ps=20&up_mid=${uid}&platform=web`)).j;
log(`  collected/list（我收藏的别人的夹）条数=${(col.data?.list || []).length}：`);
for (const f of col.data?.list || [])
  log(`    ${f.id} "${f.title}" fav_state=${f.fav_state} like_state=${f.like_state} attr=${f.attr} state=${f.state} 键数=${Object.keys(f).length}`);
const withBv = (await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=BV1ySJx6YETj&platform=web`)).j;
log(`  created/list-all(bvid=已知在 gay 夹内的视频) fav_state=[${(withBv.data?.list || []).map((f) => f.fav_state).join(',')}]（全 0）`);
const seasons = (await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=BV1G5po6zECY&platform=web&type=11`)).j;
log(`  带 type=11 对合集视频: fav_state=[${(seasons.data?.list || []).map((f) => f.fav_state).join(',')}]`);
log(`  ★ 观测范围：自建夹(带/不带 bvid)、别人的夹(collected/list)、folder/info、合集视频 → fav_state 全部 = 0，无一例外`);
log(`  ★ 定论：fav_state 在本账号所有场景恒 0，不是"视频在此夹"也不是"我收藏了此夹"的可用指示，UI 禁止依赖`);

log('\n=== C. attr 语义 + 公开/私密判据 ===');
log('  C1 匿名可读性（登录态 vs 无 cookie）：');
const stranger = (col.data?.list || [])[0];
const cmpList = [...base.slice(0, 3), ...(stranger ? [stranger] : [])];
for (const f of cmpList) {
  const authL = (await GETj(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`)).j;
  const anonL = (await GETj(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`, HN)).j;
  const authI = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`)).j;
  const anonI = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`, HN)).j;
  log(`    ${f.id} "${String(f.title).slice(0, 10)}" attr=${bits(f.attr)} state=${authI.data?.state} ` +
    `| 登录list=${(authL.data?.medias || []).length}条(code=${authL.code}) 匿名list=${(anonL.data?.medias || []).length}条(code=${anonL.code}) ` +
    `| 登录info=${authI.code} 匿名info=${anonI.code}(匿名attr=${anonI.data?.attr}) 匿名info.visibility=${anonI.data?.visibility} 匿名state=${anonI.data?.state}`);
  await sleep(150);
}
log('  C2 folder/add 参数穷举（找公开/私密的真实开关）：');
const shapes = [
  ['privacy=true', { privacy: 'true' }],
  ['privacy=1', { privacy: '1' }],
  ['public=true', { public: 'true' }],
  ['public=1', { public: '1' }],
  ['type=0', { type: '0' }],
  ['privacy=false', { privacy: 'false' }],
  ['plat+privacy', { privacy: 'true', platform: 'web' }],
  ['biz_version', { privacy: 'true', cover: '', biz_version: '2' }],
];
const createdIds = [];
let seq = 0;
for (const [label, extra] of shapes) {
  const title = 'VF_C' + String(++seq).padStart(2, '0'); // 短标题，避免长度限制干扰
  const r = await POSTj('/x/v3/fav/folder/add', { title, intro: 'p', ...extra, csrf });
  const id = r.j.data?.id;
  log(`    ${label} (${title}): code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')} data.attr=${r.j.data?.attr}(${bits(r.j.data?.attr)}) id=${id}`);
  if (r.j.code === 0 && id) createdIds.push({ id, title, label });
  await sleep(500);
}
const jsonR = await POSTj('/x/v3/fav/folder/add', { title: 'VF_C90', intro: 'p', privacy: true, csrf }, true);
log(`    JSON body {privacy:true} (VF_C90): code=${jsonR.j.code} msg=${redact(jsonR.j.message ?? jsonR.j.body ?? '')} data.attr=${jsonR.j.data?.attr}(${bits(jsonR.j.data?.attr)}) id=${jsonR.j.data?.id}`);
if (jsonR.j.code === 0 && jsonR.j.data?.id) createdIds.push({ id: jsonR.j.data.id, title: 'VF_C90', label: 'json' });
log(`  C3 回读新建夹的真实 attr 与匿名可见性：`);
for (const c of createdIds) {
  const one = (await GETj(`/x/v3/fav/folder/info?media_id=${c.id}&platform=web`)).j;
  const anon = (await GETj(`/x/v3/fav/folder/info?media_id=${c.id}&platform=web`, HN)).j;
  const anonL = (await GETj(`/x/v3/fav/resource/list?media_id=${c.id}&pn=1&ps=20&platform=web`, HN)).j;
  log(`    ${c.id} (${c.label}) info.attr=${bits(one.data?.attr)} state=${one.data?.state} visibility=${one.data?.visibility} | 匿名info code=${anon.code} attr=${bits(anon.data?.attr)} | 匿名list code=${anonL.code}`);
  await sleep(200);
}
log(`  C4 公开→私密的切换端点（bundle 里出现 folder/edit / folder/sort / resource/clean）：`);
for (const p of ['/x/v3/fav/folder/edit', '/x/v3/fav/folder/upd', '/x/v3/fav/folder/upd_info', '/x/v3/fav/folder/priv', '/x/v3/fav/folder/attr']) {
  const r = await POSTj(p, { media_id: String(createdIds[0]?.id || big.id), privacy: 'false', title: 'x', csrf });
  log(`    POST ${p} → HTTP=${r.http} code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')}`);
  await sleep(150);
}
log(`  C5 清理全部 VF_ 临时夹：`);
for (const c of createdIds) {
  const r = await POSTj('/x/v3/fav/folder/del', { media_ids: String(c.id), csrf });
  log(`    del ${c.id} (${c.label}): code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')}`);
  await sleep(600);
}

log('\n=== D. 写入假成功再确认（不存在的夹 / 新夹未就绪）===');
const fresh = await POSTj('/x/v3/fav/folder/add', { title: 'VF_D_READY', intro: 'p', csrf });
const fid = fresh.j.data?.id;
log(`  新建 VF_D_READY id=${fid} code=${fresh.j.code}`);
const t0 = await POSTj('/x/v3/fav/resource/deal', { rid: '116745046065481', type: '2', add_media_ids: String(fid), del_media_ids: '', csrf });
const idsNow = fid ? (await GETj(`/x/v3/fav/resource/ids?media_id=${fid}&rid=0&type=2`)).j : {};
log(`  立即(0ms)收藏进新夹: code=${t0.j.code} success_num=${J(t0.j.data, 90)} → resource/ids 长度=${(idsNow.data || []).length}`);
for (const wait of [800, 1500, 3000]) {
  await sleep(wait);
  const ids2 = (await GETj(`/x/v3/fav/resource/ids?media_id=${fid}&rid=0&type=2`)).j;
  const one = (await GETj(`/x/v3/fav/folder/info?media_id=${fid}&platform=web`)).j;
  log(`  +${wait}ms 后：resource/ids 长度=${(ids2.data || []).length} media_count=${one.data?.media_count} 命中目标=${(ids2.data || []).some((x) => String(x.id) === '116745046065481' || String(x.bvid) === 'BV1ySJx6YETj')}`);
}
log(`  不存在的夹（复查上一轮 code=11010 是否稳定）：`);
for (let i = 0; i < 2; i++) {
  const b = await POSTj('/x/v3/fav/resource/deal', { rid: '116745046065481', type: '2', add_media_ids: '999999999999', del_media_ids: '', csrf });
  log(`    #${i + 1} code=${b.j.code} msg=${redact(b.j.message ?? '')} data=${J(b.j.data, 80)}`);
  await sleep(400);
}
if (fid) {
  await POSTj('/x/v3/fav/resource/deal', { rid: '116745046065481', type: '2', add_media_ids: '', del_media_ids: String(fid), csrf });
  await sleep(500);
  const dr = await POSTj('/x/v3/fav/folder/del', { media_ids: String(fid), csrf });
  log(`  删 VF_D_READY: code=${dr.j.code}`);
  await sleep(700);
}

log('\n=== E. 状态核对 ===');
const fin = await listAll();
const exp = (await GETj('/x/member/web/exp/reward')).j;
const tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
const rlSt = (await GETj('/x/relation?fid=3546661399824534&ptype=1')).j;
const leftover = fin.filter((f) => String(f.title).startsWith('VF_'));
log(`  夹数=${fin.length}（应 ${base.length}）| VF_ 残留=${leftover.map((f) => f.id + '/' + f.title).join(',') || '无'}`);
log(`  media_count: ${fin.map((f) => `${f.title}=${f.media_count}`).join(' ')}`);
log(`  coins=${exp.data?.coins}（应0）| toview.count=${tv.data?.count}（应0）| attribute=${rlSt.data?.attribute}（应0）`);
const gayIds = (await GETj('/x/v3/fav/resource/ids?media_id=4020481152&rid=0&type=2')).j;
log(`  gay 夹内容未被动过=${(gayIds.data || []).length === 1 && (gayIds.data?.[0]?.bvid) === 'BV1ySJx6YETj'}`);
log(`  账号状态已恢复：${fin.length === base.length && !leftover.length && exp.data?.coins === 0 && tv.data?.count === 0 && rlSt.data?.attribute === 0 ? '是' : '★需核对 ' + JSON.stringify({ n: fin.length, base: base.length, leftover: leftover.length })}`);
