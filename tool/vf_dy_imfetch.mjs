// vf_dy_imfetch.mjs — 弹幕链路最后两条兜底路径实测（严格只读）
//
// 已坐实：无 signature 时 wss 升级失败（拿到 HTTP/1.1 200 而非 101）。
// 本探针只验证两条"不需要执行平台风控 JS"的替代可能，全部 GET：
//   A) /webcast/im/fetch/ —— 项目 wss URL 里的 im_path 就是这个值，
//      带 need_persist_msg_count 说明存在"拉取历史消息"的 HTTP 对等接口
//   B) ws:// (明文 80 端口) 升级 —— 排除"只是 TLS 层被掐"的可能
//   C) 完整读取 wss 升级响应的 body（之前只取到状态行就断了）
//   D) 换机房域名（lq/lf/al/…）与换 webcast_sdk_version 组合
//   E) App 形态（aid=1128）的 ws 域名是否存在
//
// 运行：node tool/vf_dy_imfetch.mjs
import tls from 'node:tls';
import net from 'node:net';
import dns from 'node:dns/promises';
import crypto from 'node:crypto';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';

async function feed() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 350 * i));
  }
  return [];
}

/** 完整读一次 HTTP 响应（含 body），支持 tls 或明文 net */
function rawRequest(host, port, reqLines, { tlsMode = true, ms = 10000 } = {}) {
  return new Promise((resolve) => {
    const out = { host, port, statusLine: null, headers: {}, body: '', bodyLen: 0, err: null, hex: '' };
    const mk = () => tlsMode ? tls.connect({ host, port, servername: host, rejectUnauthorized: false }) : net.connect({ host, port });
    let sock;
    const finish = () => { try { sock?.destroy(); } catch {} ; resolve(out); };
    const timer = setTimeout(finish, ms);
    let acc = Buffer.alloc(0);
    try {
      sock = mk();
      sock.on('connect', () => sock.write(reqLines.join('\r\n')));
      sock.on('secureConnect', () => sock.write(reqLines.join('\r\n')));
      sock.on('data', (d) => {
        acc = Buffer.concat([acc, d]);
        const sep = acc.indexOf('\r\n\r\n');
        if (sep >= 0) {
          const head = acc.subarray(0, sep).toString('latin1').split(/\r?\n/);
          if (!out.statusLine) {
            out.statusLine = head[0];
            for (const l of head.slice(1)) { const i = l.indexOf(':'); if (i > 0) out.headers[l.slice(0, i).trim().toLowerCase()] = l.slice(i + 1).trim(); }
            out.hex = acc.subarray(0, Math.min(48, acc.length)).toString('hex').match(/.{2}/gu).join(' ');
          }
          const rest = acc.subarray(sep + 4);
          const cl = Number(out.headers['content-length'] ?? -1);
          if (cl >= 0 ? rest.length >= cl : rest.length > 0) {
            out.body = rest.subarray(0, 400).toString('latin1').replace(/\s+/g, ' ');
            out.bodyLen = rest.length;
            clearTimeout(timer); finish();
          }
        }
      });
      sock.on('error', (e) => { out.err = `${e.code ?? e.name}: ${e.message}`; clearTimeout(timer); finish(); });
      sock.on('close', () => { clearTimeout(timer); finish(); });
    } catch (e) { out.err = String(e.message); clearTimeout(timer); resolve(out); }
  });
}
const show = (r) => {
  console.log(`  ${r.host}:${r.port} → ${r.statusLine ?? '(无状态行)'}${r.err ? ' err=' + r.err : ''}`);
  const h = Object.entries(r.headers).filter(([k]) => /upgrade|sec-websocket|server|content-type|content-length|x-tt-system|x-tt-logid|location/i.test(k));
  for (const [k, v] of h) console.log(`      < ${k}: ${v.slice(0, 70)}`);
  if (r.body) console.log(`      body(${r.bodyLen}B)=${JSON.stringify(r.body.slice(0, 200))}`);
  if (r.hex) console.log(`      raw hex=${r.hex}`);
};

