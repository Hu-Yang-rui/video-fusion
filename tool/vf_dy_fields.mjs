// vf_dy_fields.mjs — webcast/feed 房间对象"精确结构"提取（脱敏）
//
// 目的：把 Q1 关心的字段的确切形状打印出来，而不是靠文档：
//   - status 的确切取值集合 + 伴随的 start_time/finish_time/stream_close_time
//   - stats 对象全部 key（观看人数到底在哪个字段）
//   - stream_url 全部 key + hls_pull_url_map 的档位 key 与 URL 结构
//   - live_core_sdk_data 的真实播放结构（含 quality 名 origin/uhd/hd/sd/ld）
//   - im_info / danmaku_detail（弹幕连接参数是否随 feed 下发）
//   - cover / vertical_cover / dynamic_cover_dict / owner.avatar_thumb
//   - base_category / category / tags / room_tag / tags（分区到底给什么）
//   - web_rid 是否存在（决定能否走 /webcast/room/web/enter/）
//
// 运行：node tool/vf_dy_fields.mjs            # 自动从 feed 取一批
//       node tool/vf_dy_fields.mjs --from=tool/_dy_feed_raw.json  # 复用已落盘（可选）
import fs from 'node:fs';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

const argv = process.argv.slice(2);
const numArg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? Number(a.split('=')[1]) : d; };
const COUNT = numArg('count', 12);

async function getRooms() {
  for (let i = 1; i <= 10; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=${COUNT}&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' },
    });
    const t = await r.text();
    if (!t.trim()) { await new Promise((s) => setTimeout(s, 350 * i)); continue; }
    const j = JSON.parse(t);
    return (Array.isArray(j.data) ? j.data : []).map((e) => e?.data).filter(Boolean);
  }
  return [];
}

const rooms = await getRooms();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
console.log(`=== 取到 ${rooms.length} 个房间（匿名、无签名）===\n`);

const urlShape = (u) => {
  try {
    const x = new URL(u);
    const segs = x.pathname.split('/').filter(Boolean);
    return {
      scheme: x.protocol.replace(':', ''),
      host: x.hostname,
      pathSegs: segs.length,
      lastSeg: segs.at(-1) ?? '',
      queryKeys: [...x.searchParams.keys()].sort(),
      expire: x.searchParams.get('expire'),
      hasSign: !!(x.searchParams.get('sign') || x.searchParams.get('Signature') || x.searchParams.get('x-signature')),
    };
  } catch { return { raw: String(u).slice(0, 40) }; }
};

const r = rooms[0];

// ---- status / 时间 ----
console.log('=== 状态与时间字段 ===');
for (const k of ['status', 'start_time', 'finish_time', 'create_time', 'last_ping_time',
  'stream_close_time', 'book_time', 'book_end_time', 'pre_enter_time', 'lottery_finish_time',
  'is_replay', 'replay', 'replay_location', 'finish_reason', 'finish_url', 'room_audit_status',
  'mosaic_status', 'visibility_range', 'anchor_scheduled_time_text']) {
  console.log(`  ${k} = ${JSON.stringify(r[k])}`);
}
console.log('  status 分布: ' + JSON.stringify(
  rooms.reduce((a, x) => { a[String(x.status)] = (a[String(x.status)] ?? 0) + 1; return a; }, {})));

// ---- stats：观看人数到底在哪 ----
console.log('\n=== stats 对象全部 key ===');
console.log('  ' + JSON.stringify(r.stats, null, 0).slice(0, 900));
console.log('  room_view_stats = ' + JSON.stringify(r.room_view_stats));
console.log('  web_count = ' + JSON.stringify(r.web_count) + ' | user_count = ' + JSON.stringify(r.user_count) +
  ' | popularity = ' + JSON.stringify(r.popularity) + ' | popularity_str = ' + JSON.stringify(r.popularity_str) +
  ' | like_count = ' + JSON.stringify(r.like_count));
