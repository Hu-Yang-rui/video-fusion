// 坐实 stream_orientation 语义：直接从 live feed 读平台自己声明的每档 width/height。
//
// 为什么不能再猜：现有 Dart 代码写 `isPortrait: stream_orientation != 1`，
// 判错会让横屏游戏直播被裁切（cover 切掉左右）。
// 上一版探针尝试从 TS 字节里解 SPS 宽高失败（H.265 的 SPS 起始码不同），
// 而 feed 响应里本来就带 width/height（_dy_feed_raw.json 里可见 1920x1440），
// 那是平台自己声明的编码分辨率，比字节猜测权威。
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TP1A.220624.021; Cronet;)';
const H = { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' };
const Q =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

let rooms = [];
for (let i = 0; i < 10 && rooms.length < 6; i++) {
  const t = await (await fetch(`https://webcast.amemv.com/webcast/feed/?${Q}&count=10&offset=0&type=0`, { headers: H })).text();
  if (!t) { await new Promise((s) => setTimeout(s, 400)); continue; }
  const j = JSON.parse(t);
  for (const e of j.data || []) if (e?.data?.id_str) rooms.push(e.data);
  await new Promise((s) => setTimeout(s, 400));
}
console.log(`房间数 ${rooms.length}\n`);

// 收集所有带 width+height 的节点路径
function walk(node, path, out, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 8) return;
  if (Array.isArray(node)) { node.forEach((v, i) => walk(v, `${path}[${i}]`, out, depth + 1)); return; }
  if ('width' in node && 'height' in node &&
      typeof node.width === 'number' && typeof node.height === 'number') {
    out.push({
      path, width: node.width, height: node.height,
      name: node.name ?? node.resolution_name ?? undefined,
      vcodec: node.v_codec ?? node.video_codec ?? undefined,
    });
  }
  for (const [k, v] of Object.entries(node)) walk(v, `${path}.${k}`, out, depth + 1);
}

const table = [];
for (const r of rooms) {
  const su = r.stream_url || {};
  const found = [];
  walk(su, 'stream_url', found);
  const roomFound = [];
  walk({ cover: r.cover, dynamic_cover: r.dynamic_cover, tall: r.tall }, 'room', roomFound);

  // 每档分辨率：从 hls_pull_url_map 的 key 与 resolution_name 对照
  const dirOf = (w, h) => (h > w ? '竖屏' : w > h ? '横屏' : '方');
  const videoNodes = found.filter((f) => f.width > 0 && f.height > 0);
  const inferred = videoNodes.length
    ? dirOf(videoNodes[0].width, videoNodes[0].height)
    : '未知';

  table.push({
    room: r.id_str,
    str_orient: su.stream_orientation,
    top_orient: r.orientation,
    game_tag: r.game_data?.game_tag_info?.game_tag_name ?? '',
    res_names: Object.entries(su.resolution_name || {}).map(([k, v]) => `${k}:${v}`).join(' '),
    wh: videoNodes.map((f) => `${f.path.split('.').pop()}=${f.width}x${f.height}(${dirOf(f.width, f.height)})`).join(' ')
        || roomFound.map((f) => `${f.path}=${f.width}x${f.height}`).join(' ')
        || '（响应内无 width/height 节点）',
    inferred_dir: inferred,
  });
}

console.log('=== 每房间的 stream_orientation vs 平台声明分辨率 ===');
for (const t of table) {
  console.log(`room ${t.room}  str_orient=${t.str_orient}  top_orient=${t.top_orient}  game="${t.game_tag}"  → 实际方向: ${t.inferred_dir}`);
  console.log(`   宽高节点: ${t.wh}`);
  if (t.res_names) console.log(`   resolution_name: ${t.res_names}`);
}

// 汇总：str_orient 与实际方向的一致率
const stat = {};
for (const t of table) {
  if (t.inferred_dir === '未知') continue;
  const k = `str_orient=${t.str_orient} → ${t.inferred_dir}`;
  stat[k] = (stat[k] || 0) + 1;
}
console.log('\n=== 汇总 ===');
for (const [k, v] of Object.entries(stat)) console.log(`  ${k}  出现 ${v} 次`);
console.log('\n现有 Dart 判断：isPortrait = (stream_orientation != 1)，即 2→竖屏。');
console.log('请对照上表判断该假设是否成立。');
