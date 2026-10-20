/**
 * 诊断：为什么浏览器打开抖音直播页进不去。
 *
 * 已知：
 *  - 房间确实在播（裸 HTTP room/info 返回 status=2，4.3 万人在线）
 *  - 但浏览器打开 live.douyin.com/{room} 连续 110s 都是 player=false
 *  - UIFID 在 0ms 就"存在"（可疑：全新 profile 不该有）
 *
 * 要查清：
 *  1. 页面最终 URL（是否被重定向）
 *  2. 页面实际 HTML 内容（是直播间、还是首页、还是验证页）
 *  3. cookie 里到底有什么
 *  4. 是否有 "验证" / "登录" 之类的拦截提示
 *
 * 用法：node tool/diag_dy_live_page.mjs [roomId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const ROOM_ID = process.argv[2] || '7698331989480377128';
const OUT = path.join('tool', '_dy_live_diag.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9346;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
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
      }
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
  const result = { roomId: ROOM_ID, startedAt: new Date().toISOString() };

  const userDataDir = path.join(os.tmpdir(), `dy-diag-${Date.now()}`);
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

    console.log(`[1] 打开直播间 ${ROOM_ID}`);
    await cdp.send('Page.navigate', {
      url: `https://live.douyin.com/${ROOM_ID}`,
    });

    await sleep(15000);

    const state = await evalJs(`(() => {
      const html = document.body ? document.body.innerHTML : '';
      return {
        url: location.href,
        title: document.title,
        bodyLen: html.length,
        // 找关键标记
        hasVerify: /验证|verify|captcha|滑块/i.test(html),
        hasLogin: /登录|login/i.test(html),
        hasLiveWord: /直播中|在线观众|说点什么/i.test(html),
        hasVideo: !!document.querySelector('video'),
        videoCount: document.querySelectorAll('video').length,
        // 首 500 字纯文本
        textHead: (document.body ? document.body.innerText : '').slice(0, 500),
        // 前 800 字 HTML
        htmlHead: html.slice(0, 800),
      };
    })()`);
    result.state = state;

    console.log(`[2] 最终 URL: ${state?.url}`);
    console.log(`    title: ${state?.title}`);
    console.log(`    bodyLen: ${state?.bodyLen}  video: ${state?.videoCount}`);
    console.log(`    hasVerify: ${state?.hasVerify}  hasLiveWord: ${state?.hasLiveWord}`);
    console.log(`\n[3] 页面纯文本前 500 字：`);
    console.log(state?.textHead || '(空)');

    // cookie 明细
    const { cookies } = await cdp.send('Network.getAllCookies');
    result.cookies = cookies.map((c) => ({
      name: c.name,
      domain: c.domain,
      hasValue: !!c.value,
    }));
    console.log(`\n[4] Cookie ${cookies.length} 个：`);
    for (const c of cookies) {
      console.log(`    ${c.name}  (${c.domain})`);
    }

    // 检查是否有 UIFID 及其来源域
    const uifid = cookies.filter((c) => /uifid/i.test(c.name));
    console.log(`\n[5] uifid 相关 cookie：${uifid.length} 个`);
    for (const c of uifid) {
      console.log(`    ${c.name} @ ${c.domain}  len=${c.value.length}`);
    }

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
