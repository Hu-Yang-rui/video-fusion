// vf_dy_live_parse.mjs — 抖音直播解析前提的落地验证（喂给 Dart 侧实现的证据）
//
// 逐房间打印实现依赖的全部字段：
//   1) stream_orientation + 平台自声明的 extra.width/height  → 朝向判据（== 1 才是竖屏）
//   2) hls_pull_url_map 的 key 列表 / 顶层 hls_pull_url 长度 / flv_pull_url 键数
//      → 取值优先级（feed 里顶层两个字段实测是空的）
//   3) live_core_sdk_data.pull_data.stream_data 的 **类型**（必须是 string 才需要二次 jsonDecode）
//   4) resolution_name（平台自己的档位名，含拼错的 ORIGION）
//   5) options.qualities 的 v_codec / sdk_params（编码是 hevc 还是 avc）
//   6) 真拉一条 m3u8 → 首分片，验 TS 同步字节 0x47
//
// 运行：node tool/vf_dy_live_parse.mjs [--rooms=12] [--no-fetch]
import fs from 'node:fs';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const FEED = `https://webcast.amemv.com/webcast/feed/?${COMMON}&count=20&offset=0&type=0`;
const HEADERS = { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' };

const argv = process.argv.slice(2);
const numArg = (n, d) => {
  const a = argv.find((s) => s.startsWith(`--${n}=`));
  return a ? Number(a.split('=')[1]) : d;
};
const wantRooms = numArg('rooms', 12);
const noFetch = argv.includes('--no-fetch');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchFeedBatch() {
  const r = await fetch(FEED, { headers: HEADERS });
  const t = await r.text();
  if (!t.trim()) return { status: r.status, empty: true, rooms: [] };
  let j;
  try { j = JSON.parse(t); } catch { return { status: r.status, empty: true, rooms: [] }; }
  const rooms = (j.data ?? []).map((e) => e?.data).filter((d) => d && d.id_str);
  return { status: r.status, empty: false, bytes: t.length, rooms };
}

// 递归找 stream_url 里所有带 width+height 的节点（平台自声明的编码分辨率）。
function walkWH(node, path, out, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 8) return;
  if (Array.isArray(node)) {
    node.forEach((v, i) => walkWH(v, `${path}[${i}]`, out, depth + 1));
    return;
  }
  if (typeof node.width === 'number' && typeof node.height === 'number') {
    out.push({ path, width: node.width, height: node.height, v_codec: node.v_codec });
  }
  for (const [k, v] of Object.entries(node)) walkWH(v, `${path}.${k}`, out, depth + 1);
}

const dir = (w, h) => (h > w ? 'portrait' : w > h ? 'landscape' : 'square');

console.log('=== vf_dy_live_parse: 抖音直播 feed 解析前提验证 ===');
console.log(`目标端点 ${FEED.slice(0, 60)}...`);
console.log(`UA       ${UA_APP.slice(0, 40)}...\n`);

// 收集：feed 空 body 率 + 每批房间数（这两条决定 findRoomInFeed 的重试是否必要）
const rooms = [];
const seen = new Set();
let batches = 0;
let emptyBatches = 0;
const batchSizes = [];
while (rooms.length < wantRooms && batches < 25) {
  batches++;
  const b = await fetchFeedBatch();
  if (b.empty) { emptyBatches++; batchSizes.push(0); console.log(`batch#${batches}: HTTP ${b.status} len=0（空 body）`); await sleep(300); continue; }
  batchSizes.push(b.rooms.length);
  console.log(`batch#${batches}: HTTP ${b.status} len=${b.bytes} rooms=${b.rooms.length}`);
  for (const r of b.rooms) if (!seen.has(r.id_str)) { seen.add(r.id_str); rooms.push(r); }
  await sleep(250);
}
console.log(`\n>>> 房间数=${rooms.length}  批次=${batches}  空 body 批次=${emptyBatches}/${batches}` +
  `  每批房间数=[${batchSizes.join(', ')}]`);

const orientationRows = [];
let stringifiedHits = 0;
const hlsKeyDist = {};
const resNameDist = {};
let topHlsNonEmpty = 0;
let flvMapNonEmpty = 0;

