// vf_dy_webrid.mjs — 拿真实 web_rid 并验证 /webcast/room/web/enter/（弹幕链路的前提）
//
// 背景：feed 的房间对象里 web_rid 实测 0/N（不下发）。但 share_url 指向
//   https://webcast.amemv.com/douyin/webcast/reflow/<room_id>
// 是**面向 Web 的房间回流页**，页面里内嵌房间 SSR 数据，含真实 web_rid。
// 上一轮我误用 19 位 room_id 当 web_rid 打 enter/，那次测试无效。
//
// 本探针：
//   1) GET reflow 页（浏览器 UA），从 HTML 里抽 web_rid / room 状态 /流的线索
//   2) 用抽到的**真实 web_rid** 打 /webcast/room/web/enter/（web 参数、匿名）
//      → 这决定"点击直播进入直播间"该调什么，以及能否拿到弹幕所需
//         user_unique_id / 房间真实状态
//   3) 用 reflow 得到的 web_rid 直接拼 live.douyin.com/<web_rid> 页面，
//      检查 HTML 内嵌的 ws 相关参数（signature 不在，但可证明其余参数齐备）
//   4) 顺带确认：enter/ 是否比 room/info 更权威（user_count/status 对比）
//
// 运行：node tool/vf_dy_webrid.mjs
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web' +
  '&version_code=180800&version_name=18.8.0&cookie_enabled=true&screen_width=1536&screen_height=864' +
  '&browser_language=zh-CN&browser_platform=Win32&browser_name=Mozilla' +
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
async function ttwid() {
  try {
    const r = await fetch('https://ttwid.bytedance.com/ttwid/union/register/', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ region: 'cn', aid: 1768, needFid: false, service: 'www.ixigua.com', migrate_info: { ticket: '', source: 'node' }, cbUrlProtocol: 'https', union: true }),
    });
    return (r.headers.get('set-cookie') ?? '').match(/ttwid=([^;]+)/)?.[1] ?? null;
  } catch { return null; }
}

