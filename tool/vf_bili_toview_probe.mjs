// 「稍后再看」端点实测探针（授权测试小号，只做可逆写）。
//
// 目的：确定 fetchWatchLater 用哪个端点判存在性——
//   候选 A：GET /x/v2/history/toview/web        → data.count / data.list[].aid（需要全量比对）
//   候选 B：GET /x/v2/history/toview/aid?aid=   → 若可用，单条直查，成本恒定
// 以及写端点 /x/v2/history/toview/add|del 的真实响应码。
//
// 安全：绝不打印任何 cookie 值（redact 兜底）；写操作只在结尾恢复到初始态。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (
  process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')
).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID');
const csrf = pick('bili_jct');
const API = 'https://api.bilibili.com';

const secrets = [
  ...new Set(
    COOKIE.split(';')
      .map((s) => s.trim().split('=')[1])
      .filter((v) => v && v.length >= 4),
  ),
];
const redact = (s) => {
  let t = String(s);
  for (const v of secrets) t = t.split(v).join('<REDACTED>');
  return t;
};
const J = (v, n = 300) => redact(JSON.stringify(v)).slice(0, n);
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));

const H = {
  'user-agent': UA,
  referer: 'https://www.bilibili.com/',
  cookie: COOKIE,
  accept: 'application/json, text/plain, */*',
};

const get = async (path) => {
  const r = await fetch(`${API}${path}`, { headers: H });
  const t = await r.text();
  let j;
  try {
    j = JSON.parse(t);
  } catch {
    j = { __nonJson: t.slice(0, 120) };
  }
  return { status: r.status, json: j };
};

const post = async (path, bodyObj) => {
  const r = await fetch(`${API}${path}`, {
    method: 'POST',
    headers: { ...H, origin: 'https://www.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(bodyObj).toString(),
  });
  const t = await r.text();
  let j;
  try {
    j = JSON.parse(t);
  } catch {
    j = { __nonJson: t.slice(0, 120) };
  }
  return { status: r.status, json: j };
};

log('uid(len)', uid.length, 'csrf(len)', csrf.length);

// 取一个真实存在的 aid：从 view 接口拿一个公开 BV
const VIEW = await get('/x/web-interface/view?bvid=BV1GJ411x7h7');
const aid = VIEW.json?.data?.aid;
log('view code=', VIEW.json?.code, 'aid=', aid);
if (!aid) {
  log('无可用 aid，终止');
  process.exit(0);
}

// ── 候选 A：全量列表 ────────────────────────────────────────
const a = await get('/x/v2/history/toview/web?platform=web');
const list = a.json?.data?.list;
log('A toview/web        code=', a.json?.code, 'count=', a.json?.data?.count, 'listLen=', Array.isArray(list) ? list.length : typeof list);

// ── 候选 B：aid 直查 ───────────────────────────────────────
for (const p of [`/x/v2/history/toview/aid?aid=${aid}`, `/x/v2/history/toview/detail?aid=${aid}`]) {
  const r = await get(p);
  log('B', p.split('?')[0], 'http=', r.status, 'code=', r.json?.code, 'msg=', r.json?.message, 'dataKeys=', r.json?.data ? Object.keys(r.json.data).join(',').slice(0, 60) : 'null');
}

// ── 写端点：add 后再 del，恢复到初始态 ─────────────────────
const before = Array.isArray(list) ? list.some((x) => x.aid === aid) : false;
log('初始：该 aid 是否已在稍后再看 =', before);

if (!before) {
  const add = await post('/x/v2/history/toview/add', { aid: String(aid), csrf, platform: 'web' });
  log('POST toview/add    code=', add.json?.code, 'msg=', add.json?.message);

  const check = await get('/x/v2/history/toview/web?platform=web');
  const l2 = check.json?.data?.list;
  log('  add 后 list 命中 =', Array.isArray(l2) ? l2.some((x) => x.aid === aid) : false, 'count=', check.json?.data?.count);

  const del = await post('/x/v2/history/toview/del', {
    aids: JSON.stringify([aid]),
    csrf,
    platform: 'web',
  });
  log('POST toview/del(aids)      code=', del.json?.code, 'msg=', del.json?.message);

  const del2 = await post('/x/v2/history/toview/del', { aid: String(aid), csrf, platform: 'web' });
  log('POST toview/del(aid 单数)  code=', del2.json?.code, 'msg=', del2.json?.message);

  const after = await get('/x/v2/history/toview/web?platform=web');
  const l3 = after.json?.data?.list;
  log('  恢复后 list 命中 =', Array.isArray(l3) ? l3.some((x) => x.aid === aid) : false, 'count=', after.json?.data?.count);
} else {
  log('该 aid 本来就在列表里，跳过写入以免污染账号状态');
}
