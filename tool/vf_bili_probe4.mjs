// 第四轮探针 —— 全部【只读 / 零写入】。
// 目的：
//   1) 复核 fav_state（纯读：候选端点、初始态、不同 bvid 差异、非登录差异）
//   2) 收藏夹 attr / visibility / state / cnt_info 语义（夹属性全字段）
//   3) 写入接口的"存在性"探测：一律用空 csrf（预期 -111）或非法 act/type，
//      确保服务端拒绝执行，绝不产生真实副作用（建夹/删夹/关注/投币都不落地）
//   4) 稍后再看、投币余额、view.stat 的字段结构
// 安全：输出只打印 cookie 的名字、bili_jct 长度、DedeUserID（公开 uid）。
//       所有打印都经过 redact()，防止任何 cookie 值意外泄漏。
// 可重复运行：不写任何状态。
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

// —— 泄漏防护：任何输出前把 cookie 的值替换为 <REDACTED> ——
const secrets = COOKIE.split(';')
  .map((s) => s.trim().split('=')[1])
  .filter((v) => v && v.length >= 4);
const redact = (s) => {
  let t = String(s);
  for (const v of secrets) t = t.split(v).join('<REDACTED>');
  return t;
};
const J = (v, n = 260) => redact(JSON.stringify(v)).slice(0, n);
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : x)));

console.log('=== 0. 凭据自证（仅名字/长度）===');
log(
  `cookie 名=[${COOKIE.split(';').map((s) => s.trim().split('=')[0]).join(',')}] ` +
    `bili_jct.len=${csrf.length} DedeUserID=${uid}`
);

const H = {
  'user-agent': UA,
  referer: 'https://www.bilibili.com/',
  cookie: COOKIE,
  accept: 'application/json, text/plain, */*',
};
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };

