// 判别实验：`created/list-all` 的 `fav_state` 到底表示什么？
//
// 背景：先前一条契约指令声称 "fav_state 非 0 = 该视频在此夹"，
// 后续纠偏声称 "fav_state 是收藏夹自身的状态（我是否收藏了这个夹），
// 对自建夹恒为 0"。两种语义会导致完全不同的归属实现，
// 因此这里做**判别实验**，而不是二选一照抄。
//
// 只做只读请求；不写入、不改账号状态。
// 输出全部经 redact()：绝不打印 cookie 值。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (
  process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')
).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID');
const API = 'https://api.bilibili.com';

const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const red = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const say = (t, o) => console.log(t + ' | ' + red(typeof o === 'string' ? o : JSON.stringify(o)));
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const get = async (p) => { const r = await fetch(`${API}${p}`, { headers: H }); return await r.json().catch(() => ({})); };

// ── 1. 不带 bvid 的夹列表：看每个夹自带哪些状态字段 ───────────
const base = await get(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`);
const list = base?.data?.list || [];
say('S1 无bvid 夹数=', list.length);
for (const f of list) {
  say('  folder', { id: f.id, title: f.title, media_count: f.media_count, attr: f.attr, fav_state: f.fav_state, like_state: f.like_state, upper_mid: f.upper?.mid });
}

// ── 2. 找一个"确定含某视频"的夹：取 media_count 最小的非空夹 ──
const small = list.filter((f) => (f.media_count ?? 0) > 0).sort((a, b) => a.media_count - b.media_count)[0];
if (!small) { say('S2 无可用夹，终止'); process.exit(0); }
const rl = await get(`/x/v3/fav/resource/list?media_id=${small.id}&pn=1&ps=20&platform=web`);
const medias = rl?.data?.medias || [];
const target = medias[0];
say('S2 选定夹', { id: small.id, title: small.title, media_count: small.media_count, hitLen: medias.length });
say('  首条', { id: target?.id, bvid: target?.bvid, type: target?.type, title: String(target?.title).slice(0, 20), fav_time: target?.fav_time });
say('  resource/list data keys=', Object.keys(rl?.data || {}).join(','));
say('  has_more=', rl?.data?.has_more, 'info.totals=', rl?.data?.info?.totals);

const bvid = target?.bvid;
const aid = target?.id;

// ── 3. 判别：带 bvid 后，**这个确定包含它的夹** fav_state 是否变非 0 ──
const withBvid = await get(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${bvid}&platform=web`);
const wl = withBvid?.data?.list || [];
const same = wl.find((f) => f.id === small.id);
say('S3 带bvid 目标夹', { id: same?.id, title: same?.title, fav_state: same?.fav_state, like_state: same?.like_state });
say('  全部夹 fav_state=', wl.map((f) => `${f.title}:${f.fav_state}`).join(','));

// 换 aid 参数再试一次（若 bvid 被忽略而 aid 生效，也能看出来）
const withAid = await get(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${aid}&platform=web`);
say('  用 aid 当 bvid 传', { targetFavState: (withAid?.data?.list || []).find((f) => f.id === small.id)?.fav_state });

// ── 4. 结论判定 ───────────────────────────────────────────
const isInFolder = medias.some((m) => m.bvid === bvid);
const verdict = same?.fav_state !== 0 && same?.fav_state !== undefined
  ? (isInFolder ? 'fav_state 非0 且确实在夹内 → 支持"归属"语义' : '矛盾')
  : 'fav_state 在"确定在夹内"时仍为 0 → 不支持"归属"语义，须用 resource/list 扫描';
say('VERDICT', verdict);

// ── 5. 附带确认 archive/relation 的字段类型（收藏修复依赖） ──
const rel = await get(`/x/web-interface/archive/relation?bvid=${bvid}`);
say('S5 relation code=', rel?.code);
say('  data=', rel?.data);
say('  types=', Object.fromEntries(Object.entries(rel?.data || {}).map(([k, v]) => [k, typeof v])));
