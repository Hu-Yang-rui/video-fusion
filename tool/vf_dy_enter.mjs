// vf_dy_enter.mjs — 「点击直播进入直播间」该调哪个接口：逐个实测候选端点
//
// 项目文档说 /webcast/room/web/enter/ 返回 url doesn't match，但那是用 **App aid=1128 +
// App UA** 打的。抖音的 web 端房间进入接口是给 **web aid=6383 + 浏览器 UA + live.douyin.com
// 域**用的，参数集完全不同。feed 返回里 **没有 web_rid**（实测 0/6），所以只能先用
// room 的 id_str / share_url 试。
//
// 本探针系统性地测这些候选（全部只读 GET，不带任何写操作）：
//   A. live.douyin.com 域 + 浏览器 UA + aid=6383 的 /webcast/room/web/enter/
//   B. webcast.amemv.com 域 + App UA + aid=1128（复现文档结论）
//   C. /webcast/room/info_by_user/、/webcast/room/info/（按 room_id）
//   D. /webcast/setting/、/webcast/user/relation/updated/ 等旁路
//   E. share_url（reflow 页）能否解析出 room 信息与 web_rid
//   F. a.wish 域：/webcast/room/  HTML 里是否内嵌 room 状态（SSR）
// 每个记录：HTTP、status_code、status_msg、body 长度、是否有 data。
//
// 运行：node tool/vf_dy_enter.mjs
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/126.0.0.0 Safari/537.36';
const APPQ =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ =
  'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web' +
  '&version_code=180800&version_name=18.8.0&cookie_enabled=true&screen_width=1536' +
  '&screen_height=864&browser_language=zh-CN&browser_platform=Win32' +
  '&browser_name=Mozilla&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)' +
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
async function hit(label, url, { ua = UA_APP, ref = 'https://live.douyin.com/', cookie = null } = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, {
      redirect: 'follow',
      headers: { 'user-agent': ua, referer: ref, accept: 'application/json, text/plain, */*', ...(cookie ? { cookie } : {}) },
    });
    const b = Buffer.from(await r.arrayBuffer());
    const txt = b.toString('utf8');
    let sc = null, sm = null, hasData = false, dataType = null, keys = null;
    try {
      const j = JSON.parse(txt);
      sc = j.status_code ?? j.StatusCode ?? null;
      sm = j.status_msg ?? j.StatusMsg ?? null;
      hasData = j.data !== undefined && j.data !== null;
      dataType = Array.isArray(j.data) ? `Array(${j.data.length})` : (j.data && typeof j.data === 'object' ? `Object{${Object.keys(j.data).join(',').slice(0, 60)}}` : typeof j.data);
      keys = Object.keys(j).slice(0, 25).join(',');
    } catch { /* html */ }
    const isHtml = /^\s*</.test(txt);
    console.log(`  ${label.padEnd(46)} HTTP=${r.status} len=${b.length} ${Date.now() - t0}ms` +
      (sc !== null ? ` status_code=${sc}` : '') + (sm ? ` status_msg=${JSON.stringify(sm)}` : '') +
      (isHtml ? ` <HTML> title=${JSON.stringify((txt.match(/<title[^>]*>([^<]*)</)?.[1] ?? '').slice(0, 30))}` :
        (hasData ? ` data=${dataType}` : ' data=-')) +
      (keys ? ` keys=[${keys}]` : '') + (txt.length && !isHtml ? ` head=${JSON.stringify(txt.slice(0, 70))}` : ''));
    return { status: r.status, len: b.length, txt, isHtml, sc, sm, hasData };
  } catch (e) {
    console.log(`  ${label.padEnd(46)} ERR ${e.name}: ${String(e.message).slice(0, 60)}`);
    return { err: `${e.name}: ${e.message}` };
  }
}

