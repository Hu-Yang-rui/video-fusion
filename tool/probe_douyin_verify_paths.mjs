/**
 * 验证从 bundle 挖出的真实端点（私信 / 稍后再看 / 收藏夹）。
 *
 * # 前置
 *
 * 上一轮从抖音前端 bundle 里挖到真实路径，关键发现：
 *  - 私信**不在** `/aweme/v1/web/im/` 下，而是根路径 `/im/...`
 *  - 稍后再看是 `/aweme/v1/web/watchlater/{list,upsert,remove}/`
 *  - 收藏夹是 `/aweme/v1/web/collects/{list,maintain,video/list}/`
 *
 * 这解释了为什么之前的 `/aweme/v1/web/im/thread/list/` 全 404。
 *
 * 用法：node tool/probe_douyin_verify_paths.mjs [awemeId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const AWEME_ID = process.argv[2] || '7345492945006595379';
const OUT = path.join('tool', '_dy_verify_paths.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9340;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function base() {
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
  const result = { startedAt: new Date().toISOString(), probes: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-v-${Date.now()}`);
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

    const evalJs = async (expression) =>
      cdp
        .send('Runtime.evaluate', {
          expression,
          awaitPromise: true,
          returnByValue: true,
        })
        .then((r) => (r.exceptionDetails ? { __exception: r.exceptionDetails.text } : r.result?.value))
        .catch((e) => ({ error: `CDP: ${e.message}` }));

    console.log('[1] 打开视频页取正式 UIFID ...');
    await cdp.send('Page.navigate', {
      url: `https://www.douyin.com/video/${AWEME_ID}`,
    });

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
    if (fullAt < 0) {
      console.log('❌ 无正式 UIFID');
      fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
      return;
    }

    const cases = [
      // ── 私信（根路径 /im/）──
      { g: '私信', n: 'im/conversation/list_visible', p: '/im/conversation/list_visible/', m: 'GET', q: { count: '20', cursor: '0' } },
      { g: '私信', n: 'im/fetch', p: '/im/fetch/', m: 'GET', q: { count: '20', cursor: '0' } },
      { g: '私信', n: 'im/fetch/history', p: '/im/fetch/history/', m: 'GET', q: { count: '20', cursor: '0' } },
      { g: '私信', n: 'im/token', p: '/im/token/', m: 'GET', q: {} },
      { g: '私信', n: 'im/user/info', p: '/im/user/info/', m: 'GET', q: {} },
      { g: '私信', n: 'im/recent/sticker/fetch', p: '/im/recent/sticker/fetch/', m: 'GET', q: {} },
      { g: '私信', n: 'im/resource/sticker/collect', p: '/im/resource/sticker/collect/', m: 'GET', q: {} },

      // ── 稍后再看 ──
      { g: '稍后再看', n: 'watchlater/list', p: '/aweme/v1/web/watchlater/list/', m: 'GET', q: { count: '10', cursor: '0' } },
      { g: '稍后再看', n: 'watchlater/upsert', p: '/aweme/v1/web/watchlater/upsert/', m: 'POST', q: { aweme_id: AWEME_ID, action: '1' } },
      { g: '稍后再看', n: 'watchlater/remove', p: '/aweme/v1/web/watchlater/remove/', m: 'POST', q: { aweme_id: AWEME_ID } },
      { g: '稍后再看', n: 'history/read', p: '/aweme/v1/web/history/read/', m: 'GET', q: { count: '10', cursor: '0' } },

      // ── 收藏夹 ──
      { g: '收藏夹', n: 'collects/list', p: '/aweme/v1/web/collects/list/', m: 'GET', q: { count: '10', cursor: '0' } },
      { g: '收藏夹', n: 'collects/video/list', p: '/aweme/v1/web/collects/video/list/', m: 'GET', q: { count: '10', cursor: '0' } },
      { g: '收藏夹', n: 'aweme/listcollection', p: '/aweme/v1/web/aweme/listcollection/', m: 'GET', q: { count: '10', cursor: '0' } },
      { g: '收藏夹', n: 'favorite/list', p: '/aweme/v1/web/favorite/list/', m: 'GET', q: { count: '10', cursor: '0' } },
      { g: '收藏夹', n: 'aweme/collect (写)', p: '/aweme/v1/web/aweme/collect/', m: 'POST', q: { aweme_id: AWEME_ID, action: '1' } },

      // ── 关注 / 点赞（已知 code=8）──
      { g: '关注', n: 'user/following/list', p: '/aweme/v1/web/user/following/list/', m: 'GET', q: { count: '10', cursor: '0' } },
      { g: '点赞', n: 'notice/digg/list', p: '/aweme/v1/web/notice/digg/list/', m: 'GET', q: { count: '10', cursor: '0' } },

      // ── 直播互动 ──
      { g: '直播', n: 'webcast/room/like', p: '/webcast/room/like/', m: 'POST', q: { room_id: '0', count: '1' }, host: 'https://live.douyin.com' },
      { g: '直播', n: 'webcast/room/chat', p: '/webcast/room/chat/', m: 'POST', q: { room_id: '0', content: 'probe' }, host: 'https://live.douyin.com' },
    ];

    console.log('\n[3] 验证端点 ...\n');
    for (const c of cases) {
      const params = { ...base(), ...c.q };
      const host = c.host || 'https://www.douyin.com';
      const r = await evalJs(`(async () => {
        const qs = new URLSearchParams(${JSON.stringify(params)}).toString();
        const url = ${JSON.stringify(host)} + ${JSON.stringify(c.p)} + '?' + qs;
        try {
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 14000);
          const res = await fetch(url, {
            method: ${JSON.stringify(c.m)},
            credentials: 'include',
            headers: { Referer: location.href },
            signal: ctrl.signal,
          });
          clearTimeout(t);
          const text = await res.text();
          let parsed = null;
          try { parsed = JSON.parse(text); } catch {}
          return {
            status: res.status, length: text.length,
            statusCode: parsed ? (parsed.status_code ?? null) : null,
            statusMsg: parsed ? (parsed.status_msg ?? null) : null,
            hasData: parsed ? (parsed.data !== undefined && parsed.data !== null) : false,
            preview: text.slice(0, 200),
          };
        } catch(e) { return { error: String(e) }; }
      })()`);

      const row = { group: c.g, name: c.n, path: c.p, method: c.m, ...r };
      result.probes.push(row);

      const tag =
        r?.status === 404 ? 'D-404' :
        r?.error ? 'ERR' :
        r?.status === 403 ? 'B-ARGUS' :
        r?.statusCode === 8 || r?.statusCode === 2483 ? 'A-NEED-LOGIN' :
        r?.status === 200 ? 'OK' : `?(${r?.status})`;

      console.log(
        `${tag.padEnd(12)} ${c.g.padEnd(5)} ${c.n.padEnd(28)} ` +
          `HTTP=${String(r?.status).padEnd(4)} len=${String(r?.length).padEnd(6)} ` +
          `code=${r?.statusCode} ${r?.statusMsg || ''} ${r?.error || ''}`,
      );
      await sleep(400);
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
