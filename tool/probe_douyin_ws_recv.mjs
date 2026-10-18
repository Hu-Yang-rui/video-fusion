// 抖音直播弹幕：握手成功后能否真正收到消息？
//
// 上一步已确认 signature 有效、ws 返回 101。
// 但握手成功 ≠ 能收到弹幕。抖音的 ws 是 protobuf 帧，
// 需要：
//   1. 连上后发一帧 ack / 或等服务端推
//   2. 解 protobuf 帧，取 WebcastChatMessage
//
// 本脚本验证第 1 步：连上后能收到多少字节、帧结构长什么样。
// 如果收到真实帧，说明弹幕数据流是通的。

import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';
import zlib from 'node:zlib';

const SIGN_JS = fs.readFileSync('build/dyref/sign.js', 'utf8');

// ---------- 取一个真实在播房间 ----------
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
      {
        headers: {
          'user-agent': UA_APP,
          referer: 'https://live.douyin.com/',
        },
      }
    );
    const t = await r.text();
    if (t.trim()) return JSON.parse(t);
    await new Promise((s) => setTimeout(s, 400 * (i + 1)));
  }
  return null;
}

const feed = await feedOnce();
if (!feed) {
  console.log('feed 空，终止');
  process.exit(1);
}
const rooms = feed.data.map((e) => e.data).filter(Boolean);
const room = rooms[0];
const roomId = room.id_str;
console.log('room =', roomId, '|', (room.title || '').slice(0, 30));
console.log('');

// ---------- signature ----------
const USER_UNIQUE_ID = '7319483754668557238';
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
  `&internal_ext=internal_src:dim|wss_push_room_id:${roomId}|wss_push_did:${USER_UNIQUE_ID}` +
  `|first_req_ms:${T}|fetch_time:${T}|seq:1|wss_info:0-${T}-0-0|` +
  'wrds_v:7392094459690748497' +
  `&host=https://live.douyin.com&aid=6383&live_id=1&did_rule=3&endpoint=live_pc&support_wrds=1` +
  `&user_unique_id=${USER_UNIQUE_ID}&im_path=/webcast/im/fetch/&identity=audience` +
  '&need_persist_msg_count=15&insert_task_id=&live_reason=' +
  `&room_id=${roomId}&heartbeatDuration=0`;

const PARAM_ORDER = [
  'live_id', 'aid', 'version_code', 'webcast_sdk_version',
  'room_id', 'sub_room_id', 'sub_channel_id', 'did_rule',
  'user_unique_id', 'device_platform', 'device_type', 'ac', 'identity',
];
const q = wssBase.split('?')[1];
const maps = {};
for (const kv of q.split('&')) {
  const i = kv.indexOf('=');
  if (i > 0) maps[kv.slice(0, i)] = kv.slice(i + 1);
}
const tpl = PARAM_ORDER.map((k) => `${k}=${maps[k] ?? ''}`).join(',');
const md5Param = crypto.createHash('md5').update(tpl, 'utf8').digest('hex');

const sandbox = {
  console, setTimeout, clearTimeout, setInterval, clearInterval,
  Math, Date, JSON, parseInt, parseFloat, isNaN,
  encodeURIComponent, decodeURIComponent, escape, unescape,
  String, Number, Boolean, Array, Object, RegExp, Error,
  atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.document = {
  createElement: () => ({ style: {}, setAttribute: () => {}, appendChild: () => {}, getContext: () => null }),
  documentElement: { style: {} },
  getElementsByTagName: () => [],
  addEventListener: () => {},
  cookie: '',
};
sandbox.navigator = {
  userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  platform: 'Win32', language: 'zh-CN', languages: ['zh-CN', 'zh'],
  cookieEnabled: true, webdriver: false,
  plugins: { length: 5 }, mimeTypes: { length: 2 },
};
sandbox.location = { href: 'https://live.douyin.com/', protocol: 'https:', host: 'live.douyin.com', hostname: 'live.douyin.com', pathname: '/', search: '', hash: '' };
sandbox.screen = { width: 1536, height: 864, availWidth: 1536, availHeight: 864 };
sandbox.localStorage = { _d: {}, getItem(k) { return this._d[k] ?? null; }, setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; } };
sandbox.sessionStorage = sandbox.localStorage;
sandbox.performance = { now: () => Date.now(), timeOrigin: Date.now() };
sandbox.crypto = { getRandomValues: (a) => crypto.randomFillSync(a) };
sandbox.addEventListener = () => {};
sandbox.removeEventListener = () => {};

