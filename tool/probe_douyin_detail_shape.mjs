/**
 * 验证 detail 响应能否直接驱动播放（play_addr / 清晰度 / 时长）。
 *
 * 前置：`tool/probe_douyin_argus_matrix.mjs` 已证明 detail 在正式 UIFID 下
 * 返回 200 + 52KB + `aweme_detail`。
 *
 * 本脚本抓取 detail 的关键字段，确认：
 *  1. `play_addr.url_list` 是否为可直接播放的 mp4 直链
 *  2. `video.bit_rate` 有几档清晰度（供直播/长视频清晰度 UI 使用）
 *  3. `duration` / 封面 / 作者 / 统计 是否齐全
 *
 * 用法：node tool/probe_douyin_detail_shape.mjs [awemeId]
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const AWEME_ID = process.argv[2] || '7345492945006595379';
const OUT = path.join('tool', '_dy_detail_shape.json');

const CHROME =
  process.env.DY_CHROME ||
  path.join(
    os.homedir(),
    'AppData/Local/ms-playwright/chromium-1234/chrome-win64/chrome.exe',
  );

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PORT = 9336;
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
  const result = { awemeId: AWEME_ID, startedAt: new Date().toISOString() };

  const userDataDir = path.join(os.tmpdir(), `dy-cdp4-${Date.now()}`);
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

    console.log(`[1] 打开视频页 ...`);
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

    // 等正式 UIFID
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
      console.log('❌ 无正式 UIFID');
      fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8');
      return;
    }

    const params = { ...commonParams(), aweme_id: AWEME_ID };
    console.log('[3] 请求 detail 并提取结构 ...');
    const shape = await evalJs(`(async () => {
      const qs = new URLSearchParams(${JSON.stringify(params)}).toString();
      const url = 'https://www.douyin.com/aweme/v1/web/aweme/detail/?' + qs;
      const res = await fetch(url, { credentials:'include',
        headers:{ Referer: location.href }});
      const json = await res.json();
      const d = json.aweme_detail;
      if (!d) return { status: res.status, noDetail: true, keys: Object.keys(json) };
      const v = d.video || {};
      const play = v.play_addr || {};
      const cover = v.cover || {};
      const author = d.author || {};
      const stats = d.statistics || {};
      return {
        status: res.status,
        awemeId: d.aweme_id,
        desc: (d.desc || '').slice(0, 120),
        createTime: d.create_time,
        duration: v.duration,
        width: v.width,
        height: v.height,
        ratio: v.ratio,
        playUrlCount: (play.url_list || []).length,
        playUrlSample: (play.url_list || [])[0] || null,
        playUri: play.uri || null,
        dataSize: play.data_size || null,
        coverUrl: ((cover.url_list || [])[0]) || null,
        authorName: author.nickname || null,
        authorUid: author.uid || null,
        authorSecUid: author.sec_uid || null,
        avatar: ((author.avatar_thumb?.url_list || [])[0]) || null,
        stats: {
          digg: stats.digg_count, comment: stats.comment_count,
          play: stats.play_count, share: stats.share_count,
          collect: stats.collect_count,
        },
        bitRateCount: (v.bit_rate || []).length,
        bitRates: (v.bit_rate || []).slice(0, 6).map(b => ({
          gear: b.gear_name,
          quality: b.quality_type,
          bitRate: b.bit_rate,
          w: b.play_addr?.width, h: b.play_addr?.height,
          hasUrl: ((b.play_addr?.url_list || []).length) > 0,
          firstUrl: ((b.play_addr?.url_list || [])[0] || '').slice(0, 100),
        })),
        musicTitle: d.music?.title || null,
        isImage: Array.isArray(d.images) && d.images.length > 0,
        imageCount: (d.images || []).length,
      };
    })()`);

    result.shape = shape;

    console.log('\n[4] detail 结构：');
    console.log(JSON.stringify(shape, null, 2).slice(0, 3000));

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
