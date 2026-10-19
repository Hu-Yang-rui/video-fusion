// 从 feed 原始响应里把"每个档位的真实宽高"取出来，坐实 stream_orientation 语义。
//
// 为什么不用猜：上一版探针解析 TS 的 SPS 失败（H.265 的 SPS 起始码与
// H.264 不同，我的搜索只覆盖了一部分），所以分辨率不能靠字节判。
// 而 feed 的 stream_url 里**本来就带 width/height/resolution_name**
// （在 _dy_feed_raw.json 里能看到 1920x1440），这是平台自己声明的
// 编码分辨率 —— 比任何字节猜测都权威。
import fs from 'node:fs';

const raw = fs.readFileSync(process.argv[2] || 'tool/_dy_feed_raw.json', 'utf8');
const j = JSON.parse(raw);
const rooms = [];
for (const e of j.data || []) {
  const d = e?.data;
  if (!d || !d.id_str) continue;
  rooms.push(d);
}
console.log(`样本房间数：${rooms.length}\n`);

for (const r of rooms) {
  const su = r.stream_url || {};
  console.log(`room ${r.id_str}`);
  console.log(`  stream_orientation=${su.stream_orientation}  顶层 orientation=${r.orientation}`);
  console.log(`  default_resolution=${su.default_resolution}  candidate=${(su.candidate_resolution || []).join(',')}`);
  console.log(`  h265_enable=${su.h265_enable} video_profile=${su.video_profile}`);
  // resolution_name 是 {档名: 显示名}
  if (su.resolution_name) {
    console.log(`  resolution_name=${JSON.stringify(su.resolution_name)}`);
  }
  // 每档的宽高：抖音把它放在 stream_url 的若干子结构里
  const found = [];
  const walk = (node, path) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      node.forEach((v, i) => walk(v, `${path}[${i}]`));
      return;
    }
    if ('width' in node && 'height' in node) {
      found.push({
        path,
        width: node.width,
        height: node.height,
        name: node.name ?? node.resolution_name ?? node.key ?? undefined,
        rate: node.bitrate ?? undefined,
      });
    }
    for (const [k, v] of Object.entries(node)) walk(v, `${path}.${k}`);
  };
  walk(su, 'stream_url');
  // 房间级也找一遍（有些放在 data 顶层）
  const found2 = [];
  const walk2 = (node, path) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach((v, i) => walk2(v, `${path}[${i}]`)); return; }
    if ('width' in node && 'height' in node) found2.push({ path, width: node.width, height: node.height });
    for (const [k, v] of Object.entries(node)) walk2(v, `${path}.${k}`);
  };
  walk2(r, 'room');

  console.log(`  stream_url 内 width/height 节点：`);
  for (const f of found) {
    const dir = f.height > f.width ? '竖屏' : f.width > f.height ? '横屏' : '方';
    console.log(`    ${f.path}  ${f.width}x${f.height}  ← ${dir}` + (f.name ? `  name=${f.name}` : ''));
  }
  if (!found.length) {
    console.log(`    （无）；房间级 width/height：`);
    for (const f of found2) {
      const dir = f.height > f.width ? '竖屏' : f.width > f.height ? '横屏' : '方';
      console.log(`    ${f.path}  ${f.width}x${f.height}  ← ${dir}`);
    }
    if (!found2.length) console.log('    （整个房间对象里没有任何 width+height 同时存在的节点）');
  }
  // 封面尺寸（另一条方向线索）
  const cov = r.cover?.url_list?.[0] || '';
  console.log(`  cover=${cov.slice(0, 100)}`);
  console.log('');
}
