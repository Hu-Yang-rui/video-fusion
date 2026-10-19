// vf_dy_offline.mjs — 下播（status != 直播中）与播放地址失效实测
//
// 决定 UI 如何区分"下播"与"网络失败"。本探针做四件事：
//   1) 多批 feed 采样，统计 status 的真实取值集合（不是假设 1=直播中）
//   2) 用 webcast/replay 或同 room 的其它接口看已下播房间是否仍返回
//      （只读探测；不存在的路径会回 "url doesn't match"，一并记录）
//   3) 拿一条**已过期**的播放地址（把 expire 改成过去时间戳 / 改 sign 破坏签名）
//      请求，记录真实 HTTP 状态码 + 响应体头部（这是"地址失效"的指纹）
//   4) 拿一条**当前有效**地址请求，对比状态码差异
//
// 运行：node tool/vf_dy_offline.mjs --batches=4
import fs from 'node:fs';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const argv = process.argv.slice(2);
const numArg = (n, d) => { const a = argv.find((s) => s.startsWith(`--${n}=`)); return a ? Number(a.split('=')[1]) : d; };
const BATCHES = numArg('batches', 4);

async function raw(url, opts = {}) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, {
      redirect: 'manual',
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', ...(opts.headers ?? {}) },
    });
    const b = Buffer.from(await r.arrayBuffer());
    return { status: r.status, len: b.length, head: b.subarray(0, 200).toString('utf8').replace(/\s+/g, ' '),
      ct: r.headers.get('content-type'), loc: r.headers.get('location'), ms: Date.now() - t0 };
  } catch (e) { return { status: 0, len: 0, head: '', err: `${e.name}: ${e.message}`, ms: Date.now() - t0 }; }
}
async function feedBatch(count = 12) {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${COMMON}&count=${count}&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 350 * i));
  }
  return [];
}

console.log('=== vf_dy_offline: 下播与失效实测 ===\n');

// ── 1) status 取值集合（多批）────────────────────────────────
const seen = new Map();
const all = [];
for (let b = 0; b < BATCHES; b++) {
  const rooms = await feedBatch();
  for (const r of rooms) { all.push(r); seen.set(String(r.status), (seen.get(String(r.status)) ?? 0) + 1); }
  console.log(`  batch#${b + 1}: ${rooms.length} 房间, status 集合=[${[...new Set(rooms.map((r) => r.status))].join(',')}]`);
  await new Promise((s) => setTimeout(s, 400));
}
console.log(`\n  全局 status 分布: ${JSON.stringify(Object.fromEntries(seen))}`);
const anyNonTwo = all.filter((r) => r.status !== 2);
console.log(`  非 status=2 的房间数: ${anyNonTwo.length}`);
console.log(`  注意: video_feed_tag=${JSON.stringify(all[0]?.video_feed_tag)} finish_time=${all[0]?.finish_time} ` +
  `start_time=${all[0]?.start_time} stream_close_time=${all[0]?.stream_close_time}`);
console.log(`  时间合理性: now=${Math.floor(Date.now() / 1000)} → start<now? ` +
  `${all[0]?.start_time < Math.floor(Date.now() / 1000)} finish<now? ${all[0]?.finish_time < Math.floor(Date.now() / 1000)}`);

// 每个 status 值对应的"是否带可播流"，用于反推语义
const perStatus = {};
for (const r of all) {
  const k = String(r.status);
  perStatus[k] = perStatus[k] ?? { n: 0, withStream: 0, withFinishTime: 0, withReplay: 0 };
  perStatus[k].n++;
  if (Object.keys(r.stream_url?.hls_pull_url_map ?? {}).length) perStatus[k].withStream++;
  if (r.finish_time) perStatus[k].withFinishTime++;
  if (r.is_replay || r.replay) perStatus[k].withReplay++;
}
console.log(`  按 status 分类: ${JSON.stringify(perStatus)}`);

