/**
 * 直接验证：带正式 UIFID 的 webcast/im/fetch 是否仍返回空数组。
 *
 * # 背景
 *
 * 之前两次浏览器探针都失败，但失败原因已查明**与弹幕无关**：
 * 直播页在 CDP 自动化下 JS 完全不启动
 * （rootChildren=4、webcast 全局 undefined、0 个 webcast 接口调用）。
 * 这是 live.douyin.com 对自动化浏览器的检测，不是弹幕接口的问题。
 *
 * 所以换成更直接的问法：
 * **拿着正式 UIFID + 完整 cookie，直接打 im/fetch，返回什么？**
 *
 * 如果返回空数组 → 弹幕确实拿不到（与旧结论一致，但证据更强）
 * 如果返回数据 → 说明只差参数，可以实现
 *
 * 做法：用 CDP 打开 **www.douyin.com**（那个站能正常加载），
 * 拿到正式 UIFID 后，在同一页面上下文里跨域请求 live.douyin.com 的 im/fetch。
 *
 * 用法：node tool/probe_dy_danmaku_direct.mjs [roomId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const ROOM_ID = process.argv[2] || '7698331989480377128';
const OUT = path.join('tool', '_dy_danmaku_direct.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9348;
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
  const result = { roomId: ROOM_ID, startedAt: new Date().toISOString(), probes: [] };

  const userDataDir = path.join(os.tmpdir(), `dy-dd-${Date.now()}`);
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

    // 在 www.douyin.com 拿正式 UIFID（这个站能正常加载）
    console.log('[1] 打开 www.douyin.com 取正式 UIFID ...');
    await cdp.send('Page.navigate', { url: 'https://www.douyin.com/video/7345492945006595379' });

    let fullAt = -1;
    for (let i = 0; i < 200; i++) {
      await sleep(500);
      const { cookies } = await cdp.send('Network.getAllCookies');
      if (cookies.some((c) => c.name === 'UIFID' && c.domain.includes('douyin'))) {
        fullAt = i * 500;
        break;
      }
    }
    result.fullUifidAtMs = fullAt;
    console.log(`[2] 正式 UIFID @ ${fullAt}ms`);

    const { cookies } = await cdp.send('Network.getAllCookies');
    result.cookieCount = cookies.length;
    result.cookieNames = cookies.map((c) => c.name);

    // 关键：跨域请求 live.douyin.com 的 im/fetch
    // 注意 CORS：live.douyin.com 需要允许 www.douyin.com 跨域，
    // 若被 CORS 挡会得到 TypeError（这与"接口返回空"是两回事）
    const baseParams = {
      aid: '6383',
      app_name: 'douyin_web',
      device_platform: 'web',
      browser_language: 'zh-CN',
      browser_platform: 'Win32',
      browser_name: 'Chrome',
      browser_version: '124.0.0.0',
      cookie_enabled: 'true',
      screen_width: '1600',
      screen_height: '900',
      browser_online: 'true',
      room_id: ROOM_ID,
      live_id: '1',
      identity: 'audience',
      version_code: '290100',
      webcast_sdk_version: '1.0.14-beta.0',
      compress: 'gzip',
      support_wrds: '1',
    };

    // 变体：逐步加参数，看哪个组合能出数据
    const variants = [
      { name: 'minimal', params: { ...baseParams } },
      {
        name: '+cursor/heartbeat',
        params: {
          ...baseParams,
          cursor: '',
          heartbeatDuration: '0',
          need_persist_msg_count: '15',
        },
      },
      {
        name: '+user_unique_id',
        params: {
          ...baseParams,
          user_unique_id: '7698351347394004520',
          cursor: 'd-1_u-1_fh-7392091211001140287_t-1_r-1',
          internal_ext: `internal_src:dim|wss_push_room_id:${ROOM_ID}`,
        },
      },
      {
        name: '+host/endpoint',
        params: {
          ...baseParams,
          host: 'https://live.douyin.com',
          endpoint: 'live_pc',
          support_wrds: '1',
          im_path: '/webcast/im/fetch/',
          user_unique_id: '7698351347394004520',
        },
      },
    ];

    console.log('\n[3] 跨域请求 live.douyin.com/webcast/im/fetch/ ...\n');
    for (const v of variants) {
      const r = await evalJs(`(async () => {
        const p = new URLSearchParams(${JSON.stringify(v.params)}).toString();
        try {
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 18000);
          const res = await fetch('https://live.douyin.com/webcast/im/fetch/?' + p, {
            method: 'POST', credentials: 'include',
            headers: { Referer: 'https://live.douyin.com/',
              'Content-Type': 'application/x-www-form-urlencoded' },
            body: p, signal: ctrl.signal,
          });
          clearTimeout(t);
          const text = await res.text();
          let parsed = null;
          try { parsed = JSON.parse(text); } catch {}
          return {
            status: res.status, len: text.length,
            statusCode: parsed ? parsed.status_code : null,
            dataIsEmpty: parsed ? (Array.isArray(parsed.data) && parsed.data.length === 0) : null,
            dataLen: parsed && Array.isArray(parsed.data) ? parsed.data.length : null,
            hasGeneralMsg: parsed ? !!parsed.general_msg_list : null,
            preview: text.slice(0, 300),
          };
        } catch(e) {
          return { error: String(e), name: e && e.name, message: e && e.message };
        }
      })()`);

      const row = { variant: v.name, ...r };
      result.probes.push(row);
      console.log(
        `  ${v.name.padEnd(18)} status=${String(r?.status).padEnd(4)} len=${String(r?.len).padEnd(6)} ` +
          `code=${r?.statusCode} dataLen=${r?.dataLen} generalMsg=${r?.hasGeneralMsg} ${r?.error || ''}`,
      );
      if (r?.preview) console.log(`      ${r.preview.slice(0, 160)}`);
      await sleep(500);
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
