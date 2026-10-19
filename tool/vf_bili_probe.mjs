// B站登录链路与收藏接口只读探针（本地测试专用）。
//
// 凭据来源：**只从环境变量 BILI_COOKIE 或仓库外的文件读取**。
// 本文件不含任何 Cookie 值，可安全提交。
//
//   $env:BILI_COOKIE = (Get-Content D:\vf-local\bili_cookie.txt -Raw)
//   node tool/vf_bili_probe.mjs              # 只读：nav / 收藏夹 / relation
//   node tool/vf_bili_probe.mjs --write      # 写入：收藏→校验→取消（需用户授权）
//
// 输出原则：只打印 cookie 的**名字**和脱敏摘要，绝不打印取值。
// 这样即使日志被贴进仓库也不会泄露凭据。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

function loadCookie() {
  if (process.env.BILI_COOKIE) return process.env.BILI_COOKIE.trim();
  const p = process.env.BILI_COOKIE_FILE || 'D:/vf-local/bili_cookie.txt';
  if (fs.existsSync(p)) return fs.readFileSync(p, 'utf8').trim();
  return '';
}

const COOKIE = loadCookie();
if (!COOKIE) {
  console.log('没有凭据：设置 BILI_COOKIE 或 BILI_COOKIE_FILE');
  process.exit(1);
}

const pairs = COOKIE.split(';').map((s) => s.trim()).filter(Boolean);
const names = pairs.map((p) => p.split('=')[0]);
console.log(`凭据：${names.length} 项 cookie -> ${names.join(', ')}`);
const get = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = get('DedeUserID');
const csrf = get('bili_jct');
console.log(`DedeUserID=${uid}  bili_jct 长度=${csrf.length}（值不打印）`);
console.log('');

const H = {
  'user-agent': UA,
  referer: 'https://www.bilibili.com/',
  origin: 'https://www.bilibili.com',
  cookie: COOKIE,
  accept: 'application/json, text/plain, */*',
  'content-type': 'application/x-www-form-urlencoded',
};
const HG = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };

const jget = async (u) => {
  const r = await fetch(u, { headers: HG });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { code: 'non-json', raw: t.slice(0, 160) }; }
};
const jpost = async (u, body) => {
  const r = await fetch(u, { method: 'POST', headers: H, body: new URLSearchParams(body).toString() });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { code: 'non-json', raw: t.slice(0, 160) }; }
};

const API = 'https://api.bilibili.com';

// ---------- 1. 登录状态 ----------
console.log('=== 1. 登录状态 /x/web-interface/nav ===');
const nav = await jget(`${API}/x/web-interface/nav`);
console.log(`  code=${nav.code} isLogin=${nav.data?.isLogin} mid=${nav.data?.mid} ` +
  `vipType=${nav.data?.vipType} uninfo=(${nav.data?.fans?.medal_info ? 'has' : 'none'})`);
if (!nav.data?.isLogin) {
  console.log('  ✗ 登录态无效，后续写入测试中止');
  process.exit(2);
}
console.log('');

