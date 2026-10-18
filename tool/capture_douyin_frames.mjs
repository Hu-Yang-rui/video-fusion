// 用真实抓到的帧验证 Dart 解析器。
//
// 流程：连抖音 ws，收几帧，把原始二进制存成文件；
// 然后 Dart 侧读文件跑 DouyinDanmakuCodec，比对结果。
//
// 这样能在不把风控 JS 搬进 Dart 的前提下，
// 证明**解析层**是正确可用的。

import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';

const SIGN_JS = fs.readFileSync('build/dyref/sign.js', 'utf8');
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function feedOnce(tries = 8) {
  for (let i = 0; i < tries; i++) {
    const r = await fetch(
      `https://webcast.amemv.com/webcast/feed/?${COMMON}&count=5&type=0`,
      { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } }
    );
    const t = await r.text();
    if (t.trim()) return JSON.parse(t);
    await new Promise((s) => setTimeout(s, 400 * (i + 1)));
  }
  return null;
}

const feed = await feedOnce();
if (!feed) { console.log('feed 空'); process.exit(1); }
// 找一个人气高一点的房间（弹幕多）
const rooms = feed.data.map((e) => e.data).filter(Boolean);
rooms.sort((a, b) => (b.user_count ?? 0) - (a.user_count ?? 0));
const room = rooms[0];
const roomId = room.id_str;
console.log('room =', roomId, '|', (room.title || '').slice(0, 26),
  '| 在线', room.user_count);

const UID = '7319483754668557238';
const T = Date.now();
const wssBase =
  'wss://webcast100-ws-web-lq.douyin.com/webcast/im/push/v2/?app_name=douyin_web' +
  '&version_code=180800&webcast_sdk_version=1.0.14-beta.0' +
  '&update_version_code=1.0.14-beta.0&compress=gzip&device_platform=web&cookie_enabled=true' +
  '&screen_width=1536&screen_height=864&browser_language=zh-CN&browser_platform=Win32' +
  '&browser_name=Mozilla' +
  '&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20AppleWebKit/537.36%20(KHTML,' +
  '%20like%20Gecko)%20Chrome/126.0.0.0%20Safari/537.36' +
  '&browser_online=true&tz_name=Asia/Shanghai' +
  `&cursor=d-1_u-1_fh-7392091211001140287_t-${T}_r-1` +
  `&internal_ext=internal_src:dim|wss_push_room_id:${roomId}|wss_push_did:${UID}` +
  `|first_req_ms:${T}|fetch_time:${T}|seq:1|wss_info:0-${T}-0-0|wrds_v:7392094459690748497` +
  `&host=https://live.douyin.com&aid=6383&live_id=1&did_rule=3&endpoint=live_pc&support_wrds=1` +
  `&user_unique_id=${UID}&im_path=/webcast/im/fetch/&identity=audience` +
  `&need_persist_msg_count=15&insert_task_id=&live_reason=&room_id=${roomId}&heartbeatDuration=0`;

const ORDER = ['live_id','aid','version_code','webcast_sdk_version','room_id','sub_room_id','sub_channel_id','did_rule','user_unique_id','device_platform','device_type','ac','identity'];
const maps = {};
for (const kv of wssBase.split('?')[1].split('&')) {
  const i = kv.indexOf('=');
  if (i > 0) maps[kv.slice(0, i)] = kv.slice(i + 1);
}
const md5Param = crypto.createHash('md5')
  .update(ORDER.map((k) => `${k}=${maps[k] ?? ''}`).join(','), 'utf8').digest('hex');

const sandbox = {
  console, setTimeout, clearTimeout, setInterval, clearInterval,
  Math, Date, JSON, parseInt, parseFloat, isNaN,
  encodeURIComponent, decodeURIComponent, escape, unescape,
  String, Number, Boolean, Array, Object, RegExp, Error,
  atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
};
sandbox.window = sandbox; sandbox.self = sandbox; sandbox.globalThis = sandbox;
sandbox.document = { createElement: () => ({ style: {}, setAttribute: () => {}, appendChild: () => {}, getContext: () => null }), documentElement: { style: {} }, getElementsByTagName: () => [], addEventListener: () => {}, cookie: '' };
sandbox.navigator = { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36', platform: 'Win32', language: 'zh-CN', languages: ['zh-CN','zh'], cookieEnabled: true, webdriver: false, plugins: { length: 5 }, mimeTypes: { length: 2 } };
sandbox.location = { href: 'https://live.douyin.com/', protocol: 'https:', host: 'live.douyin.com', hostname: 'live.douyin.com', pathname: '/', search: '', hash: '' };
sandbox.screen = { width: 1536, height: 864, availWidth: 1536, availHeight: 864 };
sandbox.localStorage = { _d: {}, getItem(k){return this._d[k]??null;}, setItem(k,v){this._d[k]=String(v);}, removeItem(k){delete this._d[k];} };
sandbox.sessionStorage = sandbox.localStorage;
sandbox.performance = { now: () => Date.now(), timeOrigin: Date.now() };
sandbox.crypto = { getRandomValues: (a) => crypto.randomFillSync(a) };
sandbox.addEventListener = () => {}; sandbox.removeEventListener = () => {};

const ctx = vm.createContext(sandbox);
vm.runInContext(SIGN_JS, ctx, { timeout: 20000 });
const signature = ctx.get_sign(md5Param);

async function getTtwid() {
  const r = await fetch('https://ttwid.bytedance.com/ttwid/union/register/', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ region: 'cn', aid: 1768, needFid: false, service: 'www.ixigua.com', migrate_info: { ticket: '', source: 'node' }, cbUrlProtocol: 'https', union: true }),
  });
  const sc = r.headers.get('set-cookie') || '';
  const m = sc.match(/ttwid=([^;]+)/);
  return m ? m[1] : null;
}
const ttwid = await getTtwid();

// ---------- 收帧并存盘 ----------
fs.mkdirSync('build/dyframes', { recursive: true });
const frames = [];

await new Promise((resolve) => {
  const to = setTimeout(() => { try { ws.close(); } catch {} resolve(); }, 25000);
  const ws = new WebSocket(`${wssBase}&signature=${signature}`, {
    headers: {
      'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      ...(ttwid ? { cookie: `ttwid=${ttwid}` } : {}),
    },
  });
  ws.onopen = () => console.log('WS 101');
  ws.onmessage = async (ev) => {
    let buf;
    if (typeof ev.data === 'string') buf = Buffer.from(ev.data, 'binary');
    else if (ev.data instanceof Blob) buf = Buffer.from(await ev.data.arrayBuffer());
    else buf = Buffer.from(ev.data);
    frames.push(buf);
    if (frames.length >= 25) {
      clearTimeout(to);
      try { ws.close(); } catch {}
      resolve();
    }
  };
  ws.onerror = () => {};
  ws.onclose = () => { clearTimeout(to); resolve(); };
});

console.log('收到帧数:', frames.length);
let saved = 0;
for (let i = 0; i < frames.length; i++) {
  fs.writeFileSync(`build/dyframes/frame_${String(i).padStart(2, '0')}.bin`, frames[i]);
  saved++;
}
console.log('已保存', saved, '帧到 build/dyframes/');
