// vf_dy_roominfo.mjs — 「进入直播间」真实可用端点深挖：room/info_by_user
//
// 上一轮实测发现：/webcast/room/info_by_user/?user_id=<uid>（WEB 参数 + 浏览器 UA）
// **匿名返回 54KB 完整房间对象**，而 /webcast/room/web/enter/ 全部失败。
// 本探针把这个端点彻底摸清：
//   1) 精确参数要求：哪些 query 必填（aid / user_id / room_id / sec_user_id）
//   2) 返回体结构：data 是房间对象还是数组？含哪些 feed 没有的字段
//      （关键：web_rid、status、stream_url、user_count、anchor 信息、
//        以及弹幕需要的 ws 参数）
//   3) 与 feed 同房间的字段差异（谁更权威）
//   4) 下播主播调用它返回什么 → 这就是"进直播间"区分下播的正式手段
//   5) 是否有对应的按 room_id 查详情的变体
// 全部只读 GET，无写操作。
//
// 运行：node tool/vf_dy_roominfo.mjs
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/126.0.0.0 Safari/537.36';
const APPQ =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
// 与项目 dart 里一致的公共 web 参数
const WEBQ =
  'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web' +
  '&version_code=180800&version_name=18.8.0&cookie_enabled=true&screen_width=1536' +
  '&screen_height=864&browser_language=zh-CN&browser_platform=Win32&browser_name=Mozilla' +
  '&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20Chrome/126.0.0.0%20Safari/537.36' +
  '&browser_online=true&timezone_name=Asia/Shanghai';

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
async function hit(label, url, { ua = UA_WEB, ref = 'https://live.douyin.com/', cookie = '' } = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, { headers: { 'user-agent': ua, referer: ref, accept: 'application/json', ...(cookie ? { cookie } : {}) } });
    const txt = await r.text();
    let j = null; try { j = JSON.parse(txt); } catch {}
    const d = j?.data;
    const dKeys = d && typeof d === 'object' ? Object.keys(d) : null;
    console.log(`  ${label.padEnd(48)} HTTP=${r.status} len=${txt.length} ${Date.now() - t0}ms` +
      (j ? ` status_code=${j.status_code}${j.status_msg ? ' msg=' + JSON.stringify(j.status_msg) : ''}` : ' (非JSON)') +
      (d ? ` dataKeys=[${dKeys.slice(0, 14).join(',')}…]` : ''));
    return { json: j, txt, status: r.status };
  } catch (e) { console.log(`  ${label.padEnd(48)} ERR ${e.name}: ${String(e.message).slice(0, 50)}`); return { err: String(e.message) }; }
}

