// B站收藏/互动接口能力探针（只读为主，本地测试用，凭据从仓库外读取）。
//
// 目的：确定"收藏夹选择面板"该用哪个接口，以及投币余额/稍后再看/
// 关注状态的权威接口。输出不含任何 cookie 值。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE ||
  fs.readFileSync(process.env.BILI_COOKIE_FILE || 'D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const get = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = get('DedeUserID'), csrf = get('bili_jct');
const API = 'https://api.bilibili.com';
const HG = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };

const jget = async (u) => {
  const r = await fetch(u, { headers: HG });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { __nonJson: true, status: r.status, raw: t.slice(0, 120) }; }
};

const pop = await jget(`${API}/x/web-interface/popular?ps=1&pn=1`);
const tv = pop.data.list[0];
const { aid, bvid } = tv;
console.log(`测试视频 aid=${aid} bvid=${bvid} "${tv.title.slice(0, 30)}"\n`);

// ── A. 收藏夹选择面板专用接口：user/tags ─────────────────────────
console.log('=== A. /x/v3/fav/user/tags?bvid= （B站 Web 收藏面板用的接口）===');
const tags = await jget(`${API}/x/v3/fav/user/tags?platform=web&bvid=${bvid}`);
console.log(`  code=${tags.code} message=${tags.message}`);
const tl = tags.data?.list || [];
console.log(`  收藏夹 ${tl.length} 个，每项字段: ${tl.length ? Object.keys(tl[0]).join(',') : '-'}`);
for (const f of tl) {
  console.log(`    id=${f.id} "${f.title}" media_count=${f.media_count} fav_state=${f.fav_state} attr=${f.attr} ${f.current_state != null ? 'current_state=' + f.current_state : ''}`);
}
console.log(`  data 顶层键: ${tags.data ? Object.keys(tags.data).join(',') : 'null'}\n`);

// 用 aid 再试一次，看参数是否敏感
const tagsAid = await jget(`${API}/x/v3/fav/user/tags?platform=web&aid=${aid}`);
console.log(`  用 aid= 参数: code=${tagsAid.code} n=${(tagsAid.data?.list || []).length} ` +
  `fav_state序列=${(tagsAid.data?.list || []).map((f) => f.fav_state).join('/')}`);
