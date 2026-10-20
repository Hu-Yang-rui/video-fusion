/**
 * 追踪抖音页面的真实接口调用与 UIFID 升级过程。
 *
 * # 背景（上一轮实验结论）
 *
 * 同一真实 Chromium 上下文里：
 *   - `comment/list` → 200 / 16KB ✅
 *   - `aweme/detail` → 403 `Blocked by ArgusSecurityPlugin Uifid Not Found` ❌
 *
 * 且 Cookie 里只有 **`UIFID_TEMP`**（临时），没有正式 `UIFID`。
 *
 * 假设：detail 需要**完整 UIFID**（由平台风控在更完整的会话中下发），
 * 而 comment 只需要 `UIFID_TEMP` + `a_bogus` 签名。
 *
 * # 本脚本要做的事
 *
 * 1. 监听页面的所有 `/aweme/v1/web/` 请求 —— 看页面**自己**调了哪些接口，
 *    特别是它用什么路径拿视频详情（如果有）。
 * 2. 长时间观察 Cookie：`UIFID_TEMP` 是否升级为 `UIFID`，多久。
 * 3. 若出现正式 `UIFID`，立刻重试 detail，看是否放行。
 *
 * 用法：node tool/probe_douyin_uifid_upgrade.mjs [awemeId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const AWEME_ID = process.argv[2] || '7345492945006595379';
const OUT = path.join('tool', '_dy_uifid_upgrade.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9334;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.handlers = [];
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
      if (msg.method) {
        for (const h of this.handlers) h(msg);
      }
    });
  }

  on(fn) {
    this.handlers.push(fn);
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
      }, 120000);
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
    startedAt: new Date().toISOString(),
    cookieTimeline: [],
    awemeRequests: [],
  };

  const userDataDir = path.join(os.tmpdir(), `dy-cdp2-${Date.now()}`);
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

    const listRes = await fetch(`http://127.0.0.1:${PORT}/json/list`);
    const targets = await listRes.json();
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

    // 记录页面自己的 /aweme/v1/web/ 请求
    cdp.on((msg) => {
      if (msg.method === 'Network.requestWillBeSent') {
        const url = msg.params?.request?.url || '';
        if (url.includes('/aweme/v1/web/')) {
          const p = url.split('/aweme/v1/web/')[1]?.split('?')[0];
          result.awemeRequests.push({ path: p, ts: Date.now() });
        }
      }
      if (msg.method === 'Network.responseReceived') {
        const url = msg.params?.response?.url || '';
        if (url.includes('/aweme/v1/web/')) {
          const p = url.split('/aweme/v1/web/')[1]?.split('?')[0];
          result.awemeRequests.push({
            path: p,
            status: msg.params.response.status,
            ts: Date.now(),
          });
        }
      }
    });

    await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `try{Object.defineProperty(navigator,'webdriver',{get:()=>undefined})}catch(e){}`,
    });

    const target = `https://www.douyin.com/video/${AWEME_ID}`;
    console.log(`[1] 打开 ${target}`);
    await cdp.send('Page.navigate', { url: target });

    const evalJs = async (expression) => {
      const r = await cdp.send('Runtime.evaluate', {
        expression,
        awaitPromise: true,
        returnByValue: true,
      });
      if (r.exceptionDetails) return { __exception: r.exceptionDetails.text };
      return r.result?.value;
    };

    // 长时间观察 Cookie 变化（最多 90 秒）
    const seen = new Set();
    let fullUifid = false;
    let fullUifidAtMs = -1;

    console.log('[2] 观察 Cookie 变化（最多 90s）...');
    for (let i = 0; i < 180; i++) {
      await sleep(500);
      const { cookies } = await cdp.send('Network.getAllCookies');
      const names = cookies.map((c) => c.name);
      const key = names.sort().join(',');
      if (!seen.has(key)) {
        seen.add(key);
        result.cookieTimeline.push({ atMs: i * 500, names });
        console.log(`    +${i * 500}ms  cookies: ${names.join(', ')}`);
      }
      // 正式 UIFID：名字恰好是 UIFID（不是 UIFID_TEMP / UIFID_XXX）
      if (names.includes('UIFID')) {
        fullUifid = true;
        fullUifidAtMs = i * 500;
        console.log(`    ✅ 正式 UIFID 出现 @ ${fullUifidAtMs}ms`);
        break;
      }
      // 页面加载完 + 有交互也可能触发升级：中途滚动一下
      if (i === 20) {
        await evalJs('window.scrollTo(0, 400)');
      }
    }

    result.hasFullUifid = fullUifid;
    result.fullUifidAtMs = fullUifidAtMs;

    // 无论有没有正式 UIFID，都试一次 detail
    const detailParams = { ...commonParams(), aweme_id: AWEME_ID };
    console.log('[3] 请求 detail ...');
    const detail = await evalJs(`(async () => {
      const qs = new URLSearchParams(${JSON.stringify(detailParams)}).toString();
      const url = 'https://www.douyin.com/aweme/v1/web/aweme/detail/?' + qs;
      try {
        const res = await fetch(url, { credentials:'include',
          headers:{ Referer: location.href }});
        const text = await res.text();
        return { status: res.status, length: text.length,
          preview: text.slice(0,600),
          hasAwemeDetail: text.includes('"aweme_detail"') };
      } catch(e) { return { error:String(e) }; }
    })()`);
    result.detail = detail;
    console.log(
      `[4] detail → status=${detail?.status} len=${detail?.length} ` +
        `aweme_detail=${detail?.hasAwemeDetail} ${detail?.error || ''}`,
    );

    // 统计页面自己调了哪些 aweme 接口
    const paths = {};
    for (const r of result.awemeRequests) {
      const k = r.path || '?';
      paths[k] = paths[k] || { requests: 0, responses: [] };
      if (r.status !== undefined) {
        paths[k].responses.push(r.status);
      } else {
        paths[k].requests++;
      }
    }
    result.awemePathSummary = paths;
    console.log('\n[5] 页面自身调用的 /aweme/v1/web/ 接口：');
    for (const [p, v] of Object.entries(paths)) {
      console.log(
        `    ${p}  req=${v.requests} resp=[${v.responses.join(',')}]`,
      );
    }

    result.finishedAt = new Date().toISOString();
    fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
    console.log(`\n结果已写入 ${OUT}`);
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
