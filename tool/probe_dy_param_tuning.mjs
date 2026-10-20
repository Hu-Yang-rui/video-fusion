/**
 * 调通 watchlater/upsert 与 collects/video/list 的参数。
 *
 * # 现状（上一轮实测，正式 UIFID，未登录）
 *
 * | 端点 | 结果 | 含义 |
 * |---|---|---|
 * | `watchlater/upsert` | `code=1 参数错误` | 路由对，参数错 |
 * | `watchlater/remove` | `code=1 参数错误` | 同上 |
 * | `collects/video/list` | `code=4` | 路由对，参数错 |
 *
 * # 本轮做法
 *
 * 参数错误时，平台通常**不告诉你缺什么**。所以：
 *  1. 从 bundle 里挖这些端点**附近的参数字面量**（前端拼参数的地方）
 *  2. 枚举参数组合逐个试，看哪种能越过 `code=1`
 *
 * 注意：**未登录**。若某组合返回 `code=8 用户未登录`，
 * 说明参数已经对了（越过参数校验，进入登录校验）——这就是成功信号。
 *
 * 用法：node tool/probe_dy_param_tuning.mjs [awemeId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const AWEME_ID = process.argv[2] || '7345492945006595379';
const OUT = path.join('tool', '_dy_param_tuning.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9349;
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
  const result = { awemeId: AWEME_ID, startedAt: new Date().toISOString(), probes: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-pt-${Date.now()}`);
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

    console.log('[1] 打开视频页取正式 UIFID ...');
    await cdp.send('Page.navigate', {
      url: `https://www.douyin.com/video/${AWEME_ID}`,
    });

    let fullAt = -1;
    for (let i = 0; i < 200; i++) {
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
      console.log('❌ 无正式 UIFID，结果不可用');
      fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
      return;
    }

    // ── 参数组合枚举 ──
    const cases = [
      // watchlater/upsert：加动作字段的各种写法
      { name: 'wl/upsert action=1', path: '/aweme/v1/web/watchlater/upsert/', method: 'POST', q: { aweme_id: AWEME_ID, action: '1' } },
      { name: 'wl/upsert type=1', path: '/aweme/v1/web/watchlater/upsert/', method: 'POST', q: { aweme_id: AWEME_ID, type: '1' } },
      { name: 'wl/upsert item_ids', path: '/aweme/v1/web/watchlater/upsert/', method: 'POST', q: { item_ids: AWEME_ID } },
      { name: 'wl/upsert aweme_ids', path: '/aweme/v1/web/watchlater/upsert/', method: 'POST', q: { aweme_ids: `["${AWEME_ID}"]` } },
      { name: 'wl/upsert action+type', path: '/aweme/v1/web/watchlater/upsert/', method: 'POST', q: { aweme_id: AWEME_ID, action: '1', type: '1' } },
      { name: 'wl/upsert GET', path: '/aweme/v1/web/watchlater/upsert/', method: 'GET', q: { aweme_id: AWEME_ID, action: '1' } },

      // watchlater/remove
      { name: 'wl/remove aweme_id', path: '/aweme/v1/web/watchlater/remove/', method: 'POST', q: { aweme_id: AWEME_ID } },
      { name: 'wl/remove item_ids', path: '/aweme/v1/web/watchlater/remove/', method: 'POST', q: { item_ids: AWEME_ID } },
      { name: 'wl/remove aweme_ids', path: '/aweme/v1/web/watchlater/remove/', method: 'POST', q: { aweme_ids: `["${AWEME_ID}"]` } },

      // collects/video/list：加 collects_id 各种写法
      { name: 'cv/list collects_id', path: '/aweme/v1/web/collects/video/list/', method: 'GET', q: { collects_id: '0', count: '10', cursor: '0' } },
      { name: 'cv/list collects_id_str', path: '/aweme/v1/web/collects/video/list/', method: 'GET', q: { collects_id_str: '0', count: '10', cursor: '0' } },
      { name: 'cv/list no id', path: '/aweme/v1/web/collects/video/list/', method: 'GET', q: { count: '10', cursor: '0' } },
      { name: 'cv/list +collects_name', path: '/aweme/v1/web/collects/video/list/', method: 'GET', q: { collects_id: '0', collects_name: '', count: '10', cursor: '0' } },

      // 对照：已知 code=8 的端点，验证参数形态正确
      { name: 'collects/list (对照)', path: '/aweme/v1/web/collects/list/', method: 'GET', q: { count: '10', cursor: '0' } },
    ];

    console.log('\n[3] 参数组合枚举（目标：越过 code=1/4，到达 code=8 登录校验）...\n');
    for (const c of cases) {
      const params = { ...base(), ...c.q };
      const r = await evalJs(`(async () => {
        const p = new URLSearchParams(${JSON.stringify(params)}).toString();
        const url = 'https://www.douyin.com' + ${JSON.stringify(c.path)} + '?' + p;
        try {
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 14000);
          const res = await fetch(url, {
            method: ${JSON.stringify(c.method)},
            credentials: 'include',
            headers: { Referer: location.href },
            signal: ctrl.signal,
          });
          clearTimeout(t);
          const text = await res.text();
          let parsed = null;
          try { parsed = JSON.parse(text); } catch {}
          return {
            status: res.status, len: text.length,
            statusCode: parsed ? parsed.status_code : null,
            statusMsg: parsed ? parsed.status_msg : null,
            preview: text.slice(0, 200),
          };
        } catch(e) { return { error: String(e) }; }
      })()`);

      const row = { case: c.name, path: c.path, method: c.method, ...r };
      result.probes.push(row);

      // 关键判据：code=8 表示参数已对（进到登录校验）
      const code = r?.statusCode;
      const verdict =
        code === 8 ? '✅ 参数正确(需登录)' :
        code === 0 ? '✅ 成功' :
        code === 1 ? '❌ 仍参数错误' :
        code === 4 ? '❌ 仍 code=4' :
        r?.error ? 'ERR' : `?(${code})`;

      console.log(
        `${verdict.padEnd(18)} ${c.name.padEnd(26)} ` +
          `HTTP=${String(r?.status).padEnd(4)} code=${String(code).padEnd(5)} ${r?.statusMsg || ''} ${r?.error || ''}`,
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
