// vf_dy_ws_raw.mjs — 抖音弹幕 wss 握手"原始 HTTP 响应"取证
//
// Node 的 WebSocket 只报 "Connection was closed before it was established"，
// 拿不到真实失败原因。本探针用 tls.connect 手工发 Upgrade 请求，直接打印：
//   - 状态行（101 / 400 / 403 / 404 / 444 …）
//   - 全部响应头（尤其 X-TT-System-Error、Web-Server、Server）
//   - 若有 body，前 300 字节
// 对比三种情形：无 signature / 伪 signature / 只连域名不带任何参数（基线）。
// 同时检查 ws 域名 DNS 是否可解析、是否为真实存在的机房。
//
// 运行：node tool/vf_dy_ws_raw.mjs
import tls from 'node:tls';
import net from 'node:net';
import dns from 'node:dns/promises';
import crypto from 'node:crypto';

const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function feed() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)', referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 350 * i));
  }
  return [];
}

/** 手工 TLS + Upgrade，返回 {statusLine, headers, bodyHead, err} */
function rawUpgrade(host, pathWithQuery, { headers = {}, timeoutMs = 12000 } = {}) {
  return new Promise((resolve) => {
    const out = { host, path: pathWithQuery.slice(0, 90) + '…', statusLine: null, headers: {}, bodyHead: '', err: null, bytes: 0 };
    let sock;
    const done = () => { try { sock?.destroy(); } catch {} ; resolve(out); };
    const timer = setTimeout(() => { out.err = out.statusLine ? `已收状态行后 ${timeoutMs}ms 无更多数据` : `超时 ${timeoutMs}ms 未收到任何响应`; done(); }, timeoutMs);
    try {
      sock = tls.connect({ host, port: 443, servername: host, rejectUnauthorized: false }, () => {
        const key = crypto.randomBytes(16).toString('base64');
        const lines = [
          `GET ${pathWithQuery} HTTP/1.1`,
          `Host: ${host}`,
          `Upgrade: websocket`,
          `Connection: Upgrade`,
          `Sec-WebSocket-Key: ${key}`,
          `Sec-WebSocket-Version: 13`,
          `Origin: https://live.douyin.com`,
          `User-Agent: ${headers['ua'] ?? UA_WEB}`,
          ...(headers.cookie ? [`Cookie: ${headers.cookie}`] : []),
          '', '',
        ];
        sock.write(lines.join('\r\n'));
      });
      let acc = Buffer.alloc(0);
      sock.on('data', (d) => {
        acc = Buffer.concat([acc, d]);
        out.bytes = acc.length;
        const sep = acc.indexOf('\r\n\r\n');
        if (out.statusLine === null && sep >= 0) {
          const head = acc.subarray(0, sep).toString('latin1').split(/\r?\n/);
          out.statusLine = head[0];
          for (const l of head.slice(1)) { const i = l.indexOf(':'); if (i > 0) out.headers[l.slice(0, i).trim().toLowerCase()] = l.slice(i + 1).trim(); }
          out.bodyHead = acc.subarray(sep + 4, sep + 4 + 300).toString('latin1').replace(/\s+/g, ' ');
          clearTimeout(timer);
          done();
        } else if (out.statusLine === null && acc.length > 65536) {
          out.err = '响应头超长，异常';
          clearTimeout(timer); done();
        }
      });
      sock.on('error', (e) => { out.err = `${e.code ?? e.name}: ${e.message}`; clearTimeout(timer); done(); });
      sock.on('close', () => { if (!out.statusLine && !out.err) out.err = '连接被对端关闭（未发回任何 HTTP 响应）'; clearTimeout(timer); done(); });
    } catch (e) { out.err = String(e.message); clearTimeout(timer); resolve(out); }
  });
}

