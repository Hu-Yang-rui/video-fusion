// 第十一轮：三个语义定论 + 批量归属接口挖掘。
//  A. fav_state 到底是什么：拿 collected/list 里【我确实收藏过的别人的夹】查 folder/info，
//     若 fav_state=1 而自己的夹恒 0 → 定论 fav_state = "我是否收藏了这个收藏夹"，与视频归属无关。
//  B. attr 位语义 + 公开/私密：用 bundle 反解出的真实建夹参数 privacy，
//     建 3 个临时夹（privacy=true / privacy=false / 老写法 public），
//     读回 attr 并做【匿名可读性】交叉验证，然后立刻用已验证的 media_ids 删除。
//  C. /x/v3/fav/resource/ids 返回 -400（端点存在、参数不对）→ 穷举参数，找"一次问多个夹归属"的批量接口。
//  D. 视频页收藏面板用的真实端点：从 video 页 HTML + core.js 动态 chunk 里挖 /x/v3/fav 字面量。
// 输出全程 redact；写操作仅限 VF_ATTR_* 临时夹且当场删除。
import fs from 'node:fs';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID'), csrf = pick('bili_jct');
const API = 'https://api.bilibili.com';
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const redact = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));
const J = (v, n = 190) => redact(JSON.stringify(v)).slice(0, n);
const sleep = (ms = 700) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://space.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };
const GETj = async (p, h = H) => {
  const r = await fetch(`${API}${p}`, { headers: h });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 30) }; }
  return { http: r.status, j };
};
const POSTj = async (p, body) => {
  const r = await fetch(`${API}${p}`, {
    method: 'POST',
    headers: { ...H, origin: 'https://space.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 30) }; }
  return { http: r.status, j };
};
const listAll = async () => (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j.data?.list) || []);
const bits = (n) => (n === undefined ? 'n/a' : `${n}=0b${(n >>> 0).toString(2)}[${Array.from({ length: 12 }, (_, i) => (n & (1 << i) ? 1 << i : 0)).filter(Boolean).join('+')}]`);

const baseFolders = await listAll();
log(`基准夹数=${baseFolders.length} ${baseFolders.map((f) => `${f.id}:${f.title}(${bits(f.attr)})`).join(' ')}`);

log('\n=== A. fav_state 语义定论（零写入判别）===');
const col = (await GETj(`/x/v3/fav/folder/collected/list?pn=1&ps=20&up_mid=${uid}&platform=web`)).j;
const others = col.data?.list || [];
log(`  collected/list: code=${col.code} count=${col.data?.count} 条数=${others.length}`);
for (const f of others.slice(0, 5)) {
  const inf = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`)).j;
  log(`  [别人的夹] ${f.id} "${f.title}" upper.mid=${f.upper?.mid} attr=${f.attr}(${f.attr_desc ?? ''}) info.fav_state=${inf.data?.fav_state} info.like_state=${inf.data?.like_state} info.attr=${inf.data?.attr}`);
}
log(`  ——— 对比自己创建的夹 ———`);
for (const f of baseFolders.slice(0, 3)) {
  const inf = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`)).j;
  log(`  [自建夹] ${f.id} "${f.title}" info.fav_state=${inf.data?.fav_state} like_state=${inf.data?.like_state} cnt_info.collect=${inf.data?.cnt_info?.collect}`);
}
log(`  ★ 判别：若别人的夹 fav_state=1 而自建夹恒 0 → fav_state = 我是否收藏/订阅了【这个收藏夹】`);
log(`  ★ 与"该视频在此夹"无关，面板勾选态不可用它（bvid 参数只是让服务端顺带返回该字段）`);
const rel = (await GETj(`/x/web-interface/archive/relation?bvid=BV1ySJx6YETj`)).j;
log(`  对照：视频 BV1ySJx6YETj（在 gay 夹内）archive/relation.favorite=${rel.data?.favorite} season_fav=${rel.data?.season_fav}（布尔总态，实测可靠）`);

