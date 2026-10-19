// vf_dy_stream.mjs — 抖音直播播放地址"真实可拉流"实测
//
// 从 webcast/feed 匿名取房间 → 对每个房间的每个 HLS 档位做完整链路验证：
//   A. GET master .m3u8（带 Range 与不带各试一次），记录 HTTP 状态、content-type、
//      是否为 #EXTM3U、是 master（含 EXT-X-STREAM-INF）还是 media（含分片）
//   B. 解析出 variant / 首个 .ts 分片 URI，真实下载前 32 字节
//   C. 判断容器：TS 包 → 首字节必须 0x47（188 字节包长对齐）；fMP4 → 含 'ftyp'
//   D. FLV 地址（来自 live_core_sdk_data 的嵌套 stream_data，因为 stream_url.flv_pull_url
//      实测为空对象）同样 GET 前若干字节，验证 'FLV' 魔数
//   E. 同时验证 https 是否可用（feed 下发的是 http，App 端 usesCleartextTraffic=false）
//
// 输出：每房间 × 每档位一行结果，最后统计"哪档真的能取到分片"。
//
// 运行：node tool/vf_dy_stream.mjs                     # 默认抽 4 个房间
//       node tool/vf_dy_stream.mjs --rooms=6 --https=1
import fs from 'node:fs';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const argv = process.argv.slice(2);
const numArg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? Number(a.split('=')[1]) : d; };
const ROOMS = numArg('rooms', 4);
const SECS = numArg('timeout', 15000);

async function feedRooms() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' },
    });
    const t = await r.text();
    if (!t.trim()) { await new Promise((s) => setTimeout(s, 350 * i)); continue; }
    const j = JSON.parse(t);
    return (Array.isArray(j.data) ? j.data : []).map((e) => e?.data).filter(Boolean);
  }
  return [];
}

/** 带超时的 fetch，返回 {status, headers, buf, text, err} */
async function grab(url, { range, headers = {} } = {}) {
  const ac = new AbortController();
  const to = setTimeout(() => ac.abort(), SECS);
  const t0 = Date.now();
  try {
    const r = await fetch(url, {
      redirect: 'follow',
      signal: ac.signal,
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', ...(range ? { range } : {}), ...headers },
    });
    const ab = await r.arrayBuffer();
    const buf = Buffer.from(ab);
    return {
      status: r.status, len: buf.length, ms: Date.now() - t0,
      ct: r.headers.get('content-type'), cl: r.headers.get('content-length'),
      buf, text: buf.subarray(0, 4096).toString('utf8'),
      finalUrl: r.url,
    };
  } catch (e) {
    return { status: 0, len: 0, ms: Date.now() - t0, err: `${e.name}: ${e.message}`, buf: Buffer.alloc(0), text: '' };
  } finally {
    clearTimeout(to);
  }
}

const hexHead = (b, n = 16) => b.subarray(0, n).toString('hex').match(/.{2}/gu)?.join(' ') ?? '';

/** 判断分片容器：TS(0x47 + 188 对齐) / fMP4(ftyp) / FLV(FLV) */
function classify(buf) {
  if (!buf?.length) return { kind: 'empty', detail: '0 字节' };
  if (buf[0] === 0x47) {
    // TS 包 188 字节，第二个包起点应仍是同步字节（容错：连续 3 个）
    const ok2 = buf.length >= 376 ? buf[188] === 0x47 : null;
    const ok3 = buf.length >= 564 ? buf[376] === 0x47 : null;
    return { kind: 'mpegts', detail: `0x47 同步字节 ok, 188B 对齐: 2nd=${ok2} 3rd=${ok3}` };
  }
  if (buf.subarray(4, 8).toString('latin1') === 'ftyp') {
    return { kind: 'fmp4', detail: `ftyp=${buf.subarray(8, 12).toString('latin1')}` };
  }
  if (buf.subarray(0, 3).toString('latin1') === 'FLV') {
    return { kind: 'flv', detail: `FLV ver=${buf[3]} flags=${buf[4]} hdrLen=${buf.readUInt32BE(5)}` };
  }
  const txt = buf.subarray(0, 40).toString('utf8');
  if (txt.startsWith('#EXTM3U')) return { kind: 'm3u8', detail: txt.slice(0, 40) };
  if (/<html|<?xml|Forbidden|Denied/i.test(txt)) return { kind: 'error-page', detail: txt.replace(/\s+/g, ' ').slice(0, 80) };
  return { kind: 'unknown', detail: `ascii=${JSON.stringify(txt)}` };
}

