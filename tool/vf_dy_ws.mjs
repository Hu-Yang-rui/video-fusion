// vf_dy_ws.mjs — 抖音直播弹幕"现在到底能不能收到"完整实测
//
// 项目现状：danmaku_client.dart 只接受"已带 signature 的完整 wss URL"，
// 不内置也不计算 signature（sign.js 不在仓库里，实测 build/dyref 不存在）。
// 因此 App 侧真实能力取决于：**不带 signature 能否握手并收到帧**。
//
// 本探针分三层，逐层给出真实证据，绝不用模拟数据：
//   L1  直接连 wss（无 signature，无 cookie）→ 看 HTTP 握手是否 101、有无帧
//   L2  先取 ttwid（ttwid.bytedance.com），再连（无 signature）→ 看是否改善
//   L3  用 /webcast/room/web/enter/ 或 live.douyin.com SSR 拿真实 ws 参数
//       （room 的 im 前缀、user_unique_id、web_rid），再连
//   L4  若三层都收不到帧：用项目内已实现的 protobuf 解帧逻辑（对齐
//       danmaku_codec.dart 的 PushFrame 字段）解任何收到的字节，证明"有帧就能解"
//   L5  兜底证明"签名是唯一缺环"：若本机/仓库存在任何 sign.js，尝试生成 signature
//       并连接；不存在则如实报告缺失。
//
// 运行：node tool/vf_dy_ws.mjs --secs=20
import fs from 'node:fs';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/126.0.0.0 Safari/537.36';
const APPQ =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

const argv = process.argv.slice(2);
const numArg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? Number(a.split('=')[1]) : d; };
const SECS = numArg('secs', 20);

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

// ── PushFrame 解帧（与 lib/src/adapters/douyin/danmaku_codec.dart 字段一致）──
// PushFrame: 1=seqId(u64) 2=logId(u64) 3=binaryData(bytes) 4=encoding(44)
//            5=numMessages 7=payloadType 8=payload 9=method?
const MSG_NAMES = {
  WebcastChatMessage: '弹幕', WebcastMemberMessage: '进场', WebcastLikeMessage: '点赞',
  WebcastGiftMessage: '礼物', WebcastRoomUserSeqMessage: '在线人数',
  WebcastSocialMessage: '关注', WebcastRoomStatsMessage: '房间统计',
  WebcastControlMessage: '控制(下播)', WebcastRoomFanboxInfoMessage: '粉丝团',
};
function varint(buf, pos) {
  let v = 0n, shift = 0n, i = pos;
  while (i < buf.length) { const b = buf[i++]; v |= BigInt(b & 0x7f) << shift; if (!(b & 0x80)) break; shift += 7n; if (shift > 64n) return null; }
  return { v, i };
}
function walk(buf, cb, maxDepth = 3, depth = 0) {
  let p = 0;
  while (p < buf.length) {
    const h = varint(buf, p); if (!h) break; p = h.i;
    const field = Number(h.v >> 3n), wire = Number(h.v & 7n);
    try {
      if (wire === 0) { const x = varint(buf, p); if (!x) break; p = x.i; cb(field, 'varint', x.v, depth); }
      else if (wire === 1) { if (p + 8 > buf.length) break; cb(field, 'f64', buf.readBigUInt64LE(p), depth); p += 8; }
      else if (wire === 2) {
        const x = varint(buf, p); if (!x) break; p = x.i;
        const len = Number(x.v); if (p + len > buf.length) break;
        const sub = buf.subarray(p, p + len); p += len;
        cb(field, 'bytes', sub, depth);
        if (depth < maxDepth && sub.length > 0 && sub.length < 20000) walk(sub, cb, maxDepth, depth + 1);
      } else if (wire === 5) { if (p + 4 > buf.length) break; p += 4; }
      else break;
    } catch { break; }
  }
}
function decodeFrame(buf) {
  const out = { seqId: null, logId: null, payloadType: null, encoding: null, numMessages: null, binary: null, totalLen: buf.length };
  let p = 0;
  while (p < buf.length) {
    const h = varint(buf, p); if (!h) break; p = h.i;
    const field = Number(h.v >> 3n), wire = Number(h.v & 7n);
    if (wire === 0) { const x = varint(buf, p); if (!x) break; p = x.i; if (field === 5) out.numMessages = Number(x.v); }
    else if (wire === 1) { if (p + 8 > buf.length) break; if (field === 1) out.seqId = x8(buf, p); if (field === 2) out.logId = x8(buf, p); p += 8; }
    else if (wire === 2) {
      const x = varint(buf, p); if (!x) break; p = x.i;
      const len = Number(x.v); if (p + len > buf.length) break;
      const sub = buf.subarray(p, p + len); p += len;
      if (field === 3) out.binary = sub;
      if (field === 7) out.payloadType = sub.toString('utf8');
      if (field === 8) out.payload = sub.toString('utf8');
      if (field === 4) out.encoding = sub.toString('utf8');
    } else break;
  }
  return out;
}
const x8 = (b, o) => (o + 8 <= b.length ? b.readBigUInt64LE(o) : null);

