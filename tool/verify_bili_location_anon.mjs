// 决定性实验：B站评论 location 是否只取决于"有效登录 Cookie"。
//
// 背景（本轮查证）：
//   maxchang3/BiliReveal (333★) README §原理：
//     "虽然 B 站未在 Web 前端界面展示 IP 属地信息，但相关数据实际上
//      仍存在于后端接口及前端组件内。本脚本的工作原理是：在评论组件
//      渲染时，将 IP 属地数据注入到 DOM 中。"
//   → 它的做法是 hook 前端组件注入 DOM，**不是**改 credentials。
//   → 它能在"未登录"下工作，是因为 Web 端匿名请求**其实能拿到**
//     reply_control.location —— 只是前端 UI 不渲染它。
//
//   这与之前 chaoy1 项目注释"匿名返回空字符串"矛盾。
//   必须实测裁决。
//
// 关键差异：此前我一直用 api.bilibili.com + wbi 签名。
// 而 B站 Web 前端实际用的是**同一个域名但不同路径组合**，
// 且会带一套 `dm_*` 参数与 `buvid3/buvid4/_uuid` 指纹。
// 更重要的是：**pagination_str 的 mode 与 plat 组合**。
//
// 本脚本穷举"匿名下所有可能影响 location 的请求维度"，
// 每个维度单独对比，找出到底是哪个维度决定 location。

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

// ---------- 设备指纹 ----------
const spi = await (await fetch('https://api.bilibili.com/x/frontend/finger/spi', {
  headers: { 'user-agent': UA },
})).json();
const b3 = spi.data.b_3, b4 = spi.data.b_4;
const uuid = crypto.randomUUID().toUpperCase() + 'infoc';
const FP = `buvid3=${b3}; buvid4=${b4}; b_nut=${Math.floor(Date.now() / 1000)}; ` +
  `_uuid=${uuid}; buvid_fp=${crypto.createHash('md5').update(uuid).digest('hex')}; ` +
  `CURRENT_FNVAL=4048; buvid_fp_plain=undefined`;

// ---------- 取视频 ----------
const pop = await (await fetch('https://api.bilibili.com/x/web-interface/popular?ps=3&pn=1', {
  headers: { 'user-agent': UA, referer: 'https://www.bilibili.com/' },
})).json();
const v = pop.data.list[0];
const aid = v.aid;
console.log(`视频 aid=${aid}  评论=${v.stat.reply}`);
console.log(`标题: ${v.title.slice(0, 36)}`);
console.log('');

const wbiKey = await getWbiKey();
console.log('wbi_key =', wbiKey);
console.log('');

// dm_* 参数（Web 前端实际会带）
const dm = {
  dm_img_list: '[]',
  dm_img_str: Buffer.from('WebGL 1.0 (OpenGL ES 2.0 Chromium)').toString('base64'),
  dm_cover_img_str: Buffer.from('ANGLE (Intel, Intel(R) UHD Graphics 630 Direct3D11 vs_5_0 ps_5_0), or similar').toString('base64'),
  dm_img_inter: '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
};

async function probe(label, params, { cookie = '', referer, extraHeaders = {} } = {}) {
  const q = sign(params, wbiKey);
  const url = `https://api.bilibili.com/x/v2/reply/wbi/main?${q}`;
  const headers = {
    'user-agent': UA,
    referer: referer || `https://www.bilibili.com/video/${v.bvid}`,
    accept: 'application/json, text/plain, */*',
    'accept-language': 'zh-CN,zh;q=0.9',
    ...extraHeaders,
  };
  if (cookie) headers.cookie = cookie;

  const r = await fetch(url, { headers });
  const text = await r.text();
  let code = '?', n = 0, withLoc = 0;
  const samples = [];
  let keySet = '';
  try {
    const j = JSON.parse(text);
    code = j.code;
    const list = j.data?.replies || [];
    n = list.length;
    if (list[0]?.reply_control) {
      keySet = Object.keys(list[0].reply_control).join(',');
    }
    for (const rep of list) {
      const loc = rep.reply_control?.location;
      if (loc) { withLoc++; if (samples.length < 2) samples.push(loc); }
    }
  } catch {}
  const flag = withLoc > 0 ? `  ★ ${samples.join(', ')}` : '';
  console.log(
    `  ${label.padEnd(42)} code=${String(code).padEnd(5)} n=${String(n).padEnd(3)} loc=${withLoc}${flag}`
  );
  if (keySet) console.log(`      keys: [${keySet}]`);
  return { code, n, withLoc, samples, keySet };
}

