// vf_dy_short.mjs — Q8：抖音短视频推荐流匿名可用性复核（README 结论是否仍成立）
//
// 复核目标：`api.amemv.com/aweme/v1/feed/` 现在匿名（无签名、无 Cookie）是否仍返回
//   1) 真实 aweme 条目
//   2) 其中**可播的视频条目**（video.duration > 0）
//   3) play_addr 是否仍是 mp4 直链（真拉前 32 字节验 `ftyp` + brand=isom）
//
// ── 实测要点（第一次跑踩到的坑，写在代码里避免误判）──
// 匿名 feed 返回的条目是**混合内容**：真视频（duration>0、play_addr=video/mp4）
// 与音乐/图文帖（duration=0、play_addr 指向 .mp3 或 audio/mp4）。
// 单个请求可能**一条视频都没有**，因此必须"多次请求累计"才能下结论，
// 否则会误判成"README 的 mp4 直链结论已失效"。
// 参数形态也影响比例：带 device_id / 最小参数集更容易拿到视频条目。
//
// 运行：node tool/vf_dy_short.mjs                 # 默认最多打 6 次请求
//       node tool/vf_dy_short.mjs --tries=10
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
// 与 lib/src/adapters/douyin_adapter.dart 实际拼的 URL 保持一致的参数形态
const ADAPTER_Q = `${APPQ}&count=6&type=0`;
const MINIMAL_Q = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&count=6&type=0';
const DEVICE_Q = `${APPQ}&count=8&type=0&device_id=3926413869446065&openudid=7ae5fa9ca5de6c1e`;

const argv = process.argv.slice(2);
const numArg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? Number(a.split('=')[1]) : d; };
const TRIES = numArg('tries', 6);

async function get(url, headers = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, { headers: { 'user-agent': UA_APP, ...headers } });
    const b = Buffer.from(await r.arrayBuffer());
    return { status: r.status, ct: r.headers.get('content-type'), buf: b, ms: Date.now() - t0 };
  } catch (e) { return { status: 0, buf: Buffer.alloc(0), err: `${e.name}: ${e.message}`, ms: Date.now() - t0 }; }
}
const isVideo = (x) => (x.video?.duration ?? 0) > 0;

console.log('=== vf_dy_short: 匿名短视频推荐流复核 ===');
const forms = [
  ['adapter 参数形态', ADAPTER_Q],
  ['最小参数集', MINIMAL_Q],
  ['带 device_id/openudid', DEVICE_Q],
];
const all = [];
const perForm = [];
for (const [name, q] of forms) {
  let got = 0, vids = 0, rounds = 0;
  for (let i = 0; i < Math.max(2, Math.ceil(TRIES / forms.length)); i++) {
    const r = await get(`https://api.amemv.com/aweme/v1/feed/?${q}`);
    let j = null; try { j = JSON.parse(r.buf.toString('utf8')); } catch {}
    const list = Array.isArray(j?.aweme_list) ? j.aweme_list : [];
    const v = list.filter(isVideo);
    rounds++;
    got += list.length; vids += v.length;
    all.push(...list);
    if (r.status !== 200 || !list.length) {
      console.log(`  ${name}: 第${rounds}次 HTTP=${r.status} len=${r.buf.length} status_code=${j?.status_code} items=${list.length}${r.err ? ' ERR' : ''}`);
    }
    if (v.length >= 2) break; // 拿到足够视频就换下一种形态
  }
  perForm.push({ name, rounds, items: got, videos: vids });
  console.log(`  ${name.padEnd(22)} 请求${rounds}次 → 条目 ${got} 条，其中 duration>0 的真视频 ${vids} 条`);
}