/** Messages 容器 → 每条 message 的 type 名与文本 */
function decodeMessages(binary) {
  let body = binary;
  if (body?.length >= 2 && body[0] === 0x1f && body[1] === 0x8b) {
    try { body = zlib.gunzipSync(body); } catch { /* keep */ }
  }
  if (!body?.length) return { messages: [], perType: {}, gzip: binary?.length !== body?.length };
  const messages = [];
  let p = 0;
  while (p < body.length) {
    const h = varint(body, p); if (!h) break; p = h.i;
    const field = Number(h.v >> 3n), wire = Number(h.v & 7n);
    if (wire !== 2) { if (wire === 0) { const x = varint(body, p); if (!x) break; p = x.i; } else if (wire === 1) p += 8; else if (wire === 5) p += 4; else break; continue; }
    const x = varint(body, p); if (!x) break; p = x.i;
    const len = Number(x.v); if (p + len > body.length) break;
    const sub = body.subarray(p, p + len); p += len;
    if (field === 1) messages.push(sub); // Message
  }
  const perType = {};
  const decoded = [];
  for (const m of messages) {
    let type = null, payload = null;
    walk(m, (f, wt, v) => {
      if (wt === 'bytes' && f === 1 && type === null) { try { type = v.toString('utf8'); } catch {} }
      if (wt === 'bytes' && f === 2 && payload === null) payload = v;
    }, 0);
    perType[type ?? '(null)'] = (perType[type ?? '(null)'] ?? 0) + 1;
    if (payload && type === 'WebcastChatMessage') {
      let text = null, nick = null;
      walk(payload, (f, wt, v, d) => {
        if (d > 2) return;
        if (wt === 'bytes') {
          const s = (() => { try { return v.toString('utf8'); } catch { return null; } })();
          if (f === 3 && s && !text) text = s;
          if (f === 20 && s && !nick) nick = s; // 常见 nickname 字段位
        }
      }, 3);
      if (text) decoded.push({ type, text: text.slice(0, 60), nick });
    } else if (payload && type === 'WebcastRoomUserSeqMessage') {
      let n = null;
      walk(payload, (f, wt, v, d) => { if (d === 0 && wt === 'varint' && f === 3) n = Number(v); }, 1);
      decoded.push({ type, text: `online=${n}` });
    } else {
      decoded.push({ type, text: '(未解文本)' });
    }
  }
  return { messages: decoded, perType, count: messages.length, gzip: binary?.length !== body?.length };
}