// ── 2) 下播房间相关只读探测 ──────────────────────────────────
console.log('\n=== 已下播/重播可访问性探测（只读 GET）===');
const probeRoom = all[0];
const rid = probeRoom.id_str;
const paths = [
  ['webcast/room/settings/', `https://webcast.amemv.com/webcast/room/settings/?${COMMON}&room_id=${rid}`],
  ['webcast/room/enter/', `https://webcast.amemv.com/webcast/room/enter/?${COMMON}&room_id=${rid}`],
  ['webcast/room/replay/', `https://webcast.amemv.com/webcast/room/replay/?${COMMON}&room_id=${rid}`],
  ['webcast/replay/feed/', `https://webcast.amemv.com/webcast/replay/feed/?${COMMON}&room_id=${rid}&count=5`],
  ['webcast/room/wish/list/', `https://webcast.amemv.com/webcast/room/wish/list/?${COMMON}&room_id=${rid}`],
];
for (const [name, url] of paths) {
  const r = await raw(url);
  console.log(`  ${name.padEnd(26)} HTTP=${r.status} len=${r.len} body=${JSON.stringify(r.head.slice(0, 90))}${r.err ? ' ERR ' + r.err : ''}`);
}

// ── 3+4) 播放地址：有效 vs 过期/签名破坏 ─────────────────────
console.log('\n=== 播放地址失效指纹 ===');
const goodUrl = probeRoom.stream_url?.hls_pull_url_map?.HD1 ?? Object.values(probeRoom.stream_url?.hls_pull_url_map ?? {})[0];
if (!goodUrl) { console.log('  无播放地址，跳过'); }
else {
  const g = await raw(goodUrl);
  console.log(`  [有效地址]      HTTP=${g.status} ct=${g.ct} len=${g.len} body=${JSON.stringify(g.head.slice(0, 60))}`);

  const u = new URL(goodUrl);
  const now = Math.floor(Date.now() / 1000);

  // 3a) expire 改成过去
  const expired = new URL(goodUrl); expired.searchParams.set('expire', String(now - 7 * 86400));
  const e1 = await raw(expired.toString());
  console.log(`  [expire=过去]     HTTP=${e1.status} len=${e1.len} body=${JSON.stringify(e1.head.slice(0, 140))}${e1.err ? ' ERR ' + e1.err : ''}`);

  // 3b) sign 破坏（模拟被篡改/取错）
  const badSign = new URL(goodUrl); badSign.searchParams.set('sign', '0'.repeat(32));
  const e2 = await raw(badSign.toString());
  console.log(`  [sign 破坏]       HTTP=${e2.status} len=${e2.len} body=${JSON.stringify(e2.head.slice(0, 140))}${e2.err ? ' ERR ' + e2.err : ''}`);

  // 3c) 去掉 sign（模拟无鉴权）
  const noSign = new URL(goodUrl); noSign.searchParams.delete('sign');
  const e3 = await raw(noSign.toString());
  console.log(`  [无 sign]         HTTP=${e3.status} len=${e3.len} body=${JSON.stringify(e3.head.slice(0, 140))}${e3.err ? ' ERR ' + e3.err : ''}`);

  // 3d) 不存在的房间路径（同 host，模拟房间流已撤）
  const ghost = goodUrl.replace(/stream-\d+/, 'stream-999999999999999');
  const e4 = await raw(ghost);
  console.log(`  [stream 不存在]   HTTP=${e4.status} len=${e4.len} body=${JSON.stringify(e4.head.slice(0, 140))}${e4.err ? ' ERR ' + e4.err : ''}`);

  // 3e) 分片地址过期
  const seg = new URL(goodUrl);
  const tsNow = now - 7 * 86400;
  const segUrl = goodUrl.replace(/\.m3u8.*$/, `-${tsNow}.ts`);
  const e5 = await raw(segUrl);
  console.log(`  [猜的分片名]      HTTP=${e5.status} len=${e5.len} (${JSON.stringify(segUrl.slice(-50))})`);

  const expRaw = u.searchParams.get('expire') ?? u.searchParams.get('x-expires') ?? u.searchParams.get('t');
  const expNum = Number(expRaw);
  const valid = Number.isFinite(expNum) && expNum > 0;
  // 抖音有时下发秒级、有时下发毫秒级时间戳，两种都试
  const asDate = valid
    ? new Date(expNum < 1e11 ? expNum * 1000 : expNum).toISOString()
    : '(无 expire 参数)';
  console.log(`\n  URL query keys = ${[...u.searchParams.keys()].join(',')}`);
  console.log(`  expire 原值 = ${expRaw} → ${asDate}`);
  console.log(`  距今 = ${valid ? ((expNum - now) / 3600).toFixed(1) : '?'} 小时（按秒级解释）`);
}

