// 抖音直播弹幕：解 protobuf 提取真实弹幕文本。
//
// 上一步确认：ws 握手 101，收到 13 帧 / 18091 字节。
// 首帧 hex: 0801 10f7d392f5ccfacebb7a 18b845 2008 2a15 0a0d 636f6d70726573735f7479...
//
// 这是 PushFrame 结构：
//   field 1 (varint) seq
//   field 2 (varint) log_id
//   field 3 (varint) service
//   field 4 (varint) method
//   field 5 (bytes)  payload_type  ("compress_type")
//   field 6 (bytes)  payload       (gzip 压缩的 Response protobuf)
//   field 7 (bytes)  headers
//
// Response 里 field 1 是 messages 数组，每条是 Message：
//   field 1 method ("WebcastChatMessage" 等)
//   field 2 payload (gzip 压缩的 ChatMessage)
//
// 本脚本用最小 protobuf 解析器走这条链，提取弹幕文本。

import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';
import zlib from 'node:zlib';

const SIGN_JS = fs.readFileSync('build/dyref/sign.js', 'utf8');
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

// ---------- 最小 protobuf 解析 ----------
function readVarint(buf, pos) {
  let result = 0n;
  let shift = 0n;
  while (pos < buf.length) {
    const b = buf[pos++];
    result |= BigInt(b & 0x7f) << shift;
    if ((b & 0x80) === 0) return { v: result, pos };
    shift += 7n;
    if (shift > 63n) break;
  }
  return { v: null, pos };
}

/** 把 protobuf 解析成 { field: [values] }，length-delimited 给 Buffer。 */
function parseProto(buf) {
  const out = {};
  let pos = 0;
  while (pos < buf.length) {
    const t = readVarint(buf, pos);
    if (t.v === null) break;
    pos = t.pos;
    const tag = Number(t.v);
    const field = tag >> 3;
    const wire = tag & 7;
    if (field === 0) break;

    if (wire === 0) {
      const v = readVarint(buf, pos);
      if (v.v === null) break;
      pos = v.pos;
      (out[field] ||= []).push(v.v);
    } else if (wire === 2) {
      const l = readVarint(buf, pos);
      if (l.v === null) break;
      pos = l.pos;
      const len = Number(l.v);
      if (pos + len > buf.length) break;
      (out[field] ||= []).push(buf.subarray(pos, pos + len));
      pos += len;
    } else if (wire === 5) {
      if (pos + 4 > buf.length) break;
      pos += 4;
    } else if (wire === 1) {
      if (pos + 8 > buf.length) break;
      pos += 8;
    } else {
      break;
    }
  }
  return out;
}

function maybeGunzip(buf) {
  if (buf && buf.length > 2 && buf[0] === 0x1f && buf[1] === 0x8b) {
    try {
      return zlib.gunzipSync(buf);
    } catch {
      return buf;
    }
  }
  return buf;
}

// ---------- 取房间 ----------
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
const room = feed.data.map((e) => e.data).filter(Boolean)[0];
const roomId = room.id_str;
console.log('room =', roomId, '|', (room.title || '').slice(0, 30));
console.log('');

// ---------- signature ----------
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
  .update(ORDER.map((k) => `${k}=${maps[k] ?? ''}`).join(','), 'utf8')
  .digest('hex');

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
console.log('signature =', signature, '| ttwid =', ttwid ? 'ok' : 'none');
console.log('');
console.log('=== 接收并解析弹幕（20 秒）===');

const chats = [];
let frameCount = 0;
let methodStats = {};

await new Promise((resolve) => {
  const to = setTimeout(() => { try { ws.close(); } catch {} resolve(); }, 20000);
  const ws = new WebSocket(`${wssBase}&signature=${signature}`, {
    headers: {
      'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      ...(ttwid ? { cookie: `ttwid=${ttwid}` } : {}),
    },
  });

  ws.onopen = () => console.log('  WS 101 OK');

  ws.onmessage = async (ev) => {
    frameCount++;
    let buf;
    if (typeof ev.data === 'string') buf = Buffer.from(ev.data, 'binary');
    else if (ev.data instanceof Blob) buf = Buffer.from(await ev.data.arrayBuffer());
    else buf = Buffer.from(ev.data);

    // PushFrame
    const frame = parseProto(buf);
    // 按 douyin.proto：PushFrame.payload 是 field 8
    // （field 6 是 payloadEncoding，field 7 是 payloadType）
    const payload = frame[8]?.[0];
    if (!payload) return;

    const respBuf = maybeGunzip(payload);
    const resp = parseProto(respBuf);
    // field 1 = messages 数组
    const msgs = resp[1] || [];
    for (const m of msgs) {
      const msg = parseProto(m);
      const method = msg[1]?.[0]?.toString('utf8') ?? '';
      methodStats[method] = (methodStats[method] ?? 0) + 1;

      if (method === 'WebcastChatMessage') {
        const inner = maybeGunzip(msg[2]?.[0]);
        if (!inner) continue;
        const chat = parseProto(inner);
        // 按 douyin.proto：
        //   ChatMessage.user = 2, ChatMessage.content = 3
        //   User.nickName = 3
        const contentBuf = chat[3]?.[0];
        if (!contentBuf) continue;
        const text = contentBuf.toString('utf8');
        let nick = '';
        const userBuf = chat[2]?.[0];
        if (userBuf) {
          const u = parseProto(userBuf);
          nick = u[3]?.[0]?.toString('utf8') ?? '';
        }
        chats.push({ nick, text });
      }
    }

    if (frameCount >= 30) {
      clearTimeout(to);
      try { ws.close(); } catch {}
      resolve();
    }
  };
  ws.onerror = () => {};
  ws.onclose = (e) => { clearTimeout(to); resolve(); };
});

console.log('');
console.log('  收到帧数:', frameCount);
console.log('  消息类型分布:', JSON.stringify(methodStats));
console.log('  解析出的弹幕数:', chats.length);
console.log('');
if (chats.length) {
  console.log('=== 真实弹幕（前 20 条）===');
  for (const c of chats.slice(0, 20)) {
    console.log(`  ${c.nick || '(无昵称)'}: ${c.text}`);
  }
  console.log('');
  console.log('结论：**成功解析出真实弹幕文本** → 抖音弹幕完全可实现');
} else if (Object.keys(methodStats).length) {
  console.log('结论：收到消息但没解出弹幕，可能字段号不对');
} else {
  console.log('结论：没收到可解析的消息');
}
