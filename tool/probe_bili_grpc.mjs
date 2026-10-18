// Bilibili gRPC/protobuf comment probe (Node 18+, no dependencies).
//
// WHY THIS EXISTS
// ---------------
// Every JSON endpoint returns reply_control WITHOUT `location` for
// anonymous clients (7 request surfaces, 20 videos, 60 comments -> 0).
// But the Android app does not use JSON: it uses gRPC + protobuf.
// protobuf transmits field NUMBERS only, and the server-side message
// definitions may include fields the JSON serializer never emits.
//
// So the question this script answers is:
//   does the protobuf reply payload contain a location field that the
//   JSON API simply does not expose?
//
// We cannot know the exact .proto, so instead of decoding we do a
// byte-level scan of the response for:
//   - ASCII "location" / "region" / "province"
//   - UTF-8 Chinese province names (the actual payload would be a name)
//
// Run:  node tool/probe_bili_grpc.mjs [aid]
//
// Pure ASCII source on purpose.

import http2 from 'node:http2';
import fs from 'node:fs';
import path from 'node:path';

const AID = Number(process.argv[2] || 117427861985029);
const OUT = path.join('build', 'grpc');
fs.mkdirSync(OUT, { recursive: true });

// ---------- protobuf primitives ----------

function varint(value) {
  let v = BigInt(value);
  const out = [];
  while (v >= 0x80n) {
    out.push(Number((v & 0x7fn) | 0x80n));
    v >>= 7n;
  }
  out.push(Number(v));
  return Buffer.from(out);
}

function tag(field, wire) {
  return varint((field << 3) | wire);
}

function varintField(field, value) {
  return Buffer.concat([tag(field, 0), varint(value)]);
}

function bytesField(field, payload) {
  return Buffer.concat([tag(field, 2), varint(payload.length), payload]);
}

// gRPC length-prefixed frame: [compressed:1][len:4 BE][payload]
function grpcFrame(payload) {
  const head = Buffer.alloc(5);
  head.writeUInt8(0, 0);
  head.writeUInt32BE(payload.length, 1);
  return Buffer.concat([head, payload]);
}

// ---------- request bodies ----------

// bilibili.main.community.reply.v1.Reply/MainList
//   int64 oid = 1; int64 type = 2; int32 mode = 3; int32 ps = 4;
function mainListReq(aid, mode, ps) {
  return Buffer.concat([
    varintField(1, aid),
    varintField(2, 1),   // type = 1 (video)
    varintField(3, mode),
    varintField(4, ps),
  ]);
}

// bilibili.app.view.v1.View/View  ->  int64 aid = 1; string bvid = 2;
function viewReq(aid) {
  return varintField(1, aid);
}

// ---------- gRPC call over HTTP/2 ----------

function grpcCall(host, method, payload, timeoutMs = 12000) {
  return new Promise((resolve) => {
    const result = {
      host, method, ok: false, status: null,
      grpcStatus: null, grpcMessage: null,
      bytes: 0, body: Buffer.alloc(0), error: null,
    };
    let client;
    const done = () => {
      try { client && client.close(); } catch { /* ignore */ }
      resolve(result);
    };
    const timer = setTimeout(() => {
      result.error = result.error || 'timeout';
      done();
    }, timeoutMs);

    try {
      client = http2.connect(`https://${host}`, {
        settings: { enablePush: false },
      });
    } catch (e) {
      clearTimeout(timer);
      result.error = `connect: ${e.message}`;
      return resolve(result);
    }

    client.on('error', (e) => {
      clearTimeout(timer);
      result.error = `client: ${e.message}`;
      done();
    });

    let req;
    try {
      req = client.request({
        ':method': 'POST',
        ':path': method,
        'content-type': 'application/grpc',
        'te': 'trailers',
        'user-agent': 'grpc-java-okhttp/1.60.0',
        'grpc-accept-encoding': 'identity',
      });
    } catch (e) {
      clearTimeout(timer);
      result.error = `request: ${e.message}`;
      return done();
    }

    const chunks = [];
    req.on('response', (headers) => {
      result.status = headers[':status'];
    });
    req.on('data', (c) => chunks.push(c));
    req.on('trailers', (t) => {
      if (t['grpc-status'] !== undefined) result.grpcStatus = t['grpc-status'];
      if (t['grpc-message'] !== undefined) {
        result.grpcMessage = decodeURIComponent(String(t['grpc-message']));
      }
    });
    req.on('end', () => {
      clearTimeout(timer);
      result.body = Buffer.concat(chunks);
      result.bytes = result.body.length;
      result.ok = true;
      done();
    });
    req.on('error', (e) => {
      clearTimeout(timer);
      result.error = `stream: ${e.message}`;
      done();
    });

    req.end(grpcFrame(payload));
  });
}

