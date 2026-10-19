// vf_dy_roominfo_verify.mjs — 独立复核 /webcast/room/info/ 是否匿名可用
//
// 为什么要自己再打一遍：上游先给出"0/54 全败"，又更正为"必需参数只有
// aid=6383 + device_platform=web + version_code"。这个结论要直接决定
// Dart 侧是否接入该端点，必须本地坐实，不能转述。
//
// 验证 5 件事：
//   A) 三参数最小集是否成功（含删掉任一个是否失败）
//   B) 是否间歇（同房间连打 6 次）
//   C) 参数名 room_id vs room_id_str vs id_str
//   D) room/info 与 feed 的字段可得性差异（顶层 hls_pull_url / flv_pull_url）
//   E) user_count 是否比 feed 新鲜
//
// 运行：node tool/vf_dy_roominfo_verify.mjs
const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/126.0.0.0 Safari/537.36';
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; ' +
  'Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const APPQ =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const HOST = 'https://webcast.amemv.com';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const enc = (o) => Object.entries(o).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');

async function get(url, { ua = UA_WEB, headers = {} } = {}) {
  try {
    const r = await fetch(url, {
      headers: { 'user-agent': ua, referer: 'https://live.douyin.com/', accept: 'application/json, text/plain, */*', ...headers },
      redirect: 'manual',
    });
    const b = await r.text();
    let j = null; try { j = JSON.parse(b); } catch {}
    return { status: r.status, len: b.length, json: j };
  } catch (e) { return { status: 0, len: 0, json: null, err: `${e.name}:${String(e.message).slice(0, 40)}` }; }
}
const brief = (r) => {
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  return `HTTP=${r.status} len=${r.len}` +
    (r.json ? ` sc=${r.json.status_code}${r.json.status_msg ? ' msg=' + JSON.stringify(r.json.status_msg) : ''}` : ' (非JSON)') +
    ` dataKeys=${keys}` + (r.err ? ` ERR=${r.err}` : '');
};

// ── 先拿一个真实房间号（feed 匿名可用）─────────────────────────
console.log('=== vf_dy_roominfo_verify ===');
let room = null;
for (let i = 1; i <= 12 && !room; i++) {
  const r = await get(`${HOST}/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, { ua: UA_APP });
  if (r.len) {
    const rooms = (r.json?.data ?? []).map((e) => e?.data).filter((d) => d?.id_str);
    if (rooms.length) room = rooms[0];
  }
  await sleep(300);
}
if (!room) { console.log('feed 取不到房间，无法继续'); process.exit(1); }
const rid = room.id_str;
console.log(`样本房间 room_id=${rid}（字符串）status=${room.status} stream_orientation=${room.stream_url?.stream_orientation}`);
console.log(`feed 侧: user_count=${room.user_count} 顶层hls长度=${(room.stream_url?.hls_pull_url ?? '').length} flv键数=${Object.keys(room.stream_url?.flv_pull_url ?? {}).length}\n`);

const MIN = { aid: '6383', device_platform: 'web', version_code: '180800' };

console.log('── A) 最小三参数集 + 逐变量消融 ──');
console.log(`  全集            ${enc(MIN)}&room_id=${rid}`);
let ok = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`);
console.log(`  → ${brief(ok)}`);
const roomData = ok.json?.data ?? {};
for (const drop of ['device_platform', 'aid', 'version_code']) {
  const o = { ...MIN }; delete o[drop];
  const r = await get(`${HOST}/webcast/room/info/?${enc(o)}&room_id=${rid}`);
  console.log(`  删 ${drop.padEnd(16)} → ${brief(r)}`);
  await sleep(150);
}
for (const dp of ['webapp', 'android', 'pc']) {
  const r = await get(`${HOST}/webcast/room/info/?${enc({ ...MIN, device_platform: dp })}&room_id=${rid}`);
  console.log(`  device_platform=${dp.padEnd(8)} → ${brief(r)}`);
  await sleep(150);
}

console.log('\n── UA 敏感度（同一最小参数集）──');
for (const [label, ua] of [['Chrome UA', UA_WEB], ['App UA', UA_APP], ['空 UA', '']]) {
  const r = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`, { ua });
  console.log(`  ${label.padEnd(10)} → ${brief(r)}`);
}
{
  // 完全不带任何 header
  const r = await fetch(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`);
  const t = await r.text();
  console.log(`  裸请求(header 仅 host) → HTTP=${r.status} len=${t.length}`);
}

