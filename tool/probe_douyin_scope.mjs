// 抖音：分区 / 互动 的真实接口探测。
//
// 目标（按用户要求，尽量达到目的）：
//   7. 弹幕        —— ws 握手被拒，找是否有 HTTP 轮询替代
//   8. 分区        —— 找分区列表接口
//   9. 互动        —— 点赞/关注/发弹幕，找可用端点
//
// 已知失败：/webcast/room/partition/、/webcast/tag/list/、
//           /webcast/room/search/ 全部 url doesn't match
//
// 新思路：
//   - 分区：从 feed 的 category / base_category 反推有哪些分类；
//           或试 /webcast/category/list/、/webcast/room/tab/
//   - 互动：抖音直播点赞是 /webcast/room/like/，需要 signature
//   - 弹幕：试 /webcast/im/fetch/ 带正确参数

const UA =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function get(url, tries = 4) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, {
        headers: {
          'user-agent': UA,
          referer: 'https://live.douyin.com/',
          accept: 'application/json, text/plain, */*',
        },
      });
      const t = await r.text();
      if (t.trim()) return { status: r.status, text: t };
    } catch (e) {
      // ignore
    }
    await new Promise((res) => setTimeout(res, 300 * (i + 1)));
  }
  return { status: 0, text: '' };
}

function describe(name, r) {
  let code = '?';
  let msg = '';
  let keys = '';
  let count = '';
  try {
    const p = JSON.parse(r.text);
    if (p.status_code !== undefined) code = p.status_code;
    if (p.status_msg) msg = p.status_msg;
    if (p.data) {
      if (Array.isArray(p.data)) {
        count = `array(${p.data.length})`;
        if (p.data[0] && typeof p.data[0] === 'object') {
          keys = Object.keys(p.data[0]).slice(0, 10).join(',');
        }
      } else if (typeof p.data === 'object') {
        keys = Object.keys(p.data).slice(0, 10).join(',');
      }
    }
  } catch {
    code = 'non-json';
  }
  const flag = msg.includes("doesn't match") ? ' <-rejected' : '';
  console.log(
    `  ${name.padEnd(30)} HTTP=${String(r.status).padEnd(4)} ` +
    `size=${String(r.text.length).padEnd(7)} code=${String(code).padEnd(6)} ` +
    `msg=${msg.slice(0, 26)} ${count} keys=[${keys}]${flag}`
  );
  return r;
}

// ---------- 先拿一个房间 ----------
const feed = await get(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=5&type=0`);
if (!feed.text) {
  console.log('feed 空，终止');
  process.exit(1);
}
const j = JSON.parse(feed.text);
const room = j.data[0].data;
const roomId = room.id_str;
console.log('room =', roomId);
console.log('room.category =', room.category, ' base_category =', room.base_category);
console.log('');

// ---------- 8. 分区 ----------
console.log('=== 8. 分区接口探测 ===');
const partitionEndpoints = [
  ['category/list', `/webcast/category/list/?${COMMON}`],
  ['room/tab', `/webcast/room/tab/?${COMMON}`],
  ['room/partition/list', `/webcast/room/partition/list/?${COMMON}`],
  ['webcast/category', `/webcast/category/?${COMMON}`],
  ['live/category/list', `/webcast/live/category/list/?${COMMON}`],
  ['room/area', `/webcast/room/area/?${COMMON}`],
  ['webcast/partition', `/webcast/partition/?${COMMON}`],
  ['room/tag/list', `/webcast/room/tag/list/?${COMMON}`],
];
for (const [name, path] of partitionEndpoints) {
  await describe(name, await get(`https://webcast.amemv.com${path}`));
}

// ---------- 收集 feed 里出现的所有 category ----------
console.log('');
console.log('=== 8b. 从 feed 反推实际存在的 category ===');
const catCount = new Map();
for (const entry of j.data) {
  const c = entry.data?.category;
  if (c !== undefined) catCount.set(c, (catCount.get(c) ?? 0) + 1);
}
console.log('  本批 feed 的 category 分布:', JSON.stringify([...catCount]));

