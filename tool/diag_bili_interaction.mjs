// B站互动状态：只读诊断（不改任何账号数据）。
//
// 用真实 Cookie 探测以下接口的真实响应，定位"收藏按钮不高亮"的根因：
//   1. /x/web-interface/nav              -> 登录态是否有效
//   2. /x/web-interface/archive/relation -> 当前实现用的状态接口
//   3. /x/v3/fav/folder/created/list-all -> 收藏夹列表
//   4. /x/v2/fav/folder/created/list-all -> 备用收藏夹接口
//   5. /x/v3/fav/resource/list           -> 某收藏夹内是否有该视频
//   6. /x/web-interface/archive/has/like -> 是否已点赞
//   7. /x/web-interface/archive/coins    -> 已投币数
//
// 全部只读，不做任何写操作。
//
// Cookie 从环境变量读，不写死在文件里。

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

const COOKIE = process.env.BILI_COOKIE || '';
if (!COOKIE) {
  console.log('缺少 BILI_COOKIE 环境变量');
  process.exit(1);
}

// 从 Cookie 里取 uid（不打印完整 Cookie）
const uidMatch = COOKIE.match(/DedeUserID=(\d+)/);
const uid = uidMatch ? uidMatch[1] : '';
console.log('=== 凭据检查（只显示长度，不显示取值）===');
for (const k of ['SESSDATA', 'bili_jct', 'DedeUserID', 'sid']) {
  const m = COOKIE.match(new RegExp(k + '=([^;]*)'));
  console.log(`  ${k.padEnd(12)} ${m ? 'len=' + m[1].length : '(缺失)'}`);
}
console.log(`  uid = ${uid}`);
console.log('');

async function get(label, url, { withCookie = true } = {}) {
  const headers = {
    'user-agent': UA,
    referer: 'https://www.bilibili.com/',
    accept: 'application/json, text/plain, */*',
  };
  if (withCookie) headers.cookie = COOKIE;
  try {
    const r = await fetch(url, { headers });
    const t = await r.text();
    let code = '?', msg = '', dataKeys = '';
    let raw = null;
    try {
      raw = JSON.parse(t);
      code = raw.code;
      msg = raw.message || '';
      if (raw.data && typeof raw.data === 'object') {
        dataKeys = Object.keys(raw.data).slice(0, 12).join(',');
      }
    } catch {
      code = 'non-json';
    }
    console.log(`  ${label.padEnd(44)} HTTP=${r.status} code=${String(code).padEnd(6)} ${msg.slice(0, 20)}`);
    if (dataKeys) console.log(`      data keys: ${dataKeys}`);
    return raw;
  } catch (e) {
    console.log(`  ${label.padEnd(44)} ERR ${e.message}`);
    return null;
  }
}

// ---------- 1. 登录态 ----------
console.log('=== 1. 登录态 ===');
const nav = await get('nav', 'https://api.bilibili.com/x/web-interface/nav');
if (nav?.data) {
  console.log(`      isLogin=${nav.data.isLogin}  mid=${nav.data.mid}  uname=${nav.data.uname}`);
}
console.log('');

// ---------- 2. 取一个视频 ----------
const pop = await (await fetch('https://api.bilibili.com/x/web-interface/popular?ps=3&pn=1', {
  headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' },
})).json();
const v = pop.data.list[0];
const aid = v.aid;
const bvid = v.bvid;
console.log(`=== 2. 测试视频 aid=${aid} bvid=${bvid} ===`);
console.log(`   标题: ${v.title.slice(0, 36)}`);
console.log('');

// ---------- 3. archive/relation（当前实现用的接口）----------
console.log('=== 3. 当前实现用的状态接口 ===');
const rel = await get(
  'archive/relation (带 Cookie)',
  `https://api.bilibili.com/x/web-interface/archive/relation?bvid=${bvid}`
);
if (rel?.data) {
  console.log(`      完整 data: ${JSON.stringify(rel.data)}`);
}
await get(
  'archive/relation (无 Cookie)',
  `https://api.bilibili.com/x/web-interface/archive/relation?bvid=${bvid}`,
  { withCookie: false }
);
console.log('');

// ---------- 4. 收藏夹列表 ----------
console.log('=== 4. 收藏夹列表 ===');
const favAll = await get(
  'v3/fav/folder/created/list-all',
  `https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=${uid}`
);
if (favAll?.data?.list) {
  console.log(`      收藏夹数: ${favAll.data.list.length}`);
  for (const f of favAll.data.list) {
    console.log(`        id=${f.id}  name="${f.title}"  count=${f.media_count}  default=${f.attr === 1 || f.is_default === true}`);
  }
}
const favAll2 = await get(
  'v2/fav/folder/created/list-all (备用)',
  `https://api.bilibili.com/x/v2/fav/folder/created/list-all?up_mid=${uid}`
);
if (favAll2?.data?.list) {
  console.log(`      v2 收藏夹数: ${favAll2.data.list.length}`);
}
console.log('');

// ---------- 5. 该视频是否已在某收藏夹 ----------
console.log('=== 5. 该视频的收藏情况（关键）===');
// 老接口：返回该视频被收藏到的收藏夹
const inFav = await get(
  'v2/fav/folder/created/contains',
  `https://api.bilibili.com/x/v2/fav/folder/created/contains?rid=${aid}&type=2`
);
if (inFav?.data) {
  console.log(`      data: ${JSON.stringify(inFav.data).slice(0, 300)}`);
}
// 另一个常用接口
const favList = await get(
  'v3/fav/resource/list (查默认收藏夹)',
  favAll?.data?.list?.length
    ? `https://api.bilibili.com/x/v3/fav/resource/list?media_id=${favAll.data.list[0].id}&pn=1&ps=20&platform=web`
    : `https://api.bilibili.com/x/v3/fav/resource/list?media_id=0&pn=1&ps=20`
);
if (favList?.data?.medias) {
  const found = favList.data.medias.find((m) => String(m.id) === String(aid));
  console.log(`      默认收藏夹前 20 条中${found ? '**包含**' : '不包含'}该视频`);
}
console.log('');

// ---------- 6. 点赞 / 投币 ----------
console.log('=== 6. 点赞 / 投币状态 ===');
await get(
  'archive/has/like',
  `https://api.bilibili.com/x/web-interface/archive/has/like?bvid=${bvid}`
);
await get(
  'archive/coins',
  `https://api.bilibili.com/x/web-interface/archive/coins?bvid=${bvid}`
);
console.log('');
console.log('=== 诊断结束（未做任何写操作）===');
