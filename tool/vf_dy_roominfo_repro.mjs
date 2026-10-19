// vf_dy_roominfo_repro.mjs — 复现对方的 len=0（把每个可疑维度单独翻转）
//
// 已坐实（vf_dy_roominfo_ablate.mjs）：
//   · 长 web 参数集 → 56780B/165 字段（8/8 成功）
//   · 对方的短参数集（aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800）
//     在我这里同样 → 56803B/165 字段 ✅
//   · 必需参数只有 3 个：aid、device_platform、version_code（删掉任一个 → len=0）
//   · aid=1128 → len=0（这就是最常见的踩坑点）
//   · UA 不敏感（Chrome/空/App/curl 都通）、cookie 不敏感、无需预热
//   · 只有 webcast.amemv.com 通；live.douyin.com → 18B；webcast.bytedance.com → 546B
//
// 那对方为什么稳定 len=0？本脚本逐一翻转到 len=0 的形态，找出可复现的成因。
//
// 运行：node tool/vf_dy_roominfo_repro.mjs
import fs from 'node:fs';

const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701';
const SHORT = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';

async function feed() {
  for (let i = 1; i <= 10; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&device_type=Pixel7&os_version=13&channel=googleplay&language=zh&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return [];
}
async function hit(url, headers = {}, method = 'GET') {
  try {
    const r = await fetch(url, { method, headers });
    const b = Buffer.from(await r.arrayBuffer());
    let j = null; try { j = JSON.parse(b.toString('utf8')); } catch {}
    const d = j?.data;
    return { status: r.status, len: b.length, sc: j?.status_code, msg: j?.status_msg,
      keys: d && typeof d === 'object' ? Object.keys(d).length : 0, idStr: d?.id_str ?? null, body: b.subarray(0, 60).toString('latin1') };
  } catch (e) { return { status: 0, len: 0, keys: 0, err: `${e.name}` }; }
}
const line = (label, r) => console.log(`  ${label.padEnd(52)} HTTP=${r.status} len=${String(r.len).padStart(6)} data字段=${String(r.keys).padStart(3)}${r.sc !== undefined ? ' sc=' + r.sc : ''}${r.msg ? ' msg=' + JSON.stringify(r.msg) : ''}${r.idStr ? ' ✅' + r.idStr : ' ❌'}${r.err ? ' ERR=' + r.err : ''}`);

console.log('=== vf_dy_roominfo_repro: 找出 len=0 的可复现成因 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const rid = rooms[0].id_str;
const url = (q, id = rid) => `https://webcast.amemv.com/webcast/room/info/?${q}&room_id=${id}`;
const base = { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', accept: 'application/json, text/plain, */*' };

console.log('\n── A) 基线（对方短参数集 + 当前 feed 房间）──');
line('短参数 + Chrome UA + referer', await hit(url(SHORT), base));

console.log('\n── B) 单个可疑维度翻转 ──');
line('去掉 referer', await hit(url(SHORT), { 'user-agent': UA_WEB, accept: 'application/json' }));
line('去掉 accept', await hit(url(SHORT), { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' }));
line('去掉 user-agent', await hit(url(SHORT), { referer: 'https://live.douyin.com/' }));
line('全部 header 都不带', await hit(url(SHORT), {}));
line('room_id 放在参数最前', await hit(`https://webcast.amemv.com/webcast/room/info/?room_id=${rid}&${SHORT}`, base));
line('用 http:// 而非 https://', await hit(url(SHORT).replace('https://', 'http://'), base));
line('末尾多一个斜杠', await hit(url(SHORT) + '/', base));
line('不带末尾斜杠 /webcast/room/info', await hit(`https://webcast.amemv.com/webcast/room/info?${SHORT}&room_id=${rid}`, base));
line('HEAD 方法', await hit(url(SHORT), base, 'HEAD'));
line('多带 count=5', await hit(url(SHORT + '&count=5'), base));
line('browser_version 未 URL 编码（原样空格）', await hit(`https://webcast.amemv.com/webcast/room/info/?${SHORT}&browser_version=${'5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0'}&room_id=${rid}`, base));

console.log('\n── C) 最可能的两个踩坑 ──');
line('aid=1128（App aid）', await hit(url(SHORT.replace('aid=6383', 'aid=1128')), base));
line('device_platform=android', await hit(url(SHORT.replace('device_platform=web', 'device_platform=android')), base));
line('缺 device_platform', await hit(url(SHORT.replace('&device_platform=web', '')), base));
line('缺 version_code', await hit(url(SHORT.replace('&version_code=180800', '')), base));
line('缺 aid', await hit(url(SHORT.replace('aid=6383&', '')), base));
line('room_id 用 id（JS number，精度丢失）', await hit(url(SHORT, String(rooms[0].id)), base));
line('room_id 用 owner uid', await hit(url(SHORT, rooms[0].owner?.id_str), base));
line('参数名写成 room_id_str', await hit(`https://webcast.amemv.com/webcast/room/info/?${SHORT}&room_id_str=${rid}`, base));
line('参数名写成 id_str', await hit(`https://webcast.amemv.com/webcast/room/info/?${SHORT}&id_str=${rid}`, base));

console.log('\n── D) 用对方那 4 个 room_id 复跑（他们报 len=0）──');
const theirIds = ['7698026888077331215', '7697996024301832969', '7697991152271723273', '7698028394847439643'];
for (const id of theirIds) {
  const r1 = await hit(url(SHORT, id), base);
  const r2 = await hit(url(SHORT, id), base); // 第二次，看是否间歇
  console.log(`  ${id} → 第1次 len=${r1.len} 字段=${r1.keys}${r1.sc !== undefined ? ' sc=' + r1.sc : ''} | 第2次 len=${r2.len} 字段=${r2.keys}`);
}

console.log('\n── E) 用历史快照里的房间 id（可能已下播）──');
for (const f of ['tool/_dy_feed_streams.json', 'tool/_dy_feed_fields_sample.json']) {
  let ids = [];
  try {
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    ids = (j.rooms ?? j).map((x) => x.roomId ?? x.id_str).filter(Boolean).slice(0, 4);
  } catch { continue; }
  console.log(`  来自 ${f}: ${ids.join(', ')}`);
  for (const id of ids) line(`  ${id}`, await hit(url(SHORT, id), base));
}

console.log('\n── F) 时间维度：同房间连续 12 次（看是否间歇性空 body）──');
const res = [];
for (let i = 0; i < 12; i++) {
  const r = await hit(url(SHORT), base);
  res.push(r.len);
  process.stdout.write(` #${i + 1}=${r.len}`);
  await new Promise((s) => setTimeout(s, 250));
}
console.log('\n  body 长度序列: ' + JSON.stringify(res));
console.log(`  → 非零 ${(res.filter((x) => x > 0).length)}/12；空 body ${(res.filter((x) => x === 0).length)}/12`);
console.log('  结论：' + (res.every((x) => x > 0) ? 'room/info **不**间歇性空 body（与 feed 不同）' : 'room/info **也会**间歇性空 body → 适配器必须重试'));
