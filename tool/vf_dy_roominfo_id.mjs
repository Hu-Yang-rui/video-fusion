// vf_dy_roominfo_id.mjs — 「按 room_id 进房」端点确认 + 未开播语义
//
// 上一轮意外发现：`webcast/room/info/?<WEB参数>&room_id=<19位>` **匿名返回 56KB**，
// 而项目文档认为按 room_id 查详情没有可用端点。本探针把它坐实：
//   1) room/info 参数矩阵（room_id 必填？要不要 room_id_str？App aid 行不行？
//      live.douyin.com host 行不行？）
//   2) 返回体与 info_by_user / feed 的差异（字段数、档位、user_count 新鲜度）
//   3) 拿不到流时（不存在的 room_id）返回什么 → "房间不存在" 的指纹
//   4) **未开播**语义：用短视频推荐流里真实主播 uid 调 info_by_user，
//      看"账号存在但没在播"返回什么（这决定点进直播间时怎么提示"主播暂未开播"）
//   5) 过期地址复用：对同一条 hls 地址等待/篡改，比对下播后的状态码
//
// 运行：node tool/vf_dy_roominfo_id.mjs
import fs from 'node:fs';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web' +
  '&version_code=180800&version_name=18.8.0&cookie_enabled=true&screen_width=1536&screen_height=864' +
  '&browser_language=zh-CN&browser_platform=Win32&browser_name=Mozilla' +
  '&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20Chrome/126.0.0.0%20Safari/537.36' +
  '&browser_online=true&timezone_name=Asia/Shanghai';

async function hit(label, url, { ua = UA_WEB, ref = 'https://live.douyin.com/' } = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, { headers: { 'user-agent': ua, referer: ref, accept: 'application/json' } });
    const txt = await r.text();
    let j = null; try { j = JSON.parse(txt); } catch {}
    const d = j?.data;
    console.log(`  ${label.padEnd(44)} HTTP=${r.status} len=${txt.length} ${Date.now() - t0}ms` +
      (j ? ` status_code=${j.status_code}` : ' (非JSON)') +
      (j?.status_msg ? ` msg=${JSON.stringify(j.status_msg)}` : '') +
      (d && d.id_str ? ` room=${d.id_str} status=${d.status} uc=${d.user_count} tiers=[${Object.keys(d.stream_url?.hls_pull_url_map ?? {}).join(',')}] keys=${Object.keys(d).length}` : '') +
      (d && !d.id_str ? ` data=${JSON.stringify(d).slice(0, 90)}` : '') +
      (d === undefined || d === null ? ` data=-` : '') +
      (!j ? ` head=${JSON.stringify(txt.slice(0, 50).replace(/\s+/g, ' '))}` : ''));
    return { json: j, txt, status: r.status };
  } catch (e) { console.log(`  ${label.padEnd(44)} ERR ${e.name}: ${String(e.message).slice(0, 40)}`); return {}; }
}
async function feed() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 350 * i));
  }
  return [];
}