/** 从 m3u8 文本解析 master / media */
function parseM3u8(text) {
  const lines = text.split(/\r?\n/);
  const out = { isM3u8: text.startsWith('#EXTM3U'), master: [], media: [], targetDuration: null, endList: false, seq: null };
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i].trim();
    if (l.startsWith('#EXT-X-STREAM-INF')) out.master.push({ attrs: l, uri: (lines[i + 1] ?? '').trim() });
    if (l.startsWith('#EXT-X-TARGETDURATION')) out.targetDuration = l.split(':')[1];
    if (l.startsWith('#EXT-X-MEDIA-SEQUENCE')) out.seq = l.split(':')[1];
    if (l.startsWith('#EXT-X-ENDLIST')) out.endList = true;
    if (l && !l.startsWith('#')) out.media.push(l);
  }
  return out;
}

const baseOf = (u) => u.slice(0, u.lastIndexOf('/') + 1);

console.log('=== vf_dy_stream: 抖音直播播放地址真实拉流实测 ===');
const rooms = await feedRooms();
console.log(`feed 返回房间数: ${rooms.length}（取前 ${ROOMS} 个）`);
if (!rooms.length) { console.log('无数据，终止'); process.exit(1); }

const rows = [];
for (const room of rooms.slice(0, ROOMS)) {
  const su = room.stream_url ?? {};
  const hlsMap = su.hls_pull_url_map ?? {};
  console.log('\n──────── 房间 ' + room.id_str + ' status=' + room.status +
    ` default=${su.default_resolution} cand=[${(su.candidate_resolution ?? []).join(',')}] ` +
    `user_count=${room.user_count} title=${JSON.stringify((room.title ?? '').slice(0, 18))}`);

  // 从 live_core_sdk_data 里挖 FLV（stream_url.flv_pull_url 实测为空 {}）
  let nested = null;
  try {
    const sd = JSON.parse(su?.live_core_sdk_data?.pull_data?.stream_data ?? '{}');
    nested = sd?.data?.media_list ?? null;
    if (nested) {
      console.log(`  live_core_sdk_data.media_list 档位: [${Object.keys(nested).join(',')}]`);
      for (const [q, v] of Object.entries(nested)) {
        const main = v?.main ?? {};
        console.log(`    ${q}: hls=${(main.hls ?? '').length ? 'Y' : '-'} flv=${(main.flv ?? '').length ? 'Y' : '-'}` +
          ` lls=${(main.lls ?? '').length ? 'Y' : '-'} cmaf=${(main.cmaf ?? '').length ? 'Y' : '-'}` +
          ` dash=${(main.dash ?? '').length ? 'Y' : '-'} ` +
          `res=${JSON.stringify((JSON.parse(main.sdk_params ?? '{}')).resolution ?? '')}` +
          ` br=${v.main?.templateRealTimeInfo?.bitrateKbps ?? '?'}kbps` +
          ` codec=${JSON.stringify((JSON.parse(main.sdk_params ?? '{}')).VCodec ?? '')}`);
      }
    }
  } catch (e) { console.log('  stream_data 解析失败:', e.message); }

  // A) HLS：每档实测
  for (const [q, url] of Object.entries(hlsMap)) {
    if (typeof url !== 'string' || !url) continue;
    const m = await grab(url);
    const cls = classify(m.buf);
    const p = cls.kind === 'm3u8' ? parseM3u8(m.text) : null;
    let segInfo = '';
    let segOk = false;
    let segHex = '';
    if (p) {
      if (p.master.length) {
        // master → 取第一条 variant（或匹配当前档位）
        const variant = p.master[0];
        const vu = variant.uri.startsWith('http') ? variant.uri : baseOf(url) + variant.uri;
        const vr = await grab(vu);
        const vc = classify(vr.buf);
        const vp = vc.kind === 'm3u8' ? parseM3u8(vr.text) : null;
        segInfo = `master(${p.master.length}档)->GET ${vr.status} ${vc.kind}`;
        if (vp?.media.length) {
          const seg = vp.media[0];
          const sg = await grab(seg.startsWith('http') ? seg : baseOf(vu) + seg, { range: 'bytes=0-4095' });
          const sc = classify(sg.buf);
          segHex = hexHead(sg.buf, 8);
          segOk = sc.kind === 'mpegts' || sc.kind === 'fmp4';
          segInfo += ` | variant分片${vp.media.length} target=${vp.targetDuration} -> ${sg.status} ${sc.kind}(${sc.detail})`;
        }
      } else if (p.media.length) {
        segInfo = `media playlist 分片数=${p.media.length} target=${p.targetDuration} endList=${p.endList} seq=${p.seq}`;
        const seg = p.media[0];
        const sg = await grab(seg.startsWith('http') ? seg : baseOf(url) + seg, { range: 'bytes=0-4095' });
        const sc = classify(sg.buf);
        segHex = hexHead(sg.buf, 8);
        segOk = sc.kind === 'mpegts' || sc.kind === 'fmp4';
        segInfo += ` | 首片 ${sg.status} ${sc.kind} (${sc.detail})`;
      }
    }
    // E) https 同址是否可用
    let httpsNote = '';
    if (url.startsWith('http://')) {
      const hs = await grab('https://' + url.slice(7), { range: 'bytes=0-0' });
      httpsNote = ` https=${hs.status}${hs.err ? ' ' + hs.err : ` len=${hs.len}`}`;
    }
    const range = await grab(url, { range: 'bytes=0-0' });
    const row = {
      room: room.id_str, tier: q, url: 'hls_pull_url_map', status: m.status, ct: m.ct,
      len: m.len, ms: m.ms, kind: cls.kind, kindDetail: cls.detail, segOk, segHex,
      segInfo, httpsNote, rangeStatus: range.status, rangeLen: range.len, rangeCt: range.ct,
      err: m.err ?? null,
    };
    rows.push(row);
    console.log(`  HLS ${q.padEnd(8)} GET=${m.status} ct=${m.ct ?? '-'} len=${m.len} ${m.ms}ms ` +
      `容器=${cls.kind}${cls.kind === 'm3u8' ? '' : '(' + cls.detail + ')'} ` +
      `HEAD-like(bytes=0-0)=${range.status}/len=${range.len}${httpsNote}`);
    if (segInfo) console.log(`         ${segInfo} 首片hex=${segHex || '-'}`);
    if (m.err) console.log(`         ERR ${m.err}`);
    if (cls.kind === 'error-page') console.log(`         ERRORPAGE ${cls.detail}`);
  }

  // B) FLV：优先用嵌套 media_list 的 flv
  const flvCandidates = [];
  if (nested) for (const [q, v] of Object.entries(nested)) if (v?.main?.flv) flvCandidates.push([`nested:${q}`, v.main.flv]);
  for (const [q, u] of Object.entries(su.flv_pull_url ?? {})) if (u) flvCandidates.push([`flv_pull_url:${q}`, u]);
  if (su.hls_pull_url) flvCandidates.push(['hls_pull_url(top)', su.hls_pull_url]);
  for (const [tag, url] of flvCandidates.slice(0, 3)) {
    const r = await grab(url, { range: 'bytes=0-4095' });
    const c = classify(r.buf);
    const full = c.kind === 'flv' || c.kind === 'mpegts' || c.kind === 'fmp4';
    rows.push({ room: room.id_str, tier: tag, url: 'flv-or-other', status: r.status, ct: r.ct, len: r.len, ms: r.ms, kind: c.kind, kindDetail: c.detail, segOk: full, segHex: hexHead(r.buf, 16), segInfo: '', httpsNote: '', rangeStatus: r.status, rangeLen: r.len, rangeCt: r.ct, err: r.err ?? null });
    console.log(`  ${tag.padEnd(18)} GET(range)=${r.status} ct=${r.ct ?? '-'} len=${r.len} ${r.ms}ms ` +
      `容器=${c.kind}(${c.detail}) hex=${hexHead(r.buf, 12)}${r.err ? ' ERR ' + r.err : ''}`);
  }
}

// ── 汇总 ──────────────────────────────────────────────────────
console.log('\n=== 汇总：各档位真实可取分片比例 ===');
const byTier = {};
for (const r of rows.filter((x) => x.url === 'hls_pull_url_map')) {
  const k = r.tier;
  byTier[k] = byTier[k] ?? { n: 0, ok: 0, http200: 0 };
  byTier[k].n++;
  if (r.status === 200) byTier[k].http200++;
  if (r.segOk) byTier[k].ok++;
}
for (const [k, v] of Object.entries(byTier)) {
  console.log(`  ${k.padEnd(9)} playlist200=${v.http200}/${v.n}  分片可取(0x47/ftyp)=${v.ok}/${v.n}`);
}
const flvRows = rows.filter((x) => x.url !== 'hls_pull_url_map');
console.log(`  FLV/其它 实测 ${flvRows.length} 条，容器: ` +
  JSON.stringify(flvRows.reduce((a, x) => { a[x.kind] = (a[x.kind] ?? 0) + 1; return a; }, {})));
fs.writeFileSync('tool/_dy_stream_results.json', JSON.stringify({ at: new Date().toISOString(), rows }, null, 2), 'utf8');
console.log('\n已写 tool/_dy_stream_results.json');
