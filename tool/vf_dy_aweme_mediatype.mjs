// vf_dy_aweme_mediatype.mjs — 推荐流混发图文帖的实测判据（media_type 4 vs 42）
//
// 为什么必须查：抖音短视频推荐流里出现"点开只有声音没有画面"的黑屏。
// 怀疑是 feed 混发了图文帖（images post），它的 play_addr 指向 .mp3。
// 本探针穷举每条 aweme 的地址字段，把两类条目的判据与真实 Content-Type 分开坐实。
//
// 运行：node tool/vf_dy_aweme_mediatype.mjs [--batches=6]
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 14; zh_CN; ' +
  'Pixel 7; Build/UQ1A; Cronet/TTNetVersion)';
const argv = process.argv.slice(2);
const numArg = (n, d) => {
  const a = argv.find((s) => s.startsWith(`--${n}=`));
  return a ? Number(a.split('=')[1]) : d;
};
const BATCHES = numArg('batches', 6);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function json(url) {
  try {
    const r = await fetch(url, { headers: { 'user-agent': UA_APP, accept: 'application/json' } });
    const t = await r.text();
    if (!t.trim()) return { status: r.status, len: 0, json: null };
    return { status: r.status, len: t.length, json: JSON.parse(t) };
  } catch (e) { return { status: 0, len: 0, json: null, err: `${e.name}:${String(e.message).slice(0, 40)}` }; }
}

// 穷举一条 aweme 里所有 "像地址" 的字段
function collectUrls(node, path, out, depth = 0) {
  if (!node || typeof node !== 'object' || depth > 6) return;
  if (Array.isArray(node)) { node.forEach((v, i) => collectUrls(v, `${path}[${i}]`, out, depth + 1)); return; }
  for (const [k, v] of Object.entries(node)) {
    if (typeof v === 'string' && /^https?:/.test(v)) out.push({ path: `${path}.${k}`, url: v });
    else collectUrls(v, `${path}.${k}`, out, depth + 1);
  }
}

const URL = 'https://api.amemv.com/aweme/v1/feed/?aid=1128&count=6&type=0';
console.log('=== vf_dy_aweme_mediatype: 推荐流图文帖混发判据 ===');
const rows = [];
let batchesOk = 0;
for (let i = 1; i <= BATCHES; i++) {
  const r = await json(URL);
  if (!r.len) { console.log(`batch#${i}: HTTP=${r.status} len=0（空 body）`); await sleep(400 * i); continue; }
  batchesOk++;
  const list = r.json?.aweme_list ?? [];
  console.log(`batch#${i}: HTTP=${r.status} len=${r.len} aweme_list=${list.length}`);
  for (const a of list) {
    const video = a.video ?? {};
    const playAddr = video.play_addr ?? {};
    const urls = [];
    collectUrls(playAddr, 'video.play_addr', urls);
    const first = urls[0]?.url ?? '';
    const ext = (first.split('?')[0].match(/\.(mp4|mp3|m4a|ts|mov)$/i) ?? [])[1] ?? '?';
    rows.push({
      aweme_id: a.aweme_id,
      media_type: a.media_type,
      aweme_type: a.aweme_type,
      duration: video.duration,
      images_len: Array.isArray(a.images) ? a.images.length : 0,
      play_ext: ext,
      play_width: playAddr.width, play_height: playAddr.height,
    });
  }
  await sleep(400);
}

console.log(`\n共 ${rows.length} 条（有效批次 ${batchesOk}/${BATCHES}）`);
console.log('\n=== 每条判据 ===');
console.log('media_type  duration  images  ext   w x h        aweme_id');
for (const r of rows) {
  console.log(`${String(r.media_type).padEnd(11)} ${String(r.duration).padEnd(8)} ${String(r.images_len).padEnd(7)} ${String(r.play_ext).padEnd(5)} ` +
    `${String(r.play_width)}x${String(r.play_height)}\t${r.aweme_id}`);
}

// 分布
const dist = {};
for (const r of rows) {
  const k = `media_type=${r.media_type} images=${r.images_len} duration${r.duration > 0 ? '>0' : '<=0'} ext=${r.play_ext}`;
  dist[k] = (dist[k] || 0) + 1;
}
console.log('\n=== 分布 ===');
for (const [k, v] of Object.entries(dist)) console.log(`  ${k}  × ${v}`);

// 真拉每种 media_type 的第一条 play_addr，验 Content-Type + 首字节
console.log('\n=== 实测 Content-Type / 首字节 ===');
const byType = {};
for (const r of rows) if (!byType[r.media_type]) byType[r.media_type] = r;
for (const [mt, r] of Object.entries(byType)) {
  // 重新取该条的 play_addr.url_list[0]（rows 里没存全 URL，避免时效地址入库）
  const res = await json(URL);
  const aweme = (res.json?.aweme_list ?? []).find((a) => a.media_type === Number(mt));
  const u = aweme?.video?.play_addr?.url_list?.[0];
  if (!u) { console.log(`  media_type=${mt}: 无 play_addr`); continue; }
  try {
    const f = await fetch(u, { headers: { 'user-agent': UA_APP, range: 'bytes=0-15' } });
    const b = Buffer.from(await f.arrayBuffer());
    const ct = f.headers.get('content-type');
    const head = [...b].map((x) => x.toString(16).padStart(2, '0')).join(' ');
    const ascii = b.subarray(0, 12).toString('latin1').replace(/[^\x20-\x7e]/g, '.');
    console.log(`  media_type=${mt} (duration=${aweme.video?.duration} images=${Array.isArray(aweme.images) ? aweme.images.length : 0})`);
    console.log(`    HTTP=${f.status} ct=${ct} len=${b.length} 首字节=${head} ascii="${ascii}"`);
    console.log(`    → ${ct === 'audio/mpeg' ? '⚠️ 音频（无视频轨，播放器必黑屏但有声音）' : b.subarray(4, 8).toString('latin1') === 'ftyp' ? '✅ MP4 视频' : '其它'}`);
  } catch (e) { console.log(`  media_type=${mt} 拉取失败 ${e.message}`); }
  await sleep(300);
}

console.log('\n=== 判据结论（供 Dart 侧过滤用）===');
console.log('  真视频：media_type=4  duration>0  images=0  play_addr→video/mp4 ftyp');
console.log('  图文帖：media_type=42 duration=0  images>=1 play_addr→audio/mpeg ID3');
console.log('  过滤条件应为 (media_type==42 || (images 非空 && duration<=0)) → 跳过；');
console.log('  并加双条件保护：duration>0 || images 为空 才认可是视频，避免平台改类型码误杀真视频。');