// ── 真实 ws 参数：走 live.douyin.com SSR / enter 接口 ───────────
async function getTtwid() {
  try {
    const r = await fetch('https://ttwid.bytedance.com/ttwid/union/register/', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ region: 'cn', aid: 1768, needFid: false, service: 'www.ixigua.com', migrate_info: { ticket: '', source: 'node' }, cbUrlProtocol: 'https', union: true }),
    });
    const sc = r.headers.get('set-cookie') ?? '';
    const m = sc.match(/ttwid=([^;]+)/);
    return m ? m[1] : null;
  } catch (e) { return null; }
}
function buildWss(roomId, uid, { withSig = null, withCursor = true } = {}) {
  const T = Date.now();
  return 'wss://webcast100-ws-web-lq.douyin.com/webcast/im/push/v2/' +
    '?app_name=douyin_web&version_code=180800&webcast_sdk_version=1.0.14-beta.0' +
    '&update_version_code=1.0.14-beta.0&compress=gzip&device_platform=web&cookie_enabled=true' +
    '&screen_width=1536&screen_height=864&browser_language=zh-CN&browser_platform=Win32' +
    '&browser_name=Mozilla&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20Chrome/126.0.0.0%20Safari/537.36' +
    '&browser_online=true&tz_name=Asia/Shanghai' +
    (withCursor ? `&cursor=d-1_u-1_t-${T}_r-1` : '') +
    `&internal_ext=internal_src:dim|wss_push_room_id:${roomId}|wss_push_did:${uid}|first_req_ms:${T}|fetch_time:${T}|seq:1|wss_info:0-${T}-0-0` +
    '&host=https://live.douyin.com&aid=6383&live_id=1&did_rule=3&endpoint=live_pc&support_wrds=1' +
    `&user_unique_id=${uid}&im_path=/webcast/im/fetch/&identity=audience&need_persist_msg_count=15` +
    `&room_id=${roomId}&heartbeatDuration=0` + (withSig ? `&signature=${withSig}` : '');
}

const PARAM_ORDER = ['live_id', 'aid', 'version_code', 'webcast_sdk_version', 'room_id',
  'sub_room_id', 'sub_channel_id', 'did_rule', 'user_unique_id', 'device_platform',
  'device_type', 'ac', 'identity'];
function md5Tpl(url) {
  const q = url.split('?')[1] ?? '';
  const maps = {};
  for (const kv of q.split('&')) { const i = kv.indexOf('='); if (i > 0) maps[kv.slice(0, i)] = kv.slice(i + 1); }
  return crypto.createHash('md5').update(PARAM_ORDER.map((k) => `${k}=${maps[k] ?? ''}`).join(',')).digest('hex');
}

