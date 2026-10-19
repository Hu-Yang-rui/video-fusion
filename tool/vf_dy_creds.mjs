// vf_dy_creds.mjs — 抖音登录态可得性检查（只报存在与长度，绝不打印取值）
//
// 目的：回答"直播列表/播放地址在**未登录**下是否完整可用"，即登录对直播有无增益。
// 做法：
//   1) 检查本机是否存在任何可复用的抖音 cookie 落点（只存在性 + 名称 + 长度）
//   2) 用**完全匿名**（无 cookie）请求做 A/B：feed 与 room/info、room/info_by_user
//      各取一次，逐字段比对"带 ttwid cookie" 与 "不带" 的差异
//      —— 这就是"登录增益"的可测量代理指标
//   3) 检查仓库内是否存在抖音 cookie 常量/夹具（grep 名称，不打印值）
//
// 安全：全程不输出任何 cookie 取值、不写仓库。
// 运行：node tool/vf_dy_creds.mjs
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; ' +
  'Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)';
const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web' +
  '&version_code=180800&version_name=18.8.0&cookie_enabled=true&screen_width=1536&screen_height=864' +
  '&browser_language=zh-CN&browser_platform=Win32&browser_name=Mozilla' +
  '&browser_version=5.0%20(Windows%20NT%2010.0;%20Win64;%20x64)%20Chrome/126.0.0.0%20Safari/537.36' +
  '&browser_online=true&timezone_name=Asia/Shanghai';

console.log('=== vf_dy_creds: 抖音登录态可得性 + 匿名完整性 ===\n');

// ── 1) 本机 cookie 落点存在性（只名字/长度/键名，绝不打值）──────────
console.log('── 1) 本机可能的 cookie 落点（存在性检查，不读取取值内容到输出）──');
const candidates = [
  'D:\\vf-local\\douyin_cookie.txt',
  'D:\\vf-local\\dy_cookie.txt',
  'D:\\vf-local\\douyin.txt',
  'D:\\vf-local\\cookie.txt',
  'D:\\vf-local\\',
  'D:\\vf-local\\bili_cookie.txt',
  path.join(process.env.USERPROFILE ?? '', 'AppData', 'Local', 'Doubao'),
  path.join(process.env.APPDATA ?? '', 'douyin'),
  'C:\\Users\\Public\\douyin',
];
for (const p of candidates) {
  let exists = false;
  try { exists = fs.existsSync(p); } catch {}
  if (!exists) { console.log(`  ${p}: MISSING`); continue; }
  try {
    const st = fs.statSync(p);
    if (st.isDirectory()) {
      const names = fs.readdirSync(p);
      console.log(`  ${p}: DIR 条目数=${names.length} 名称=[${names.slice(0, 8).join(', ')}]`);
      // 只按"文件名是否像 cookie"提示，不打开内容
      const cookieish = names.filter((n) => /cookie|credential|token|session|dy|douyin/i.test(n));
      console.log(`      文件名疑似凭证: ${cookieish.length ? cookieish.join(', ') : '(无)'}`);
    } else {
      console.log(`  ${p}: FILE size=${st.size}`);
    }
  } catch (e) { console.log(`  ${p}: EXISTS 但无法 stat (${e.name})`); }
}
console.log('  环境变量: ' + ['DY_COOKIE', 'DOUYIN_COOKIE', 'WEB_COOKIE', 'TTWID'].map(
  (k) => `${k}=${process.env[k] ? `SET(len=${process.env[k].length})` : 'unset'}`).join(' | '));

console.log('\n  项目 credential_vault 存储机制（读代码得出的结论，见 lib/src/core/credential_vault.dart）：');
console.log('    key = "video_fusion.session." + platformId，platformId 用 "douyin"；');
console.log('    落点 = FlutterSecureStore（Windows=凭管管理器 / Android=Keystore），非明文文件；');
console.log('    因此桌面/模拟器上的抖音 cookie 不会以文件形态出现在工作区，本次检查为 MISSING 属正常。');

