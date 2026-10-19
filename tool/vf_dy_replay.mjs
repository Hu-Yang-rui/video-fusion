// vf_dy_replay.mjs — 「已结束」房间在接口里的真实形态（Q3 的关键补充）
//
// 已实测：feed 里 status 恒为 2（24/24），拿不到 status!=2 的条目。
// 但 feed 里有 13/24 条 is_replay / replay 为真 —— 这些就是"下播后仍以回放形态存在"的条目。
// 本探针专攻：
//   1) 多批 feed，找 is_replay=true / replay=true / replay_location!=0 / status!=2 的条目
//   2) 对这类条目：是否仍带 hls_pull_url_map？地址能否真拉（200/403）？
//   3) 纵向复验：把本会话早期抓到的房间 id 再查一遍 room/info，看 status 是否变化、
//      其地址是否已 403（这是"下播"与"网络失败"区分的直接证据）
//   4) 对同一个 room_id 连查 2 次 room/info，观察 status/user_count 抖动幅度
//
// 运行：node tool/vf_dy_replay.mjs --batches=5
import fs from 'node:fs';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800' +
  '&version_name=18.8.0&cookie_enabled=true&device_platform=web&browser_name=Mozilla&browser_online=true';

async function feedBatches(n) {
  const out = [];
  for (let b = 0; b < n; b++) {
    let rooms = [];
    for (let i = 1; i <= 10; i++) {
      const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
        headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
      const t = await r.text();
      if (t.trim()) { const j = JSON.parse(t); rooms = (j.data ?? []).map((e) => e?.data).filter(Boolean); break; }
      await new Promise((s) => setTimeout(s, 300 * i));
    }
    console.log(`  batch#${b + 1}: ${rooms.length} 房间 status=[${[...new Set(rooms.map((r) => r.status))].join(',')}]`);
    out.push(...rooms);
    await new Promise((s) => setTimeout(s, 300));
  }
  return out;
}
async function fetchHead(url, n = 4096, ms = 12000) {
  const ac = new AbortController(); const timer = setTimeout(() => ac.abort(), ms);
  try {
    const r = await fetch(url, { signal: ac.signal, headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    let got = 0; const chunks = [];
    if (r.body) { const rd = r.body.getReader(); while (got < n) { const { done, value } = await rd.read(); if (done) break; chunks.push(Buffer.from(value)); got += value.length; } try { rd.cancel(); } catch {} }
    ac.abort();
    return { status: r.status, ct: r.headers.get('content-type'), buf: Buffer.concat(chunks) };
  } catch (e) { return { status: 0, buf: Buffer.alloc(0), err: `${e.name}` }; }
  finally { clearTimeout(timer); }
}

console.log('=== vf_dy_replay: 已结束/回放房间的真实形态 ===');
const argv = process.argv.slice(2);
const nb = Number((argv.find((s) => s.startsWith('--batches=')) ?? '--batches=5').split('=')[1]);
const rooms = await feedBatches(nb);
const uniq = [...new Map(rooms.map((r) => [r.id_str, r])).values()];
console.log(`\n  去重后房间 ${uniq.length} 个；status 集合=[${[...new Set(uniq.map((r) => r.status))].join(',')}]`);

console.log('\n── 1) is_replay / replay 条目占比与形态 ──');
const flagCount = {};
for (const r of uniq) {
  const k = `is_replay=${r.is_replay} replay=${r.replay} loc=${r.replay_location} status=${r.status} finish_reason=${r.finish_reason} stream_close=${r.stream_close_time}`;
  flagCount[k] = (flagCount[k] ?? 0) + 1;
}
for (const [k, v] of Object.entries(flagCount)) console.log(`  ${v}× ${k}`);

console.log('\n── 2) 这些条目是否仍带可播地址 + 真拉验证 ──');
for (const r of uniq.slice(0, 6)) {
  const tiers = Object.keys(r.stream_url?.hls_pull_url_map ?? {});
  const u = Object.values(r.stream_url?.hls_pull_url_map ?? {})[0];
  let probe = '';
  if (u) {
    const h = await fetchHead(u, 256);
    probe = `GET playlist HTTP=${h.status} ct=${h.ct ?? '-'} 首4B=${h.buf.subarray(0, 4).toString('latin1') === '#EXT' ? '#EXT' : h.buf.subarray(0, 8).toString('hex').match(/.{2}/gu).join(' ')}${h.err ? ' ' + h.err : ''}`;
  }
  console.log(`  ${r.id_str} status=${r.status} is_replay=${r.is_replay} replay=${r.replay} 档位=[${tiers.join(',')}] ${probe}`);
}

console.log('\n── 3) 纵向复验：早期快照里的房间现在如何 ──');
let old = null;
try { old = JSON.parse(fs.readFileSync('tool/_dy_feed_streams.json', 'utf8')); } catch {}
if (old) {
  console.log(`  快照时间 ${old.at}（距今 ${((Date.now() - Date.parse(old.at)) / 60000).toFixed(1)} 分钟），含 ${old.rooms.length} 房间`);
  for (const r of old.rooms.slice(0, 5)) {
    // a) 是否仍在 feed 集合里
    const inFeed = uniq.some((x) => x.roomId === r.roomId || x.id_str === r.roomId);
    // b) room/info 再查
    let info = null;
    try {
      info = await fetch(`https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${r.roomId}`, {
        headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } }).then((x) => x.json());
    } catch {}
    const d = info?.data ?? {};
    const empty = !d || Object.keys(d).length === 0;
    // c) 用**当时快照里的旧地址**再拉一次 → 这是"地址失效"最直接的证据
    const oldUrl = Object.values(r.hlsMap ?? {})[0] ?? null;
    let oldRes = '';
    if (oldUrl) { const h = await fetchHead(oldUrl, 128); oldRes = `旧快照地址 HTTP=${h.status}${h.err ? '/' + h.err : ''}`; }
    // d) 用刚拿到的新地址拉一次，对比
    const newUrl = Object.values(d.stream_url?.hls_pull_url_map ?? {})[0] ?? null;
    let newRes = '';
    if (newUrl) { const h = await fetchHead(newUrl, 128); newRes = `新地址 HTTP=${h.status}${h.err ? '/' + h.err : ''}`; }
    console.log(`  ${r.roomId} 在feed=${inFeed ? 'Y' : 'N'} room/info:${empty ? `data 空 status_code=${info?.status_code} msg=${JSON.stringify(info?.data?.message ?? info?.status_msg ?? null)}` : `status=${d.status} uc=${d.user_count} 档位=${Object.keys(d.stream_url?.hls_pull_url_map ?? {}).length}`} ${oldRes} ${newRes}`);
  }
}

console.log('\n── 4) 同 room_id 连查 2 次的抖动（决定 UI 该信谁）──');
const rid = uniq[0]?.id_str;
if (rid) {
  const a = await fetch(`https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${rid}`, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } }).then((r) => r.json()).catch(() => null);
  await new Promise((s) => setTimeout(s, 1200));
  const b = await fetch(`https://webcast.amemv.com/webcast/room/info/?${WEBQ}&room_id=${rid}`, { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } }).then((r) => r.json()).catch(() => null);
  const u = (j) => ({ status: j?.data?.status, uc: j?.data?.user_count, exp: (() => { try { return new URL(Object.values(j?.data?.stream_url?.hls_pull_url_map ?? {})[0]).searchParams.get('expire'); } catch { return null; } })(), sign: (() => { try { const x = new URL(Object.values(j?.data?.stream_url?.hls_pull_url_map ?? {})[0]).searchParams.get('sign'); return x ? x.slice(0, 8) + '…' : null; } catch { return null; } })() });
  console.log(`  第1次 ${JSON.stringify(u(a))}`);
  console.log(`  第2次 ${JSON.stringify(u(b))}`);
  console.log(`  → 同房间两次下发的 expire/sign 是否相同：${JSON.stringify(u(a)) === JSON.stringify(u(b)) ? '相同（地址稳定）' : '不同（地址每次重新签发，不可缓存）'}`);
}
