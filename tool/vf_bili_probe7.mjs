// 从 B站 前端资源里挖真实的收藏夹端点名（纯静态 GET，无鉴权、无写入）。
// 思路：抓 space 收藏夹页面 HTML → 提取 js bundle → grep "/x/v3/fav/..." 字面量。
// 目的：确定 删除夹 / 新建夹 / 改夹 的准确 path 与参数名，解决 VF_PROBE_TMP* 清理问题。
import fs from 'node:fs';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID');
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const redact = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: '*/*' };

const pages = [
  `https://space.bilibili.com/${uid}/favlist`,
  `https://www.bilibili.com/blackboard/activity-HcVF9JvoUT.html`,
  `https://account.bilibili.com/account/home`,
];
const bundles = new Set();
for (const p of pages) {
  try {
    const r = await fetch(p, { headers: { 'user-agent': UA, cookie: COOKIE, accept: 'text/html' } });
    const t = await r.text();
    log(`${p} → HTTP ${r.status} len=${t.length}`);
    for (const m of t.matchAll(/https:\/\/[^"'\\ ]+?\.js/g)) bundles.add(m[0]);
  } catch (e) {
    log(`${p} ERR ${e.message}`);
  }
}
log(`候选 bundle 数=${bundles.size}`);
// 优先抓与 fav / space 相关的包
const ranked = [...bundles].sort((a, b) => {
  const s = (x) => (/fav|space|media|video/i.test(x) ? 0 : 1);
  return s(a) - s(b) || a.length - b.length;
});
const hits = new Map();
const tryFetch = async (u) => {
  try {
    const r = await fetch(u, { headers: { 'user-agent': UA, referer: 'https://space.bilibili.com/' } });
    if (!r.ok) return;
    const t = await r.text();
    let n = 0;
    for (const m of t.matchAll(/\/x\/[a-z0-9_\-\/]*(fav|relation|history|coin|toview)[a-z0-9_\-\/]*/gi)) {
      const k = m[0];
      hits.set(k, (hits.get(k) || 0) + 1);
      n++;
    }
    for (const m of t.matchAll(/["'](add_media_ids|del_media_ids|media_id|folder_id|recursion_ids|up_mid|bvid|platform|public|privacy|intro|cover|title|csrf|_csrf)["']/g)) {
      const k = `param:${m[1]}`;
      hits.set(k, (hits.get(k) || 0) + 1);
    }
    log(`  ${u.slice(0, 96)} len=${t.length} 端点匹配=${n}`);
  } catch (e) {
    log(`  ${u.slice(0, 80)} ERR ${e.message}`);
  }
};
for (const u of ranked.slice(0, 14)) await tryFetch(u);
const api = [...hits.keys()].filter((k) => !k.startsWith('param:')).sort();
log(`\n=== bundle 中出现的 fav/relation/history/coin 端点 ===`);
for (const k of api) log(`  ${k}  (x${hits.get(k)})`);
const ps = [...hits.keys()].filter((k) => k.startsWith('param:')).map((k) => k.slice(6));
log(`\n出现过的参数名: ${ps.join(', ')}`);
fs.writeFileSync('D:/vf-local/probe7_endpoints.txt', redact(api.join('\n') + '\nPARAMS:' + ps.join(',')));
log('(结果存到仓库外 D:/vf-local/probe7_endpoints.txt)');
