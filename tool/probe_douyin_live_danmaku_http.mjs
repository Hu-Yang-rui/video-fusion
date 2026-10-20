// 抖音直播弹幕：走 HTTP 轮询 `/webcast/im/fetch/`，不用 wss、不用 signature。
//
// # 为什么这个脚本存在
//
// 项目此前把抖音直播弹幕判定为"不可用"，理由是：
//
//   > `signature` 由平台下发的 `sign.js`（473 KB 混淆 JS，内部是 webmssdk）
//   > 计算……本项目不内置也不执行这个 JS。
//
// 这个结论**对 wss 路径成立，但漏了一条路**：直播间页面自己用的是
// `/webcast/im/fetch/` 这个 **HTTP 轮询**接口，它同样返回完整弹幕
// （protobuf），且：
//
//   - 不需要 `signature`
//   - 不需要 wss 长连接
//   - 只需要正式 `UIFID` Cookie（页面加载时自动下发）
//
// 之前的探测用的是**死房间号**，所以拿到空数据，从而误判为"接口不可用"。
//
// # 用法
//
// ```bash
// node tool/probe_douyin_live_danmaku_http.mjs [roomId] [轮询次数]
// ```
//
// 不给 roomId 时自动从 `webcast/feed` 挑一个当前在播、在线人数最高的房间。
//
// # 实测记录（本轮）
//
// 房间 `7698363358944627490`（旭旭宝宝，44.7 万人在线）：
//   - 单次 `/webcast/im/fetch/` 返回 130–175 KB
//   - 连续 8 次轮询全部有数据
//   - 解析出真实弹幕，例如 `[过火啦] 我手机坏了`
//
// # 依赖
//
// Chrome（有头模式）+ 本机可访问 `live.douyin.com`。
// **必须用有头模式**：headless 下直播间页面的 SSR 会失败
// （页面显示"服务器开小差了"），拿不到 UIFID。

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

// ── 参数 ────────────────────────────────────────────────────

const ROOM_ARG = process.argv[2] || '';
const POLLS = Math.max(1, Math.min(30, Number(process.argv[3] || 5)));
const CDP_PORT = 9400 + Math.floor(Math.random() * 100);
const OUT_DIR = path.join(os.tmpdir(), 'dy_live_danmaku');

const CHROME_CANDIDATES = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
];

// ── protobuf 读取 ───────────────────────────────────────────

/**
 * 极简 protobuf 读取器。
 *
 * 只支持 varint 与 length-delimited 两种 wire type——弹幕用到的就这两种。
 * 未知字段靠 [skip] 跳过（protobuf 的前向兼容规则）。
 */
class Reader {
  constructor(bytes) {
    this.b = bytes;
    this.i = 0;
  }

  get atEnd() {
    return this.i >= this.b.length;
  }

  varint() {
    let result = 0n;
    let shift = 0n;
    while (true) {
      if (this.i >= this.b.length) throw new Error('truncated varint');
      const x = this.b[this.i++];
      result |= BigInt(x & 0x7f) << shift;
      if ((x & 0x80) === 0) break;
      shift += 7n;
      if (shift > 63n) throw new Error('varint too long');
    }
    return result;
  }

  tag() {
    const t = this.varint();
    return { field: Number(t >> 3n), wire: Number(t & 7n) };
  }

  bytes(len) {
    if (this.i + len > this.b.length) throw new Error('truncated bytes');
    const out = this.b.subarray(this.i, this.i + len);
    this.i += len;
    return out;
  }

  string(len) {
    return Buffer.from(this.bytes(len)).toString('utf8');
  }

  skip(wire) {
    switch (wire) {
      case 0: this.varint(); break;
      case 1: this.i += 8; break;
      case 2: this.i += Number(this.varint()); break;
      case 5: this.i += 4; break;
      default: throw new Error(`unknown wire ${wire}`);
    }
    if (this.i > this.b.length) throw new Error('skip past end');
  }
}

/** 把一个 protobuf 消息读成 { field: value | {len, off} }。 */
function readFields(bytes, start = 0, end = bytes.length) {
  const r = new Reader(bytes);
  r.i = start;
  const out = {};
  while (r.i < end) {
    const { field, wire } = r.tag();
    if (wire === 0) out[field] = { value: r.varint() };
    else if (wire === 2) {
      const len = Number(r.varint());
      out[field] = { len, off: r.i };
      r.i += len;
    } else if (wire === 1) r.i += 8;
    else if (wire === 5) r.i += 4;
    else break;
  }
  return out;
}

