/**
 * 从抖音前端 JS bundle 里挖私信 / 收藏 / 稍后再看的真实端点。
 *
 * # 为什么换这个方法
 *
 * 猜路径已失败：`/aweme/v1/web/im/thread/list/` 等 13 个候选全 404
 * （`Unsupported path(Janus)`）。说明这些功能不在 `aweme/v1/web` 网关下。
 *
 * 前端 bundle 里一定有真实端点字符串——这是最可靠的来源，
 * 本项目挖 B站私信时用的也是同样方法（读 `message-pc` bundle）。
 *
 * # 做法
 *
 * 1. 打开抖音页面，收集所有已加载的 JS 资源 URL
 * 2. 逐个下载，grep 端点特征串（`/aweme/v1/web/im`、`/im/`、`collect` 等）
 * 3. 输出命中的完整路径
 *
 * 用法：node tool/probe_douyin_bundle_endpoints.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const OUT = path.join('tool', '_dy_bundle_endpoints.json');
const CACHE = path.join('tool', '_dy_bundles');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9339;
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
  const result = { startedAt: new Date().toISOString(), scripts: [], hits: {} };
  fs.mkdirSync(CACHE, { recursive: true });

  const userDataDir = path.join(os.tmpdir(), `dy-b-${Date.now()}`);
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

    console.log('[1] 访问页面并收集 JS 资源 ...');
    for (const url of [
      'https://www.douyin.com/',
      'https://www.douyin.com/user/self',
    ]) {
      try {
        await cdp.send('Page.navigate', { url });
      } catch {}
      await sleep(8000);
    }

    const scriptUrls = new Set();
    for (const ev of cdp.events) {
      if (ev.method !== 'Network.responseReceived') continue;
      const r = ev.params?.response;
      const u = r?.url || '';
      if (!/\.js(\?|$)/.test(u)) continue;
      if (!u.includes('douyin') && !u.includes('bytedance') && !u.includes('zijie')) continue;
      scriptUrls.add(u);
    }
    result.scripts = [...scriptUrls];
    console.log(`[2] 收集到 ${scriptUrls.size} 个 JS 资源`);

    // 逐个下载并 grep
    const patterns = [
      /\/aweme\/v\d+\/web\/[a-z0-9_\/]*im[a-z0-9_\/]*/gi,
      /\/aweme\/v\d+\/web\/[a-z0-9_\/]*collect[a-z0-9_\/]*/gi,
      /\/aweme\/v\d+\/web\/[a-z0-9_\/]*(later|history)[a-z0-9_\/]*/gi,
      /\/aweme\/v\d+\/web\/[a-z0-9_\/]*follow[a-z0-9_\/]*/gi,
      /\/webcast\/[a-z0-9_\/]*(chat|like|gift)[a-z0-9_\/]*/gi,
      /\/im\/[a-z0-9_\/]{4,60}/gi,
      /\/aweme\/v\d+\/web\/[a-z0-9_\/]{4,60}/gi,
    ];

    const allHits = new Set();
    let i = 0;
    for (const u of scriptUrls) {
      i++;
      let text;
      const cacheFile = path.join(CACHE, `s${i}.js`);
      if (fs.existsSync(cacheFile)) {
        text = fs.readFileSync(cacheFile, 'utf8');
      } else {
        try {
          const res = await fetch(u, {
            headers: { 'User-Agent': UA, Referer: 'https://www.douyin.com/' },
          });
          if (!res.ok) continue;
          text = await res.text();
          fs.writeFileSync(cacheFile, text, 'utf8');
        } catch {
          continue;
        }
      }
      for (const re of patterns) {
        const m = text.match(re);
        if (m) for (const x of m) allHits.add(x.replace(/\/$/, '') + '/');
      }
      if (i % 10 === 0) console.log(`    已扫描 ${i}/${scriptUrls.size}`);
    }

    const sorted = [...allHits].sort();
    result.hits = { total: sorted.length, paths: sorted };

    console.log(`\n[3] 命中 ${sorted.length} 个端点候选：\n`);
    for (const p of sorted) console.log(`    ${p}`);

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
