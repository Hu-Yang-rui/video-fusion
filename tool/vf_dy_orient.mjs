// 朝向判据坐实：stream_orientation 与真实视频分辨率的对应关系。
//
// 为什么必须验证：UI 用它决定画面比例与填充方式。判错的话，
// 横屏游戏直播会被裁切（cover 切掉左右），竖屏直播会被压成小条。
// 现有 Dart 代码写的是 `stream_orientation != 1 → 竖屏`，
// 而我实测同一批 feed 里 1 和 2 都出现，且带 game_tag（游戏直播，
// 通常横屏）的房间反而是 2 —— 与代码假设相反，必须用像素证实。
//
// 做法：对每个房间拉 HLS master/media playlist，取 RESOLUTION= 或
// 直接读 TS 分片的 SPS 宽高，与 stream_orientation 对照。
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TP1A.220624.021; Cronet;)';
const API = 'https://webcast.amemv.com';
const Q =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

const rows = [];
for (let attempt = 0; attempt < 6; attempt++) {
  const r = await fetch(`${API}/webcast/feed/?${Q}&count=10&offset=0&type=0`, {
    headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' },
  });
  const t = await r.text();
  if (!t) { await new Promise((s) => setTimeout(s, 350)); continue; }
  const j = JSON.parse(t);
  for (const e of j.data || []) {
    const d = e?.data;
    if (d?.id_str) rows.push(d);
  }
  if (rows.length >= 6) break;
  await new Promise((s) => setTimeout(s, 350));
}
console.log(`拿到 ${rows.length} 个房间\n`);

// 从 TS 分片里读 SPS 宽高（不依赖 master playlist 的 RESOLUTION= 标签）
function tsDimensions(buf) {
  const PKT = 188;
  let patPid = -1, pmtPid = -1;
  const videoStreams = [];
  for (let off = 0; off + PKT <= buf.length; off += PKT) {
    if (buf[off] !== 0x47) return null; // 包边界不齐
    const b1 = buf[off + 1];
    const pid = ((b1 & 0x1f) << 8) | buf[off + 2];
    const pusi = (b1 & 0x40) !== 0;
    let afc = (buf[off + 3] >> 4) & 3;
    let payloadStart = off + 4;
    if (afc & 2) payloadStart += buf[off + 4] + 1;
    if (payloadStart >= off + PKT) continue;
    if (pusi) {
      const ptr = buf[payloadStart];
      payloadStart += 1 + ptr;
      if (payloadStart >= off + PKT) continue;
    }
    if (pid === 0x0000) {
      // PAT → 第一个 program 的 PMT PID
      const tableStart = payloadStart + 1 + buf[payloadStart + 1];
      if (buf[tableStart] !== 0x00) continue;
      const secLen = ((buf[tableStart + 1] & 0x0f) << 8) | buf[tableStart + 2];
      const progStart = tableStart + 8;
      if (progStart + 4 < buf.length) {
        const p = buf.slice(progStart, progStart + 4);
        // 跳过 descriptor 后取 PMT PID（简化：program 项固定 5 字节且无 descriptor）
        const afterDesc = progStart + 4 + ((p[3] & 0xf0) << 3 | (p[3] & 0x0f) * 0) + 2;
        const v = ((buf[progStart + 3] & 0xf0) << 8) | buf[progStart + 4];
        if (v && v !== 0xffff) patPid = v;
      }
      void secLen;
    } else if (pid === patPid && patPid > 0) {
      const tableStart = payloadStart + 1 + buf[payloadStart + 1];
      if (buf[tableStart] !== 0x02) continue;
      const progInfoLen = ((buf[tableStart + 10] & 0x0f) << 8) | buf[tableStart + 11];
      let p = tableStart + 12 + progInfoLen;
      const secLen = ((buf[tableStart + 1] & 0x0f) << 8) | buf[tableStart + 2];
      const end = tableStart + 3 + secLen - 4;
      while (p + 5 <= end) {
        const stype = buf[p];
        const esLen = ((buf[p + 3] & 0x0f) << 8) | buf[p + 4];
        const sPid = ((buf[p + 1] & 0x1f) << 8) | buf[p + 2];
        if (stype >= 0x1b && stype <= 0x27) videoStreams.push({ pid: sPid, stype });
        p += 5 + esLen;
      }
    } else if (videoStreams.some((v) => v.pid === pid)) {
      // 在该 ES 的 payload 里找 Annex-B 起始码 → SPS
      const chunk = buf.subarray(payloadStart, off + PKT);
      for (let i = 0; i + 5 < chunk.length; i++) {
        if (chunk[i] === 0 && chunk[i + 1] === 0 && chunk[i + 2] === 1) {
          const type = chunk[i + 3] & 0x1f;
          if (type === 7) {
            // SPS: skip byte alignment / profile, then parse width/height via ue(v)
            const bits = [];
            for (let k = i + 4; k < chunk.length; k++) {
              for (let b = 7; b >= 0; b--) bits.push((chunk[k] >> b) & 1);
            }
            let pos = 0;
            const u = (n) => { let v = 0; for (let x = 0; x < n; x++) v = (v << 1) | (bits[pos++] ?? 0); return v; };
            const ue = () => { let z = 0; while (pos < bits.length && bits[pos] === 0) { z++; pos++; } pos++; let v = 0; for (let x = 0; x < z; x++) v = (v << 1) | bits[pos++]; return (1 << z) - 1 + v; };
            const profile = u(8); u(8); u(8); u(8);
            ue(); // seq_parameter_set_id
            let chroma = 1;
            if (profile === 100 || profile === 110 || profile === 122 || profile === 244 ||
                profile === 44 || profile === 83 || profile === 86 || profile === 118 ||
                profile === 128 || profile === 138 || profile === 139 || profile === 134 || profile === 135) {
              chroma = ue();
              if (chroma === 3) u(1);
              ue(); ue(); u(1);
              if (u(1)) { for (let s = 0; s < 6; s++) if (u(1)) for (let m = 0; m < 16; m++) u(4); }
            }
            ue(); // log2_max_frame_num
            const picOrder = ue();
            if (picOrder === 4) u(1);
            ue(); // num_ref_frames
            u(1); // gaps
            const maxNum = ue() + 1;
            for (let i2 = 0; i2 < maxNum; i2++) {
              u(picOrder === 0 ? 24 : 32);
              if (u(1)) { u(2); u(1); u(1); u(1); u(1); u(1); }
            }
            u(1); // frame_mbs_only
            if (!u(1)) u(1);
            ue(); // crop
            const wInMbs = u(16) + 1;
            const hInUnits = u(16) + 1;
            return { width: wInMbs * 16, height: hInUnits * 16, chroma, stype: videoStreams.find((v) => v.pid === pid)?.stype };
          }
        }
      }
    }
  }
  return null;
}

