// 第九轮：(1) 用 media_ids(复数) 清掉最后的 VF_PROBE_TMP 残留；
//         (2) 从 fresh-space bundle 提取 fav_state / attr 的代码上下文，确定其真实语义；
//         (3) 夹收藏/取消（folder/fav, folder/unfav）证明 fav_state 的归属对象；
//         (4) 权威归属接口的实测：ps 上限、批量 resource/ids、collected/list。
// 写操作仅限：VF_PROBE_TMP* 清理 + 临时夹的夹收藏（随后 unfav）。真实 6 夹零改动。
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
const J = (v, n = 200) => redact(JSON.stringify(v)).slice(0, n);
const sleep = (ms = 700) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://space.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const GETj = async (p) => {
  const r = await fetch(`${API}${p}`, { headers: H });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 34) }; }
  return { http: r.status, j };
};
const POSTj = async (p, body) => {
  const r = await fetch(`${API}${p}`, {
    method: 'POST',
    headers: { ...H, origin: 'https://space.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __html: 1, body: t.replace(/\s+/g, ' ').slice(0, 34) }; }
  return { http: r.status, j };
};
const listAll = async () => (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&platform=web`)).j.data?.list) || []);

log('=== 1. 清理残留（media_ids 复数）===');
let tmp = (await listAll()).filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));
log(`  残留: ${tmp.map((f) => `${f.id}/${f.title}`).join(',') || '无'}`);
for (const f of tmp) {
  const r = await POSTj('/x/v3/fav/folder/del', { media_ids: String(f.id), csrf });
  log(`  删 ${f.id} "${f.title}" (media_ids=${f.id}): code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')}`);
  await sleep(1000);
  const still = (await listAll()).some((x) => String(x.id) === String(f.id));
  log(`    复查：该夹仍在？${still}`);
}
const after1 = await listAll();
log(`  ★ 当前夹数=${after1.length}（应 6）残留=${after1.filter((f) => String(f.title).startsWith('VF_PROBE_TMP')).length}`);

log('\n=== 2. bundle 中 fav_state / attr 的代码上下文 ===');
const bu = 'https://s1.hdslb.com/bfs/static/shanks/fresh-space/assets/index-76bd2e5f.js';
const bt = await (await fetch(bu, { headers: { 'user-agent': UA } })).text();
log(`  bundle len=${bt.length}`);
for (const key of ['fav_state', 'like_state', 'is_kid_playlist', 'attr', 'visibility', 'private']) {
  const idxs = [];
  let i = -1;
  while ((i = bt.indexOf(key, i + 1)) !== -1 && idxs.length < 12) idxs.push(i);
  log(`  "${key}" 出现 ${idxs.length} 处示例：`);
  for (const p of idxs.slice(0, 6)) log('    …' + redact(bt.slice(Math.max(0, p - 110), p + 110).replace(/\s+/g, ' ')) + '…');
}
// 找 fav_state 相关赋值/比较（=== 1 / ? 1 :）
for (const m of bt.matchAll(/.{90}fav_state.{110}/g)) {
  const s = m[0];
  if (/===?\s*[012]|if\s*\(|\?\s*1\s*:|\?\s*true/.test(s)) log('  [判定逻辑] …' + redact(s.replace(/\s+/g, ' ')) + '…');
}

log('\n=== 3. 夹收藏 folder/fav + folder/unfav（证明 fav_state 归属对象）===');
const col = (await GETj(`/x/v3/fav/folder/collected/list?pn=1&ps=20&up_mid=${uid}&platform=web`)).j;
log(`  collected/list（我收藏的别人的夹）: code=${col.code} data键=${Object.keys(col.data || {}).join(',')} 条数=${(col.data?.list || []).length} 首项=${J((col.data?.list || [])[0], 190)}`);
const target = after1.find((f) => String(f.title) === '神人视频') || after1[after1.length - 1];
const st0 = (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=BV1ySJx6YETj&platform=web`)).j.data?.list) || []);
log(`  收藏前 fav_state 串: ${st0.map((f) => `${f.title.slice(0, 4)}=${f.fav_state}`).join(' ')}`);
const fv = await POSTj('/x/v3/fav/folder/fav', { resource_id: String(target.id), resource_type: '20', biz_code: 'spm_id_from=333.788.space.collection_op.fav.click', csrf });
log(`  folder/fav(resource_id=${target.id} "${target.title}", resource_type=20): code=${fv.j.code} msg=${redact(fv.j.message ?? fv.j.body ?? '')} data=${J(fv.j.data, 90)}`);
await sleep(1200);
const st1 = (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=BV1ySJx6YETj&platform=web`)).j.data?.list) || []);
log(`  收藏该夹后 fav_state 串: ${st1.map((f) => `${f.title.slice(0, 4)}=${f.fav_state}`).join(' ')}`);
log(`  → 目标夹 ${target.title} fav_state: ${st0.find((f) => f.id === target.id)?.fav_state} → ${st1.find((f) => f.id === target.id)?.fav_state}`);
// 复查 collected/list 是否出现该夹（更硬的证据）
const col2 = (await GETj(`/x/v3/fav/folder/collected/list?pn=1&ps=20&up_mid=${uid}&platform=web`)).j;
log(`  collected/list 现在含该夹=${(col2.data?.list || []).some((f) => String(f.id) === String(target.id))} 条数=${(col2.data?.list || []).length}`);
const uf = await POSTj('/x/v3/fav/folder/unfav', { resource_id: String(target.id), resource_type: '20', csrf });
log(`  folder/unfav 恢复: code=${uf.j.code} msg=${redact(uf.j.message ?? uf.j.body ?? '')}`);
await sleep(1200);
const st2 = (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=BV1ySJx6YETj&platform=web`)).j.data?.list) || []);
const col3 = (await GETj(`/x/v3/fav/folder/collected/list?pn=1&ps=20&up_mid=${uid}&platform=web`)).j;
log(`  取消后 fav_state 串: ${st2.map((f) => `${f.title.slice(0, 4)}=${f.fav_state}`).join(' ')} | collected 含该夹=${(col3.data?.list || []).some((f) => String(f.id) === String(target.id))}`);
log(`  ★ 结论依据：若 folder/fav 后 collected/list 出现该夹而 list-all.fav_state 仍 0 → fav_state 与"夹归属/夹收藏"都无关，面板不可依赖它`);

log('\n=== 4. 权威"该视频在哪些夹"候选实测 ===');
const rl = (await GETj(`/x/v3/fav/resource/list?media_id=62851852&pn=1&ps=100&platform=web`)).j;
log(`  resource/list ps=100: code=${rl.code} 返回条数=${(rl.data?.medias || []).length} has_more=${rl.data?.has_more}（夹内 32 条）`);
const rl2 = (await GETj(`/x/v3/fav/resource/list?media_id=3683371952&pn=1&ps=200&platform=web`)).j;
log(`  resource/list ps=200（神人视频 145 条）: 返回=${(rl2.data?.medias || []).length} has_more=${rl2.data?.has_more} → ps 上限观测`);
const rl1000 = (await GETj(`/x/v3/fav/resource/list?media_id=3683371952&pn=1&ps=1000&platform=web`)).j;
log(`  resource/list ps=1000: 返回=${(rl1000.data?.medias || []).length} has_more=${rl1000.data?.has_more}`);
const rlNoDetail = (await GETj(`/x/v3/fav/resource/list?media_id=62851852&pn=1&ps=100&platform=web&detail=0`)).j;
log(`  detail=0 时 medias[0] 键=${Object.keys((rlNoDetail.data?.medias || [])[0] || {}).join(',')}（找 id/bvid 精简字段）`);
for (const c of [
  `/x/v3/fav/resource/ids?rid=${116745046065481}&type=2`,
  `/x/v3/fav/resource/ids?ids=${116745046065481}&type=2`,
  `/x/v3/fav/resource/ids?resources=${116745046065481}&type=2`,
  `/x/v3/fav/folder/created/list?up_mid=${uid}&pn=1&ps=20&bvid=BV1ySJx6YETj`,
  `/x/v3/fav/folder/list4navigate?up_mid=${uid}&platform=web&bvid=BV1ySJx6YETj`,
  `/x/v3/fav/statistics/count?up_mid=${uid}`,
  `/x/v3/fav/resource/list?media_id=62851852&pn=1&ps=20&platform=web&keyword=BV1ySJx6YETj`,
]) {
  const r = await GETj(c);
  log(`  ${c.slice(0, 92)}\n      HTTP=${r.http} code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')} data=${J(r.j.data, 150)}`);
}
// 逐夹并发扫（这是 UI 唯一可靠方案）：验证能在"神人视频"第 N 页找到深处的视频
const deepFolder = after1.find((f) => String(f.title) === '神人视频');
if (deepFolder) {
  const total = deepFolder.media_count;
  const ps = 20, pages = Math.ceil(total / ps);
  let hit = null;
  const last = (await GETj(`/x/v3/fav/resource/list?media_id=${deepFolder.id}&pn=${pages}&ps=${ps}&platform=web`)).j;
  const lastList = last.data?.medias || [];
  hit = lastList.length ? (lastList[0].bvid || lastList[0].bv_id) : null;
  log(`  深页验证：${deepFolder.title} 共 ${total} 条 → 第 ${pages} 页返回 ${lastList.length} 条，其中一条=${hit}`);
  if (hit) {
    const stD = (((await GETj(`/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${hit}&platform=web`)).j.data?.list) || []);
    const rowD = stD.find((f) => String(f.id) === String(deepFolder.id));
    log(`    该深页视频用 list-all(bvid) 查 → ${deepFolder.title}.fav_state=${rowD?.fav_state}（期望 1，若 0 则 fav_state 彻底不可用）`);
    const relD = (await GETj(`/x/web-interface/archive/relation?bvid=${hit}`)).j;
    log(`    archive/relation.favorite=${relD.data?.favorite}（该视频确实已被收藏，=true 则总态可用）`);
  }
}

log('\n=== 5. 状态核对 ===');
const fin = await listAll();
const tmpLeft = fin.filter((f) => String(f.title).startsWith('VF_PROBE_TMP'));
const exp = (await GETj('/x/member/web/exp/reward')).j;
const tv = (await GETj('/x/v2/history/toview/web?platform=web')).j;
const rel = (await GETj('/x/relation?fid=3546661399824534&ptype=1')).j;
log(`  夹数=${fin.length}（应 6）| VF_PROBE_TMP 残留=${tmpLeft.length}（应 0）`);
log(`  media_count: ${fin.map((f) => `${f.title}=${f.media_count}`).join(' ')}`);
log(`  coins=${exp.data?.coins}（应 0）| toview.count=${tv.data?.count}（应 0）| 关注 attribute=${rel.data?.attribute}（应 0）`);
log(`  账号状态已恢复：${fin.length === 6 && tmpLeft.length === 0 && exp.data?.coins === 0 && tv.data?.count === 0 && rel.data?.attribute === 0 ? '是' : '★需核对（夹数或残留未归零）'}`);
