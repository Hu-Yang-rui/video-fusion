// vf_dy_feed.mjs — 抖音直播 webcast/feed 真实字段实测探针
//
// 用途：不依赖任何一次性状态，可重复运行。
//   1) 匿名（无 Cookie、无签名）请求 /webcast/feed/
//   2) 统计 HTTP 状态、body 长度、房间条数、空 body 重试率
//   3) 输出一份脱敏的真实响应字段树（长数组截断、URL 只保留 host+path 结构）
//   4) 逐房间打印关键字段的"确切名字与值类型"：封面/头像/昵称/标题/分区/
//      观看人数（user_count vs stat_display vs pulse）/status/room_id/id_str/
//      owner/cover.url_list/stream(hls_pull_url / live_play / hls_pull_url_map)
//   5) 把所有播放地址落到 tool/_dy_feed_streams.json，供 vf_dy_stream.mjs 复用
//
// 运行：node tool/vf_dy_feed.mjs            # 默认 count=10，采 2 批
//       node tool/vf_dy_feed.mjs --count=20 --batches=3
import fs from 'node:fs';
import path from 'node:path';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const COMMON =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const FEED = 'https://webcast.amemv.com/webcast/feed/';

const argv = process.argv.slice(2);
const numArg = (name, dflt) => {
  const a = argv.find((s) => s.startsWith(`--${name}=`));
  return a ? Number(a.split('=')[1]) : dflt;
};
const COUNT = numArg('count', 10);
const BATCHES = numArg('batches', 2);
const MAXTRY = numArg('maxtry', 8);
const OUT = path.join('tool', '_dy_feed_streams.json');
const RAW = path.join('tool', '_dy_feed_raw.json');

// ── 脱敏 ────────────────────────────────────────────────────────
const REDACT_HOSTS = new Set();
function maskUrl(u) {
  if (typeof u !== 'string' || !u) return u;
  try {
    const x = new URL(u);
    // 保留结构与 query 参数名，去掉真实签名值与真实路径尾段
    const q = [...x.searchParams.keys()].sort().join(',');
    const segs = x.pathname.split('/').filter(Boolean);
    const tail = segs.length ? `${segs.length}segs/${segs[segs.length - 1].slice(0, 6)}…` : '';
    return `${x.protocol}//${x.host}/${tail}?<${q}>`;
  } catch {
    return u.slice(0, 24) + '…';
  }
}
function maskToken(s) {
  if (typeof s !== 'string' || !s) return s;
  if (s.length <= 6) return s[0] + '**';
  return s.slice(0, 3) + '…' + s.slice(-2) + ` (len=${s.length})`;
}