function tryConnect(label, url, { cookie, secs }) {
  return new Promise((resolve) => {
    const st = { label, url: url.slice(0, 120) + '…', opened: false, closeCode: null, closeReason: '',
      error: null, frames: 0, bytes: 0, firstHex: '', decoded: [], perType: {}, ackSent: 0 };
    let ws;
    try { ws = new WebSocket(url, { headers: { 'user-agent': UA_WEB, ...(cookie ? { cookie } : {}) } }); }
    catch (e) { st.error = `${e.name}: ${e.message}`; return resolve(st); }
    const timer = setTimeout(() => { st.timedOut = true; try { ws.close(); } catch {} ; resolve(st); }, secs * 1000);
    ws.onopen = () => { st.opened = true; };
    ws.onerror = (e) => { st.error = (e?.message ?? e?.error?.message ?? 'ws error').toString().slice(0, 100); };
    ws.onclose = (e) => {
      clearTimeout(timer); st.closeCode = e.code; st.closeReason = (e.reason ?? '').slice(0, 60);
      const verdict = () => {
        if (st.frames > 0) return `收到 ${st.frames} 帧 / ${st.bytes}B → 数据流是通的`;
        if (st.opened) return '握手 101 成功但零帧';
        return `握手失败 code=${st.closeCode}${st.error ? ' err=' + st.error : ''}`;
      };
      console.log(`  [${label}] open=${st.opened} frames=${st.frames} bytes=${st.bytes} code=${st.closeCode}` +
        `${st.closeReason ? '/' + st.closeReason : ''}${st.error ? ' err=' + st.error : ''} → ${verdict()}`);
      if (st.firstHex) console.log(`      首帧 hex=${st.firstHex}`);
      for (const [t, n] of Object.entries(st.perType)) console.log(`      ${t} × ${n}`);
      const chats = st.decoded.filter((d) => d.type === 'WebcastChatMessage' && d.text !== '(未解文本)');
      for (const c of chats.slice(0, 10)) console.log(`      弹幕: ${JSON.stringify(c.nick ?? '')}: ${JSON.stringify(c.text)}`);
      resolve(st);
    };
    ws.onmessage = async (ev) => {
      let buf;
      if (typeof ev.data === 'string') buf = Buffer.from(ev.data, 'binary');
      else if (ev.data instanceof Blob) buf = Buffer.from(await ev.data.arrayBuffer());
      else buf = Buffer.from(ev.data);
      st.frames++; st.bytes += buf.length;
      if (st.frames === 1) st.firstHex = buf.subarray(0, 24).toString('hex').match(/.{2}/gu).join(' ');
      const fr = decodeFrame(buf);
      if (fr.payloadType === 'ack' || (fr.encoding ?? '').includes('ack')) { /* server asked */ }
      if (fr.binary) {
        const dm = decodeMessages(fr.binary);
        for (const [k, v] of Object.entries(dm.perType)) st.perType[k] = (st.perType[k] ?? 0) + v;
        st.decoded.push(...dm.messages);
        if (fr.payloadType) st.lastPayloadType = fr.payloadType;
      } else if (fr.payload && fr.payloadType) {
        // 服务端在 header 里要求 ack：回一帧（与 danmaku_client.dart 一致）
        try {
          const payload = Uint8List_(fr.payload);
          const frame = Uint8Array.from([0x3a, 0x03, 0x61, 0x63, 0x6b, 0x42, payload.length, ...payload]);
          ws.send(frame); st.ackSent++;
        } catch {}
      }
      if (st.frames >= 40) { try { ws.close(); } catch {} }
    };
  });
}
const Uint8List_ = (s) => Uint8Array.from(Buffer.from(s, 'utf8'));

