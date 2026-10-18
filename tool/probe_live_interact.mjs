// 直播互动接口探测：B站 + 抖音。
//
// 第 9 项要求：点赞 / 关注 / 发弹幕。
//
// B站：接口公开，但写操作需要登录凭证（SESSDATA + bili_jct）。
//      这里测"路径是否存在、需要什么"，不伪造凭证。
// 抖音：已测 room/like、room/follow、room/comment 全部 url doesn't match。
//      只有 room/digg 返回 20003（路径存在但需登录/签名）。
//
// 目的：确定哪些是"路径不存在"（做不了）、哪些是"需要登录"（有登录就能做）。

const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function req(url, { ua = UA_WEB, method = 'GET', body = null, referer } = {}) {
  const headers = {
    'user-agent': ua,
    referer: referer || 'https://live.bilibili.com/',
    accept: 'application/json, text/plain, */*',
  };
  if (body) headers['content-type'] = 'application/x-www-form-urlencoded';
  try {
    const r = await fetch(url, { method, headers, body });
    const t = await r.text();
    return { status: r.status, text: t };
  } catch (e) {
    return { status: 0, text: 'ERR ' + e.message };
  }
}

function show(label, r) {
  let code = '?', msg = '';
  try {
    const j = JSON.parse(r.text);
    code = j.code ?? j.status_code ?? '?';
    msg = j.message ?? j.status_msg ?? '';
  } catch {
    code = 'non-json';
  }
  const flag =
    code === -101 ? ' <-需要登录' :
    code === -400 ? ' <-参数错误(路径存在)' :
    code === -404 ? ' <-路径不存在' :
    code === -352 ? ' <-风控' :
    code === 20003 ? ' <-需要登录/签名' :
    msg.includes("doesn't match") ? ' <-路径不存在' : '';
  console.log(
    `  ${label.padEnd(34)} HTTP=${String(r.status).padEnd(4)} ` +
    `code=${String(code).padEnd(7)} ${msg.slice(0, 24)}${flag}`
  );
}

// ---------- 找 B站房间 ----------
console.log('=== 准备：取一个 B站在播房间 ===');
const list = await req(
  'https://api.live.bilibili.com/room/v3/area/getRoomList?platform=web&parent_area_id=0&area_id=0&sort_type=online&page=1&page_size=3'
);
let bRoom = 0;
try {
  bRoom = JSON.parse(list.text).data.list[0].roomid;
} catch {}
console.log('  B站 room_id =', bRoom);
console.log('');

// ---------- B站直播互动 ----------
console.log('=== 9a. B站直播互动（无登录）===');
const biliEndpoints = [
  ['点赞 room/like_report', `https://api.live.bilibili.com/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3?room_id=${bRoom}&uid=0&anchor_id=0`],
  ['关注 relation/modify', `https://api.live.bilibili.com/room/v1/Room/room_entry_action?room_id=${bRoom}&action=1`],
  ['发弹幕 msg/send', `https://api.live.bilibili.com/msg/send`],
  ['历史弹幕 msg/history', `https://api.live.bilibili.com/xlive/web-room/v1/dM/gethistory?roomid=${bRoom}`],
  ['弹幕配置 room/danmu_config', `https://api.live.bilibili.com/xlive/web-room/v1/dM/getDMConfig?room_id=${bRoom}`],
  ['主播信息 live_user/v1', `https://api.live.bilibili.com/live_user/v1/Master/info?uid=1`],
  ['房间关注数 room/getInfoByRoom', `https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom?room_id=${bRoom}`],
];
for (const [name, url] of biliEndpoints) {
  const r = await req(url, { referer: `https://live.bilibili.com/${bRoom}` });
  show(name, r);
}

// 发弹幕需要 POST
console.log('');
const sendRes = await req('https://api.live.bilibili.com/msg/send', {
  method: 'POST',
  body: `msg=test&roomid=${bRoom}&csrf=&csrf_token=`,
  referer: `https://live.bilibili.com/${bRoom}`,
});
show('msg/send POST', sendRes);

// ---------- 抖音 ----------
console.log('');
console.log('=== 9b. 抖音直播互动（无登录）===');
const feed = await (async () => {
  for (let i = 0; i < 6; i++) {
    const r = await req(
      `https://webcast.amemv.com/webcast/feed/?${COMMON}&count=3&type=0`,
      { ua: UA_APP, referer: 'https://live.douyin.com/' }
    );
    if (r.text.trim()) return r;
    await new Promise((res) => setTimeout(res, 400 * (i + 1)));
  }
  return { text: '' };
})();

let dyRoom = '';
if (feed.text) {
  try {
    dyRoom = JSON.parse(feed.text).data[0].data.id_str;
  } catch {}
}
console.log('  抖音 room_id =', dyRoom || '(none)');

if (dyRoom) {
  const dyEndpoints = [
    ['digg (点赞)', `/webcast/room/digg/?${COMMON}&room_id=${dyRoom}`],
    ['like (点赞)', `/webcast/room/like/?${COMMON}&room_id=${dyRoom}`],
    ['follow (关注)', `/webcast/room/follow/?${COMMON}&room_id=${dyRoom}`],
    ['comment (评论)', `/webcast/room/comment/?${COMMON}&room_id=${dyRoom}`],
    ['chat (聊天)', `/webcast/room/chat/?${COMMON}&room_id=${dyRoom}`],
  ];
  for (const [name, path] of dyEndpoints) {
    const r = await req(`https://webcast.amemv.com${path}`, {
      ua: UA_APP,
      referer: 'https://live.douyin.com/',
    });
    show(name, r);
  }
}

// ---------- 结论 ----------
console.log('');
console.log('=== 结论 ===');
console.log('  -101 / 20003  = 路径存在，需要登录凭证 → 有登录就能做');
console.log('  -404 / url does not match = 路径不存在 → 平台没开放，做不了');