console.log('=== vf_dy_roominfo: webcast/room/info_by_user 深挖 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0];
const uid = room.owner?.id_str;
const sec = room.owner?.sec_uid;
const rid = room.id_str;
console.log(`样本: room=${rid} uid=${uid} nickname=${JSON.stringify(room.owner?.nickname)} ` +
  `display_id=${JSON.stringify(room.owner?.display_id)} sec_uid=${sec ? sec.slice(0, 12) + '…' : '-'}`);

console.log('\n── 1) 参数矩阵：哪些是必填 ──');
const matrix = [
  ['仅 user_id', `user_id=${uid}`],
  ['仅 sec_user_id', `sec_user_id=${sec}`],
  ['user_id + room_id', `user_id=${uid}&room_id=${rid}`],
  ['仅 room_id', `room_id=${rid}`],
  ['空参数', ''],
];
for (const [label, q] of matrix) {
  await hit(`info_by_user [${label}]`,
    `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}${q ? '&' + q : ''}`);
}

console.log('\n── 2) UA / aid 是否敏感 ──');
await hit('info_by_user (App UA + App aid)',
  `https://webcast.amemv.com/webcast/room/info_by_user/?${APPQ}&user_id=${uid}`, { ua: UA_APP });
await hit('info_by_user (WEB UA + App aid)',
  `https://webcast.amemv.com/webcast/room/info_by_user/?${APPQ}&user_id=${uid}`, { ua: UA_WEB });
await hit('info_by_user (live.douyin.com host)',
  `https://live.douyin.com/webcast/room/info_by_user/?${WEBQ}&user_id=${uid}`);
await hit('info_by_user (无 referer)',
  `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${uid}`, { ref: '' });

console.log('\n── 3) 返回体结构（脱敏字段树 + 关键字段）──');
const res = await hit('info_by_user 完整取回',
  `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${uid}`);
const data = res.json?.data;
if (data) {
  console.log(`\n  data 顶层 keys (${Object.keys(data).length}): ${Object.keys(data).sort().join(', ')}`);
  for (const k of ['id_str', 'status', 'title', 'user_count', 'web_rid', 'orientation', 'category',
    'base_category', 'has_replay', 'replay', 'is_replay', 'live_room_mode', 'sec_owner_uid',
    'owner_user_id', 'tag_list', 'mask_operators', 'room_tabs', 'linker_map', 'game_data',
    'official_channel_uid', 'promoter_id', 'anchor_layer_type']) {
    const v = data[k];
    if (v === undefined) continue;
    console.log(`    ${k} = ${typeof v === 'object' ? JSON.stringify(v).slice(0, 120) : JSON.stringify(v)}`);
  }
  console.log(`\n  --- 房间对象里"feed 没有"的字段（对进房关键）---`);
  const feedKeys = new Set(Object.keys(room));
  const extra = Object.keys(data).filter((k) => !feedKeys.has(k));
  const missing = [...feedKeys].filter((k) => !(k in data));
  console.log(`    info_by_user 独有: ${extra.slice(0, 40).join(', ')}${extra.length > 40 ? ' …' : ''}`);
  console.log(`    feed 独有: ${missing.slice(0, 40).join(', ')}${missing.length > 40 ? ' …' : ''}`);

  console.log('\n  --- 播放流 ---');
  const su = data.stream_url ?? {};
  console.log(`    stream_url keys: ${Object.keys(su).sort().join(', ')}`);
  console.log(`    default_resolution=${JSON.stringify(su.default_resolution)} ` +
    `candidate=${JSON.stringify(su.candidate_resolution)}`);
  const hm = su.hls_pull_url_map ?? {};
  console.log(`    hls_pull_url_map 档位: [${Object.keys(hm).join(',')}]`);
  console.log(`    flv_pull_url keys: ${JSON.stringify(Object.keys(su.flv_pull_url ?? {}))} ` +
    `hls_pull_url 顶层长度=${(su.hls_pull_url ?? '').length}`);
  for (const [q, u] of Object.entries(hm)) {
    const x = new URL(u);
    console.log(`      ${q}: host=${x.hostname} scheme=${x.protocol.replace(':', '')} query=[${[...x.searchParams.keys()].join(',')}]`);
  }
  // live_play / 多档位新字段
  for (const k of ['live_play', 'play', 'pull_datas', 'hls_trial', 'pay_live', 'stream_control']) {
    if (data[k] !== undefined || su[k] !== undefined)
      console.log(`    ${k} = ${JSON.stringify(data[k] ?? su[k])?.slice(0, 160)}`);
  }

  console.log('\n  --- 主播 / 在线 / 弹幕所需 ---');
  const o = data.owner ?? {};
  console.log(`    owner keys: ${Object.keys(o).sort().join(', ').slice(0, 400)}`);
  console.log(`    owner.web_rid=${JSON.stringify(o.web_rid ?? null)} owner.display_id=${JSON.stringify(o.display_id ?? null)} ` +
    `owner.sec_uid=${(o.sec_uid ?? '').slice(0, 10)}…`);
  console.log(`    stats=${JSON.stringify(data.stats)?.slice(0, 300)}`);
  console.log(`    room_view_stats=${JSON.stringify(data.room_view_stats)?.slice(0, 240)}`);
  console.log(`    user_count=${JSON.stringify(data.user_count)} popularity=${JSON.stringify(data.popularity)}`);
  console.log(`    im_info=${JSON.stringify(data.im_info)?.slice(0, 220)}`);
  console.log(`    danmaku_detail=${JSON.stringify(data.danmaku_detail)}`);
  console.log(`    ticket=${JSON.stringify(data.ticket ?? null)}  ← 弹幕 ws 是否需要`);
  console.log(`    其它 ws 线索 keys: ${Object.keys(data).filter((k) => /ws|im_|push|sign|token|did/i.test(k)).join(', ') || '(无)'}`);

  console.log('\n  --- 与 feed 同房间对比（谁更权威）---');
  console.log(`    feed:  user_count=${room.user_count} status=${room.status} title=${JSON.stringify((room.title ?? '').slice(0, 16))} ` +
    `档位=[${Object.keys(room.stream_url?.hls_pull_url_map ?? {}).join(',')}]`);
  console.log(`    info:  user_count=${data.user_count} status=${data.status} title=${JSON.stringify((data.title ?? '').slice(0, 16))} ` +
    `档位=[${Object.keys(data.stream_url?.hls_pull_url_map ?? {}).join(',')}]`);

  console.log('\n  --- 该 data 里房间数组形式？(有些端点返回 data.data[]) ---');
  if (Array.isArray(data.data)) console.log(`    data.data[] 长度=${data.data.length}`);
  else console.log('    data.data 不存在（直接是房间对象）');
  console.log(`    extra=${JSON.stringify(data.extra ?? null)?.slice(0, 260)}`);
  console.log(`    顶层(非data) keys=${Object.keys(res.json).join(', ')}`);
}

console.log('\n── 4) 下播主播（status != 直播中）返回什么 ──');
// 用 feed 里出现过的 uid 之外，取一个"多半没在播"的：owner 的 uid 但强制查
// 更可靠的做法：连查多个 uid，看是否存在 data 为空 / status 非 2 的样本
for (const r of rooms.slice(1, 5)) {
  const res2 = await hit(`info_by_user uid=${r.owner?.id_str}`,
    `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${r.owner?.id_str}`);
  const d2 = res2.json?.data;
  console.log(`      → status=${d2?.status} user_count=${d2?.user_count} 档位=[${Object.keys(d2?.stream_url?.hls_pull_url_map ?? {}).join(',')}] ` +
    `title=${JSON.stringify((d2?.title ?? '').slice(0, 14))}`);
}
// 一个不存在的 uid，看错误形态
for (const bad of ['1', '0', '9999999999999999999']) {
  const res3 = await hit(`info_by_user uid=${bad} (非法/不存在)`,
    `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${bad}`);
  console.log(`      → status_code=${res3.json?.status_code} msg=${JSON.stringify(res3.json?.status_msg ?? null)} ` +
    `data=${res3.json?.data ? '存在' : 'null/缺失'} head=${JSON.stringify(res3.txt?.slice(0, 90))}`);
}

console.log('\n── 5) 按 room_id 查详情的其它候选（带 WEB 参数）──');
for (const p of ['webcast/room/info/', 'webcast/room/info_by_id/', 'webcast/room/enter/',
  'webcast/room/web/enter/', 'webcast/room/list_by_room/', 'webcast/room/status/']) {
  await hit(p, `https://webcast.amemv.com/${p}?${WEBQ}&room_id=${rid}&web_rid=${rid}`);
}

console.log('\n── 6) 弹幕历史（只读，判断"无 ws 时能否拿历史弹幕"）──');
for (const p of ['webcast/room/chat_history/', 'webcast/chat/history/', 'webcast/room/barrage_list/',
  'webcast/room/danmaku/history/']) {
  await hit(p, `https://webcast.amemv.com/${p}?${WEBQ}&room_id=${rid}`);
}
