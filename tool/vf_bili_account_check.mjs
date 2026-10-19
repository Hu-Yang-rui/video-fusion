// 账号状态复核（只读）：确认可逆写入测试没有留下任何改动。
// 凭据从仓库外读取，输出不含任何 cookie 取值。
import fs from 'node:fs';

const CK = (process.env.BILI_COOKIE ||
  fs.readFileSync('D:/vf-local/bili_cookie.txt', 'utf8')).trim();
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const H = { 'user-agent': UA, referer: 'https://www.bilibili.com/', cookie: CK, accept: 'application/json' };
const BV = 'BV1G5po6zECY';
const API = 'https://api.bilibili.com';

const j = async (u) => (await (await fetch(u, { headers: H })).json());

const rel = await j(`${API}/x/web-interface/archive/relation?bvid=${BV}`);
console.log(`测试视频 ${BV} relation = ${JSON.stringify(rel.data)}`);
console.log(`  favorite = ${rel.data?.favorite}  ← 必须 false（账号已恢复原状）`);

const uid = (CK.match(/DedeUserID=(\d+)/) || [])[1];
const f = await j(`${API}/x/v3/fav/folder/created/list-all?up_mid=${uid}`);
const list = f.data?.list || [];
console.log(`\n收藏夹数量 = ${list.length}`);
for (const x of list) {
  console.log(`   id=${x.id}  "${x.title}"  media_count=${x.media_count}`);
}
const leftovers = list.filter((x) => (x.title || '').startsWith('VF_PROBE_TMP'));
console.log(`探针残留夹 = ${leftovers.length ? leftovers.map((x) => `${x.id} "${x.title}"`).join(', ') : '无'}`);

const lt = await j(`${API}/x/v2/history/toview/web?platform=web`);
console.log(`\n稍后再看 count = ${lt.data?.count}  ← 测试不应留下条目`);