function buildPath(roomId, uid, sig) {
  const T = Date.now();
  return '/webcast/im/push/v2/?app_name=douyin_web&version_code=180800&webcast_sdk_version=1.0.14-beta.0' +
    '&update_version_code=1.0.14-beta.0&compress=gzip&device_platform=web&cookie_enabled=true' +
    '&screen_width=1536&screen_height=864&browser_language=zh-CN&browser_platform=Win32' +
    '&browser_name=Mozilla&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20Chrome/126.0.0.0%20Safari/537.36' +
    '&browser_online=true&tz_name=Asia/Shanghai' +
    `&cursor=d-1_u-1_t-${T}_r-1` +
    `&internal_ext=internal_src:dim|wss_push_room_id:${roomId}|wss_push_did:${uid}|first_req_ms:${T}|fetch_time:${T}|seq:1|wss_info:0-${T}-0-0` +
    '&host=https://live.douyin.com&aid=6383&live_id=1&did_rule=3&endpoint=live_pc&support_wrds=1' +
    `&user_unique_id=${uid}&im_path=/webcast/im/fetch/&identity=audience&need_persist_msg_count=15` +
    `&room_id=${roomId}&heartbeatDuration=0` + (sig ? `&signature=${sig}` : '');
}
const show = (r) => {
  console.log(`  ${r.host}`);
  console.log(`    路径: ${r.path}`);
  console.log(`    状态行: ${r.statusLine ?? '(无)'}`);
  const interesting = Object.entries(r.headers).filter(([k]) =>
    /x-tt|error|server|web-server|upgrade|sec-websocket|location|content-type|x-border|via|timing/i.test(k));
  for (const [k, v] of interesting) console.log(`    < ${k}: ${v.slice(0, 90)}`);
  if (r.bodyHead) console.log(`    body(前300B): ${JSON.stringify(r.bodyHead.slice(0, 200))}`);
  if (r.err) console.log(`    err: ${r.err}`);
  console.log(`    收到字节: ${r.bytes}`);
};

console.log('=== vf_dy_ws_raw: 弹幕 wss 握手原始响应取证 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const roomId = rooms[0].id_str;
const uid = String(7000000000000000000 + Math.floor(Math.random() * 999999999999));
console.log(`房间=${roomId}\n`);

console.log('── DNS 解析检查 ──');
for (const h of ['webcast100-ws-web-lq.douyin.com', 'webcast100-ws-web-al.douyin.com',
  'webcast5-ws-web-lf.douyin.com', 'webcast.polaris.ttw81.cn', 'live.douyin.com']) {
  try { const a = await dns.resolve4(h); console.log(`  ${h} → ${a.slice(0, 3).join(', ')}`); }
  catch (e) { console.log(`  ${h} → 解析失败 (${e.code ?? e.message})`); }
}

console.log('\n── A. 真实房间 + 无 signature ──');
show(await rawUpgrade('webcast100-ws-web-lq.douyin.com', buildPath(roomId, uid, null)));

console.log('\n── B. 真实房间 + 伪 signature（32 位）──');
show(await rawUpgrade('webcast100-ws-web-lq.douyin.com', buildPath(roomId, uid, 'a'.repeat(32))));

console.log('\n── C. 基线：只连 push/v2 路径不带任何 query ──');
show(await rawUpgrade('webcast100-ws-web-lq.douyin.com', '/webcast/im/push/v2/'));

console.log('\n── D. 其它 ws 机房 + 无 signature ──');
for (const h of ['webcast100-ws-web-al.douyin.com', 'webcast5-ws-web-lf.douyin.com']) {
  try { show(await rawUpgrade(h, buildPath(roomId, uid, null), { timeoutMs: 9000 })); } catch (e) { console.log(`  ${h} ERR ${e.message}`); }
}

console.log('\n── E. live.douyin.com 上的同名路径（web 域代理）──');
show(await rawUpgrade('live.douyin.com', buildPath(roomId, uid, null).replace('/webcast/im/push/v2/', '/webcast/im/push/'), { timeoutMs: 9000 }));

console.log('\n── F. 纯 HTTPS GET（非 Upgrade）同样参数，看是否返回业务错误码 ──');
{
  const u = `https://webcast100-ws-web-lq.douyin.com${buildPath(roomId, uid, null)}`;
  try {
    const r = await fetch(u, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
    const b = Buffer.from(await r.arrayBuffer());
    console.log(`  HTTP=${r.status} len=${b.length} ct=${r.headers.get('content-type')}`);
    console.log(`  headers: ${JSON.stringify(Object.fromEntries([...r.headers.entries()].filter(([k]) => /x-tt|server|error/i.test(k))))}`);
    console.log(`  body: ${JSON.stringify(b.subarray(0, 200).toString('latin1').replace(/\s+/g, ' '))}`);
  } catch (e) { console.log(`  ERR ${e.name}: ${e.message}`); }
}
