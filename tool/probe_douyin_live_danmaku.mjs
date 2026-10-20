/**
 * 用正式 UIFID 重测抖音直播弹幕接收。
 *
 * # 为什么重测
 *
 * 旧结论（写在 douyin_adapter.dart 里）说：
 *   (2) im/fetch: 11 参数组合 x 2 POST 方式全部 HTTP 200 len=27
 *       {"data":[],"status_code":0}（空数组）
 *
 * 但那批测试是在**只有 UIFID_TEMP** 的会话里做的。本轮已证明
 * detail/related/feed 在**正式 UIFID** 下才可用——弹幕很可能同理。
 *
 * # 本脚本
 *
 * 1. 拿到正式 UIFID
 * 2. 打开一个真实直播间页面，抓它**自己**请求的弹幕端点
 * 3. 用页面自己的参数重放 im/fetch，看是否还空
 *
 * 用法：node tool/probe_douyin_live_danmaku.mjs [roomId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const ROOM_ID = process.argv[2] || '7697991152271723273';
const OUT = path.join('tool', '_dy_live_danmaku.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9342;
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
  const result = { roomId: ROOM_ID, startedAt: new Date().toISOString(), wsUrls: [], probes: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-ld-${Date.now()}`);
  const child = spawn(
    CHROME,
    [
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${userDataDir}`,
      '--headless=new',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-blink-features=AutomationControlled',
      '--disable-gpu',
      '--window-size=1536,864',
      `--user-agent=${UA}`,
      '--lang=zh-CN',
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

    console.log(`[1] 打开直播间 https://live.douyin.com/${ROOM_ID} ...`);
    await cdp.send('Page.navigate', {
      url: `https://live.douyin.com/${ROOM_ID}`,
    });

    // 等正式 UIFID
    let fullAt = -1;
    for (let i = 0; i < 120; i++) {
      await sleep(500);
      const { cookies } = await cdp.send('Network.getAllCookies');
      if (cookies.some((c) => c.name === 'UIFID')) {
        fullAt = i * 500;
        break;
      }
    }
    result.fullUifidAtMs = fullAt;
    console.log(`[2] 正式 UIFID @ ${fullAt}ms`);

    // 再等一会，让直播页完成 IM 初始化
    await sleep(12000);

    // 收集页面自己请求的弹幕相关端点
    const wsUrls = new Set();
    const imUrls = new Set();
    for (const ev of cdp.events) {
      if (ev.method !== 'Network.requestWillBeSent') continue;
      const u = ev.params?.request?.url || '';
      if (u.startsWith('wss://') || u.startsWith('ws://')) wsUrls.add(u);
      if (/\/webcast\/im\/|\/im\/fetch|danmaku|push/i.test(u)) imUrls.add(u);
    }
    result.wsUrls = [...wsUrls];
    result.imUrls = [...imUrls];

    console.log(`\n[3] 页面自己建立的 WS 连接 ${wsUrls.size} 个：`);
    for (const u of wsUrls) console.log(`    ${u.slice(0, 200)}`);
    console.log(`\n[4] 页面自己请求的 IM/弹幕端点 ${imUrls.size} 个：`);
    for (const u of imUrls) console.log(`    ${u.slice(0, 200)}`);

    // 看页面上是否真的渲染了弹幕 DOM（最有力的证据）
    const evalJs = async (expression) =>
      cdp
        .send('Runtime.evaluate', {
          expression,
          awaitPromise: true,
          returnByValue: true,
        })
        .then((r) => (r.exceptionDetails ? { __exception: r.exceptionDetails.text } : r.result?.value))
        .catch((e) => ({ error: `CDP: ${e.message}` }));

    const domProbe = await evalJs(`(() => {
      const texts = [];
      // 抖音直播弹幕通常在带特定 class 的容器里
      document.querySelectorAll('div,span').forEach(el => {
        const t = (el.textContent || '').trim();
        if (!t || t.length > 60) return;
        if (el.children.length > 2) return;
        texts.push(t);
      });
      const uniq = [...new Set(texts)];
      return {
        total: uniq.length,
        sample: uniq.slice(0, 40),
        hasWebcastSdk: typeof window.webcast !== 'undefined',
        bodyLen: document.body ? document.body.innerHTML.length : 0,
      };
    })()`);
    result.domProbe = domProbe;
    console.log(`\n[5] 页面 DOM 文本节点 ${domProbe?.total ?? 0} 个，抽样：`);
    console.log(`    ${JSON.stringify((domProbe?.sample || []).slice(0, 20))}`);

    // 直接重放 im/fetch（用页面自己的 cookie）
    const probeBody = await evalJs(`(async () => {
      const body = new URLSearchParams({
        aid: '6383', app_name: 'douyin_web', device_platform: 'web',
        browser_language: 'zh-CN', browser_platform: 'Win32',
        browser_name: 'Chrome', browser_version: '124.0.0.0',
        cookie_enabled: 'true', screen_width: '1536', screen_height: '864',
        browser_online: 'true', room_id: ${JSON.stringify(ROOM_ID)},
        live_id: '1', identity: 'audience', version_code: '290100',
        webcast_sdk_version: '1.0.14-beta.0', compress: 'gzip',
      }).toString();
      try {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 15000);
        const res = await fetch('https://live.douyin.com/webcast/im/fetch/?' + body, {
          method: 'POST', credentials: 'include',
          headers: { Referer: location.href,
            'Content-Type': 'application/x-www-form-urlencoded' },
          body: body, signal: ctrl.signal,
        });
        clearTimeout(t);
        const text = await res.text();
        return { status: res.status, len: text.length, preview: text.slice(0, 300) };
      } catch(e) { return { error: String(e) }; }
    })()`);
    result.imFetchReplay = probeBody;
    console.log(`\n[6] 重放 /webcast/im/fetch/ → ${JSON.stringify(probeBody).slice(0, 300)}`);

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
