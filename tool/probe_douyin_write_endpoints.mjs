/**
 * 探测抖音 Web 端写操作接口的真实拦截形态。
 *
 * # 要回答的问题
 *
 * 上一轮已证明：正式 UIFID 下**读接口**（detail/comment/related/feed）可用。
 * 但点赞 / 收藏 / 关注 / 私信 / 稍后再看 / 直播互动都是**写操作**，
 * 它们走的是另一批端点。必须先搞清楚拦截形态：
 *
 *   A) `status_code=2483 / 8` 之类「请先登录」 → **可以实现**（需登录态）
 *   B) HTTP 403 `Blocked by ArgusSecurityPlugin` → 需要 App 端签名，不可实现
 *   C) 空 body / 200 但无数据 → 静默拒绝，不可归因
 *   D) 路由 404 → 端点不存在，换路径
 *
 * **本脚本不携带任何登录态**，因此不会真的修改任何账号数据。
 * 未登录时写操作必然被拒，这正是我们要观察的形态。
 *
 * 用法：node tool/probe_douyin_write_endpoints.mjs [awemeId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const AWEME_ID = process.argv[2] || '7345492945006595379';
const OUT = path.join('tool', '_dy_write_endpoints.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9337;
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
  const result = { awemeId: AWEME_ID, startedAt: new Date().toISOString(), probes: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-w-${Date.now()}`);
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

    console.log(`[1] 打开视频页以获取正式 UIFID ...`);
    await cdp.send('Page.navigate', {
      url: `https://www.douyin.com/video/${AWEME_ID}`,
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

    let fullUifidAtMs = -1;
    for (let i = 0; i < 120; i++) {
      await sleep(500);
      const { cookies } = await cdp.send('Network.getAllCookies');
      if (cookies.some((c) => c.name === 'UIFID')) {
        fullUifidAtMs = i * 500;
        break;
      }
    }
    result.fullUifidAtMs = fullUifidAtMs;
    console.log(`[2] 正式 UIFID @ ${fullUifidAtMs}ms`);
    if (fullUifidAtMs < 0) {
      console.log('❌ 无正式 UIFID，中止');
      fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
      return;
    }

    // 探测是否有登录态（未登录时这些写操作会被拒，正好观察形态）
    const loginProbe = await evalJs(`(async () => {
      try {
        const res = await fetch('/aweme/v1/web/im/user/info/?device_platform=webapp&aid=6383', {credentials:'include'});
        const t = await res.text();
        return { status: res.status, len: t.length, preview: t.slice(0,200) };
      } catch(e){ return { error: String(e) }; }
    })()`);
    result.loginProbe = loginProbe;

    const base = commonParams();
    const cases = [
      // ── 点赞 ──
      {
        group: '点赞',
        name: 'commit/item/digg (POST)',
        path: '/aweme/v1/web/commit/item/digg/',
        method: 'POST',
        params: { aweme_id: AWEME_ID, item_type: '0', type: '1' },
      },
      {
        group: '点赞',
        name: 'commit/item/digg (GET)',
        path: '/aweme/v1/web/commit/item/digg/',
        method: 'GET',
        params: { aweme_id: AWEME_ID, item_type: '0', type: '1' },
      },
      // ── 收藏 ──
      {
        group: '收藏',
        name: 'aweme/collect (POST)',
        path: '/aweme/v1/web/aweme/collect/',
        method: 'POST',
        params: { aweme_id: AWEME_ID, action: '1' },
      },
      {
        group: '收藏',
        name: 'aweme/favorite (POST)',
        path: '/aweme/v1/web/aweme/favorite/',
        method: 'POST',
        params: { aweme_id: AWEME_ID, type: '1' },
      },
      {
        group: '收藏',
        name: 'aweme/collect/list (GET)',
        path: '/aweme/v1/web/aweme/collect/list/',
        method: 'GET',
        params: { count: '10', cursor: '0' },
      },
      // ── 关注 ──
      {
        group: '关注',
        name: 'commit/follow/user (POST)',
        path: '/aweme/v1/web/commit/follow/user/',
        method: 'POST',
        params: { user_id: '0', sec_user_id: '', type: '1', channel_id: '0' },
      },
      // ── 私信 ──
      {
        group: '私信',
        name: 'im/thread/list (GET)',
        path: '/aweme/v1/web/im/thread/list/',
        method: 'GET',
        params: { count: '10', cursor: '0' },
      },
      {
        group: '私信',
        name: 'im/user/info (GET)',
        path: '/aweme/v1/web/im/user/info/',
        method: 'GET',
        params: {},
      },
      {
        group: '私信',
        name: 'im/message/send (POST)',
        path: '/aweme/v1/web/im/message/send/',
        method: 'POST',
        params: { to_user_id: '0', content: 'probe', message_type: '7' },
      },
      // ── 稍后再看 ──
      {
        group: '稍后再看',
        name: 'watch/later/list (GET)',
        path: '/aweme/v1/web/watch/later/list/',
        method: 'GET',
        params: { count: '10', cursor: '0' },
      },
      {
        group: '稍后再看',
        name: 'aweme/watch/later (POST)',
        path: '/aweme/v1/web/aweme/watch/later/',
        method: 'POST',
        params: { aweme_id: AWEME_ID, action: '1' },
      },
      // ── 直播互动 ──
      {
        group: '直播互动',
        name: 'live/room/chat (POST)',
        path: '/webcast/room/chat/',
        method: 'POST',
        params: { room_id: '0', content: 'probe' },
        host: 'https://live.douyin.com',
      },
      {
        group: '直播互动',
        name: 'webcast/like (POST)',
        path: '/webcast/room/like/',
        method: 'POST',
        params: { room_id: '0', count: '1' },
        host: 'https://live.douyin.com',
      },
    ];

    console.log('\n[3] 写操作端点探测（未登录，不会修改任何数据）...\n');
    for (const c of cases) {
      const params = { ...base, ...c.params };
      const host = c.host || 'https://www.douyin.com';
      let r;
      try {
        r = await evalJs(`(async () => {
          const qs = new URLSearchParams(${JSON.stringify(params)}).toString();
          const url = ${JSON.stringify(host)} + ${JSON.stringify(c.path)} + '?' + qs;
          try {
            const ctrl = new AbortController();
            const timer = setTimeout(() => ctrl.abort(), 15000);
            const res = await fetch(url, {
              method: ${JSON.stringify(c.method)},
              credentials: 'include',
              headers: { Referer: location.href },
              signal: ctrl.signal,
            });
            clearTimeout(timer);
            const text = await res.text();
            let parsed = null;
            try { parsed = JSON.parse(text); } catch {}
            return {
              status: res.status,
              length: text.length,
              statusCode: parsed ? (parsed.status_code ?? null) : null,
              statusMsg: parsed ? (parsed.status_msg ?? null) : null,
              preview: text.slice(0, 260),
            };
          } catch(e) { return { error: String(e), name: e && e.name }; }
        })()`);
      } catch (e) {
        // CDP 层超时：记录后继续，不中断整轮探测
        r = { error: `CDP: ${e.message}` };
      }
      if (!r || typeof r !== 'object') r = { error: 'no result' };

      const row = { group: c.group, name: c.name, path: c.path, method: c.method, ...r };
      result.probes.push(row);

      // 归类拦截形态
      let verdict;
      if (r.error) verdict = 'ERR';
      else if (r.status === 403) verdict = 'B-ARGUS';
      else if (r.length === 0) verdict = 'C-EMPTY';
      else if (r.statusCode === 8 || r.statusCode === 2483) verdict = 'A-NEED-LOGIN';
      else if (r.status === 404) verdict = 'D-404';
      else verdict = `?(${r.statusCode})`;

      console.log(
        `${verdict.padEnd(13)} ${c.group.padEnd(6)} ${c.name.padEnd(28)} ` +
          `HTTP=${String(r.status).padEnd(4)} len=${String(r.length).padEnd(6)} ` +
          `code=${r.statusCode} ${r.statusMsg ? 'msg=' + r.statusMsg : ''} ${r.error || ''}`,
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