// 多取几批，统计全部分类
const allCats = new Map();
for (let i = 0; i < 3; i++) {
  const f = await get(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=20&type=0`);
  if (!f.text) continue;
  try {
    const p = JSON.parse(f.text);
    for (const e of p.data ?? []) {
      const c = e.data?.category;
      if (c !== undefined) allCats.set(c, (allCats.get(c) ?? 0) + 1);
    }
  } catch {}
  await new Promise((r) => setTimeout(r, 500));
}
console.log('  3 批 feed 累计 category 分布:', JSON.stringify([...allCats].sort((a, b) => b[1] - a[1])));

// ---------- 9. 互动 ----------
console.log('');
console.log('=== 9. 互动接口探测（GET 先看路径是否接受）===');
const interactEndpoints = [
  ['room/like', `/webcast/room/like/?${COMMON}&room_id=${roomId}&count=1`],
  ['room/follow', `/webcast/room/follow/?${COMMON}&room_id=${roomId}`],
  ['room/comment', `/webcast/room/comment/?${COMMON}&room_id=${roomId}`],
  ['room/digg', `/webcast/room/digg/?${COMMON}&room_id=${roomId}`],
  ['room/chat/send', `/webcast/room/chat/send/?${COMMON}&room_id=${roomId}`],
  ['im/send', `/webcast/im/send/?${COMMON}&room_id=${roomId}`],
];
for (const [name, path] of interactEndpoints) {
  await describe(name, await get(`https://webcast.amemv.com${path}`));
}

// ---------- 7. 弹幕：HTTP 轮询替代 ----------
console.log('');
console.log('=== 7. 弹幕 HTTP 轮询替代方案 ===');
const danmakuEndpoints = [
  ['im/fetch', `/webcast/im/fetch/?${COMMON}&room_id=${roomId}&cursor=0&fetch_rule=1`],
  ['im/fetch2', `/webcast/im/fetch/?${COMMON}&room_id=${roomId}&live_id=1&cursor=0`],
  ['room/message', `/webcast/room/message/?${COMMON}&room_id=${roomId}`],
  ['room/chat/list', `/webcast/room/chat/list/?${COMMON}&room_id=${roomId}`],
  ['im/message', `/webcast/im/message/?${COMMON}&room_id=${roomId}`],
];
for (const [name, path] of danmakuEndpoints) {
  await describe(name, await get(`https://webcast.amemv.com${path}`));
}

// ---------- ws 带 signature 再试一次 ----------
console.log('');
console.log('=== 7b. ws 握手：加常见 query 参数 ===');
const roomForWs = roomId;
const wsVariants = [
  `wss://webcast5-ws-web-lf.douyin.com/webcast/im/ws/?app_name=douyin_web&version_code=180800&webcast_sdk_version=1.0.14&room_id=${roomForWs}&compress=gzip&device_platform=web`,
  `wss://webcast5-ws-web-lf.douyin.com/webcast/im/ws/?room_id=${roomForWs}&app_name=douyin_lite&aid=1128`,
  `wss://webcast5-ws-web-lf.douyin.com/webcast/im/ws/?room_id=${roomForWs}`,
];
for (const u of wsVariants) {
  const res = await new Promise((resolve) => {
    const to = setTimeout(() => resolve('timeout'), 7000);
    let ws;
    try {
      ws = new WebSocket(u);
    } catch (e) {
      clearTimeout(to);
      return resolve('ctor: ' + e.message);
    }
    ws.onopen = () => {
      clearTimeout(to);
      ws.close();
      resolve('OPENED');
    };
    ws.onerror = () => {
      clearTimeout(to);
      resolve('rejected (non-101)');
    };
    ws.onclose = (e) => {
      clearTimeout(to);
      resolve(`closed ${e.code}`);
    };
  });
  const short = u.replace('wss://webcast5-ws-web-lf.douyin.com/webcast/im/ws/?', '').slice(0, 60);
  console.log(`  ${short.padEnd(62)} -> ${res}`);
}