/**
 * 解析一次 `/webcast/im/fetch/` 的响应。
 *
 * # 实测结构（逐字节核对过，必须按这个解）
 *
 * 响应体是 `repeated Message`，每条 Message **外面还包一层 `tag(1,LEN)`**：
 *
 * ```
 * // 真实响应开头（hex）
 * 0a bb 03                          ← tag(1,LEN) + len=443（外层包裹）
 *   0a 12 "WebcastRoomMessage"      ← Message.f1 = method 名
 *   12 e8 02 ...                    ← Message.f2 = payload
 *   18 ...                          ← Message.f3 = msgId
 *   4a ...                          ← Message.f9 = headers
 * ```
 *
 * # 三个坑
 *
 *  1. **payload 没有 gzip**。gzip 是 wss 推送帧（`PushFrame`）才有的，
 *     HTTP 轮询的响应是裸 protobuf。
 *  2. **f1 是 method 名字符串**，不是嵌套消息；按"每个 field 都递归"
 *     去解会把 method 名当消息体，最后一条弹幕都拿不到。
 *  3. **外层包裹不能省**。虽然只读内层的 f1/f2 也能凑巧工作
 *     （外层 f1 的内容恰好是内层 f1 的内容），但那是巧合——
 *     一旦平台调整外层字段顺序就会错位。
 *
 * 返回 `[{ method, payload }]`。
 */
function parseImFetch(bytes) {
  const out = [];
  const r = new Reader(bytes);

  while (!r.atEnd) {
    const { field, wire } = r.tag();
    if (wire !== 2) {
      r.skip(wire);
      continue;
    }
    const len = Number(r.varint());
    const start = r.i;
    const end = start + len;
    if (end > bytes.length) break;

    // 外层包裹：field 1 包着一条 Message
    if (field === 1) {
      const msg = readFields(bytes, start, end);
      if (msg[1]?.off !== undefined && msg[2]?.off !== undefined) {
        out.push({
          method: Buffer.from(
            bytes.subarray(msg[1].off, msg[1].off + msg[1].len),
          ).toString('utf8'),
          payload: Buffer.from(
            bytes.subarray(msg[2].off, msg[2].off + msg[2].len),
          ),
        });
      }
    }
    r.i = end;
  }

  return out;
}

/**
 * 解析 `WebcastChatMessage` 的 payload。
 *
 * # 实测结构
 *
 * ```
 * WebcastChatMessage {
 *   Common common  = 1;   // method / msgId / roomId / createTime
 *   User   user    = 2;   // id / shortId / nickname ...
 *   string content = 3;   // 弹幕正文
 * }
 * User {
 *   int64  id       = 1;
 *   string nickname = 3;
 * }
 * ```
 *
 * 没有正文时返回 null（心跳 / 空消息）。
 */
function parseChatMessage(payload) {
  const f = readFields(payload);
  const out = {};

  if (f[2]?.off !== undefined) {
    const u = readFields(payload, f[2].off, f[2].off + f[2].len);
    out.userId = u[1]?.value?.toString() ?? '';
    out.nickname =
      u[3]?.off !== undefined
        ? Buffer.from(payload.subarray(u[3].off, u[3].off + u[3].len)).toString('utf8')
        : '';
  }

  if (f[3]?.off !== undefined) {
    out.content = Buffer.from(
      payload.subarray(f[3].off, f[3].off + f[3].len),
    ).toString('utf8');
  }

  if (f[1]?.off !== undefined) {
    const c = readFields(payload, f[1].off, f[1].off + f[1].len);
    if (c[2]?.value !== undefined) out.msgId = c[2].value.toString();
    if (c[4]?.value !== undefined) out.createTime = c[4].value.toString();
  }

  return out.content ? out : null;
}

// ── CDP ────────────────────────────────────────────────────

