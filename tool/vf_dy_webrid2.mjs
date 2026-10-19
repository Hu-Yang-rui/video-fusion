// vf_dy_webrid2.mjs — 找**真实 web_rid** 并复验 /webcast/room/web/enter/
//
// 之前失败原因：feed 不下发 web_rid，而我拿 19 位 room_id 当 web_rid 打 enter/，
// 那次测试是无效的。抖音的真实"房间号"（web_rid）是 6~12 位短号，出现在：
//   a) 主播主页/直播页 https://live.douyin.com/<web_rid>
//   b) owner.display_id / owner.short_id 有时就是可访问的号
// 本探针：从 reflow 页 + live.douyin.com/<display_id> 的 SSR HTML 里正则出 web_rid 与
// roomId，再用**真 web_rid** 打 enter/，给出该端点到底可不可用的最终结论。
//
// 运行：node tool/vf_dy_webrid2.mjs
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';

async function feed() {
  for (let i = 1; i <= 10; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return [];
}
const pick = (re, s) => (s.match(re) ?? [])[1] ?? null;

console.log('=== vf_dy_webrid2: 真实 web_rid 定位 + enter/ 终判 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0];
console.log(`房间=${room.id_str} display_id=${JSON.stringify(room.owner?.display_id)} short_id=${JSON.stringify(room.owner?.short_id)}`);

console.log('\n── 1) reflow 页里找 web_rid（多种正则）──');
const rr = await fetch(room.share_url, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
const html = await rr.text();
console.log(`  reflow HTTP=${rr.status} len=${html.length} final=${rr.url.slice(0, 76)}`);
const pats = [
  [/"web_rid"\s*:\s*"?(\d{4,14})"?/g, 'web_rid'],
  [/"roomId"\s*:\s*"?(\d{15,20})"?/g, 'roomId'],
  [/live\.douyin\.com\/(\d{4,14})/g, 'live.douyin.com/<num>'],
  [/"web_rid"\s*:\s*"([a-zA-Z0-9_]{4,20})"/g, 'web_rid(可能字母)'],
  [/"anchor_id_str"\s*:\s*"?(\d{6,20})"?/g, 'anchor_id_str'],
  [/"status"\s*:\s*(\d+)/g, 'status'],
];
let webRid = null;
for (const [re, name] of pats) {
  const ms = [...new Set((html.match(re) ?? []).map((x) => x.replace(/[^\w]/g, '')))].slice(0, 6);
  const v = pick(re, html);
  if (name === 'web_rid' && v) webRid = v;
  console.log(`  ${name.padEnd(20)} → ${JSON.stringify(ms)}`);
}
console.log(`  HTML 是否含 "signature" 字样=${/signature/i.test(html)}  含 wss://=${/wss:\/\//i.test(html)}`);

console.log('\n── 2) 用 display_id 走 live.douyin.com（房间号可能是短号）──');
for (const id of [room.owner?.display_id, String(room.owner?.short_id ?? '')]) {
  if (!id || id === '0' || id === 'undefined') continue;
  let p, h;
  try {
    p = await fetch(`https://live.douyin.com/${id}`, { headers: { 'user-agent': UA_WEB } });
    h = await p.text();
  } catch (e) { console.log(`  live.douyin.com/${id} ERR ${e.name}`); continue; }
  const wr = pick(/"web_rid"\s*:\s*"?(\d{4,14})"?/, h);
  console.log(`  live.douyin.com/${id} HTTP=${p.status} final=${p.url.slice(0, 74)} len=${h.length}`);
  console.log(`      roomId=${pick(/"roomId"\s*:\s*"?(\d{15,20})"?/, h)}  web_rid=${JSON.stringify(wr)}  ` +
    `status=${pick(/"status"\s*:\s*(\d+)/, h)}  user_count=${pick(/"user_count"\s*:\s*(\d+)/, h)}`);
  console.log(`      wss=${(h.match(/wss:\/\/[a-z0-9.-]+/i) ?? ['(无)'])[0]}  含 signature 字段=${/"signature"\s*:/i.test(h)} ` +
    `user_unique_id=${/"user_unique_id"\s*:\s*"?(\d{6,20})"?/.test(h)}`);
  if (wr && !webRid) webRid = wr;
  // 检查 SSR 里是否有 room 数组（瑞玉数据通常在 RENDER_DATA）
  const render = pick(/<script[^>]+id="RENDER_DATA"[^>]*>([^<]+)</, h);
  console.log(`      RENDER_DATA 存在=${!!render}${render ? ' len=' + render.length : ''}`);
}

console.log('\n── 3) enter/ 终判：用抽到的 web_rid（若无则用 19 位 room_id 再确认一次）──');
const target = webRid ?? room.id_str;
console.log(`  使用 web_rid=${target} ${webRid ? '(真实短号)' : '(⚠️ 没抽到短号，退化成 19 位 room_id)'}`);
for (const host of ['webcast.amemv.com', 'live.douyin.com']) {
  const u = `https://${host}/webcast/room/web/enter/?${WEBQ}&web_rid=${target}&enter_from=web_live&publish_video_strategy_type=2`;
  try {
    const r = await fetch(u, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    let j = null; try { j = JSON.parse(t); } catch {}
    const inner = j?.data?.data?.[0] ?? j?.data?.room ?? null;
    console.log(`  ${host} HTTP=${r.status} len=${t.length}` +
      (j ? ` status_code=${j.status_code}${j.status_msg ? ' msg=' + JSON.stringify(j.status_msg) : ''}` : ' (非 JSON)') +
      (inner ? ` → 房间 keys=${Object.keys(inner).length} id_str=${inner.id_str} status=${inner.status}` : '') +
      (!inner && j?.data ? ` → data=${JSON.stringify(j.data).slice(0, 80)}` : ''));
  } catch (e) { console.log(`  ${host} ERR ${e.name}: ${String(e.message).slice(0, 40)}`); }
}

console.log('\n── 4) 若拿到真 web_rid：room/info 用 19 位仍可用？（对照）──');
{
  const u = `https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${room.id_str}`;
  const r = await fetch(u, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
  const j = await r.json().catch(() => null);
  console.log(`  room/info HTTP=${r.status} status_code=${j?.status_code} 房间=${j?.data?.id_str} status=${j?.data?.status} ` +
    `档位=${Object.keys(j?.data?.stream_url?.hls_pull_url_map ?? {}).length}`);
}
