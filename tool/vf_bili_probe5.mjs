// 第五轮探针 —— 受控写回环（账号为用户授权的测试小号）。
// 允许的可逆写入：收藏/取消收藏、稍后再看 add/del、关注/取关（仅当初始未关注）、
//                 建夹 VF_PROBE_TMP* / 删夹（仅在确认存在可用删除端点后才建）。
// 禁止：消耗硬币（余额 0，仅作失败码验证）、批量点赞、改资料、弹幕评论。
// 输出经 redact()：绝不打印任何 cookie 值；只打印名字、bili_jct 长度、DedeUserID。
// 可重复运行：脚本开头捕获真实初始态并在结尾恢复到该初始态。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (
  process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')
).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID');
const csrf = pick('bili_jct');
const API = 'https://api.bilibili.com';

const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const redact = (s) => {
  let t = String(s);
  for (const v of secrets) t = t.split(v).join('<REDACTED>');
  return t;
};
const J = (v, n = 240) => redact(JSON.stringify(v)).slice(0, n);
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));
const sleep = (ms = 800) => new Promise((r) => setTimeout(r, ms));

const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };
const GETj = async (p, h = H) => {
  const r = await fetch(`${API}${p}`, { headers: h });
  const t = await r.text();
  try {
    return { http: r.status, j: JSON.parse(t) };
  } catch {
    return { http: r.status, j: { __nonJson: true, body: t.replace(/\s+/g, ' ').slice(0, 48) } };
  }
};
// form：POST。opts.query=参数也放 URL（部分端点只认 query）。
const FORM = async (p, body = {}, opts = {}) => {
  const q = opts.query ? `?${new URLSearchParams(opts.query)}` : '';
  const useQuery = opts.query && opts.queryOnly;
  const url = `${API}${p}${q}`;
  const init = {
    method: opts.method || 'POST',
    headers: { ...H, origin: 'https://www.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
  };
  if (!useQuery) init.body = new URLSearchParams(body).toString();
  const r = await fetch(url, init);
  const t = await r.text();
  let j;
  try {
    j = JSON.parse(t);
  } catch {
    j = { __nonJson: true, body: t.replace(/\s+/g, ' ').slice(0, 48) };
  }
  return { http: r.status, j };
};
const brief = (r) => `HTTP=${r.http} code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')}${r.j.toast ? ` toast=${redact(r.j.toast)}` : ''}`;

// —— fav_state 读取器（唯一权威来源）——
const stateOf = async (bvid) => {
  const { j } = await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${bvid}&platform=web`);
  const list = j.data?.list || [];
  return Object.fromEntries(list.map((f) => [String(f.id), { fav_state: f.fav_state, media_count: f.media_count, attr: f.attr, title: f.title }]));
};
const fmt = (st) => Object.values(st).map((f) => `${String(f.title).slice(0, 6)}=${f.fav_state}(${f.media_count})`).join(' ');

log('=== 0. 前置：凭据自证 + 选择测试视频（当前未收藏）===');
log(`cookie 名=[${COOKIE.split(';').map((s) => s.trim().split('=')[0]).join(',')}] bili_jct.len=${csrf.length} DedeUserID=${uid}`);

let BV = process.env.VF_TEST_BVID || '';
let infoR = BV ? await GETj(`/x/web-interface/view?bvid=${BV}`, HN) : null;
if (!infoR?.j?.data?.aid) {
  const pop = (await GETj('/x/web-interface/popular?ps=6&pn=1', HN)).j;
  for (const it of pop.data?.list || []) {
    const st = await stateOf(it.bvid);
    if (Object.values(st).every((f) => f.fav_state === 0)) {
      BV = it.bvid;
      break;
    }
  }
  infoR = await GETj(`/x/web-interface/view?bvid=${BV}`, HN);
}
const AID = infoR.j.data.aid;
const OWNER = infoR.j.data.owner.mid;
log(`测试视频 bvid=${BV} aid=${AID} owner.mid=${OWNER} "${String(infoR.j.data.title).slice(0, 28)}"`);

// 真实初始态快照（结尾恢复到这个基准）
const INIT = await stateOf(BV);
const INIT_COUNT = Object.keys(INIT).length;
const initFolderIds = Object.keys(INIT);
const initCounts = Object.fromEntries(Object.entries(INIT).map(([k, v]) => [k, v.media_count]));
log(`初始 fav_state 串 = ${Object.values(INIT).map((f) => f.fav_state).join('')}（必须全 0 才是干净基准）`);
const initToview = (await GETj('/x/v2/history/toview/web?platform=web')).j;
const INIT_TOVIEW_COUNT = initToview.data?.count ?? 0;
const INIT_TOVIEW_HAS = (initToview.data?.list || []).some((x) => String(x.bvid) === BV);
const initExp = (await GETj('/x/member/web/exp/reward')).j;
const INIT_COINS = initExp.data?.coins;
const initStat = (await GETj(`/x/web-interface/view?bvid=${BV}`, HN)).j.data?.stat;
const INIT_STAT_FAV = initStat?.favorite;
const INIT_STAT_COIN = initStat?.coin;
const initRel = (await GETj(`/x/relation?fid=${OWNER}&ptype=1`)).j;
const INIT_ATT = initRel.data?.attribute;
log(`初始：toview.count=${INIT_TOVIEW_COUNT} 含本视频=${INIT_TOVIEW_HAS} | coins=${INIT_COINS} | stat.favorite=${INIT_STAT_FAV} stat.coin=${INIT_STAT_COIN} | 关注(${OWNER}).attribute=${INIT_ATT}`);
if (Object.values(INIT).some((f) => f.fav_state !== 0)) {
  log('★ 初始非干净态，先清理（del 全部已收藏夹）');
  const dirty = initFolderIds.filter((id) => INIT[id].fav_state !== 0);
  log('  ' + brief(await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: '', del_media_ids: dirty.join(','), csrf })));
  await sleep(1000);
  log('  清理后：' + fmt(await stateOf(BV)));
}

log('\n=== A. fav_state 语义（真实收藏回环）===');
const sorted = Object.entries(INIT).sort((a, b) => a[1].attr - b[1].attr);
const F1 = sorted[0][0], F1T = sorted[0][1].title; // 默认夹 attr=0
const F2 = sorted[1][0], F2T = sorted[1][1].title; // 任一 attr=22
const F3 = sorted[2][0], F3T = sorted[2][1].title;
log(`用夹：F1="${F1T}"(${F1}, attr=${INIT[F1].attr})  F2="${F2T}"(${F2}, attr=${INIT[F2].attr})  F3="${F3T}"(${F3})`);

log(`\n[A1] 收藏到 F1（单夹）`);
const a1 = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: String(F1), del_media_ids: '', csrf });
log('  ' + brief(a1) + ' | data=' + J(a1.j.data, 120));
await sleep(1000);
let st = await stateOf(BV);
log('  复查 fav_state: ' + fmt(st));
const relA = (await GETj(`/x/web-interface/archive/relation?bvid=${BV}`)).j;
log(`  archive/relation: favorite=${relA.data?.favorite} season_fav=${relA.data?.season_fav} 键=${Object.keys(relA.data || {}).join(',')}`);
const noBvidList = ((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j.data?.list || []);
const noBvidF1 = noBvidList.find((f) => String(f.id) === F1) || {};
log(`  ★ 对照：list-all 不带 bvid → F1 项有 fav_state 键=${('fav_state' in noBvidF1)} 值=${noBvidF1.fav_state}；带 bvid → ${st[F1]?.fav_state}`);
const rlCheck = (await GETj(`/x/v3/fav/resource/list?media_id=${F1}&pn=1&ps=20&platform=web`)).j;
log(`  resource/list F1 首屏命中本 bvid=${(rlCheck.data?.medias || []).some((m) => (m.bvid || m.bv_id) === BV)}（首屏 20 条内，非首屏会漏）`);

log(`\n[A2] 幂等：同一夹再收藏一次`);
const a2 = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: String(F1), del_media_ids: '', csrf });
log('  ' + brief(a2));
await sleep(900);
st = await stateOf(BV);
log('  复查: ' + fmt(st) + ` → fav_state 仍=${st[F1]?.fav_state}，F1 media_count ${INIT[F1].media_count}→${st[F1]?.media_count}（只 +1，未重复）`);

log(`\n[A3] 同时收藏到 2 个夹（一次请求 add F2,F3）`);
const a3 = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: `${F2},${F3}`, del_media_ids: '', csrf });
log('  ' + brief(a3));
await sleep(1000);
st = await stateOf(BV);
log(`  复查: F1=${st[F1]?.fav_state} F2=${st[F2]?.fav_state} F3=${st[F3]?.fav_state} | ${fmt(st)}`);

log(`\n[A4] add 与 del 同时非空（一次请求：加 F1 删 F2）`);
const a4 = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: String(F1), del_media_ids: String(F2), csrf });
log('  ' + brief(a4));
await sleep(1000);
st = await stateOf(BV);
log(`  复查: F1=${st[F1]?.fav_state}(已1? 幂等) F2=${st[F2]?.fav_state}(应0) F3=${st[F3]?.fav_state}(应1) | ${fmt(st)}`);

log(`\n[A5] 不存在的夹：假成功识别`);
const a5 = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: '999999999999', del_media_ids: '', csrf });
log('  ' + brief(a5) + '  ← 只看 code 会误判成功');
await sleep(700);
const stBogus = await stateOf(BV);
log(`  复查: 夹数 ${Object.keys(stBogus).length}（初始 ${INIT_COUNT}）→ 若 ${INIT_COUNT} 且各项 fav_state 与 A4 后一致，则服务端静默忽略 = 确认假成功`);
const a5b = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: '999999999999,222222222222', del_media_ids: '', csrf });
await sleep(500);
log('  多个不存在夹: ' + brief(a5b) + ' | 复查夹数=' + Object.keys(await stateOf(BV)).length + ' fav_state=' + Object.values(stBogus).map((f) => f.fav_state).join(''));
log(`\n[A6] del 一个不含本视频的夹（幂等删除）`);
const notIn = initFolderIds.find((id) => (st[id]?.fav_state ?? 0) === 0);
const a6 = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: '', del_media_ids: String(notIn), csrf });
log('  ' + brief(a6) + ` (del 未包含的夹 ${notIn})`);
await sleep(700);

log(`\n[A7] 取消：del 全部 → fav_state 是否回落到 0、media_count 是否回到初始`);
const a7 = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: '', del_media_ids: initFolderIds.join(','), csrf });
log('  ' + brief(a7));
await sleep(1100);
st = await stateOf(BV);
log('  复查: ' + fmt(st));
const relB = (await GETj(`/x/web-interface/archive/relation?bvid=${BV}`)).j;
log(`  archive/relation.favorite=${relB.data?.favorite}（收藏后=true，取消后应回落 false）`);
const afterStat = (await GETj(`/x/web-interface/view?bvid=${BV}`, HN)).j.data?.stat;
log(`  view.stat.favorite ${INIT_STAT_FAV}→${afterStat?.favorite}（全局收藏计数，平台侧可能有缓存/延迟）`);

log('\n=== B. 稍后再看 add/del（可逆写入）===');
const b1 = await FORM('/x/v2/history/toview/add', { aid: String(AID), csrf });
log('  add POST: ' + brief(b1));
await sleep(900);
let tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
log(`  复查 toview/web: count=${tv.data?.count}（初始 ${INIT_TOVIEW_COUNT}）含本视频=${(tv.data?.list || []).some((x) => String(x.bvid) === BV)} list[0]键=${Object.keys((tv.data?.list || [])[0] || {}).slice(0, 18).join(',')}`);
const b1b = await FORM('/x/v2/history/toview/add', { aid: String(AID), csrf });
log('  add 第二次（幂等）: ' + brief(b1b));
await sleep(600);
tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
log(`  复查 count=${tv.data?.count}（不应再加）`);
const b2 = await FORM('/x/v2/history/toview/del', { aid: String(AID), csrf });
log('  del POST: ' + brief(b2));
await sleep(900);
tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
log(`  复查: count=${tv.data?.count} 含本视频=${(tv.data?.list || []).some((x) => String(x.bvid) === BV)}（应回落到初始 ${INIT_TOVIEW_COUNT}）`);
const b2b = await FORM('/x/v2/history/toview/del', { aid: String(AID), csrf });
log('  del 第二次（不在列表）: ' + brief(b2b));
const b3 = await GETj('/x/v2/history/toview/del?aid=' + AID + '&csrf=' + csrf, H);
log('  del 走 GET?（对照）: ' + brief(b3) + '  ← 仅用于确认 GET 形态；已删所以无副作用');
const b4 = await FORM('/x/v2/history/toview/batch?platform=web', { aids: '', csrf });
log('  batch? 端点: ' + brief(b4));

log('\n=== C. 关注 UP 主（正确端点 /x/relation/modify）===');
log(`  初始 /x/relation?fid=${OWNER}&ptype=1 attribute=${INIT_ATT} data=${J(initRel.data, 160)}`);
if (INIT_ATT === 0) {
  const c1 = await FORM('/x/relation/modify', { fid: String(OWNER), act: '1', re_sub: '0', csrf });
  log('  act=1 关注: ' + brief(c1) + ' data=' + J(c1.j.data, 100));
  await sleep(900);
  const r1 = (await GETj(`/x/relation?fid=${OWNER}&ptype=1`)).j;
  log(`  复查 attribute=${r1.data?.attribute} special=${r1.data?.special} tag=${J(r1.data?.tag, 60)} mtime=${r1.data?.mtime}`);
  const arcOn = (await GETj(`/x/web-interface/archive/relation?bvid=${BV}`)).j;
  log(`  ★ 关注后 archive/relation.attention=${arcOn.data?.attention}（期望 true，验证实时性）`);
  const c2 = await FORM('/x/relation/modify', { fid: String(OWNER), act: '2', re_sub: '0', csrf });
  log('  act=2 取关: ' + brief(c2));
  await sleep(900);
  const r2 = (await GETj(`/x/relation?fid=${OWNER}&ptype=1`)).j;
  const arcOff = (await GETj(`/x/web-interface/archive/relation?bvid=${BV}`)).j;
  log(`  复查 attribute=${r2.data?.attribute}（应回 ${INIT_ATT}）| ★ archive/relation.attention=${arcOff.data?.attention}（期望回落 false）`);
  const c5 = await FORM('/x/relation/modify', { fid: String(OWNER), act: '1', re_sub: '0', csrf });
  await sleep(700);
  const arcDup = (await GETj(`/x/web-interface/archive/relation?bvid=${BV}`)).j;
  log(`  复查关注态=true 后再 act=1（重复关注）: code=${c5.j.code} msg=${redact(c5.j.message ?? '')} attention=${arcDup.data?.attention}`);
  const c6 = await FORM('/x/relation/modify', { fid: String(OWNER), act: '2', re_sub: '0', csrf });
  const c7 = await FORM('/x/relation/modify', { fid: String(OWNER), act: '2', re_sub: '0', csrf });
  await sleep(700);
  const r3 = (await GETj(`/x/relation?fid=${OWNER}&ptype=1`)).j;
  log(`  重复取关（act=2 两次）: code=${c6.j.code}/${c7.j.code} 最终 attribute=${r3.data?.attribute}（必须回 ${INIT_ATT}）`);
} else {
  log(`  ★ 初始 attribute=${INIT_ATT} ≠ 0（已关注/已拉黑），按约束跳过全部关注写入。`);
}

log('\n=== D. 投币：余额 0 的真实失败码（不可能消耗）===');
const expNow = (await GETj('/x/member/web/exp/reward')).j;
log(`  exp/reward.coins=${expNow.data?.coins}`);
const navNow = (await GETj('/x/web-interface/nav')).j;
log(`  nav.money=${navNow.data?.money}（★与 exp/reward.coins 冲突，需判定权威字段）`);
const uc = await GETj('/x/user-coins', H);
log(`  /x/user-coins: ${brief(uc)} data=${J(uc.j.data, 160)}`);
if ((expNow.data?.coins ?? 0) > 0) {
  log('  ★ 余额>0，跳过任何投币请求（禁止消耗）');
} else {
  const d1 = await FORM('/x/web-interface/coin/add', { bvid: BV, multiply: '1', select_like: '0', csrf });
  log('  coin/add multiply=1（余额0）: ' + brief(d1) + ' data=' + J(d1.j.data, 120));
  await sleep(700);
  const d2 = await FORM('/x/web-interface/coin/add', { bvid: BV, multiply: '2', select_like: '0', csrf });
  log('  coin/add multiply=2（余额0）: ' + brief(d2));
  const d3 = await FORM('/x/web-interface/coin/add', { aid: String(AID), multiply: '1', csrf });
  log('  coin/add 用 aid（余额0）: ' + brief(d3));
  const expAfter = (await GETj('/x/member/web/exp/reward')).j;
  const statAfter = (await GETj(`/x/web-interface/view?bvid=${BV}`, HN)).j.data?.stat;
  log(`  复查：coins=${expAfter.data?.coins}（应仍 ${INIT_COINS}）| stat.coin ${INIT_STAT_COIN}→${statAfter?.coin}（未变=未消耗）`);
}

log('\n=== E. 收藏夹新建/删除：端点存在性 + 受控临时夹 ===');
// 存在性：空 csrf → 404 表示端点不存在；-111 表示存在。全部零副作用。
const cands = [
  ['POST /x/v3/fav/folder/add', '/x/v3/fav/folder/add', { title: 'x', description: '', public: 'true', csrf: '' }],
  ['POST /x/v3/fav/folder/del', '/x/v3/fav/folder/del', { media_id: '999999999999', csrf: '' }],
  ['POST /x/v3/fav/folder/cur/del', '/x/v3/fav/folder/cur/del', { media_id: '999999999999', platform: 'web', csrf: '' }],
  ['GET? /x/v3/fav/folder/cur/del?media_id=', '/x/v3/fav/folder/cur/del', { media_id: '999999999999', platform: 'web', csrf: '' }],
  ['POST /x/v3/fav/folder/delete', '/x/v3/fav/folder/delete', { media_id: '999999999999', csrf: '' }],
  ['POST /x/v3/fav/folder/upd', '/x/v3/fav/folder/upd', { title: 'x', media_id: '999999999999', csrf: '' }],
  ['POST /x/v3/fav/folder/upd_info', '/x/v3/fav/folder/upd_info', { title: 'x', media_id: '999999999999', csrf: '' }],
  ['POST /x/v3/fav/folder/priv', '/x/v3/fav/folder/priv', { media_id: '999999999999', csrf: '' }],
  ['POST /x/v3/fav/folder/cur/upd', '/x/v3/fav/folder/cur/upd', { media_id: '999999999999', title: 'x', csrf: '' }],
  ['POST /x/v3/fav/resource/deals', '/x/v3/fav/resource/deals', { resources: '[]', add_media_ids: '', del_media_ids: '', csrf: '' }],
  ['POST /x/v3/fav/resource/batch/del', '/x/v3/fav/resource/batch/del', { media_id: '999999999999', recursion_ids: '[]', csrf: '' }],
];
const exist = {};
for (const [label, p, body] of cands) {
  const r = label.startsWith('GET?') ? await FORM(p, {}, { method: 'GET', query: body, queryOnly: true }) : await FORM(p, body);
  exist[p] = { label, http: r.http, code: r.j.code };
  log(`  ${label}: HTTP=${r.http} code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')}`);
}
// 删除端点是否真的可用：用不存在的 media_id + 真 csrf（无副作用）
const delProbe = [];
for (const p of ['/x/v3/fav/folder/cur/del', '/x/v3/fav/folder/del', '/x/v3/fav/folder/delete']) {
  if (exist[p] && exist[p].http !== 404) {
    const q = { media_id: '999999999999', platform: 'web' };
    const a = await FORM(p, { ...q, csrf });
    const b = await FORM(p, {}, { method: 'GET', query: { ...q, csrf }, queryOnly: true });
    delProbe.push([p, a, b]);
    log(`  删不存在夹 ${p} POST-form: ${brief(a)} | GET-query: ${brief(b)}`);
  }
}
const delOk = delProbe.find(([, a, b]) => a.http !== 404 && (a.j.code !== undefined));
if (!delOk) {
  log('  ★ 未找到可用删除端点 → 按约束【不创建临时夹】，新建/删除标记为未验证。');
} else {
  log('  删除端点可用（对不存在夹返回非 404），现在做受控临时夹回环：');
  const mk = async (title, pub) => {
    const r = await FORM('/x/v3/fav/folder/add', { title, description: 'vf probe tmp', public: String(pub), csrf });
    log(`  add "${title}" public=${pub}: ${brief(r)} data=${J(r.j.data, 140)}`);
    return r.j.data;
  };
  const p1 = await mk('VF_PROBE_TMP', true);
  await sleep(700);
  const p0 = await mk('VF_PROBE_TMP_PRIV', false);
  await sleep(700);
  const ids = [p1?.media_id, p1?.id, p0?.media_id, p0?.id].filter(Boolean);
  const lst = (await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${BV}&platform=web`)).j;
  const created = (lst.data?.list || []).filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));
  log(`  list-all 新增夹: ${created.map((f) => `${f.id} "${f.title}" attr=${f.attr} fav_state=${f.fav_state} media_count=${f.media_count}`).join(' | ')}`);
  log(`  add 返回键: ${Object.keys(p1 || {}).join(',')} 值=${J(p1, 160)}`);
  for (const f of created) {
    const i = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`)).j;
    log(`  folder/info ${f.id}: attr=${i.data?.attr} state=${i.data?.state} visibility=${i.data?.visibility} like_state=${i.data?.like_state} intro=${J(i.data?.intro, 40)}`);
  }
  // 临时夹里收藏一次，验证新夹可作为 add_media_ids（随后随夹一起删掉）
  if (created[0]) {
    const t = await FORM('/x/v3/fav/resource/deal', { rid: String(AID), type: '2', add_media_ids: String(created[0].id), del_media_ids: '', csrf });
    await sleep(800);
    const s2 = await stateOf(BV);
    log(`  收藏进临时夹: ${brief(t)} 复查 fav_state=${s2[String(created[0].id)]?.fav_state ?? '（夹已不在 list）'}`);
  }
  const [dp, , dg] = delOk;
  for (const f of created) {
    let r = await FORM(dp, { media_id: String(f.id), platform: 'web', csrf });
    if (r.http === 404 || r.j.code === undefined) r = await FORM(dp, {}, { method: 'GET', query: { media_id: String(f.id), platform: 'web', csrf }, queryOnly: true });
    log(`  删夹 ${f.id} "${f.title}" via ${dp}: ${brief(r)}`);
    await sleep(600);
  }
  const lst2 = (await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${BV}&platform=web`)).j;
  const left = (lst2.data?.list || []).filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));
  log(`  ★ 删后残留 VF_PROBE_TMP* 夹 = ${left.length}（应 0）；夹数 ${(lst2.data?.list || []).length}（应回到初始 ${INIT_COUNT}）`);
  if (left.length) {
    log('  ★★ 清理未成功，需人工在 B站 Web 删除：' + left.map((f) => `${f.id}/${f.title}`).join(','));
  }
}

log('\n=== Z. 账号状态恢复核对 ===');
const finSt = await stateOf(BV);
const finIds = Object.keys(finSt);
const favOk = finIds.length === INIT_COUNT && finIds.every((id) => (finSt[id]?.fav_state ?? -1) === 0);
const cntOk = finIds.every((id) => finSt[id]?.media_count === initCounts[id]);
const tv2 = (await GETj('/x/v2/history/toview/web?platform=web')).j;
const tvOk = (tv2.data?.count ?? -1) === INIT_TOVIEW_COUNT && (tv2.data?.list || []).some((x) => String(x.bvid) === BV) === INIT_TOVIEW_HAS;
const rel2 = (await GETj(`/x/relation?fid=${OWNER}&ptype=1`)).j;
const relOk = rel2.data?.attribute === INIT_ATT;
const exp2 = (await GETj('/x/member/web/exp/reward')).j;
const coinOk = exp2.data?.coins === INIT_COINS;
const st2 = (await GETj(`/x/web-interface/view?bvid=${BV}`, HN)).j.data?.stat;
log(`  收藏夹归属: 夹数 ${finIds.length}/${INIT_COUNT} fav_state=[${finIds.map((i) => finSt[i].fav_state).join('')}] → ${favOk ? 'OK' : '★FAIL'}`);
log(`  各夹 media_count 回初始: ${cntOk ? 'OK' : '★差异: ' + finIds.filter((id) => finSt[id].media_count !== initCounts[id]).map((id) => `${finSt[id].title} ${initCounts[id]}→${finSt[id].media_count}`).join(';')}`);
log(`  稍后再看 count=${tv2.data?.count}(初始${INIT_TOVIEW_COUNT}) 含本视频=${(tv2.data?.list || []).some((x) => String(x.bvid) === BV)} → ${tvOk ? 'OK' : '★FAIL'}`);
log(`  关注态 attribute=${rel2.data?.attribute}(初始${INIT_ATT}) → ${relOk ? 'OK' : '★FAIL'}`);
log(`  硬币余额=${exp2.data?.coins}(初始${INIT_COINS}) stat.coin=${st2?.coin}(初始${INIT_STAT_COIN}) → ${coinOk ? 'OK（未消耗）' : '★FAIL'}`);
log(`  全局 stat.favorite=${st2?.favorite}(初始${INIT_STAT_FAV}) — 平台聚合计数，可能有缓存延迟，不作为回滚判据`);
log(`\n账号状态已恢复：${favOk && cntOk && tvOk && relOk && coinOk ? '是（全部核对通过）' : '部分项需人工核对（见上）'}`);
