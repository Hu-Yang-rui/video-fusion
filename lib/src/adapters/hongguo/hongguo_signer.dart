/// 红果请求签名器。
///
/// 产出六个签名头：
///
///  - `x-khronos`：时间戳
///  - `x-ladon`：时间戳大端 base64
///  - `x-argus`：时间戳小端 base64
///  - `x-gorgon`：query + body 的 RC4 混淆签名
///  - `x-helios`：基于时间戳的链式摘要
///  - `x-medusa`：完整设备身份 + 请求摘要的加密载荷
///
/// # 关键约束
///
/// 设备标识只能用一次。同一对 `iid`/`device_id` 连续复用会被服务端
/// 静默封锁（返回 HTTP 200 + 空 body），表现为「请求成功但没数据」。
///
/// `_rticket` 需要试最多 128 次，直到 `branch()` 返回 0。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'aes_v3.dart';
import 'signer_bytes.dart';
import 'signer_tables.dart';
import 'sm3.dart';

/// 一次签名请求的结果。
class SignedRequest {
  const SignedRequest({required this.url, required this.headers, this.body});

  final String url;
  final Map<String, String> headers;
  final Uint8List? body;
}

/// 红果签名器。
class HongguoSigner {
  HongguoSigner({Random? random, DateTime Function()? clock})
    : _random = random ?? Random.secure(),
      _clock = clock ?? DateTime.now;

  final Random _random;
  final DateTime Function() _clock;

  /// 当前毫秒时间戳。
  int get _nowMs => _clock().millisecondsSinceEpoch;

  /// 32 位随机数。
  ///
  /// 必须走 `nextDouble()` 再放大，不能直接 `nextInt(2^32)`：
  /// 后者在 Dart 里消耗的随机序列与 `nextDouble()` 不同，
  /// 会导致后续所有随机量的位置错位。
  int _rand() => (_random.nextDouble() * 4294967296.0).toInt() & 0xFFFFFFFF;

  // ── 内部：取模 / 位运算 ─────────────────────────────────────

  int _getIv(int initial, List<int> data) {
    var value = initial;
    for (var i = 0; i < data.length; i++) {
      final d = data[i] & 0xFF;
      if (i & 1 == 0) {
        value = ((value >> 4) ^ value ^ (value << 6) ^ d) & 0xFFFFFFFF;
      } else {
        value = ((value >> 7) ^ value ^ (d | (value << 12))) & 0xFFFFFFFF;
        value = (~value) & 0xFFFFFFFF;
      }
    }
    return value;
  }

  int _iv(List<int> query, List<int> body, int ts) =>
      _getIv(_getIv(_getIv(0x20230928, query), body), le32(ts));

  /// 分支号：必须是 0 才能用这个 `_rticket`。
  int branch(String query, Uint8List? body, int ts) {
    final q = sm3(utf8.encode(query));
    final b = body != null ? md5(body) : Uint8List(16);
    return (_iv(q, b, ts) & 15) % 3;
  }

  int _sumMd5(List<int> data) {
    var check = 0x20220420;
    for (var i = 0; i < 12; i++) {
      final temp = ((check >> (i & 1 == 0 ? 3 : 5)) ^ check) & 0xFFFFFFFF;
      if (i & 1 == 0) {
        check = ((data[i] & 0xFF) ^ (check << 7)) & 0xFFFFFFFF;
      } else {
        check = (~((data[i] & 0xFF) | (check << 11))) & 0xFFFFFFFF;
      }
      check = (check ^ temp) & 0xFFFFFFFF;
    }
    return ((check | 4) ^ 0x1000000) & 0xFFFFFFFF;
  }

  // ── hashF13 ─────────────────────────────────────────────────

