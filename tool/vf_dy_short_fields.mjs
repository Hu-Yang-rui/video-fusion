// vf_dy_short_fields.mjs — 推荐流条目里**所有**候选播放字段逐个实测
//
// 背景：匿名 /aweme/v1/feed/ 返回的是**混合内容**——既有真视频条目
// （video.duration>0），也有音乐/图文帖（duration=0，play_addr 指向 .mp3）。
// 早期一次探针只抽到音乐帖，误判成"整条链路已变成音频"。本探针做穷举：
//   对同一个 aweme，把 video/music 下**每一个**可能是地址的字段真拉前 32 字节，
//   报 content-type + 首字节 hex + 容器（ftyp 视频 / ftyp 音频 / ID3 / 非MP4），
//   并列出该 aweme 的全部字段名（含 play_addr_h264 / play_addr_265 / DASH 是否存在），
//   从而能确定回答："抖音应用内播放现在到底还能不能用"。
//
// 运行：node tool/vf_dy_short_fields.mjs
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
// ⚠️ 实测：最小参数集（不带 device_type/os_version/channel 等）更容易拿到真视频条目
const Q = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&count=8&type=0&device_id=3926413869446065';

async function get(url, headers = {}) {
  try {
    const r = await fetch(url, { headers: { 'user-agent': UA_APP, ...headers } });
    const b = Buffer.from(await r.arrayBuffer());
    return { status: r.status, ct: r.headers.get('content-type'), buf: b };
  } catch (e) { return { status: 0, buf: Buffer.alloc(0), err: `${e.name}` }; }
}
const isVideoItem = (x) => (x.video?.duration ?? 0) > 0;

/** 递归收集所有 http(s) 字符串，路径形如 video.bit_rate[0].play_addr.url_list[1] */
function collectUrls(node, path = '', out = []) {
  if (typeof node === 'string') {
    if (/^https?:\/\//.test(node)) out.push([path, node]);
    return out;
  }
  if (Array.isArray(node)) {
    node.forEach((v, i) => collectUrls(v, `${path}[${i}]`, out));
    return out;
  }
  if (node && typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) collectUrls(v, path ? `${path}.${k}` : k, out);
  }
  return out;
}
const classify = (buf, ct) => {
  if (!buf.length) return '空';
  if (buf.subarray(4, 8).toString('latin1') === 'ftyp') {
    const brand = buf.subarray(8, 12).toString('latin1').trim();
    return /audio/i.test(ct ?? '') ? `ftyp/${brand}=音频` : `ftyp/${brand}=视频`;
  }
  if (buf[0] === 0x49 && buf[1] === 0x44 && buf[2] === 0x33) return 'ID3=MP3音频';
  if (buf[0] === 0x47) return 'TS 0x47';
  const t = buf.subarray(0, 20).toString('latin1').replace(/\s+/g, ' ');
  if (t.startsWith('#EXTM3U')) return 'm3u8';
  return `非MP4(${JSON.stringify(t)})`;
};

console.log('=== vf_dy_short_fields: 推荐流播放字段穷举实测 ===');
// 多打几次，确保至少拿到 2 条"真视频"条目
let pool = [];
for (let i = 0; i < 6 && pool.filter(isVideoItem).length < 2; i++) {
  const r = await get(`https://api.amemv.com/aweme/v1/feed/?${Q}`);
  let j = null; try { j = JSON.parse(r.buf.toString('utf8')); } catch {}
  const list = Array.isArray(j?.aweme_list) ? j.aweme_list : [];
  console.log(`  第 ${i + 1} 次: HTTP=${r.status} items=${list.length} 真视频=${list.filter(isVideoItem).length} (duration>0)`);
  pool.push(...list);
}
const videos = pool.filter(isVideoItem);
const musics = pool.filter((x) => !isVideoItem(x));
console.log(`\n累计: ${pool.length} 条 → 真视频 ${videos.length} 条 / 音乐或图文帖 ${musics.length} 条`);
if (!videos.length) {
  console.log('⚠️ 拿不到 duration>0 的条目，无法判定视频直链可用性（重试或改参数）');
}

