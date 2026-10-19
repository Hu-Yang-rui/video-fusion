// vf_dy_flv_ts.mjs — FLV 首字节取证 + 每档 TS 编码（bytevc1 还是 h264）
//
// 两件事：
//  1) 上一轮 flv 请求全部 AbortError，原因是 FLV 是**无限流**，arrayBuffer() 永不 resolve。
//     这里改用 response.body reader 读够 4KB 就 abort，取真实首字节验 'FLV' 魔数。
//  2) 对 feed 下发的每个 HLS 档位，真拉 1MB .ts 分片并解 PMT，打印 stream_type。
//     这决定 media_kit 侧能不能解：0x24=HEVC（含 bytevc1），0x1B=H.264。
//
// 运行：node tool/vf_dy_flv_ts.mjs
const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

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

/** 流式读前 n 字节后中断（对付无限流） */
async function readHead(url, n = 4096, ms = 12000) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), ms);
  try {
    const r = await fetch(url, { signal: ac.signal, headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const chunks = [];
    let got = 0;
    if (r.body) {
      const rd = r.body.getReader();
      while (got < n) {
        const { done, value } = await rd.read();
        if (done) break;
        chunks.push(value); got += value.length;
      }
      try { rd.cancel(); } catch {}
    }
    ac.abort(); // 立刻断流
    const buf = Buffer.concat(chunks.map((c) => Buffer.from(c.buffer, c.byteOffset, c.length)));
    return { status: r.status, ct: r.headers.get('content-type'), buf };
  } catch (e) {
    return { status: 0, buf: Buffer.concat([]), err: `${e.name}: ${String(e.message).slice(0, 40)}` };
  } finally { clearTimeout(timer); }
}

const ST = { 0x1b: 'H.264/AVC', 0x24: 'H.265/HEVC', 0x0f: 'AAC ADTS', 0x11: 'AAC LATM', 0x06: 'MP3/私用', 0x03: 'MP1/2 Audio' };
function parseTsTables(buf) {
  const PKT = 188, pmts = new Map(), streams = new Map();
  const push = (b) => { if (!streams.has(b)) return; };
  for (let off = 0; off + PKT <= buf.length; off += PKT) {
    if (buf[off] !== 0x47) continue;
    const h = buf[off + 1];
    const pusi = (h >> 6) & 1, pid = ((h & 0x1f) << 8) | buf[off + 2];
    const adapt = (buf[off + 3] >> 4) & 3;
    let p = off + 4;
    if (adapt & 2) p += 1 + buf[p];
    if (!(adapt & 1) || p + 9 >= buf.length) continue;
    const start = p + 1 + buf[p];
    if (start + 9 >= buf.length) continue;
    if (pid === 0 && buf[start] === 0x00) {
      const sl = ((buf[start + 1] & 0x0f) << 8) | buf[start + 2];
      const end = Math.min(start + 3 + sl - 4, buf.length);
      for (let q = start + 8; q + 3 < end; q += 4) {
        const pn = (buf[q] << 8) | buf[q + 1], pp = ((buf[q + 2] & 0x1f) << 8) | buf[q + 3];
        if (pp > 0 && pp < 0x1fff) pmts.set(pn, pp);
      }
    } else if (pusi && [...pmts.values()].includes(pid) && buf[start] === 0x02) {
      const sl = ((buf[start + 1] & 0x0f) << 8) | buf[start + 2];
      const end = Math.min(start + 3 + sl - 4, buf.length);
      const pmi = ((buf[start + 10] & 0x0f) << 8) | buf[start + 11];
      for (let q = start + 12 + pmi; q + 4 < end;) {
        const st = buf[q], epid = ((buf[q + 1] & 0x1f) << 8) | buf[q + 2];
        const dl = ((buf[q + 3] & 0x0f) << 8) | buf[q + 4];
        let lang = '';
        for (let d = q + 5; d + 1 < q + 5 + dl && d + 4 < end;) {
          const tag = buf[d], len = buf[d + 1];
          if (tag === 0x09) lang = Buffer.from(buf.subarray(d + 2, d + 5)).toString('latin1');
          d += 2 + len;
        }
        streams.set(epid, { st, name: ST[st] ?? `私用0x${st.toString(16).padStart(2, '0')}`, lang });
        q += 5 + dl;
      }
    }
  }
  return { programs: [...pmts.entries()], es: [...streams.entries()] };
}
function magic(b) {
  if (!b.length) return 'empty';
  if (b.subarray(0, 3).toString('latin1') === 'FLV') return `FLV ver=${b[3]} hdrLen=${b.readUInt32BE(5)}`;
  if (b[0] === 0x47) return 'TS 0x47';
  if (b.subarray(4, 8).toString('latin1') === 'ftyp') return 'MP4 ftyp=' + b.subarray(8, 12).toString('latin1');
  const t = b.subarray(0, 40).toString('latin1').replace(/\s+/g, ' ');
  return `other ${JSON.stringify(t)}`;
}

console.log('=== vf_dy_flv_ts: FLV 首字节 + 每档 TS 编码 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }

for (const room of rooms.slice(0, 3)) {
  const su = room.stream_url ?? {};
  console.log(`\n──── 房间 ${room.id_str} status=${room.status} title=${JSON.stringify((room.title ?? '').slice(0, 16))}`);
  let sd = null;
  try { sd = JSON.parse(su?.live_core_sdk_data?.pull_data?.stream_data ?? '{}'); } catch {}
  const ml = sd?.data ?? {};
  console.log(`  stream_data.data 档位: [${Object.keys(ml).join(', ')}]`);

  // 1) FLV 首字节（feed 的 flv_pull_url 是 {}，只能从 stream_data 取）
  for (const q of ['hd', 'sd', 'ld', 'origin']) {
    const u = ml[q]?.main?.flv;
    if (typeof u !== 'string' || !u) continue;
    const r = await readHead(u, 4096);
    console.log(`  FLV ${q.padEnd(7)} HTTP=${r.status} ct=${r.ct ?? '-'} 读到=${r.buf.length}B ` +
      `魔数=${magic(r.buf)} hex=${r.buf.subarray(0, 12).toString('hex').match(/.{2}/gu).join(' ')} host=${(() => { try { return new URL(u).hostname; } catch { return '?'; } })()}${r.err ? ' ' + r.err : ''}`);
  }

  // 2) 每档 HLS 的 TS 编码
  for (const [tier, url] of Object.entries(su.hls_pull_url_map ?? {})) {
    const pl = await readHead(url, 4096);
    const text = pl.buf.toString('utf8');
    let variantText = text, variantBase = url;
    const m = text.match(/#EXT-X-STREAM-INF:[^\n]*\n([^\n]+)/);
    if (m) {
      const vu = m[1].trim().startsWith('http') ? m[1].trim() : new URL(m[1].trim(), url).toString();
      const vr = await readHead(vu, 4096);
      variantText = vr.buf.toString('utf8'); variantBase = vu;
    }
    const segs = variantText.split(/\r?\n/).filter((l) => l && !l.startsWith('#'));
    if (!segs.length) { console.log(`  HLS ${tier.padEnd(9)} (playlist 无分片)`); continue; }
    const seg = segs[0].startsWith('http') ? segs[0] : new URL(segs[0], variantBase).toString();
    const s = await readHead(seg, 1024 * 1024);
    const t = parseTsTables(s.buf);
    const declared = (() => {
      try {
        const opts = su.live_core_sdk_data.pull_data.options.qualities ?? [];
        const key = { FULL_HD1: 'uhd', HD1: 'hd', SD1: 'ld', SD2: 'sd', ORIGION: 'origin' }[tier];
        const q = opts.find((x) => x.sdk_key === key);
        return q ? `${q.name}/${q.v_codec}/${q.resolution}@${q.fps}` : `sdk_key=${key}`;
      } catch { return '?'; }
    })();
    console.log(`  HLS ${tier.padEnd(9)} 分片 HTTP=${s.status} len=${s.buf.length} 首字节=${magic(s.buf)} ` +
      `PMT程序=${t.programs.map(([n, p]) => n + '/' + p).join(',')} ES=[${t.es.map(([, e]) => `pid${''}0x${e.st.toString(16)}=${e.name}${e.lang ? '/' + e.lang : ''}`).join(' ')}] ` +
      `feed声明=${declared}`);
  }
}
