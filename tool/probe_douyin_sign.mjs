// 复现抖音直播弹幕 signature（参考 DouyinLiveWebFetcher 的实现思路）。
//
// 参考项目的做法：
//   1. 拼一个 wss URL，含 13 个固定参数
//   2. 把这 13 个参数按固定顺序拼成 "k1=v1,k2=v2,..."
//   3. md5 这个字符串
//   4. 用 JS 引擎执行 sign.js 的 get_sign(md5) → 得到 signature
//   5. wss + "&signature=" + signature，带 Cookie: ttwid=xxx
//
// 本脚本在 Node 里复现第 2~4 步，验证：
//   a) sign.js 能否在 Node 里跑起来（需要 window/document shim）
//   b) 生成的 signature 能否让 ws 握手成功（101）
//
// 如果能打通，说明抖音弹幕在纯 Dart 之外是可行的；
// 但注意：这需要执行平台风控 JS，属于另一类合规判断。

import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';

const SIGN_JS = fs.readFileSync('build/dyref/sign.js', 'utf8');

// ---------- 1. 构造 wss ----------
const ROOM_ID = process.argv[2] || '7697991152271723273';
const USER_UNIQUE_ID = '7319483754668557238';
const T = Date.now();

const wss =
  'wss://webcast100-ws-web-lq.douyin.com/webcast/im/push/v2/?app_name=douyin_web' +
  '&version_code=180800&webcast_sdk_version=1.0.14-beta.0' +
  '&update_version_code=1.0.14-beta.0&compress=gzip&device_platform=web&cookie_enabled=true' +
  '&screen_width=1536&screen_height=864&browser_language=zh-CN&browser_platform=Win32' +
  '&browser_name=Mozilla' +
  '&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20AppleWebKit/537.36%20(KHTML,' +
  '%20like%20Gecko)%20Chrome/126.0.0.0%20Safari/537.36' +
  '&browser_online=true&tz_name=Asia/Shanghai' +
  `&cursor=d-1_u-1_fh-7392091211001140287_t-${T}_r-1` +
  `&internal_ext=internal_src:dim|wss_push_room_id:${ROOM_ID}|wss_push_did:${USER_UNIQUE_ID}` +
  `|first_req_ms:${T}|fetch_time:${T}|seq:1|wss_info:0-${T}-0-0|` +
  'wrds_v:7392094459690748497' +
  `&host=https://live.douyin.com&aid=6383&live_id=1&did_rule=3&endpoint=live_pc&support_wrds=1` +
  `&user_unique_id=${USER_UNIQUE_ID}&im_path=/webcast/im/fetch/&identity=audience` +
  '&need_persist_msg_count=15&insert_task_id=&live_reason=' +
  `&room_id=${ROOM_ID}&heartbeatDuration=0`;

// ---------- 2. 按参考项目的参数顺序算 md5 ----------
const PARAM_ORDER = [
  'live_id', 'aid', 'version_code', 'webcast_sdk_version',
  'room_id', 'sub_room_id', 'sub_channel_id', 'did_rule',
  'user_unique_id', 'device_platform', 'device_type', 'ac',
  'identity',
];

const query = wss.split('?')[1] || '';
const maps = {};
for (const kv of query.split('&')) {
  const i = kv.indexOf('=');
  if (i > 0) maps[kv.slice(0, i)] = kv.slice(i + 1);
}
const tpl = PARAM_ORDER.map((k) => `${k}=${maps[k] ?? ''}`).join(',');
const md5Param = crypto.createHash('md5').update(tpl, 'utf8').digest('hex');

console.log('=== 参数拼接 ===');
console.log('  tpl =', tpl);
console.log('  md5 =', md5Param);
console.log('');

// ---------- 3. 在 vm 里执行 sign.js ----------
console.log('=== 在 Node vm 中执行 sign.js ===');

