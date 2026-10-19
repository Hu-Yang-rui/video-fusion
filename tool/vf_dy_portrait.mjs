// 抖音直播：确定"竖屏/横屏"的可靠判据，并验证 room/info 详情端点。
//
// 背景：UI 需要按房间朝向选择画面比例与填充方式（竖屏 9:16 cover，
// 横屏 16:9 contain）。feed 里同时有 `orientation`、
// `stream_url.stream_orientation`、封面尺寸三个候选，必须用真实数据
// 确认哪个可靠 —— 猜错会导致竖屏直播被压成小条。
//
// 只读，不改变任何账号数据。
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; ' +
  'Build/TP1A.220624.021; Cronet;)';
const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const APP_Q =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEB_Q =
  'aid=6383&app_name=aweme&channel=channel_pc_web&pc_client_type=1' +
  '&version_code=170400&version_name=17.4.0&platform=PC';

const jget = async (u, headers) => {
  const r = await fetch(u, { headers });
  const t = await r.text();
  try { return { ok: true, json: JSON.parse(t), status: r.status, len: t.length }; }
  catch { return { ok: false, status: r.status, len: t.length, raw: t.slice(0, 80) }; }
};

// ---------- 1. feed 拿房间 + 朝向候选字段 ----------
const feed = await jget(
  `https://webcast.amemv.com/webcast/feed/?${APP_Q}&count=10&offset=0&type=0`,
  { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' },
);
if (!feed.ok || !Array.isArray(feed.json?.data)) {
  console.log('feed 失败：', feed.status, feed.len, feed.raw);
  process.exit(1);
}
const rooms = [];
for (const e of feed.json.data) {
  const d = e?.data;
  if (!d || !d.id_str) continue;
  rooms.push(d);
}
console.log(`feed 拿到 ${rooms.length} 个房间（HTTP ${feed.status}, ${feed.len}B）\n`);

console.log('=== 1. 朝向三个候选字段逐房间对照 ===');
console.log('id_str'.padEnd(21), 'orient', 'stream_orient', 'cover WxH', 'game_tag');
for (const r of rooms) {
  const cov = r.cover?.url_list?.[0];
  // 封面尺寸从 URL 里解（抖音封面 URL 常带 _w_h 段）；解不出就用 0
  let cw = 0, ch = 0;
  const m = cov ? /_(\d+)_(\d+)[^/]*\.(?:jpg|jpeg|png|webp)|\/(\d+)\/(\d+)\//.exec(cov) : null;
  if (m) { cw = +(m[1] || m[3]); ch = +(m[2] || m[4]); }
  const so = r.stream_url?.stream_orientation;
  const tag = r.game_data?.game_tag_info?.game_tag_name ?? '';
  console.log(
    String(r.id_str).padEnd(21),
    String(r.orientation).padEnd(7),
    String(so).padEnd(13),
    `${cw}x${ch}`.padEnd(11),
    tag,
  );
}
console.log('');

// ---------- 2. room/info 详情端点复核（web aid + 浏览器 UA）----------
console.log('=== 2. /webcast/room/info/ 逐房间（匿名，web 参数）===');
for (const r of rooms.slice(0, 4)) {
  const res = await jget(
    `https://webcast.amemv.com/webcast/room/info/?${WEB_Q}&room_id=${r.id_str}`,
    { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' },
  );
  if (!res.ok) { console.log(`  ${r.id_str} → HTTP ${res.status} 非 JSON len=${res.len}`); continue; }
  const d = res.json?.data;
  if (!d || Object.keys(d).length === 0) {
    console.log(`  ${r.id_str} → status_code=${res.json?.status_code} data 空`);
    continue;
  }
  const su = d.stream_url ?? {};
  const hlsMap = su.hls_pull_url_map ?? {};
  const flvMap = su.flv_pull_url ?? {};
  console.log(`  ${d.id_str} keys=${Object.keys(d).length} status=${d.status} ` +
    `user_count=${d.user_count} orientation=${d.orientation} stream_orient=${su.stream_orientation}`);
  console.log(`     顶层 hls_pull_url 长度=${(su.hls_pull_url || '').length}  ` +
    `hls_map 档=${Object.keys(hlsMap).join(',')}  flv_map 档=${Object.keys(flvMap).join(',')}`);
  console.log(`     owner=${d.owner?.nickname} game_tag=${d.game_data?.game_tag_info?.game_tag_name ?? '-'}`);
  // 用 variant 的分辨率判断横竖更可靠：拉 master playlist
  const firstUrl = hlsMap['HD1'] || hlsMap['FULL_HD1'] || hlsMap['SD1'] || su.hls_pull_url;
  if (firstUrl) {
    const t = await (await fetch(firstUrl.replace(/^http:/, 'https:'), { headers: { 'user-agent': UA_WEB } })).text();
    const reso = [...t.matchAll(/RESOLUTION=(\d+)x(\d+)/g)].map((m) => `${m[1]}x${m[2]}`);
    const isMaster = t.startsWith('#EXTM3U') && t.includes('#EXT-X-STREAM-INF');
    console.log(`     ${isMaster ? 'master' : 'media'} playlist, RESOLUTION=${reso.join(',') || '-'}`);
    // 竖屏判据：存在 w<h 的分辨率
    const portrait = reso.some((s) => { const [w, h] = s.split('x').map(Number); return h > w; });
    const landscape = reso.some((s) => { const [w, h] = s.split('x').map(Number); return w > h; });
    console.log(`     → 分片分辨率判据: portrait=${portrait} landscape=${landscape}`);
  }
}
console.log('');

// ---------- 3. 判据交叉验证：status / 下播 ----------
console.log('=== 3. 下播与不存在房间的指纹 ===');
const bad = await jget(
  `https://webcast.amemv.com/webcast/room/info/?${WEB_Q}&room_id=7698007617718995728`,
  { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' },
);
console.log(`  不存在的 room_id → status_code=${bad.json?.status_code} msg=${JSON.stringify(bad.json?.extra?.description || bad.json?.message || bad.json?.status_msg)}`);
const noParam = await jget(
  `https://webcast.amemv.com/webcast/room/info/?${WEB_Q}`,
  { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' },
);
console.log(`  不带 room_id    → HTTP ${noParam.status} status_code=${noParam.json?.status_code} msg=${noParam.json?.status_msg}`);
const byUser = await jget(
  `https://webcast.amemv.com/webcast/room/info_by_user/?${WEB_Q}&user_id=${rooms[0]?.owner?.id_str ?? ''}`,
  { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' },
);
console.log(`  info_by_user    → HTTP ${byUser.status} status_code=${byUser.json?.status_code} dataKeys=${Object.keys(byUser.json?.data || {}).length}`);

// ---------- 4. 观看人数展示字段 ----------
console.log('\n=== 4. 观看人数字段（列表卡片要用哪个）===');
for (const r of rooms.slice(0, 4)) {
  console.log(`  ${r.id_str}: user_count=${r.user_count} stats.total_user=${r.stats?.total_user} ` +
    `stats.user_count_str="${r.stats?.user_count_str}" rv_stats.display_long="${r.room_view_stats?.display_long}" ` +
    `like_count=${r.like_count} category=${r.category} game_tag="${r.game_data?.game_tag_info?.game_tag_name ?? ''}"`);
}
