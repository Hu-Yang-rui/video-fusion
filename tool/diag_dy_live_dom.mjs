/**
 * 深挖：抖音直播页为什么渲染不出播放器。
 *
 * 已知（上一轮 diag）：
 *  - 页面 URL 没被重定向，仍在 /{roomId}
 *  - bodyLen 90 万，但 videoCount=0
 *  - UIFID 和 UIFID_TEMP 都在（domain=.douyin.com，len=160）
 *  - HTML 里有个 `script-layouts` div，含 user_is_login:0
 *
 * 要查：
 *  1. 页面里到底有没有"直播间"的 DOM 结构（只是选择器没匹配上？）
 *  2. 是否有 JS 报错阻止渲染
 *  3. 关键接口（room/info、webcast/enter）是否被调用、返回什么
 *  4. `script-layouts` 里的完整状态
 *
 * 用法：node tool/diag_dy_live_dom.mjs [roomId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const ROOM_ID = process.argv[2] || '7698331989480377128';
const OUT = path.join('tool', '_dy_live_dom.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9347;
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
  const result = { roomId: ROOM_ID, startedAt: new Date().toISOString(), consoleErrors: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-dom-${Date.now()}`);
  const child = spawn(
    CHROME,
    [
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${userDataDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-blink-features=AutomationControlled',
      '--disable-gpu',
      '--window-size=1600,900',
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
    await cdp.send('Log.enable');

    // 抓 console 错误
    const origEvents = cdp.events;
    cdp.events = [];
    const collect = () => {
      for (const ev of cdp.events) {
        if (ev.method === 'Runtime.consoleAPICalled' &&
            ['error', 'warning'].includes(ev.params?.type)) {
          const txt = (ev.params.args || [])
            .map((a) => a.value ?? a.description ?? '')
            .join(' ');
          if (txt) result.consoleErrors.push(txt.slice(0, 300));
        }
        if (ev.method === 'Runtime.exceptionThrown') {
          const d = ev.params?.exceptionDetails;
          result.consoleErrors.push(
            `EXCEPTION: ${d?.text || ''} ${d?.exception?.description || ''}`.slice(0, 300),
          );
        }
      }
      cdp.events = [];
    };

    // 注意：这里**不注入** navigator.webdriver 改写。
    // 实测该注入会让直播页抛
    //   "Cannot assign to read only property 'call' of object"
    // 导致整个页面 JS 初始化中断（rootChildren=4、webcast 全局 undefined、
    // 一个 webcast/room 接口都不调）。用 --disable-blink-features 就够了。

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

    console.log(`[1] 打开直播间 ${ROOM_ID}`);
    await cdp.send('Page.navigate', {
      url: `https://live.douyin.com/${ROOM_ID}`,
    });

    // 分阶段观察
    for (const wait of [5000, 10000, 15000]) {
      await sleep(wait);
      collect();
      const snap = await evalJs(`(() => {
        const html = document.body ? document.body.innerHTML : '';
        const root = document.getElementById('root');
        return {
          t: Date.now(),
          url: location.href,
          bodyLen: html.length,
          rootChildren: root ? root.children.length : -1,
          rootTextLen: root ? (root.innerText || '').length : -1,
          videos: document.querySelectorAll('video').length,
          canvases: document.querySelectorAll('canvas').length,
          // 找任何带 player 的 class
          playerish: document.querySelectorAll('[class*="player"],[class*="Player"],[class*="xg-"]').length,
          // 是否有房间标题
          hasTitle: html.includes('王大宝') || html.includes('直播中'),
          textLen: (document.body ? document.body.innerText : '').length,
          textHead: (document.body ? document.body.innerText : '').slice(0, 200),
        };
      })()`);
      console.log(`    +${wait}ms: rootChildren=${snap?.rootChildren} videos=${snap?.videos} canvases=${snap?.canvases} playerish=${snap?.playerish} hasTitle=${snap?.hasTitle} textLen=${snap?.textLen}`);
    }

    const finalState = await evalJs(`(() => {
      const html = document.body ? document.body.innerHTML : '';
      // script-layouts 里的状态
      const layouts = document.getElementById('script-layouts');
      let layoutData = null;
      if (layouts) {
        try { layoutData = JSON.parse(layouts.getAttribute('data-value') || '{}'); } catch {}
      }
      return {
        url: location.href,
        title: document.title,
        layoutData,
        // 所有 script src（看加载了哪些 bundle）
        scriptCount: document.scripts.length,
        // 是否有 webcast sdk 全局
        globals: {
          webcast: typeof window.webcast,
          bytedacm: typeof window.bytedacm,
          _webcast: typeof window._webcast,
          RENDER_DATA: typeof window.RENDER_DATA,
        },
      };
    })()`);
    result.finalState = finalState;

    console.log(`\n[2] 最终状态：`);
    console.log(`    url: ${finalState?.url}`);
    console.log(`    title: ${finalState?.title}`);
    console.log(`    globals: ${JSON.stringify(finalState?.globals)}`);
    console.log(`    layoutData: ${JSON.stringify(finalState?.layoutData).slice(0, 400)}`);

    console.log(`\n[3] Console 错误/异常 ${result.consoleErrors.length} 条：`);
    for (const e of result.consoleErrors.slice(0, 20)) {
      console.log(`    ${e}`);
    }

    // 关键：页面自己有没有请求 room/info 或 webcast/enter
    const apiCalls = new Map();
    for (const ev of cdp.events) {
      if (ev.method !== 'Network.requestWillBeSent') continue;
      const u = ev.params?.request?.url || '';
      if (/webcast\/(room|im)\//.test(u)) {
        const k = u.split('?')[0];
        apiCalls.set(k, (apiCalls.get(k) || 0) + 1);
      }
    }
    result.apiCalls = [...apiCalls.entries()].map(([k, v]) => ({ path: k, count: v }));
    console.log(`\n[4] 页面自己调用的 webcast 接口：`);
    for (const a of result.apiCalls) console.log(`    ${a.path}  x${a.count}`);

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
