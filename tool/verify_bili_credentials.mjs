// 最终验证：`credentials` 到底改变了什么？
//
// 用户提供的信息说：
//   "通过脚本拦截（Hook）浏览器发出的评论请求（XHR/Fetch），
//    并手动为其加上 credentials（即模拟携带登录凭证）。
//    这样接口就会认为请求是'已登录'状态，从而返回包含 IP 属地的数据。"
//
// 需要澄清一个技术事实：
//   `credentials: 'include'` 只是告诉浏览器"**允许**附带本站 Cookie"。
//   它本身不创造凭证 —— 浏览器里没有登录 Cookie 时，
//   include 也不会凭空产生 SESSDATA。
//
// 所以两种可能：
//   A. 用户在浏览器里**已登录**，脚本用 include 确保 Cookie 被带上
//      → 本质仍是登录态
//   B. 服务端只看"有没有 buvid 指纹 + 某个头"，include 触发了不同分支
//      → 存在匿名路径
//
// 本脚本用真实 Cookie 语义对比：
//   - 完全不带 Cookie
//   - 带设备指纹（buvid3/buvid4/_uuid）
//   - 带设备指纹 + 伪造 SESSDATA
//   - 带设备指纹 + 伪造 SESSDATA + 伪造 bili_jct
//   - 带设备指纹 + **格式正确但签名无效**的 SESSDATA（模拟"看起来已登录"）
//
// 关键：构造一个**格式合法**的 SESSDATA（base64 的 uid,ts,sig 结构），
// 看服务端是否会在"解析成功但校验失败"时泄露 location。

import crypto from 'node:crypto';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

const MIXIN_TAB = [
  46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,
  14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,
  56,59,6,63,57,62,11,36,20,34,44,52,
];

async function getWbiKey() {
  const r = await fetch('https://api.bilibili.com/x/web-interface/nav', {
    headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' },
  });
  const j = await r.json();
  const img = j.data.wbi_img.img_url.split('/').pop().split('.')[0];
  const sub = j.data.wbi_img.sub_url.split('/').pop().split('.')[0];
  return MIXIN_TAB.map((i) => (img + sub)[i]).join('').slice(0, 32);
}

function sign(params, key) {
  const p = { ...params, wts: String(Math.floor(Date.now() / 1000)) };
  const q = Object.keys(p).sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(String(p[k]).replace(/[!'()*]/g, ''))}`)
    .join('&');
  return `${q}&w_rid=${crypto.createHash('md5').update(q + key).digest('hex')}`;
}

const spi = await (await fetch('https://api.bilibili.com/x/frontend/finger/spi', {
  headers: { 'user-agent': UA },
})).json();
const b3 = spi.data.b_3, b4 = spi.data.b_4;
const uuid = crypto.randomUUID().toUpperCase() + 'infoc';
const FP = `buvid3=${b3}; buvid4=${b4}; b_nut=${Math.floor(Date.now() / 1000)}; _uuid=${uuid}`;

const pop = await (await fetch('https://api.bilibili.com/x/web-interface/popular?ps=3&pn=1', {
  headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' },
})).json();
const v = pop.data.list[0];
const aid = v.aid;
console.log(`视频 aid=${aid}  评论=${v.stat.reply}`);
console.log('');

const wbiKey = await getWbiKey();

// ---------- 构造"格式合法但签名无效"的 SESSDATA ----------
// 真实格式：base64("{uid},{timestamp},{md5签名}")
const fakeUid = '99999999';
const fakeTs = Math.floor(Date.now() / 1000);
const fakeSig = crypto.createHash('md5').update(`${fakeUid},${fakeTs},fake`).digest('hex');
const structuredSess = Buffer.from(`${fakeUid},${fakeTs},${fakeSig}`).toString('base64');
// 真实 Cookie 里逗号会被 urlencode
const structuredSessEnc = structuredSess.replace(/=/g, '%3D').replace(/,/g, '%2C').replace(/\+/g, '%2B');

const base = { oid: aid, type: 1, mode: 3, pagination_str: '{"offset":""}', plat: 1, web_location: 1315875 };

async function probe(label, cookie) {
  const q = sign(base, wbiKey);
  const headers = {
    'user-agent': UA,
    referer: `https://www.bilibili.com/video/${v.bvid}`,
    accept: 'application/json, text/plain, */*',
  };
  if (cookie) headers.cookie = cookie;
  const r = await fetch(`https://api.bilibili.com/x/v2/reply/wbi/main?${q}`, { headers });
  const j = await r.json();

  // 同时看 nav 接口的 isLogin，确认服务端是否认这个 Cookie
  let isLogin = '?';
  try {
    const navHeaders = { 'user-agent': UA, referer: 'https://www.bilibili.com/' };
    if (cookie) navHeaders.cookie = cookie;
    const nav = await (await fetch('https://api.bilibili.com/x/web-interface/nav', {
      headers: navHeaders,
    })).json();
    isLogin = String(nav.data?.isLogin);
  } catch {}

  const list = j.data?.replies || [];
  let withLoc = 0;
  for (const rep of list) if (rep.reply_control?.location) withLoc++;
  console.log(
    `  ${label.padEnd(40)} code=${j.code} n=${list.length} ` +
    `loc=${withLoc}  nav.isLogin=${isLogin}`
  );
  return { withLoc, isLogin };
}

console.log('=== 关键对比：伪造"看起来合法"的登录 Cookie ===');
await probe('A. 无 Cookie', '');
await probe('B. 仅设备指纹', FP);
await probe('C. 指纹 + 结构化 SESSDATA（签名错）', `${FP}; SESSDATA=${structuredSessEnc}`);
await probe('D. 指纹 + 结构化 SESSDATA + bili_jct', `${FP}; SESSDATA=${structuredSessEnc}; bili_jct=${fakeSig}; DedeUserID=${fakeUid}`);
await probe('E. 指纹 + 结构化 SESSDATA + DedeUserID（urlencode 逗号）', `${FP}; SESSDATA=${structuredSessEnc}; DedeUserID=${fakeUid}`);

console.log('');
console.log('=== 结论 ===');
console.log('  credentials 的语义：');
console.log('    credentials: "include" 只表示"允许浏览器附带本站 Cookie"，');
console.log('    它不创造凭证。没有登录 Cookie 时，include 也带不出 SESSDATA。');
console.log('');
console.log('  因此 BiliReveal 等脚本能显示属地的真实前提是：');
console.log('    **用户浏览器里已经登录了 B站**，脚本只是把');
console.log('    页面已登录请求响应里的 reply_control.location 渲染到 DOM。');
console.log('');
console.log('  如果 nav.isLogin 全部为 false 且 loc 全部为 0，');
console.log('  则证明：伪造 Cookie 无法进入"已登录"分支，');
console.log('  匿名路径不存在。');
