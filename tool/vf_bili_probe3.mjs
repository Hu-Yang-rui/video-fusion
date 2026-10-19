// 第三轮（已修正版）：fav_state 语义、稍后再看、关注、夹属性。
// ── 修正说明（依据 probe4~probe14 的实测）──────────────────────────────
// [1] 原第 4 节用 /x/relation/tags/addUsers 与 /x/relation/fans/del —— 端点错误。
//     正确端点：POST /x/relation/modify，参数 fid、act（1=关注 2=取关 5=拉黑 6=取消拉黑）、re_sub、csrf。
//     现改为：先读 /x/relation?fid=<mid>&ptype=1 的 attribute；
//             初始 0 才做 act=1 → 复查 → act=2 → 复查；初始非 0 则完全跳过写入。
//     实测补充：关注后 attribute = 2（不是 1）；archive/relation.attention 会实时 false→true→false。
// [2] 原脚本用 fav_state 判断"是否已收藏/是否恢复原状" —— 已被证伪：
//     fav_state 是【收藏夹自身】被当前用户收藏(订阅)的标记，对自己创建的夹恒为 0，
//     只有 /x/v3/fav/folder/collected/list 里别人的夹才会出现 1。
//     视频→夹 的权威判据改为 GET /x/v3/fav/resource/ids?media_id=&rid=0&type=2（一次返回夹内全部 bvid，无分页）。
// [3] 测试视频改为动态挑选（原 BV1rcn56hEoT 可能不存在），且只选"当前不在任何夹内"的视频。
// 凭据从仓库外读取；输出经 redact()，只允许打印 cookie 名字、bili_jct 长度、DedeUserID。
// 写操作仅收藏/取消、稍后再看增删、关注取关（可逆）；投币只验证失败码。可重复运行。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (
  process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')
).trim();
const g = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = g('DedeUserID'), csrf = g('bili_jct');
const API = 'https://api.bilibili.com';
// 泄漏防护：任何输出前替换掉 cookie 的值
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const redact = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const J = (v, n = 200) => redact(JSON.stringify(v)).slice(0, n);
const consoleLog = console.log.bind(console);
console.log = (...a) => consoleLog(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));