log('\n=== B. attr 位语义 + 公开/私密（建 3 临时夹 → 读 attr → 匿名可读性 → 立即删除）===');
const mk = async (title, extra) => {
  const r = await POSTj('/x/v3/fav/folder/add', { title, intro: 'probe', ...extra, csrf });
  log(`  add "${title}" 参数=${JSON.stringify(extra)} → code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')} data.attr=${r.j.data?.attr} data.id=${r.j.data?.id}`);
  return r.j;
};
const made = [];
const m1 = await mk('VF_ATTR_PUB', { privacy: 'true' }); made.push(m1.data?.id);
await sleep(900);
const m2 = await mk('VF_ATTR_PRIV', { privacy: 'false' }); made.push(m2.data?.id);
await sleep(900);
const m3 = await mk('VF_ATTR_DEF', {}); made.push(m3.data?.id);
await sleep(1200);
const now = await listAll();
const tmps = now.filter((f) => String(f.title).startsWith('VF_ATTR_'));
log(`  list-all 回读：`);
for (const f of tmps) log(`    ${f.id} "${f.title}" attr=${bits(f.attr)} media_count=${f.media_count}`);
log(`  真实夹 attr 参照：`);
for (const f of now.filter((x) => !String(x.title).startsWith('VF_ATTR_'))) log(`    ${f.id} "${f.title}" attr=${bits(f.attr)}`);
// 把已知视频放进"公开"和"私密"临时夹，再用匿名请求验证可读性
if (tmps.length >= 2) {
  const pub = tmps.find((f) => /PUB$/.test(f.title)) || tmps[0];
  const prv = tmps.find((f) => /PRIV$/.test(f.title)) || tmps[1];
  for (const f of [pub, prv]) {
    const d = await POSTj('/x/v3/fav/resource/deal', { rid: '116745046065481', type: '2', add_media_ids: String(f.id), del_media_ids: '', csrf });
    log(`  放入 ${f.title}: code=${d.j.code}`);
    await sleep(800);
  }
  await sleep(1200);
  for (const f of [pub, prv]) {
    const auth = (await GETj(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`)).j;
    const anon = (await GETj(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`, HN)).j;
    const infoA = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`, HN)).j;
    log(`  ${f.title} attr=${bits((await listAll()).find((x) => x.id === f.id)?.attr)}: 登录resource/list 条数=${(auth.data?.medias || []).length} | 匿名 resource/list code=${anon.code} 条数=${(anon.data?.medias || []).length} | 匿名 folder/info code=${infoA.code} attr=${infoA.data?.attr} visibility=${infoA.data?.visibility}`);
  }
  // 真实 6 夹的匿名可读性对照（公开/私密判据的 ground truth）
  log(`  真实夹匿名对照：`);
  for (const f of (await listAll()).filter((x) => !String(x.title).startsWith('VF_ATTR_'))) {
    const anon = (await GETj(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`, HN)).j;
    const ainfo = (await GETj(`/x/v3/fav/folder/info?media_id=${f.id}&platform=web`, HN)).j;
    log(`    "${f.title}" attr=${bits(f.attr)}: 匿名 list code=${anon.code} 条数=${(anon.data?.medias || []).length} info_count=${anon.data?.info?.media_count} | 匿名 folder/info code=${ainfo.code} attr=${ainfo.data?.attr}`);
  }
}
log(`  删除临时夹（已验证方式：media_ids + csrf）：`);
for (const f of tmps) {
  const d = await POSTj('/x/v3/fav/resource/deal', { rid: '116745046065481', type: '2', add_media_ids: '', del_media_ids: String(f.id), csrf });
  log(`    先移出内容 ${f.id}: code=${d.j.code}`);
  await sleep(600);
  const r = await POSTj('/x/v3/fav/folder/del', { media_ids: String(f.id), csrf });
  log(`    folder/del media_ids=${f.id} "${f.title}": code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')}`);
  await sleep(900);
}
const afterDel = await listAll();
log(`  ★ 删后夹数=${afterDel.length}（应 ${baseFolders.length}）残留 VF_ATTR_*=${afterDel.filter((f) => String(f.title).startsWith('VF_ATTR_')).length}（应 0）`);

log('\n=== C. 批量归属接口穷举（/x/v3/fav/resource/ids 存在但 -400）===');
const ids = baseFolders.map((f) => f.id);
const rid = '116745046065481';
for (const q of [
  `rid=${rid}`, `rid=${rid}&type=2`, `rid=${rid}&type=2&media_ids=${ids.join(',')}`,
  `rid=${rid}&media_ids=${ids.join(',')}`, `rids=${rid}&type=2`,
  `resource_ids=${rid}&type=2`, `ids=${rid}`, `ids=${rid}&type=2&media_ids=${ids.join(',')}`,
  `media_id=${ids[0]}&rid=${rid}&type=2`, `rid=${rid}&type=2&platform=web&media_ids=${ids.join(',')}`,
  `bvid=BV1ySJx6YETj&type=2&media_ids=${ids.join(',')}`, `rid=${rid}&type=2&up_mid=${uid}&media_ids=${ids.join(',')}`,
]) {
  const a = await GETj('/x/v3/fav/resource/ids?' + q);
  const b = await POSTj('/x/v3/fav/resource/ids', Object.fromEntries(new URLSearchParams(q)));
  if (a.j.code !== -400 || b.j.code !== -400)
    log(`  ${q.slice(0, 74)}\n      GET code=${a.j.code} msg=${redact(a.j.message ?? a.j.body ?? '')} data=${J(a.j.data, 150)} | POST code=${b.j.code} msg=${redact(b.j.message ?? b.j.body ?? '')} data=${J(b.j.data, 150)}`);
  await sleep(120);
}
log(`  （仅打印非 -400 的组合；全部 -400 表示该端点参数结构不可用，放弃批量方案）`);
// list4navigate 完整结构（可能一次返回所有夹 + 归属）
const nav4 = (await GETj(`/x/v3/fav/folder/list4navigate?up_mid=${uid}&platform=web&type=0&bvid=BV1ySJx6YETj`)).j;
log(`  list4navigate: code=${nav4.code} 顶层=${J(nav4.data, 90)}`);
for (const g of nav4.data || [])
  log(`    group "${g.name}" id=${g.id} 键=${Object.keys(g).join(',')} mediaListResponse=${J(g.mediaListResponse, 130)}`);
