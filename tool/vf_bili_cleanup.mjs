// 紧急清理 + 删除收藏夹端点发现：只针对 VF_PROBE_TMP* 这两个临时夹（显式 media_id），
// 逐个尝试参数形态，命中后立刻用 list-all 复查，绝不对真实夹（62851852/4020481152/
// 3896864752/3926837952/3962862352/3683371952）发起任何删除。
import fs from 'node:fs';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE || fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const pick = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = pick('DedeUserID'), csrf = pick('bili_jct');
const API = 'https://api.bilibili.com';
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const secrets = [...new Set(COOKIE.split(';').map((s) => s.trim().split('=')[1]).filter((v) => v && v.length >= 4))];
const redact = (s) => { let t = String(s); for (const v of secrets) t = t.split(v).join('<REDACTED>'); return t; };
const log = (...a) => console.log(...a.map((x) => (typeof x === 'string' ? redact(x) : String(x))));
const sleep = (ms = 700) => new Promise((r) => setTimeout(r, ms));
const listAll = async () => {
  const r = await fetch(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`, { headers: H });
  const j = await r.json();
  return j.data?.list || [];
};
const POST = async (p, body, query) => {
  const url = `${API}${p}${query ? '?' + new URLSearchParams(query) : ''}`;
  const r = await fetch(url, {
    method: 'POST',
    headers: { ...H, origin: 'https://www.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __nonJson: 1, body: t.replace(/\s+/g, ' ').slice(0, 40) }; }
  return { http: r.status, j };
};
const GETQ = async (p, query) => {
  const r = await fetch(`${API}${p}?${new URLSearchParams(query)}`, { headers: H });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __nonJson: 1, body: t.replace(/\s+/g, ' ').slice(0, 40) }; }
  return { http: r.status, j };
};

let folders = await listAll();
log(`当前夹数=${folders.length} 清单=${folders.map((f) => `${f.id}:${f.title}`).join(' | ')}`);
const PROTECTED = new Set(['62851852', '4020481152', '3896864752', '3926837952', '3962862352', '3683371952']);
const tmp = folders.filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));
if (!tmp.length) log('没有 VF_PROBE_TMP* 残留（无需清理）');

const shapes = [
  ['POST /x/v3/fav/folder/del {media_id,csrf,platform}', (id) => POST('/x/v3/fav/folder/del', { media_id: String(id), csrf, platform: 'web' })],
  ['POST /x/v3/fav/folder/del?media_id&platform {csrf}', (id) => POST('/x/v3/fav/folder/del', { csrf }, { media_id: String(id), platform: 'web' })],
  ['POST /x/v3/fav/folder/del {media_id,_csrf}', (id) => POST('/x/v3/fav/folder/del', { media_id: String(id), _csrf: csrf })],
  ['POST /x/v3/fav/folder/del {media_id,csrf}', (id) => POST('/x/v3/fav/folder/del', { media_id: String(id), csrf })],
  ['GET  /x/v3/fav/folder/del?media_id&csrf&platform', (id) => GETQ('/x/v3/fav/folder/del', { media_id: String(id), csrf, platform: 'web' })],
  ['POST /x/v3/fav/folder/cur/del {media_id,csrf,platform}', (id) => POST('/x/v3/fav/folder/cur/del', { media_id: String(id), csrf, platform: 'web' })],
  ['POST /x/v3/fav/folder/delete {media_id,csrf}', (id) => POST('/x/v3/fav/folder/delete', { media_id: String(id), csrf })],
  ['POST /x/v3/fav/folder/del {id,csrf}', (id) => POST('/x/v3/fav/folder/del', { id: String(id), csrf })],
  ['POST /x/v3/fav/folder/del {fid,csrf}', (id) => POST('/x/v3/fav/folder/del', { fid: String(id), csrf })],
  ['POST /x/v3/fav/folder/del {media_id,csrf,recursion_ids}', (id) => POST('/x/v3/fav/folder/del', { media_id: String(id), csrf, recursion_ids: '[]', platform: 'web' })],
  ['POST /x/v3/fav/folder/remove {media_id,csrf}', (id) => POST('/x/v3/fav/folder/remove', { media_id: String(id), csrf })],
  ['POST /x/v3/fav/folder/cur/del?media_id&platform&csrf', (id) => POST('/x/v3/fav/folder/cur/del', {}, { media_id: String(id), platform: 'web', csrf })],
];

let winner = null;
for (const [label, fn] of shapes) {
  const target = (await listAll()).find((f) => String(f.title).startsWith('VF_PROBE_TMP'));
  if (!target) break;
  const r = await fn(target.id);
  const ok = r.http === 200 && r.j.code === 0;
  log(`${ok ? '✔' : ' '} ${label}\n    → target=${target.id} HTTP=${r.http} code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')}`);
  if (ok) {
    await sleep(900);
    const left = (await listAll()).filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));
    if (!left.length) { winner = label; break; }
    log(`      code=0 但夹仍在（又一个假成功！）残留=${left.map((f) => f.id).join(',')}`);
  }
}

// 兜底：先取消临时夹内视频，再重试
const after = await listAll();
const still = after.filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));
log(`\n剩余临时夹=${still.length} 总夹数=${after.length}`);
if (still.length) {
  log('尝试先从临时夹里移除视频再删：');
  const rl = await fetch(`${API}/x/v3/fav/resource/list?media_id=${still[0].id}&pn=1&ps=20&platform=web`, { headers: H });
  const rlj = await rl.json();
  const rids = (rlj.data?.medias || []).map((m) => m.id);
  if (rids.length) {
    log('  ' + JSON.stringify((await POST('/x/v3/fav/resource/deal', { rid: String(rids[0]), type: '2', add_media_ids: '', del_media_ids: String(still[0].id), csrf })).j).slice(0, 120));
    await sleep(800);
  }
  for (const [label, fn] of shapes.slice(0, 6)) {
    const t2 = (await listAll()).find((f) => String(f.title).startsWith('VF_PROBE_TMP'));
    if (!t2) break;
    const r = await fn(t2.id);
    log(`  重试 ${label} → code=${r.j.code} msg=${redact(r.j.message ?? '')}`);
    await sleep(500);
  }
}
const fin = await listAll();
log(`\n=== 清理结果 ===`);
log(`总夹数=${fin.length}（真实应为 6）| VF_PROBE_TMP* 残留=${fin.filter((f) => String(f.title).startsWith('VF_PROBE_TMP')).map((f) => `${f.id}/${f.title}`).join(',') || '无'}`);
log(`真实夹清单与 media_count：` + fin.filter((f) => PROTECTED.has(String(f.id))).map((f) => `${f.title}=${f.media_count}`).join(' '));
log(`可用删除端点：${winner || '★未找到（见上尝试记录，需人工删）'}`);