/** 递归字段树：只保留类型与样本，数组截断到 2，字符串脱敏。 */
function fieldTree(node, depth = 0, maxDepth = 6) {
  if (node === null) return 'null';
  if (Array.isArray(node)) {
    if (node.length === 0) return 'Array(0)';
    if (depth >= maxDepth) return `Array(${node.length})`;
    return {
      __array: node.length,
      sample: fieldTree(node[0], depth + 1, maxDepth),
    };
  }
  if (typeof node === 'object') {
    if (depth >= maxDepth) return `Object{${Object.keys(node).length}}`;
    const out = {};
    for (const [k, v] of Object.entries(node)) {
      if (k === 'data' && typeof v === 'string') { out[k] = '<base64/binary>'; continue; }
      if (/url_list$/.test(k) || k === 'url_list') {
        out[k] = Array.isArray(v)
          ? { __array: v.length, sample: maskUrl(v[0]) }
          : v;
        continue;
      }
      if (/(^|_)(url|hls|flv|uri)$/.test(k) || /pull_url/.test(k)) {
        out[k] = typeof v === 'string' ? maskUrl(v) : v;
        continue;
      }
      if (/signature|token|_msToken|cookie/.test(k)) {
        out[k] = typeof v === 'string' ? maskToken(v) : `<${typeof v}>`;
        continue;
      }
      out[k] = fieldTree(v, depth + 1, maxDepth);
    }
    return out;
  }
  if (typeof node === 'string') {
    if (/^https?:\/\//.test(node)) return maskUrl(node);
    return node.length > 40 ? node.slice(0, 40) + '…' : node;
  }
  return node;
}

// ── 请求 ────────────────────────────────────────────────────────
async function feedOnce(count, offset = 0) {
  const t0 = Date.now();
  const r = await fetch(`${FEED}?${COMMON}&count=${count}&offset=${offset}&type=0`, {
    headers: {
      'user-agent': UA_APP,
      referer: 'https://live.douyin.com/',
      accept: 'application/json, text/plain, */*',
    },
  });
  const text = await r.text();
  return {
    status: r.status,
    len: text.length,
    ms: Date.now() - t0,
    ct: r.headers.get('content-type'),
    body: text,
  };
}

console.log('=== vf_dy_feed: 匿名 webcast/feed 实测 ===');
console.log(`count=${COUNT} batches=${BATCHES} maxtry=${MAXTRY}`);
console.log('UA =', UA_APP.slice(0, 42) + '…');
console.log('Cookie: (none)  Signature: (none)');
console.log('');

const attempts = [];
const allRooms = [];
for (let b = 0; b < BATCHES; b++) {
  let got = null;
  for (let i = 1; i <= MAXTRY; i++) {
    const res = await feedOnce(COUNT, 0);
    attempts.push(res);
    const tag = `  try#${i}`;
    if (!res.body.trim()) {
      console.log(`${tag} HTTP=${res.status} len=0  (空 body) ${res.ms}ms`);
      await new Promise((s) => setTimeout(s, 300 * i));
      continue;
    }
    let json;
    try {
      json = JSON.parse(res.body);
    } catch (e) {
      console.log(`${tag} HTTP=${res.status} len=${res.len} JSON 解析失败: ${e.message}`);
      continue;
    }
    const n = Array.isArray(json.data) ? json.data.length : -1;
    console.log(
      `${tag} HTTP=${res.status} len=${res.len} status_code=${json.status_code}` +
        ` status_msg=${JSON.stringify(json.status_msg ?? null)} data[]=${n} ${res.ms}ms`,
    );
    got = json;
    break;
  }
  if (!got) {
    console.log(`  batch#${b + 1}: ${MAXTRY} 次全部空 body / 解析失败`);
    continue;
  }
  const data = Array.isArray(got.data) ? got.data : [];
  for (const e of data) {
    const rd = e?.data;
    if (rd && typeof rd === 'object') allRooms.push(rd);
  }
  if (b === 0) {
    fs.writeFileSync(RAW, JSON.stringify(fieldTree(got), null, 2), 'utf8');
  }
  console.log(`  batch#${b + 1} 累计房间=${allRooms.length}`);
  await new Promise((s) => setTimeout(s, 500));
}

const emptyCount = attempts.filter((a) => !a.body.trim()).length;
console.log('');
console.log('=== 汇总 ===');
console.log(`  请求次数: ${attempts.length}  空 body 次数: ${emptyCount}` +
  `  空 body 率: ${(100 * emptyCount / attempts.length).toFixed(1)}%`);
console.log(`  去重后房间数: ${new Set(allRooms.map((r) => r.id_str)).size}`);
console.log(`  脱敏响应树已写入: ${RAW}`);

// ── 顶层结构 ────────────────────────────────────────────────────
if (allRooms.length) {
  const r0 = allRooms[0];
  console.log('');
  console.log('=== 房间对象顶层 key（按字母）===');
  console.log('  ' + Object.keys(r0).sort().join(', '));
  console.log('');
  console.log('=== 第一个房间脱敏字段树 ===');
  console.log(JSON.stringify(fieldTree(r0), null, 2).slice(0, 12000));
}

// ── 字段可用性统计（决定 UI 能展示什么）────────────────────────
const boolField = (name, get) => {
  const vals = allRooms.map(get);
  const present = vals.filter((v) => v !== undefined && v !== null && v !== '').length;
  return `${name}: ${present}/${allRooms.length}`;
};
const pick = (o, p) => p.split('.').reduce((a, k) => (a == null ? a : a[k]), o);

console.log('');
console.log('=== 展示字段可用性（存在数/总数）===');
for (const line of [
  boolField('id_str', (r) => r.id_str),
  boolField('id (num-as-str)', (r) => r.id),
  boolField('web_rid', (r) => r.web_rid),
  boolField('title', (r) => r.title),
  boolField('status', (r) => r.status),
  boolField('status_name', (r) => r.status_name),
  boolField('room_status', (r) => r.room_status),
  boolField('live_type', (r) => r.live_type),
  boolField('category', (r) => r.category),
  boolField('category_name', (r) => r.category_name),
  boolField('user_count', (r) => r.user_count),
  boolField('stats.total_user', (r) => pick(r, 'stats.total_user')),
  boolField('stats.display_concurrent_user_count(stat_display)', (r) => pick(r, 'stats.display_concurrent_user_count')),
  boolField('stats.user_count(text)', (r) => pick(r, 'stats.user_count')),
  boolField('popularity', (r) => r.popularity),
  boolField('cover.url_list[0]', (r) => pick(r, 'cover.url_list.0')),
  boolField('owner.nickname', (r) => pick(r, 'owner.nickname')),
  boolField('owner.avatar_thumb.url_list[0]', (r) => pick(r, 'owner.avatar_thumb.url_list.0')),
  boolField('owner.id_str', (r) => pick(r, 'owner.id_str')),
  boolField('owner.sec_uid', (r) => pick(r, 'owner.sec_uid')),
  boolField('stream_url.hls_pull_url', (r) => pick(r, 'stream_url.hls_pull_url')),
  boolField('stream_url.hls_pull_url_map', (r) => {
    const m = pick(r, 'stream_url.hls_pull_url_map');
    return m && Object.keys(m).length ? 'yes' : null;
  }),
  boolField('stream_url.flv_pull_url', (r) => {
    const m = pick(r, 'stream_url.flv_pull_url');
    return m && Object.keys(m).length ? 'yes' : null;
  }),
  boolField('owner.live_plan / live_play', (r) => pick(r, 'owner.live_plan') ?? pick(r, 'live_play')),
  boolField('linkmic_info', (r) => r.linkmic_info),
  boolField('dynamic_cover', (r) => r.dynamic_cover),
  boolField('vertical_cover', (r) => r.vertical_cover),
  boolField('landscape', (r) => r.landscape),
  boolField('with_draw_something', (r) => r.with_draw_something),
  boolField('danmaku_detail', (r) => r.danmaku_detail),
  boolField('anchor / anchors', (r) => r.anchor ?? (Array.isArray(r.anchors) ? 'anchors[]' : null)),
]) console.log('  ' + line);

// ── status / user_count 口径 ────────────────────────────────────
console.log('');
console.log('=== status 分布 ===');
const st = {};
for (const r of allRooms) st[String(r.status)] = (st[String(r.status)] ?? 0) + 1;
console.log('  ' + JSON.stringify(st));
console.log('=== 逐房间摘要（观看人数字段逐个对比）===');
for (const r of allRooms) {
  const hm = pick(r, 'stream_url.hls_pull_url_map') ?? {};
  const fm = pick(r, 'stream_url.flv_pull_url') ?? {};
  console.log(
    `  ${r.id_str} st=${r.status} cat=${r.category}` +
      ` user_count=${r.user_count}` +
      ` stats.user_count=${JSON.stringify(pick(r, 'stats.user_count') ?? null)}` +
      ` stats.total_user=${pick(r, 'stats.total_user')}` +
      ` disp=${JSON.stringify(pick(r, 'stats.display_concurrent_user_count') ?? null)}` +
      ` hls=[${Object.keys(hm).join('|')}] flv=[${Object.keys(fm).join('|')}]` +
      ` title=${JSON.stringify((r.title ?? '').slice(0, 22))}`,
  );
}

// ── 导出播放地址给下游探针 ──────────────────────────────────────
const exportRooms = allRooms.map((r) => {
  const hm = pick(r, 'stream_url.hls_pull_url_map') ?? {};
  const fm = pick(r, 'stream_url.flv_pull_url') ?? {};
  return {
    roomId: r.id_str,
    webRid: r.web_rid ?? null,
    title: r.title ?? null,
    status: r.status,
    statusName: r.status_name ?? null,
    category: r.category ?? null,
    userCount: r.user_count ?? null,
    statsUserCount: pick(r, 'stats.user_count') ?? null,
    statsTotalUser: pick(r, 'stats.total_user') ?? null,
    statsDisplay: pick(r, 'stats.display_concurrent_user_count') ?? null,
    nickname: pick(r, 'owner.nickname') ?? null,
    faceUrl: pick(r, 'owner.avatar_thumb.url_list.0') ?? null,
    coverUrl: pick(r, 'cover.url_list.0') ?? null,
    uid: pick(r, 'owner.id_str') ?? pick(r, 'owner.id') ?? null,
    hlsMaster: pick(r, 'stream_url.hls_pull_url') ?? null,
    hlsMap: hm,
    flvMap: fm,
    defaultResolution: pick(r, 'stream_url.default_resolution') ?? null,
    candidateResolution: pick(r, 'stream_url.candidate_resolution') ?? null,
    streamOrientation: pick(r, 'stream_url.stream_orientation') ?? null,
    coverUrlList: pick(r, 'cover.url_list') ?? null,
    verticalCover: pick(r, 'vertical_cover') ?? null,
    dynamicCover: pick(r, 'dynamic_cover') ?? null,
  };
});
fs.writeFileSync(OUT, JSON.stringify({ at: new Date().toISOString(), rooms: exportRooms }, null, 2), 'utf8');
console.log('');
console.log(`=== 播放地址清单已写入 ${OUT} (${exportRooms.length} 房间) ===`);