  /// 核心哈希。
  Uint8List hashF13(List<int> query, List<int> body, int ts) {
    final ivValue = _iv(query, body, ts);
    final index = (ivValue & 15) ~/ 3;
    if ((ivValue & 15) % 3 != 0) {
      throw StateError('Unsupported hash branch');
    }

    const ivV1Table = <int>[
      0xC4A78580,
      0xB3C0FD39,
      0xC58C5686,
      0xC9AA3BA7,
      0xF5A7ADF2,
      0x963C2ED1,
    ];
    final ivV1 = ivV1Table[index];
    final count = (ivV1 + ts) & 0xFFFFFFFF;

    final tt = signerHashTable
        .map((v) => ror(v, (count + 1) & 255))
        .toList(growable: false);

    final shift = (count + 2) & 7;
    final pad = <int>[
      0xFA,
      0x45,
      0x61,
      0xD7,
    ].map((v) => (((v | (v << 8)) >> shift)) & 0xFF).toList();

    final data = concat([
      query,
      body,
      le32(ts),
      Uint8List.fromList(pad),
      hex('00000000000001a0'),
    ]);

    // 字节序：上游 i32() 默认大端，这里必须一致。
    final di = <int>[];
    for (var i = 0; i < data.length; i += 4) {
      di.add(i32(data, i));
    }
    for (var i = 0; i < 112; i++) {
      final x = di[i + 1];
      final y = di[i + 14];
      final v =
          (di[i] +
              di[i + 9] +
              (rol(x, 14) ^ rol(x, 25) ^ ((x & 0xFFFFFFFF) >> 3)) +
              (rol(y, 13) ^ rol(y, 15) ^ ((y & 0xFFFFFFFF) >> 10))) &
          0xFFFFFFFF;
      di.add(v);
    }

    const initialBase = <int>[
      0x7ABA4FC8,
      0x67166507,
      0x6403FA00,
      0x340F512F,
      984304912,
      3005047866,
      2874125293,
      2152413264,
    ];
    final initial = initialBase
        .map((v) => ror(v, count))
        .toList(growable: false);

    const chosenTable = <List<int>>[
      [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
      [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
      [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
      [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
      [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
      [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
    ];
    final chosen = chosenTable[index];

    final d = List<int>.from(initial);
    for (var i = 0; i < chosen[0]; i++) {
      final base = (ivV1 + i) & 0xFFFFFFFF;

      final n1 =
          (((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]) &
          0xFFFFFFFF;
      final n2 =
          (rol(d[chosen[1]], 26) ^
              rol(d[chosen[1]], 21) ^
              rol(d[chosen[1]], 7)) &
          0xFFFFFFFF;
      final n4 =
          (di[base & 127] + n1 + n2 + tt[base & 63] + d[chosen[5]]) &
          0xFFFFFFFF;
      final n5 =
          (rol(d[chosen[2]], 30) ^
              rol(d[chosen[2]], 19) ^
              rol(d[chosen[2]], 10)) &
          0xFFFFFFFF;
      final n6 =
          ((d[chosen[2]] & d[chosen[6]]) |
              ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]])) &
          0xFFFFFFFF;

      final old = d[chosen[9]];
      // d.add(0, d.removeAt(7))
      final moved = d.removeAt(7);
      d.insert(0, moved);
      d[chosen[10]] = (n5 + n6 + n4) & 0xFFFFFFFF;
      d[chosen[8]] = (old + n4) & 0xFFFFFFFF;
    }

    final ret = <int>[];
    for (var i = 0; i < 8; i++) {
      ret.addAll(be32((d[i] + initial[i]) & 0xFFFFFFFF));
    }
    final folded = xorBytes(ret.sublist(0, 16), ret.sublist(16, 32));
    return concat([folded, le32(_sumMd5(folded))]);
  }

  // ── gorgon ──────────────────────────────────────────────────

  /// X-Gorgon。
  String gorgon(String query, Uint8List? body, int ts, int random) {
    final input = concat([
      head(md5(utf8.encode(query)), 4),
      body != null ? head(md5(body), 4) : Uint8List(4),
      Uint8List(4),
      le32(67503104),
      be32(ts),
    ]);

    final key = <int>[
      0x4A,
      0x40,
      0x16,
      (random >> 8) & 255,
      0x47,
      0x6C,
      1,
      random & 255,
    ];

    // 注意：这里不是标准 RC4。
    //
    // 上游实现只做 s[i] = s[j]，没有交换 s[j]。
    // 按标准 RC4 写出来的结果与服务端不一致。
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % 8]) & 255;
      s[i] = s[j];
    }

    // PRGA 同样只做 s[i] = y，不交换。
    j = 0;
    final out = Uint8List(input.length);
    for (var n = 0; n < input.length; n++) {
      final i = n + 1;
      j = (j + s[i]) & 255;
      final y = s[j & 255];
      s[i] = y;
      out[n] = (input[n] & 0xFF) ^ s[(y + y) & 255];
    }

    for (var i = 0; i < out.length; i++) {
      final value = (((out[i] & 0xFF) >> 4) | ((out[i] & 0xFF) << 4)) & 255;
      final next = out[i + 1 < out.length ? i + 1 : 0] & 0xFF;
      final reversed = _reverseBits8((next ^ value) & 255);
      out[i] = (~(reversed ^ 20)) & 0xFF;
    }

    return hexOf(
      concat([
        hex('8404'),
        Uint8List.fromList([random & 0xFF, (random >> 8) & 0xFF, 0x40, 0x01]),
        out,
      ]),
    );
  }

  static int _reverseBits8(int v) {
    var x = v & 0xFF;
    var r = 0;
    for (var i = 0; i < 8; i++) {
      r = (r << 1) | (x & 1);
      x >>= 1;
    }
    return r & 0xFF;
  }

  // ── proto 编码 ──────────────────────────────────────────────

  Uint8List _varint(int value) {
    final out = <int>[];
    var n = value;
    while (n > 127) {
      out.add((n & 127) | 128);
      n = n >> 7;
    }
    out.add(n & 0xFF);
    return Uint8List.fromList(out);
  }

  Uint8List _proto(List<_Field> fields) {
    final out = <int>[];
    for (final f in fields) {
      switch (f.type) {
        case 'sint':
          final n = (f.value as num).toInt();
          out.addAll(_varint(f.tag << 3));
          out.addAll(_varint(n < 0 ? -n * 2 - 1 : n * 2));
        case 'float':
          out.addAll(_varint((f.tag << 3) | 5));
          final bytes = ByteData(4)
            ..setFloat32(0, (f.value as num).toDouble(), Endian.little);
          out.addAll(bytes.buffer.asUint8List());
        default:
          final List<int> bytes;
          if (f.value is List<int>) {
            bytes = f.value as List<int>;
          } else {
            bytes = utf8.encode(f.value.toString());
          }
          if (bytes.isNotEmpty) {
            out.addAll(_varint((f.tag << 3) | 2));
            out.addAll(_varint(bytes.length));
            out.addAll(bytes);
          }
      }
    }
    return Uint8List.fromList(out);
  }

  _Field _f(int tag, Object value, [String type = 'string']) =>
      _Field(tag, value, type);

  // ── deviceProto ─────────────────────────────────────────────

  Uint8List _deviceProto(String deviceId) => _proto([
    _f(1, 1, 'sint'),
    _f(2, 2, 'sint'),
    _f(3, '8662'),
    _f(4, deviceId),
    _f(5, 'Ai6svO3PyrwDOUSmO6ZcResxu'),
    _f(6, '!noperm!'),
    _f(7, -888888, 'sint'),
    _f(8, -888888, 'sint'),
    _f(9, 3, 'sint'),
    _f(10, -888888, 'sint'),
    _f(11, '!notset!'),
    _f(12, 'Asia/Shanghai,8'),
    _f(13, 'zh_CN'),
    _f(14, 4, 'sint'),
    _f(16, 255.24993896484375, 'float'),
    _f(17, 35.58599090576172, 'float'),
    _f(18, 3.467449188232422, 'float'),
    _f(19, 3.467449188232422, 'float'),
    _f(20, 255.1754913330078, 'float'),
    _f(21, 42.17544174194336, 'float'),
    _f(22, '16'),
    _f(23, 41, 'sint'),
    _f(24, 36, 'sint'),
    _f(25, 1728388016635, 'sint'),
    _f(26, 1728388016635, 'sint'),
    _f(27, 1728388016635, 'sint'),
    _f(28, 1728388016637, 'sint'),
    _f(29, -1, 'sint'),
    _f(30, '25053RT47C'),
    _f(31, 'Redmi'),
    _f(32, '25053RT47C'),
    _f(33, '25053RT47C'),
    _f(34, 'Xiaomi'),
    _f(35, 'Redmi'),
    _f(36, 'Redmi'),
    _f(38, 31, 'sint'),
  ]);

  // ── xmxor ───────────────────────────────────────────────────

  Uint8List _xmxor(List<int> data, List<int> key) {
    final encoded = List<int>.filled(data.length, 0);
    for (var i = 0; i < data.length; i++) {
      final at = (i * 4) & 28;
      final d0 = key[at] & 0xFF;
      final d1 = key[at + 1] & 0xFF;
      final v = data[i] & 0xFF;

      var d2 = ((((v << 4) | (v >> 4)) & 255) + d0) & 0xFFFFFFFF;
      d2 = (~d2) ^ d1;
      d2 = (((d2 & 255) << 3) | ((d2 & 255) >> 5)) & 255;
      d2 = (d2 + d1) & 255;
      d2 = (d2 ^ d0) & 255;
      encoded[data.length - i - 1] = (~d2) & 255;
    }

    final last = (encoded.last ^ encoded[encoded.length - 2]) & 0xFF;
    final first = encoded[0];
    encoded[0] = ((~last) + first) & 0xFF;
    encoded[1] = ((encoded[0] ^ encoded.last ^ 254) + encoded[1]) & 0xFF;
    encoded[2] =
        (encoded[2] +
            (((last - first) ^
                ((((encoded[1] << 3) | (encoded[1] >> 5)) & 255)) ^
                2))) &
        0xFF;

    for (var i = 0; i < encoded.length - 4; i++) {
      final temp =
          ((((encoded[i + 2] << 3) | (encoded[i + 2] >> 5)) & 255) ^
              encoded[i + 1] ^
              (i + 3)) &
          0xFF;
      encoded[i + 3] = ((~temp) + encoded[i + 3]) & 0xFF;
    }

    encoded[encoded.length - 1] =
        (encoded.last ^ encoded[encoded.length - 2]) & 0xFF;

    var sum = 0;
    for (var i = 1; i < encoded.length; i++) {
      sum += encoded[i];
    }
    encoded[0] = (((encoded[0] ^ encoded[1]) + sum) & 0xFFFFFFFF) & 0xFF;

    return Uint8List.fromList(encoded.map((e) => e & 0xFF).toList());
  }

  // ── medusa ──────────────────────────────────────────────────

  /// X-Medusa：完整设备身份 + 请求摘要的加密载荷。
  String medusa(
    String url,
    Uint8List? body,
    int ts,
    Map<String, String> device,
  ) {
    final deviceId = _identity(device, 'device_id');
    final version = _identity(device, 'version_name');

    final bodyMd5 = body != null ? md5(body) : Uint8List(16);
    final queryStr = url.contains('?')
        ? url.substring(url.indexOf('?') + 1)
        : '';
    final query = utf8.encode(queryStr);
    final querySm3 = sm3(query);
    final queryBodyTs = hashF13(querySm3, bodyMd5, ts);

    final nested = _proto([
      _f(1, 111, 'sint'),
      _f(2, 10, 'sint'),
      _f(3, 694367, 'sint'),
      _f(5, 586952199, 'sint'),
    ]);

    final messageRand = _rand();
    final envLaunch = (_random.nextDouble() * 21).toInt() + 100;
    final envPid = (_random.nextDouble() * 2000).toInt() + 10001;

    final env = _proto([
      _f(1, envLaunch, 'sint'),
      _f(2, 146331399, 'sint'),
      _f(3, 146331396, 'sint'),
      _f(5, 7, 'sint'),
      _f(6, 'v04.06.04.03-bugfix'),
      _f(7, envPid, 'sint'),
      _f(12, _deviceProto(deviceId)),
      _f(
        13,
        _proto([
          _f(1, _nowMs ~/ 1000, 'sint'),
          _f(2, -2, 'sint'),
          _f(4, 200, 'sint'),
        ]),
      ),
      _f(14, version),
    ]);

    final queryHash = sm3(concat([query, bodyMd5, utf8.encode('none')]));

    final message = _proto([
      _f(1, hex('f7e85ffad7d7dc3bd62ac87057cf6118')),
      _f(2, 3, 'sint'),
      _f(3, messageRand, 'sint'),
      _f(4, '8662'),
      _f(5, deviceId),
      _f(6, '1588093228'),
      _f(7, version),
      _f(8, 'v04.06.04-ml-android'),
      _f(9, 67503104, 'sint'),
      _f(10, hex('4001000000000000')),
      _f(12, ts, 'sint'),
      _f(13, queryBodyTs),
      _f(14, querySm3.sublist(0, 6)),
      _f(15, nested),
      _f(16, 'AXYQOS6n2m60x1fVZHIrH3iol'),
      _f(17, ts, 'sint'),
      _f(19, queryHash),
      _f(20, 'none'),
      _f(21, 312, 'sint'),
      _f(23, env),
      _f(
        24,
        '{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,'
        '"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}',
      ),
    ]);

    final r = _rand();
    final signKey = hex(
      '8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5',
    );
    final hash = sm3(concat([signKey, le32(r), signKey]));
    final d1 = (r >> 16) & 255;
    final seed = le32(
      (~((((d1 << 11) | ((r & 0xFFFFFFFF) >> 24)) ^ (d1 >> 5) ^ d1))) &
          0xFFFFFFFF,
    );

    final xored = _xmxor(message, hash);
    final transformed = reversed(concat([hex('4001000000000000'), xored]));

    for (var i = 0; i < transformed.length; i++) {
      transformed[i] = (transformed[i] & 0xFF) ^ (seed[(~i) & 3] & 0xFF);
    }

    final check =
        (((querySm3[0] & 63) << 14) |
            0x18000001 |
            ((queryBodyTs[0] & 63) << 8)) &
        0xFFFFFFFF;

    final packed = concat([
      Uint8List.fromList([0x35]),
      le32(_rand()),
      le32(check),
      transformed,
      Uint8List.fromList([(r >> 16) & 0xFF, (r >> 24) & 0xFF]),
    ]);

    final encrypted = AesV3(
      hex('f1593376766ea98d34f31b057a9d5be4'),
      ts,
    ).encrypt(packed, hex('1fe109a4125283f418de9e051a969e12'));

    final versionBytes = hex('03000000f7e85ffad7d7dc3bd62ac87057cf6118');
    final prefixParts = <List<int>>[];
    for (var i = 0; i < 20; i += 4) {
      prefixParts.add(le32(i32(versionBytes, i, little: true) ^ ts));
    }
    final prefix = concat(prefixParts);

    return base64Of(
      concat([
        prefix,
        Uint8List.fromList([r & 0xFF, (r >> 8) & 0xFF, 0, 1]),
        encrypted,
      ]),
    );
  }

  String _identity(Map<String, String> device, String key) {
    final value = (device[key] ?? '').trim();
    if (value.isEmpty) {
      throw StateError('设备身份缺失：$key 为空，服务器会静默封锁');
    }
    return value;
  }

  // ── helios ──────────────────────────────────────────────────

  /// X-Helios。
  ///
  /// 全程用 [BigInt] 承载 64 位无符号量：Dart 的 int 有符号，
  /// 高位为 1 的中间值会被当成负数，符号位会污染 XOR 与比较。
  String helios(int ts) {
    final random = _rand();
    final ascii = utf8.encode(
      hexOf(md5(concat([le32(random), utf8.encode('8662')]))),
    );

    // 4 个 64 位字（小端读取）
    final words = <BigInt>[for (var i = 0; i < 4; i++) u64FromLe(ascii, i * 8)];
    final table = <BigInt>[words[0]];

    var b0 = words.removeAt(0);
    var b8 = words.removeAt(0);

    for (var i = 0; i < 34; i++) {
      var x8 = xorU64(addU64(rorU64(b8, 8), b0), BigInt.from(i));
      words.add(x8);
      x8 = xorU64(x8, rorU64(b0, 61));
      table.add(x8);
      b0 = x8;
      b8 = words.removeAt(0);
    }

    final text = utf8.encode('$ts-1588093228-8662');
    final padding = 16 - text.length % 16;
    final data = concat([
      text,
      Uint8List(padding)..fillRange(0, padding, padding),
    ]);

    final output = <int>[...le32(random)];

    for (var at = 0; at < data.length; at += 16) {
      var a = u64FromLe(data, at);
      var b = u64FromLe(data, at + 8);
      for (var i = 0; i < 34; i++) {
        b = xorU64(table[i], addU64(a, rorU64(b, 8)));
        a = xorU64(b, rorU64(a, 61));
      }
      output.addAll(le64u(a));
      output.addAll(le64u(b));
    }

    return base64Of(output);
  }

  // ── sign ────────────────────────────────────────────────────

  /// 签名一次请求。
  ///
  /// [base] 是接口 URL（不带 query）。
  /// [device] 是设备身份 map（会被写进 query 和 x-medusa）。
  /// [body] 是请求体；GET 传 null。
  SignedRequest sign(
    String base,
    Map<String, String> device, {
    Uint8List? body,
  }) {
    _identity(device, 'device_id');
    _identity(device, 'iid');

    final now = _nowMs;
    final ts = now ~/ 1000;

    for (var offset = 0; offset < 128; offset++) {
      final ticket = now + offset;
      final params = <String, String>{
        ...device,
        'ts': ts.toString(),
        '_rticket': ticket.toString(),
      };
      final query = _encodeMap(params);

      if (branch(query, body, ts) == 0) {
        final url = '$base?$query';
        final random = (_random.nextDouble() * 65536).toInt();

        final headers = <String, String>{
          'User-Agent': body != null ? _videoUa : _appUa,
          'Accept': 'application/json; charset=utf-8,application/x-protobuf',
          'x-ss-req-ticket': ticket.toString(),
          'x-tt-request-tag': 't=0;n=0',
          'sdk-version': '2',
          'passport-sdk-version': '50561',
          'x-xs-from-web': '0',
          'x-khronos': ts.toString(),
          'x-ladon': base64Of(be32(ts)),
          'x-argus': base64Of(le32(ts)),
          'x-gorgon': gorgon(query, body, ts, random),
          'x-helios': helios(ts),
          'x-medusa': medusa(url, body, ts, device),
          'x-tt-dt': '',
        };

        if (body != null) {
          headers['Content-Type'] = 'application/json; charset=UTF-8';
          headers['x-vc-bdturing-sdk-version'] = '3.7.2.cn';
          headers['x-ss-stub'] = hexOf(md5(body)).toUpperCase();
        }

        return SignedRequest(url: url, headers: headers, body: body);
      }
    }

    throw StateError('无法生成请求签名（128 次尝试都未命中 branch 0）');
  }

  static const _videoUa =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';

  static const _appUa =
      'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3)';

  static String _encodeMap(Map<String, String> values) => values.entries
      .map((e) => '${_encode(e.key)}=${_encode(e.value)}')
      .join('&');

  static String _encode(String value) =>
      Uri.encodeComponent(value).replaceAll('+', '%20').replaceAll('%7E', '~');
}

class _Field {
  const _Field(this.tag, this.value, this.type);
  final int tag;
  final Object value;
  final String type;
}
