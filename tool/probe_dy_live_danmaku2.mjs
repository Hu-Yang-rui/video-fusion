/**
 * 抖音直播弹幕接收重测（第二轮）。
 *
 * # 上一轮为什么失败
 *
 * - `UIFID @ 0ms` —— 复用了带 cookie 的旧 profile，cookie 残留导致误判
 * - DOM 只有首页框架，没有直播间内容 —— 页面没真正进入直播间
 * - 结果 `/webcast/im/fetch/` 仍是 `{"data":[],"status_code":0}`（len=27）
 *
 * 所以上一轮的"空数组"**不能作为结论**，因为页面根本没进入直播间。
 *
 * # 本轮做法
 *
 * 1. 全新 profile（无 cookie 残留）
 * 2. 打开直播间后**等页面真正渲染出直播间元素**（不是只等 load）
 * 3. 抓页面自己发的所有 `/webcast/im/` 请求**及其响应体**
 * 4. 检查页面是否建立了 WS（抖音直播弹幕走 wss）
 *
 * 用法：node tool/probe_dy_live_danmaku2.mjs [roomId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const ROOM_ID = process.argv[2] || '7698331989480377128';
const OUT = path.join('tool', '_dy_live_danmaku2.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9345;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.events = [];
    ws.addEventListener('message', (ev) => {
      let msg;
      try {
        msg = JSON.parse(ev.data);
      } catch {
        return;
      }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
        return;
      }
      if (msg.method) this.events.push(msg);
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }
      }, 60000);
    });
  }
}

async function waitForDevtools(port, timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (res.ok) return await res.json();
    } catch {}
    await sleep(300);
  }
  throw new Error('devtools endpoint did not come up');
}

async function main() {
  const result = {
    roomId: ROOM_ID,
    startedAt: new Date().toISOString(),
    imRequests: [],
    wsUrls: [],
    pageState: null,
  };

  // 全新 profile：避免 cookie 残留导致 UIFID 误判
  const userDataDir = path.join(os.tmpdir(), `dy-ld2-${Date.now()}`);
  const child = spawn(
    CHROME,
    [
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${userDataDir}`,
      // 不用 headless：抖音直播页在 headless 下不渲染播放器/聊天区
      // （实测连续 110s player=false，页面只出首页框架）
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-blink-features=AutomationControlled',
      '--disable-gpu',
      '--window-size=1600,900',
      `--user-agent=${UA}`,
      '--lang=zh-CN',
      '--mute-audio',
      'about:blank',
    ],
    { stdio: 'ignore' },
  );

  let cdp;
  try {
    await waitForDevtools(PORT);
    const targets = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    const pageTarget = targets.find((t) => t.type === 'page');
    const ws = new WebSocket(pageTarget.webSocketDebuggerUrl);
    await new Promise((res, rej) => {
      ws.addEventListener('open', res);
      ws.addEventListener('error', rej);
    });
    cdp = new Cdp(ws);

    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Network.enable');
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `try{Object.defineProperty(navigator,'webdriver',{get:()=>undefined})}catch(e){}`,
    });

    const evalJs = async (expression) =>
      cdp
        .send('Runtime.evaluate', {
          expression,
          awaitPromise: true,
          returnByValue: true,
        })
        .then((r) =>
          r.exceptionDetails
            ? { __exception: r.exceptionDetails.text }
            : r.result?.value,
        )
        .catch((e) => ({ error: `CDP: ${e.message}` }));

    const target = `https://live.douyin.com/${ROOM_ID}`;
    console.log(`[1] 全新 profile，打开 ${target}`);
    await cdp.send('Page.navigate', { url: target });

    // 先等 UIFID（全新 profile，不会误判）
    let fullAt = -1;
    for (let i = 0; i < 140; i++) {
      await sleep(500);
      const { cookies } = await cdp.send('Network.getAllCookies');
      if (cookies.some((c) => c.name === 'UIFID')) {
        fullAt = i * 500;
        break;
      }
    }
    result.fullUifidAtMs = fullAt;
    console.log(`[2] 正式 UIFID @ ${fullAt}ms`);

    // 等页面真正进入直播间：轮询关键元素
    let entered = false;
    let enteredAt = -1;
    for (let i = 0; i < 120; i++) {
      await sleep(1000);
      const st = await evalJs(`(() => {
        const html = document.body ? document.body.innerHTML : '';
        return {
          url: location.href,
          bodyLen: html.length,
          // 直播间关键特征
          hasPlayer: !!document.querySelector('video, .xg-player, [data-e2e="live-player"]'),
          hasChat: !!document.querySelector('[class*="chat"], [class*="Chat"]'),
          hasComment: html.includes('说点什么') || html.includes('在线观众'),
          textSample: html.slice(0, 200),
        };
      })()`);
      if (st?.hasPlayer || st?.hasComment) {
        entered = true;
        enteredAt = i * 1000;
        result.pageState = st;
        break;
      }
      if (i % 10 === 0) {
        console.log(`    ${i}s: player=${st?.hasPlayer} comment=${st?.hasComment} len=${st?.bodyLen}`);
      }
    }
    result.enteredRoom = entered;
    result.enteredAtMs = enteredAt;
    console.log(`[3] 进入直播间: ${entered} @ ${enteredAt}ms`);

    // 再多等，收集 IM 流量
    console.log('[4] 继续观察 30s 收集弹幕流量 ...');
    await sleep(30000);

    // 汇总 IM 相关请求 + 响应
    const imPaths = new Map();
    for (const ev of cdp.events) {
      if (ev.method === 'Network.requestWillBeSent') {
        const u = ev.params?.request?.url || '';
        if (u.startsWith('wss://') || u.startsWith('ws://')) {
          if (!result.wsUrls.includes(u)) result.wsUrls.push(u);
        }
        if (/\/webcast\/im\/|\/im\/fetch|push\/v2|\/webcast\/im\b/i.test(u)) {
          const key = u.split('?')[0];
          if (!imPaths.has(key)) imPaths.set(key, { url: u, requests: 0, responses: [] });
          imPaths.get(key).requests++;
        }
      }
      if (ev.method === 'Network.responseReceived') {
        const u = ev.params?.response?.url || '';
        if (/\/webcast\/im\/|\/im\/fetch|push\/v2/i.test(u)) {
          const key = u.split('?')[0];
          if (imPaths.has(key)) {
            imPaths.get(key).responses.push(ev.params.response.status);
          }
        }
      }
    }

    result.imRequests = [...imPaths.values()].map((v) => ({
      url: v.url.slice(0, 200),
      requests: v.requests,
      responses: v.responses,
    }));

    console.log(`\n[5] WS 连接 ${result.wsUrls.length} 个：`);
    for (const u of result.wsUrls) console.log(`    ${u.slice(0, 220)}`);
    console.log(`\n[6] IM 端点 ${result.imRequests.length} 个：`);
    for (const r of result.imRequests) {
      console.log(`    ${r.url.slice(0, 120)}  req=${r.requests} resp=[${r.responses.join(',')}]`);
    }

    // 用页面上下文重放 im/fetch（带完整参数）
    const replay = await evalJs(`(async () => {
      const p = new URLSearchParams({
        aid: '6383', app_name: 'douyin_web', device_platform: 'web',
        browser_language: 'zh-CN', browser_platform: 'Win32',
        browser_name: 'Chrome', browser_version: '124.0.0.0',
        cookie_enabled: 'true', screen_width: '1600', screen_height: '900',
        browser_online: 'true', room_id: ${JSON.stringify(ROOM_ID)},
        live_id: '1', identity: 'audience', version_code: '290100',
        webcast_sdk_version: '1.0.14-beta.0', compress: 'gzip',
        support_wrds: '1', heartbeatDuration: '0',
      }).toString();
      try {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 20000);
        const res = await fetch('https://live.douyin.com/webcast/im/fetch/?' + p, {
          method: 'POST', credentials: 'include',
          headers: { Referer: location.href,
            'Content-Type': 'application/x-www-form-urlencoded' },
          body: p, signal: ctrl.signal,
        });
        clearTimeout(t);
        const text = await res.text();
        return { status: res.status, len: text.length, preview: text.slice(0, 400) };
      } catch(e) { return { error: String(e) }; }
    })()`);
    result.imFetchReplay = replay;
    console.log(`\n[7] 重放 /webcast/im/fetch/ → ${JSON.stringify(replay).slice(0, 300)}`);

    result.finishedAt = new Date().toISOString();
    fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
    console.log(`\n结果已写入 ${OUT}`);
  } finally {
    try { cdp?.ws?.close(); } catch {}
    try { child.kill(); } catch {}
  }
}

main().catch((e) => {
  console.error('FATAL', e);
  process.exitCode = 1;
});