console.log('=== vf_dy_webrid: 真实 web_rid + enter/ 验证 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0], rid = room.id_str;
const tw = await ttwid();
console.log(`样本 room=${rid} title=${JSON.stringify((room.title ?? '').slice(0, 16))} ` +
  `share_url=${(room.share_url ?? '').slice(0, 70)}…  ttwid=${tw ? 'len=' + tw.length : '缺'}`);
console.log('  （说明：本探针不打印任何 cookie 取值）\n');

console.log('── 1) reflow 页（匿名，浏览器 UA）──');
const rf = await fetch(room.share_url, { redirect: 'follow', headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', cookie: tw ? `ttwid=${tw}` : '' } });
const html = await rf.text();
console.log(`  HTTP=${rf.status} finalUrl=${rf.url.slice(0, 90)} len=${html.length} ct=${rf.headers.get('content-type')}`);

// 抽 web_rid：出现在 "web_rid":"7xxxxxx" 或 URL /7xxxxxxx 形式
const grab = (re) => (html.match(re) ?? [])[1] ?? null;
const webRid = grab(/"web_rid"\s*:\s*"?(\d{6,12})"?/) ?? grab(/live\.douyin\.com\/(\d{6,12})/) ?? grab(/webRid\s*[:=]\s*"?(\d{6,12})"?/);
const roomInHtml = grab(/"roomId"\s*:\s*"?(\d{15,20})"?/) ?? grab(/"room_id"\s*:\s*"?(\d{15,20})"?/);
const statusInHtml = grab(/"status"\s*:\s*(\d+)/);
const uidInHtml = grab(/"anchor_id_?\d?_?\w*"\s*:\s*"?(\d{6,20})"?/) ?? grab(/"ownerId"\s*:\s*"?(\d{6,20})"?/);
const hlsInHtml = (html.match(/pull-hls-[a-z0-9-]+\.douyincdn\.com/g) ?? []);
const flvInHtml = (html.match(/pull-flv-[a-z0-9-]+\.douyin\w+\.com/g) ?? []);
const sdkVer = grab(/"webcast_sdk_version"\s*:\s*"([^"]+)"/);
console.log(`  抽到 web_rid=${JSON.stringify(webRid)} roomId=${JSON.stringify(roomInHtml)} status=${JSON.stringify(statusInHtml)}`);
console.log(`  anchor uid=${JSON.stringify(uidInHtml)} hls hosts=${[...new Set(hlsInHtml)].join(',')} flv hosts=${[...new Set(flvInHtml)].join(',')}`);
console.log(`  webcast_sdk_version=${JSON.stringify(sdkVer)}`);
console.log(`  HTML 里 ws/签名线索: signature=${/signature/i.test(html)} ws_url=${/wss:\/\//i.test(html)} ` +
  `ws host=${JSON.stringify((html.match(/wss:\/\/([a-z0-9.-]+)/i) ?? [])[1] ?? null)} ` +
  `user_unique_id=${/"user_unique_id"\s*:\s*"?(\d{6,20})"?/.test(html)}`);
const wsHosts = [...new Set(html.match(/wss:\/\/[a-z0-9.-]+/gi) ?? [])];
console.log(`  wss 地址出现 ${wsHosts.length} 个: ${wsHosts.slice(0, 4).join(' ')}`);

console.log('\n── 2) /webcast/room/web/enter/ 用真实 web_rid（匿名）──');
for (const host of ['webcast.amemv.com', 'live.douyin.com']) {
  for (const id of [webRid, rid]) {
    if (!id) continue;
    const u = `https://${host}/webcast/room/web/enter/?${WEBQ}&web_rid=${id}&enter_from=web_live&enter_method=web_live&publish_video_strategy_type=2&room_id_str=${rid}`;
    try {
      const r = await fetch(u, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', cookie: tw ? `ttwid=${tw}` : '' } });
      const t = await r.text();
      let j = null; try { j = JSON.parse(t); } catch {}
      const d = j?.data;
      const inner = d?.data?.[0] ?? d?.room ?? null;
      console.log(`  ${host} web_rid=${String(id).slice(0, 12)} HTTP=${r.status} len=${t.length}` +
        (j ? ` status_code=${j.status_code}${j.status_msg ? ' msg=' + JSON.stringify(j.status_msg) : ''}` : ' (非JSON)') +
        (inner ? ` → 房间对象 keys=${Object.keys(inner).length} id_str=${inner.id_str} status=${inner.status} uc=${inner.user_count} 档位=[${Object.keys(inner.stream_url?.hls_pull_url_map ?? {}).join(',')}]` :
          (d ? ` → data=${JSON.stringify(d).slice(0, 90)}` : ' → data=-')));
      if (inner) {
        console.log(`      enter 独有字段: ${Object.keys(inner).filter((k) => !(k in room)).slice(0, 25).join(', ') || '(无)'}`);
        console.log(`      link_mask_info / 流: hls_pull_url 顶层 len=${(inner.stream_url?.hls_pull_url ?? '').length} ` +
          `flv_pull_url keys=${JSON.stringify(Object.keys(inner.stream_url?.flv_pull_url ?? {}))}`);
      }
    } catch (e) { console.log(`  ${host} web_rid=${String(id).slice(0, 12)} ERR ${e.message}`); }
  }
}

console.log('\n── 3) live.douyin.com/<web_rid> 页面（进房链路第二跳）──');
if (webRid) {
  const p = await fetch(`https://live.douyin.com/${webRid}`, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', cookie: tw ? `ttwid=${tw}` : '' } });
  const h2 = await p.text();
  console.log(`  HTTP=${p.status} finalUrl=${p.url.slice(0, 80)} len=${h2.length}`);
  console.log(`  含 signature 线索=${/"signature"\s*:/i.test(h2)}  含 web_rid=${h2.includes(String(webRid))} ` +
    `含 用户 uid=${/"user_unique_id"/i.test(h2)} wss=${(h2.match(/wss:\/\/[a-z0-9.-]+/gi) ?? []).slice(0, 2).join(',')}`);
  const g2 = (re) => (h2.match(re) ?? [])[1] ?? null;
  console.log(`  room=${g2(/"roomId"\s*:\s*"?(\d{15,20})"?/)} status=${g2(/"status"\s*:\s*(\d+)/)} ` +
    `user_count=${g2(/"user_count"\s*:\s*(\d+)/)}`);
}

console.log('\n── 4) 权威性对比：room/info vs enter/ vs feed ──');
const info = await fetch(`https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${rid}`, {
  headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } }).then((r) => r.json()).catch(() => null);
console.log(`  feed      : status=${room.status} uc=${room.user_count} tiers=[${Object.keys(room.stream_url?.hls_pull_url_map ?? {}).join(',')}] flvKeys=${Object.keys(room.stream_url?.flv_pull_url ?? {}).length}`);
console.log(`  room/info : status=${info?.data?.status} uc=${info?.data?.user_count} tiers=[${Object.keys(info?.data?.stream_url?.hls_pull_url_map ?? {}).join(',')}] flvKeys=${Object.keys(info?.data?.stream_url?.flv_pull_url ?? {}).length}`);
console.log(`  → feed 的 flv_pull_url 是否为空对象：${Object.keys(room.stream_url?.flv_pull_url ?? {}).length === 0 ? 'YES（App 端不下发 FLV）' : 'no'}`);
console.log(`  → room/info 是否下发 FLV：${Object.keys(info?.data?.stream_url?.flv_pull_url ?? {}).length > 0 ? 'YES' : 'no'}`);
