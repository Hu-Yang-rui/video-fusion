// vf_dy_roominfo_ablate.mjs — /webcast/room/info/ 到底靠哪些参数才通（逐项消融）
//
// 背景：另一个 agent 用 aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web
//   &version_code=180800 这组**短参数**打 room/info/ 得到 HTTP 200 / len=0；
//   我用**长 web 参数集**得到 59162B / 165 字段。分歧必须坐实到具体参数。
//
// 做法：
//   1) 打印我成功那次用的**完整 URL + 全部请求头**（cookie 只列头名，不列值）
//   2) 以长参数集为基线，逐个删掉一个参数 → 看 body 是否变 0（找出必需参数）
//   3) 以短参数集为基线，逐个加上一个参数 → 找出触发成功的那个
//   4) 明确测：需不需要 cookie（ttwid / __ac_nonce / 先访问 live.douyin.com 首页拿 cookie）
//   5) 域名维度：webcast.amemv.com / live.douyin.com / webcast.bytedance.com
//
// 运行：node tool/vf_dy_roominfo_ablate.mjs
import dns from 'node:dns/promises';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';

// 我成功那次（vf_dy_roominfo_id.mjs）用的完整 web 参数集，逐字照抄
const FULL_WEB = {
  aid: '6383',
  app_name: 'aweme',
  channel: 'channel_id_web',
  device_platform: 'web',
  version_code: '180800',
  version_name: '18.8.0',
  cookie_enabled: 'true',
  screen_width: '1536',
  screen_height: '864',
  browser_language: 'zh-CN',
  browser_platform: 'Win32',
  browser_name: 'Mozilla',
  browser_version: '5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36',
  browser_online: 'true',
  timezone_name: 'Asia/Shanghai',
};
// 对方那组短参数
const SHORT_WEB = { aid: '6383', app_name: 'aweme', channel: 'channel_id_web', device_platform: 'web', version_code: '180800' };

const enc = (o) => Object.entries(o).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');

async function feedRoom() {
  for (let i = 1; i <= 10; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) {
      const rooms = (JSON.parse(t).data ?? []).map((e) => e?.data).filter(Boolean);
      if (rooms.length) return rooms[0];
    }
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return null;
}
async function call(url, { ua = UA_WEB, ref = 'https://live.douyin.com/', cookie = null, extraHeaders = {} } = {}) {
  const headers = { 'user-agent': ua, referer: ref, accept: 'application/json, text/plain, */*', ...extraHeaders };
  if (cookie) headers.cookie = cookie;
  try {
    const r = await fetch(url, { headers, redirect: 'manual' });
    const b = Buffer.from(await r.arrayBuffer());
    let j = null; try { j = JSON.parse(b.toString('utf8')); } catch {}
    return { status: r.status, len: b.length, json: j, headers: Object.fromEntries(r.headers.entries()) };
  } catch (e) { return { status: 0, len: 0, err: `${e.name}: ${String(e.message).slice(0, 40)}` }; }
}
const verdict = (r) => {
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  const emptyObj = d && typeof d === 'object' && keys === 0;
  return `HTTP=${r.status} len=${r.len}` +
    (r.json ? ` status_code=${r.json.status_code}${r.json.status_msg ? ' msg=' + JSON.stringify(r.json.status_msg) : ''}` : ' (非JSON)') +
    ` data字段数=${keys}${emptyObj ? ' [data 为空对象]' : ''}` +
    (keys > 50 ? ` ✅房间对象 id_str=${d.id_str} status=${d.status} 档位=${Object.keys(d.stream_url?.hls_pull_url_map ?? {}).length}` : '') +
    (r.err ? ` ERR=${r.err}` : '');
};

console.log('=== vf_dy_roominfo_ablate: room/info 必需参数定位 ===');
const room = await feedRoom();
if (!room) { console.log('feed 无数据'); process.exit(1); }
const rid = room.id_str, uid = room.owner?.id_str;
console.log(`样本 room=${rid} uid=${uid} status=${room.status} orientation=${room.orientation} stream_orientation=${room.stream_url?.stream_orientation}`);

// ── 1) 成功请求原样打印（URL + 头，cookie 只列名）──────────────
const successUrl = `https://webcast.amemv.com/webcast/room/info/?${enc(FULL_WEB)}&room_id=${rid}`;
console.log('\n── 1) 我成功那次用的原始请求（无 cookie）──');
console.log('  METHOD GET');
console.log('  URL  ' + successUrl);
console.log('  HEAD user-agent: ' + UA_WEB);
console.log('  HEAD referer:    https://live.douyin.com/');
console.log('  HEAD accept:     application/json, text/plain, */*');
console.log('  HEAD cookie:     (不带任何 cookie)');
const s1 = await call(successUrl);
console.log('  → ' + verdict(s1));
console.log('  响应头关键项: ' + JSON.stringify({
  'content-type': s1.headers['content-type'], 'server': s1.headers['server'],
  'x-tt-logid': s1.headers['x-tt-logid'], 'set-cookie': s1.headers['set-cookie'] ? '(下发了 cookie)' : '(无)',
}));