const lr = (await GETj(`/x/v3/fav/folder/created/list?up_mid=${uid}&pn=1&ps=20&bvid=BV1ySJx6YETj`)).j;
log(`  created/list(带bvid): code=${lr.code} count=${lr.data?.count} 首项键=${Object.keys(lr.data?.list?.[0] || {}).join(',')} attr_desc=${J((lr.data?.list || []).map((x) => x.attr_desc), 80)}`);
log(`  → created/list 是否含 fav_state=${'fav_state' in (lr.data?.list?.[0] || {})}；attr_desc 提供了 attr 的官方文字描述`);

log('\n=== D. 视频页收藏面板真实端点（挖 chunk）===');
const page = await (await fetch('https://www.bilibili.com/video/BV1ySJx6YETj/', { headers: { 'user-agent': UA, cookie: COOKIE, accept: 'text/html' } })).text();
const jsu = new Set();
for (const m of page.matchAll(/["']((?:https:|http:)?(?:\/\/|\\u002F\\u002F)[^"'\\]+?\.js(?:\\u002F|\/)[^"'\\]*)["']/g)) jsu.add(m[1]);
for (const m of page.matchAll(/(?:src|href)=["']([^"']+?\.js)["']/g)) {
  let u = m[1];
  if (u.startsWith('//')) u = 'https:' + u; else if (u.startsWith('/')) u = new URL(u, 'https://www.bilibili.com').href;
  jsu.add(u);
}
const clean = [...jsu].map((u) => u.replace(/\\u002F/g, '/')).filter((u) => /^https?:\/\//.test(u));
log(`  video 页 js 候选=${clean.length}`);
const ep = new Map();
const scan = (t, srcTag) => {
  for (const m of t.matchAll(/["'](\/x\/[a-zA-Z0-9_\-\/]+)["']/g)) {
    if (!/fav|relation|coin|like/i.test(m[1])) continue;
    ep.set(m[1], (ep.get(m[1]) || 0) + 1);
  }
  for (const m of t.matchAll(/\/x\/v3\/fav\/[a-zA-Z0-9_\-\/${}.]+/g)) ep.set(m[0], (ep.get(m[0]) || 0) + 1);
  return t;
};
for (const u of clean.slice(0, 10)) {
  try {
    const r = await fetch(u, { headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' } });
    const t = await r.text();
    scan(t, u);
    // 动态 chunk：从 bundle 里找相对路径片段
    const chunks = new Set();
    for (const m of t.matchAll(/["']([\w\-./]+?\.js)["']/g)) chunks.add(m[1]);
    log(`    ${u.slice(-64)} len=${t.length} 累计端点=${ep.size}`);
    if (/player\/main\/core/.test(u)) {
      const base = u.slice(0, u.lastIndexOf('/') + 1);
      const cand = [...chunks].filter((c) => /fav|popup|collect|share|action/i.test(c)).slice(0, 8);
      for (const c of cand) {
        try {
          const rr = await fetch(base + c, { headers: { 'user-agent': UA } });
          if (!rr.ok) continue;
          const tt = await rr.text();
          scan(tt, c);
          log(`      chunk ${c} len=${tt.length}`);
        } catch {}
      }
    }
  } catch (e) { log(`    ${u.slice(-50)} ERR ${e.message}`); }
}
const fav = [...ep.keys()].filter((k) => /fav/i.test(k)).sort();
log(`  挖到的 fav 端点(${fav.length}):`);
for (const k of fav) log(`    ${k} (x${ep.get(k)})`);
fs.writeFileSync('D:/vf-local/probe11_fav_eps.txt', redact(fav.join('\n')));

log('\n=== E. 状态核对 ===');
const fin = await listAll();
const exp = (await GETj('/x/member/web/exp/reward')).j;
const tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
const rlSt = (await GETj('/x/relation?fid=3546661399824534&ptype=1')).j;
const gayState = await GETj(`/x/v3/fav/resource/list?media_id=4020481152&pn=1&ps=20&platform=web`).then((r) => (r.j.data?.medias || []).length);
log(`  夹数=${fin.length}（基准 ${baseFolders.length}）| VF_ATTR_*残留=${fin.filter((f) => String(f.title).startsWith('VF_ATTR_')).length} | VF_PROBE_TMP残留=${fin.filter((f) => String(f.title).startsWith('VF_PROBE_TMP')).length}`);
log(`  media_count: ${fin.map((f) => `${f.title}=${f.media_count}`).join(' ')}（gay 夹内实际条数=${gayState}）`);
log(`  coins=${exp.data?.coins}（应0）| toview.count=${tv.data?.count}（应0）| 关注attribute=${rlSt.data?.attribute}（应0）`);
const okAttr = fin.length === baseFolders.length && fin.every((f) => String(f.title).startsWith('VF_') === false);
log(`  账号状态已恢复：${okAttr && exp.data?.coins === 0 && tv.data?.count === 0 && rlSt.data?.attribute === 0 ? '是' : '★需核对：' + JSON.stringify({ n: fin.length, base: baseFolders.length })}`);
