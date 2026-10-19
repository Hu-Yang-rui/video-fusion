// vf_dy_emu_live.mjs — 抖音直播在 Android 模拟器上的真实解码/黑屏取证
//
// 目的：回答"直播黑屏是 HEVC 解码问题，还是 referer/UA/其它"。
// 做法（只安装+启动+点按，不改任何代码）：
//   1) 匿名取 feed 房间 → 挑 HD1 与 FULL_HD1 两档 HLS 地址
//   2) logcat -c 清空，启动 app-debug.apk（com.example.video_fusion）
//   3) uiautomator dump 找"直播"入口并点进去，再点第一个房间
//   4) 抓 media_kit / mpv / libmpv / VF / MediaCodec / hevc 相关日志行
//   5) 同时用 screencap 存图，判断画面是否纯黑（与 position 是否前进对照）
//
// 运行：node tool/vf_dy_emu_live.mjs            # 默认在直播页停留 45s
//       node tool/vf_dy_emu_live.mjs --stay=60
import { execFileSync, execSync } from 'node:child_process';
import fs from 'node:fs';

const ADB = 'D:\\android-sdk\\platform-tools\\adb.exe';
const PKG = 'com.example.video_fusion';
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701';

const argv = process.argv.slice(2);
const numArg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? Number(a.split('=')[1]) : d; };
const STAY = numArg('stay', 45) * 1000;

function adb(args, opt = {}) {
  return execFileSync(ADB, ['-s', 'emulator-5554', ...args], {
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: opt.timeout ?? 60000, ...opt,
  });
}
function safe(fn, label) { try { return fn(); } catch (e) { console.log(`  ! ${label}: ${String(e.message).split('\n')[0].slice(0, 120)}`); return null; } }
// 同步等待（Atomics.wait 不阻塞事件循环的 fetch 语义需求，脚本本身是顺序执行）
const sleep = (ms) => { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { const end = Date.now() + ms; while (Date.now() < end) { } } };

console.log('=== vf_dy_emu_live: 模拟器实机直播播放取证 ===');
console.log('  devices:', adb(['devices']).split('\n').filter(Boolean).join(' / '));