function findChrome() {
  for (const p of CHROME_CANDIDATES) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function cdpJson(port, urlPath) {
  return new Promise((resolve, reject) => {
    http
      .get({ host: '127.0.0.1', port, path: urlPath }, (res) => {
        let b = '';
        res.on('data', (d) => (b += d));
        res.on('end', () => {
          try {
            resolve(JSON.parse(b));
          } catch (e) {
            reject(e);
          }
        });
      })
      .on('error', reject);
  });
}

async function waitForCdp(port, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      return await cdpJson(port, '/json/version');
    } catch {
      await new Promise((r) => setTimeout(r, 350));
    }
  }
  throw new Error('CDP 端口未就绪');
}

class CdpSession {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
  }

  async open() {
    await new Promise((res, rej) => {
      this.ws.onopen = res;
      this.ws.onerror = rej;
    });
    this.ws.onmessage = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) reject(new Error(JSON.stringify(m.error)));
        else resolve(m.result);
      }
    };
    return this;
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const mid = ++this.id;
      this.pending.set(mid, { resolve, reject });
      this.ws.send(JSON.stringify({ id: mid, method, params }));
    });
  }

  close() {
    try {
      this.ws.close();
    } catch {}
  }
}

// ── 主流程 ──────────────────────────────────────────────────

