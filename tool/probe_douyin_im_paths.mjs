/**
 * 挖掘抖音私信 / 稍后再看的**真实 Web 端点**。
 *
 * # 前置结论（上一轮实测）
 *
 * | 功能 | 结果 |
 * |---|---|
 * | 点赞 `commit/item/digg` | `code=8 用户未登录` → **可实现** |
 * | 收藏 `aweme/collect` | `code=8 用户未登录` → **可实现** |
 * | 关注 `commit/follow/user` | `code=8 用户未登录` → **可实现** |
 * | 直播互动 `webcast/room/chat` | `20003 User doesn't login` → **可实现** |
 * | 私信 `im/thread/list` | **404 Unsupported path(Janus)** → 路径错 |
 * | 稍后再看 `watch/later/list` | **404 Unsupported path(Janus)** → 路径错 |
 *
 * 因此本轮要解决的是**找对路径**，而不是"能不能做"。
 *
 * # 方法
 *
 * 1. 打开抖音页面，全量监听所有 XHR/fetch 请求，筛出含
 *    `im` / `message` / `collect` / `favorite` / `later` / `history` 的路径
 * 2. 直接请求几个候选路径，看哪个不是 404
 *
 * 用法：node tool/probe_douyin_im_paths.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const OUT = path.join('tool', '_dy_im_paths.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9338;
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
  const result = { startedAt: new Date().toISOString(), observedPaths: [], candidates: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-im-${Date.now()}`);
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
    const version = await waitForDevtools(PORT);
    result.browser = version.Browser;

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

    const evalJs = async (expression) => {
      const r = await cdp.send('Runtime.evaluate', {
        expression,
        awaitPromise: true,
        returnByValue: true,
      });
      if (r.exceptionDetails) return { __exception: r.exceptionDetails.text };
      return r.result?.value;
    };

    // 依次访问几个页面，尽量触发 im / collect 相关请求
    console.log('[1] 访问多个页面以收集真实接口路径 ...');
    for (const url of [
      'https://www.douyin.com/',
      'https://www.douyin.com/user/self?showTab=collection',
      'https://www.douyin.com/user/self?showTab=like',
    ]) {
      console.log(`    → ${url}`);
      try {
        await cdp.send('Page.navigate', { url });
      } catch {}
      await sleep(6000);
    }

    // 汇总观察到的路径
    const seen = new Set();
    for (const ev of cdp.events) {
      if (ev.method !== 'Network.requestWillBeSent') continue;
      const u = ev.params?.request?.url || '';
      if (!u.includes('douyin.com')) continue;
      const m = u.match(/douyin\.com(\/[^?#]*)/);
      if (!m) continue;
      const p = m[1];
      if (/\/aweme\/v\d\/web\//.test(p) || /\/webcast\//.test(p)) {
        if (!seen.has(p)) {
          seen.add(p);
          result.observedPaths.push(p);
        }
      }
    }

    const interesting = result.observedPaths.filter((p) =>
      /im|message|collect|favorite|later|history|follow|digg/i.test(p),
    );
    console.log(`\n[2] 共观察到 ${result.observedPaths.length} 个接口路径，其中相关 ${interesting.length} 个：`);
    for (const p of interesting) console.log(`    ${p}`);

    // 候选路径探测（不依赖登录，只看是否 404）
    const candidates = [
      // 私信
      '/aweme/v1/web/im/thread/list/',
      '/aweme/v1/web/im/thread/list/v2/',
      '/aweme/v1/web/im/user/info/',
      '/aweme/v1/web/im/message/list/',
      '/aweme/v1/web/im/conversation/list/',
      '/aweme/v1/web/im/session/list/',
      // 稍后再看 / 观看历史
      '/aweme/v1/web/watch/later/list/',
      '/aweme/v1/web/history/list/',
      '/aweme/v1/web/aweme/history/list/',
      '/aweme/v1/web/play/history/list/',
      // 收藏夹
      '/aweme/v1/web/aweme/collect/list/',
      '/aweme/v1/web/collect/list/',
      '/aweme/v1/web/aweme/collect/folder/list/',
    ];

    console.log('\n[3] 候选路径探测（看是否 404）...\n');
    for (const p of candidates) {
      const r = await evalJs(`(async () => {
        try {
          const url = 'https://www.douyin.com' + ${JSON.stringify(p)}
            + '?device_platform=webapp&aid=6383&count=10&cursor=0';
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 12000);
          const res = await fetch(url, { credentials:'include',
            headers:{ Referer: location.href }, signal: ctrl.signal });
          clearTimeout(t);
          const text = await res.text();
          let parsed = null;
          try { parsed = JSON.parse(text); } catch {}
          return { status: res.status, length: text.length,
            statusCode: parsed ? (parsed.status_code ?? null) : null,
            statusMsg: parsed ? (parsed.status_msg ?? null) : null,
            preview: text.slice(0, 160) };
        } catch(e) { return { error: String(e) }; }
      })()`).catch((e) => ({ error: `CDP: ${e.message}` }));

      const row = { path: p, ...r };
      result.candidates.push(row);

      const tag =
        r?.status === 404 ? 'D-404' :
        r?.error ? 'ERR' :
        r?.status === 200 && r?.length === 0 ? 'C-EMPTY' :
        r?.status === 200 ? 'OK-PATH' : `?(${r?.status})`;
      console.log(
        `${tag.padEnd(9)} ${p.padEnd(42)} HTTP=${String(r?.status).padEnd(4)} ` +
          `len=${String(r?.length).padEnd(6)} code=${r?.statusCode} ${r?.statusMsg || ''} ${r?.error || ''}`,
      );
      await sleep(350);
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