const showKeys = (a) => {
  console.log(`\n  video 对象全部 key: ${Object.keys(a.video ?? {}).sort().join(', ')}`);
  console.log(`  aweme 顶层与播放相关 key: ${Object.keys(a).filter((k) => /video|play|download|dash|media|bit_rate|music|image/i.test(k)).join(', ')}`);
  for (const k of ['play_addr_h264', 'play_addr_265', 'play_addr', 'download_addr', 'bit_rate', 'dashed', 'dash']) {
    console.log(`    存在 ${k} = ${a.video?.[k] !== undefined ? JSON.stringify(Array.isArray(a.video[k]) ? `Array(${a.video[k].length})` : (typeof a.video[k])) : 'ABSENT'}`);
  }
  // DASH 形态（抖音 web 端才用 video.dashed[]）
  console.log(`    video.dashed 存在=${!!a.video?.dashed}  video.bit_rate 档数=${(a.video?.bit_rate ?? []).length}`);
};

const tested = [];
for (const [idx, a] of videos.slice(0, 2).entries()) {
  console.log(`\n══════ 真视频条目 #${idx}: aweme_id=${a.aweme_id} duration=${a.video.duration}ms ${a.video.width}x${a.video.height} is_h265=${a.video.is_h265} decode_key=${a.video.decode_key ? '有' : '无'}`);
  console.log(`  desc=${JSON.stringify((a.desc ?? '').slice(0, 40))}`);
  showKeys(a);
  console.log(`  bit_rate 各档 gear=${JSON.stringify((a.video.bit_rate ?? []).map((x) => x.gear_name))}`);

  const urls = collectUrls(a.video, 'video');
  const musicUrls = a.music ? collectUrls(a.music, 'music') : [];
  console.log(`\n  该条目 video 下共 ${urls.length} 个 http 地址；music 下 ${musicUrls.length} 个`);
  const seen = new Set();
  for (const [p, u] of urls) {
    const key = u.slice(0, 160);
    if (seen.has(key)) continue;
    seen.add(key);
    const r = await get(u, { range: 'bytes=0-31' });
    const verdict = classify(r.buf, r.ct);
    const host = (() => { try { return new URL(u).hostname; } catch { return '?'; } })();
    console.log(`    ${p.padEnd(46)} HTTP=${r.status} ct=${r.ct ?? '-'} len=${r.buf.length} ${verdict} host=${host}${r.err ? ' ERR' : ''}`);
    console.log(`        hex=${r.buf.subarray(0, 32).toString('hex').match(/.{2}/gu)?.join(' ') ?? ''}`);
    tested.push({ path: p, status: r.status, ct: r.ct, verdict });
  }
  // 音频帖对照：证明"混入的是另一类条目"而不是"视频变音频"
  const one = musics[idx];
  if (one) {
    console.log(`\n  ── 对照：音乐/图文帖 aweme_id=${one.aweme_id} duration=${one.video?.duration} ${one.video?.width}x${one.video?.height}`);
    for (const [p, u] of collectUrls(one.video, 'video').slice(0, 3)) {
      const r = await get(u, { range: 'bytes=0-31' });
      console.log(`    ${p.padEnd(30)} HTTP=${r.status} ct=${r.ct ?? '-'} ${classify(r.buf, r.ct)} hex=${r.buf.subarray(0, 16).toString('hex').match(/.{2}/gu)?.join(' ') ?? ''}`);
    }
    const mu = collectUrls(one.music ?? {}, 'music')[0];
    if (mu) {
      const r = await get(mu[1], { range: 'bytes=0-31' });
      console.log(`    music.play_url[0]`.padEnd(32) + ` HTTP=${r.status} ct=${r.ct ?? '-'} ${classify(r.buf, r.ct)} hex=${r.buf.subarray(0, 16).toString('hex').match(/.{2}/gu)?.join(' ') ?? ''}`);
    }
  }
}

const videoOk = tested.filter((t) => /ftyp\/.*=视频/.test(t.verdict)).length;
const audioOk = tested.filter((t) => /(音频|ID3)/.test(t.verdict)).length;
console.log(`\n=== 判定 ===`);
console.log(`  探测 ${tested.length} 个地址 → 视频容器 ${videoOk} 个 / 音频容器 ${audioOk} 个`);
if (videoOk > 0) {
  console.log(`  ✅ 抖音"应用内播放"仍可用：真视频条目的 play_addr/bit_rate[].play_addr/download_addr` +
    ` 都是 **video/mp4 直链（ftyp brand=isom，HTTP 206）**，media_kit 能直接播。`);
  console.log(`  ⚠️ 但匿名 feed 混发音乐/图文帖（duration=0，地址是 .mp3 或 audio/mp4）。` +
    `适配器必须按 video.duration>0 过滤，否则会把音频帖当视频渲染 —— 表现就是"有声音、画面黑"。`);
} else {
  console.log(`  ❌ 无任何视频容器地址可取 → README「抖音应用内播放 ✅」需降级。`);
}