// ── 用真实分片验证过期行为：先取 playlist 的分片行，再分别请求有效/过期 ──
console.log('\n=== 用真实 .ts 分片验证过期行为 ===');
{
  const nowS = Math.floor(Date.now() / 1000);
  // 逐房间：master → variant → 分片（分片的相对 base 必须是 **variant**，不是 master）
  let segAbs = null, segBase = null;
  for (const room of all.slice(0, 6)) {
    for (const u of Object.values(room.stream_url?.hls_pull_url_map ?? {})) {
      const pl = await fetch(u, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } }).then((r) => r.text()).catch(() => '');
      if (!pl.startsWith('#EXTM3U')) continue;
      let base = u, body = pl;
      const m = pl.match(/#EXT-X-STREAM-INF:[^\n]*\n([^\n]+)/);
      if (m) { // master → 取第一条 variant
        const vu = m[1].trim().startsWith('http') ? m[1].trim() : new URL(m[1].trim(), u).toString();
        body = await fetch(vu, { headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } }).then((r) => r.text()).catch(() => '');
        base = vu;
      }
      const lines = body.split(/\r?\n/).filter((l) => l && !l.startsWith('#'));
      if (lines.length) {
        segBase = base;
        segAbs = lines[0].startsWith('http') ? lines[0] : new URL(lines[0], base).toString();
        console.log(`  房间 ${room.id_str} 分片行数=${lines.length}（master=${!!m}）`);
        console.log(`  第一行(截断)=${JSON.stringify(lines[0].slice(0, 100))}`);
        break;
      }
    }
    if (segAbs) break;
  }
  if (!segAbs) console.log('  未取到分片行，跳过');
  else {
    const ok = await raw(segAbs, { headers: { range: 'bytes=0-187' } });
    const firstByteHex = ok.bufFirstByte ?? (ok.head ? '0x' + ok.head.charCodeAt(0).toString(16) : '?');
    console.log(`  [分片 有效]       HTTP=${ok.status} ct=${ok.ct} len=${ok.len} 首字节=${firstByteHex}`);
    const su = new URL(segAbs);
    const hasExpire = !!su.searchParams.get('expire');
    if (hasExpire) {
      su.searchParams.set('expire', String(nowS - 7 * 86400));
      const es = await raw(su.toString());
      console.log(`  [分片 expire 改]  HTTP=${es.status} len=${es.len} body=${JSON.stringify(es.head.slice(0, 120))}${es.err ? ' ERR ' + es.err : ''}`);
    } else {
      console.log(`  分片 URL 无 expire 参数（query keys=${[...su.searchParams.keys()].join(',')}），` +
        `改用同 playlist 的过期方式验证`);
      const pl = new URL(segBase);
      if (pl.searchParams.get('expire')) {
        pl.searchParams.set('expire', String(nowS - 7 * 86400));
        const e = await raw(pl.toString());
        console.log(`  [playlist expire 改] HTTP=${e.status} len=${e.len} body=${JSON.stringify(e.head.slice(0, 120))}`);
      }
    }
    // 分片 sign 破坏
    const su2 = new URL(segAbs);
    if (su2.searchParams.get('sign')) {
      su2.searchParams.set('sign', 'f'.repeat(32));
      const e2 = await raw(su2.toString());
      console.log(`  [分片 sign 破坏]    HTTP=${e2.status} len=${e2.len} body=${JSON.stringify(e2.head.slice(0, 120))}`);
    }
  }
}
