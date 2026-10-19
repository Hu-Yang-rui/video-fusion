// vf_dy_orientation.mjs — stream_orientation 到底是几=竖屏（用 ffprobe 实测帧尺寸判定）
//
// 为什么必须实测：Dart 现在写 `isPortrait: _toInt(room['stream_orientation']) != 1`
// （2→竖屏）。判反会把横屏游戏直播裁切。feed 顶层 `orientation` 实测恒 0，无区分度。
//
// 证据链（三条互相独立）：
//   A. HLS master/media playlist 里 #EXT-X-STREAM-INF:RESOLUTION=wxd（CDN 声明）
//   B. ffprobe 真读该档流的 width/height（= 解码器实际看到的帧尺寸，含 display matrix）
//      —— 与 media_kit(libmpv) 看到的是同一个 FFmpeg 判据，最有说服力
//   C. feed 的 stream_url.extra.width/height 与 stream_data.options.qualities[].resolution
// 把每条房间的 stream_orientation 与 A/B/C 对齐，直接给出映射结论。
//
// 运行：node tool/vf_dy_orientation.mjs
//       node tool/vf_dy_orientation.mjs --tiers=HD1 --max=10
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

const argv = process.argv.slice(2);
const arg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? a.split('=')[1] : d; };
const TIER = arg('tiers', 'HD1');
const MAX = Number(arg('max', 10));

const hasFfprobe = (() => { try { execFileSync('ffprobe', ['-version'], { stdio: 'ignore' }); return true; } catch { return false; } })();

async function feedBatches(n) {
  const out = [];
  for (let b = 0; b < n; b++) {
    for (let i = 1; i <= 10; i++) {
      const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
        headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
      const t = await r.text();
      if (t.trim()) { const j = JSON.parse(t); out.push(...(j.data ?? []).map((e) => e?.data).filter(Boolean)); break; }
      await new Promise((s) => setTimeout(s, 300 * i));
    }
    await new Promise((s) => setTimeout(s, 250));
  }
  return out;
}
async function getText(url) {
  try { const r = await fetch(url, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } }); return await r.text(); }
  catch { return ''; }
}
/** ffprobe 真读该档流：返回 coded w/h、display matrix、codec */
function probeStream(url) {
  if (!hasFfprobe) return null;
  try {
    const out = execFileSync('ffprobe', [
      '-hide_banner', '-loglevel', 'error',
      '-user_agent', UA_APP,
      '-headers', `referer:https://live.douyin.com/\r\n`,
      '-show_entries', 'stream=codec_name,codec_type,width,height,sample_aspect_ratio,display_aspect_ratio:stream_side_data=rotation',
      '-select_streams', 'v:0', '-of', 'json', '-read_intervals', '%+3', url,
    ], { encoding: 'utf8', timeout: 90000, maxBuffer: 16 * 1024 * 1024 });
    return JSON.parse(out);
  } catch (e) { return { __err: String(e.message).split('\n')[0].slice(0, 90) }; }
}

console.log('=== vf_dy_orientation: stream_orientation 实测对齐 ===');
console.log(`ffprobe 可用=${hasFfprobe}（不可用则只比 playlist RESOLUTION 与 feed 声明）`);
const rooms = await feedBatches(3);
const uniq = [...new Map(rooms.map((r) => [r.id_str, r])).values()].slice(0, MAX);
console.log(`样本房间数=${uniq.length}`);
const soDist = uniq.reduce((a, r) => { const k = String(r.stream_url?.stream_orientation); a[k] = (a[k] ?? 0) + 1; return a; }, {});
console.log(`stream_orientation 分布=${JSON.stringify(soDist)}  orientation 分布=${JSON.stringify(uniq.reduce((a, r) => { a[String(r.orientation)] = (a[String(r.orientation)] ?? 0) + 1; return a; }, {}))}`);

