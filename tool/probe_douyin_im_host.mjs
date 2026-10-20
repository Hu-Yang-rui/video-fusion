/**
 * 定位抖音私信的**独立网关**。
 *
 * # 已知
 *
 * - `/im/*` 打到 `www.douyin.com` 返回 **HTML 页面**（len=210015），
 *   说明该前缀不在 www 网关下，而是另有 host
 * - `/aweme/v1/web/im/*` 全部 404 `Unsupported path(Janus)`
 * - bundle 里挖到 `/im/conversation/list_visible/`、`/im/fetch/` 等路径
 *
 * # 本脚本要做的事
 *
 * 1. 访问抖音私信页面（`/messages` 或 `/im`），看真实请求打到哪个 host
 * 2. 监听所有 XHR，筛出 `im` 相关的**完整 URL**（含 host）
 * 3. 直接对候选 host + 路径发起请求验证
 *
 * 用法：node tool/probe_douyin_im_host.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const OUT = path.join('tool', '_dy_im_host.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9341;
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
  const result = { startedAt: new Date().toISOString(), imUrls: [], hosts: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-imh-${Date.now()}`);
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

    console.log('[1] 访问私信相关页面 ...');
    for (const url of [
      'https://www.douyin.com/messages',
      'https://www.douyin.com/im',
      'https://www.douyin.com/',
    ]) {
      console.log(`    → ${url}`);
      try {
        await cdp.send('Page.navigate', { url });
      } catch {}
      await sleep(7000);
    }

    // 汇总所有含 im 的请求 URL（完整 host）
    const urls = new Set();
    const hosts = new Set();
    for (const ev of cdp.events) {
      if (ev.method !== 'Network.requestWillBeSent') continue;
      const u = ev.params?.request?.url || '';
      if (!/\/im\b|\/im\/|message|conversation/i.test(u)) continue;
      if (/\.(js|css|png|jpg|webp|woff2?)(\?|$)/.test(u)) continue;
      urls.add(u);
      try {
        hosts.add(new URL(u).host);
      } catch {}
    }

    result.imUrls = [...urls];
    result.hosts = [...hosts];

    console.log(`\n[2] 含 im/message 的请求 ${urls.size} 个，涉及 host：`);
    for (const h of hosts) console.log(`    ${h}`);
    console.log('\n[3] 具体 URL：');
    for (const u of urls) console.log(`    ${u.slice(0, 160)}`);

    // 直接验证候选 host
    const evalJs = async (expression) =>
      cdp
        .send('Runtime.evaluate', {
          expression,
          awaitPromise: true,
          returnByValue: true,
        })
        .then((r) => (r.exceptionDetails ? { __exception: r.exceptionDetails.text } : r.result?.value))
        .catch((e) => ({ error: `CDP: ${e.message}` }));

    const candidates = [
      { host: 'https://www.douyin.com', path: '/im/conversation/list_visible/' },
      { host: 'https://imapi.douyin.com', path: '/im/conversation/list_visible/' },
      { host: 'https://im.douyin.com', path: '/im/conversation/list_visible/' },
      { host: 'https://api.douyin.com', path: '/im/conversation/list_visible/' },
      { host: 'https://www.douyin.com', path: '/aweme/v1/web/im/conversation/list_visible/' },
      { host: 'https://www.douyin.com', path: '/aweme/v1/web/im/user/info/' },
    ];

    console.log('\n[4] 候选 host 验证（注意 CORS 可能阻止跨域，需看 error）...\n');
    for (const c of candidates) {
      const r = await evalJs(`(async () => {
        try {
          const url = ${JSON.stringify(c.host + c.path)} + '?device_platform=webapp&aid=6383&count=10&cursor=0';
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 12000);
          const res = await fetch(url, { credentials:'include',
            headers:{ Referer: location.href }, signal: ctrl.signal });
          clearTimeout(t);
          const text = await res.text();
          return { status: res.status, length: text.length,
            isHtml: text.trimStart().startsWith('<'),
            preview: text.slice(0, 120) };
        } catch(e) { return { error: String(e), name: e && e.name }; }
      })()`);
      console.log(
        `  ${c.host}${c.path}\n    → ${JSON.stringify(r)}`,
      );
      await sleep(300);
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