for (const r of rooms) {
  const su = r.stream_url ?? {};
  const mapKeys = Object.keys(su.hls_pull_url_map ?? {});
  mapKeys.forEach((k) => { hlsKeyDist[k] = (hlsKeyDist[k] || 0) + 1; });
  const resName = su.resolution_name ?? {};
  for (const [k, v] of Object.entries(resName)) {
    resNameDist[`${k}=${v}`] = (resNameDist[`${k}=${v}`] || 0) + 1;
  }
  const topHls = typeof su.hls_pull_url === 'string' ? su.hls_pull_url : '';
  if (topHls) topHlsNonEmpty++;
  const flvKeys = Object.keys(su.flv_pull_url ?? {});
  if (flvKeys.length) flvMapNonEmpty++;

  const sdRaw = su.live_core_sdk_data?.pull_data?.stream_data;
  const sdType = sdRaw === undefined ? 'undefined' : (typeof sdRaw);
  if (sdType === 'string') stringifiedHits++;

  const wh = [];
  walkWH(su, 'stream_url', wh);
  const extraWH = su.extra && typeof su.extra.width === 'number'
    ? `${su.extra.width}x${su.extra.height}`
    : (wh.length ? `${wh[0].width}x${wh[0].height}` : 'n/a');

  const opts = su.live_core_sdk_data?.pull_data?.options;
  const vcodecs = (opts?.qualities ?? []).map((q) => `${q.sdk_key}:${q.v_codec ?? q.video_codec ?? '?'}`);

  orientationRows.push({
    room: r.id_str,
    game: r.game_data?.game_tag_info?.game_tag_name ?? '',
    stream_orientation: su.stream_orientation,
    top_orientation: r.orientation,
    wh: extraWH,
    dir: /^(\d+)x(\d+)$/.test(extraWH)
      ? dir(Number(extraWH.split('x')[0]), Number(extraWH.split('x')[1]))
      : 'unknown',
    hls_map_keys: mapKeys,
    res_name: resName,
    hls_top_len: topHls.length,
    flv_map_keys: flvKeys.length,
    stream_data_type: sdType,
    sdk_data_keys: sdType === 'string'
      ? Object.keys((() => { try { return JSON.parse(sdRaw).data ?? {}; } catch { return {}; } })())
      : [],
    sdk_options_vcodec: vcodecs,
    default_resolution: su.default_resolution,
    sdk_params: (() => {
      try {
        const sd = JSON.parse(sdRaw);
        return Object.entries(sd.data ?? {}).map(([k, v]) =>
          `${k}[${Object.keys(v?.main ?? {}).join('/')}]:${String(v?.main?.flv ?? v?.main?.hls ?? '').slice(0, 0)}`);
      } catch { return []; }
    })(),
  });
}

console.log('\n=== 1) 朝向：stream_orientation vs 平台声明分辨率（extra.width/height）===');
for (const o of orientationRows) {
  console.log(`  ${o.room}  stream_orientation=${o.stream_orientation}  顶层 orientation=${o.top_orientation}` +
    `  声明 ${o.wh} → ${o.dir}  game="${o.game}"`);
}
const orientStat = {};
for (const o of orientationRows) {
  const k = `stream_orientation=${o.stream_orientation} → ${o.dir}`;
  orientStat[k] = (orientStat[k] || 0) + 1;
}
console.log('  汇总: ' + JSON.stringify(orientStat));
console.log('  顶层 orientation 取值集合: ' + JSON.stringify([...new Set(orientationRows.map((o) => o.top_orientation))]));

console.log('\n=== 2/3) 流地址来源分布（决定取值优先级）===');
console.log(`  hls_pull_url_map key 分布: ${JSON.stringify(hlsKeyDist)}`);
console.log(`  顶层 hls_pull_url 非空: ${topHlsNonEmpty}/${rooms.length}（0 才印证"feed 里是空串"）`);
console.log(`  flv_pull_url 非空对象: ${flvMapNonEmpty}/${rooms.length}（0 才印证"feed 里是 {}"）`);
console.log(`  live_core_sdk_data...stream_data 类型为 string: ${stringifiedHits}/${rooms.length}` +
  '  ← 必须 jsonDecode');
for (const o of orientationRows) {
  console.log(`  ${o.room}: map=[${o.hls_map_keys.join(',')}] default=${o.default_resolution}` +
    ` hls_top_len=${o.hls_top_len} flv_keys=${o.flv_map_keys} sd_type=${o.stream_data_type}` +
    ` sd_data=[${o.sdk_data_keys.join(',')}]`);
  if (o.sdk_options_vcodec.length) console.log(`      options.qualities v_codec: ${o.sdk_options_vcodec.join(' ')}`);
}

