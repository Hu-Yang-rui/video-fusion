// vf_dy_cdn_auth.mjs — CDN 鉴权两种方案 + 403 的两种指纹（Q3 核心）
//
// 实测发现播放地址有**两套不同的签名方案**（按 CDN 节点/房间不同）：
//   方案 A：?expire=<秒级>&sign=<md5>&…            → 改 expire/sign 一律 HTTP=403 len=0
//   方案 B：?keeptime=&wsSecret=&wsTime=&…          → 阿里 Tengine 式 remote-auth
//                                                   改 expire/sign **无效**（因为不存在）
// 并且 403 有两种形态：
//   403 + Content-Length: 0        → 鉴权失败（签名/过期）
//   403 + text/html 2592B 抖音错误页 → 流本身不存在（房间已撤/下播）
// 这就是 UI 区分"下播"与"网络失败"的判据。本探针逐条坐实。
//
// 另外实测 master playlist 里的 variant URI 可能是**裸 IP host**
// （http://59.37.89.99/pull-hls-q1.douyincdn.com/…），Dart 侧拼相对分片必须处理。
//
// 运行：node tool/vf_dy_cdn_auth.mjs
import fs from 'node:fs';

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
async function req(url, headers = {}) {
  const ac = new AbortController(); const to = setTimeout(() => ac.abort(), 15000);
  try {
    const r = await fetch(url, { redirect: 'manual', signal: ac.signal,
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', ...headers } });
    const b = Buffer.from(await r.arrayBuffer());
    return { status: r.status, ct: r.headers.get('content-type'), cl: r.headers.get('content-length'),
      server: r.headers.get('server'), via: r.headers.get('via'), xtt: r.headers.get('x-tt-logid'),
      loc: r.headers.get('location'), buf: b };
  } catch (e) { return { status: 0, buf: Buffer.alloc(0), err: `${e.name}` }; }
  finally { clearTimeout(to); }
}
const desc = (r) => `HTTP=${r.status} len=${r.buf.length} ct=${r.ct ?? '-'} cl=${r.cl ?? '-'} server=${r.server ?? '-'}${r.loc ? ' loc=' + r.loc.slice(0, 50) : ''}${r.err ? ' ERR=' + r.err : ''}`;

console.log('=== vf_dy_cdn_auth: 两种签名方案 + 403 指纹 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }

const rows = [];
for (const room of rooms.slice(0, 5)) {
  const map = room.stream_url?.hls_pull_url_map ?? {};
  const entries = Object.entries(map);
  if (!entries.length) continue;
  const [tier0, url0] = entries[0];
  const u0 = new URL(url0);
  const scheme = u0.searchParams.has('expire') ? 'A(expire+sign)' : u0.searchParams.has('wsSecret') ? 'B(wsSecret+wsTime)' : '未知';
  console.log(`\n──── 房间 ${room.id_str} 档 ${tier0} 方案=${scheme}`);
  console.log(`  query keys: ${[...u0.searchParams.keys()].join(', ')}`);

  const base = await req(url0);
  console.log(`  [原始地址]            ${desc(base)}`);
  rows.push({ room: room.id_str, case: '原始地址(有效)', status: base.status, len: base.buf.length, ct: base.ct });
  const isMaster = base.buf.toString('utf8').includes('#EXT-X-STREAM-INF');
  console.log(`  playlist 类型: ${isMaster ? 'master（含 EXT-X-STREAM-INF）' : 'media（直接分片）'}`);
  const variantUrl = (() => {
    const m = base.buf.toString('utf8').match(/#EXT-X-STREAM-INF:[^\n]*\n([^\n]+)/);
    if (!m) return null;
    const v = m[1].trim();
    return v.startsWith('http') ? v : new URL(v, url0).toString();
  })();
  if (variantUrl) {
    const vu = new URL(variantUrl);
    console.log(`  variant host = ${vu.host} ${/^\d+\.\d+\.\d+\.\d+$/.test(vu.hostname) ? '⚠️ 裸 IP host！' : '(域名)'}`);
    console.log(`  variant query keys = ${[...vu.searchParams.keys()].join(', ')}`);
  }

  // 方案 A 篡改
  const tA = new URL(url0);
  if (tA.searchParams.has('expire')) {
    tA.searchParams.set('expire', String(Math.floor(Date.now() / 1000) - 7 * 86400));
    const r = await req(tA.toString());
    console.log(`  [A: expire→过去7天]   ${desc(r)}${r.buf.length && r.buf.length < 400 ? ' body=' + JSON.stringify(r.buf.toString('utf8').slice(0, 90)) : (r.buf.length > 400 ? ' body=HTML错误页' : '')}`);
    rows.push({ room: room.id_str, case: 'expire 改过去', status: r.status, len: r.buf.length, ct: r.ct });
  }
  const tA2 = new URL(url0);
  if (tA2.searchParams.has('sign')) {
    tA2.searchParams.set('sign', '0'.repeat(32));
    const r = await req(tA2.toString());
    console.log(`  [A: sign→全 0]        ${desc(r)}`);
    rows.push({ room: room.id_str, case: 'sign 破坏', status: r.status, len: r.buf.length, ct: r.ct });
  }

  // 方案 B 篡改（wsSecret / wsTime）
  const tB = new URL(url0);
  if (tB.searchParams.has('wsSecret')) {
    tB.searchParams.set('wsSecret', '0'.repeat(32));
    const r = await req(tB.toString());
    console.log(`  [B: wsSecret→全 0]    ${desc(r)}`);
    rows.push({ room: room.id_str, case: 'wsSecret 破坏', status: r.status, len: r.buf.length, ct: r.ct });
    const tT = new URL(url0);
    const wt = tT.searchParams.get('wsTime');
    tT.searchParams.set('wsTime', (parseInt(wt, 16) - 7 * 86400).toString(16).padStart(wt.length, '0'));
    const r2 = await req(tT.toString());
    console.log(`  [B: wsTime→过去]      ${desc(r2)}  (wsTime 是 16 进制: ${wt})`);
    rows.push({ room: room.id_str, case: 'wsTime 改过去', status: r2.status, len: r2.buf.length, ct: r2.ct });
  } else {
    console.log(`  [B 方案] 本地址无 wsSecret，跳过`);
  }

  // 真分片：有效 / 破坏其签名
  const vbase = variantUrl ?? url0;
  const vr = await req(vbase);
  const segLines = vr.buf.toString('utf8').split(/\r?\n/).filter((l) => l && !l.startsWith('#'));
  if (segLines.length) {
    const segAbs = segLines[0].startsWith('http') ? segLines[0] : new URL(segLines[0], vbase).toString();
    const su = new URL(segAbs);
    console.log(`  分片 query keys = ${[...su.searchParams.keys()].join(', ')}  host=${su.host}`);
    const ok = await req(segAbs, { range: 'bytes=0-187' });
    console.log(`  [分片 原样]         ${desc(ok)} 首字节=0x${ok.buf[0]?.toString(16)}`);
    rows.push({ room: room.id_str, case: '分片原样', status: ok.status, len: ok.buf.length, ct: ok.ct });
    if (su.searchParams.get('wsSecret')) {
      su.searchParams.set('wsSecret', 'f'.repeat(32));
      const bad = await req(su.toString());
      console.log(`  [分片 wsSecret 破坏] ${desc(bad)}${bad.buf.length ? ' body头=' + JSON.stringify(bad.buf.subarray(0, 80).toString('latin1').replace(/\s+/g, ' ')) : ''}`);
      rows.push({ room: room.id_str, case: '分片 wsSecret 破坏', status: bad.status, len: bad.buf.length, ct: bad.ct });
    }
    if (su.searchParams.get('sign')) {
      const su2 = new URL(segAbs); su2.searchParams.set('sign', 'f'.repeat(32));
      const bad = await req(su2.toString());
      console.log(`  [分片 sign 破坏]     ${desc(bad)}`);
      rows.push({ room: room.id_str, case: '分片 sign 破坏', status: bad.status, len: bad.buf.length, ct: bad.ct });
    }
  }

  // 流不存在（房间撤）—— 改 stream 号
  const ghost = url0.replace(/stream-\d+/, 'stream-400000000000000000');
  const gr = await req(ghost);
  console.log(`  [stream 号改成不存在] ${desc(gr)}${gr.buf.length > 200 ? ' body=' + JSON.stringify(gr.buf.subarray(0, 120).toString('latin1').replace(/\s+/g, ' ')) : ''}`);
  rows.push({ room: room.id_str, case: 'stream 不存在', status: gr.status, len: gr.buf.length, ct: gr.ct,
    bodyKind: gr.buf.length > 200 ? 'html' : 'empty' });
  if (rows.filter((x) => x.case === '原始地址').length >= 3) break; // 抽 3 个房间即可
}

console.log('\n=== 403 形态归类（决定 UI 文案）===');
const byCase = {};
for (const r of rows) {
  const k = `HTTP ${r.status} / len=${r.len > 0 ? (r.len > 400 ? '>400(HTML)' : '有body') : '0'} / ct=${r.ct ?? '-'}`;
  byCase[r.case] = byCase[r.case] ?? [];
  byCase[r.case].push(k);
}
for (const [c, v] of Object.entries(byCase)) console.log(`  ${c.padEnd(22)} → ${[...new Set(v)].join('  |  ')}`);
fs.writeFileSync('tool/_dy_cdn_auth.json', JSON.stringify({ at: new Date().toISOString(), rows }, null, 2), 'utf8');
console.log('\n已写 tool/_dy_cdn_auth.json');