console.log('  逐房间 user_count / stats 对比:');
for (const x of rooms) console.log(`    ${x.id_str} user_count=${x.user_count} stats=${JSON.stringify(x.stats)}`);

// ---- 分区 ----
console.log('\n=== 分区相关 ===');
for (const k of ['category', 'base_category', 'tags', 'room_tag', 'content_tag', 'video_feed_tag',
  'game_cp', 'game_data', 'game_room_type', 'live_room_mode', 'live_id', 'cell_style', 'stamps',
  'appearance', 'layout', 'orientation', 'with_draw_something', 'with_ktv', 'with_linkmic']) {
  const v = r[k];
  const s = JSON.stringify(v);
  console.log(`  ${k} = ${s === undefined ? '(absent)' : s.slice(0, 160)}`);
}
console.log('  本批 category/base_category 分布:');
console.log('    ' + rooms.map((x) => `${x.category}/${x.base_category}`).sort().join(' '));
console.log('  tags[0] 结构 = ' + JSON.stringify(Array.isArray(r.tags) ? r.tags[0] : r.tags)?.slice(0, 400));

// ---- stream_url ----
console.log('\n=== stream_url 全部 key ===');
const su = r.stream_url ?? {};
console.log('  keys: ' + Object.keys(su).sort().join(', '));
for (const k of ['default_resolution', 'candidate_resolution', 'quick_connect', 'stream_orientation',
  'hls_pull_url', 'hls_pull_url_map', 'flv_pull_url', 'flv_pull_url_params', 'rtmp_pull_url',
  'ttp_pull_url', 'qa_hls_pull_url_map', 'disable_extra', 'resolution_name', 'sdk_params']) {
  if (k in su) console.log(`  ${k} = ${JSON.stringify(su[k])?.slice(0, 200) ?? 'undefined'}`);
}
console.log('\n  --- hls_pull_url_map 每档 URL 结构 ---');
for (const [q, u] of Object.entries(su.hls_pull_url_map ?? {})) {
  console.log(`    ${q}: ${JSON.stringify(urlShape(u))}`);
}
console.log('\n  --- flv_pull_url（是否真的还有 FLV）---');
console.log('    keys: ' + JSON.stringify(Object.keys(su.flv_pull_url ?? {})) +
  `  (hls_pull_url 顶层单值长度=${(su.hls_pull_url ?? '').length})`);

console.log('\n  --- live_core_sdk_data 结构（去掉超长 stream_data 字符串）---');
const lc = su.live_core_sdk_data ?? {};
const trimDeep = (o, d = 0) => {
  if (typeof o === 'string') return o.length > 60 ? `<str len=${o.length}> ${o.slice(0, 50)}…` : o;
  if (Array.isArray(o)) return o.length > 4 ? `Array(${o.length})` : o.map((x) => trimDeep(x, d + 1));
  if (o && typeof o === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(o)) out[k] = trimDeep(v, d + 1);
    return out;
  }
  return o;
};
console.log('    ' + JSON.stringify(trimDeep(lc), null, 2).slice(0, 6000));

// 解析 stream_data 里的真实档位
try {
  const sdRaw = lc?.pull_data?.stream_data;
  if (typeof sdRaw === 'string') {
    const sd = JSON.parse(sdRaw);
    console.log('\n  --- stream_data 解析 ---');
    console.log('    keys: ' + Object.keys(sd).join(', '));
    const ml = sd?.media_list ?? sd?.data ?? null;
    if (ml) console.log('    media_list 样例: ' + JSON.stringify(trimDeep(Array.isArray(ml) ? ml.slice(0, 3) : ml), null, 1).slice(0, 3000));
    else console.log('    ' + JSON.stringify(trimDeep(sd), null, 1).slice(0, 3000));
  }
} catch (e) { console.log('    stream_data 解析失败: ' + e.message); }

