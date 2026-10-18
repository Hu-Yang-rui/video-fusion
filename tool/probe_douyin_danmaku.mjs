// 抖音直播弹幕：找 ws 入口与 signature 要求。
//
// 已知：room_auth.Chat = true，但 im_info 里没有 ws 地址。
// 需要找：
//   1. ws 地址从哪来（可能在 feed 响应其他位置，或需要单独接口）
//   2. signature 怎么算（抖音用 X-MS-STUB 或 query 里的 signature）
//
// 同时测几个已知的抖音弹幕相关接口。

const UA =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function get(url, tries = 6) {
  for (let i = 0; i < tries; i++) {
    const r = await fetch(url, {
      headers: {
        'user-agent': UA,
        referer: 'https://live.douyin.com/',
        accept: 'application/json, text/plain, */*',
      },
    });
    const t = await r.text();
    if (t.trim()) return { status: r.status, text: t };
    await new Promise((res) => setTimeout(res, 400 * (i + 1)));
  }
  return { status: 0, text: '' };
}

// ---------- 1. 拿房间 ----------
const feed = await get(
  `https://webcast.amemv.com/webcast/feed/?${COMMON}&count=3&type=0`
);
if (!feed.text) {
  console.log('feed 一直空，终止');
  process.exit(1);
}
const j = JSON.parse(feed.text);
const room = j.data[0].data;
const roomId = room.id_str;
console.log('room =', roomId);
console.log('');

// ---------- 2. 找 ws 地址 ----------
console.log('=== 1. room 对象里的 ws / im 线索 ===');
const hits = [];
(function walk(o, path) {
  if (o === null || o === undefined) return;
  if (typeof o === 'string') {
    if (/^wss?:\/\//i.test(o) || /webcast.*im|im.*webcast|\/webcast\/im\//i.test(o)) {
      hits.push(`${path} = ${o.slice(0, 140)}`);
    }
    return;
  }
  if (typeof o === 'object') {
    for (const k of Object.keys(o)) walk(o[k], path ? `${path}.${k}` : k);
  }
})(room, 'room');
console.log(hits.length ? hits.join('\n') : '(none)');
console.log('');

// ---------- 3. 测弹幕相关接口 ----------
console.log('=== 2. 弹幕相关接口探测 ===');
const endpoints = [
  ['im/fetch', `https://webcast.amemv.com/webcast/im/fetch/?${COMMON}&room_id=${roomId}&cursor=0`],
  ['im/pull', `https://webcast.amemv.com/webcast/im/pull/?${COMMON}&room_id=${roomId}`],
  ['room/web/enter', `https://webcast.amemv.com/webcast/room/web/enter/?${COMMON}&web_rid=1&room_id=${roomId}`],
  ['chat/list', `https://webcast.amemv.com/webcast/chat/list/?${COMMON}&room_id=${roomId}`],
  ['im/wrds', `https://webcast.amemv.com/webcast/im/wrds/?${COMMON}&room_id=${roomId}`],
  ['room/chat', `https://webcast.amemv.com/webcast/room/chat/?${COMMON}&room_id=${roomId}`],
  ['room/enter', `https://webcast.amemv.com/webcast/room/enter/?${COMMON}&room_id=${roomId}`],
];

for (const [name, url] of endpoints) {
  const r = await get(url, 3);
  let code = '?';
  let msg = '';
  let keys = '';
  try {
    const p = JSON.parse(r.text);
    if (p.status_code !== undefined) code = p.status_code;
    if (p.status_msg) msg = p.status_msg;
    if (p.data && typeof p.data === 'object') {
      keys = Object.keys(p.data).slice(0, 12).join(',');
    }
  } catch {
    code = 'non-json';
  }
  console.log(
    `  ${name.padEnd(16)} HTTP=${String(r.status).padEnd(4)} ` +
    `size=${String(r.text.length).padEnd(7)} code=${String(code).padEnd(6)} ` +
    `msg=${msg.slice(0, 30)} keys=[${keys}]`
  );
}

// ---------- 4. 看 room_auth 里 Chat/Danmaku 的具体结构 ----------
console.log('');
console.log('=== 3. room_auth.Chat / Danmaku ===');
for (const k of ['Chat', 'Danmaku', 'DanmakuDefault', 'PublicScreen']) {
  if (room.room_auth?.[k] !== undefined) {
    console.log(`  ${k} =`, JSON.stringify(room.room_auth[k]).slice(0, 200));
  }
}

// ---------- 5. 检查 feed 响应顶层有没有 im 配置 ----------
console.log('');
console.log('=== 4. feed 响应顶层 / extra ===');
console.log('  top keys:', Object.keys(j).join(', '));
if (j.extra) console.log('  extra:', JSON.stringify(j.extra).slice(0, 400));

// ---------- 6. 已知的抖音弹幕 ws 域名能否解析/握手 ----------
console.log('');
console.log('=== 5. 抖音弹幕 ws 域名连通性 ===');
const wsHosts = [
  'wss://webcast5-ws-web-lf.douyin.com/webcast/im/ws/',
  'wss://webcast5-ws-web-hl.douyin.com/webcast/im/ws/',
  'wss://webcast-ws.douyin.com/webcast/im/ws/',
];
for (const h of wsHosts) {
  const url = `${h}?app_name=douyin_web&version_code=180800&webcast_sdk_version=1.0.14&room_id=${roomId}&compress=gzip`;
  const res = await new Promise((resolve) => {
    const to = setTimeout(() => resolve('timeout'), 8000);
    let ws;
    try {
      ws = new WebSocket(url);
    } catch (e) {
      clearTimeout(to);
      return resolve('ctor: ' + e.message);
    }
    ws.onopen = () => {
      clearTimeout(to);
      ws.close();
      resolve('OPENED');
    };
    ws.onerror = (e) => {
      clearTimeout(to);
      resolve('error: ' + (e.message || 'unknown'));
    };
    ws.onclose = (e) => {
      clearTimeout(to);
      resolve('closed code=' + e.code + (e.reason ? ' reason=' + e.reason : ''));
    };
  });
  console.log(`  ${h.slice(6, 50).padEnd(46)} -> ${res}`);
}
