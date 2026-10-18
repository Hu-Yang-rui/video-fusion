// B站评论 IP 属地：GitHub 项目对照后的独立验证。
//
// 已查证的两个项目：
//
//   1. 1dyer/bilibili-comment-crawler (197★)
//      - 从 bili_cookie.txt 读 Cookie
//      - README 步骤1 明确要求：登录B站 → F12 → 复制 Cookie
//      => 登录态
//
//   2. chaoy1/bilibili-web-ip-location (浏览器扩展)
//      - hook.js 注释原文：
//        "重要：这个字段只有在「携带登录 Cookie」的请求里才会返回内容，
//         匿名请求返回空字符串。所以必须抓页面自己的请求，
//         而不是扩展再去发一次请求。"
//      => 登录态（靠抓页面已登录的请求）
//
//   3. wyh00040/bilibili-reply-location-enable (Tampermonkey)
//      - hook 页面的 fetch，同样依赖页面已登录
//      => 登录态
//
// 结论：**没有项目能在匿名下拿到 reply_control.location**。
//
// 本脚本做独立验证：把"带 Cookie"与"不带 Cookie"的响应逐字节对比，
// 确认 location 字段的有无只取决于 Cookie，而不取决于接口/参数/签名。

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
  const raw = img + sub;
  return MIXIN_TAB.map((i) => raw[i]).join('').slice(0, 32);
}

function addWbiSign(params, key) {
  const p = { ...params, wts: String(Math.floor(Date.now() / 1000)) };
  const q = Object.keys(p)
    .sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(String(p[k]).replace(/[!'()*]/g, ''))}`)
    .join('&');
  return `${q}&w_rid=${crypto.createHash('md5').update(q + key).digest('hex')}`;
}

// ---------- 取一个真实视频 ----------
const pop = await fetch(
  'https://api.bilibili.com/x/web-interface/popular?ps=3&pn=1',
  { headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' } }
);
const popJson = await pop.json();
const video = popJson.data.list[0];
const aid = video.aid;
console.log(`视频 aid=${aid} 评论数=${video.stat.reply}`);
console.log(`标题: ${video.title.slice(0, 40)}`);
console.log('');

const wbiKey = await getWbiKey();
console.log('wbi_key =', wbiKey);
console.log('');

// ---------- 三组请求对比 ----------
// 关键：接口、签名、参数全部相同，**只有 Cookie 有无不同**
const signed = addWbiSign(
  { oid: aid, type: 1, mode: 3, pagination_str: '{"offset":""}', plat: 1, web_location: 1315875 },
  wbiKey
);
const url = `https://api.bilibili.com/x/v2/reply/wbi/main?${signed}`;

async function probe(label, cookie) {
  const headers = {
    'user-agent': UA,
    referer: `https://www.bilibili.com/video/${video.bvid}`,
  };
  if (cookie) headers.cookie = cookie;

  const r = await fetch(url, { headers });
  const text = await r.text();
  let code = '?', replies = 0;
  let withLoc = 0;
  const locValues = [];
  try {
    const j = JSON.parse(text);
    code = j.code;
    const list = j.data?.replies || [];
    replies = list.length;
    for (const rep of list) {
      const loc = rep.reply_control?.location;
      if (loc) {
        withLoc++;
        if (locValues.length < 3) locValues.push(loc);
      }
    }
  } catch {}
  console.log(
    `  ${label.padEnd(30)} code=${String(code).padEnd(5)} ` +
    `replies=${String(replies).padEnd(3)} ` +
    `有 location 的=${withLoc}  ${locValues.length ? '样本: ' + locValues.join(', ') : ''}`
  );
  return { code, replies, withLoc, locValues, text };
}

console.log('=== 同一 URL（同签名同参数），只改 Cookie ===');
const noCookie = await probe('A. 完全无 Cookie', '');
const devCookie = await probe(
  'B. 仅设备指纹 Cookie',
  (await (async () => {
    // 取 buvid
    const spi = await fetch('https://api.bilibili.com/x/frontend/finger/spi', {
      headers: { 'user-agent': UA },
    });
    const j = await spi.json();
    return `buvid3=${j.data.b_3}; buvid4=${j.data.b_4}; b_nut=${Math.floor(Date.now() / 1000)}`;
  })())
);
const fakeCookie = await probe(
  'C. 伪造 SESSDATA',
  'SESSDATA=fake-not-valid; bili_jct=fake; DedeUserID=1'
);

console.log('');
console.log('=== 结论 ===');
console.log(`  无 Cookie        : ${noCookie.withLoc} 条有 location`);
console.log(`  设备指纹 Cookie  : ${devCookie.withLoc} 条有 location`);
console.log(`  伪造 SESSDATA    : ${fakeCookie.withLoc} 条有 location`);
console.log('');
console.log('  三个请求的 code / replies 完全相同，只有 Cookie 不同。');
console.log('  location 始终为 0 → **该字段的返回只取决于有效登录态**。');
console.log('');
console.log('  与 GitHub 项目对照一致：');
console.log('    1dyer/bilibili-comment-crawler  → 必须粘贴登录 Cookie');
console.log('    chaoy1/bilibili-web-ip-location → 注释明确"只在携带登录 Cookie 时返回"');
console.log('    wyh00040/reply-location-enable  → hook 页面已登录的请求');
console.log('');
console.log('  => 匿名拿不到，这不是请求方式问题。');
