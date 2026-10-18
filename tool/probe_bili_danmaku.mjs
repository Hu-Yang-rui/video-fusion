// B站直播弹幕：未登录能不能连？
//
// 已知：getDanmuInfo 未登录返回 -352。
// 但 -352 是风控码，不一定等于"必须登录"。测四种情况：
//   A. 裸请求（无任何 cookie）
//   B. 带完整设备指纹（buvid3 + buvid4 + b_nut + _uuid）
//   C. 带 bili_ticket
//   D. 直接连 broadcastlv 服务器（不走 getDanmuInfo，用空 token）
//
// D 是关键：弹幕协议的认证包里 token 可以为空，
// 部分房间历史上允许匿名连接。

import crypto from 'node:crypto';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

function md5(s) {
  return crypto.createHash('md5').update(s).digest('hex');
}

async function get(url, cookie = '') {
  const h = { 'user-agent': UA, 'referer': 'https://live.bilibili.com/' };
  if (cookie) h.cookie = cookie;
  const r = await fetch(url, { headers: h });
  const t = await r.text();
  return { status: r.status, text: t };
}

// ---------- 设备指纹 ----------
const spi = await get('https://api.bilibili.com/x/frontend/finger/spi');
let b3 = '', b4 = '';
try {
  const j = JSON.parse(spi.text);
  b3 = j.data.b_3;
  b4 = j.data.b_4;
} catch {}
const uuid = crypto.randomUUID().toUpperCase() +
  String(Date.now() % 100000) + 'infoc';
const fp = `buvid3=${b3}; buvid4=${b4}; b_nut=${Math.floor(Date.now() / 1000)}; ` +
  `_uuid=${uuid}; buvid_fp=${md5(uuid)}; CURRENT_FNVAL=4048`;

console.log('=== 设备指纹 ===');
console.log('  buvid3:', b3 ? b3.slice(0, 20) + '...' : '(none)');
console.log('  buvid4:', b4 ? b4.slice(0, 20) + '...' : '(none)');
console.log('');

// ---------- 找一个真实在播房间 ----------
const list = await get(
  'https://api.live.bilibili.com/room/v3/area/getRoomList?platform=web&parent_area_id=0&area_id=0&sort_type=online&page=1&page_size=5'
);
let roomId = 0;
try {
  const j = JSON.parse(list.text);
  if (j.data?.list?.length) roomId = j.data.list[0].roomid;
} catch {}
console.log('测试房间 room_id =', roomId);
console.log('');

if (!roomId) {
  console.log('拿不到房间，终止');
  process.exit(1);
}

const infoUrl =
  `https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?id=${roomId}&type=0`;

async function probe(label, cookie) {
  const r = await get(infoUrl, cookie);
  let code = '?', token = '', hosts = 0;
  try {
    const j = JSON.parse(r.text);
    code = j.code;
    if (j.data) {
      token = j.data.token || '';
      hosts = (j.data.host_list || []).length;
    }
  } catch {}
  console.log(
    `  ${label.padEnd(28)} HTTP=${r.status} code=${String(code).padEnd(6)} ` +
    `token=${token ? token.slice(0, 12) + '...(' + token.length + ')' : '(none)'} ` +
    `hosts=${hosts}`
  );
  return { code, token, hosts, raw: r.text };
}

console.log('=== A/B/C. getDanmuInfo 各种 cookie 组合 ===');
const a = await probe('A. 无 cookie', '');
const b = await probe('B. 完整设备指纹', fp);
const c = await probe('C. 设备指纹 + bili_ticket', fp + '; bili_ticket=fake_ticket_value');

// ---------- D. 直接连弹幕服务器 ----------
console.log('');
console.log('=== D. 直接连 broadcastlv（不走 getDanmuInfo）===');

// 取一个弹幕服务器地址
const hostList = [
  'broadcastlv.chat.bilibili.com',
  'tx-bj-live-comet-02.chat.bilibili.com',
  'broadcastlv.chat.bilibili.com',
];

// B站弹幕协议：16 字节头 + body
function buildPacket(op, bodyObj) {
  const body = Buffer.from(JSON.stringify(bodyObj), 'utf8');
  const header = Buffer.alloc(16);
  header.writeUInt32BE(16 + body.length, 0); // 总长度
  header.writeUInt16BE(16, 4); // 头长度
  header.writeUInt16BE(1, 6); // 协议版本（明文 json）
  header.writeUInt32BE(op, 8); // 操作码
  header.writeUInt32BE(1, 12); // 序列号
  return Buffer.concat([header, body]);
}

const authBody = {
  uid: 0,
  roomid: roomId,
  protover: 2,
  platform: 'web',
  type: 2,
  key: '', // 空 token 试一下
};

const host = hostList[0];
const wsUrl = `wss://${host}/sub`;
console.log('  连接:', wsUrl);

const result = await new Promise((resolve) => {
  const timeout = setTimeout(() => resolve({ ok: false, reason: 'timeout' }), 15000);
  let ws;
  try {
    ws = new WebSocket(wsUrl);
  } catch (e) {
    clearTimeout(timeout);
    return resolve({ ok: false, reason: 'ctor: ' + e.message });
  }

  let opened = false;
  let authed = false;
  let packets = 0;

  ws.onopen = () => {
    opened = true;
    console.log('  WS 已连接，发送认证包（空 token）');
    ws.send(buildPacket(7, authBody));
  };

  ws.onmessage = (ev) => {
    packets++;
    const buf = Buffer.from(ev.data);
    if (buf.length < 16) return;
    const op = buf.readUInt32BE(8);
    const bodyLen = buf.readUInt32BE(0) - 16;
    const body = buf.subarray(16, 16 + bodyLen);
    // op=8 是认证回复
    if (op === 8) {
      const txt = body.toString('utf8');
      console.log('  认证回复 op=8:', txt.slice(0, 120));
      if (txt.includes('"code":0')) authed = true;
    } else if (op === 5) {
      console.log('  收到业务消息 op=5，长度', bodyLen);
    }
    if (packets >= 3 || authed) {
      clearTimeout(timeout);
      ws.close();
      resolve({ ok: authed, reason: authed ? 'authed' : 'auth-failed', packets });
    }
  };

  ws.onerror = (e) => {
    clearTimeout(timeout);
    resolve({ ok: false, reason: 'ws error: ' + (e.message || 'unknown'), opened });
  };

  ws.onclose = (e) => {
    clearTimeout(timeout);
    resolve({ ok: authed, reason: 'closed code=' + e.code, opened, authed, packets });
  };
});

console.log('  结果:', JSON.stringify(result));
console.log('');
console.log('=== 结论 ===');
if (a.token) {
  console.log('  getDanmuInfo 匿名可用，token 已拿到 → 弹幕可实现');
} else if (b.token) {
  console.log('  带设备指纹后 getDanmuInfo 可用 → 弹幕可实现');
} else if (result.ok) {
  console.log('  空 token 直连成功 → 弹幕可实现（不走 getDanmuInfo）');
} else {
  console.log('  匿名全部失败：code=' + a.code + '，直连=' + result.reason);
  console.log('  → 需要真实登录凭证才能拿到弹幕 token');
}
