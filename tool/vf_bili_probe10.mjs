// 第十轮：A) 从 fresh-space bundle 反解 attr→private 的判定函数 T、folder/fav 的参数名、
//            resource/list 的全部查询参数；B) 实测 ps 上限 / keyword 命中 / load_all / order；
//         C) 并发风控。全部只读 + 仅对临时夹的夹收藏（不落真实数据）。
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
const sleep = (ms = 500) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://space.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const GETj = async (p) => {
  const r = await fetch(`${API}${p}`, { headers: H });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 30) }; }
  return { http: r.status, j };
};

log('=== A. bundle 反解 ===');
const bt = await (await fetch('https://s1.hdslb.com/bfs/static/shanks/fresh-space/assets/index-76bd2e5f.js', { headers: { 'user-agent': UA } })).text();
log(`bundle len=${bt.length}`);
// A1 attr→private：找 `private:T(G.attr)` 的 T 定义 + 所有 attr 位运算
const grab = (re, n = 8, w = 200) => {
  const out = [];
  let m;
  const g = re instanceof RegExp ? new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g') : new RegExp(re, 'g');
  while ((m = g.exec(bt)) && out.length < n) out.push(m[0]);
  return out.map((s) => '    …' + redact(s.replace(/\s+/g, ' ')).slice(0, w * 2) + '…');
};
log('A1a attr 位运算片段：');
grab('attr\\s*&\\s*\\d+|&\\s*\\d+\\)\\s*\\?|1\\s*<<\\s*\\d+|\\d+\\s*<<\\s*\\d+|attr\\s*>>\\s*\\d+', 14, 120).forEach(log);
log('A1b private 判定（含 attr 的箭头函数）：');
grab('(?:const|function)\\s+\\w+\\s*=\\s*(?:\\([^)]*\\)\\s*=>|\\w+\\s*\\([^)]*\\)\\s*\\{)[^;]{0,140}attr[^;]{0,140}', 8, 200).forEach(log);
grab('[a-zA-Z_$][\\w$]*\\s*:\\s*T\\(G\\.attr\\)|private\\s*[:=][^,;]{0,90}attr[^,;]{0,90}', 8, 160).forEach(log);
log('A1c folder/fav 与 resource_type / biz_code：');
grab('/x/v3/fav/folder/(?:fav|unfav)[^"]*"\\)\\s*,?\\s*\\{?[^}]{0,180}', 6, 220).forEach(log);
grab('resource_type[^,;}]{0,40}|biz_code[^,;}]{0,60}', 14, 80).forEach(log);
log('A1d resource/list 查询参数：');
grab('resource/list[^"]*"[^)]{0,220}', 4, 260).forEach(log);
grab(/load_all[^,;}]{0,30}|with_current[^,;}]{0,30}|detail\s*:\s*[!]?(?:0|1|true|false)|order\s*:\s*["'][a-z]+/g, 18, 60).forEach(log);
log('A1e del 夹参数（media_ids vs media_id）：');
grab('folder/del[^"]*"[^)]{0,200}', 4, 220).forEach(log);
grab('media_ids[^,;})]{0,40}|media_id\\s*[:=][^,;})]{0,30}', 14, 70).forEach(log);
log('A1f 新建夹参数（public/private）：');
grab('folder/add[^"]*"[^)]{0,220}', 3, 240).forEach(log);
grab('["\\\']public["\\\']\\s*:\\s*[^,;}]{0,30}|privacy[^,;}]{0,30}', 10, 60).forEach(log);

log('\n=== B1. ps 上限实测（默认收藏夹 32 条 / 神人视频 145 条）===');
for (const [mid, name, total] of [[62851852, '默认收藏夹', 32], [3683371952, '神人视频', 145]]) {
  for (const ps of [20, 25, 30, 40, 50, 60, 80, 100, 150, 200]) {
    const r = await GETj(`/x/v3/fav/resource/list?media_id=${mid}&pn=1&ps=${ps}&platform=web`);
    const n = (r.j.data?.medias || []).length;
    log(`  ${name}(${total}) ps=${ps}: code=${r.j.code} 返回=${n} has_more=${r.j.data?.has_more} ttl=${r.j.data?.ttl}`);
    await sleep(120);
  }
  log('  ---');
}

log('\n=== B2. keyword 能否命中（决定"扫一个夹要几个请求"）===');
const samples = [
  ['BV1ySJx6YETj', 4020481152, 'gay(1)'],
  ['BV1EF2uBMEKU', 3683371952, '神人视频(145) 深页第8页的视频'],
];
for (const [bvid, mediaId, note] of samples) {
  const v = (await GETj(`/x/web-interface/view?bvid=${bvid}`, { ...H, referer: 'https://www.bilibili.com/' })).j;
  const title = String(v.data?.title || '');
  const kwTitle = encodeURIComponent(title.slice(0, 6));
  for (const [label, kw] of [['bvid 原文', encodeURIComponent(bvid)], ['标题前6字', kwTitle], ['标题全名', encodeURIComponent(title)], ['aid', String(v.data?.aid)]]) {
    const r = await GETj(`/x/v3/fav/resource/list?media_id=${mediaId}&pn=1&ps=20&platform=web&keyword=${kw}`);
    const list = r.j.data?.medias || [];
    log(`  ${note} ${label}: code=${r.j.code} 命中条数=${list.length} 含目标=${list.some((m) => (m.bvid || m.bv_id) === bvid)} 首条=${(list[0]?.bvid || list[0]?.bv_id) || '-'}`);
    await sleep(120);
  }
}

log('\n=== B3. 其它开关：load_all / with_current / detail / order / type ===');
for (const q of [
  'pn=1&ps=20&platform=web&load_all=true',
  'pn=1&ps=20&platform=web&load_all=1',
  'pn=1&ps=20&platform=web&with_current=false',
  'pn=1&ps=20&platform=web&detail=1',
  'pn=1&ps=20&platform=web&detail=0',
  'pn=1&ps=20&platform=web&order=mtime',
  'pn=1&ps=20&platform=web&order=addts',
  'pn=1&ps=20&platform=web&order=view',
  'pn=1&ps=20&platform=web&type=0',
  'pn=1&ps=20&platform=web&keyword=',
  'pn=999&ps=20&platform=web',
  'pn=0&ps=20&platform=web',
]) {
  const r = await GETj(`/x/v3/fav/resource/list?media_id=62851852&${q}`);
  const d = r.j.data || {};
  log(`  ${q.slice(0, 56)} → code=${r.j.code} 条数=${(d.medias || []).length} has_more=${d.has_more} ttl=${d.ttl} 首条=${(d.medias?.[0]?.bvid) || '-'}`);
  await sleep(140);
}
log('  pn 越界（判断翻到底）：');
for (const pn of [2, 3, 5, 10, 999]) {
  const r = await GETj(`/x/v3/fav/resource/list?media_id=62851852&pn=${pn}&ps=20&platform=web`);
  log(`    pn=${pn}（32 条 / ps=20 → 2 页）: code=${r.j.code} 条数=${(r.j.data?.medias || []).length} has_more=${r.j.data?.has_more}`);
  await sleep(120);
}

log('\n=== B4. medias[i] 用哪个字段判等最稳（bvid vs id/aid）===');
const rl = (await GETj('/x/v3/fav/resource/list?media_id=3683371952&pn=1&ps=20&platform=web')).j;
for (const m of (rl.data?.medias || []).slice(0, 3)) {
  log(`  id(aid)=${m.id} bvid=${m.bvid} bv_id=${m.bv_id} type=${m.type} attr=${m.attr} fav_time=${m.fav_time} duration=${m.duration} 相等=${String(m.bvid) === String(m.bv_id)}`);
  const v = (await GETj(`/x/web-interface/view?bvid=${m.bvid}`, { ...H, referer: 'https://www.bilibili.com/' })).j;
  log(`      view 反查 aid=${v.data?.aid} → 与 medias.id 一致=${String(v.data?.aid) === String(m.id)}`);
}

log('\n=== C. 并发风控（同 cookie 并行 6 个 resource/list）===');
const ids = [62851852, 4020481152, 3896864752, 3926837952, 3962862352, 3683371952];
const par = await Promise.all(
  ids.map((id) => GETj(`/x/v3/fav/resource/list?media_id=${id}&pn=1&ps=20&platform=web`))
);
par.forEach((r, i) => log(`  并发#${i + 1} media_id=${ids[i]}: HTTP=${r.http} code=${r.j.code} 条数=${(r.j.data?.medias || []).length} has_more=${r.j.data?.has_more}`));
log('  串行对照：');
const ser = [];
for (const id of ids) { ser.push(await GETj(`/x/v3/fav/resource/list?media_id=${id}&pn=1&ps=20&platform=web`)); await sleep(80); }
log(`  串行全部 code=${ser.map((r) => r.j.code).join(',')}`);
log('  并发 12 个（含重复夹，压一下）：');
const par12 = await Promise.all(Array.from({ length: 12 }, (_, i) => GETj(`/x/v3/fav/resource/list?media_id=${ids[i % 6]}&pn=1&ps=20&platform=web`)));
log(`  并发12 code=${[...new Set(par12.map((r) => r.j.code))].join(',')} HTTP=${[...new Set(par12.map((r) => r.http))].join(',')} 空响应=${par12.filter((r) => !(r.j.data?.medias || []).length).length}`);

log('\n=== D. 状态核对（本轮全部只读）===');
const fl = (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j.data?.list) || []);
const exp = (await GETj('/x/member/web/exp/reward')).j;
const tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
const rel = (await GETj('/x/relation?fid=3546661399824534&ptype=1')).j;
log(`  夹数=${fl.length}（应 6）残留 VF_PROBE_TMP=${fl.filter((f) => String(f.title).startsWith('VF_PROBE_TMP')).length}`);
log(`  media_count: ${fl.map((f) => `${f.title}=${f.media_count}`).join(' ')}`);
log(`  coins=${exp.data?.coins}（应0）| toview.count=${tv.data?.count}（应0）| attribute=${rel.data?.attribute}（应0）`);
log(`  账号状态已恢复：${fl.length === 6 && exp.data?.coins === 0 && tv.data?.count === 0 && rel.data?.attribute === 0 ? '是（本轮零写入）' : '★需核对'}`);
