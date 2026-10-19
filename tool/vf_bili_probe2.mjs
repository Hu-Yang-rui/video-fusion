// 第二轮接口探针：确定"该视频在哪些收藏夹"的权威接口 + 投币余额 + 稍后再看。
// 凭据从仓库外读取，输出不含 cookie 值。
import fs from 'node:fs';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const COOKIE = (process.env.BILI_COOKIE ||
  fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const g = (n) => (COOKIE.match(new RegExp(`${n}=([^;]+)`)) || [])[1] || '';
const uid = g('DedeUserID'), csrf = g('bili_jct');
const API = 'https://api.bilibili.com';
const HG = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: COOKIE, accept: 'application/json, text/plain, */*' };

const probe = async (label, url, opts = {}) => {
  try {
    const r = await fetch(url, { headers: HG, ...opts });
    const t = await r.text();
    let j; try { j = JSON.parse(t); } catch { console.log(`  ${label}\n    → HTTP ${r.status} 非 JSON: ${t.replace(/\s+/g, ' ').slice(0, 70)}`); return null; }
    console.log(`  ${label}\n    → code=${j.code} msg=${j.message} data=${JSON.stringify(j.data).slice(0, 220)}`);
    return j;
  } catch (e) { console.log(`  ${label}\n    → ERR ${e.message}`); return null; }
};

const pop = await (await fetch(`${API}/x/web-interface/popular?ps=1&pn=1`, { headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' } })).json();
const { aid, bvid } = pop.data.list[0];
const folders = ((await (await fetch(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}`, { headers: HG })).json()).data?.list) || [];
const ids = folders.map((f) => f.id).join(',');
console.log(`测试 aid=${aid} bvid=${bvid} 夹=[${ids}]\n`);

console.log('=== 1. 权威"某视频在哪些夹"候选接口 ===');
await probe('a /x/v3/fav/resource/metas?ids=&type=2', `${API}/x/v3/fav/resource/metas?ids=${aid}&type=2&platform=web`);
await probe('b /x/v3/fav/resource/batch/metas', `${API}/x/v3/fav/resource/batch/metas?resources[0][id]=${aid}&resources[0][type]=2`);
await probe('c /x/v3/fav/tag/list?up_mid=', `${API}/x/v3/fav/tag/list?up_mid=${uid}&platform=web`);
await probe('d /x/v3/fav/user/tags?up_mid=&bvid=', `${API}/x/v3/fav/user/tags?up_mid=${uid}&bvid=${bvid}&platform=web`);
await probe('e /x/v3/fav/folder/created/list-all?up_mid=&bvid=', `${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}&bvid=${bvid}&platform=web`);
await probe('f /x/v3/fav/resource/check?rid=&type=&media_ids=', `${API}/x/v3/fav/resource/check?rid=${aid}&type=2&media_ids=${ids}`);
await probe('g /x/v3/fav/batch/check?media_ids=&rid=', `${API}/x/v3/fav/batch/check?media_ids=${ids}&rid=${aid}&type=2`);
await probe('h /x/v2/fav/video?bvid=', `${API}/x/v2/fav/video?bvid=${bvid}&platform=web`);
await probe('i /x/v3/fav/folder/visited/list-all', `${API}/x/v3/fav/folder/visited/list-all?up_mid=${uid}`);
await probe('j /x/v3/fav/folder/info?media_id=', `${API}/x/v3/fav/folder/info?media_id=${folders[0]?.id}`);
await probe('k /x/v3/fav/folder/count/type?mid=', `${API}/x/v3/fav/folder/count/type?mid=${uid}`);

console.log('\n=== 2. 收藏夹内计数与全量翻页字段 ===');
const rl = await (await fetch(`${API}/x/v3/fav/resource/list?media_id=${folders[folders.length - 1].id}&pn=1&ps=20&platform=web`, { headers: HG })).json();
console.log(`  "神人视频" data.info=${JSON.stringify(rl.data.info)?.slice(0, 260)}`);
console.log(`  has_more=${rl.data.has_more} medias=${(rl.data.medias || []).length}`);

console.log('\n=== 3. 投币余额 ===');
const exp = await (await fetch(`${API}/x/member/web/exp/reward`, { headers: HG })).json();
console.log(`  data=${JSON.stringify(exp.data)}`);
await probe('coin/money', `${API}/x/web-interface/coin/money`);

console.log('\n=== 4. 稍后再看候选 ===');
await probe('a /x/v2/history/toview/web', `${API}/x/v2/history/toview/web?platform=web`);
await probe('b /x/v2/history/toview', `${API}/x/v2/history/toview`);
await probe('c /x/v3/fav/season/list?season_id=', `${API}/x/v3/fav/season/list?season_id=0&pn=1&ps=5`);

console.log('\n=== 5. 点赞/收藏计数来源 ===');
const view = await (await fetch(`${API}/x/web-interface/view?bvid=${bvid}`, { headers: HG })).json();
console.log(`  view.stat=${JSON.stringify(view.data.stat)}`);
const rel = await (await fetch(`${API}/x/web-interface/archive/relation?bvid=${bvid}`, { headers: HG })).json();
console.log(`  relation=${JSON.stringify(rel.data)}`);
console.log(`  ★ relation.like 是布尔(${typeof rel.data.like})，不是点赞数 —— 现有代码把它当 likeCount`);

console.log('\n=== 6. 关注 UP 主状态 ===');
const mid = pop.data.list[0].owner.mid;
await probe(`a /x/relation?fid=${mid}&ptype=1`, `${API}/x/relation?fid=${mid}&ptype=1`);
await probe(`b /x/web-interface/card?mid=`, `${API}/x/web-interface/card?mid=${mid}`);
await probe(`c /x/space/tags?tid=${mid}`, `${API}/x/space/tags?tid=${mid}`);