const tagsNone = await jget(`${API}/x/v3/fav/user/tags?platform=web&bvid=BV1xx411c7mD`);
console.log(`  另一视频 bvid: code=${tagsNone.code} fav_state序列=${(tagsNone.data?.list || []).map((f) => f.fav_state).join('/')}`);
const tagsAnon = await (await fetch(`${API}/x/v3/fav/user/tags?platform=web&bvid=${bvid}`, {
  headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' } })).json().catch(() => ({}));
console.log(`  匿名（不带 cookie）: code=${tagsAnon.code} message=${tagsAnon.message}\n`);

// ── B. created/list-all 的 attr 语义 + folder/info ─────────────
console.log('=== B. attr 语义确认（上一步 attr=22 的账号夹）===');
const created = await jget(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}`);
for (const f of (created.data?.list || [])) {
  const info = await jget(`${API}/x/v3/fav/folder/info?media_id=${f.id}`);
  console.log(`  "${f.title}" list-all.attr=${f.attr} info.visibility=${info.data?.visibility} ` +
    `info.ctr=(${info.data?.ctr ? Object.keys(info.data.ctr).join(',') : '-'}) intro_len=${(info.data?.intro || '').length}`);
}
console.log('');

// ── C. fav/resource/list 真实结构（total 字段名） ────────────────
console.log('=== C. /x/v3/fav/resource/list 结构 ===');
const rl = await jget(`${API}/x/v3/fav/resource/list?media_id=${created.data.list[0].id}&pn=1&ps=20&platform=web`);
console.log(`  data 键: ${Object.keys(rl.data || {}).join(',')}`);
console.log(`  count=${rl.data?.count} medias=${(rl.data?.medias || []).length} has_more=${rl.data?.has_more} ` +
  `bvid_count=${(rl.data?.bvids || []).length}`);
console.log(`  medias[0] 键: ${rl.data?.medias?.[0] ? Object.keys(rl.data.medias[0]).join(',') : '-'}`);
console.log(`  medias[0].id=${rl.data?.medias?.[0]?.id} upper=$(rl.data?.medias?.[0]?.upper?.mid)\n`);

// ── D. 投币余额 ────────────────────────────────────────────────
console.log('=== D. 投币余额 /x/member/web/exp/reward ===');
const exp = await jget(`${API}/x/member/web/exp/reward`);
console.log(`  code=${exp.code} 键=${Object.keys(exp.data || {}).join(',')}`);
console.log(`  coin=${exp.data?.coin} level=${exp.data?.level} video_exp=${exp.data?.video_exp} ` +
  `daily_cap=${exp.data?.daily_exp_cap} vip=${exp.data?.vip_exp} login=${exp.data?.login}`);
const money = await jget(`${API}/x/web-interface/coin/money`);
console.log(`  /x/web-interface/coin/money: code=${money.code} ${JSON.stringify(money).slice(0, 160)}\n`);

// ── E. 稍后再看 ────────────────────────────────────────────────
console.log('=== E. 稍后再看 /x/v3/fav/season 系与 /x/collection/watching/later ===');
const later = await jget(`${API}/x/collection/watching/later?platform=web`);
console.log(`  watching/later: code=${later.code} count=${(later.data?.list || []).length} 键=${Object.keys(later.data || {}).join(',')}`);
const rel = await jget(`${API}/x/web-interface/archive/relation?bvid=${bvid}`);
console.log(`  archive/relation data 键=${Object.keys(rel.data || {}).join(',')} -> ${JSON.stringify(rel.data)}\n`);

// ── F. 关注（UP 主）状态 ───────────────────────────────────────
console.log('=== F. 关注状态 /x/relation/tag? 与 /x/space/relation ===');
const upMid = tv.owner.mid;
const card = await jget(`${API}/x/web-interface/card?mid=${upMid}`);
console.log(`  UP主 mid=${upMid} name="${card.data?.card?.name}" relation=${JSON.stringify(card.data?.relation)?.slice(0, 200)}`);
const g = await jget(`${API}/x/relation/tags?referer=${upMid}&platform=web`);
console.log(`  /x/relation/tags: code=${g.code} ${JSON.stringify(g).slice(0, 200)}\n`);

// ── G. 点赞/投币错误路径（不发成功请求，只验参数校验分支） ─────
console.log('=== G. 写接口错误分支（不改变账号数据）===');
const post = async (p, body) => {
  const r = await fetch(`${API}${p}`, {
    method: 'POST',
    headers: { ...HG, origin: 'https://www.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });
  return r.json().catch(() => ({}));
};
const badLike = await post('/x/web-interface/archive/like', { bvid: 'BV00000000000', like: '1', csrf });
console.log(`  like 不存在的 bvid : code=${badLike.code} message=${badLike.message}`);
const badCoinCsrf = await post('/x/web-interface/archive/like', { bvid, like: '1', csrf: 'wrong' });
console.log(`  like 错误 csrf     : code=${badCoinCsrf.code} message=${badCoinCsrf.message}`);
const badCoin = await post('/x/web-interface/coin/add', { bvid: 'BV00000000000', multiply: '1', select_like: '0', csrf });
console.log(`  coin 不存在的 bvid : code=${badCoin.code} message=${badCoin.message}`);
const badFav = await post('/x/v3/fav/resource/deal', { rid: '1', type: '2', add_media_ids: '999999999999', del_media_ids: '', csrf });
console.log(`  fav 不存在的夹     : code=${badFav.code} message=${badFav.message}`);
const emptyFav = await post('/x/v3/fav/resource/deal', { rid: String(aid), type: '2', add_media_ids: '', del_media_ids: '', csrf });
console.log(`  fav 两个都空       : code=${emptyFav.code} message=${emptyFav.message}`);
