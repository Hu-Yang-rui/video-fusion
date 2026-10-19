// vf_dy_codec_per_tier.mjs — 每个档位的真实编码（hevc vs avc）+ stream_url 键位
//
// 要坐实两件事，决定 Dart 侧 codecName 怎么填：
//   1) stream_url 顶层有哪些键？h265_enable / video_profile 到底在哪一层？
//      （已发现 extra.h265_enable=false 但实测分片 PMT 是 0x24=HEVC，
//        所以这个字段**不能**当编码判据，必须查清它的位置与含义）
//   2) options.qualities 每条的 sdk_key / v_codec / level，与 hls_pull_url_map
//      的 FULL_HD1/HD1/SD1/SD2 能不能对上；有没有 H.264 档存在。
//   3) 对 FULL_HD1/HD1/SD1/SD2 各拉一个 TS 分片，从 PMT 读 stream_type
//      （0x1B=H.264, 0x24=H.265）—— 这才是权威。
//
// 运行：node tool/vf_dy_codec_per_tier.mjs
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; ' +
  'Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const APPQ =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function feedRooms(n) {
  const rooms = [];
  for (let i = 1; i <= 20 && rooms.length < n; i++) {
    try {
      const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=20&offset=0&type=0`,
        { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
      const t = await r.text();
      if (!t.trim()) { await sleep(300); continue; }
      for (const e of (JSON.parse(t).data ?? [])) if (e?.data?.stream_url) rooms.push(e.data);
    } catch {}
    await sleep(250);
  }
  return rooms;
}

// MPEG-TS: 找 PMT，读每个 elementary stream 的 stream_type
function tsStreamTypes(buf) {
  const out = [];
  const found = new Set();
  for (let i = 0; i + 188 <= buf.length; i += 188) {
    if (buf[i] !== 0x47) { i -= 187; if (i < -187) break; continue; }
    const pid = ((buf[i + 1] & 0x1f) << 8) | buf[i + 2];
    const payloadStart = (buf[i + 1] & 0x40) !== 0;
    if (pid !== 0 && pid !== 0x1fff && payloadStart) {
      const pointer = buf[i + 4];
      const base = i + 5 + pointer;
      if (base + 12 <= buf.length && buf[base] === 0x02) {
        const programInfoLen = ((buf[base + 10] & 0x0f) << 8) | buf[base + 11];
        let p = base + 12 + programInfoLen;
        while (p + 5 < buf.length) {
          const st = buf[p];
          const esPid = ((buf[p + 1] & 0x1f) << 8) | buf[p + 2];
          const esInfoLen = ((buf[p + 3] & 0x0f) << 8) | buf[p + 4];
          if (st === 0xff) break;
          const key = `${st}@${esPid}`;
          if (!found.has(key)) {
            found.add(key);
            out.push({ stream_type: st, pid: esPid, label: st === 0x1b ? 'H.264/AVC' : st === 0x24 ? 'H.265/HEVC' : st === 0x0f ? 'AAC' : st === 0x03 || st === 0x04 ? 'MP3' : `0x${st.toString(16)}` });
          }
          p += 5 + esInfoLen;
        }
      }
    }
  }
  return out;
}

const rooms = await feedRooms(3);
console.log(`=== vf_dy_codec_per_tier: 房间数 ${rooms.length} ===`);

for (const r of rooms) {
  const su = r.stream_url;
  console.log(`\n──── 房间 ${r.id_str} stream_orientation=${su.stream_orientation} ────`);
  console.log(`  stream_url 顶层 keys(${Object.keys(su).length}): ${Object.keys(su).sort().join(', ')}`);
  console.log(`  stream_url 顶层里编码相关字段: ` +
    Object.entries(su).filter(([k]) => /codec|h26|h265|hevc|avc|profile|bytevc/i.test(k))
      .map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(' ') || '(无)');
  console.log(`  stream_url.extra 编码字段: h265_enable=${JSON.stringify(su.extra?.h265_enable)} ` +
    `video_profile=${JSON.stringify(su.extra?.video_profile)} bytevc1_enable=${JSON.stringify(su.extra?.bytevc1_enable)} ` +
    `w/h=${su.extra?.width}x${su.extra?.height}`);
  const sdk = su.live_core_sdk_data?.pull_data;
  console.log(`  pull_data keys: ${Object.keys(sdk ?? {}).join(', ')}`);
  console.log(`  pull_data.options keys: ${Object.keys(sdk?.options ?? {}).join(', ')}`);
  console.log(`  options.qualities = ${JSON.stringify(sdk?.options?.qualities)}`);
  console.log(`  options.default_quality = ${JSON.stringify(sdk?.options?.default_quality)}`);
  console.log(`  顶层 su.options 是否存在 = ${su.options !== undefined}`);
  if (su.options) console.log(`  su.options = ${JSON.stringify(su.options).slice(0, 300)}`);

  // 每档实测
  let sd = null;
  try { sd = JSON.parse(sdk?.stream_data ?? '{}'); } catch {}
  for (const [tier, url] of Object.entries(su.hls_pull_url_map ?? {})) {
    try {
      const m = await (await fetch(url, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } })).text();
      const seg = m.split('\n').find((l) => l && !l.startsWith('#'));
      if (!seg) { console.log(`  HLS ${tier}: m3u8 无分片`); continue; }
      const sb = Buffer.from(await (await fetch(new URL(seg.trim(), url).toString(), {
        headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', range: 'bytes=0-3759' } })).arrayBuffer());
      const types = tsStreamTypes(sb);
      console.log(`  HLS ${tier}: m3u8首行=${JSON.stringify(m.split('\n')[0])} 分片=${sb.length}B ` +
        `PMT=[${types.map((t) => `${t.pid}:${t.label}`).join(', ')}]`);
    } catch (e) { console.log(`  HLS ${tier}: 失败 ${e.message}`); }
    await sleep(120);
  }
  // stream_data 里的 md / ao 档（parent 说 md 是唯一 h264）
  for (const tier of ['md', 'ao', 'origin', 'ld']) {
    const flv = sd?.data?.[tier]?.main?.flv;
    if (typeof flv !== 'string' || !flv) continue;
    try {
      const b = Buffer.from(await (await fetch(flv, {
        headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', range: 'bytes=0-65535' } })).arrayBuffer());
      // FLV body 里找视频 tag(0x09) 的 codecId = (byte>>4)：7=AVC, 12=HEVC
      const codecs = new Set();
      for (let i = 0; i + 11 < b.length; i++) {
        if (b[i] === 0x09 && b[i + 10] === 0) {
          const prev = i > 3 ? b.readUInt32BE(i - 4) : -1;
          if (prev > 0 && prev < 65536 && i - 4 - prev >= 0) {
            // tag header: type(1) dataLen(3) ts(3) tsExt(1) streamId(3) then byte0=codecId<<4|...
            const b0 = b[i + 11];
            if (b0 !== undefined) codecs.add((b0 >> 4) === 7 ? 'AVC' : (b0 >> 4) === 12 ? 'HEVC' : `codecId=${b0 >> 4}`);
          }
        }
      }
      const sdkParams = sd?.data?.[tier]?.main?.sdk_params ?? '';
      console.log(`  sdk ${tier}: FLV ${b.length}B tag编码=[${[...codecs].join(',')}] sdk_params=${String(sdkParams).slice(0, 90)}`);
    } catch (e) { console.log(`  sdk ${tier}: 失败 ${e.message}`); }
    await sleep(120);
  }
}