// sign.js 依赖浏览器环境，需要最小 shim
const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  Math,
  Date,
  JSON,
  parseInt,
  parseFloat,
  isNaN,
  encodeURIComponent,
  decodeURIComponent,
  escape,
  unescape,
  String,
  Number,
  Boolean,
  Array,
  Object,
  RegExp,
  Error,
  atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.document = {
  createElement: () => ({
    style: {},
    setAttribute: () => {},
    appendChild: () => {},
    getContext: () => null,
  }),
  documentElement: { style: {} },
  getElementsByTagName: () => [],
  addEventListener: () => {},
  cookie: '',
};
sandbox.navigator = {
  userAgent:
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  platform: 'Win32',
  language: 'zh-CN',
  languages: ['zh-CN', 'zh'],
  cookieEnabled: true,
  webdriver: false,
  plugins: { length: 5 },
  mimeTypes: { length: 2 },
};
sandbox.location = {
  href: 'https://live.douyin.com/',
  protocol: 'https:',
  host: 'live.douyin.com',
  hostname: 'live.douyin.com',
  pathname: '/',
  search: '',
  hash: '',
};
sandbox.screen = { width: 1536, height: 864, availWidth: 1536, availHeight: 864 };
sandbox.localStorage = {
  _d: {},
  getItem(k) { return this._d[k] ?? null; },
  setItem(k, v) { this._d[k] = String(v); },
  removeItem(k) { delete this._d[k]; },
};
sandbox.sessionStorage = sandbox.localStorage;
sandbox.performance = { now: () => Date.now(), timeOrigin: Date.now() };
sandbox.crypto = { getRandomValues: (a) => crypto.randomFillSync(a) };
sandbox.addEventListener = () => {};
sandbox.removeEventListener = () => {};

let signature = null;
try {
  const ctx = vm.createContext(sandbox);
  vm.runInContext(SIGN_JS, ctx, { timeout: 20000 });
  if (typeof ctx.get_sign === 'function') {
    signature = ctx.get_sign(md5Param);
    console.log('  get_sign() 返回:', String(signature).slice(0, 80));
    console.log('  signature 长度:', String(signature).length);
  } else {
    console.log('  !! ctx.get_sign 不是函数，类型:', typeof ctx.get_sign);
    // 看看沙箱里有哪些顶层函数
    const keys = Object.keys(ctx).filter((k) => typeof ctx[k] === 'function');
    console.log('  可用函数:', keys.slice(0, 20).join(', '));
  }
} catch (e) {
  console.log('  !! 执行失败:', e.message.slice(0, 200));
}

if (!signature) {
  console.log('');
  console.log('结论：sign.js 在当前 Node 环境跑不通，需要完整浏览器环境。');
  process.exit(1);
}

// ---------- 4. 试 ws 握手 ----------
console.log('');
console.log('=== ws 握手（带 signature）===');

// 先取 ttwid
async function getTtwid() {
  const r = await fetch('https://ttwid.bytedance.com/ttwid/union/register/', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      region: 'cn',
      aid: 1768,
      needFid: false,
      service: 'www.ixigua.com',
      migrate_info: { ticket: '', source: 'node' },
      cbUrlProtocol: 'https',
      union: true,
    }),
  });
  const setCookie = r.headers.get('set-cookie') || '';
  const m = setCookie.match(/ttwid=([^;]+)/);
  return m ? m[1] : null;
}

const ttwid = await getTtwid();
console.log('  ttwid:', ttwid ? ttwid.slice(0, 30) + '...' : '(none)');

const finalUrl = `${wss}&signature=${signature}`;
const res = await new Promise((resolve) => {
  const to = setTimeout(() => resolve('timeout'), 12000);
  let ws;
  try {
    ws = new WebSocket(finalUrl, {
      headers: {
        'user-agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
          '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        ...(ttwid ? { cookie: `ttwid=${ttwid}` } : {}),
      },
    });
  } catch (e) {
    clearTimeout(to);
    return resolve('ctor: ' + e.message);
  }
  ws.onopen = () => {
    clearTimeout(to);
    ws.close();
    resolve('OPENED (101)');
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

console.log('  结果:', res);
console.log('');
if (String(res).includes('OPENED')) {
  console.log('结论：signature 有效，ws 握手成功 → 抖音弹幕技术上可实现');
} else {
  console.log('结论：signature 生成了但握手仍失败，可能还缺 ttwid/__ac_signature 等');
}
