// B站直播弹幕：getDanmuInfo + wbi 签名。
//
// 参考 xfgryujk/blivedm（1408★）的 clients/web.py：
//   DANMAKU_SERVER_CONF_URL = '.../xlive/web-room/v1/index/getDanmuInfo'
//   params = add_wbi_sign({'id': room_id, 'type': 0})
//
// 代码注释明确指出：code == -352 是 "wbi签名错误"。
// 我之前没带 wbi 签名，所以一直 -352 —— 不是"必须登录"。

import crypto from 'node:crypto';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

// blivedm 的 WBI_KEY_INDEX_TABLE
const MIXIN_TAB = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
  36, 20, 34, 44, 52,
];

async function getWbiKey() {
  const r = await fetch('https://api.bilibili.com/x/web-interface/nav', {
    headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' },
  });
  const j = await r.json();
  const img = j.data.wbi_img.img_url.split('/').pop().split('.')[0];
  const sub = j.data.wbi_img.sub_url.split('/').pop().split('.')[0];
  const raw = img + sub;
  const key = MIXIN_TAB.map((i) => raw[i]).join('');
  return key.slice(0, 32);
}

function addWbiSign(params, wbiKey) {
  const wts = String(Math.floor(Date.now() / 1000));
  const p = { ...params, wts };
  const keys = Object.keys(p).sort();
  const query = keys
    .map((k) => {
      // 过滤 !'()* 五个字符
      const v = String(p[k]).replace(/[!'()*]/g, '');
      return `${encodeURIComponent(k)}=${encodeURIComponent(v)}`;
    })
    .join('&');
  const wRid = crypto.createHash('md5').update(query + wbiKey).digest('hex');
  return `${query}&w_rid=${wRid}`;
}

// ---------- 取房间 ----------
const listRes = await fetch(
  'https://api.live.bilibili.com/room/v3/area/getRoomList' +
    '?platform=web&parent_area_id=0&area_id=0&sort_type=online&page=1&page_size=5',
  { headers: { 'user-agent': UA, referer: 'https://live.bilibili.com/' } }
);
const listJson = await listRes.json();
const roomId = listJson.data.list[0].roomid;
console.log('room_id =', roomId, '| 人气', listJson.data.list[0].online);
console.log('');

// ---------- wbi key ----------
const wbiKey = await getWbiKey();
console.log('wbi_key =', wbiKey);
console.log('');

// ---------- 三种组合对比 ----------
console.log('=== getDanmuInfo 对比 ===');

// A. 无签名（我之前做的）
{
  const r = await fetch(
    `https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?id=${roomId}&type=0`,
    { headers: { 'user-agent': UA, referer: `https://live.bilibili.com/${roomId}` } }
  );
  const j = await r.json();
  console.log(`  A. 无签名          code=${j.code}  message=${j.message ?? ''}`);
}

// B. 带 wbi 签名（blivedm 的做法）
{
  const signed = addWbiSign({ id: roomId, type: 0 }, wbiKey);
  const r = await fetch(
    `https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?${signed}`,
    { headers: { 'user-agent': UA, referer: `https://live.bilibili.com/${roomId}` } }
  );
  const j = await r.json();
  console.log(`  B. wbi 签名        code=${j.code}  message=${j.message ?? ''}`);
  if (j.code === 0 && j.data) {
    console.log(`     token 长度: ${(j.data.token || '').length}`);
    console.log(`     host_list: ${(j.data.host_list || []).length} 个`);
    if (j.data.host_list) {
      for (const h of j.data.host_list.slice(0, 3)) {
        console.log(`       ${h.host}: wss_port=${h.wss_port}`);
      }
    }
    console.log(`     token 前 20: ${(j.data.token || '').slice(0, 20)}...`);

    // ---------- 用这个 token 连 ws ----------
    console.log('');
    console.log('=== 用 token 连接弹幕服务器 ===');
    const host = j.data.host_list[0];
    const token = j.data.token;

    const authBody = {
      uid: 0,
      roomid: roomId,
      protover: 2,
      platform: 'web',
      type: 2,
      key: token,
    };

    function buildPacket(op, obj) {
      const body = Buffer.from(JSON.stringify(obj), 'utf8');
      const header = Buffer.alloc(16);
      header.writeUInt32BE(16 + body.length, 0);
      header.writeUInt16BE(16, 4);
      header.writeUInt16BE(1, 6);
      header.writeUInt32BE(op, 8);
      header.writeUInt32BE(1, 12);
      return Buffer.concat([header, body]);
    }

    const wsUrl = `wss://${host.host}:${host.wss_port}/sub`;
    console.log('  连接:', wsUrl);

    const result = await new Promise((resolve) => {
      const to = setTimeout(() => resolve({ ok: false, reason: 'timeout' }), 15000);
      const ws = new WebSocket(wsUrl);
      let opened = false;
      let authed = false;
      let msgCount = 0;

      ws.onopen = () => {
        opened = true;
        console.log('  WS 101 已连接，发送认证包');
        ws.send(buildPacket(7, authBody));
      };

      ws.onmessage = async (ev) => {
        let buf;
        if (typeof ev.data === 'string') buf = Buffer.from(ev.data, 'binary');
        else if (ev.data instanceof Blob) buf = Buffer.from(await ev.data.arrayBuffer());
        else buf = Buffer.from(ev.data);

        if (buf.length < 16) return;
        const op = buf.readUInt32BE(8);
        const bodyLen = buf.readUInt32BE(0) - 16;
        const body = buf.subarray(16, 16 + bodyLen);

        if (op === 8) {
          const txt = body.toString('utf8');
          console.log('  认证回复:', txt.slice(0, 100));
          if (txt.includes('"code":0')) authed = true;
        } else if (op === 5) {
          msgCount++;
          if (msgCount <= 2) {
            console.log(`  收到业务包 op=5，${bodyLen}B`);
          }
        }
        if (authed && msgCount >= 3) {
          clearTimeout(to);
          ws.close();
          resolve({ ok: true, authed, msgCount, opened });
        }
      };

      ws.onerror = () => { clearTimeout(to); resolve({ ok: false, reason: 'error', opened }); };
      ws.onclose = (e) => { clearTimeout(to); resolve({ ok: authed, authed, msgCount, opened, code: e.code }); };
    });

    console.log('');
    console.log('  结果:', JSON.stringify(result));
    console.log('');
    if (result.authed) {
      console.log('结论：**wbi 签名后 getDanmuInfo 可用，弹幕服务器认证成功**');
      console.log('      → B站弹幕完全可实现，不需要登录');
    } else {
      console.log('结论：token 拿到了但认证未成功，需查 protover 或 auth 字段');
    }
  }
}