if (s1.len === 0) {
  console.log('\n⚠️ 本次连"长参数集"都拿不到数据 —— 说明该端点行为随时间/IP/风控状态变化。');
  console.log('   继续做下面的矩阵，把变化范围也测出来。');
}

// ── 2) 短参数集（对方用的）────────────────────────────────────
const shortUrl = `https://webcast.amemv.com/webcast/room/info/?${enc(SHORT_WEB)}&room_id=${rid}`;
console.log('\n── 2) 对方的短参数集 ──');
console.log('  URL  ' + shortUrl);
console.log('  → ' + verdict(await call(shortUrl)));

// ── 3) 消融：从长参数集逐个删 ─────────────────────────────────
console.log('\n── 3) 长参数集逐项删除（找必需参数）──');
for (const k of Object.keys(FULL_WEB)) {
  const o = { ...FULL_WEB }; delete o[k];
  const r = await call(`https://webcast.amemv.com/webcast/room/info/?${enc(o)}&room_id=${rid}`);
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  console.log(`  删 ${k.padEnd(18)} → len=${r.len} data字段=${keys} ${keys > 50 ? '仍可用' : '❌失效'}${r.json?.status_code !== undefined ? ' sc=' + r.json.status_code : ''}`);
  await new Promise((s) => setTimeout(s, 120));
}

// ── 4) 累积：从短参数集逐项加 ─────────────────────────────────
console.log('\n── 4) 短参数集逐项加回（找触发参数）──');
const order = ['version_name', 'cookie_enabled', 'screen_width', 'screen_height', 'browser_language',
  'browser_platform', 'browser_name', 'browser_version', 'browser_online', 'timezone_name'];
let acc = { ...SHORT_WEB };
for (const k of order) {
  acc = { ...acc, [k]: FULL_WEB[k] };
  const r = await call(`https://webcast.amemv.com/webcast/room/info/?${enc(acc)}&room_id=${rid}`);
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  console.log(`  加到 ${Object.keys(acc).length} 个（+${k.padEnd(16)}）→ len=${r.len} data字段=${keys} ${keys > 50 ? '✅' : ''}`);
  await new Promise((s) => setTimeout(s, 120));
}

// ── 4b) 二分：只留 aid + browser_* / 只留 aid + screen_* 等组合
console.log('\n── 4b) 关键组合二分 ──');
const combos = [
  ['仅 aid+device_platform+version_code+cookie_enabled', { aid: '6383', device_platform: 'web', version_code: '180800', cookie_enabled: 'true' }],
  ['+browser_name+browser_version', { aid: '6383', device_platform: 'web', version_code: '180800', browser_name: 'Mozilla', browser_version: '5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0.0.0 Safari/537.36' }],
  ['+screen_width+screen_height', { aid: '6383', device_platform: 'web', version_code: '180800', screen_width: '1536', screen_height: '864' }],
  ['+timezone_name', { aid: '6383', device_platform: 'web', version_code: '180800', timezone_name: 'Asia/Shanghai' }],
  ['aid=6383 单独', { aid: '6383' }],
  ['aid=6383+cookie_enabled', { aid: '6383', cookie_enabled: 'true' }],
  ['全参数但 aid=1128', { ...FULL_WEB, aid: '1128' }],
];
for (const [label, o] of combos) {
  const r = await call(`https://webcast.amemv.com/webcast/room/info/?${enc(o)}&room_id=${rid}`);
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  console.log(`  ${label.padEnd(48)} → len=${r.len} data字段=${keys} ${keys > 50 ? '✅' : ''}${r.json?.status_code !== undefined ? ' sc=' + r.json.status_code : ''}`);
  await new Promise((s) => setTimeout(s, 120));
}

