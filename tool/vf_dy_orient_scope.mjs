// vf_dy_orient_scope.mjs — stream_orientation 到底在哪一层（room 顶层 vs stream_url）
//
// 为什么必须查：Dart 里 isPortrait 写的是 `room['stream_orientation']`，
// 而所有探针此前读的是 `room.stream_url.stream_orientation`。
// 若平台只在 stream_url 里下发，`room['stream_orientation']` 恒为 null，
// 判据就永远不成立 → 所有房间都按横屏渲染（竖屏直播被压成中间小条）。
//
// 同时对照 feed 与 room/info 两个端点，因为 Dart 两条路径都会走。
//
// 运行：node tool/vf_dy_orient_scope.mjs
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; ' +
  'Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const APPQ =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const MIN = { aid: '6383', device_platform: 'web', version_code: '180800' };
const HOST = 'https://webcast.amemv.com';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const enc = (o) => Object.entries(o).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');

async function getJson(url, ua = UA_APP) {
  try {
    const r = await fetch(url, { headers: { 'user-agent': ua, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (!t.trim()) return null;
    return JSON.parse(t);
  } catch { return null; }
}

let rooms = [];
for (let i = 1; i <= 15 && rooms.length < 6; i++) {
  const j = await getJson(`${HOST}/webcast/feed/?${APPQ}&count=20&offset=0&type=0`);
  for (const e of (j?.data ?? [])) if (e?.data?.id_str) rooms.push(e.data);
  await sleep(300);
}
console.log(`=== vf_dy_orient_scope: 房间数 ${rooms.length} ===\n`);
console.log('room_key           顶层 stream_orientation  stream_url.stream_orientation  extra.w/h  顶层 orientation  → 方向');

let topLevelHits = 0;
for (const r of rooms) {
  const su = r.stream_url ?? {};
  const top = r.stream_orientation;
  if (top !== undefined) topLevelHits++;
  const w = su.extra?.width ?? '?';
  const h = su.extra?.height ?? '?';
  const dir = (typeof w === 'number' && typeof h === 'number') ? (h > w ? '竖屏' : '横屏') : '未知';
  console.log(`${r.id_str}  ${top === undefined ? 'ABSENT(undefined)' : top}`.padEnd(46) +
    `${su.stream_orientation}`.padEnd(28) + `${w}x${h} ${dir}  top.orientation=${r.orientation}`);
}
console.log(`\n顶层 stream_orientation 有值的房间: ${topLevelHits}/${rooms.length}`);
console.log('→ 若为 0，则 Dart 的 room["stream_orientation"] 恒 null，必须改成 room["stream_url"]["stream_orientation"]');

// room/info 路径同样检查
console.log('\n── room/info 侧 ──');
{
  const rid = rooms[0]?.id_str;
  if (!rid) { console.log('无样本'); process.exit(0); }
  const j = await getJson(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`,
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36');
  const d = j?.data ?? {};
  console.log(`  data['stream_orientation']       = ${JSON.stringify(d.stream_orientation)}`);
  console.log(`  data['stream_url']['stream_orientation'] = ${JSON.stringify(d.stream_url?.stream_orientation)}`);
  console.log(`  data['orientation']              = ${JSON.stringify(d.orientation)}`);
  console.log(`  data['stream_url']['extra']      = ${JSON.stringify(d.stream_url?.extra)}`);
  console.log(`  data['user_count']               = ${JSON.stringify(d.user_count)}`);
  console.log(`  data['status']                   = ${JSON.stringify(d.status)}`);
  console.log(`  data 顶层含 'extra' 前缀的 key   = ${Object.keys(d).filter((k) => /orient|rotation/i.test(k)).join(', ') || '(无)'}`);
  // room/info 的 status_code 分支样本
  const bad = await getJson(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=1`);
  console.log(`  不存在房间: status_code=${bad?.status_code} status_msg=${JSON.stringify(bad?.status_msg)} prompts=${JSON.stringify(bad?.prompts)} data=${JSON.stringify(bad?.data)}`);
}