const HG = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };
const GET = async (u, h = HG) => {
  const r = await fetch(u, { headers: h });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { __nonJson: true, status: r.status }; }
};
const POST = async (p, body) => {
  const r = await fetch(`${API}${p}`, {
    method: 'POST',
    headers: { ...HG, origin: 'https://www.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { __nonJson: true, status: r.status }; }
};
const wait = (ms = 900) => new Promise((r) => setTimeout(r, ms));

console.log(`=== 0. 凭据自证 ===`);
console.log(`cookie 名=[${COOKIE.split(';').map((s) => s.trim().split('=')[0]).join(',')}] bili_jct.len=${csrf.length} DedeUserID=${uid}`);

// —— 修正 [2]：归属判据用 resource/ids ——
const foldersOf = async () => {
  const j = await GET(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`);
  return j.data?.list || [];
};
const idsOf = async (mediaId) => {
  const j = await GET(`${API}/x/v3/fav/resource/ids?media_id=${mediaId}&rid=0&type=2`);
  return Array.isArray(j.data) ? j : { data: [] };
};
// 返回 {夹id: 是否含该视频}（bvid 或 aid 命中都算，双判据更稳）
const memberMap = async (folders, bvid, aid) => {
  const out = {};
  for (const f of folders) {
    const j = await idsOf(f.id);
    out[f.id] = (j.data || []).some((x) => String(x.bvid) === String(bvid) || String(x.id) === String(aid));
  }
  return out;
};

console.log('\n=== 1. 挑选测试视频（必须当前不在任何夹内）===');
const folders = await foldersOf();
console.log(`夹（id/title/attr/media_count/fav_state）：`);
for (const f of folders) console.log(`  ${f.id} "${f.title}" attr=${f.attr} media_count=${f.media_count} fav_state=${f.fav_state}`);

let picked = null;
const candBvids = [];
if (process.env.VF_TEST_BVID) candBvids.push(process.env.VF_TEST_BVID);
const pop = await GET(`${API}/x/web-interface/popular?ps=8&pn=1`, HN);
for (const it of pop.data?.list || []) candBvids.push(it.bvid);
for (const b of [...new Set(candBvids)]) {
  const v = await GET(`${API}/x/web-interface/view?bvid=${b}`, HN);
  if (!v.data?.aid) continue;
  const mm = await memberMap(folders, b, v.data.aid);
  if (!Object.values(mm).some(Boolean)) { picked = { bvid: b, aid: v.data.aid, title: v.data.title, owner: v.data.owner.mid }; break; }
  await wait(150);
}
if (!picked) { console.log('  ★ 未找到未收藏的候选视频，退出'); process.exit(0); }
console.log(`  选用 ${picked.bvid} aid=${picked.aid} owner.mid=${picked.owner} "${String(picked.title).slice(0, 28)}"`);
const { aid, bvid: BV, owner } = picked;
const def = folders.find((f) => f.attr === 0) || folders[0];
const other = folders.find((f) => f.id !== def.id);

console.log('\n=== 2. fav_state 语义（修正版：fav_state 不是视频归属字段）===');
const st0 = await GET(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${BV}&platform=web`);
console.log(`  收藏前 list-all(带bvid) fav_state=[${(st0.data?.list || []).map((f) => f.fav_state).join(',')}]`);
const w1 = await POST('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: String(def.id), del_media_ids: '', csrf });
console.log(`  收藏到 "${def.title}": code=${w1.code} msg=${w1.message} data=${J(w1.data, 110)}`);
await wait(1500);
const mm1 = await memberMap(folders, BV, aid);
const st1 = await GET(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${BV}&platform=web`);
console.log(`  复查 resource/ids 归属: ${Object.entries(mm1).map(([k, v]) => `${(folders.find((f) => String(f.id) === k) || {}).title}=${v ? 'IN' : '-'}`).join(' ')}`);
console.log(`  同刻 list-all fav_state=[${(st1.data?.list || []).map((f) => f.fav_state).join(',')}] ← 写入已生效但 fav_state 仍全 0 → 证伪`);
const rel1 = await GET(`${API}/x/web-interface/archive/relation?bvid=${BV}`);
console.log(`  archive/relation=${J(rel1.data, 170)}（favorite=true 只表示"收藏过"，不表示在哪个夹）`);
// 幂等
const w2 = await POST('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: String(def.id), del_media_ids: '', csrf });
await wait(1200);
const mm2 = await memberMap(folders, BV, aid);
const cnt2 = (await foldersOf()).find((f) => f.id === def.id)?.media_count;
console.log(`  同夹重复收藏: code=${w2.code} msg=${w2.message} 归属仍=${mm2[def.id]} media_count=${cnt2}（不重复插入）`);
// 两个夹
const w3 = await POST('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: `${def.id},${other.id}`, del_media_ids: '', csrf });
await wait(1500);
const mm3 = await memberMap(folders, BV, aid);
console.log(`  同时收藏 2 夹 "${def.title}"+"${other.title}": code=${w3.code} 归属=[${Object.values(mm3).map((v) => (v ? 1 : 0)).join('')}]`);
// add + del 同时非空
const w4 = await POST('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: String(def.id), del_media_ids: String(other.id), csrf });
await wait(1500);
const mm4 = await memberMap(folders, BV, aid);
console.log(`  add+del 同请求（加"${def.title}" 删"${other.title}"）: code=${w4.code} → ${def.title}=${mm4[def.id]} ${other.title}=${mm4[other.id]}`);
// 不存在的夹
const w5 = await POST('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: '999999999999', del_media_ids: '', csrf });
await wait(900);
const after5 = await foldersOf();
console.log(`  不存在的夹: code=${w5.code} msg=${w5.message} data=${J(w5.data, 90)} → 夹数 ${after5.length}（基准 ${folders.length}），无夹被创建 = ${after5.length === folders.length ? '静默失败' : '异常'}`);
// 恢复：del 全部
const w6 = await POST('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: '', del_media_ids: folders.map((f) => f.id).join(','), csrf });
await wait(1500);
const mm6 = await memberMap(folders, BV, aid);
console.log(`  恢复原状（del 全部夹）: code=${w6.code} → 归属残留=[${Object.values(mm6).map((v) => (v ? 1 : 0)).join('')}]（必须全 0）`);

console.log('\n=== 3. 夹属性 attr（公开/私密判据）===');
for (const f of folders) {
  const i = await GET(`${API}/x/v3/fav/folder/info?media_id=${f.id}&platform=web`);
  const anon = await GET(`${API}/x/v3/fav/folder/info?media_id=${f.id}&platform=web`, HN);
  const isPub = (f.attr & 1) === 0;
  const anonOk = anon.code === 0;
  console.log(`  ${f.id} "${f.title}" attr=${f.attr}(0b${(f.attr >>> 0).toString(2)}, bit0=${f.attr & 1}) state=${i.data?.state} like_state=${i.data?.like_state} visibility=${i.data?.visibility} cnt_info=${J(i.data?.cnt_info, 70)} | 匿名info code=${anon.code} → 判${isPub ? '公开' : '私密'}，与匿名可读(${anonOk})${isPub === anonOk ? ' 一致' : ' ★矛盾'}`);
}
console.log(`  folder/info 全部键: ${Object.keys((await GET(`${API}/x/v3/fav/folder/info?media_id=${def.id}&platform=web`)).data || {}).join(',')}`);

console.log('\n=== 4. 关注 UP 主（修正：/x/relation/modify）===');
const r0 = await GET(`${API}/x/relation?fid=${owner}&ptype=1`);
console.log(`  权威来源：GET /x/relation?fid=&ptype=1 → data=${J(r0.data, 170)} attribute=${r0.data?.attribute}（0=未关注）`);
if (r0.data?.attribute === 0) {
  const a1 = await POST('/x/relation/modify', { fid: String(owner), act: '1', re_sub: '0', csrf });
  await wait(900);
  const r1 = await GET(`${API}/x/relation?fid=${owner}&ptype=1`);
  const ar1 = await GET(`${API}/x/web-interface/archive/relation?bvid=${BV}`);
  console.log(`  act=1 关注: code=${a1.code} msg=${a1.message} → attribute=${r1.data?.attribute}（★实测关注态是 2） archive/relation.attention=${ar1.data?.attention}`);
  const a2 = await POST('/x/relation/modify', { fid: String(owner), act: '2', re_sub: '0', csrf });
  await wait(900);
  const r2 = await GET(`${API}/x/relation?fid=${owner}&ptype=1`);
  const ar2 = await GET(`${API}/x/web-interface/archive/relation?bvid=${BV}`);
  console.log(`  act=2 取关: code=${a2.code} → attribute=${r2.data?.attribute}（应回 0） attention=${ar2.data?.attention}（应回落 false）`);
  console.log(`  ★ 关注态权威来源 = /x/relation.attribute；archive/relation.attention 实时可用但只有布尔，无分组(tag)`);
} else {
  console.log(`  ★ 初始 attribute=${r0.data?.attribute} ≠ 0（已关注/已拉黑）→ 按约束跳过全部关注写入，只做只读结论`);
}

console.log('\n=== 5. 稍后再看 add/del ===');
const l0 = await GET(`${API}/x/v2/history/toview/web?platform=web`);
console.log(`  初始 count=${l0.data?.count} data键=${Object.keys(l0.data || {}).join(',')}`);
const la = await POST('/x/v2/history/toview/add', { aid: String(aid), csrf });
await wait(1000);
const l1 = await GET(`${API}/x/v2/history/toview/web?platform=web`);
console.log(`  add: code=${la.code} msg=${la.message} → count=${l1.data?.count} 含本视频=${(l1.data?.list || []).some((x) => String(x.bvid) === BV)}`);
const la2 = await POST('/x/v2/history/toview/add', { aid: String(aid), csrf });
await wait(700);
console.log(`  重复 add: code=${la2.code} → count=${(await GET(`${API}/x/v2/history/toview/web?platform=web`)).data?.count}（幂等）`);
const ld = await POST('/x/v2/history/toview/del', { aid: String(aid), csrf });
await wait(1000);
const l2 = await GET(`${API}/x/v2/history/toview/web?platform=web`);
console.log(`  del: code=${ld.code} → count=${l2.data?.count} 含本视频=${(l2.data?.list || []).some((x) => String(x.bvid) === BV)}（应回 ${l0.data?.count}）`);

console.log('\n=== 6. 投币（余额 0，只验失败码，不消耗）===');
const exp = await GET(`${API}/x/member/web/exp/reward`);
console.log(`  exp/reward.coins=${exp.data?.coins}（nav.money 是另一个字段，不可当投币余额）`);
if ((exp.data?.coins ?? 0) === 0) {
  const c1 = await POST('/x/web-interface/coin/add', { bvid: BV, multiply: '1', select_like: '0', csrf });
  console.log(`  coin/add multiply=1: code=${c1.code} msg=${c1.message} data=${J(c1.data, 150)}`);
  console.log(`  ★ 余额 0 → 实测 ${c1.code}/${c1.message}，UI 必须投币前先查 coins（-401 还带风控 decisions，重试也没用）`);
} else {
  console.log('  ★ 余额>0，跳过（禁止消耗）');
}
console.log(`  复查 coins=${(await GET(`${API}/x/member/web/exp/reward`)).data?.coins}（应仍 ${exp.data?.coins}）`);

console.log('\n=== 7. 账号状态恢复核对 ===');
const finFolders = await foldersOf();
const finMember = await memberMap(finFolders, BV, aid);
const checks = {
  夹数回到基准: finFolders.length === folders.length,
  无VF临时夹残留: !finFolders.some((f) => String(f.title).startsWith('VF_')),
  测试视频未在任何夹: !Object.values(finMember).some(Boolean),
  稍后再看回到基准: (await GET(`${API}/x/v2/history/toview/web?platform=web`)).data?.count === l0.data?.count,
  硬币余额未变: (await GET(`${API}/x/member/web/exp/reward`)).data?.coins === exp.data?.coins,
  关注态回到基准: (await GET(`${API}/x/relation?fid=${owner}&ptype=1`)).data?.attribute === r0.data?.attribute,
};
for (const [k, v] of Object.entries(checks)) console.log(`  ${k}: ${v ? '✔' : '★异常'}`);
console.log(`  各夹 media_count: ${finFolders.map((f) => `${f.title}=${f.media_count}`).join(' ')}`);
console.log(`\n账号状态已恢复：${Object.values(checks).every(Boolean) ? '是（全部核对通过）' : '★有异常，见上'}`);