console.log('\n=== 档位名 resolution_name 分布（平台自己的命名）===');
for (const [k, v] of Object.entries(resNameDist)) console.log(`  ${k}  出现 ${v} 次`);

// 4) 真拉一次 HLS：m3u8 → 首个分片 → TS 同步字节
if (!noFetch && orientationRows.length) {
  const withUrl = rooms.find((r) => Object.keys(r.stream_url?.hls_pull_url_map ?? {}).length);
  if (withUrl) {
    const su = withUrl.stream_url;
    const key = su.default_resolution && su.hls_pull_url_map[su.default_resolution]
      ? su.default_resolution
      : Object.keys(su.hls_pull_url_map)[0];
    const url = su.hls_pull_url_map[key];
    console.log(`\n=== 4) 实测播放：房间 ${withUrl.id_str} 档位 ${key} ===`);
    console.log(`  host=${new URL(url).hostname} path=${new URL(url).pathname.slice(0, 30)}…` +
      `（签名参数不打印，避免时效地址入库）`);
    const mres = await fetch(url, { headers: HEADERS });
    const mbody = await mres.text();
    console.log(`  m3u8: HTTP=${mres.status} ct=${mres.headers.get('content-type')} len=${mbody.length}` +
      ` 首行=${JSON.stringify(mbody.split('\n')[0])}`);
    const tsLine = mbody.split('\n').find((l) => l && !l.startsWith('#'));
    if (tsLine) {
      const tsUrl = new URL(tsLine.trim(), url).toString();
      const t = await fetch(tsUrl, { headers: { ...HEADERS, range: 'bytes=0-11' } });
      const buf = Buffer.from(await t.arrayBuffer());
      console.log(`  分片: HTTP=${t.status} len=${buf.length} 首字节=${[...buf].map((b) => b.toString(16).padStart(2, '0')).join(' ')}` +
        `  → ${buf[0] === 0x47 ? 'TS sync 0x47 ✅（标准 MPEG-TS，非 fMP4）' : '非 TS 头'}`);
    }
    // FLV 实测（从 stream_data 取）
    try {
      const sd = JSON.parse(su.live_core_sdk_data?.pull_data?.stream_data);
      const firstFlv = Object.entries(sd.data ?? {}).flatMap(([k, v]) =>
        v?.main?.flv ? [[k, v.main.flv]] : []);
      if (firstFlv.length) {
        const [k, u] = firstFlv[0];
        const f = await fetch(u, { headers: { ...HEADERS, range: 'bytes=0-11' } });
        const b = Buffer.from(await f.arrayBuffer());
        console.log(`  FLV ${k}: HTTP=${f.status} ct=${f.headers.get('content-type')} len=${b.length}` +
          ` 魔数=${b.subarray(0, 3).toString('latin1')} ver=${b[3]} hdrLen=${b.readUInt32BE(5)}`);
      }
    } catch (e) { console.log(`  FLV 取不到: ${e.message}`); }
  }
}

// 落盘一份精简结果，便于 Dart 侧写测试 fixture
const out = {
  at: new Date().toISOString(),
  rooms: rooms.length,
  batches,
  emptyBatches,
  batchSizes,
  orientation: orientationRows.map((o) => ({
    room: o.room, stream_orientation: o.stream_orientation, top_orientation: o.top_orientation,
    wh: o.wh, dir: o.dir, game: o.game, hls_map_keys: o.hls_map_keys,
    res_name: o.res_name, hls_top_len: o.hls_top_len, flv_map_keys: o.flv_map_keys,
    stream_data_type: o.stream_data_type, sdk_data_keys: o.sdk_data_keys,
    sdk_options_vcodec: o.sdk_options_vcodec, default_resolution: o.default_resolution,
  })),
  summary: { orientStat, hlsKeyDist, resNameDist, topHlsNonEmpty, flvMapNonEmpty, stringifiedHits },
};
fs.writeFileSync(new URL('../tool/_dy_live_parse.json', import.meta.url), JSON.stringify(out, null, 2));
console.log('\n结果已写入 tool/_dy_live_parse.json（不含任何签名 URL）');