console.log('\n── B) 间歇性：同房间连打 6 次 ──');
const lens = [];
for (let i = 0; i < 6; i++) {
  const r = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`);
  const d = r.json?.data;
  lens.push({ len: r.len, keys: d && typeof d === 'object' ? Object.keys(d).length : 0 });
  console.log(`  #${i + 1} len=${r.len} dataKeys=${lens[i].keys}${r.json?.status_code !== undefined ? ' sc=' + r.json.status_code : ''}`);
  await sleep(200);
}
console.log(`  → 6 次里成功 ${lens.filter((x) => x.keys > 50).length} 次`);

console.log('\n── C) 参数名维度 ──');
for (const name of ['room_id', 'room_id_str', 'id_str', 'roomId']) {
  const r = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&${name}=${rid}`);
  console.log(`  ${name.padEnd(12)} → ${brief(r)}`);
  await sleep(120);
}

console.log('\n── C2) 精度丢失坑：number 中转后的末位变化 ──');
{
  const asNum = Number(rid);
  const back = String(asNum);
  console.log(`  原字符串 ${rid} → Number → ${back}  ${back === rid ? '（本环境精度够用）' : '❌ 末位已丢，请求必得 30001'}`);
  const r = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${back}`);
  console.log(`  用丢精度值请求 → ${brief(r)}${r.json?.prompts ? ' prompts=' + JSON.stringify(r.json.prompts) : ''}`);
}

console.log('\n── C3) 不存在的房间指纹 ──');
{
  const r = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=1`);
  console.log(`  room_id=1 → ${brief(r)} prompts=${JSON.stringify(r.json?.prompts ?? null)}`);
}

console.log('\n── C4) 域名维度 ──');
for (const host of ['webcast.amemv.com', 'live.douyin.com', 'webcast.bytedance.com']) {
  const r = await get(`https://${host}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`);
  console.log(`  ${host.padEnd(22)} → ${brief(r)}`);
  await sleep(120);
}

console.log('\n── D) room/info vs feed 字段可得性 ──');
const su = roomData.stream_url ?? {};
console.log(`  room/info: data 字段数=${Object.keys(roomData).length} stream_url 字段数=${Object.keys(su).length}`);
console.log(`    hls_pull_url_map keys = ${JSON.stringify(Object.keys(su.hls_pull_url_map ?? {}))}`);
console.log(`    顶层 hls_pull_url 长度 = ${(su.hls_pull_url ?? '').length}  ← feed 实测 0`);
console.log(`    flv_pull_url keys = ${JSON.stringify(Object.keys(su.flv_pull_url ?? {}))}  ← feed 实测 {}`);
console.log(`    resolution_name = ${JSON.stringify(su.resolution_name)}`);
console.log(`    stream_orientation = ${su.stream_orientation}  顶层 orientation = ${roomData.orientation}`);
console.log(`    web_rid = ${JSON.stringify(roomData.web_rid)}  有 ticket = ${!!su.ticket}  cover 有 = ${!!roomData.cover?.url_list?.length}`);
const sdStr = su.live_core_sdk_data?.pull_data?.stream_data;
console.log(`    live_core_sdk_data...stream_data 类型 = ${typeof sdStr}` +
  (typeof sdStr === 'string' ? ` len=${sdStr.length} data keys=${Object.keys(JSON.parse(sdStr).data ?? {}).join(',')}` : ''));

console.log('\n── E) user_count 新鲜度（feed vs room/info vs 再请求）──');
{
  const r1 = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`);
  await sleep(1200);
  const r2 = await get(`${HOST}/webcast/room/info/?${enc(MIN)}&room_id=${rid}`);
  console.log(`  feed=${room.user_count} → room/info#${1}=${r1.json?.data?.user_count} → room/info#2=${r2.json?.data?.user_count}`);
}

console.log('\n── F) 顶层响应键（判断是否需二次包 data）──');
console.log(`  ${Object.keys(ok.json ?? {}).join(', ')}`);
