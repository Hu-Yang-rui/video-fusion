// vf_dy_ts_codec.mjs — 抖音直播 HLS 分片的真实编码（决定 media_kit 能不能解码）
//
// feed 里 options.qualities 声明 v_codec=bytevc1（字节自研 HEVC 变体），
// 只有 md 档是 h264。但 Flutter 侧用的是 media_kit/libmpv（FFmpeg），
// 能不能播取决于 **TS 里 PMT 声明的 stream_type**，不是 JSON 里的字符串。
//
// 本探针：
//   1) 拉一个真实 .ts 分片（≥ 512KB，保证覆盖 PAT/PMT）
//   2) 按 188 字节包长扫同步字节，找 PID=0 的 PAT → 找 PMT PID → 解 PMT
//   3) 打印每个 elementary stream 的 stream_type：
//        0x1B=H.264/AVC  0x24=H.265/HEVC  0x06/0x0F/0x11=MPEG-1/2 AUDIO
//        0x03/0x04=MPEG-1/2 Audio  0x15/0x16=ADTS/LATM AAC  0x81/0x06=字节私有
//   4) 结论：media_kit 能否硬解 / 是否需要退回 h264 档
//
// 运行：node tool/vf_dy_ts_codec.mjs
import fs from 'node:fs';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function feed() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 350 * i));
  }
  return [];
}
async function get(url, headers = {}) {
  const ac = new AbortController(); const to = setTimeout(() => ac.abort(), 20000);
  try {
    const r = await fetch(url, { signal: ac.signal, headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', ...headers } });
    const b = Buffer.from(await r.arrayBuffer());
    return { status: r.status, ct: r.headers.get('content-type'), buf: b };
  } finally { clearTimeout(to); }
}

const STREAM_TYPE = {
  0x01: 'MPEG-1 Video', 0x02: 'MPEG-2 Video', 0x03: 'MPEG-1 Audio', 0x04: 'MPEG-2 Audio',
  0x06: 'MPEG-1/2 Audio (私用/AC-3)', 0x0F: 'AAC ADTS', 0x11: 'AAC LATM',
  0x1B: 'H.264/AVC', 0x24: 'H.265/HEVC', 0x15: 'ATA A52/AC-3', 0x16: 'MPEG2 ADTS AAC',
  0x81: '字节/私用 (0x81)', 0x86: 'SMPTE VC-1 ?（私用）', 0xDB: '私用',
};

/** 扫 TS 包：校验同步字节对齐 + 解 PAT（program_number -> pmt_pid）。 */
function parseTs(buf) {
  const PKT = 188;
  const pmts = new Map();
  let syncPackets = 0, misaligned = 0;
  for (let off = 0; off + PKT <= buf.length; off += PKT) {
    if (buf[off] !== 0x47) {
      const nxt = buf.indexOf(0x47, off);
      if (nxt < 0) break;
      off = nxt - PKT; misaligned++; continue;
    }
    syncPackets++;
    const b1 = buf[off + 1];
    const pid = (((b1 & 0x1f) << 8) | buf[off + 2]);
    const adapt = (buf[off + 3] >> 4) & 3;
    let payload = off + 4;
    if (adapt & 2) payload += 1 + buf[payload];
    if (!(adapt & 1) || payload + 9 >= buf.length) continue;
    if (pid !== 0) continue;
    const pui = payload + 1 + buf[payload]; // pointer_field -> section start
    if (buf[pui] !== 0x00) continue;
    const sectLen = ((buf[pui + 1] & 0x0f) << 8) | buf[pui + 2];
    const end = Math.min(pui + 3 + sectLen - 4, buf.length);
    for (let q = pui + 8; q + 3 < end; q += 4) {
      const progNum = (buf[q] << 8) | buf[q + 1];
      const pmtPid = ((buf[q + 2] & 0x1f) << 8) | buf[q + 3];
      if (pmtPid > 0 && pmtPid < 0x1fff) pmts.set(progNum, pmtPid);
    }
  }
  return { syncPackets, misaligned, programs: [...pmts.entries()] };
}
function esLen(buf, i) { return ((buf[i] & 0x0f) << 8) | buf[i + 1]; }

// 更稳的 PMT 解析（独立实现，避免上面步进出错）
function parsePmt(buf, pmtPids) {
  const PKT = 188;
  const out = [];
  const seen = new Set();
  for (let off = 0; off + PKT <= buf.length; off += PKT) {
    if (buf[off] !== 0x47) continue;
    const b1 = buf[off + 1];
    if (!((b1 >> 6) & 1)) continue;
    const pid = (((b1 & 0x1f) << 8) | buf[off + 2]);
    if (!pmtPids.includes(pid)) continue;
    const adapt = (buf[off + 3] >> 4) & 3;
    let payload = off + 4;
    if (adapt & 2) payload += 1 + buf[payload];
    if (!(adapt & 1)) continue;
    const ptr = payload + 1 + buf[payload];
    if (buf[ptr] !== 0x02) continue;
    const sectLen = ((buf[ptr + 1] & 0x0f) << 8) | buf[ptr + 2];
    const progEnd = Math.min(ptr + 3 + sectLen - 4, buf.length);
    const pmi = ((buf[ptr + 10] & 0x0f) << 8) | buf[ptr + 11];
    for (let q = ptr + 12 + pmi; q + 4 < progEnd;) {
      const st = buf[q];
      const epid = ((buf[q + 1] & 0x1f) << 8) | buf[q + 2];
      const dl = ((buf[q + 3] & 0x0f) << 8) | buf[q + 4];
      const key = `${st}:${epid}`;
      if (!seen.has(key)) {
        seen.add(key);
        let hint = '';
        for (let d = q + 5; d + 1 < q + 5 + dl && d + 1 < progEnd;) {
          const tag = buf[d], len = buf[d + 1];
          if (tag === 0x09 && d + 5 <= progEnd) hint += ` lang=${Buffer.from(buf.subarray(d + 2, d + 5)).toString('latin1')}`;
          if (tag === 0x06) hint += ` desc06=${Buffer.from(buf.subarray(d + 2, d + 2 + Math.min(len, 12))).toString('hex')}`;
          d += 2 + len;
        }
        out.push({ pid: epid, stream_type: st, type: STREAM_TYPE[st] ?? `未知(0x${st.toString(16).padStart(2, '0')})`, hint: hint.trim() });
      }
      q += 5 + dl;
    }
  }
  return out;
}

console.log('=== vf_dy_ts_codec: 抖音直播 TS 分片编码实测 ===');
const rooms = await feed();
console.log(`feed 房间数=${rooms.length}`);
const results = [];
for (const room of rooms.slice(0, 3)) {
  const map = room.stream_url?.hls_pull_url_map ?? {};
  for (const [tier, url] of Object.entries(map)) {
    let pl;
    try { pl = await get(url); } catch (e) { console.log(`  ${tier} playlist 失败 ${e.message}`); continue; }
    if (!pl.buf.length || pl.buf[0] === 0x3c) continue;
    const text = pl.buf.toString('utf8');
    if (!text.startsWith('#EXTM3U')) continue;
    let masterUri = null;
    const m = text.match(/#EXT-X-STREAM-INF:[^\n]*\n([^\n]+)/);
    if (m) masterUri = m[1].trim();
    let variantText = text, variantBase = url;
    if (masterUri) {
      const vu = masterUri.startsWith('http') ? masterUri : new URL(masterUri, url).toString();
      const vr = await get(vu);
      variantText = vr.buf.toString('utf8'); variantBase = vu;
    }
    const segs = variantText.split(/\r?\n/).filter((l) => l && !l.startsWith('#'));
    if (!segs.length) { console.log(`  ${room.id_str} ${tier}: playlist 无分片`); continue; }
    const segUrl = segs[0].startsWith('http') ? segs[0] : new URL(segs[0], variantBase).toString();
    const seg = await get(segUrl);
    const b = seg.buf;
    const ts = parseTs(b);
    const pmtPids = [...new Set(ts.programs.map(([, p]) => p))];
    const streams = parsePmt(b, pmtPids);
    // feed 声明的 codec（options.qualities 里按 sdk_key 匹配当前档位）
    const SDK_KEY = { FULL_HD1: 'uhd', HD1: 'hd', SD1: 'ld', SD2: 'sd', ORIGION: 'origin' };
    let declared = '';
    try {
      const opts = JSON.parse(JSON.stringify(room.stream_url?.live_core_sdk_data?.pull_data?.options ?? {}));
      const q = (opts.qualities ?? []).find((x) => x.sdk_key === SDK_KEY[tier]);
      declared = q ? `${q.sdk_key}=${q.v_codec}@${q.resolution}/${q.fps}fps/${Math.round(q.v_bit_rate / 1000)}kbps` : `sdk_key=${SDK_KEY[tier]} 未在 qualities 中`;
    } catch { declared = '(解析失败)'; }
    const row = {
      room: room.id_str, tier, segStatus: seg.status, segLen: b.length,
      firstByte: '0x' + b[0]?.toString(16), segCt: seg.ct,
      tsSyncPackets: ts.syncPackets, tsMisaligned: ts.misaligned,
      programs: ts.programs.map(([n, p]) => `prog${n}/pmt${p}`),
      streams: streams.map((s) => `pid=${s.pid} stream_type=0x${s.stream_type.toString(16).padStart(2, '0')} ${s.type}${s.hint ? ' ' + s.hint : ''}`),
      declaredCodec: declared,
    };
    results.push(row);
    console.log(`\n  房间 ${room.id_str} 档 ${tier}: 分片 HTTP=${seg.status} len=${b.length} ` +
      `首字节=0x${b[0]?.toString(16)} ct=${seg.ct} TS包=${ts.syncPackets} 错位=${ts.misaligned}`);
    console.log(`    PAT 节目表: ${row.programs.join(', ') || '(未找到)'}`);
    for (const s of row.streams) console.log(`    ES: ${s}`);
    const hasH264 = streams.some((s) => s.stream_type === 0x1b);
    const hasHevc = streams.some((s) => s.stream_type === 0x24);
    console.log(`    → ${hasH264 ? '含 H.264' : ''}${hasHevc ? ' 含 H.265/bytevc1' : ''}${!hasH264 && !hasHevc ? ' 视频流类型未知' : ''}`);
    break; // 每房间一档就够
  }
}
fs.writeFileSync('tool/_dy_ts_codec.json', JSON.stringify(results, null, 2), 'utf8');
console.log('\n已写 tool/_dy_ts_codec.json');