console.log('room_id'.padEnd(21), 'str_orient', 'game_tag', 'RESOLUTION(master)', 'TS实测 WxH', 'h264/h265', '方向');
for (const r of rows) {
  const so = r.stream_url?.stream_orientation;
  const topOrient = r.orientation;
  const tag = r.game_data?.game_tag_info?.game_tag_name ?? '';
  const map = r.stream_url?.hls_pull_url_map || {};
  const url = (map.HD1 || map.FULL_HD1 || map.SD1 || r.stream_url?.hls_pull_url || '').replace(/^http:/, 'https:');
  let masterRes = '-';
  let tsDims = '-';
  let stype = '-';
  if (url) {
    try {
      const text = await (await fetch(url, { headers: { 'user-agent': UA_APP } })).text();
      const res = [...text.matchAll(/RESOLUTION=(\d+)x(\d+)/g)].map((m) => `${m[1]}x${m[2]}`);
      if (res.length) masterRes = res.join('/');
      // 取第一个分片（media playlist 或 master 的第一条 variant）
      let seg = text.match(/[^\s]*\.ts[^\s]*/)?.[0];
      if (text.includes('#EXT-X-STREAM-INF')) {
        const variant = text.split('\n').find((l) => l.includes('.m3u8'));
        if (variant) {
          const base = url.split('/').slice(0, -1).join('/');
          const vurl = variant.startsWith('http') ? variant.replace(/^http:/, 'https:') : `${base}/${variant}`;
          const vtext = await (await fetch(vurl, { headers: { 'user-agent': UA_APP } })).text();
          const vr = [...vtext.matchAll(/RESOLUTION=(\d+)x(\d+)/g)].map((m) => `${m[1]}x${m[2]}`);
          if (vr.length) masterRes = vr.join('/');
          seg = vtext.match(/[^\s]*\.ts[^\s]*/)?.[0];
        }
      }
      if (seg) {
        const base = url.split('/').slice(0, -1).join('/');
        const surl = (seg.startsWith('http') ? seg.replace(/^http:/, 'https:') : `${base}/${seg}`)
          .replace(/\.ts\?v=([^&]+)&rs=([^&]+)&rn=\w+/, '.ts?v=$1&rs=$2');
        const ab = await (await fetch(surl, {
          headers: { 'user-agent': UA_APP, range: 'bytes=0-3759' },
        })).arrayBuffer();
        const dims = tsDimensions(Buffer.from(ab));
        if (dims) {
          tsDims = `${dims.width}x${dims.height}`;
          stype = dims.stype === 0x24 ? 'HEVC' : dims.stype === 0x1b ? 'H264' : `0x${dims.stype?.toString(16)}`;
        }
      }
    } catch (e) { tsDims = 'ERR ' + String(e).slice(0, 30); }
  }
  const dim = tsDims !== '-' ? (() => { const [w, h] = tsDims.split('x').map(Number); return h > w ? '竖屏' : w > h ? '横屏' : '方形'; })()
    : masterRes !== '-' ? (() => { const [w, h] = masterRes.split('/')[0].split('x').map(Number); return h > w ? '竖屏' : w > h ? '横屏' : '方形'; })()
    : '未知';
  console.log(
    String(r.id_str).padEnd(21),
    `top=${topOrient} str=${so}`.padEnd(10),
    String(tag).padEnd(9),
    String(masterRes).padEnd(17),
    String(tsDims).padEnd(11),
    String(stype).padEnd(9),
    dim,
  );
}
console.log('\n=== 结论要求：stream_orientation 与真实方向的对应是否稳定，以及现有 Dart 判断是否反了 ===');
