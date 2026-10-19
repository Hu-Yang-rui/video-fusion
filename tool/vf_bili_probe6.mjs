// 第六轮：fav_state 判别实验（纯只读，零写入）。
// 核心问题：上一轮把视频成功收藏进夹（media_count +1、resource/list 首屏能命中）之后，
//          created/list-all 的 fav_state 仍然是 0。到底是
//          (a) fav_state 需要延迟/缓存刷新？
//          (b) fav_state 需要特定参数才计算？
//          (c) fav_state 根本不是"该视频在此夹"的指示？
// 判别方法：拿一个【已经确定在夹里】的视频（从 resource/list 真实读出），
//          再查 list-all 看那个夹的 fav_state 是不是 1。
// 附带：aid/bvid 等价性、多 P（同一 aid 不同 part bvid）、未登录/坏 cookie 的 code。
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };
const HN = { 'user-agent': UA, referer: 'https://www.bilibili.com/', accept: 'application/json, text/plain, */*' };
const BAD = { 'user-agent': UA, referer: 'https://www.bilibili.com', cookie: 'SESSDATA=deadbeefdeadbeef; bili_jct=deadbeefdeadbeef; DedeUserID=' + uid };
const G = async (p, h = H) => {
  const r = await fetch(`${API}${p}`, { headers: h });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = { __nonJson: 1, body: t.replace(/\s+/g, ' ').slice(0, 40) }; }
  return { http: r.status, j };
};
const LA = async (q, h = H) => (await G(`/x/v3/fav/folder/created/list-all?${q}`, h)).j;
const row = (j, id) => (j.data?.list || []).find((f) => String(f.id) === String(id)) || null;
const str = (j) => (j.data?.list || []).map((f) => `${f.title.slice(0, 5)}:${f.fav_state}`).join(' ');