// ---- 弹幕连接参数是否随 feed 下发 ----
console.log('\n=== im_info（弹幕/WS 参数）===');
console.log('  ' + JSON.stringify(trimDeep(r.im_info ?? null), null, 1).slice(0, 2500));
console.log('\n=== danmaku_detail ===');
console.log('  ' + JSON.stringify(trimDeep(r.danmaku_detail ?? null), null, 1).slice(0, 1500));

// ---- owner / cover ----
console.log('\n=== owner 全部 key ===');
console.log('  ' + Object.keys(r.owner ?? {}).sort().join(', '));
const o = r.owner ?? {};
for (const k of ['id_str', 'nickname', 'avatar_thumb', 'avatar_large', 'pay_grade.level', 'id', 'sec_uid',
  'follow_info', 'fansclub', 'verify', 'custom_verify']) {
  console.log(`  owner.${k} = ${JSON.stringify(k.split('.').reduce((a, s) => (a == null ? a : a[s]), o))?.slice(0, 220)}`);
}
console.log('\n=== cover 相关 ===');
for (const k of ['cover', 'auto_cover', 'vertical_cover_uri', 'dynamic_cover_uri', 'dynamic_cover_dict']) {
  const v = r[k];
  if (v && typeof v === 'object' && Array.isArray(v.url_list)) {
    console.log(`  ${k}: url_list(${v.url_list.length}) w=${v.width} h=${v.height} avg=${v.avg_color} ` +
      `shape0=${JSON.stringify(urlShape(v.url_list[0]))}`);
  } else {
    console.log(`  ${k} = ${JSON.stringify(trimDeep(v))?.slice(0, 260)}`);
  }
}

// ---- web_rid / 房间可进入标识 ----
console.log('\n=== 房间标识与进入路径可用字段 ===');
for (const k of ['id', 'id_str', 'web_rid', 'vid', 'group_id', 'share_url', 'room_create_ab_param',
  'anchor_tab_type', 'live_distribution', 'live_platform_source', 'app_id', 'fcdn_appid', 'ticket',
  'enter_type', 'pack_meta']) {
  console.log(`  ${k} = ${JSON.stringify(trimDeep(r[k]))?.slice(0, 200) ?? 'undefined'}`);
}
console.log('  本批 web_rid 出现数: ' + rooms.filter((x) => x.web_rid).length + '/' + rooms.length);

// ---- comment_box / 互动相关（Q7 只读线索）----
console.log('\n=== 互动开关（只读字段，决定送礼/点赞/弹幕 UI 是否可能）===');
for (const k of ['comment_box', 'paid_live_data', 'has_commerce_goods', 'luckymoney_num',
  'gift_msg_style', 'fansclub_msg_style', 'follow_msg_style', 'share_msg_style',
  'webcast_comment_tcs', 'comment_name_mode', 'filter_words', 'sofa_layout', 'linker_detail']) {
  console.log(`  ${k} = ${JSON.stringify(trimDeep(r[k]))?.slice(0, 240) ?? 'undefined'}`);
}

fs.writeFileSync('tool/_dy_feed_fields_sample.json',
  JSON.stringify(rooms.map((x) => ({
    id_str: x.id_str, status: x.status, category: x.category, base_category: x.base_category,
    user_count: x.user_count, stats: x.stats, title: x.title,
    nickname: x.owner?.nickname, uid: x.owner?.id_str,
    cover: x.cover?.url_list?.[0], face: x.owner?.avatar_thumb?.url_list?.[0],
    hlsMap: x.stream_url?.hls_pull_url_map ?? null,
    flvMap: x.stream_url?.flv_pull_url ?? null,
    defaultResolution: x.stream_url?.default_resolution ?? null,
    candidateResolution: x.stream_url?.candidate_resolution ?? null,
    webRid: x.web_rid ?? null, shareUrl: x.share_url ?? null,
    imInfo: x.im_info ?? null, danmaku: x.danmaku_detail ?? null,
    startTime: x.start_time, finishTime: x.finish_time, orientation: x.orientation,
  })), null, 2), 'utf8');
console.log('\n=== 已写 tool/_dy_feed_fields_sample.json ===');