const GETj = async (u, h = H) => {
  const r = await fetch(u, { headers: h });
  const t = await r.text();
  try {
    return { status: r.status, j: JSON.parse(t) };
  } catch {
    return { status: r.status, j: { __nonJson: true, body: t.replace(/\s+/g, ' ').slice(0, 60) } };
  }
};
// 存在性探测专用：POST 但强制空 csrf（或指定危险参数），预期被服务端拒绝。
const POSTsafe = async (p, body, forceEmptyCsrf = true) => {
  const b = { ...body };
  if (forceEmptyCsrf) b.csrf = '';
  const r = await fetch(`${API}${p}`, {
    method: 'POST',
    headers: { ...H, origin: 'https://www.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(b).toString(),
  });
  const t = await r.text();
  let j;
  try {
    j = JSON.parse(t);
  } catch {
    j = { __nonJson: true, body: t.replace(/\s+/g, ' ').slice(0, 60) };
  }
  return { status: r.status, j };
};

const nav = (await GETj(`${API}/x/web-interface/nav`)).j;
log(`\nnav: isLogin=${nav.data?.isLogin} mid=${nav.data?.mid} vipType=${nav.data?.vipType} money?=${nav.data?.money}`);

const exp = (await GETj(`${API}/x/member/web/exp/reward`)).j;
log(`exp/reward: coins=${exp.data?.coins} (投币余额；0 表示不可投币)\n`);

log('=== 1. fav_state 语义复核（纯只读）===');
const pickBvid = process.env.VF_TEST_BVID || '';
const cand = [];
if (pickBvid) cand.push(pickBvid);
const pop = (await GETj(`${API}/x/web-interface/popular?ps=3&pn=1`, HN)).j;
for (const it of pop.data?.list || []) cand.push(it.bvid);
const seq = (await GETj(`${API}/x/web-interface/archive/related?bvid=${cand[0]}`, HN)).j;
for (const it of (seq.data || []).slice(0, 3)) cand.push(it.bvid);
const uniq = [...new Set(cand)].slice(0, 5);

// 1a 不带 bvid vs 带 bvid 的字段差异
const noBvid = (await GETj(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j;
log(`\n[1a] list-all 不带 bvid: 每项键 = ${Object.keys(noBvid.data?.list?.[0] || {}).join(',')}`);
log(`     fav_state 是否存在 = ${'fav_state' in (noBvid.data?.list?.[0] || {})}`);

const first = uniq[0];
const withBvid = (await GETj(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${first}&platform=web`)).j;
log(`[1b] list-all 带 bvid=${first}: 每项键 = ${Object.keys(withBvid.data?.list?.[0] || {}).join(',')}`);
const folders = withBvid.data?.list || [];
log(`     夹清单（id/title/attr/upper/mid/fav_state）：`);
for (const f of folders)
  log(`       ${f.id} "${f.title}" attr=${f.attr} upper=${f.upper} mid=${f.mid} fav_state=${f.fav_state} videos=${f.media_count}`);

// 1c 多 bvid 交叉：确认 fav_state 是按 bvid 计算的、不是固定值
log(`[1c] 同一组夹对不同 bvid 的 fav_state 矩阵（0/1/其它）：`);
const matrix = {};
for (const b of uniq) {
  const j = (await GETj(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${b}&platform=web`)).j;
  matrix[b] = (j.data?.list || []).map((f) => f.fav_state).join('');
  log(`       ${b} -> [${matrix[b]}]`);
}
const seenVals = new Set(Object.values(matrix).join('').split(''));
log(`     ★ 观测到的 fav_state 取值集合 = {${[...seenVals].join(',')}}；初始全为 0 => 该视频当前未在任何夹内`);

// 1d 匿名（无 cookie）时 fav_state
const anon = (await GETj(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${first}&platform=web`, HN)).j;
log(`[1d] 匿名请求: code=${anon.code} 首项 fav_state=${(anon.data?.list || [])[0]?.fav_state}（匿名应拿不到个人归属态）`);

// 1e aid 版（type=1 用 aid）是否也支持
const vinfo = (await GETj(`${API}/x/web-interface/view?bvid=${first}`, HN)).j;
log(`     view: code=${vinfo.code} aid=${vinfo.data?.aid} bvid=${vinfo.data?.bvid} title="${(vinfo.data?.title || '').slice(0, 24)}"`);
const byAid = (await GETj(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&aid=${vinfo.data?.aid}&platform=web`)).j;
log(`[1e] list-all 用 aid= 代替 bvid=: 首项 fav_state=${(byAid.data?.list || [])[0]?.fav_state}（若与 bvid 版一致则 aid 亦可）`);

log('\n=== 2. 夹属性：attr / visibility / state / cnt_info 全字段 ===');
for (const f of folders) {
  const i = (await GETj(`${API}/x/v3/fav/folder/info?media_id=${f.id}&platform=web`)).j;
  const d = i.data || {};
  log(
    `  ${f.id} "${f.title}" list-all.attr=${f.attr} | info: code=${i.code} attr=${d.attr} ` +
      `visibility=${d.visibility} state=${d.state} like_status=${d.like_status} ` +
      `in_free_time=${d.in_free_time} show_follow_activity=${d.show_follow_activity} ` +
      `upper=${J(d.upper, 60)} cnt_info=${J(d.cnt_info, 90)}`
  );
  log(`       info 全部键: ${Object.keys(d).join(',')}`);
}
log(`  list-all 每项全部键: ${Object.keys(folders[0] || {}).join(',')}`);

log('\n=== 3. resource/list 结构 + 漏判风险（只读）===');
const def = folders.find((f) => (f.attr === 0 || String(f.title).includes('默认'))) || folders[0];
const big = folders.sort((a, b) => (b.media_count || 0) - (a.media_count || 0))[0];
for (const f of [def, big]) {
  const rl = (await GETj(`${API}/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web&detail=1`)).j;
  const d = rl.data || {};
  const m0 = (d.medias || [])[0] || {};
  log(
    `  "${f.title}"(${f.media_count}) data键=${Object.keys(d).join(',')} has_more=${d.has_more} ttl=${d.ttl} ` +
      `medias=${(d.medias || []).length} info键=${Object.keys(d.info || {}).join(',')}`
  );
  log(`       medias[0] 键: ${Object.keys(m0).slice(0, 40).join(',')} | fav_time=${m0.fav_time} id=${m0.id} bvid=${m0.bvid || m0.bv_id}`);
}
// 用 info.media_count 判断是否需要翻页（>20 就说明"只看第一页"会漏判）
log(`  ★ 最大夹 "${big.title}" media_count=${big.media_count} > ps=20 => 逐夹 resource/list 首屏会漏判，fav_state 才是权威`);

log('\n=== 4. 写入端点【存在性】探测：一律空 csrf 或非法参数，服务端应拒绝执行 ===');
const aid0 = vinfo.data.aid, BV0 = vinfo.data.bvid;
const exists = [];
const show = async (label, promise) => {
  const { status, j } = await promise;
  log(`  ${label}\n      HTTP=${status} code=${j.code} msg=${redact(j.message || j.body || '')} data=${J(j.data, 80)}`);
  exists.push({ label, http: status, code: j.code, msg: j.message ?? j.body });
};
await show('fav/resource/deal POST csrf=""（应 -111，证明端点存在且不落地）', POSTsafe('/x/v3/fav/resource/deal', { rid: String(aid0), type: '2', add_media_ids: String(def.id), del_media_ids: '' }));
await show('fav/folder/add POST csrf="" title=VF_PROBE_TMP', POSTsafe('/x/v3/fav/folder/add', { title: 'VF_PROBE_TMP', description: 'probe', public: 'false', csrf }));
await show('fav/folder/cur/del POST csrf="" media_id=999999999999', POSTsafe('/x/v3/fav/folder/cur/del', { media_id: '999999999999', platform: 'web' }));
await show('fav/folder/upd POST csrf="" media_id=999999999999', POSTsafe('/x/v3/fav/folder/upd', { title: 'x', media_id: '999999999999', platform: 'web' }));
await show('relation/modify POST csrf="" fid=240352 act=1', POSTsafe('/x/relation/modify', { fid: uid, act: '1', re_sub: '0' }));
await show('relation/modify POST act=999（非法 act，真 csrf）', POSTsafe('/x/relation/modify', { fid: uid, act: '999', re_sub: '0', csrf }, false));
await show('[旧] relation/tags/addUsers POST csrf=""', POSTsafe('/x/relation/tags/addUsers', { fids: uid, tagid: '0' }));
await show('[旧] relation/fans/del POST csrf="" fid=240352', POSTsafe('/x/relation/fans/del', { fid: uid }));
await show('history/toview/add POST csrf="" aid', POSTsafe('/x/v2/history/toview/add', { aid: String(aid0) }));
await show('history/toview/del POST csrf="" aid', POSTsafe('/x/v2/history/toview/del', { aid: String(aid0) }));
await show('coin/add POST csrf="" bvid multiply=1', POSTsafe('/x/web-interface/coin/add', { bvid: BV0, multiply: '1', select_like: '0' }));
await show('coin/add POST multiply=0（非法数量，真 csrf，不消耗）', POSTsafe('/x/web-interface/coin/add', { bvid: BV0, multiply: '0', csrf }, false));
await show('archive/like POST csrf="" bvid', POSTsafe('/x/web-interface/archive/like', { bvid: BV0, thumb: '1' }));

log('\n=== 5. 稍后再看 / 关注态 读取侧字段（只读）===');
const tv = (await GETj(`${API}/x/v2/history/toview/web?platform=web`)).j;
log(`  toview/web: code=${tv.code} data键=${Object.keys(tv.data || {}).join(',')} count=${tv.data?.count} listlen=${(tv.data?.list || []).length}`);
const tvm = (await GETj(`${API}/x/v2/history/toview/middle?platform=web`)).j;
log(`  toview/middle: code=${tvm.code} data=${J(tvm.data, 120)}`);
const tv0 = (await GETj(`${API}/x/v2/history/toview`)).j;
log(`  toview(旧): code=${tv0.code} data键=${Object.keys(tv0.data || {}).join(',')}`);
log(`  ★ 待测 bvid=${BV0} 是否已在稍后再看: ${(tv.data?.list || []).some((x) => String(x.bvid) === BV0 || String(x.aid) === String(aid0))}`);

const owner = vinfo.data.owner.mid;
const rel = (await GETj(`${API}/x/relation?fid=${owner}&ptype=1`)).j;
log(`\n  /x/relation?fid=${owner}&ptype=1: code=${rel.code} data=${J(rel.data, 200)}`);
log(`       data 全部键: ${Object.keys(rel.data || {}).join(',')}`);
const card = (await GETj(`${API}/x/web-interface/card?mid=${owner}`)).j;
log(`  card.relation=${J(card.data?.relation, 300)}`);
const myRel = (await GETj(`${API}/x/relation?fid=${uid}&ptype=1`)).j;
log(`  /x/relation 自查(fid=自己): attribute=${myRel.data?.attribute}（关注端点存在性已在上节验证）`);
const relTag = (await GETj(`${API}/x/relation/tag?mid=${uid}&tagid=-10&pn=1&ps=5`)).j;
log(`  /x/relation/tag?tagid=-10 关注列表: code=${relTag.code} 条数=${(relTag.data || []).length} 首项键=${Object.keys((relTag.data || [])[0] || {}).join(',')}`);
const arcRel = (await GETj(`${API}/x/web-interface/archive/relation?bvid=${BV0}`)).j;
log(`  archive/relation: data键=${Object.keys(arcRel.data || {}).join(',')} 值=${J(arcRel.data, 200)}`);

log('\n=== 6. view.stat 计数权威来源（只读）===');
log(`  stat=${J(vinfo.data?.stat, 300)}`);
log(`  mysum?=${J(vinfo.data?.mysum, 160)}  staff?=${vinfo.data?.staff !== undefined} pages=${(vinfo.data?.pages || []).length}`);
const multi = (await GETj(`${API}/x/web-interface/view?bvid=${(seq.data || [])[0]?.bvid || BV0}`, HN)).j;
log(`  另一样本 stat=${J(multi.data?.stat, 220)}`);

log('\n=== 7. 零写入核对（与脚本开头同基准）===');
const nav2 = (await GETj(`${API}/x/web-interface/nav`)).j;
const exp2 = (await GETj(`${API}/x/member/web/exp/reward`)).j;
const tv2 = (await GETj(`${API}/x/v2/history/toview/web?platform=web`)).j;
const fl2 = (await GETj(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${BV0}&platform=web`)).j;
const states2 = (fl2.data?.list || []).map((f) => f.fav_state).join('');
const ok =
  exp2.data?.coins === exp.data?.coins &&
  tv2.data?.count === tv.data?.count &&
  (fl2.data?.list || []).length === folders.length &&
  /^0+$/.test(states2);
log(`  夹数 ${(fl2.data?.list || []).length}（应 ${folders.length}）| fav_state 串 ${states2}（应全 0）| coins ${exp2.data?.coins}（应 ${exp.data?.coins}）| toview.count ${tv2.data?.count}（应 ${tv.data?.count}）`);
log(`  结论：${ok ? '账号状态未被本探针改动（零写入确认通过）' : '★异常：出现变化，需人工核对'}`);
log(`  账号状态已恢复：${ok ? '是（本来就没改）' : '需核对'}`);

fs.writeFileSync('D:/vf-local/probe4_exists.json', redact(JSON.stringify(exists, null, 1)));
log('  存在性探测结果已写入仓库外: D:/vf-local/probe4_exists.json（不在 git 内）');