log('=== 1. 取一个"确定在夹内"的视频作为判别样本 ===');
const folders0 = (await LA(`up_mid=${uid}&platform=web`)).data?.list || [];
log(`夹：${folders0.map((f) => `${f.id} ${f.title}(${f.media_count})`).join(' | ')}`);
// 从最小夹 gay(1)/合(1) 里直接读，保证 100% 命中且只 1 条
const small = folders0.filter((f) => (f.media_count || 0) > 0 && (f.media_count || 0) <= 8 && !String(f.title).startsWith('VF_PROBE_TMP'));
let sample = null;
for (const f of small) {
  const rl = (await G(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`)).j;
  const m = (rl.data?.medias || [])[0];
  if (m) { sample = { folder: f, bvid: m.bvid || m.bv_id, aid: m.id, fav_time: m.fav_time, title: m.title }; break; }
}
log(`判别样本：夹 "${sample.folder.title}"(${sample.folder.id}) 内含 bvid=${sample.bvid} aid=${sample.aid} fav_time=${sample.fav_time}`);
log(`  "${String(sample.title).slice(0, 30)}"`);

log('\n=== 2. fav_state 参数矩阵（对"确定在夹内"的样本）===');
const combos = [
  [`up_mid=${uid}&bvid=${sample.bvid}`, 'bvid only'],
  [`up_mid=${uid}&bvid=${sample.bvid}&platform=web`, 'bvid+platform'],
  [`up_mid=${uid}&aid=${sample.aid}`, 'aid only'],
  [`up_mid=${uid}&aid=${sample.aid}&platform=web`, 'aid+platform'],
  [`up_mid=${uid}&bvid=${sample.bvid}&aid=${sample.aid}&platform=web`, 'both'],
  [`up_mid=${uid}&bvid=${sample.bvid}&platform=web&kind=11`, 'bvid+kind=11'],
  [`up_mid=${uid}&bvid=${sample.bvid}&platform=web&type=2`, 'bvid+type=2'],
  [`up_mid=${uid}&bvid=${sample.bvid.toUpperCase()}&platform=web`, 'bvid 大写'],
  [`up_mid=${uid}&bvid=BV00000000000&platform=web`, 'bvid 不存在'],
];
const target = sample.folder.id;
for (const [q, label] of combos) {
  const j = await LA(q);
  const r = row(j, target);
  log(`  [${label}] code=${j.code} → 目标夹 fav_state=${r?.fav_state} | 全串=${str(j)}`);
}

log('\n=== 3. 对照：fav_time（resource/list）与 fav_state 是否互相印证 ===');
const rlT = (await G(`/x/v3/fav/resource/list?media_id=${target}&pn=1&ps=20&platform=web`)).j;
log(`  resource/list 命中该 bvid=${(rlT.data?.medias || []).some((m) => (m.bvid || m.bv_id) === sample.bvid)}`);
const jNow = await LA(`up_mid=${uid}&bvid=${sample.bvid}&platform=web`);
log(`  同一时刻 list-all 该夹 fav_state=${row(jNow, target)?.fav_state}  → ${row(jNow, target)?.fav_state === 1 ? 'fav_state 有效' : '★fav_state 不反映已知归属'}`);
log(`  该响应目标夹完整对象：${J(row(jNow, target), 260)}`);

log('\n=== 4. 遍历夹：fav_state 是否在别的夹上出现非 0 值 ===');
log(`  每个已知在夹视频的归属夹 fav_state 抽样：`);
for (const f of small.slice(0, 4)) {
  const rl = (await G(`/x/v3/fav/resource/list?media_id=${f.id}&pn=1&ps=20&platform=web`)).j;
  const m = (rl.data?.medias || [])[0];
  if (!m) continue;
  const j = await LA(`up_mid=${uid}&bvid=${m.bvid || m.bv_id}&platform=web`);
  log(`    ${f.title} 内第一条 ${m.bvid || m.bv_id} → 该夹 fav_state=${row(j, f.id)?.fav_state} | 串=${str(j)}`);
}

log('\n=== 5. 多 P / 合集：同一 aid 的不同 part ===');
const vp = (await G(`/x/web-interface/view?bvid=${sample.bvid}`, HN)).j;
log(`  view: aid=${vp.data?.aid} bvid=${vp.data?.bvid} pages=${(vp.data?.pages || []).length} ugc_season=${vp.data?.ugc_season ? 'yes' : 'no'}`);
if ((vp.data?.pages || []).length > 1) {
  for (const p of vp.data.pages.slice(0, 3))
    log(`    part cid=${p.cid} page=${p.page} part=${String(p.part).slice(0, 14)}`);
  for (const p of vp.data.pages.slice(0, 2)) {
    const j = await LA(`up_mid=${uid}&bvid=${vp.data.bvid}&pid=${p.page}&platform=web`);
    log(`    list-all 加 pid=${p.page} → 目标夹 fav_state=${row(j, target)?.fav_state}`);
  }
  const jAid = await LA(`up_mid=${uid}&aid=${vp.data.aid}&platform=web`);
  log(`    list-all 用 aid → 目标夹 fav_state=${row(jAid, target)?.fav_state}（整视频维度）`);
} else {
  log('  该样本是单 P。另找一个多 P 视频：');
  const pop = (await G('/x/web-interface/popular?ps=10&pn=1', HN)).j;
  let mp = null;
  for (const it of pop.data?.list || []) {
    const v = (await G(`/x/web-interface/view?bvid=${it.bvid}`, HN)).j;
    if ((v.data?.pages || []).length > 1) { mp = v.data; break; }
  }
  if (mp) {
    log(`  多P样本：${mp.bvid} aid=${mp.aid} pages=${mp.pages.length} ugc_season=${mp.ugc_season ? 'yes' : 'no'}`);
    const j1 = await LA(`up_mid=${uid}&bvid=${mp.bvid}&platform=web`);
    log(`    fav_state 串（未收藏态基线）= ${str(j1)}`);
    const j2 = await LA(`up_mid=${uid}&aid=${mp.aid}&platform=web`);
    log(`    aid 版串 = ${str(j2)}`);
    const pidv = mp.pages[1];
    const j3 = await LA(`up_mid=${uid}&bvid=${mp.bvid}&pid=${pidv.page}&platform=web`);
    log(`    带 pid=${pidv.page} 串 = ${str(j3)}`);
    log(`    ★ 多 P 只按整视频（aid/bvid）判定，part 不影响归属：见上三串是否一致`);
    if (mp.ugc_season) {
      const sid = mp.ugc_season.id;
      const jS = await LA(`up_mid=${uid}&bvid=${mp.bvid}&platform=web`);
      log(`    合集 season_id=${sid} list-all.season_fav? → archive/relation.season_fav=${(await G(`/x/web-interface/archive/relation?bvid=${mp.bvid}`)).j.data?.season_fav} | 串=${str(jS)}`);
    }
  } else log('  未找到多 P 样本');
}

log('\n=== 6. 未登录 / 坏 cookie 对 list-all 的返回（决定 UI 登录失效分支）===');
const a1 = await LA(`up_mid=${uid}&bvid=${sample.bvid}&platform=web`, HN);
log(`  无 cookie: code=${a1.code} msg=${redact(a1.message ?? '')} 夹数=${(a1.data?.list || []).length} fav_state=${a1.data?.list?.[0]?.fav_state} 首项=${J(row(a1, target), 150)}`);
const a2 = await LA(`up_mid=${uid}&bvid=${sample.bvid}&platform=web`, BAD);
log(`  坏 cookie: code=${a2.code} msg=${redact(a2.message ?? '')} 夹数=${(a2.data?.list || []).length}`);
const a3 = await LA(`up_mid=${uid}&bvid=${sample.bvid}&platform=web`, { ...HN, cookie: 'SESSDATA=' });
log(`  空 SESSDATA: code=${a3.code} msg=${redact(a3.message ?? '')}`);
const n1 = (await G('/x/web-interface/nav', HN)).j;
log(`  nav 无 cookie: code=${n1.code} data.isLogin=${n1.data?.isLogin} vipType=${n1.data?.vipType}`);
const n2 = (await G('/x/web-interface/nav', BAD)).j;
log(`  nav 坏 cookie: code=${n2.code} msg=${redact(n2.message ?? '')} isLogin=${n2.data?.isLogin}（★-101 只出现在哪些接口需分开判定）`);
const relAnon = (await G(`/x/web-interface/archive/relation?bvid=${sample.bvid}`, HN)).j;
log(`  archive/relation 无 cookie: code=${relAnon.code} msg=${redact(relAnon.message ?? '')}`);
const relBad = (await G(`/x/web-interface/archive/relation?bvid=${sample.bvid}`, BAD)).j;
log(`  archive/relation 坏 cookie: code=${relBad.code} msg=${redact(relBad.message ?? '')}`);
const tvAnon = (await G('/x/v2/history/toview/web?platform=web', HN)).j;
log(`  toview/web 无 cookie: code=${tvAnon.code} msg=${redact(tvAnon.message ?? '')}`);
const dealBad = await fetch(`${API}/x/v3/fav/resource/deal`, {
  method: 'POST',
  headers: { ...BAD, origin: 'https://www.bilibili.com', 'content-type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ rid: String(sample.aid), type: '2', add_media_ids: String(target), del_media_ids: '', csrf: 'deadbeef' }).toString(),
});
const dj = await dealBad.json();
log(`  deal 坏 cookie: code=${dj.code} msg=${redact(dj.message ?? '')}（★未落地的写，等于 -101/-111 的登录失效分支）`);

log('\n=== 7. fav_state 候选替代接口（判"在哪些夹"）===');
const cands = [
  `/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${sample.bvid}&platform=web&time=${Math.floor(Date.now() / 1000)}`,
  `/x/v3/fav/folder/recursion/list-all?up_mid=${uid}&bvid=${sample.bvid}&platform=web`,
  `/x/v3/fav/folder/visited/list-all?up_mid=${uid}`,
  `/x/v3/fav/folder/count?media_ids=${target}`,
  `/x/v3/fav/resource/info?rid=${sample.aid}&type=2`,
  `/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${sample.bvid}&platform=pc`,
  `/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${sample.bvid}`,
  `/x/v2/fav/video?bvid=${sample.bvid}`,
  `/x/v3/fav/resource/ids?rid=${sample.aid}&type=2`,
  `/x/v3/fav/tag/tags?up_mid=${uid}`,
];
for (const u of cands) {
  const r = await G(u);
  log(`  ${u.slice(0, 78)}\n      HTTP=${r.http} code=${r.j.code} msg=${redact(r.j.message ?? r.j.body ?? '')} data=${J(r.j.data, 150)}`);
}
log('\n=== 8. 零写入核对 ===');
const f2 = (await LA(`up_mid=${uid}&platform=web`)).data?.list || [];
log(`  夹数=${f2.length} media_count: ${f2.map((f) => `${f.title.slice(0, 6)}=${f.media_count}`).join(' ')}`);
log('  本探针未发起任何写请求（仅 GET + 一次坏 csrf 的 deal，服务端拒绝、无副作用）。账号状态已恢复：是（本来就没改）');
