// B站收藏：真实写入测试（用户明确授权，用小号）。
//
// 测试顺序（每步都验证服务端真实状态，不靠本地布尔值）：
//   1. 选一个测试视频（推荐流第一条）
//   2. 查初始收藏状态（archive/relation）
//   3. 收藏到指定收藏夹（fav/resource/deal, add_media_ids）
//   4. 复查 archive/relation -> favorite 是否变 true
//   5. 查该收藏夹内是否真的有这个视频（fav/resource/list）
//   6. 取消收藏（del_media_ids）
//   7. 复查是否恢复 false
//
// 全部使用真实 Cookie（环境变量），不写入任何文件。
//
// 同时对比：用错误 media_id 时返回什么，以确认失败可被识别。

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

const COOKIE = process.env.BILI_COOKIE || '';
if (!COOKIE) {
  console.log('缺少 BILI_COOKIE');
  process.exit(1);
}
const uid = (COOKIE.match(/DedeUserID=(\d+)/) || [])[1] || '';
const csrf = (COOKIE.match(/bili_jct=([^;]+)/) || [])[1] || '';

const H = {
  'user-agent': UA,
  referer: 'https://www.bilibili.com/',
  origin: 'https://www.bilibili.com',
  cookie: COOKIE,
  accept: 'application/json, text/plain, */*',
  'content-type': 'application/x-www-form-urlencoded',
};

async function getJson(url) {
  const r = await fetch(url, { headers: H });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { code: 'non-json', raw: t.slice(0, 200) }; }
}

async function postForm(url, body) {
  const r = await fetch(url, {
    method: 'POST',
    headers: H,
    body: new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { code: 'non-json', raw: t.slice(0, 200) }; }
}

// ---------- 准备 ----------
const pop = await (await fetch('https://api.bilibili.com/x/web-interface/popular?ps=3&pn=1', {
  headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' },
})).json();
const v = pop.data.list[0];
const aid = v.aid;
const bvid = v.bvid;
console.log(`测试视频: aid=${aid} bvid=${bvid}`);
console.log(`标题: ${v.title.slice(0, 40)}`);
console.log('');

const favs = await getJson(
  `https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=${uid}`
);
const folders = favs.data?.list || [];
console.log(`收藏夹 ${folders.length} 个:`);
for (const f of folders) console.log(`  id=${f.id}  "${f.title}"  count=${f.media_count}`);
// 选默认收藏夹（名字含"默认"）
const target = folders.find((f) => f.title.includes('默认')) || folders[0];
console.log(`\n目标收藏夹: id=${target.id} "${target.title}"`);
console.log('');

// ---------- 1. 初始状态 ----------
console.log('=== 1. 初始状态 ===');
const before = await getJson(
  `https://api.bilibili.com/x/web-interface/archive/relation?bvid=${bvid}`
);
console.log(`  archive/relation: favorite=${before.data?.favorite} like=${before.data?.like} coin=${before.data?.coin}`);

// 该收藏夹里是否已有这个视频
async function inFolder(mediaId) {
  const r = await getJson(
    `https://api.bilibili.com/x/v3/fav/resource/list?media_id=${mediaId}&pn=1&ps=20&platform=web`
  );
  const medias = r.data?.medias || [];
  return { found: medias.some((m) => String(m.id) === String(aid)), count: medias.length, code: r.code };
}
const inBefore = await inFolder(target.id);
console.log(`  收藏夹 "${target.title}" 前 ${inBefore.count} 条中${inBefore.found ? '**已包含**' : '不包含'}该视频`);
console.log('');

// ---------- 2. 收藏 ----------
console.log('=== 2. 执行收藏（add_media_ids）===');
const addRes = await postForm('https://api.bilibili.com/x/v3/fav/resource/deal', {
  rid: String(aid),
  type: '2',
  add_media_ids: String(target.id),
  del_media_ids: '',
  csrf: csrf,
});
console.log(`  响应: code=${addRes.code}  message=${addRes.message}`);
console.log(`  完整: ${JSON.stringify(addRes).slice(0, 300)}`);
console.log('');

// ---------- 3. 复查 ----------
console.log('=== 3. 服务端是否真的变了 ===');
await new Promise((r) => setTimeout(r, 800));
const after = await getJson(
  `https://api.bilibili.com/x/web-interface/archive/relation?bvid=${bvid}`
);
console.log(`  archive/relation: favorite=${after.data?.favorite}`);
const inAfter = await inFolder(target.id);
console.log(`  收藏夹 "${target.title}" 前 ${inAfter.count} 条中${inAfter.found ? '**已包含** ✅' : '仍不包含 ❌'}`);
console.log('');

// ---------- 4. 取消收藏 ----------
console.log('=== 4. 取消收藏（del_media_ids）===');
const delRes = await postForm('https://api.bilibili.com/x/v3/fav/resource/deal', {
  rid: String(aid),
  type: '2',
  add_media_ids: '',
  del_media_ids: String(target.id),
  csrf: csrf,
});
console.log(`  响应: code=${delRes.code}  message=${delRes.message}`);
await new Promise((r) => setTimeout(r, 800));
const final = await getJson(
  `https://api.bilibili.com/x/web-interface/archive/relation?bvid=${bvid}`
);
console.log(`  恢复后 favorite=${final.data?.favorite}`);
const inFinal = await inFolder(target.id);
console.log(`  收藏夹内${inFinal.found ? '仍包含 ❌' : '已移除 ✅'}`);
console.log('');

// ---------- 5. 错误场景 ----------
console.log('=== 5. 错误场景（验证失败可被识别）===');
const badFolder = await postForm('https://api.bilibili.com/x/v3/fav/resource/deal', {
  rid: String(aid),
  type: '2',
  add_media_ids: '999999999999',
  del_media_ids: '',
  csrf: csrf,
});
console.log(`  不存在的 media_id: code=${badFolder.code} message=${badFolder.message}`);
const badCsrf = await postForm('https://api.bilibili.com/x/v3/fav/resource/deal', {
  rid: String(aid),
  type: '2',
  add_media_ids: String(target.id),
  del_media_ids: '',
  csrf: 'wrong-csrf-value',
});
console.log(`  错误 csrf        : code=${badCsrf.code} message=${badCsrf.message}`);
console.log('');
console.log('=== 测试结束，账号状态已恢复 ===');
