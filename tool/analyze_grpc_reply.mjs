// Analyze the protobuf MainList response: is the province name a
// standalone field value (i.e. an IP-location field) or just text
// inside a comment body?
//
// Approach: walk the protobuf wire format generically (we do not need
// the .proto to read length-delimited fields), and report every
// length-delimited value that looks like a short place name.

import fs from 'node:fs';
import path from 'node:path';

const dir = path.join('build', 'grpc');
const files = fs.readdirSync(dir).filter((f) => f.includes('MainList'));
if (!files.length) {
  console.error('no MainList response found in build/grpc');
  process.exit(1);
}

const PLACES = new Set([
  '北京', '天津', '上海', '重庆', '河北', '山西', '辽宁', '吉林', '黑龙江',
  '江苏', '浙江', '安徽', '福建', '江西', '山东', '河南', '湖北', '湖南',
  '广东', '海南', '四川', '贵州', '云南', '陕西', '甘肃', '青海', '台湾',
  '内蒙古', '广西', '西藏', '宁夏', '新疆', '香港', '澳门',
  '日本', '美国', '韩国', '英国', '加拿大', '澳大利亚', '新加坡',
  '泰国', '马来西亚', '德国', '法国', '俄罗斯', '意大利', '西班牙',
  '荷兰', '瑞典', '瑞士', '挪威', '丹麦', '芬兰', '波兰', '土耳其',
]);

function readVarint(buf, pos) {
  let result = 0n;
  let shift = 0n;
  while (pos < buf.length) {
    const b = buf[pos++];
    result |= BigInt(b & 0x7f) << shift;
    if ((b & 0x80) === 0) return { value: result, pos };
    shift += 7n;
    if (shift > 63n) break;
  }
  return { value: null, pos };
}

// generic walk: collect all length-delimited payloads
function walk(buf, depth, out, limit = 400000) {
  let pos = 0;
  let guard = 0;
  while (pos < buf.length && guard++ < limit) {
    const start = pos;
    const t = readVarint(buf, pos);
    if (t.value === null) break;
    pos = t.pos;
    const tagv = Number(t.value);
    const field = tagv >> 3;
    const wire = tagv & 7;
    if (field === 0) break;

    if (wire === 0) {
      const v = readVarint(buf, pos);
      if (v.value === null) break;
      pos = v.pos;
    } else if (wire === 2) {
      const l = readVarint(buf, pos);
      if (l.value === null) break;
      pos = l.pos;
      const len = Number(l.value);
      if (len < 0 || pos + len > buf.length) break;
      const slice = buf.subarray(pos, pos + len);
      out.push({ depth, field, value: slice, at: start });
      // try to recurse (nested message) when it does not look like text
      const asText = slice.toString('utf8');
      const isMostlyText =
        slice.length < 200 &&
        /^[\p{L}\p{N}\p{P}\p{Zs}\n\r\t]*$/u.test(asText) &&
        slice.every((b) => b === 9 || b === 10 || b === 13 || b >= 32);
      if (!isMostlyText && depth < 6) {
        walk(slice, depth + 1, out);
      }
      pos += len;
    } else if (wire === 5) {
      pos += 4;
    } else if (wire === 1) {
      pos += 8;
    } else {
      break;
    }
  }
}

const file = files[0];
const raw = fs.readFileSync(path.join(dir, file));
// strip gRPC frame header (5 bytes) if present
let body = raw;
if (raw.length > 5 && raw[0] === 0) {
  const len = raw.readUInt32BE(1);
  if (len === raw.length - 5) body = raw.subarray(5);
}
console.log(`file=${file} raw=${raw.length} body=${body.length}`);

const nodes = [];
walk(body, 0, nodes);
console.log(`length-delimited fields parsed: ${nodes.length}`);

// 1. exact-match place names -> strong signal of a location field
const exact = [];
// 2. place name embedded inside longer text -> probably comment body
const embedded = [];

for (const n of nodes) {
  const text = n.value.toString('utf8');
  if (!text || text.length > 500) continue;
  const trimmed = text.trim();
  if (PLACES.has(trimmed)) {
    exact.push({ field: n.field, depth: n.depth, text: trimmed });
    continue;
  }
  for (const p of PLACES) {
    if (trimmed.includes(p)) {
      embedded.push({
        field: n.field,
        depth: n.depth,
        place: p,
        preview: trimmed.slice(0, 60).replace(/\n/g, ' '),
      });
      break;
    }
  }
}

console.log('');
console.log('=== exact-match place-name values (would indicate a location field) ===');
if (exact.length === 0) {
  console.log('  none');
} else {
  for (const e of exact.slice(0, 30)) {
    console.log(`  field=${e.field} depth=${e.depth} value="${e.text}"`);
  }
}

console.log('');
console.log('=== place name embedded in longer text (comment bodies) ===');
if (embedded.length === 0) {
  console.log('  none');
} else {
  for (const e of embedded.slice(0, 15)) {
    console.log(`  field=${e.field} place=${e.place} text="${e.preview}"`);
  }
}

// 3. what short string fields exist at all (field census)
const census = new Map();
for (const n of nodes) {
  const text = n.value.toString('utf8');
  if (!text || text.length > 40) continue;
  if (!/^[\p{L}\p{N}\p{P}\p{Zs}]+$/u.test(text)) continue;
  const key = `${n.field}`;
  if (!census.has(key)) census.set(key, new Set());
  census.get(key).add(text);
}

console.log('');
console.log('=== short string field census (field -> distinct values, sample) ===');
const rows = [...census.entries()]
  .sort((a, b) => Number(a[0]) - Number(b[0]))
  .slice(0, 25);
for (const [field, set] of rows) {
  const sample = [...set].slice(0, 4).map((s) => s.slice(0, 20)).join(' | ');
  console.log(`  field=${field} distinct=${set.size} sample=[${sample}]`);
}
