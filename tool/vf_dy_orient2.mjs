// 最小化：把抖音直播 HLS 地址逐层拉下来，拿到真实分辨率。
// 只打印结构，不打印完整签名 URL（避免地址外泄）。
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TP1A.220624.021; Cronet;)';
const H = { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' };
const API = 'https://webcast.amemv.com';
const Q =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

let rooms = [];
for (let i = 0; i < 8 && rooms.length < 4; i++) {
  const t = await (await fetch(`${API}/webcast/feed/?${Q}&count=10&offset=0&type=0`, { headers: H })).text();
  if (!t) { await new Promise((s) => setTimeout(s, 400)); continue; }
  const j = JSON.parse(t);
  for (const e of j.data || []) if (e?.data?.id_str) rooms.push(e.data);
  await new Promise((s) => setTimeout(s, 400));
}
console.log(`房间数 ${rooms.length}\n`);

for (const r of rooms) {
  const so = r.stream_url?.stream_orientation;
  const tag = r.game_data?.game_tag_info?.game_tag_name ?? '';
  const map = r.stream_url?.hls_pull_url_map || {};
  const keys = Object.keys(map);
  console.log(`--- room ${r.id_str}  stream_orientation=${so}  game_tag="${tag}"  hls_map档=${keys.join(',')}`);

  // 1) 动态封面/普通封面的 URL 里常带宽高
  for (const [nm, obj] of [['cover', r.cover], ['dynamic_cover', r.dynamic_cover]]) {
    const u = obj?.url_list?.[0] || '';
    const m = /(\d{2,4})x(\d{2,4})|\/(\d{2,4})\/(\d{2,4})\/|_(\d{2,4})_(\d{2,4})_/.exec(u);
    if (m) console.log(`    ${nm} URL 尺寸线索: ${m[0]}  ← ${u.slice(0, 90)}`);
  }

  // 2) 拉 master 或 media playlist
  const first = (map[keys[0]] || r.stream_url?.hls_pull_url || '').replace(/^http:/, 'https:');
  if (!first) { console.log('    无 HLS 地址'); continue; }
  let text = '';
  try {
    const res = await fetch(first, { headers: { ...H } });
    text = await res.text();
    console.log(`    playlist: HTTP ${res.status} ct=${res.headers.get('content-type')} len=${text.length}`);
  } catch (e) { console.log('    fetch 失败', String(e).slice(0, 70)); continue; }

  const res = [...text.matchAll(/RESOLUTION=(\d+)x(\d+)/g)].map((m) => `${m[1]}x${m[2]}`);
  if (res.length) console.log(`    master 声明 RESOLUTION: ${res.join(' ')}`);

  // 3) 若有 variant，进一层
  let media = text;
  let mediaBase = first;
  if (text.includes('#EXT-X-STREAM-INF')) {
    const v = text.split(/\r?\n/).find((l) => l.trim() && !l.startsWith('#'));
    if (v) {
      const vu = (v.startsWith('http') ? v.replace(/^http:/, 'https:')
        : new URL(v, first).toString());
      media = await (await fetch(vu, { headers: { ...H } })).text();
      mediaBase = vu;
      const r2 = [...media.matchAll(/RESOLUTION=(\d+)x(\d+)/g)].map((m) => `${m[1]}x${m[2]}`);
      if (r2.length) console.log(`    variant 声明 RESOLUTION: ${r2.join(' ')}`);
      console.log(`    media playlist len=${media.length} 分片数=${(media.match(/\.ts/g) || []).length}`);
    }
  }

  // 4) 取一个 TS 分片，从 PMT 里读视频流类型，并扫 SPS 关键字节
  const seg = media.match(/([^\s]+\.ts[^\s]*)/)?.[1];
  if (seg) {
    const su = seg.startsWith('http') ? seg.replace(/^http:/, 'https:') : new URL(seg, mediaBase).toString();
    const ab = await (await fetch(su, { headers: { ...H, range: 'bytes=0-7519' } })).arrayBuffer();
    const buf = Buffer.from(ab);
    console.log(`    TS: ${buf.length}B  首字节 ${[...buf.subarray(0, 8)].map((b) => b.toString(16).padStart(2, '0')).join(' ')}`);
    // TS 里 stream_type: 0x1b=H.264, 0x24=H.265；直接在字节里找这两种 PSI 标记
    const has1b = buf.includes(0x1b), has24 = buf.includes(0x24);
    // 更可靠：找 SPS 起始码 00 00 00 01 67（H.264）或 00 00 00 01 42（H.265 VPS/SPS）
    const naluH264 = buf.subarray(0, Math.min(buf.length, 4000)).includes(Buffer.from([0, 0, 0, 1, 0x67]));
    const naluH265 = buf.subarray(0, Math.min(buf.length, 4000)).includes(Buffer.from([0, 0, 0, 1, 0x40])) ||
                     buf.subarray(0, Math.min(buf.length, 4000)).includes(Buffer.from([0, 0, 0, 1, 0x42]));
    console.log(`    NALU: H.264 SPS(0x67)=${naluH264}  H.265(0x40/0x42)=${naluH265}`);
    // 从 H.264 SPS 粗解宽高：找到 pic_width_in_mbs_minus1 近似位置不稳，改用
    // 直接看 PAT/PMT 的 stream_id 前后字节（这里只给参考）
    void has1b; void has24;
  } else {
    console.log('    playlist 里没有 .ts 分片（可能是 fMP4 或列表为空）',
      media.slice(0, 120).replace(/\r?\n/g, '|'));
  }
  console.log('');
}