console.log('=== vf_dy_roominfo_id: room/info（按 room_id）坐实 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0], rid = room.id_str, uid = room.owner?.id_str;
console.log(`样本 room=${rid} uid=${uid}\n`);

console.log('── 1) room/info 参数矩阵 ──');
await hit('room/info?room_id (WEB q)', `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${rid}`);
await hit('room/info?room_id_str', `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id_str=${rid}`);
await hit('room/info 两个都给', `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${rid}&room_id_str=${rid}`);
await hit('room/info 无参数', `https://webcast.amemv.com/webcast/room/info/?${WEBQ}`);
await hit('room/info (App q+App UA)', `https://webcast.amemv.com/webcast/room/info/?${APPQ}&room_id=${rid}`, { ua: UA_APP });
await hit('room/info (App q+WEB UA)', `https://webcast.amemv.com/webcast/room/info/?${APPQ}&room_id=${rid}`);
await hit('room/info (live.douyin.com)', `https://live.douyin.com/webcast/room/info/?${WEBQ}&room_id=${rid}`);
await hit('room/info (webcast.amemv + enter_from)',
  `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${rid}&enter_from=web_live&enter_method=feed&publish_video_strategy_type=2`);

console.log('\n── 2) 三方一致性（feed / room/info / info_by_user 同一时刻）──');
const a = await hit('feed 样本(基准)', 'about:blank').catch(() => {});
const b = await hit('room/info', `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${rid}`);
const c = await hit('info_by_user', `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${uid}`);
const cmp = (j) => {
  const d = j?.json?.data ?? {};
  return {
    room: d.id_str ?? null, status: d.status ?? null, uc: d.user_count ?? null,
    title: (d.title ?? '').slice(0, 10), tiers: Object.keys(d.stream_url?.hls_pull_url_map ?? {}),
    flv: Object.keys(d.stream_url?.flv_pull_url ?? {}).length,
    hlsTop: (d.stream_url?.hls_pull_url ?? '').length,
    keys: Object.keys(d).length,
    expire: (() => { const u = Object.values(d.stream_url?.hls_pull_url_map ?? {})[0]; try { return new URL(u).searchParams.get('expire'); } catch { return null; } })(),
    statsTotal: d.stats?.total_user ?? null,
  };
};
console.log(`  feed        : ${JSON.stringify({ room: rid, status: room.status, uc: room.user_count, tiers: Object.keys(room.stream_url?.hls_pull_url_map ?? {}), flv: Object.keys(room.stream_url?.flv_pull_url ?? {}).length, hlsTop: (room.stream_url?.hls_pull_url ?? '').length, keys: Object.keys(room).length })}`);
console.log(`  room/info   : ${JSON.stringify(cmp(b))}`);
console.log(`  info_by_user: ${JSON.stringify(cmp(c))}`);

console.log('\n── 3) 不存在的 room_id → "房间不存在" 指纹 ──');
for (const bad of ['1', '0', '7698007617718995728', '9999999999999999999']) {
  await hit(`room/info room_id=${bad}`, `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${bad}`);
}

console.log('\n── 4) 未开播语义：用短视频侧真实主播 uid 查（多数不在直播）──');
let authors = [];
try {
  const r = await fetch(`https://api.amemv.com/aweme/v1/feed/?${APPQ}&refresh_index=1&channel=googleplay&count=10`, {
    headers: { 'user-agent': UA_APP } });
  const j = JSON.parse(await r.text());
  authors = (j.aweme_list ?? []).map((x) => ({ uid: x.author?.uid_str ?? String(x.author?.id ?? ''), nick: x.author?.nickname ?? '' })).slice(0, 8);
  console.log(`  从 aweme/v1/feed 取到 ${authors.length} 个真实主播 uid`);
} catch (e) { console.log('  取短视频主播失败:', e.message); }
const offlineSamples = [];
for (const a of authors) {
  const res = await hit(`info_by_user uid=${a.uid} (${(a.nick || '').slice(0, 8)})`,
    `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${a.uid}`);
  const d = res.json?.data;
  const empty = !d || Object.keys(d).length === 0;
  offlineSamples.push({ uid: a.uid, empty, status: d?.status ?? null, keys: d ? Object.keys(d).length : 0 });
  console.log(`      → ${empty ? 'data={} 空对象（未在播/无房间）' : `data 有 ${Object.keys(d).length} 字段 status=${d.status}`}`);
}
fs.writeFileSync('tool/_dy_offline_semantics.json', JSON.stringify(offlineSamples, null, 2), 'utf8');
console.log(`  汇总：空 data 的样本 ${offlineSamples.filter((x) => x.empty).length}/${offlineSamples.length}`);

console.log('\n── 5) 房间 id_str 从 feed 消失后（模拟下播）：room/info 仍返回吗 ──');
// 用上一轮已抓到的旧 room id（_dy_feed_streams.json 里的第一条，可能已下播）
try {
  const old = JSON.parse(fs.readFileSync('tool/_dy_feed_streams.json', 'utf8'));
  const oldIds = old.rooms.map((r) => r.roomId).slice(0, 3);
  for (const id of oldIds) {
    const res = await hit(`旧房间 room/info ${id}`, `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${id}`);
    const d = res.json?.data ?? {};
    console.log(`      → status=${d.status ?? '无'} 档位=[${Object.keys(d.stream_url?.hls_pull_url_map ?? {}).join(',')}] ` +
      `title=${JSON.stringify((d.title ?? '').slice(0, 12))}`);
    // 若仍返回播放地址，实测它是否已失效
    const u = Object.values(d.stream_url?.hls_pull_url_map ?? {})[0];
    if (u) {
      try {
        const rr = await fetch(u, { headers: { 'user-agent': UA_APP } });
        console.log(`      → 该流地址实测 HTTP=${rr.status}（403=已失效/签名过期）`);
      } catch (e) { console.log(`      → 该流地址实测 ERR ${e.message}`); }
    }
  }
} catch (e) { console.log('  (无历史样本文件，跳过)'); }