// ---------- scan helpers ----------

const PROVINCES = [
  '北京', '天津', '上海', '重庆', '河北', '山西', '辽宁', '吉林', '黑龙江',
  '江苏', '浙江', '安徽', '福建', '江西', '山东', '河南', '湖北', '湖南',
  '广东', '海南', '四川', '贵州', '云南', '陕西', '甘肃', '青海', '台湾',
  '内蒙古', '广西', '西藏', '宁夏', '新疆', '香港', '澳门',
  '日本', '美国', '韩国', '英国', '加拿大', '澳大利亚', '新加坡',
];

function scan(label, buf) {
  const ascii = buf.toString('latin1');
  const utf8 = buf.toString('utf8');
  const found = [];
  for (const kw of ['location', 'region', 'province', 'ip_label', 'ipLocation']) {
    const n = (ascii.match(new RegExp(kw, 'g')) || []).length;
    if (n) found.push(`${kw}x${n}`);
  }
  // the Chinese word for "IP location"
  const cnShudi = '\u5c5e\u5730';
  const nCn = (utf8.match(new RegExp(cnShudi, 'g')) || []).length;
  if (nCn) found.push(`shudi x${nCn}`);

  const provHits = PROVINCES.filter((p) => utf8.includes(p));
  console.log(
    `  ${label}: bytes=${buf.length} ` +
    `markers=[${found.join(', ') || 'none'}] ` +
    `provinces=[${provHits.join(',') || 'none'}]`
  );
  return { found, provHits };
}

// ---------- main ----------

const HOSTS = ['grpc.biliapi.net', 'app.bilibili.com', 'grpc.bilivideo.com'];
const CALLS = [
  {
    method: '/bilibili.main.community.reply.v1.Reply/MainList',
    label: 'Reply/MainList',
    body: mainListReq(AID, 2, 20),
  },
  {
    method: '/bilibili.app.view.v1.View/View',
    label: 'View/View',
    body: viewReq(AID),
  },
];

console.log(`aid=${AID}`);
console.log('');

let anyHit = false;

for (const host of HOSTS) {
  console.log(`=== ${host} ===`);
  for (const call of CALLS) {
    const r = await grpcCall(host, call.method, call.body);
    if (r.error) {
      console.log(`  ${call.label}: ERROR ${r.error}`);
      continue;
    }
    console.log(
      `  ${call.label}: http=${r.status} grpc-status=${r.grpcStatus ?? '?'}` +
      (r.grpcMessage ? ` msg=${r.grpcMessage}` : '')
    );
    if (r.bytes > 0) {
      const file = path.join(
        OUT,
        `${host.replace(/\./g, '_')}-${call.label.replace(/\//g, '_')}.bin`
      );
      fs.writeFileSync(file, r.body);
      const { found, provHits } = scan(call.label, r.body);
      if (found.length || provHits.length) anyHit = true;
    }
  }
  console.log('');
}

// ---------- also: does View/View work at all? dump readable strings ----------

const probe = await grpcCall(HOSTS[0], CALLS[1].method, CALLS[1].body);
if (probe.bytes > 0) {
  const utf8 = probe.body.toString('utf8');
  const strings = utf8.match(/[\u4e00-\u9fa5]{2,}/g) || [];
  const uniq = [...new Set(strings)].slice(0, 15);
  console.log('=== sample Chinese strings in View/View payload ===');
  console.log(uniq.join(' | ') || '(none)');
}

console.log('');
console.log(anyHit
  ? 'RESULT: markers found -- inspect build/grpc/*.bin'
  : 'RESULT: no location/region marker and no province name in any gRPC payload');