// ── 1) 取真实房间地址 ──────────────────────────────────────────
let feed = null;
for (let i = 1; i <= 10 && !feed; i++) {
  const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&device_type=Pixel7&os_version=13&channel=googleplay&language=zh&count=12&offset=0&type=0`, {
    headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
  const t = await r.text();
  if (t.trim()) feed = JSON.parse(t);
  else sleep(300 * i);
}
const rooms = (feed?.data ?? []).map((e) => e?.data).filter(Boolean);
if (!rooms.length) { console.log('feed 无数据，终止'); process.exit(1); }
console.log(`  feed 房间数=${rooms.length}，样本 ${rooms[0].id_str} ${JSON.stringify((rooms[0].title ?? '').slice(0, 16))}`);

// ── 2) 清 logcat + 启动 App ────────────────────────────────────
safe(() => adb(['logcat', '-c']), 'logcat -c');
console.log('\n── 启动 App ──');
const launched = safe(() => adb(['shell', 'monkey', '-p', PKG, '-c', 'android.intent.category.LAUNCHER', '1']), 'monkey launch');
console.log('  ' + (launched ? launched.split('\n').filter((l) => /Events|pv-click|dbg/.test(l)).join(' | ') : '启动失败'));
sleep(9000);

const dumpUi = () => {
  // uiautomator dump 到文件再 cat：/dev/tty 方式在部分镜像上会失败
  safe(() => adb(['shell', 'rm', '-f', '/sdcard/vf_dump.xml'], { timeout: 15000 }), 'rm dump');
  const d = safe(() => adb(['shell', 'uiautomator', 'dump', '/sdcard/vf_dump.xml'], { timeout: 45000 }), 'uiautomator dump');
  if (!d || /ERROR|could not|null/i.test(d)) console.log(`  dump 输出: ${String(d).split('\n')[0].slice(0, 100)}`);
  const xml = safe(() => adb(['exec-out', 'cat', '/sdcard/vf_dump.xml'], { encoding: 'utf8', timeout: 30000 }), 'cat dump');
  return xml ?? '';
};
const findNode = (xml, text) => {
  const out = [];
  const re = new RegExp(`<node[^>]*text="[^"]*${text}[^"]*"[^>]*bounds="\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]"`, 'gi');
  for (const m of xml.matchAll(re)) {
    const x1 = +m[1], y1 = +m[2], x2 = +m[3], y2 = +m[4];
    out.push({ x: Math.round((x1 + x2) / 2), y: Math.round((y1 + y2) / 2), label: m[0].match(/text="([^"]*)"/)?.[1] ?? text });
  }
  return out;
};
const tap = (x, y) => safe(() => adb(['shell', 'input', 'tap', String(x), String(y)]), `tap ${x},${y}`);

let xml = dumpUi();
console.log(`  UI dump 长度=${xml.length}`);
if (xml.length) {
  fs.writeFileSync('tool/_dy_emu_ui1.xml', xml, 'utf8');
  // 关掉可能的弹窗/引导
  for (const kw of ['我知道了', '稍后再说', '同意', '允许', '跳过']) {
    const n = findNode(xml, kw)[0];
    if (n) { console.log(`  点掉弹窗按钮: ${JSON.stringify(n.label)} @${n.x},${n.y}`); tap(n.x, n.y); sleep(1500); xml = dumpUi(); }
  }
  const live = findNode(xml, '直播')[0] ?? findNode(xml, 'Live')[0];
  if (live) {
    console.log(`  进入直播页: ${JSON.stringify(live.label)} @${live.x},${live.y}`);
    tap(live.x, live.y); sleep(6000);
    xml = dumpUi(); fs.writeFileSync('tool/_dy_emu_ui2.xml', xml, 'utf8');
    console.log(`  直播页 dump 长度=${xml.length}`);
    // 点第一个房间卡片：找任意带 text 的可点击节点里靠下的
    const cards = [...xml.matchAll(/<node[^>]*clickable="true"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/g)]
      .map((m) => ({ x: (+m[1] + +m[3]) / 2, y: (+m[2] + +m[4]) / 2, w: +m[3] - +m[1], h: +m[4] - +m[2] }))
      .filter((c) => c.w > 100 && c.h > 100 && c.y > 200);
    if (cards.length) {
      console.log(`  点第一个房间卡片 @${Math.round(cards[0].x)},${Math.round(cards[0].y)} (共 ${cards.length} 个可点区域)`);
      tap(Math.round(cards[0].x), Math.round(cards[0].y));
    } else console.log('  没找到房间卡片');
    sleep(STAY);
    fs.writeFileSync('tool/_dy_emu_ui3.xml', dumpUi(), 'utf8');
  } else {
    console.log('  ⚠️ UI 里没找到"直播"入口（可能首屏是别的 tab）');
    const texts = [...xml.matchAll(/text="([^"]{1,18})"/g)].map((m) => m[1]).filter(Boolean);
    console.log('  可见文本: ' + JSON.stringify([...new Set(texts)].slice(0, 40)));
    sleep(STAY);
  }
}

// ── 3) 截图判断黑屏 ───────────────────────────────────────────
const png = 'tool/_dy_emu_screencap.png';
const capBuf = safe(() => execFileSync(ADB, ['-s', 'emulator-5554', 'exec-out', 'screencap', '-p'], { maxBuffer: 64 * 1024 * 1024, timeout: 30000 }), 'screencap');
if (capBuf) { fs.writeFileSync(png, capBuf); console.log(`\n  截图: ${png} (${capBuf.length} bytes)`); }

// ── 4) 抓 logcat ──────────────────────────────────────────────
console.log('\n=== logcat 关键行 ===');
const log = safe(() => adb(['logcat', '-d', '-v', 'brief']), 'logcat -d') ?? '';
fs.writeFileSync('tool/_dy_emu_logcat.txt', log, 'utf8');
console.log(`  logcat 总行数=${log.split('\n').length}，已存 tool/_dy_emu_logcat.txt`);
const pats = [
  ['mpv / media_kit', /\bmpv\b|media_kit|libmpv|MPV|player\.dart/i],
  ['解码器/MediaCodec', /MediaCodec|c2\.android|c2\.goldfish|OMX\.google|swcodec|Codec2|vppJni/i],
  ['HEVC/H265/bytevc1', /hevc|h265|bytevc1|H265|HEVC/i],
  ['App 自身日志 (VF)', /VF\s*\[|video_fusion|VideoFusion/i],
  ['Flutter 报错', /Flutter.*Error|E\/flutter|Exception|Bad state|Unhandled/i],
  ['网络/403/证书', /403|404|SSL|certificate|Handshake|Failed to open|Network/i],
  ['GL/EGL/Surface', /EGL|GLConsumer|SurfaceFlinger|OpenGL|dequeueBuffer|Swappy/i],
];
for (const [name, re] of pats) {
  const lines = log.split('\n').filter((l) => re.test(l));
  console.log(`\n── ${name}: ${lines.length} 行 ──`);
  for (const l of lines.slice(0, 22)) console.log('  ' + l.slice(0, 190));
  if (lines.length > 22) console.log(`  … 其余 ${lines.length - 22} 行见 tool/_dy_emu_logcat.txt`);
}
