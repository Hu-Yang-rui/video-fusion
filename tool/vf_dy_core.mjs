// vf_dy_core.mjs — live_core_sdk_data.pull_data.stream_data 精确结构 + FLV/LLS 可用性
//
// 背景：stream_url.flv_pull_url 实测为 {}，但 live_core_sdk_data 里的 stream_data
// （一个被字符串化的 JSON）含 flv/hls/lls 多档多线路。本探针把它挖出来并实测：
//   1) stream_data 顶层 key、common key、data key
//   2) 每个 quality(档位) 的 main/backup 有哪些协议字段（flv/hls/lls/cmaf/dash…）
//   3) 对每条 flv/lls 地址真拉前 4096 字节，验 'FLV' 魔数或 0x47
//   4) options.qualities 数组（sdk_key / name / level）→ 档位映射表
//
// 运行：node tool/vf_dy_core.mjs --rooms=3
import fs from 'node:fs';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const argv = process.argv.slice(2);
const numArg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? Number(a.split('=')[1]) : d; };
const ROOMS = numArg('rooms', 3);

async function feed() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 350 * i));
  }
  return [];
}
async function grab(url, range) {
  const ac = new AbortController(); const to = setTimeout(() => ac.abort(), 15000);
  try {
    const r = await fetch(url, { signal: ac.signal, headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', ...(range ? { range } : {}) } });
    const b = Buffer.from(await r.arrayBuffer());
    return { status: r.status, ct: r.headers.get('content-type'), len: b.length, buf: b };
  } catch (e) { return { status: 0, len: 0, buf: Buffer.alloc(0), err: `${e.name}:${e.message}` }; }
  finally { clearTimeout(to); }
}
const magic = (b) => {
  if (!b.length) return 'empty';
  if (b.subarray(0, 3).toString('latin1') === 'FLV') return `FLV(ver=${b[3]},hdr=${b.readUInt32BE(5)})`;
  if (b[0] === 0x47) return 'TS(0x47)';
  if (b.subarray(4, 8).toString('latin1') === 'ftyp') return 'fMP4';
  const t = b.subarray(0, 30).toString('utf8');
  if (t.startsWith('#EXTM3U')) return 'm3u8';
  return `?${JSON.stringify(t.replace(/\s+/g, ' '))}`;
};

const rooms = await feed();
console.log(`=== vf_dy_core: stream_data 精确结构（房间数 ${rooms.length}，抽 ${ROOMS}）===`);
for (const room of rooms.slice(0, ROOMS)) {
  const su = room.stream_url ?? {};
  const sdStr = su?.live_core_sdk_data?.pull_data?.stream_data;
  console.log(`\n──── 房间 ${room.id_str} status=${room.status} default=${su.default_resolution} ` +
    `flv_pull_url keys=${JSON.stringify(Object.keys(su.flv_pull_url ?? {}))} hls_top_len=${(su.hls_pull_url ?? '').length}`);
  console.log(`  stream_url 里可能藏流的其它 key: ` +
    Object.keys(su).filter((k) => /pull|stream|data|play|url/i.test(k)).join(', '));
  console.log(`  play=${JSON.stringify(su.play)?.slice(0, 120)} pull_datas=${JSON.stringify(su.pull_datas)?.slice(0, 160)} ` +
    `stream_control_type=${su.stream_control_type} multi_stream_scene=${JSON.stringify(su.multi_stream_scene)?.slice(0, 80)}`);
  if (!sdStr) { console.log('  (无 stream_data)'); continue; }
  let sd; try { sd = JSON.parse(sdStr); } catch (e) { console.log('  stream_data 解析失败', e.message); continue; }
  console.log(`  stream_data 顶层 keys: ${Object.keys(sd).join(', ')}`);
  console.log(`  common keys: ${Object.keys(sd.common ?? {}).join(', ')}`);
  console.log(`  common.stream=${sd.common?.stream} session_id=${sd.common?.session_id} ts=${sd.common?.ts} ` +
    `mode=${sd.common?.mode} app_id=${sd.common?.app_id} auto=${JSON.stringify(sd.common?.auto)}`);
  console.log(`  data keys: ${Object.keys(sd.data ?? {}).join(', ')}`);
  // options.qualities 档位表
  const opts = su?.live_core_sdk_data?.pull_data?.options;
  console.log(`  options.default_quality=${JSON.stringify(opts?.default_quality)}`);
  console.log(`  options.qualities=` + JSON.stringify(opts?.qualities));
  console.log(`  options.quality_strategy=${JSON.stringify(opts?.quality_strategy)} vpass=${opts?.vpass_default}`);
  // 实测：stream_data.data 直接以 sdk_key 为 key（**不是** data.media_list）
  const ml = sd.data ?? {};
  const qKeys = new Set((opts?.qualities ?? []).map((x) => x.sdk_key));
  console.log(`  data 档位: [${Object.keys(ml).join(', ')}]  (options.qualities sdk_key: [${[...qKeys].join(', ')}])`);
  for (const [q, v] of Object.entries(ml)) {
    if (typeof v === 'string') {
      console.log(`    ${q}: <str len=${v.length}> ${v.slice(0, 220)}`);
      continue;
    }
    for (const line of ['main', 'backup', 'zhi']) {
      const m = v?.[line]; if (!m) continue;
      const fields = Object.entries(m).filter(([, x]) => typeof x === 'string' && /^https?:/.test(x)).map(([k]) => k);
      console.log(`    ${q}.${line}: 协议字段=[${fields.join(',')}] ` +
        `bitrate=${m.templateRealTimeInfo?.bitrateKbps} name=${m.templateRealTimeInfo?.name} ` +
        `sdk_params=${(m.sdk_params ?? '').slice(0, 110)}`);
    }
  }
  // 实测每个档位的 flv 与 lls
  for (const [q, v] of Object.entries(ml)) {
    if (typeof v !== 'object') continue;
    for (const proto of ['flv', 'lls', 'hls', 'cmaf', 'dash']) {
      const u = v?.main?.[proto];
      if (typeof u !== 'string' || !u) continue;
      const g = await grab(u, 'bytes=0-4095');
      console.log(`    ${q}.${proto} 实测: HTTP=${g.status} ct=${g.ct ?? '-'} len=${g.len} ` +
        `魔数=${magic(g.buf)}${g.err ? ' ERR ' + g.err : ''} host=${(() => { try { return new URL(u).hostname } catch { return '?' } })()}`);
    }
  }
}
