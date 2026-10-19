// vf_dy_emu_nav.mjs — 导航到「直播」tab 并实播抖音直播，抓 media_kit/HEVC 真实日志
//
// 上一轮 screencap 显示 App 停在「推荐」tab（画面黑是 media_kit 在模拟器强制软渲染的已知限制），
// 没有进入直播页 → logcat 里 0 条 MediaCodec/HEVC 记录，无法回答"直播黑屏是不是解码问题"。
// 本脚本按底部导航坐标（推荐/发现/直播/我的，y≈2308）直接点「直播」，再点第一个房间，
// 然后抓 media_kit / MediaCodec / hevc / flutter(VF) 日志 + 截图。
//
// 只安装/启动/点按，不改任何代码。
//
// 运行：node tool/vf_dy_emu_nav.mjs --stay=50
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const ADB = 'D:\\android-sdk\\platform-tools\\adb.exe';
const PKG = 'com.example.video_fusion';
const argv = process.argv.slice(2);
const STAY = Number((argv.find((s) => s.startsWith('--stay=')) ?? '--stay=50').split('=')[1]) * 1000;
const sleep = (ms) => { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { const e = Date.now() + ms; while (Date.now() < e) { } } };

function adb(args, opt = {}) {
  return execFileSync(ADB, ['-s', 'emulator-5554', ...args], {
    encoding: opt.encoding ?? 'utf8', maxBuffer: 96 * 1024 * 1024, timeout: opt.timeout ?? 60000,
  });
}
const safe = (fn, label) => { try { return fn(); } catch (e) { console.log(`  ! ${label}: ${String(e.message).split('\n')[0].slice(0, 110)}`); return null; } };
const dump = () => {
  safe(() => adb(['shell', 'rm', '-f', '/sdcard/vf.xml']), 'rm');
  safe(() => adb(['shell', 'uiautomator', 'dump', '/sdcard/vf.xml'], { timeout: 45000 }), 'uiautomator');
  return safe(() => adb(['exec-out', 'cat', '/sdcard/vf.xml'], { timeout: 30000 })) ?? '';
};
const nodes = (xml) => [...xml.matchAll(/<node[^>]*?\/>/g)].map((m) => {
  const at = (k) => (m[0].match(new RegExp(`${k}="([^"]*)"`)) ?? [])[1];
  const b = at('bounds'); const mm = b && b.match(/\[(\d+),(\d+)\]\[(\d+),(\d+)\]/);
  return { text: at('text') ?? '', desc: at('content-desc') ?? '', cls: at('class') ?? '', clickable: at('clickable'),
    x: mm ? Math.round((+mm[1] + +mm[3]) / 2) : null, y: mm ? Math.round((+mm[2] + +mm[4]) / 2) : null,
    w: mm ? +mm[3] - +mm[1] : 0, h: mm ? +mm[4] - +mm[2] : 0 };
}).filter((n) => n.x !== null);
const tap = (x, y) => safe(() => adb(['shell', 'input', 'tap', String(x), String(y)]), `tap ${x},${y}`);

console.log('=== vf_dy_emu_nav: 进入直播页实播并抓解码日志 ===');
const size = safe(() => adb(['shell', 'wm', 'size']), 'wm size');
console.log('  screen size: ' + (size ?? '?').trim());
safe(() => adb(['logcat', '-c']), 'logcat -c');
adb(['shell', 'am', 'force-stop', PKG]); sleep(1000);
safe(() => adb(['shell', 'monkey', '-p', PKG, '-c', 'android.intent.category.LAUNCHER', '1']), 'launch');
sleep(10000);

let xml = dump();
let ns = nodes(xml);
console.log(`  首屏可交互节点 ${ns.length} 个`);
// 关弹窗
for (const kw of ['我知道了', '稍后再说', '同意', '允许', '跳过', '取消']) {
  const n = ns.find((x) => (x.text || x.desc).includes(kw));
  if (n) { console.log(`  关闭弹窗: ${JSON.stringify(n.text || n.desc)}`); tap(n.x, n.y); sleep(1500); xml = dump(); ns = nodes(xml); }
}
// 点「直播」tab
const liveTab = ns.find((n) => (n.text === '直播' || n.desc === '直播') && n.y > 1800)
  ?? ns.find((n) => (n.text || '').includes('直播'));