// ---------- 2. 收藏夹列表 ----------
console.log('=== 2. 收藏夹列表 /x/v3/fav/folder/created/list-all ===');
const favs = await jget(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}`);
const folders = favs.data?.list || [];
console.log(`  code=${favs.code} count=${favs.data?.count} 实际=${folders.length}`);
for (const f of folders) {
  console.log(`    id=${f.id}  "${f.title}"  media_count=${f.media_count} attr=${f.attr} ${f.title.includes('默认') ? '← 默认夹(按名称)' : ''}`);
}
console.log('');

// ---------- 3. 取测试视频 ----------
const testBv = process.env.VF_TEST_BVID || '';
let tv = null;
if (testBv) {
  const r = await jget(`${API}/x/web-interface/view?bvid=${testBv}`);
  tv = r.data;
  console.log(`=== 3. 指定测试视频 ${testBv} aid=${tv?.aid} "${(tv?.title || '').slice(0, 30)}" ===`);
} else {
  const pop = await jget(`${API}/x/web-interface/popular?ps=1&pn=1`);
  tv = pop.data?.list?.[0];
  console.log(`=== 3. 测试视频（热门第一条）aid=${tv?.aid} bvid=${tv?.bvid} ===`);
}
console.log(`  标题: ${(tv?.title || '').slice(0, 40)}`);
const aid = tv.aid, bvid = tv.bvid;
console.log('');

// ---------- 4. 互动状态 ----------
console.log('=== 4. 互动状态 /x/web-interface/archive/relation ===');
const rel = await jget(`${API}/x/web-interface/archive/relation?bvid=${bvid}`);
const d = rel.data || {};
console.log(`  code=${rel.code} like=${d.like} coin=${d.coin} favorite=${d.favorite} ` +
  `fav_time=${d.fav_time} progress=${d.progress}`);
console.log(`  data 的全部键: ${Object.keys(d).join(', ')}`);
console.log('');

// ---------- 5. 该视频在哪些夹里（逐个夹 resource/list） ----------
console.log('=== 5. 收藏夹归属查询 /x/v3/fav/resource/list ===');
for (const f of folders) {
  const r = await jget(`${API}/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`);
  const medias = r.data?.medias || [];
  const hit = medias.some((m) => String(m.id) === String(aid));
  console.log(`  "${f.title}"(${f.id}) code=${r.code} 返回${medias.length}/${r.data?.total || 0} 条 ${hit ? '★ 含该视频' : ''}`);
}
console.log('');

// ---------- 5b. 一次性验证：fav/resource/metas（是否能直接反查归属） ----------
console.log('=== 5b. 反查方案对比：/x/v3/fav/resource/metas ===');
const metas = await jget(`${API}/x/v3/fav/resource/metas?platform=web&type=2&ids=${aid}&with_current=false`);
console.log(`  code=${metas.code} ${JSON.stringify(metas).slice(0, 300)}`);
console.log('=== 5c. /x/v2/fav/video?bvid= ===');
const fv = await jget(`${API}/x/v2/fav/video?bvid=${bvid}`);
console.log(`  code=${fv.code} ${JSON.stringify(fv).slice(0, 300)}`);
console.log('');

// ---------- 6. 写入测试（需显式 --write） ----------
if (!process.argv.includes('--write')) {
  console.log('（未加 --write，跳过真实写入；收藏/取消未测试）');
  process.exit(0);
}
const target = folders.find((f) => f.title.includes('默认')) || folders[0];
console.log(`=== 6. 真实写入测试：收藏到 "${target.title}"(${target.id}) ===`);
const add = await jpost(`${API}/x/v3/fav/resource/deal`, {
  rid: String(aid), type: '2', add_media_ids: String(target.id), del_media_ids: '', csrf,
});
console.log(`  收藏响应: code=${add.code} message=${add.message} toasts=${JSON.stringify(add.toasts || null)}`);
console.log(`  响应全部键: ${Object.keys(add).join(', ')}`);
await new Promise((r) => setTimeout(r, 1000));
const rel2 = await jget(`${API}/x/web-interface/archive/relation?bvid=${bvid}`);
console.log(`  服务端复查: favorite=${rel2.data?.favorite} fav_time=${rel2.data?.fav_time}`);
const inF = await jget(`${API}/x/v3/fav/resource/list?media_id=${target.id}&pn=1&ps=20&platform=web`);
const found = (inF.data?.medias || []).some((m) => String(m.id) === String(aid));
console.log(`  收藏夹列表复查: ${found ? '★ 已包含（服务端确认）' : '✗ 未包含'}`);

console.log('=== 7. 重复收藏（幂等性）===');
const dup = await jpost(`${API}/x/v3/fav/resource/deal`, {
  rid: String(aid), type: '2', add_media_ids: String(target.id), del_media_ids: '', csrf,
});
console.log(`  重复收藏: code=${dup.code} message=${dup.message}`);

console.log('=== 8. 取消收藏并恢复 ===');
const del = await jpost(`${API}/x/v3/fav/resource/deal`, {
  rid: String(aid), type: '2', add_media_ids: '', del_media_ids: String(target.id), csrf,
});
console.log(`  取消响应: code=${del.code} message=${del.message}`);
await new Promise((r) => setTimeout(r, 1000));
const rel3 = await jget(`${API}/x/web-interface/archive/relation?bvid=${bvid}`);
console.log(`  服务端复查: favorite=${rel3.data?.favorite}`);

console.log('=== 9. 错误场景 ===');
const badF = await jpost(`${API}/x/v3/fav/resource/deal`, {
  rid: String(aid), type: '2', add_media_ids: '999999999999', del_media_ids: '', csrf,
});
console.log(`  不存在 media_id : code=${badF.code} message=${badF.message}`);
const badC = await jpost(`${API}/x/v3/fav/resource/deal`, {
  rid: String(aid), type: '2', add_media_ids: String(target.id), del_media_ids: '', csrf: 'deadbeef',
});
console.log(`  错误 csrf       : code=${badC.code} message=${badC.message}`);
const noC = await jpost(`${API}/x/v3/fav/resource/deal`, {
  rid: String(aid), type: '2', add_media_ids: String(target.id), del_media_ids: '',
});
console.log(`  缺 csrf         : code=${noC.code} message=${noC.message}`);
console.log('');
console.log('=== 结束：账号收藏状态已恢复原状 ===');