async function pickLiveRoom() {
  const ua =
    'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
    'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
  const url =
    'https://webcast.amemv.com/webcast/feed/?aid=1128&app_name=douyin_lite' +
    '&device_platform=android&version_code=400701&device_type=Pixel7' +
    '&os_version=13&channel=googleplay&language=zh&count=15&type=0';

  const res = await fetch(url, { headers: { 'user-agent': ua, accept: 'application/json' } });
  const json = await res.json();
  const rooms = [];
  for (const item of json.data || []) {
    const d = item.data;
    if (!d || d.status !== 2) continue;
    rooms.push({
      roomId: d.id_str,
      online: d.user_count || 0,
      title: d.title || '',
      owner: d.owner?.nickname || '',
    });
  }
  rooms.sort((a, b) => b.online - a.online);
  return rooms[0] || null;
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const chrome = findChrome();
  if (!chrome) {
    console.error('找不到 Chrome / Edge，无法走 CDP 路径');
    process.exit(1);
  }

  // 1) 定房间
  let room = ROOM_ARG;
  let roomMeta = null;
  if (!room) {
    console.log('未指定房间号，从在播列表中挑一个...');
    roomMeta = await pickLiveRoom();
    if (!roomMeta) {
      console.error('没有找到在播房间（可能本机网络无法访问 webcast/feed）');
      process.exit(1);
    }
    room = roomMeta.roomId;
    console.log(`选中: ${room}  ${roomMeta.online} 人在线  ${roomMeta.title}`);
  }

  // 2) 起 Chrome（有头：headless 下直播间 SSR 会失败）
  const profile = path.join(OUT_DIR, `profile-${Date.now()}`);
  fs.mkdirSync(profile, { recursive: true });

  console.log('启动 Chrome（有头模式）...');
  const child = spawn(
    chrome,
    [
      `--remote-debugging-port=${CDP_PORT}`,
      `--user-data-dir=${profile}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-blink-features=AutomationControlled',
      '--window-size=1280,860',
      '--mute-audio',
      'about:blank',
    ],
    { stdio: 'ignore', detached: false },
  );

  const cleanup = () => {
    try {
      child.kill();
    } catch {}
    try {
      fs.rmSync(profile, { recursive: true, force: true });
    } catch {}
  };
  process.on('exit', cleanup);

  try {
    await waitForCdp(CDP_PORT);
    const targets = await cdpJson(CDP_PORT, '/json/list');
    const page = targets.find((t) => t.type === 'page');
    if (!page) throw new Error('没有可用的 page target');

    const cdp = await new CdpSession(page.webSocketDebuggerUrl).open();
    await cdp.send('Runtime.enable');
    await cdp.send('Page.enable');

    // 3) 打开直播间，等 UIFID 下发
    console.log(`打开直播间 ${room} ...`);
    await cdp.send('Page.navigate', { url: `https://live.douyin.com/${room}` });

    let uifidOk = false;
    for (let i = 0; i < 40; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      const st = await cdp.send('Runtime.evaluate', {
        expression: `JSON.stringify({
          ready: document.readyState,
          hasUifid: document.cookie.includes('UIFID='),
          hasTemp: document.cookie.includes('UIFID_TEMP='),
          textLen: document.body ? document.body.innerText.length : 0,
        })`,
        returnByValue: true,
      });
      const s = JSON.parse(st.result.value);
      if (s.hasUifid) {
        uifidOk = true;
        console.log(`[${i + 1}s] 正式 UIFID 已就绪`);
        break;
      }
      if (i % 5 === 4) console.log(`[${i + 1}s] 等待 UIFID... (temp=${s.hasTemp})`);
    }

    if (!uifidOk) {
      console.warn('未拿到正式 UIFID，弹幕请求可能返回空');
    }

    // 4) 轮询 im/fetch
    console.log(`\n开始轮询 /webcast/im/fetch/，共 ${POLLS} 次...`);
    const allChats = [];
    const methodCounts = {};
    let cursor = '';

    for (let i = 0; i < POLLS; i++) {
      const r = await cdp.send('Runtime.evaluate', {
        expression: `
          (async () => {
            const common = 'aid=6383&app_name=douyin_web&live_id=1'
              + '&device_platform=web&language=zh-CN&enter_from=link_share'
              + '&cookie_enabled=true&screen_width=1280&screen_height=860'
              + '&browser_language=zh-CN&browser_platform=Win32'
              + '&browser_name=Chrome&browser_version=124.0.0.0';
            const u = 'https://live.douyin.com/webcast/im/fetch/?' + common
              + '&room_id=${room}'
              + '&cursor=' + encodeURIComponent('${cursor}')
              + '&resp_content_type=protobuf&did_rule=3&identity=audience'
              + '&need_persist_msg_count=15';
            const res = await fetch(u, { credentials: 'include',
              headers: { 'Referer': location.href } });
            const ab = await res.arrayBuffer();
            const buf = new Uint8Array(ab);
            let bin = '';
            for (let k = 0; k < buf.length; k++) bin += String.fromCharCode(buf[k]);
            return JSON.stringify({ status: res.status, bytes: buf.length, b64: btoa(bin) });
          })()`,
        awaitPromise: true,
        returnByValue: true,
      });

      const parsed = JSON.parse(r.result.value);
      if (parsed.status !== 200 || parsed.bytes === 0) {
        console.log(`  第 ${i + 1} 次: HTTP ${parsed.status}, ${parsed.bytes} bytes（无数据）`);
        await new Promise((r2) => setTimeout(r2, 1500));
        continue;
      }

      const bytes = Buffer.from(parsed.b64, 'base64');
      const msgs = parseImFetch(bytes);

      let chats = 0;
      for (const m of msgs) {
        methodCounts[m.method] = (methodCounts[m.method] || 0) + 1;
        if (m.method === 'WebcastChatMessage') {
          const chat = parseChatMessage(m.payload);
          if (chat) {
            allChats.push(chat);
            chats++;
          }
        }
      }
      console.log(
        `  第 ${i + 1} 次: ${parsed.bytes} bytes, ${msgs.length} 条消息, ${chats} 条弹幕`,
      );
      await new Promise((r2) => setTimeout(r2, 1500));
    }

    // 5) 汇总
    console.log('\n=== 消息类型分布 ===');
    for (const [k, v] of Object.entries(methodCounts).sort((a, b) => b[1] - a[1])) {
      console.log(`  ${k}: ${v}`);
    }

    console.log(`\n=== 解析出的弹幕（共 ${allChats.length} 条）===`);
    for (const c of allChats.slice(0, 25)) {
      console.log(`  [${c.nickname || '?'}] ${c.content}`);
    }

    const outFile = path.join(OUT_DIR, `chats-${room}.json`);
    fs.writeFileSync(outFile, JSON.stringify(allChats, null, 2), 'utf8');
    console.log(`\n结果已保存: ${outFile}`);

    const ok = allChats.length > 0;
    console.log(
      ok
        ? '\n结论：HTTP 轮询路径可用，无需 wss / signature。'
        : '\n结论：本次没解析出弹幕。检查房间是否在播、UIFID 是否就绪。',
    );

    cdp.close();
    process.exitCode = ok ? 0 : 2;
  } finally {
    cleanup();
  }
}

main().catch((e) => {
  console.error('失败:', e.message);
  process.exit(1);
});
