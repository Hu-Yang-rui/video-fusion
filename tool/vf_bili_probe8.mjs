// 第八轮：定位真实的"删除收藏夹"端点并清理 VF_PROBE_TMP* 残留。
// 步骤：1) 正确提取 B站 SPA 的 script src（含协议相对 // 与 //s1.hdslb.com）
//       2) 下载 bundle，grep fav/folder 路径与参数名
//       3) 只对 VF_PROBE_TMP* 这两个显式 media_id 穷举删夹参数形态（绝不碰真实 6 夹）
// 输出脱敏；不写仓库（结果落 D:/vf-local）。
import fs from 'node:fs';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID'), csrf = pick('bili_jct');
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const redact = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));
const sleep = (ms = 500) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: '*/*' };
const API = 'https://api.bilibili.com';

log('=== 1. 提取 SPA script src（含协议相对 URL）===');
const pages = [
  `https://space.bilibili.com/${uid}/favlist`,
  `https://www.bilibili.com/video/BV16GJv6SEeE/`,
];
const urls = new Set();
for (const p of pages) {
  const r = await fetch(p, { headers: { 'user-agent': UA, cookie: COOKIE, accept: 'text/html,application/xhtml+xml' } });
  const t = await r.text();
  log(`${p} → HTTP=${r.status} len=${t.length}`);
  for (const m of t.matchAll(/(?:src|href)=["']([^"']+?\.js)["']/g)) {
    let u = m[1];
    if (u.startsWith('//')) u = 'https:' + u;
    else if (u.startsWith('/')) u = new URL(u, p).href;
    urls.add(u);
  }
  for (const m of t.matchAll(/https?:\/\/[^"'\\\s<>]+?\.js/g)) urls.add(m[0]);
  // 内联脚本里也可能直接有 api 路径
  for (const m of t.matchAll(/\/x\/[a-z0-9_\-\/]+/gi)) urls.add('inline:' + m[0]);
}
const bundles = [...urls].filter((u) => !u.startsWith('inline:'));
const inlineHits = [...new Set([...urls].filter((u) => u.startsWith('inline:')).map((u) => u.slice(7)))];
log(`bundle 数=${bundles.length}；页面内联出现的 /x/ 路径=${inlineHits.slice(0, 25).join(' ') || '无'}`);
for (const b of bundles) log('   ' + b.slice(0, 120));

log('\n=== 2. 下载 bundle 并 grep fav/folder 端点 ===');
const found = new Map();
for (const b of bundles) {
  if (/hdslb|bilibili/.test(b) === false) continue;
  try {
    const r = await fetch(b, { headers: { 'user-agent': UA, referer: 'https://space.bilibili.com/' } });
    const t = await r.text();
    let n = 0;
    for (const m of t.matchAll(/["'](\/x\/[a-zA-Z0-9_\-\/{}$.]+)["']/g)) {
      const p = m[1];
      if (!/fav|relation|history|coin|like/i.test(p)) continue;
      found.set(p, (found.get(p) || 0) + 1);
      n++;
    }
    for (const m of t.matchAll(/(media_id|folder_id|del_media_ids|add_media_ids|recursion_ids|up_mid|fav_key|folder)\s*:/g)) {
      found.set('param:' + m[1], (found.get('param:' + m[1]) || 0) + 1);
    }
    log(`  ${b.slice(-72)} HTTP=${r.status} len=${t.length} 命中=${n}`);
  } catch (e) {
    log(`  ${b.slice(-60)} ERR ${e.message}`);
  }
}
const eps = [...found.keys()].filter((k) => !k.startsWith('param:')).sort();
log(`\n端点候选(${eps.length}):`);
for (const e of eps) log('  ' + e + ` (x${found.get(e)})`);
log(`参数候选: ${[...found.keys()].filter((k) => k.startsWith('param:')).join(', ')}`);
fs.writeFileSync('D:/vf-local/probe8_bundle.txt', redact(eps.join('\n') + '\n' + [...found.keys()].join('\n')));

log('\n=== 3. 删夹端点/参数穷举（仅 VF_PROBE_TMP*）===');
const listAll = async () => {
  const r = await fetch(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`, { headers: H });
  return ((await r.json()).data?.list) || [];
};
const POST = async (p, body, query) => {
  const url = `${API}${p}${query ? '?' + new URLSearchParams(query) : ''}`;
  const r = await fetch(url, {
    method: 'POST',
    headers: { ...H, origin: 'https://space.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { code: 'HTML', msg: t.slice(0, 26) }; }
  return { http: r.status, j };
};
const JSONPOST = async (p, obj, query) => {
  const r = await fetch(`${API}${p}${query ? '?' + new URLSearchParams(query) : ''}`, {
    method: 'POST',
    headers: { ...H, origin: 'https://space.bilibili.com', 'content-type': 'application/json' },
    body: JSON.stringify(obj),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { code: 'HTML', msg: t.slice(0, 26) }; }
  return { http: r.status, j };
};
const tmpOf = async () => (await listAll()).filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));

const paths = [...new Set(['/x/v3/fav/folder/del', '/x/v3/fav/folder/cur/del', ...eps.filter((e) => /folder.*(del|delete|remove|dest|upd)/i.test(e))])];
const id0 = (await tmpOf())[0];
if (!id0) {
  log('  无残留，跳过');
} else {
  log(`  目标夹 id=${id0.id} fid=${id0.fid} attr=${id0.attr} mid=${id0.mid}`);
  const forms = [];
  for (const p of paths) {
    forms.push([`${p} form{media_id,csrf}`, () => POST(p, { media_id: String(id0.id), csrf })]);
    forms.push([`${p} form{media_id,csrf,platform,type}`, () => POST(p, { media_id: String(id0.id), csrf, platform: 'web', type: '11' })]);
    forms.push([`${p} form{media_ids,csrf}`, () => POST(p, { media_ids: String(id0.id), csrf })]);
    forms.push([`${p} form{media_id,csrf,biz_name}`, () => POST(p, { media_id: String(id0.id), csrf, biz_name: 'ugc-space' })]);
    forms.push([`${p} form{fid,csrf}`, () => POST(p, { fid: String(id0.fid), csrf })]);
    forms.push([`${p} form{media_id,csrf,recursion_ids}`, () => POST(p, { media_id: String(id0.id), csrf, recursion_ids: JSON.stringify([id0.id]) })]);
    forms.push([`${p} query{media_id,platform}+csrf`, () => POST(p, { csrf }, { media_id: String(id0.id), platform: 'web' })]);
    forms.push([`${p} json{media_id,csrf}`, () => JSONPOST(p, { media_id: id0.id, csrf })]);
  }
  let done = null;
  for (const [label, fn] of forms) {
    const left = await tmpOf();
    if (!left.length) break;
    const r = await fn();
    const code = r.j.code;
    log(`  ${code === 0 ? '✔' : ' '} ${label} → HTTP=${r.http} code=${code} msg=${redact(r.j.message ?? r.j.msg ?? '')}`);
    if (code === 0) {
      await sleep(900);
      if (!(await tmpOf()).length) { done = label; break; }
      log('      code=0 但夹未消失（又一个假成功）');
    }
    if (r.http === 404 || code === -400 || code === 'HTML') continue;
  }
  log(`\n  可用删除方式：${done || '★仍未找到'}`);
}
const fin = await listAll();
log(`  当前夹数=${fin.length} VF_PROBE_TMP* 残留=${(await tmpOf()).map((f) => f.id + '/' + f.title).join(',') || '无'}`);
log(`  真实 6 夹 media_count: ${fin.filter((f) => !String(f.title).startsWith('VF_PROBE_TMP')).map((f) => `${f.title}=${f.media_count}`).join(' ')}`);
