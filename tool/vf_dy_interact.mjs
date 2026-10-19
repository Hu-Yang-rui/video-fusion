// vf_dy_interact.mjs — 送礼/点赞/关注/发弹幕：接口存在性与鉴权档位（严格只读）
//
// 规则：本探针**不发送任何会改变账号数据的请求**。判定方法只有三种：
//   1) 对目标路径发**无 body 的 GET / HEAD**（抖音这些接口是 POST，GET 只会命中路由层，
//      返回 "url doesn't match" / 参数错误 / 未登录，不会写入任何数据）
//   2) OPTIONS 预检（只探测路由与 CORS，不执行动作）
//   3) 已知的**只读**伴生接口（礼物列表、房间设置）确认可得性
// 结论分三档：能做 / 不能做 / 需要 Argus（项目不实现）。
//
// 运行：node tool/vf_dy_interact.mjs
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';

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
async function probe(label, url, method, { ua = UA_WEB, ref = 'https://live.douyin.com/' } = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, { method, headers: { 'user-agent': ua, referer: ref, accept: 'application/json' } });
    const txt = await r.text();
    let j = null; try { j = JSON.parse(txt); } catch {}
    const sc = j?.status_code, sm = j?.status_msg;
    const msg = j?.data?.message ?? j?.data?.prompts ?? null;
    console.log(`  ${method.padEnd(6)} ${label.padEnd(38)} HTTP=${r.status} len=${txt.length} ${Date.now() - t0}ms` +
      (sc !== undefined ? ` status_code=${sc}` : '') + (sm ? ` msg=${JSON.stringify(sm)}` : '') +
      (msg ? ` data.message=${JSON.stringify(msg)}` : '') +
      (!j && txt ? ` head=${JSON.stringify(txt.slice(0, 60).replace(/\s+/g, ' '))}` : '') +
      (j?.data && !msg ? ` data=${JSON.stringify(j.data).slice(0, 70)}` : ''));
    return { status: r.status, j, txt };
  } catch (e) { console.log(`  ${method.padEnd(6)} ${label.padEnd(38)} ERR ${e.name}: ${String(e.message).slice(0, 50)}`); return { err: String(e.message) }; }
}

console.log('=== vf_dy_interact: 互动接口存在性（只读探测，零写入）===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0], rid = room.id_str, uid = room.owner?.id_str;
console.log(`样本房间 ${rid} 主播 uid=${uid}\n`);

console.log('── 1) 写接口：GET 探测路由层（不构造 POST body，不会执行动作）──');
const writePaths = [
  ['发弹幕', 'webcast/room/chat/send/', 'webcast.im/send.message/'],
  ['点赞', 'webcast/room/digg/', 'webcast.digg/'],
  ['送礼', 'webcast/gift/send/', 'webcast.gift.send/'],
  ['关注主播', 'webcast/room/follow/', ' relation/follow/', 'user/follow/'],
];
await probe('chat/send (webcast)', `https://webcast.amemv.com/webcast/room/chat/send/?${WEBQ}&room_id=${rid}&content=test`, 'GET');
await probe('im/send.message (aweme 域)', `https://aweme.snssdk.com/aweme/v1/webcast/im/send/message/`, 'GET');
await probe('room/digg (点赞)', `https://webcast.amemv.com/webcast/room/digg/?${WEBQ}&room_id=${rid}`, 'GET');
await probe('gift/send', `https://webcast.amemv.com/webcast/gift/send/?${WEBQ}&room_id=${rid}`, 'GET');
await probe('webcast 关注', `https://webcast.amemv.com/webcast/room/follow/?${WEBQ}&room_id=${rid}&to_uid=${uid}`, 'GET');

console.log('\n── 2) OPTIONS 预检（只看路由/CORS 是否存在，不执行）──');
for (const p of ['webcast/room/chat/send/', 'webcast/room/digg/', 'webcast/gift/send/', 'webcast/room/web/enter/']) {
  await probe(p, `https://webcast.amemv.com/${p}?${WEBQ}&room_id=${rid}`, 'OPTIONS');
}

console.log('\n── 3) 只读伴生接口：能否拿到"礼物列表/弹幕配置"（决定 UI 能否展示）──');
for (const p of ['webcast/gift/list/', 'webcast/gift/config/', 'webcast/gift/icons/',
  'webcast/room/gift/list/', 'webcast/chat/config/', 'webcast/comment/config/']) {
  const r = await probe(p, `https://webcast.amemv.com/${p}?${WEBQ}&room_id=${rid}`, 'GET');
}
console.log('\n── 4) App 域（aweme）互动接口路由是否存在（只 GET，不带 body）──');
for (const p of ['aweme/v1/comment/publish/', 'aweme/v1/digg/', 'aweme/v1/commit/follow/user/',
  'aweme/v1/user/', 'aweme/v1/feed/']) {
  await probe(p, `https://api.amemv.com/${p}?${APPQ}`, 'GET', { ua: UA_APP });
}
console.log('\n── 5) 直播房间设置（只读，判断弹幕是否被房主关闭）──');
console.log(`  feed 字段: comment_box=${JSON.stringify(room.comment_box)?.slice(0, 200)}`);
console.log(`             webcast_comment_tcs=${JSON.stringify(room.webcast_comment_tcs)} ` +
  `comment_name_mode=${JSON.stringify(room.comment_name_mode)} filter_words 数=${(room.filter_words ?? []).length}`);
console.log(`             paid_live_data=${JSON.stringify(room.paid_live_data)?.slice(0, 160)}`);
console.log(`             luckymoney_num=${JSON.stringify(room.luckymoney_num)}`);