console.log('=== vf_dy_enter: 进入直播间候选端点实测（只读）===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0];
const rid = room.id_str;
const uid = room.owner?.id_str ?? room.owner?.uid ?? '';
const secUid = room.owner?.sec_uid ?? '';
const share = room.share_url ?? '';
console.log(`样本房间 id_str=${rid} owner=${uid} web_rid=${JSON.stringify(room.web_rid ?? null)} ` +
  `owner.web_rid=${JSON.stringify(room.owner?.web_rid ?? null)} share_url=${share.slice(0, 60)}…\n`);

console.log('── A. live.douyin.com / webcast.amemv.com + WEB 参数（aid=6383, 浏览器 UA）──');
await hit('room/web/enter (web_rid=room.id_str)',
  `https://live.douyin.com/webcast/room/web/enter/?${WEBQ}&web_rid=${rid}&enter_from=web_live&publish_video_strategy_type=2`);
await hit('room/web/enter (amemv host, web q)',
  `https://webcast.amemv.com/webcast/room/web/enter/?${WEBQ}&web_rid=${rid}&enter_from=web_live&publish_video_strategy_type=2`);
await hit('room/web/enter (amemv host, app q)',
  `https://webcast.amemv.com/webcast/room/enter/?${APPQ}&room_id=${rid}`);
await hit('room/info_by_user (uid, web q)',
  `https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${uid}`);
await hit('room/info_by_id (room_id, web q)',
  `https://webcast.amemv.com/webcast/room/info_by_id/?${WEBQ}&room_id=${rid}`);

console.log('\n── B. 复现文档结论：App aid + App UA ──');
await hit('room/web/enter (app q + app UA)',
  `https://webcast.amemv.com/webcast/room/web/enter/?${APPQ}&web_rid=${rid}`);
await hit('room/feed (app q)',
  `https://webcast.amemv.com/webcast/room/feed/?${APPQ}&count=5`);
await hit('room/list (app q)',
  `https://webcast.amemv.com/webcast/room/list/?${APPQ}&count=5`);
await hit('room/partition (app q)',
  `https://webcast.amemv.com/webcast/room/partition/?${APPQ}`);

console.log('\n── C. 更多候选（room 详情类，逐个探）──');
for (const p of ['webcast/room/info/', 'webcast/room/status/', 'webcast/room/preview/',
  'webcast/room/barrage/', 'webcast/room/chat/', 'webcast/room/user/',
  'webcast/room/list_by_category/', 'webcast/room/search/', 'webcast/feed/category/',
  'webcast/category/list/', 'webcast/room/anchor/', 'webcast/room/get/', 'webcast/room/detail/']) {
  await hit(p + ' [room_id]', `https://webcast.amemv.com/${p}?${APPQ}&room_id=${rid}&count=5`);
}

console.log('\n── D. share_url / reflow 页（能否换出 web_rid）──');
if (share) await hit('share_url (reflow, 跟随重定向)', share, { ua: UA_WEB });

console.log('\n── E. 用 owner.sec_uid 走 user 主页（web 域）──');
await hit('live.douyin.com/{web_rid} HTML',
  `https://live.douyin.com/${rid}`, { ua: UA_WEB, ref: 'https://live.douyin.com/' });

console.log('\n── F. 检查 feed 里 web_rid 是否任何房间有 ──');
const withWeb = rooms.filter((r) => r.web_rid);
console.log(`  本批 ${rooms.length} 房间中 web_rid 存在数 = ${withWeb.length}`);
console.log(`  owner.web_rid 存在数 = ${rooms.filter((r) => r.owner?.web_rid).length}`);
for (const r of rooms.slice(0, 4)) {
  console.log(`    ${r.id_str} web_rid=${JSON.stringify(r.web_rid ?? null)} owner.web_rid=${JSON.stringify(r.owner?.web_rid ?? null)} ` +
    `display_id=${JSON.stringify(r.owner?.display_id ?? null)} short_id=${JSON.stringify(r.owner?.short_id ?? null)}`);
}
