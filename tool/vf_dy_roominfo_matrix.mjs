// 坐实 /webcast/room/info/ 的正确请求形态（参数矩阵）。
//
// 上一版探针拿到 HTTP 200 + len=0，而实测代理报告同端点可得 59KB 完整
// 房间对象。两者不一致必须搞清楚：进直播间若要"区分下播 / 地址失效 /
// 房间不存在"，只有 room/info 的 status_code=30001 能做，feed 里翻找不行。
// 所以这里把参数×UA×域名全组合跑一遍，找出那个能出数据的形态。
const UA_APP =
  'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TP1A.220624.021; Cronet;)';
const UA_WEB =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';
const UA_LIVE =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1';

// 先拿一个真实在播房间号
const feedQ =
  'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701' +
  '&device_type=Pixel7&os_version=13&channel=googleplay&language=zh&count=10&offset=0&type=0';
const feed = await (await fetch(`https://webcast.amemv.com/webcast/feed/?${feedQ}`, {
  headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' },
})).json().catch(() => null);
const room = feed?.data?.find((e) => e?.data?.id_str)?.data;
if (!room) { console.log('feed 没拿到房间，无法继续'); process.exit(1); }
const roomId = room.id_str;
const webRid = room.web_rid || room?.owner?.web_rid || '';
console.log(`样本房间 room_id=${roomId} web_rid="${webRid}" status=${room.status}\n`);

const WEB_Q = [
  'aid=6383', 'app_name=aweme', 'channel=channel_pc_web', 'pc_client_type=1',
  'version_code=170400', 'version_name=17.4.0', 'platform=PC',
];
const APP_Q = [
  'aid=1128', 'app_name=douyin_lite', 'device_platform=android',
  'version_code=400701', 'device_type=Pixel7', 'os_version=13',
  'channel=googleplay', 'language=zh',
];

const cases = [];
for (const [host, path] of [
  ['webcast.amemv.com', '/webcast/room/info/'],
  ['live.douyin.com', '/webcast/room/info/'],
  ['webcast.amemv.com', '/webcast/room/info_by_apps/'],
]) {
  for (const [qname, q] of [['web', WEB_Q], ['app', APP_Q], ['empty', []]]) {
    for (const [pname, param] of [['room_id', `room_id=${roomId}`], ['room_id_str', `room_id_str=${roomId}`]]) {
      for (const [uname, ua] of [['UA_WEB', UA_WEB], ['UA_APP', UA_APP], ['UA_LIVE', UA_LIVE]]) {
        cases.push({ host, path, q: q.join('&'), param, ua: uname, uaVal: ua });
      }
    }
  }
}

const results = [];
for (const c of cases) {
  const url = `https://${c.host}${c.path}?${c.q}${c.q ? '&' : ''}${c.param}`;
  const t0 = Date.now();
  try {
    const r = await fetch(url, { headers: { 'user-agent': c.uaVal, referer: 'https://live.douyin.com/' } });
    const text = await r.text();
    let parsed = null;
    try { parsed = JSON.parse(text); } catch { /* html or empty */ }
    results.push({
      url: `${c.host}${c.path} q=${c.q.split('=')[0]}+${c.q.includes('aid=6383') ? 'web' : c.q.includes('aid=1128') ? 'app' : '-'} ${c.param.split('=')[0]} ${c.ua}`,
      status: r.status,
      len: text.length,
      ct: r.headers.get('content-type'),
      statusCode: parsed?.status_code,
      keys: parsed?.data ? Object.keys(parsed.data).length : 0,
      ms: Date.now() - t0,
    });
  } catch (e) {
    results.push({ url: `${c.host}${c.path} ${c.param} ${c.ua}`, err: String(e).slice(0, 60) });
  }
}

const ok = results.filter((r) => r.keys > 5);
console.log(`=== 成功形态（data 键数 > 5）：${ok.length}/${results.length} ===`);
for (const r of ok.slice(0, 12)) console.log('  ✔', JSON.stringify(r));
console.log('\n=== 失败样本（去重前 14 条）===');
const seen = new Set();
for (const r of results) {
  if (r.keys > 5) continue;
  const k = `${r.status}|${r.len}|${r.statusCode}|${r.err || ''}`;
  if (seen.has(k)) continue;
  seen.add(k);
  console.log('  ✗', JSON.stringify(r));
  if (seen.size > 13) break;
}

// 用成功形态验证：不存在房间的返回、下播房间的返回
if (ok.length) {
  const good = results.find((r) => r.keys > 5);
  console.log('\n(用第一个成功形态复核不存在房间 / 空 body 情况见 vf_dy_roominfo 探针)');
}
