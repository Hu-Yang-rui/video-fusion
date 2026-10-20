/**
 * 决定性实验：在**真实 Chromium 页面上下文**里请求抖音 detail。
 *
 * 不依赖 playwright/puppeteer —— 直接用原生 CDP（Chrome DevTools Protocol）。
 * Node 22 自带 WebSocket，因此零依赖。
 *
 * # 要回答的问题
 *
 * App 里评论接口（`/aweme/v1/web/comment/list/`）通过隐藏 WebView 已跑通，
 * 而 detail（`/aweme/v1/web/aweme/detail/`）走**裸 HTTP**，实测 403
 * `Blocked by ArgusSecurityPlugin Uifid Not Found`。
 *
 * 差异只有"是否经过真实浏览器环境"。所以本脚本验证：
 *   页面内 fetch detail → 成功 or 仍被拒？
 *
 * 用法：
 *   node tool/probe_douyin_detail_inpage.mjs [awemeId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const AWEME_ID = process.argv[2] || '7345492945006595379';
const OUT = path.join('tool', '_dy_detail_inpage.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9333;

function commonParams() {
  return {
    device_platform: 'webapp',
    aid: '6383',
    channel: 'channel_pc_web',
    pc_client_type: '1',
    version_code: '290100',
    version_name: '29.1.0',
    cookie_enabled: 'true',
    browser_language: 'zh-CN',
    browser_platform: 'Win32',
    browser_name: 'Chrome',
    browser_version: '124.0.0.0',
    browser_online: 'true',
    engine_name: 'Blink',
    engine_version: '124.0.0.0',
    os_name: 'Windows',
    os_version: '10',
    platform: 'PC',
    downlink: '10',
    effective_type: '4g',
    round_trip_time: '0',
    update_version_code: '170400',
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 极简 CDP 客户端。 */
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

  send(method, params = {}, sessionId) {
    const id = ++this.id;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify(payload));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }
      }, 90000);
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
    awemeId: AWEME_ID,
    chrome: CHROME,
    startedAt: new Date().toISOString(),
  };

  if (!fs.existsSync(CHROME)) {
    throw new Error(`chrome not found: ${CHROME}`);
  }

  const userDataDir = path.join(os.tmpdir(), `dy-cdp-${Date.now()}`);
  const args = [
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
  ];

  console.log(`[0] 启动 Chromium ...`);
  const child = spawn(CHROME, args, { stdio: 'ignore' });

  let cdp;
  try {
    const version = await waitForDevtools(PORT);
    result.browser = version.Browser;

    // 新建一个 page target
    const listRes = await fetch(`http://127.0.0.1:${PORT}/json/list`);
    const targets = await listRes.json();
    let pageTarget = targets.find((t) => t.type === 'page');
    if (!pageTarget) {
      const created = await fetch(
        `http://127.0.0.1:${PORT}/json/new?about:blank`,
        { method: 'PUT' },
      );
      pageTarget = await created.json();
    }

    const ws = new WebSocket(pageTarget.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve);
      ws.addEventListener('error', reject);
    });
    cdp = new Cdp(ws);

    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Network.enable');

    // 去掉自动化标记（与 App 内 WebView 一致）
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `try{Object.defineProperty(navigator,'webdriver',{get:()=>undefined})}catch(e){}`,
    });

    const target = `https://www.douyin.com/video/${AWEME_ID}`;
    console.log(`[1] 打开 ${target}`);
    await cdp.send('Page.navigate', { url: target });

    // 等 uifid
    let hasUifid = false;
    let uifidAfterMs = -1;
    for (let i = 0; i < 50; i++) {
      await sleep(500);
      const { cookies } = await cdp.send('Network.getAllCookies');
      const names = cookies.map((c) => c.name);
      if (names.some((n) => /uifid/i.test(n))) {
        hasUifid = true;
        uifidAfterMs = i * 500;
        break;
      }
    }
    result.hasUifid = hasUifid;
    result.uifidAfterMs = uifidAfterMs;

    const { cookies: allCookies } = await cdp.send('Network.getAllCookies');
    result.cookieNames = allCookies.map((c) => c.name);
    console.log(
      `[2] uifid=${hasUifid} after ${uifidAfterMs}ms; cookies=${result.cookieNames.length}`,
    );

    const evalJs = async (expression) => {
      const r = await cdp.send('Runtime.evaluate', {
        expression,
        awaitPromise: true,
        returnByValue: true,
      });
      if (r.exceptionDetails) {
        return { __exception: r.exceptionDetails.text };
      }
      return r.result?.value;
    };

    result.pageUrl = await evalJs('location.href');
    result.pageTitle = await evalJs('document.title');
    result.sdkProbe = await evalJs(`(() => ({
      hasBdms: typeof window.bdms !== 'undefined',
      bytedacm: typeof window.bytedacm !== 'undefined',
      webmssdk: typeof window.webmssdk !== 'undefined',
      scriptCount: document.scripts.length,
      sdkScripts: Array.from(document.scripts).map(s=>s.src)
        .filter(s=>/bdms|webmssdk|secsdk|sdk/i.test(s)).slice(0,8)
    }))()`);

    // ── 核心 1：页面内 detail ───────────────────────────────
    const detailParams = { ...commonParams(), aweme_id: AWEME_ID };
    console.log('[3] 页面内请求 detail ...');
    const detail = await evalJs(`(async () => {
      const params = ${JSON.stringify(detailParams)};
      const qs = new URLSearchParams(params).toString();
      const url = 'https://www.douyin.com/aweme/v1/web/aweme/detail/?' + qs;
      try {
        const res = await fetch(url, {
          method: 'GET', credentials: 'include',
          headers: { 'Referer': location.href }
        });
        const text = await res.text();
        return {
          status: res.status,
          length: text.length,
          preview: text.slice(0, 800),
          hasAwemeDetail: text.includes('"aweme_detail"'),
          abortHeader: res.headers.get('x-whale-throughput-abort-data') || null
        };
      } catch (e) {
        return { error: String(e), name: e && e.name, message: e && e.message };
      }
    })()`);
    result.detail = detail;
    console.log(
      `[4] detail → status=${detail?.status} len=${detail?.length} ` +
        `aweme_detail=${detail?.hasAwemeDetail} ${detail?.error || ''}`,
    );

    // ── 对照：页面内 comment ───────────────────────────────
    const commentParams = {
      ...commonParams(),
      aweme_id: AWEME_ID,
      cursor: '0',
      count: '5',
      item_type: '0',
    };
    console.log('[5] 页面内请求 comment/list（对照组）...');
    const comment = await evalJs(`(async () => {
      const params = ${JSON.stringify(commentParams)};
      const qs = new URLSearchParams(params).toString();
      const url = 'https://www.douyin.com/aweme/v1/web/comment/list/?' + qs;
      try {
        const res = await fetch(url, {
          method: 'GET', credentials: 'include',
          headers: { 'Referer': location.href }
        });
        const text = await res.text();
        return {
          status: res.status, length: text.length,
          preview: text.slice(0, 400),
          hasComments: text.includes('"comments"')
        };
      } catch (e) { return { error: String(e) }; }
    })()`);
    result.comment = comment;
    console.log(
      `[6] comment → status=${comment?.status} len=${comment?.length} ` +
        `comments=${comment?.hasComments} ${comment?.error || ''}`,
    );

    result.finishedAt = new Date().toISOString();
    fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
    console.log(`\n结果已写入 ${OUT}`);

    if (detail?.hasAwemeDetail) {
      console.log('\n✅ detail 在真实浏览器上下文中成功');
      process.exitCode = 0;
    } else {
      console.log('\n❌ detail 在真实浏览器上下文中仍未成功');
      process.exitCode = 2;
    }
  } finally {
    try {
      cdp?.ws?.close();
    } catch {}
    try {
      child.kill();
    } catch {}
  }
}

main().catch((e) => {
  console.error('FATAL', e);
  process.exitCode = 1;
});
