// 用 CDP 抓红果播放页的真实网络请求。
//
// # 目的
//
// 官网公开路径只有 360p，但外部证据（hongguo-desktop-releases）说
// 1080p 存在且通过「公开游客播放请求参数」拿到。
//
// 静态分析 bundle 找不到取流逻辑（懒加载 chunk），因此直接抓真实请求。
//
// # 跑法
//
//   node tool/capture_hongguo_player.mjs
//
// 需要本机 Chrome。

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9333;
const PLAYER_URL =
  'https://hongguoduanju.com/player/7503745441910017049';

const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hg-cdp-'));

const chrome = spawn(
  CHROME,
  [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${userDataDir}`,
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1280,900',
    PLAYER_URL,
  ],
  { stdio: 'ignore', detached: false },
);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getTargets() {
  for (let i = 0; i < 30; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const list = await r.json();
      const page = list.find((t) => t.type === 'page');
      if (page) return page;
    } catch {}
    await sleep(500);
  }
  return null;
}

const page = await getTargets();
if (!page) {
  console.log('无法连接 Chrome');
  chrome.kill();
  process.exit(1);
}
console.log('已连接页面:', page.url);

// 用 CDP WebSocket
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0;
const pending = new Map();
const requests = [];

ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg.result);
    pending.delete(msg.id);
    return;
  }
  if (msg.method === 'Network.requestWillBeSent') {
    const req = msg.params.request;
    requests.push({
      url: req.url,
      method: req.method,
      headers: req.headers,
      postData: req.postData,
      type: msg.params.type,
    });
  }
});

function send(method, params = {}) {
  const msgId = ++id;
  return new Promise((resolve) => {
    pending.set(msgId, resolve);
    ws.send(JSON.stringify({ id: msgId, method, params }));
  });
}

await new Promise((resolve) => ws.addEventListener('open', resolve));

await send('Network.enable');
await send('Page.enable');

// 重新加载，确保抓到全部请求
await send('Page.navigate', { url: PLAYER_URL });
console.log('等待页面加载与播放器初始化…');
await sleep(12000);

// 尝试点击播放按钮触发取流
await send('Runtime.evaluate', {
  expression: `
    (function(){
      const v = document.querySelector('video');
      if (v) { v.muted = true; v.play().catch(()=>{}); return 'video.play()'; }
      const btn = document.querySelector('[class*=play]');
      if (btn) { btn.click(); return 'click play btn'; }
      return 'no player found';
    })()
  `,
  returnByValue: true,
}).then((r) => console.log('触发播放:', r?.result?.value));

await sleep(8000);

ws.close();
chrome.kill();

// ── 分析结果 ──────────────────────────────────────────────
const out = path.join(process.env.TEMP || '.', 'hg_player_requests.json');
fs.writeFileSync(out, JSON.stringify(requests, null, 2), 'utf8');

console.log(`\n共抓到 ${requests.length} 个请求，已存 ${out}\n`);

const interesting = requests.filter((r) => {
  const u = r.url;
  return (
    /\.(mp4|m3u8|m4s|ts)(\?|$)/i.test(u) ||
    /video|play|series|item|episode/i.test(u) ||
    /qznovelvod|volcengineapi|byteplusapi|vod/i.test(u)
  );
});

console.log('=== 视频/播放相关请求 ===');
const seen = new Set();
for (const r of interesting) {
  const key = r.url.split('?')[0];
  if (seen.has(key)) continue;
  seen.add(key);
  console.log(`\n${r.method} ${r.url.slice(0, 160)}`);
  if (r.postData) {
    console.log('  body:', String(r.postData).slice(0, 300));
  }
  // 打印关键请求头
  for (const [k, v] of Object.entries(r.headers)) {
    if (/auth|token|sign|referer|origin|x-/i.test(k)) {
      console.log(`  ${k}: ${String(v).slice(0, 100)}`);
    }
  }
}

// 找清晰度信息
console.log('\n=== 响应里出现的清晰度标记 ===');
const quals = new Set();
for (const r of requests) {
  for (const q of ['1080', '720', '540', '480', '360']) {
    if (r.url.includes(q)) quals.add(q);
  }
}
console.log([...quals].join(', ') || '(URL 里没有清晰度标记)');