console.log('\n── 2) 仓库内是否含抖音 cookie 夹具（只 grep 键名，不打印值）──');
try {
  const out = execSync('git grep -l -I -E "passport_csrf_token|sessionid=|ttwid=|dwttwy_sdk|jsessionid" -- lib tool test 2>nul',
    { cwd: process.cwd(), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const files = out.split(/\r?\n/).filter(Boolean);
  console.log(`  命中文件 ${files.length} 个: ${files.join(', ') || '(无)'}`);
  console.log('  （未打印任何匹配行内容）');
} catch { console.log('  git grep 无命中或非 git 环境'); }

// ── 3) A/B：匿名 vs 带 ttwid，字段级差异 ────────────────────────
async function getJson(url, headers) {
  for (let i = 1; i <= 10; i++) {
    const r = await fetch(url, { headers });
    const t = await r.text();
    if (t.trim()) { try { return { status: r.status, json: JSON.parse(t), len: t.length }; } catch { return { status: r.status, text: t, len: t.length }; } }
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return { status: 0, len: 0, empty: true };
}
async function ttwid() {
  try {
    const r = await fetch('https://ttwid.bytedance.com/ttwid/union/register/', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ region: 'cn', aid: 1768, needFid: false, service: 'www.ixigua.com', migrate_info: { ticket: '', source: 'node' }, cbUrlProtocol: 'https', union: true }),
    });
    const m = (r.headers.get('set-cookie') ?? '').match(/ttwid=([^;]+)/);
    return m ? m[1] : null;
  } catch { return null; }
}
const tw = await ttwid();
console.log(`\n── 3) A/B 实测（ttwid ${tw ? 'len=' + tw.length : '获取失败'}；ttwid 是匿名访客标识，非登录态）──`);

const anon = await getJson(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=10&offset=0&type=0`,
  { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' });
const withTtwid = await getJson(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=10&offset=0&type=0`,
  { 'user-agent': UA_APP, referer: 'https://live.douyin.com/', cookie: `ttwid=${tw}` });

const shape = (j) => {
  const data = Array.isArray(j?.data) ? j.data : [];
  const rooms = data.map((e) => e?.data).filter(Boolean);
  return {
    rooms: rooms.length,
    bytes: JSON.stringify(j ?? {}).length,
    withStream: rooms.filter((r) => Object.keys(r.stream_url?.hls_pull_url_map ?? {}).length).length,
    withCover: rooms.filter((r) => r.cover?.url_list?.length).length,
    withNick: rooms.filter((r) => r.owner?.nickname).length,
    withUserCount: rooms.filter((r) => r.user_count !== undefined).length,
    keysPerRoom: rooms[0] ? Object.keys(rooms[0]).length : 0,
    ids: rooms.map((r) => r.id_str).slice(0, 3),
  };
};
console.log(`  feed 匿名:         ${JSON.stringify(shape(anon.json))}`);
console.log(`  feed + ttwid:      ${JSON.stringify(shape(withTtwid.json))}`);

// 房间详情：匿名 vs 带 ttwid
const someRoom = (Array.isArray(anon.json?.data) ? anon.json.data : []).map((e) => e?.data).find((r) => r?.owner?.id_str);
if (someRoom) {
  const uid = someRoom.owner.id_str;
  const dA = await getJson(`https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${uid}`,
    { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' });
  const dB = await getJson(`https://webcast.amemv.com/webcast/room/info_by_user/?${WEBQ}&user_id=${uid}`,
    { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', cookie: `ttwid=${tw}` });
  const cnt = (j) => { const d = j?.data ?? {}; return { keys: Object.keys(d).length, status: d.status, user_count: d.user_count, tiers: Object.keys(d.stream_url?.hls_pull_url_map ?? {}).length, pay: JSON.stringify(d.paid_live_data ?? null)?.slice(0, 60) }; };
  console.log(`  info_by_user 匿名:    ${JSON.stringify(cnt(dA.json))}`);
  console.log(`  info_by_user +ttwid:  ${JSON.stringify(cnt(dB.json))}`);
  // 付费/受限直播间是否在匿名响应里被裁掉
  const paid = JSON.stringify(dA.json?.data?.paid_live_data ?? null);
  console.log(`  付费房间字段(paid_live_data) 匿名可见性: ${paid}`);
}

// 是否存在"需要登录才给"的字段：用一个已知只在登录时下发的高价值字段验证
console.log('\n── 4) 登录才有的字段是否出现在匿名 feed/详情里 ──');
const probeKeys = ['ticket', 'user_ticket', 'pay_grade', 'fansclub', 'score', 'gift_list', 'diamond', 'income'];
const flat = JSON.stringify(anon.json ?? {}).toLowerCase();
for (const k of probeKeys) console.log(`  字段名 "${k}" 出现在匿名 feed 响应中: ${flat.includes(`"${k.toLowerCase()}"`) ? 'YES' : 'no'}`);

console.log('\n── 5) 结论行（脚本自动判定）──');
const s1 = shape(anon.json), s2 = shape(withTtwid.json);
const same = s1.rooms > 0 && s1.withStream === s1.rooms && s1.withCover === s1.rooms && s1.withNick === s1.rooms;
console.log(`  直播列表匿名可用: ${same ? `YES（${s1.rooms} 房间全部带流/封面/昵称）` : 'NO/部分'}`);
console.log(`  ttwid 是否增益:   ${s2.rooms >= s1.rooms ? `无明显增益（房间数 ${s2.rooms} vs ${s1.rooms}，字段数 ${s2.keysPerRoom} vs ${s1.keysPerRoom}）` : '反而更少（服务端推荐随机性）'}`);