if (!liveTab) {
  console.log('  ⚠️ 没找到「直播」tab，可见文本: ' + JSON.stringify([...new Set(ns.map((n) => n.text).filter(Boolean))].slice(0, 30)));
  // 退化：按截图坐标点第 3 个 tab
  console.log('  退化：直接点 (637, 2308)');
  tap(637, 2308); sleep(6000);
} else {
  console.log(`  点「直播」tab @${liveTab.x},${liveTab.y}`);
  tap(liveTab.x, liveTab.y); sleep(7000);
}
xml = dump(); ns = nodes(xml);
fs.writeFileSync('tool/_dy_emu_ui_live.xml', xml, 'utf8');
console.log(`  直播页节点 ${ns.length}，文本样本: ` + JSON.stringify([...new Set(ns.map((n) => n.text).filter((t) => t && t.length > 2))].slice(0, 22)));

// 点第一个房间卡片：取 y 在 300~2000 之间、面积较大的可点节点
const cards = ns.filter((n) => n.clickable === 'true' && n.w > 150 && n.h > 150 && n.y > 300 && n.y < 2100);
console.log(`  候选房间卡片 ${cards.length} 个`);
if (cards.length) {
  const c = cards[0];
  console.log(`  点第一个卡片 @${c.x},${c.y} (${c.w}x${c.h})`);
  tap(c.x, c.y);
} else {
  // 再退化：点屏幕中部
  console.log('  没找到卡片，点屏幕中部 (540,1200)');
  tap(540, 1200);
}
sleep(STAY);

// 抓日志
const log = safe(() => adb(['logcat', '-d', '-v', 'brief']), 'logcat -d') ?? '';
fs.writeFileSync('tool/_dy_emu_logcat_live.txt', log, 'utf8');
console.log(`\n=== logcat（${log.split('\n').length} 行，已存 tool/_dy_emu_logcat_live.txt）===`);
const groups = [
  ['media_kit / mpv', /media_kit|\bmpv\b|libmpv|VideoOutput|NativeReferenceHolder/i],
  ['MediaCodec / 解码器', /MediaCodec|c2\.(android|goldfish)|OMX\.google|swcodec|Codec2|media\.codec/i],
  ['HEVC / H265 / bytevc1', /hevc|h265|bytevc1/i],
  ['flutter 应用日志', /I\/flutter|E\/flutter|W\/flutter/],
  ['错误/失败', /error|fail|denied|exception|invalid|cannot|unable|403|abort/i],
];
for (const [name, re] of groups) {
  const lines = log.split('\n').filter((l) => re.test(l) && !/BestClock|ApkAssets|HWUI/.test(l));
  console.log(`\n── ${name}: ${lines.length} 行 ──`);
  for (const l of lines.slice(0, 30)) console.log('  ' + l.slice(0, 200));
  if (lines.length > 30) console.log(`  … 其余 ${lines.length - 30} 行见文件`);
}
// 截图
const cap = safe(() => execFileSync(ADB, ['-s', 'emulator-5554', 'exec-out', 'screencap', '-p'], { maxBuffer: 96 * 1024 * 1024, timeout: 30000 }), 'screencap');
if (cap) { fs.writeFileSync('tool/_dy_emu_live_cap.png', cap); console.log(`\n  截图 tool/_dy_emu_live_cap.png (${cap.length}B)`); }
// 播放器状态：读 position 是否前进（两次 dump 对比）
const xml2 = dump();
console.log('  直播页最终 UI 文本: ' + JSON.stringify([...new Set(nodes(xml2).map((n) => n.text).filter((t) => t && t.length > 1))].slice(0, 25)));