console.log('=== vf_dy_imfetch: 弹幕兜底路径实测（只读）===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const rid = rooms[0].id_str;
const uid = String(7000000000000000000 + Math.floor(Math.random() * 999999999999));
const T = Date.now();
console.log(`房间=${rid}  假 user_unique_id=${uid.slice(0, 4)}…\n`);

console.log('── A) /webcast/im/fetch/ HTTP 对等接口（匿名 GET）──');
for (const [host, q] of [['webcast.amemv.com', WEBQ], ['live.douyin.com', WEBQ], ['webcast.amemv.com', APPQ]]) {
  const u = `https://${host}/webcast/im/fetch/?${q}&room_id=${rid}&need_persist_msg_count=15&identity=audience&endpoint=live_pc`;
  try {
    const r = await fetch(u, { headers: { 'user-agent': host === 'live.douyin.com' ? UA_WEB : UA_APP, referer: 'https://live.douyin.com/' } });
    const b = Buffer.from(await r.arrayBuffer());
    let j = null; try { j = JSON.parse(b.toString('utf8')); } catch {}
    console.log(`  ${host} im/fetch HTTP=${r.status} len=${b.length}` +
      (j ? ` status_code=${j.status_code}${j.status_msg ? ' msg=' + JSON.stringify(j.status_msg) : ''} keys=[${Object.keys(j).join(',')}]` :
        ` head=${JSON.stringify(b.subarray(0, 60).toString('latin1').replace(/\s+/g, ' '))}`));
  } catch (e) { console.log(`  ${host} im/fetch ERR ${e.name}`); }
}

console.log('\n── B) ws:// 明文 80 端口升级（排除 TLS 层被掐）──');
const wsPath = `/webcast/im/push/v2/?app_name=douyin_web&version_code=180800&webcast_sdk_version=1.0.14-beta.0` +
  `&compress=gzip&device_platform=web&aid=6383&live_id=1&room_id=${rid}&user_unique_id=${uid}&identity=audience&endpoint=live_pc&support_wrds=1&im_path=/webcast/im/fetch/` +
  `&internal_ext=internal_src:dim|wss_push_room_id:${rid}|wss_push_did:${uid}|fetch_time:${T}|seq:1`;
show(await rawRequest('webcast100-ws-web-lq.douyin.com', 80, [
  `GET ${wsPath} HTTP/1.1`, 'Host: webcast100-ws-web-lq.douyin.com', 'Upgrade: websocket', 'Connection: Upgrade',
  `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}`, 'Sec-WebSocket-Version: 13',
  'Origin: https://live.douyin.com', `User-Agent: ${UA_WEB}`, '', '',
], { tlsMode: false, ms: 9000 }));

console.log('\n── C) wss 升级响应完整读取（无 signature）──');
show(await rawRequest('webcast100-ws-web-lq.douyin.com', 443, [
  `GET ${wsPath} HTTP/1.1`, 'Host: webcast100-ws-web-lq.douyin.com', 'Upgrade: websocket', 'Connection: Upgrade',
  `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}`, 'Sec-WebSocket-Version: 13',
  'Origin: https://live.douyin.com', `User-Agent: ${UA_WEB}`, '', '',
], { tlsMode: true, ms: 12000 }));

console.log('\n── C2) 带伪 signature 的完整读取（对比 body 是否不同）──');
show(await rawRequest('webcast100-ws-web-lq.douyin.com', 443, [
  `GET ${wsPath}&signature=${'b'.repeat(32)} HTTP/1.1`, 'Host: webcast100-ws-web-lq.douyin.com',
  'Upgrade: websocket', 'Connection: Upgrade',
  `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}`, 'Sec-WebSocket-Version: 13',
  'Origin: https://live.douyin.com', `User-Agent: ${UA_WEB}`, '', '',
], { tlsMode: true, ms: 12000 }));

console.log('\n── D) 机房域名枚举（DNS + 一次升级）──');
const hosts = ['webcast100-ws-web-lq.douyin.com', 'webcast100-ws-web-lf.douyin.com', 'webcast100-ws-web-al.douyin.com',
  'webcast100-ws-web-lax.douyin.com', 'webcast5-ws-web-lf.douyin.com', 'webcast5-ws-web-lq.douyin.com',
  'webcast1-ws-web-lf.douyin.com', 'ws-web-c1.douyin.com', 'webcast-ws.douyin.com'];
for (const h of hosts) {
  let ip = null;
  try { ip = (await dns.resolve4(h)).slice(0, 2).join(','); } catch (e) { ip = `解析失败(${e.code})`; }
  console.log(`  ${h.padEnd(38)} ${ip}`);
}

console.log('\n── E) 老 push 路径 /webcast/im/push/（v1，无 v2）──');
show(await rawRequest('webcast100-ws-web-lq.douyin.com', 443, [
  `GET /webcast/im/push/?app_name=douyin_web&aid=6383&version_code=180800&device_platform=web&compress=gzip&room_id=${rid}&user_unique_id=${uid} HTTP/1.1`,
  'Host: webcast100-ws-web-lq.douyin.com', 'Upgrade: websocket', 'Connection: Upgrade',
  `Sec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}`, 'Sec-WebSocket-Version: 13',
  'Origin: https://live.douyin.com', `User-Agent: ${UA_WEB}`, '', '',
], { tlsMode: true, ms: 9000 }));

console.log('\n── F) 项目内既有解析层的输入从哪来：确认 signature 是否有 HTTP 换取接口 ──');
for (const p of ['webcast/sign/', 'webcast/im/sign/', 'webcast/push/sign/', 'webcast/room/push_sign/', 'webcast/sign/get/']) {
  try {
    const r = await fetch(`https://webcast.amemv.com/${p}?${WEBQ}&room_id=${rid}`, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    let j = null; try { j = JSON.parse(t); } catch {}
    console.log(`  ${p.padEnd(28)} HTTP=${r.status} len=${t.length}` +
      (j ? ` status_code=${j.status_code}${j.status_msg ? ' msg=' + JSON.stringify(j.status_msg) : ''}` : ` head=${JSON.stringify(t.slice(0, 40))}`));
  } catch (e) { console.log(`  ${p} ERR ${e.name}`); }
}