console.log('=== 维度 1：Cookie 有无（同参数同签名）===');
const base = { oid: aid, type: 1, mode: 3, pagination_str: '{"offset":""}', plat: 1, web_location: 1315875 };
await probe('无 Cookie', base);
await probe('仅设备指纹', base, { cookie: FP });
await probe('设备指纹 + dm_* 参数', { ...base, ...dm }, { cookie: FP });

console.log('');
console.log('=== 维度 2：mode 值（3=热门 2=最新 0=?) ===');
for (const mode of [0, 2, 3]) {
  await probe(`mode=${mode} + 指纹 + dm`, { ...base, mode, ...dm }, { cookie: FP });
}

console.log('');
console.log('=== 维度 3：plat / web_location ===');
for (const [plat, wl] of [[1, 1315875], [2, 1315875], [1, 333.788], [2, 333.788]]) {
  await probe(`plat=${plat} wl=${wl}`, { ...base, plat, web_location: wl, ...dm }, { cookie: FP });
}

console.log('');
console.log('=== 维度 4：旧接口 /x/v2/reply（不带 wbi）===');
{
  const url = `https://api.bilibili.com/x/v2/reply?type=1&oid=${aid}&pn=1&ps=20&sort=2&web_location=333.788`;
  const r = await fetch(url, {
    headers: {
      'user-agent': UA,
      referer: `https://www.bilibili.com/video/${v.bvid}`,
      cookie: FP,
      accept: 'application/json, text/plain, */*',
    },
  });
  const j = await r.json();
  const list = j.data?.replies || [];
  let withLoc = 0;
  for (const rep of list) if (rep.reply_control?.location) withLoc++;
  console.log(`  旧接口 reply             code=${j.code} n=${list.length} loc=${withLoc}`);
  if (list[0]?.reply_control) {
    console.log(`      keys: [${Object.keys(list[0].reply_control).join(',')}]`);
  }
}

console.log('');
console.log('=== 维度 5：二级评论 /x/v2/reply/reply ===');
{
  const root = (await (await fetch(
    `https://api.bilibili.com/x/v2/reply/main?type=1&oid=${aid}&mode=3&next=0&ps=20`,
    { headers: { 'user-agent': UA, referer: `https://www.bilibili.com/video/${v.bvid}`, cookie: FP } }
  )).json()).data?.replies?.find((x) => x.rcount > 0);
  if (root) {
    const url = `https://api.bilibili.com/x/v2/reply/reply?oid=${aid}&type=1&root=${root.rpid}&ps=10&pn=1&web_location=333.788`;
    const j = await (await fetch(url, {
      headers: { 'user-agent': UA, referer: `https://www.bilibili.com/video/${v.bvid}`, cookie: FP },
    })).json();
    const list = j.data?.replies || [];
    let withLoc = 0;
    for (const rep of list) if (rep.reply_control?.location) withLoc++;
    console.log(`  二级评论 root=${root.rpid}  code=${j.code} n=${list.length} loc=${withLoc}`);
    if (list[0]?.reply_control) {
      console.log(`      keys: [${Object.keys(list[0].reply_control).join(',')}]`);
    }
  } else {
    console.log('  没找到有二级评论的根评论');
  }
}

console.log('');
console.log('=== 维度 6：伪造 SESSDATA（验证是否只认"有效"登录态）===');
await probe('伪造 SESSDATA', base, {
  cookie: FP + '; SESSDATA=forged-value-not-signed; bili_jct=forged; DedeUserID=1',
});

console.log('');
console.log('=== 维度 7：Web 前端真实 UA + Sec-Fetch 全套 ===');
await probe('完整浏览器请求头', { ...base, ...dm }, {
  cookie: FP,
  extraHeaders: {
    'sec-ch-ua': '"Chromium";v="134", "Not:A-Brand";v="24"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-site',
    origin: 'https://www.bilibili.com',
  },
});

console.log('');
console.log('=== 判定 ===');
console.log('  若所有匿名组合 loc 恒为 0，而 GitHub 项目能免登录显示，');
console.log('  则说明它们拿到的 location 来自**页面已登录的会话**，');
console.log('  或来自前端组件内已有的数据（非本次请求）。');
console.log('  若某组合 loc > 0，则找到了真正的匿名路径。');
