// vf_dy_feed_paging.mjs — feed 分页/分区/更多参数实测（决定"加载更多"怎么做）
//
// 已知：每批固定 6 条房间（count=10/12/20 都给 6），文档称"无游标、重复请求给不同集合"。
// 本探针坐实：
//   1) count 上限：count=1/2/5/6/8/10/20/50 各给几条？
//   2) offset 是否真的翻页：offset=0/6/12/20，与 offset=0 的集合去重后新增多少？
//   3) 连续重复请求（同参数）新增房间数 → 能否靠"重新取一批"堆出列表
//   4) type=0/1/2 与 partition_id/category_id/secondary_category_id 等服务端筛选是否生效
//   5) 返回体里是否有游标字段（max_time/offset/has_more/refresh...）
//   6) gift/list 匿名可用性（Q7 的"能做"部分）
//
// 运行：node tool/vf_dy_feed_paging.mjs
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const FEED = 'https://webcast.amemv.com/webcast/feed/';

async function call(extra, tries = 8) {
  for (let i = 1; i <= tries; i++) {
    const r = await fetch(`${FEED}?${COMMON}&${extra}`, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) {
      try { return { status: r.status, json: JSON.parse(t), len: t.length }; }
      catch { return { status: r.status, bad: true, len: t.length }; }
    }
    await new Promise((s) => setTimeout(s, 250 * i));
  }
  return { status: 200, empty: true, tries };
}
const roomsOf = (j) => (Array.isArray(j?.data) ? j.data : []).map((e) => e?.data).filter(Boolean);

console.log('=== vf_dy_feed_paging ===\n');

console.log('── 1) count 上限 ──');
for (const c of [1, 2, 5, 6, 8, 10, 20, 50]) {
  const r = await call(`count=${c}&offset=0&type=0`);
  const n = roomsOf(r.json).length;
  console.log(`  count=${String(c).padStart(2)} → HTTP=${r.status} 房间=${r.empty ? '0(空body,' + r.tries + '次)' : n} body=${r.len}B`);
}

console.log('\n── 2) offset 是否翻页 ──');
const seen = new Set();
for (const off of [0, 6, 12, 20, 40]) {
  const r = await call(`count=10&offset=${off}&type=0`);
  const ids = roomsOf(r.json).map((x) => x.id_str);
  const fresh = ids.filter((x) => !seen.has(x));
  fresh.forEach((x) => seen.add(x));
  const cursorish = Object.keys(r.json ?? {}).filter((k) => /offset|cursor|max_time|min_time|has_more|refresh|page|scene|log_id|forward/i.test(k));
  console.log(`  offset=${String(off).padStart(2)} → 房间=${ids.length} 其中新=${fresh.length} 累计去重=${seen.size} 顶层游标类字段=[${cursorish.join(',')}]`);
}
const topKeys = Object.keys((await call('count=6&offset=0&type=0')).json ?? {});
console.log(`  顶层 key: ${topKeys.join(', ')}`);

console.log('\n── 3) 同参数连续 6 次能堆出多少不重复房间 ──');
const acc = new Set();
for (let i = 0; i < 6; i++) {
  const r = await call('count=12&offset=0&type=0');
  const ids = roomsOf(r.json).map((x) => x.id_str);
  ids.forEach((x) => acc.add(x));
  process.stdout.write(`    第${i + 1}次 ${ids.length}条/累计${acc.size}  `);
}
console.log('\n');

console.log('── 4) 服务端筛选参数是否生效（看返回房间 category 是否被约束）──');
const cats = new Map();
const base = roomsOf((await call('count=12&offset=0&type=0')).json);
for (const r of base) cats.set(r.category, (cats.get(r.category) ?? 0) + 1);
console.log(`  基线 category 分布: ${JSON.stringify(Object.fromEntries(cats))}`);
for (const extra of ['type=1', 'type=2', 'type=4', 'partition_id=412', 'category_id=545',
  'secondary_category_id=545', 'live_id=1&category=545', 'enter_from=vertical_live',
  'count=12&offset=0&type=0&channel=1&filter_with_no_password=0', 'count=12&offset=0&type=0&source=category']) {
  const r = await call(extra);
  const rooms = roomsOf(r.json);
  const cs = [...new Set(rooms.map((x) => x.category))];
  const sm = r.json?.status_msg;
  console.log(`  ${extra.padEnd(52)} → 房间=${r.empty ? '0(空,' + r.tries + ')' : rooms.length}` +
    ` category=[${cs.join(',')}]${sm ? ' status_msg=' + JSON.stringify(sm) : ''}`);
}

console.log('\n── 5) gift/list 匿名可用性（只读）──');
const rooms = roomsOf((await call('count=12&offset=0&type=0')).json);
const rid = rooms[0]?.id_str;
const uid = rooms[0]?.owner?.id_str;
const gl = await fetch(`https://webcast.amemv.com/webcast/gift/list/?aid=6383&app_name=aweme&device_platform=web&version_code=180800&room_id=${rid}&user_id=${uid}`, {
  headers: { 'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36', referer: 'https://live.douyin.com/' } });
const gj = await gl.json().catch(() => null);
if (gj) {
  const gifts = gj.data?.gifts ?? [];
  const groups = gj.data?.gifts_info?.gift_group_infos ?? [];
  console.log(`  HTTP=${gl.status} len=${JSON.stringify(gj).length} status_code=${gj.status_code}`);
  console.log(`  gifts=${Array.isArray(gifts) ? gifts.length : typeof gifts}  gift_group_infos=${Array.isArray(groups) ? groups.length : typeof groups}`);
  const g0 = Array.isArray(gifts) ? gifts[0] : null;
  if (g0) console.log(`  首个礼物字段: ${Object.keys(g0).slice(0, 18).join(', ')}`);
  if (g0) console.log(`  样例: id=${g0.id} name=${JSON.stringify(g0.name)} diamond_price=${g0.diamond_count} icon=${(g0.icon?.url_list?.[0] ?? '').slice(0, 40)}…`);
  if (Array.isArray(groups) && groups[0]) console.log(`  分组样例: ${JSON.stringify(groups[0]).slice(0, 180)}`);
  console.log(`  → 结论：礼物面板数据匿名可取（但发送仍需登录+签名，见 vf_dy_interact.mjs）`);
} else console.log('  gift/list 非 JSON');
