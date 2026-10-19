// vf_dy_roominfo_diff.mjs — 定位对方 len=0 的确切参数成因
//
// 读对方 tool/vf_dy_portrait.mjs 得到其 WEB_Q：
//   aid=6383&app_name=aweme&channel=channel_pc_web&pc_client_type=1
//   &version_code=170400&version_name=17.4.0&platform=PC
// 我的 WEB_Q：
//   aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800
// 差异候选：① **缺 device_platform=web**（消融已证明 device_platform 是必需项）
//          ② channel 值不同 ③ version_code 不同 ④ 多了 platform=PC / pc_client_type
// 本脚本逐条隔离验证，每种组合打 3 次取稳定结论。
//
// 运行：node tool/vf_dy_roominfo_diff.mjs
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function feedRoom() {
  for (let i = 1; i <= 12; i++) {
    try {
      const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
        headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
      const t = await r.text();
      if (t.trim()) {
        const rooms = (JSON.parse(t).data ?? []).map((e) => e?.data).filter(Boolean);
        if (rooms.length) return rooms[0];
      }
    } catch {}
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return null;
}
async function probe(q, rid) {
  const lens = []; let ok = 0; let sc = null;
  for (let i = 0; i < 3; i++) {
    try {
      const r = await fetch(`https://webcast.amemv.com/webcast/room/info/?${q}&room_id=${rid}`, {
        headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
      const t = await r.text();
      lens.push(t.length);
      try { const j = JSON.parse(t); sc = j?.status_code ?? sc; if (j?.data && Object.keys(j.data).length > 50) ok++; } catch {}
    } catch { lens.push(-1); }
    await new Promise((s) => setTimeout(s, 150));
  }
  return { ok, lens, sc };
}
const room = await feedRoom();
if (!room) { console.log('feed 拿不到房间，终止'); process.exit(1); }
const rid = room.id_str;
console.log('=== vf_dy_roominfo_diff ===');
console.log(`样本房间 ${rid}  stream_orientation=${room.stream_url?.stream_orientation}\n`);

const THEIRS = 'aid=6383&app_name=aweme&channel=channel_pc_web&pc_client_type=1&version_code=170400&version_name=17.4.0&platform=PC';
const MINE = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';

const cases = [
  ['① 对方原样（无 device_platform）', THEIRS],
  ['② 对方 + device_platform=web', THEIRS.replace('&version_code=', '&device_platform=web&version_code=')],
  ['③ 对方但 version_code=180800', THEIRS.replace('version_code=170400', 'version_code=180800')],
  ['④ 对方 + device_platform=web + vc=180800', THEIRS.replace('&version_code=170400', '&device_platform=web&version_code=180800')],
  ['⑤ 我的（channel_id_web + dp=web）', MINE],
  ['⑥ channel_pc_web + dp=web + vc=180800', 'aid=6383&app_name=aweme&channel=channel_pc_web&device_platform=web&version_code=180800'],
  ['⑦ 无 channel + dp=web', 'aid=6383&app_name=aweme&device_platform=web&version_code=180800'],
  ['⑧ vc=170400 + dp=web', 'aid=6383&device_platform=web&version_code=170400'],
  ['⑨ vc=170400 无 dp（只改 version_code 隔离）', 'aid=6383&version_code=170400'],
  ['⑩ 只 aid + dp=web', 'aid=6383&device_platform=web'],
  ['⑪ dp=android（错误值）', 'aid=6383&device_platform=android&version_code=180800'],
  ['⑫ dp=webapp', 'aid=6383&device_platform=webapp&version_code=180800'],
];
for (const [label, q] of cases) {
  const r = await probe(q, rid);
  console.log(`  ${label.padEnd(42)} 成功 ${r.ok}/3  长度=[${r.lens.join(',')}]${r.sc !== null ? ' sc=' + r.sc : ''}`);
}

console.log('\n── 单变量隔离：只加/去 device_platform ──');
for (const [label, q] of [
  ['对方串 + 仅补 device_platform=web', THEIRS + '&device_platform=web'],
  ['我的串 仅删 device_platform', MINE.replace('&device_platform=web', '')],
]) {
  const r = await probe(q, rid);
  console.log(`  ${label.padEnd(42)} 成功 ${r.ok}/3  长度=[${r.lens.join(',')}]`);
}

console.log('\n── 顺带：info_by_user 用对方 WEB_Q 是否也通 ──');
{
  const uid = room.owner?.id_str;
  for (const [label, q] of [['对方 WEB_Q', THEIRS], ['我的 WEB_Q', MINE], ['对方 WEB_Q + dp=web', THEIRS + '&device_platform=web']]) {
    let ok = 0; const lens = [];
    for (let i = 0; i < 2; i++) {
      const r = await fetch(`https://webcast.amemv.com/webcast/room/info_by_user/?${q}&user_id=${uid}`, {
        headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
      const t = await r.text(); lens.push(t.length);
      try { if (Object.keys(JSON.parse(t)?.data ?? {}).length > 50) ok++; } catch {}
    }
    console.log(`  info_by_user ${label.padEnd(18)} 成功 ${ok}/2 长度=[${lens.join(',')}]`);
  }
}