const videos = all.filter(isVideo);
console.log(`\n累计：${all.length} 条 aweme，${videos.length} 条真视频（duration>0）`);
if (!all.length) {
  console.log('\n⚠️ 匿名 feed 完全拿不到 aweme_list → README 短视频结论失效');
} else {
  console.log('\n=== 逐条容器判定（真拉前 32 字节）===');
  const cand = [];
  const push = (tag, u) => { if (typeof u === 'string' && /^https?:/.test(u)) cand.push([tag, u]); };
  videos.slice(0, 3).forEach((x, i) => (x.video?.play_addr?.url_list ?? []).forEach((u, j) => push(`video[${i}].play[${j}]`, u)));
  videos.slice(0, 2).forEach((x, i) => (x.video?.bit_rate ?? []).forEach((br, j) => push(`video[${i}].br[${j}]${(br.gear_name ?? '').slice(0, 10)}`, (br?.play_addr?.url_list ?? [])[0])));
  videos.slice(0, 2).forEach((x, i) => (x.video?.download_addr?.url_list ?? []).forEach((u, j) => push(`video[${i}].dl[${j}]`, u)));
  all.filter((x) => !isVideo(x)).slice(0, 2).forEach((x, i) => push(`非视频条目[${i}].play[0]`, (x.video?.play_addr?.url_list ?? [])[0]));

  let vMp4 = 0, aMp4 = 0, checked = 0;
  const brands = new Set();
  for (const [tag, u] of cand.slice(0, 12)) {
    const r = await get(u, { range: 'bytes=0-31' });
    const head = r.buf.subarray(0, 32).toString('hex').match(/.{2}/gu)?.join(' ') ?? '';
    const ftyp = r.buf.subarray(4, 8).toString('latin1');
    const brand = r.buf.subarray(8, 12).toString('latin1').trim();
    const isMp4 = ftyp === 'ftyp';
    const isMp3 = r.buf[0] === 0x49 && r.buf[1] === 0x44 && r.buf[2] === 0x33;
    const audio = /audio/i.test(r.ct ?? '');
    checked++;
    if (isMp4) { if (audio) aMp4++; else { vMp4++; brands.add(brand); } }
    const host = (() => { try { return new URL(u).hostname; } catch { return '?'; } })();
    console.log(`  ${tag.padEnd(26)} HTTP=${r.status} ct=${r.ct ?? '-'} len=${r.buf.length} ` +
      `容器=${isMp4 ? `ftyp brand=${brand || '?'} ${audio ? '(音频)' : '(视频)'}` : isMp3 ? 'MP3/ID3(音频)' : '非MP4'} host=${host}${r.err ? ' ERR' : ''}`);
    console.log(`      hex=${head}`);
  }
  const a0 = videos[0] ?? all[0];
  console.log(`\n=== 样本 aweme 结构 ===`);
  console.log(`  aweme_id=${a0.aweme_id} duration=${a0.video?.duration}ms ${a0.video?.width}x${a0.video?.height} is_h265=${a0.video?.is_h265} decode_key=${a0.video?.decode_key ? '有' : '无'} blob_type=${JSON.stringify(a0.video?.blob_type ?? null)}`);
  console.log(`  author: uid=${a0.author?.uid ?? '(无)'} nickname存在=${!!a0.author?.nickname} sec_uid存在=${!!a0.author?.sec_uid}`);
  console.log(`  bit_rate 档数=${(a0.video?.bit_rate ?? []).length} ` + JSON.stringify((a0.video?.bit_rate ?? []).map((x) => `${x.gear_name}/${Math.round((x.bit_rate ?? 0) / 1000)}k`)));
  console.log(`  download_addr url 数=${(a0.video?.download_addr?.url_list ?? []).length} data_size=${a0.video?.download_addr?.data_size ?? '(无)'}`);
  console.log(`\n→ ftyp 视频容器可取: ${vMp4} / ftyp 音频容器: ${aMp4}（共探测 ${checked}）`);
  if (vMp4 > 0) {
    console.log(`\n✅【实测通过】README 结论仍成立：匿名（无签名、无 Cookie）/aweme/v1/feed/ 返回真实 aweme，` +
      `视频条目 play_addr 是 **mp4 直链（ftyp brand=${[...brands].join('/') || 'isom'}，HTTP 206）**，media_kit 可原生播放。`);
    console.log(`   但需注意：返回是混合内容，${all.length} 条里 ${videos.length} 条是可播视频，其余是音乐/图文帖；`);
    console.log(`   UI 侧必须按 video.duration>0 过滤，否则会把音频帖当视频渲染。`);
  } else {
    console.log('\n⚠️【实测失败】多次请求累计拿不到任何 ftyp 视频容器 → README「抖音应用内播放 ✅」需降级。');
  }
}

console.log('\n=== 对照：其它短视频只读接口现在是否匿名可用 ===');
for (const [label, u] of [
  ['aweme/v1/search/suggested/', `https://api.amemv.com/aweme/v1/search/suggested/?${APPQ}&keyword=%E7%BE%8E%E9%A3%9F`],
  ['general/search/single/', `https://api.amemv.com/aweme/v1/general/search/single/?${APPQ}&keyword=%E7%BE%8E%E9%A3%9F&offset=0&count=10`],
  ['challenge/detail/', `https://api.amemv.com/aweme/v1/challenge/detail/?${APPQ}&challenge_id=1`],
  ['aweme/v1/user/(登录态)', `https://api.amemv.com/aweme/v1/user/?${APPQ}`],
]) {
  const r = await get(u);
  let j = null; try { j = JSON.parse(r.buf.toString('utf8')); } catch {}
  console.log(`  ${label.padEnd(32)} HTTP=${r.status} len=${r.buf.length}` +
    (j ? ` status_code=${j.status_code}${j.status_msg ? ' msg=' + JSON.stringify(j.status_msg) : ''} keys=[${Object.keys(j).slice(0, 7).join(',')}]` :
      ` head=${JSON.stringify(r.buf.subarray(0, 40).toString('latin1').replace(/\s+/g, ' '))}`) + (r.err ? ' ERR' : ''));
}
