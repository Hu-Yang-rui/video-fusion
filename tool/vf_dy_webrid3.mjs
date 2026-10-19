// vf_dy_webrid3.mjs — live.douyin.com/<id> HTML 里到底有什么（web_rid 可得性终判）
//
// 上一轮：live.douyin.com/<display_id> 返回 1.28MB HTML，但我的正则全没命中，
// 不能就此断言"拿不到 web_rid"。本探针把这个 HTML **结构化解析**：
//   1) 列出所有 <script id=...> 与 JSON-ish 全局变量名（不打印内容，只列 key）
//   2) 在其中搜房间字段：roomId / web_rid / 房间状态 / 流地址 / user_count
//   3) 若找到 web_rid → 立刻用真 web_rid 打 /webcast/room/web/enter/，给终判
//   4) 若确实拿不到 → 明确报告"feed/HTML 两条路都无法匿名获得 web_rid"
//
// 运行：node tool/vf_dy_webrid3.mjs
import zlib from 'node:zlib';

const UA_APP = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001)';
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const APPQ = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh';
const WEBQ = 'aid=6383&app_name=aweme&channel=channel_id_web&device_platform=web&version_code=180800';

async function feed() {
  for (let i = 1; i <= 10; i++) {
    const r = await fetch(`https://webcast.amemv.com/webcast/feed/?${APPQ}&count=12&offset=0&type=0`, {
      headers: { 'user-agent': UA_APP, referer: 'https://live.douyin.com/' } });
    const t = await r.text();
    if (t.trim()) { const j = JSON.parse(t); return (j.data ?? []).map((e) => e?.data).filter(Boolean); }
    await new Promise((s) => setTimeout(s, 300 * i));
  }
  return [];
}

console.log('=== vf_dy_webrid3: live.douyin.com HTML 结构解析 ===');
const rooms = await feed();
if (!rooms.length) { console.log('feed 无数据'); process.exit(1); }
const room = rooms[0];
const displayId = room.owner?.display_id || String(room.owner?.short_id || '');
console.log(`房间=${room.id_str} nickname=${JSON.stringify(room.owner?.nickname)} display_id=${JSON.stringify(displayId)}`);

async function loadHtml(url) {
  const r = await fetch(url, { headers: {
    'user-agent': UA_WEB, 'accept-language': 'zh-CN,zh;q=0.9', 'accept-encoding': 'gzip, deflate',
    referer: 'https://live.douyin.com/',
  } });
  const buf = Buffer.from(await r.arrayBuffer());
  let txt = '';
  if (buf[0] === 0x1f && buf[1] === 0x8b) { try { txt = zlib.gunzipSync(buf).toString('utf8'); } catch { txt = buf.toString('latin1'); } }
  else txt = buf.toString('utf8');
  return { status: r.status, ct: r.headers.get('content-type'), url: r.url, txt, len: txt.length,
    cookies: (r.headers.getSetCookie?.() ?? []).map((c) => c.split('=')[0]) };
}

for (const url of [`https://live.douyin.com/${displayId}`, `https://live.douyin.com/${room.id_str}`]) {
  console.log(`\n──── GET ${url}`);
  let h;
  try { h = await loadHtml(url); } catch (e) { console.log(`  ERR ${e.name}: ${e.message}`); continue; }
  console.log(`  HTTP=${h.status} ct=${h.ct} html长度=${h.len} final=${h.url.slice(0, 80)}`);
  console.log(`  set-cookie 名称(不打印值): ${JSON.stringify(h.cookies)}`);

  // 1) script 标签 id / 全局变量名
  const scriptIds = [...new Set((h.txt.match(/<script[^>]*\bid="([^"]+)"/g) ?? []).map((s) => s.replace(/.*id="/, '').replace(/"$/, '')))];
  console.log(`  <script id> 列表: ${JSON.stringify(scriptIds)}`);
  const globals = [...new Set((h.txt.match(/window\.([A-Za-z_$][\w$]*)\s*=/g) ?? []).map((s) => s.slice(7, -1).trim()))];
  console.log(`  window.* 全局变量名: ${JSON.stringify(globals.slice(0, 25))}`);

  // 2) 房间字段是否存在（只报命中与否 + 附近 key 名，不打印值）
  const keys = ['web_rid', 'roomId', 'room_id', 'user_count', 'status', 'stream_url', 'hls_pull_url',
    'pull_hls', 'nickname', 'signature', 'user_unique_id', 'wss', 'im_path', 'InternalExt'];
  for (const k of keys) {
    const i = h.txt.indexOf(k);
    console.log(`    ${k.padEnd(16)} ${i >= 0 ? `出现（首次 index=${i}）` : '未出现'}`);
  }

  // 3) 解析 RENDER_DATA / 其它 JSON island
  for (const id of scriptIds) {
    const m = h.txt.match(new RegExp(`<script[^>]*id="${id}"[^>]*>([\\s\\S]*?)</script>`));
    if (!m) continue;
    let raw = m[1].trim();
    // RENDER_DATA 常是 URL-encoded JSON
    if (id === 'RENDER_DATA') { try { raw = decodeURIComponent(raw); } catch {} }
    let obj = null; try { obj = JSON.parse(raw); } catch {}
    console.log(`    script#${id}: raw=${m[1].length}B JSON=${obj ? '可解析' : '不可解析'}`);
    if (obj) {
      const paths = [];
      const walk = (o, p, d) => {
        if (d > 6 || paths.length > 60) return;
        if (o && typeof o === 'object') {
          for (const [k, v] of Object.entries(o)) {
            if (/web_rid|roomId|room_id|user_count|stream_url|status$/i.test(k)) paths.push(`${p}.${k}=${typeof v === 'object' ? '<obj>' : JSON.stringify(v)?.slice(0, 24)}`);
            if (v && typeof v === 'object') walk(v, `${p}.${k}`, d + 1);
          }
        }
      };
      walk(obj, id, 0);
      console.log(`      命中房间字段路径(${paths.length}): ${paths.slice(0, 18).join(' | ')}`);
      const wr = paths.find((x) => /\.web_rid=/.test(x));
      if (wr) {
        const v = wr.split('=')[1];
        if (v && /^\d+$/.test(v)) {
          console.log(`      → 抽到 web_rid=${v}，立刻用真值打 enter/`);
          for (const host of ['webcast.amemv.com', 'live.douyin.com']) {
            try {
              const rr = await fetch(`https://${host}/webcast/room/web/enter/?${WEBQ}&web_rid=${v}&enter_from=web_live&publish_video_strategy_type=2`,
                { headers: { 'user-agent': UA_WEB, referer: 'https://live.douyin.com/' } });
              const t = await rr.text();
              let j = null; try { j = JSON.parse(t); } catch {}
              console.log(`        ${host} HTTP=${rr.status} len=${t.length} status_code=${j?.status_code} msg=${JSON.stringify(j?.status_msg ?? null)} data=${j?.data ? Object.keys(j.data).join(',').slice(0, 50) : '-'}`);
            } catch (e) { console.log(`        ${host} ERR ${e.name}`); }
          }
        }
      }
    }
  }
}

console.log('\n── 终判：匿名能否拿到 web_rid ──');
console.log('  见上方"web_rid 未出现/出现"与 enter/ 结果，按实际输出下结论。');