const rows = [];
for (const room of uniq) {
  const su = room.stream_url ?? {};
  const so = su.stream_orientation ?? null;
  const url = su.hls_pull_url_map?.[TIER] ?? Object.values(su.hls_pull_url_map ?? {})[0];
  if (!url) { console.log(`  ${room.id_str} 无地址，跳过`); continue; }
  // A) playlist RESOLUTION
  let text = await getText(url);
  let res = [...text.matchAll(/RESOLUTION=(\d+)x(\d+)/g)].map((m) => `${m[1]}x${m[2]}`);
  let base = url;
  if (text.includes('#EXT-X-STREAM-INF')) {
    const m = text.match(/#EXT-X-STREAM-INF:[^\n]*\n([^\n]+)/);
    if (m) { base = m[1].trim().startsWith('http') ? m[1].trim() : new URL(m[1].trim(), url).toString(); text = await getText(base); }
  }
  const segs = text.split(/\r?\n/).filter((l) => l && !l.startsWith('#'));
  const segUrl = segs.length ? (segs[0].startsWith('http') ? segs[0] : new URL(segs[0], base).toString()) : null;
  // B) ffprobe
  const fp = probeStream(url);
  const vs = fp?.streams?.[0] ?? null;
  const rot = fp?.streams?.[0]?.side_data_list?.find?.((s) => s.rotation !== undefined)?.rotation
    ?? fp?.streams?.[0]?.rotation;
  const fw = vs?.width, fh = vs?.height;
  // C) feed 声明
  const ew = su.extra?.width, eh = su.extra?.height;
  let qRes = [];
  try { qRes = (su.live_core_sdk_data?.pull_data?.options?.qualities ?? []).map((q) => `${q.sdk_key}:${q.resolution}`); } catch {}

  const row = {
    room: room.id_str, stream_orientation: so, feed_orientation: room.orientation,
    playlistResolution: [...new Set(res)],
    ffprobe: fw ? { w: fw, h: fh, codec: vs.codec_name, dar: vs.display_aspect_ratio, rotation: rot ?? null } : (fp?.__err ? { err: fp.__err } : null),
    segmentUrlGot: !!segUrl,
    extraWH: ew && eh ? `${ew}x${eh}` : null,
    qualitiesRes: qRes,
    title: (room.title ?? '').slice(0, 16),
  };
  rows.push(row);
  console.log(`\n  ${room.id_str}  stream_orientation=${so}  orientation=${room.orientation}  ${JSON.stringify(row.title)}`);
  console.log(`    playlist RESOLUTION=[${row.playlistResolution.join(',')}]`);
  console.log(`    ffprobe: ${fw ? `${fw}x${fh} codec=${vs.codec_name} DAR=${vs.display_aspect_ratio ?? '-'} rotation=${rot ?? 'none'}` : (fp?.__err ? 'ERR ' + fp.__err : '(未取到)')}`);
  console.log(`    feed extra=${ew}x${eh}  qualities=[${qRes.join(' ')}]`);
}

// ── 对齐分析 ─────────────────────────────────────────────────
function isPortrait(spec) {
  if (!spec) return null;
  const [w, h] = spec.split('x').map(Number);
  if (!w || !h) return null;
  return h > w;
}
console.log('\n=== 结论 ===');
const buckets = {};
for (const r of rows) {
  const pf = r.ffprobe?.w ? (r.ffprobe.h > r.ffprobe.w) : null;
  // rotation!=0 说明码流是横着编、靠 display matrix 转正 → 视觉上竖屏
  const rot = r.ffprobe?.rotation;
  const visualPortrait = pf === null ? null : (rot ? !pf : pf);
  const pl = r.playlistResolution[0] ? isPortrait(r.playlistResolution[0]) : null;
  const k = `stream_orientation=${r.stream_orientation}`;
  buckets[k] = buckets[k] ?? { n: 0, ffPortrait: 0, ffLandscape: 0, plPortrait: 0, rotated: 0, unknown: 0 };
  buckets[k].n++;
  if (visualPortrait === true) buckets[k].ffPortrait++;
  else if (visualPortrait === false) buckets[k].ffLandscape++;
  else buckets[k].unknown++;
  if (pl === true) buckets[k].plPortrait++;
  if (rot) buckets[k].rotated++;
}
for (const [k, v] of Object.entries(buckets)) {
  console.log(`  ${k.padEnd(24)} n=${v.n}  ffprobe竖屏=${v.ffPortrait} ffprobe横屏=${v.ffLandscape} 带rotation=${v.rotated} playlist声明竖=${v.plPortrait} 未知=${v.unknown}`);
}
const a = buckets['stream_orientation=1'], b = buckets['stream_orientation=2'];
const judge = (x) => {
  if (!x || x.n === 0) return '样本不足';
  if (x.ffPortrait > x.ffLandscape) return '竖屏为主';
  if (x.ffLandscape > x.ffPortrait) return '横屏为主';
  return '各半/不确定';
};
console.log(`\n  stream_orientation=1 → ${judge(a)}`);
console.log(`  stream_orientation=2 → ${judge(b)}`);
const twoPortrait = b && b.ffPortrait > b.ffLandscape;
const oneLandscape = a && a.ffLandscape > a.ffPortrait;
console.log(`\n  当前 Dart 判据 \`isPortrait = stream_orientation != 1\`（即 2→竖屏）：`);
if (twoPortrait && oneLandscape) console.log('  ✅ 与实测一致，无需修改。');
else if (b && a && b.ffLandscape > b.ffPortrait && a.ffPortrait > a.ffLandscape) console.log('  ❌ 实测相反：应改成 isPortrait = (stream_orientation == 1)。');
else console.log('  ⚠️ 实测不足以断言（样本各半或 ffprobe 不可用），保持现状但不要把朝向当裁切依据，改用 ffprobe/播放器上报的真实帧尺寸。');
console.log(`  注意：带 rotation(Display Matrix) 的流，coded w>h 但视觉是竖屏 —— ` +
  `${rows.filter((r) => r.ffprobe?.rotation).length}/${rows.length} 条带 rotation，` +
  `所以**不能用 extra.width/height 判朝向**，必须看播放器实际帧尺寸或 rotation。`);
fs.writeFileSync('tool/_dy_orientation.json', JSON.stringify({ at: new Date().toISOString(), hasFfprobe, rows }, null, 2), 'utf8');
console.log('\n已写 tool/_dy_orientation.json');