const ctx = vm.createContext(sandbox);
vm.runInContext(SIGN_JS, ctx, { timeout: 20000 });
const signature = ctx.get_sign(md5Param);
console.log('signature =', signature);

// ---------- ttwid ----------
async function getTtwid() {
  const r = await fetch('https://ttwid.bytedance.com/ttwid/union/register/', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      region: 'cn', aid: 1768, needFid: false, service: 'www.ixigua.com',
      migrate_info: { ticket: '', source: 'node' },
      cbUrlProtocol: 'https', union: true,
    }),
  });
  const sc = r.headers.get('set-cookie') || '';
  const m = sc.match(/ttwid=([^;]+)/);
  return m ? m[1] : null;
}
const ttwid = await getTtwid();
console.log('ttwid =', ttwid ? ttwid.slice(0, 30) + '...' : '(none)');
console.log('');

// ---------- 连上并收帧 ----------
console.log('=== 连接并接收消息（15 秒）===');
const url = `${wssBase}&signature=${signature}`;

const stats = {
  opened: false,
  frames: 0,
  totalBytes: 0,
  firstFrameHex: '',
  decodedTexts: [],
};

await new Promise((resolve) => {
  const to = setTimeout(() => {
    try { ws.close(); } catch {}
    resolve();
  }, 15000);

  const ws = new WebSocket(url, {
    headers: {
      'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      ...(ttwid ? { cookie: `ttwid=${ttwid}` } : {}),
    },
  });

  ws.onopen = () => {
    stats.opened = true;
    console.log('  WS 已连接 (101)');
  };

  ws.onmessage = async (ev) => {
    stats.frames++;
    let buf;
    if (typeof ev.data === 'string') {
      buf = Buffer.from(ev.data, 'binary');
    } else if (ev.data instanceof Blob) {
      buf = Buffer.from(await ev.data.arrayBuffer());
    } else if (ev.data instanceof ArrayBuffer) {
      buf = Buffer.from(ev.data);
    } else {
      buf = Buffer.from(ev.data);
    }
    stats.totalBytes += buf.length;
    if (stats.frames === 1) {
      stats.firstFrameHex = buf.subarray(0, 32).toString('hex');
      console.log(`  首帧 ${buf.length}B, hex=${stats.firstFrameHex}`);
    }
    // 抖音帧：8 字节头（type + seq + len...）具体格式见 push_frame
    // 先尝试从帧里提取可读中文，判断是否含弹幕文本
    try {
      // 可能是 gzip 压缩的 protobuf
      const maybeGzip = buf.subarray(8);
      let plain = maybeGzip;
      if (maybeGzip[0] === 0x1f && maybeGzip[1] === 0x8b) {
        plain = zlib.gunzipSync(maybeGzip);
      }
      const text = plain.toString('utf8');
      const cn = text.match(/[\u4e00-\u9fa5]{2,}/g);
      if (cn && cn.length) {
        for (const s of cn.slice(0, 3)) stats.decodedTexts.push(s);
      }
    } catch {
      // ignore
    }
    if (stats.frames >= 8) {
      clearTimeout(to);
      try { ws.close(); } catch {}
      resolve();
    }
  };

  ws.onerror = () => {
    console.log('  ws error');
  };
  ws.onclose = (e) => {
    clearTimeout(to);
    console.log('  ws closed code=' + e.code);
    resolve();
  };
});

console.log('');
console.log('=== 统计 ===');
console.log('  握手成功:', stats.opened);
console.log('  收到帧数:', stats.frames);
console.log('  总字节:', stats.totalBytes);
if (stats.decodedTexts.length) {
  console.log('  解出的中文片段:', [...new Set(stats.decodedTexts)].slice(0, 10).join(' | '));
}
console.log('');
if (stats.frames > 0) {
  console.log('结论：**能收到真实数据帧** → 弹幕数据流是通的，只需解 protobuf');
} else if (stats.opened) {
  console.log('结论：握手成功但没收到帧，可能需要发 ack 或心跳');
} else {
  console.log('结论：握手失败');
}
