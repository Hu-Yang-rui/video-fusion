// vf_dy_imfetch_body.mjs — /webcast/im/fetch/ 响应体到底是什么（回答"缺什么才收得到帧"）
//
// 分歧点：我先前实测 im/fetch 恒为 `{"data":[],"status_code":0}`（27B）。
// 另一 agent 报：基线 200/10211B、带 signature= 200/44B、带伪签名 200/252B。
// 长度差异必然来自**参数集不同**（他可能带了完整 web 参数 + cursor/internal_ext）。
// 本脚本把参数逐个加回，打印每次的 body 长度与结构（key 树，不打印可疑值），
// 目标是回答：
//   1) 哪种参数组合能拿到非空 data？
//   2) 非空时结构是不是 general_msg_list / 消息数组？
//   3) 带 signature 与不带的差别（是否 signature 让服务端进入另一分支）
//
// 运行：node tool/vf_dy_imfetch_body.mjs
import fs from 'node:fs';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';

async function feed() {
  for (let i = 1; i <= 12; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return [];
}
/** 打印结构（key + 类型 + 长度），不打印任何可能是 token 的值 */
function shape(node, d = 0, maxD = 4) {
  if (node === null) return 'null';
  if (Array.isArray(node)) return node.length === 0 ? 'Array(0)' : (d >= maxD ? `Array(${node.length})` : `Array(${node.length})[${shape(node[0], d + 1, maxD)}]`);
  if (typeof node === 'object') {
    if (d >= maxD) return `Object{${Object.keys(node).length}}`;
    const parts = Object.entries(node).slice(0, 22).map(([k, v]) => {
      if (/signature|token|ticket|cookie|secret/i.test(k)) return `${k}:<${typeof v}${typeof v === 'string' ? ' len=' + v.length : ''}>`;
      return `${k}:${shape(v, d + 1, maxD)}`;
    });
    return `{${parts.join(', ')}}`;
  }
  if (typeof node === 'string') return `str(${node.length})${node.length <= 24 ? ':' + JSON.stringify(node) : ''}`;
  return typeof node + '(' + node + ')';
}
async function get(url, headers) {
  try {
    const r = await fetch(url, { headers });
    const t = await r.text();
    let j = null; try { j = JSON.parse(t); } catch {}
    return { status: r.status, len: t.length, json: j, raw: t.slice(0, 120) };
  } catch (e) { return { status: 0, len: 0, err: `${e.name}` }; }
}

console.log('=== vf_dy_imfetch_body ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0], rid = room.id_str, uid = room.owner?.id_str;
const T = Date.now();
console.log(`房间=${rid} owner=${uid}\n`);

const cases = [
  ['裸路径（无参数）', `https://webcast.amemv.com/webcast/im/fetch/`, WEBQ.slice(0, 0)],
  ['web 基础参数', WEBQ, ''],
  ['web + room_id', WEBQ, `&room_id=${rid}`],
  ['web + room_id + user_unique_id', WEBQ, `&room_id=${rid}&user_unique_id=${uid}`],
  ['web + need_persist_msg_count', WEBQ, `&room_id=${rid}&user_unique_id=${uid}&need_persist_msg_count=15`],
  ['web + cursor + internal_ext', WEBQ, `&room_id=${rid}&user_unique_id=${uid}&cursor=0&internal_ext=internal_src:dim|wss_push_room_id:${rid}|wss_push_did:${uid}|fetch_time:${T}|seq:1`],
  ['完整 wss 同款参数', WEBQ, `&room_id=${rid}&user_unique_id=${uid}&identity=audience&endpoint=live_pc&support_wrds=1&im_path=/webcast/im/fetch/&live_id=1&did_rule=3&need_persist_msg_count=15&cursor=d-1_u-1_t-${T}_r-1&internal_ext=internal_src:dim|wss_push_room_id:${rid}|wss_push_did:${uid}|fetch_time:${T}|seq:1`],
  ['同上 + 伪 signature', WEBQ, `&room_id=${rid}&user_unique_id=${uid}&identity=audience&endpoint=live_pc&need_persist_msg_count=15&signature=${'a'.repeat(32)}`],
  ['同上 + signature=空串', WEBQ, `&room_id=${rid}&user_unique_id=${uid}&signature=`],
  ['App 参数集', APPQ, `&room_id=${rid}`],
  ['App 参数 + 完整字段', APPQ, `&room_id=${rid}&user_unique_id=${uid}&identity=audience&need_persist_msg_count=15`],
];
const out = [];
for (const [label, base, extra] of cases) {
  const url = `https://webcast.amemv.com/webcast/im/fetch/?${base}${extra}`;
  const r = await get(url, { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', accept: 'application/json' });
  const dataLen = Array.isArray(r.json?.data) ? r.json.data.length : (r.json?.data === undefined ? 'no-data' : typeof r.json?.data);
  console.log(`  ${label.padEnd(32)} HTTP=${r.status} len=${String(r.len).padStart(6)} sc=${r.json?.status_code ?? '-'} data条数=${dataLen}${r.err ? ' ERR' : ''}`);
  if (r.len > 0 && r.len <= 400) console.log(`      body=${JSON.stringify(r.raw)}`);
  if (r.json) console.log(`      结构=${shape(r.json)}`);
  out.push({ label, status: r.status, len: r.len, sc: r.json?.status_code ?? null, dataLen, shape: r.json ? shape(r.json) : r.raw });
}

// POST 形态（抖音 im/fetch 可能是 POST-only；仍只读：不带任何写 body）
console.log('\n── POST 形态（无 body，只探路由）──');
for (const [label, base] of [['web', WEBQ], ['app', APPQ]]) {
  try {
    const r = await fetch(`https://webcast.amemv.com/webcast/im/fetch/?${base}&room_id=${rid}&user_unique_id=${uid}`, {
      method: 'POST', headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/', 'content-type': 'application/json' } });
    const t = await r.text();
    console.log(`  POST ${label} HTTP=${r.status} len=${t.length} body=${JSON.stringify(t.slice(0, 100))}`);
  } catch (e) { console.log(`  POST ${label} ERR ${e.name}`); }
}
fs.writeFileSync('tool/_dy_imfetch_body.json', JSON.stringify({ at: new Date().toISOString(), rid, out }, null, 2), 'utf8');
console.log('\n已写 tool/_dy_imfetch_body.json');