// ── 5) UA 维度 ────────────────────────────────────────────────
console.log('\n── 5) UA 与 cookie 维度（长参数集固定）──');
const uaTests = [
  ['Chrome UA', UA_WEB, null],
  ['空 UA', '', null],
  ['App UA', UA_APP, null],
  ['curl UA', 'curl/8.4.0', null],
  ['Chrome UA + ttwid cookie', UA_WEB, 'ttwid=__PLACEHOLDER__'],
  ['Chrome UA + 假 webcast cookie', UA_WEB, '__ac_nonce=0675abcdef'],
] ;
// 先取真 ttwid
let tw = null;
try {
  const r = await fetch('https://ttwid.bytedance.com/ttwid/union/register/', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ region: 'cn', aid: 1768, needFid: false, service: 'www.ixigua.com', migrate_info: { ticket: '', source: 'node' }, cbUrlProtocol: 'https', union: true }),
  });
  tw = (r.headers.get('set-cookie') ?? '').match(/ttwid=([^;]+)/)?.[1] ?? null;
} catch {}
console.log(`  (ttwid 获取: ${tw ? '成功，长度 ' + tw.length : '失败'})`);
for (const [label, ua, ck] of uaTests) {
  let cookie = ck;
  if (cookie?.includes('__PLACEHOLDER__')) cookie = ck.replace('__PLACEHOLDER__', tw ?? 'none');
  const r = await call(`https://webcast.amemv.com/webcast/room/info/?${enc(FULL_WEB)}&room_id=${rid}`, { ua, cookie });
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  console.log(`  ${label.padEnd(30)} → len=${r.len} data字段=${keys} ${keys > 50 ? '✅' : ''}${r.json?.status_code !== undefined ? ' sc=' + r.json.status_code : ' ' + (r.status === 200 && r.len === 0 ? '(200 空 body)' : '')}`);
  await new Promise((s) => setTimeout(s, 150));
}

console.log('\n── 5b) 先访问 live.douyin.com 首页拿 cookie 再打（会话预热假设）──');
{
  const home = await fetch('https://live.douyin.com/', { headers: { 'user-agent': UA_WEB } });
  const sc = home.headers.getSetCookie?.() ?? [];
  const names = sc.map((c) => c.split('=')[0]);
  console.log(`  首页 HTTP=${home.status} set-cookie 头名=${JSON.stringify(names)}（不打印值）`);
  const jar = sc.map((c) => c.split(';')[0]).join('; ');
  const r = await call(`https://webcast.amemv.com/webcast/room/info/?${enc(FULL_WEB)}&room_id=${rid}`, { cookie: jar || null });
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  console.log(`  带首页 cookie → len=${r.len} data字段=${keys} ${keys > 50 ? '✅' : '❌'}`);
}

// ── 6) 域名维度 ───────────────────────────────────────────────
console.log('\n── 6) 域名维度（长参数集固定）──');
for (const host of ['webcast.amemv.com', 'live.douyin.com', 'webcast.bytedance.com',
  'webcast.larkoffice.com', 'www.douyin.com']) {
  let ip = '';
  try { ip = (await dns.resolve4(host)).slice(0, 2).join(','); } catch (e) { ip = `DNS失败(${e.code})`; }
  const r = await call(`https://${host}/webcast/room/info/?${enc(FULL_WEB)}&room_id=${rid}`);
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  console.log(`  ${host.padEnd(24)} ${ip.padEnd(30)} → len=${r.len} data字段=${keys} ${keys > 50 ? '✅' : ''}`);
  await new Promise((s) => setTimeout(s, 120));
}

// ── 7) 稳定性：同一请求连打 8 次，看是否间歇性 len=0 ──────────
console.log('\n── 7) 稳定性：长参数集连打 8 次 ──');
const lens = [];
for (let i = 0; i < 8; i++) {
  const r = await call(successUrl);
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  lens.push({ len: r.len, keys, sc: r.json?.status_code });
  console.log(`  #${i + 1} len=${r.len} data字段=${keys}${r.json?.status_code !== undefined ? ' sc=' + r.json.status_code : ''}`);
  await new Promise((s) => setTimeout(s, 200));
}
const okN = lens.filter((x) => x.keys > 50).length;
console.log(`  → 8 次里成功 ${okN} 次（${(okN / 8 * 100).toFixed(0)}%）：${okN === 8 ? '稳定' : okN > 0 ? '**间歇性**，适配器必须重试' : '现在整体不可用'}\n`);

console.log('── 8) 对照：room/info_by_user 用同样两套参数 ──');
for (const [label, o] of [['短参数', SHORT_WEB], ['长参数', FULL_WEB]]) {
  const r = await call(`https://webcast.amemv.com/webcast/room/info_by_user/?${enc(o)}&user_id=${uid}`);
  const d = r.json?.data;
  const keys = d && typeof d === 'object' ? Object.keys(d).length : 0;
  console.log(`  info_by_user ${label} → len=${r.len} data字段=${keys} ${keys > 50 ? '✅' : '❌'}`);
}