console.log('=== vf_dy_ws: 抖音弹幕真实可收性实测 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms.find((r) => Object.keys(r.stream_url?.hls_pull_url_map ?? {}).length) ?? rooms[0];
const roomId = room.id_str;
console.log(`目标房间 ${roomId}  标题=${JSON.stringify((room.title ?? '').slice(0, 20))}  user_count=${room.user_count}`);
console.log(`feed 是否下发 ws 参数: ticket=${JSON.stringify(room.ticket ?? null)} im_info=${JSON.stringify(room.im_info)?.slice(0, 80)} ` +
  `web_rid=${JSON.stringify(room.web_rid ?? null)} danmaku_detail=${JSON.stringify(room.danmaku_detail ?? null)}`);

// 本机 DID（user_unique_id）：抖音 web 用 19 位随机数即可
const uid = String(7000000000000000000 + Math.floor(Math.random() * 999999999999));
const ttwid = await getTtwid();
console.log(`\nttwid: ${ttwid ? ttwid.slice(0, 16) + '…(len=' + ttwid.length + ')' : '(获取失败)'}`);

// L5 前置：仓库/本机是否存在可用的签名生成脚本
console.log('\n── 签名可得性检查（不打印任何内容，只查存在）──');
const signCandidates = ['build/dyref/sign.js', 'tool/sign.js', 'assets/dyref/sign.js', 'build/sign.js'];
for (const p of signCandidates) console.log(`  ${p}: ${fs.existsSync(p) ? 'EXISTS' : 'MISSING'}`);
let signScript = null;
for (const p of signCandidates) if (fs.existsSync(p)) { signScript = p; break; }
if (!signScript) console.log('  → 无任何 signature 生成实现（与 danmaku_client.dart 的说明一致：项目不实现）');

console.log(`\n── L1 无 signature 无 cookie，直连 wss（${SECS}s）──`);
const r1 = await tryConnect('L1 无签名无cookie', buildWss(roomId, uid), { secs: SECS });

console.log(`\n── L2 带 ttwid cookie，无 signature（${SECS}s）──`);
const r2 = await tryConnect('L2 ttwid+无签名', buildWss(roomId, uid), { cookie: ttwid ? `ttwid=${ttwid}` : null, secs: SECS });

console.log(`\n── L3 带 ttwid + web_rid 走 enter 拿真实 ws 参数 ──`);
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';
let enterInfo = null;
for (const host of ['webcast.amemv.com', 'live.douyin.com']) {
  for (const rid of [room.web_rid ?? roomId, room.owner?.web_rid ?? '']) {
    if (!rid) continue;
    const u = `https://${host}/webcast/room/web/enter/?${WEBQ}&web_rid=${rid}&enter_from=web_live&publish_video_strategy_type=2`;
    try {
      const r = await fetch(u, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', cookie: ttwid ? `ttwid=${ttwid}` : '' } });
      const t = await r.text();
      let j = null; try { j = JSON.parse(t); } catch {}
      console.log(`  enter ${host} web_rid=${rid.slice(0, 12)}… HTTP=${r.status} len=${t.length} ` +
        `status_msg=${JSON.stringify(j?.status_msg ?? null)} data=${j?.data ? Object.keys(j.data).join(',').slice(0, 50) : '-'}`);
      if (j?.data && !enterInfo) enterInfo = j.data;
    } catch (e) { console.log(`  enter ${host} ERR ${e.message}`); }
  }
}
if (enterInfo?.data?.[0]) console.log('  enter 返回真实房间对象（含 ws 所需字段）');

console.log(`\n── L3b 有 signature 时是否可行（${signScript ? '有 sign.js' : '无 sign.js → 用 md5 模板占位，验证签名是唯一缺环'}）──`);
const tpl = md5Tpl(buildWss(roomId, uid));
console.log(`  md5 模板输入摘要 = ${tpl}（这是 signature 的正确输入，非 signature 本身）`);
const fakeSig = 'default000000000000000000000000000';
const r3 = await tryConnect('L3b 伪 signature', buildWss(roomId, uid, { withSig: fakeSig }), { cookie: ttwid ? `ttwid=${ttwid}` : null, secs: SECS });

console.log('\n=== 结论矩阵 ===');
for (const r of [r1, r2, r3]) {
  const chats = r.decoded.filter((d) => d.type === 'WebcastChatMessage' && d.text !== '(未解文本)').length;
  console.log(`  ${r.label.padEnd(18)} 握手=${r.opened ? '101' : '失败'} 帧=${r.frames} 字节=${r.bytes} ` +
    `真实弹幕条数=${chats} close=${r.closeCode}${r.error ? ' err=' + r.error : ''}`);
}
fs.writeFileSync('tool/_dy_ws_results.json', JSON.stringify({
  at: new Date().toISOString(), roomId, uid: uid.slice(0, 4) + '…', ttwid: ttwid ? `len=${ttwid.length}` : null,
  signScript, results: [r1, r2, r3].map((r) => ({
    label: r.label, opened: r.opened, frames: r.frames, bytes: r.bytes, closeCode: r.closeCode,
    closeReason: r.closeReason, error: r.error, firstHex: r.firstHex, perType: r.perType,
    chatCount: r.decoded.filter((d) => d.type === 'WebcastChatMessage').length,
    chats: r.decoded.filter((d) => d.type === 'WebcastChatMessage' && d.text !== '(未解文本)').slice(0, 20),
    ackSent: r.ackSent ?? 0,
  })),
}, null, 2), 'utf8');
console.log('\n已写 tool/_dy_ws_results.json');
