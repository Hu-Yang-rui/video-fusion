/**
 * 在**正式 UIFID 就绪**后，测一遍受 Argus 保护的接口矩阵。
 *
 * # 前置结论（已实证）
 *
 * - `UIFID_TEMP` 在 ~500ms 出现，`UIFID`（正式）在 ~4000ms 出现
 * - 有正式 UIFID 后 `aweme/detail` → 200 / 54KB / 有 `aweme_detail`
 * - 页面自身还调用了 `aweme/related/`、`danmaku/get_v2/`、`emoji/list` 等
 *
 * 本脚本回答：**拿到正式 UIFID 后，哪些接口真正可用**。
 *
 * 用法：node tool/probe_douyin_argus_matrix.mjs [awemeId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const AWEME_ID = process.argv[2] || '7345492945006595379';
const OUT = path.join('tool', '_dy_argus_matrix.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9335;
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
  const result = {
    awemeId: AWEME_ID,
    startedAt: new Date().toISOString(),
    probes: [],
  };

  const userDataDir = path.join(os.tmpdir(), `dy-cdp3-${Date.now()}`);
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

    // 等正式 UIFID（精确名）
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
      console.log('❌ 未拿到正式 UIFID，后续探测无意义');
      fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
      return;
    }

    // ── 接口矩阵 ──────────────────────────────────────────
    const base = commonParams();
    const cases = [
      {
        name: 'detail',
        path: '/aweme/v1/web/aweme/detail/',
        params: { aweme_id: AWEME_ID },
        expectKey: 'aweme_detail',
      },
      {
        name: 'comment/list',
        path: '/aweme/v1/web/comment/list/',
        params: { aweme_id: AWEME_ID, cursor: '0', count: '5', item_type: '0' },
        expectKey: 'comments',
      },
      {
        name: 'aweme/related',
        path: '/aweme/v1/web/aweme/related/',
        params: { aweme_id: AWEME_ID, count: '10', filterGids: '' },
        expectKey: 'aweme_list',
      },
      {
        name: 'search/item',
        path: '/aweme/v1/web/general/search/single/',
        params: {
          keyword: '猫咪',
          search_channel: 'aweme_general',
          offset: '0',
          count: '10',
          search_source: 'normal_search',
        },
        expectKey: 'data',
      },
      {
        name: 'user/profile',
        path: '/aweme/v1/web/user/profile/other/',
        params: { sec_user_id: '', publish_video_strategy_type: '2' },
        expectKey: 'user',
      },
      {
        name: 'danmaku/list',
        path: '/aweme/v1/web/danmaku/get_v2/',
        params: { aweme_id: AWEME_ID, duration: '10000', start_time: '0' },
        expectKey: 'danmaku_list',
      },
      {
        name: 'emoji/list',
        path: '/aweme/v1/web/emoji/list',
        params: {},
        expectKey: 'emoji_list',
      },
      {
        name: 'hot/search',
        path: '/aweme/v1/web/hot/search/list/',
        params: {},
        expectKey: 'data',
      },
      {
        name: 'challenge/detail',
        path: '/aweme/v1/web/challenge/detail/',
        params: { cid: '1594669969041416' },
        expectKey: 'challenge_info',
      },
      {
        name: 'tab/feed',
        path: '/aweme/v1/web/tab/feed/',
        params: { count: '6', refresh_index: '1' },
        expectKey: 'aweme_list',
      },
    ];

    console.log('\n[3] 接口矩阵探测 ...\n');
    for (const c of cases) {
      const params = { ...base, ...c.params };
      const r = await evalJs(`(async () => {
        const qs = new URLSearchParams(${JSON.stringify(params)}).toString();
        const url = 'https://www.douyin.com${c.path}?' + qs;
        try {
          const res = await fetch(url, { credentials:'include',
            headers:{ Referer: location.href }});
          const text = await res.text();
          let parsed = null;
          try { parsed = JSON.parse(text); } catch {}
          return {
            status: res.status,
            length: text.length,
            hasKey: text.includes('"${c.expectKey}"'),
            statusCode: parsed ? parsed.status_code : null,
            statusMsg: parsed ? (parsed.status_msg || null) : null,
            preview: text.slice(0, 200)
          };
        } catch(e) { return { error:String(e) }; }
      })()`);

      const row = {
        name: c.name,
        path: c.path,
        ...r,
      };
      result.probes.push(row);

      const ok = r.status === 200 && r.hasKey;
      const mark = ok ? '✅' : '❌';
      console.log(
        `${mark} ${c.name.padEnd(18)} status=${String(r.status).padEnd(4)} ` +
          `len=${String(r.length).padEnd(7)} key(${c.expectKey})=${r.hasKey} ` +
          `${r.statusMsg ? 'msg=' + r.statusMsg : ''} ${r.error || ''}`,
      );

      await sleep(400); // 轻微间隔，避免触发频控
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
