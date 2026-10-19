// vf_dy_h264_tier.mjs — 确认哪个档位的 TS 真能解出 H.264（media_kit 兜底档）
//
// 背景：feed 的 hls_pull_url_map 只有 FULL_HD1/HD1/SD1/SD2，实测 PMT stream_type=0x24
// （HEVC/bytevc1）。而 live_core_sdk_data 的 stream_data 里 **md 档声明 VCodec=h264**。
// 若 md 档真能解出 H.264，Dart 侧就应把 md 作为解码兜底档（模拟器/低端机无 HEVC 硬解时）。
// 本脚本用 ffprobe 实测每档真实 codec_name，而不是相信 JSON 声明。
//
// 运行：node tool/vf_dy_h264_tier.mjs
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function feed() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return [];
}
/** 取某档 HLS 的首个 .ts 分片并落盘 */
async function firstSegment(hlsUrl) {
  let txt = await (await fetch(hlsUrl, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } })).text().catch(() => '');
  let base = hlsUrl;
  if (txt.includes('#EXT-X-STREAM-INF')) {
    const m = txt.match(/#EXT-X-STREAM-INF:[^\n]*\n([^\n]+)/);
    if (!m) return null;
    base = m[1].trim().startsWith('http') ? m[1].trim() : new URL(m[1].trim(), hlsUrl).toString();
    txt = await (await fetch(base, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } })).text().catch(() => '');
  }
  const seg = (txt.split(/\r?\n/).filter((l) => l && !l.startsWith('#'))[0] ?? '');
  if (!seg) return null;
  const url = seg.startsWith('http') ? seg : new URL(seg, base).toString();
  const buf = Buffer.from(await (await fetch(url, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } })).arrayBuffer().catch(() => new ArrayBuffer(0)));
  return buf.length ? buf : null;
}
function probe(file) {
  try {
    return execFileSync('ffprobe', ['-hide_banner', '-loglevel', 'error',
      '-show_entries', 'stream=codec_name,profile,width,height', '-select_streams', 'v:0',
      '-of', 'csv=p=0', file], { encoding: 'utf8' }).trim();
  } catch (e) { return `ERR ${String(e.message).split('\n')[0].slice(0, 50)}`; }
}

console.log('=== vf_dy_h264_tier: 每档真实 codec（ffprobe 实测）===');
const rooms = await feed();
console.log(`房间数=${rooms.length}\n`);
const summary = {};
for (const room of rooms.slice(0, 3)) {
  const su = room.stream_url ?? {};
  let sd = null;
  try { sd = JSON.parse(su.live_core_sdk_data?.pull_data?.stream_data ?? '{}'); } catch {}
  const ml = sd?.data ?? {};
  console.log(`──── 房间 ${room.id_str} stream_orientation=${su.stream_orientation} ` +
    `hls_map=[${Object.keys(su.hls_pull_url_map ?? {}).join(',')}] stream_data档=[${Object.keys(ml).join(',')}]`);
  for (const q of Object.keys(ml)) {
    const main = ml[q]?.main ?? {};
    if (!main.hls) continue;
    let declared = '?';
    try { declared = JSON.parse(main.sdk_params || '{}').VCodec ?? '?'; } catch {}
    const buf = await firstSegment(main.hls);
    if (!buf) { console.log(`    ${q.padEnd(7)} 声明=${declared.padEnd(8)} 分片取不到`); continue; }
    const f = `tool/_seg_${room.id_str.slice(-6)}_${q}.ts`;
    fs.writeFileSync(f, buf);
    const got = probe(f);
    fs.unlinkSync(f);
    const codec = got.split(',')[0] ?? '?';
    summary[codec] = (summary[codec] ?? 0) + 1;
    console.log(`    ${q.padEnd(7)} 声明=${declared.padEnd(8)} ffprobe=${got}  分片=${buf.length}B`);
  }
  // hls_map 里的档位也测（Dart 现在用的就是这些）
  for (const [tier, url] of Object.entries(su.hls_pull_url_map ?? {}).slice(0, 2)) {
    const buf = await firstSegment(url);
    if (!buf) { console.log(`    hls_map:${tier} 分片取不到`); continue; }
    const f = `tool/_seg_${room.id_str.slice(-6)}_map_${tier}.ts`;
    fs.writeFileSync(f, buf);
    const got = probe(f);
    fs.unlinkSync(f);
    summary[got.split(',')[0]] = (summary[got.split(',')[0]] ?? 0) + 1;
    console.log(`    hls_map:${tier.padEnd(9)} ffprobe=${got}  分片=${buf.length}B`);
  }
}
console.log(`\n=== codec 统计 ===\n  ${JSON.stringify(summary)}`);
console.log(`  → 若存在 hevc 而无 h264：Dart 侧必须接受 HEVC（模拟器有 c2.goldfish.hevc/OMX.google.hevc 软解）`);
console.log(`  → 若 md 档实测 h264：可把 md 作为"解码兜底档"（代价：仅 360p/15fps）`);
