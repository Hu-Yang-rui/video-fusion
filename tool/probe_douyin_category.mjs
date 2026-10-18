// 抖音 category 码 → 可读分区名 的映射探测。
//
// 8b 已确认 feed 返回真实的 category 值（7171/1128/448/545/7832/546/1129/1127/3019）。
// 这些是抖音内部码，需要映射成展示名。
//
// 思路：
//   1. 大样本采集 category，看稳定出现的有哪些
//   2. 用每个 category 的代表房间的 title/owner 反推它属于什么品类
//   3. 检查是否有接口能直接给出映射
//
// 如果拿不到权威映射，就**只展示数据里真实出现的分区**，
// 用「该分类下有多少个直播间」这种客观信息，不编造品类名。

const UA =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

async function get(url, tries = 8) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(url, {
        headers: {
          'user-agent': UA,
          referer: 'https://live.douyin.com/',
          accept: 'application/json, text/plain, */*',
        },
      });
      const t = await r.text();
      if (t.trim()) return t;
    } catch {}
    await new Promise((res) => setTimeout(res, 350 * (i + 1)));
  }
  return '';
}

// 采集 8 批，记录每个 category 的代表性房间
const byCat = new Map();
let batches = 0;

for (let i = 0; i < 8; i++) {
  const t = await get(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=20&type=0`);
  if (!t) continue;
  batches++;
  try {
    const p = JSON.parse(t);
    for (const e of p.data ?? []) {
      const d = e.data;
      if (!d) continue;
      const c = d.category;
      if (c === undefined) continue;
      if (!byCat.has(c)) byCat.set(c, []);
      const arr = byCat.get(c);
      if (arr.length < 4) {
        arr.push({
          title: (d.title || '').slice(0, 26),
          nick: (d.owner?.nickname || '').slice(0, 16),
          base: d.base_category,
        });
      }
    }
  } catch {}
  await new Promise((res) => setTimeout(res, 600));
}

console.log(`采集批次: ${batches}/8`);
console.log(`出现过的 category 数: ${byCat.size}`);
console.log('');

const sorted = [...byCat.entries()].sort((a, b) => b[1].length - a[1].length);
console.log('=== category 码 → 样本房间（用于人工判定品类）===');
for (const [cat, samples] of sorted) {
  console.log(`\ncategory=${cat}  (base=${samples[0]?.base})`);
  for (const s of samples) {
    console.log(`   ${s.nick.padEnd(16)} | ${s.title}`);
  }
}

// 按 base_category 归组
const byBase = new Map();
for (const [cat, samples] of sorted) {
  const b = samples[0]?.base;
  if (b === undefined) continue;
  if (!byBase.has(b)) byBase.set(b, new Set());
  byBase.get(b).add(cat);
}
console.log('');
console.log('=== base_category 归组 ===');
for (const [b, cats] of [...byBase.entries()].sort()) {
  console.log(`  base=${b} -> categories ${[...cats].join(',')}`);
}
