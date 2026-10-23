/// 抖音 `x-tt-session-dtrait` 的纯 Dart 实现。
///
/// # 这是什么（实测 2026-10-23）
///
/// passport 登录接口要求请求头 `x-tt-session-dtrait`（600+ 字符）。
/// 它是**设备特征自证**：把一份设备档案编码成 blob，用 RSA 加密的
/// AES 密钥封起来，随每个请求发出。缺了它，`check_qrconnect` 返回
/// `4031`「已阻止此次访问」。
///
/// # 为什么能纯算法复现（关键）
///
/// 我原以为它依赖真实 GPU/canvas 渲染，因此不可能伪造。查
/// `cv-cat/catbus` 的 `dtrait.ts` 后确认：**渲染类特征以 murmur3
/// 哈希固化在档案 JSON 里**（`render_hashes`），运行时不需要渲染。
///
/// 原注释：
/// > canvas / WebGL / audio / 字体像素这类特征必须真实渲染，
/// > 档案里直接存 murmur3 结果（render_hashes）；其余由档案字段现算。
///
/// 所以只要有一份固化档案 + 纯算法，就能算出与真机一致的 blob。
///
/// # 结构（逆自 `@byted/uc-secure-dtrait-core`）
///
/// ```
/// blob = [1 字节头][bool 位图][34 × 5 字节字符串特征段]
/// 头   = (reserved<<6) | (dtraitType<<5) | (accessType<<4) | version
/// 段   = [tag][murmur3 大端 4 字节]
/// tag  = str_1..str_33 → 32..64，str_34 → 71
/// ```
///
/// 头部 `x-tt-session-dtrait` 的格式：
/// ```
/// d0_<base64(RSA_PKCS1v15(aesKeyHex))>_<base64(iv + AES128CBC(payload))>
/// payload = {"dtrait":<blob>,"timestamp":<秒>,"sdkVersion":"1.0.0.16","path":<path>}
/// ```
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// dtrait 的固定档案（来源：catbus `static/douyin/dtrait_profile.json`）。
///
/// 从 Chrome 153 DevTools 固化的真实设备档案。`render_hashes` 是
/// canvas / WebGL / audio / 字体像素等**必须真实渲染**才能得到的
/// 特征的 murmur3 结果——这里直接复用，所以不需要在设备上渲染。
const String _defaultProfileJson = '''
{
  "source": "real-device-20261017",
  "reserved": 0,
  "dtrait_type": 1,
  "version": 0,
  "bools": {"1": false, "2": false, "3": false, "4": true, "5": false,
            "6": true, "7": true, "8": false, "9": false, "10": false},
  "render_hashes": {"1": 755324578, "2": 3795871487, "3": 3493564185,
    "4": 1207649148, "5": 1383342405, "6": 762554969, "7": 2246935287,
    "8": 2868190146, "9": 2046748658, "10": 500342467, "13": 1189848898,
    "20": 2347868216, "21": 699560564, "22": 308954736, "23": 2240922934,
    "24": 466459917, "25": 1482679892, "26": 3117199483, "33": 1555653270,
    "34": 19522071},
  "downlink": 10,
  "effective_type": "4g",
  "language": "zh-CN",
  "languages": ["zh-CN", "zh", "en", "zh-TW", "ja"],
  "str16_list": [],
  "vendor": "Google Inc.",
  "platform": "Win32",
  "str17_tail": "undefined",
  "str18_list": [],
  "ua": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36",
  "locale": "zh-CN",
  "timezone": "Asia/Shanghai",
  "notification_permission": "default",
  "str29_head": "10",
  "device_memory": 32,
  "hardware_concurrency": 20,
  "max_touch_points": 10,
  "avail_height": 1392,
  "avail_left": 0,
  "avail_top": 0,
  "avail_width": 2560,
  "screen_height": 1440,
  "screen_width": 2560,
  "color_depth": 24,
  "pixel_depth": 24,
  "device_pixel_ratio": 1
}
''';

/// 登录页 bundle 内置的 d0 公钥（PKCS#1 PEM）。
///
/// 来源：`cv-cat/DouYin_Spider` 的 `_BUILTIN_TRAIT_PK1_B64`。
/// 用于 RSA 加密随机生成的 AES 密钥。
const String _builtinPk1Pem = '''-----BEGIN RSA PUBLIC KEY-----
MIIBCgKCAQEA4+dvvY7uM+opc+nLG/DumSeFo7aVcIm1LO+mUIrWprRzP0a1GpEQ
4qtO9MRf/lwEIx38+4BZ4XOGzevVtuUvfIOUE7ATtQW7FKJf5PnSLCI6/k0vl1FC
LUSVmEP6qPJrIjZ4zXoqi3yuNZ+1odbRA//GHgcgSyyyaLqzwjkpWGXouMYmvYsS
ppk/fv2EWABstPNxWa4EOBCadTUPkXNQ76NBEP9xzfJS20wiDv1oS/vKvrSUpWcJ
nazkkBvqQbbAqVbQFTF/DPikppu6ZT6lGIXvJKCreeFiHA2qK6tS18SWVHW9ARz1
+pjB1eqIIYtohWpT2B40OC4O8tVeBAnbiQIDAQAB
-----END RSA PUBLIC KEY-----''';

/// SDK 版本（写进 payload）。
const String dtraitSdkVersion = '1.0.0.16';

/// 头部前缀。
const String dtraitPk1Version = 'd0';

/// Math 指纹常量（Chrome V8 的值）。
///
/// 注释里写明不能运行时现算——Node 的 V8 与 Chrome 差 1 ULP。
const Map<int, String> _mathFeatures = {
  11: '-1.4214488238747245,0.5493061443340549,'
      '0.5493061443340549,-0.8390715290095377',
  12: '1.7182818284590453,1.9275814160560206e-50,'
      '0.8187819121159085,-1.4214488238747245',
};

/// MurmurHash3 x86 32 位（按 UTF-8 字节）。
int murmur3(String input, [int seed = 0]) {
  final data = utf8.encode(input);
  const c1 = 0xcc9e2d51;
  const c2 = 0x1b873593;
  var h = seed;

  final n = data.length & ~3;
  for (var i = 0; i < n; i += 4) {
    var k = data[i] |
        (data[i + 1] << 8) |
        (data[i + 2] << 16) |
        (data[i + 3] << 24);
    k = (k * c1) & 0xffffffff;
    k = ((k << 15) | (k >> 17)) & 0xffffffff;
    k = (k * c2) & 0xffffffff;
    h ^= k;
    h = ((h << 13) | (h >> 19)) & 0xffffffff;
    h = (h * 5 + 0xe6546b64) & 0xffffffff;
  }

  if (data.length > n) {
    var k = 0;
    for (var i = n; i < data.length; i++) {
      k |= data[i] << (8 * (i - n));
    }
    k = (k * c1) & 0xffffffff;
    k = ((k << 15) | (k >> 17)) & 0xffffffff;
    k = (k * c2) & 0xffffffff;
    h ^= k;
  }

  h ^= data.length;
  h ^= h >> 16;
  h = (h * 0x85ebca6b) & 0xffffffff;
  h ^= h >> 13;
  h = (h * 0xc2b2ae35) & 0xffffffff;
  h ^= h >> 16;
  return h & 0xffffffff;
}

/// `str_N` 的 tag 字节。
int _strTag(int n) => n <= 33 ? 31 + n : 71;

/// 由档案字段现算的特征串（键是 str_N 的 N）。
Map<int, String> _computedFeatures(Map<String, dynamic> p) {
  String j(Object? v) => v is List ? v.join(',') : '$v';
  return {
    ..._mathFeatures,
    14: '${p['downlink']},${p['effective_type']}',
    15: '${p['language']},${j(p['languages'])}',
    16: '${j(p['str16_list'])},${p['vendor']}',
    17: '${p['platform']},${p['str17_tail']}',
    18: j(p['str18_list']),
    19: '${p['ua']}',
    27: '${p['locale']}+${p['timezone']}',
    28: '${p['notification_permission']}',
    29: '${p['str29_head']},${p['device_memory']},'
        '${p['hardware_concurrency']},${p['max_touch_points']}',
    30: '${p['avail_height']},${p['avail_left']},'
        '${p['avail_top']},${p['avail_width']}',
    31: '${p['screen_height']},${p['screen_width']}',
    32: '${p['color_depth']},${p['pixel_depth']},'
        '${p['device_pixel_ratio']}',
  };
}

/// bool 位图。
Uint8List _boolBuffer(Map<int, bool> bools) {
  if (bools.isEmpty) return Uint8List(0);
  final keys = bools.keys.toList()..sort();
  final maxIdx = keys.last;
  final buf = Uint8List((maxIdx ~/ 32 + 1) * 5);
  for (final n in keys) {
    if (n % 32 == 0) buf[n ~/ 32] = n ~/ 8;
    if (bools[n] == true) {
      final i = 5 * (n ~/ 32 + 1) - ((n % 32) ~/ 8) - 1;
      buf[i] = buf[i] | (1 << (n % 8));
    }
  }
  return buf;
}

/// 生成内层 dtrait blob（base64）。
///
/// [profile] 为 null 时用内置档案。
String buildDtraitBlob({Map<String, dynamic>? profile}) {
  final p = profile ?? (jsonDecode(_defaultProfileJson) as Map<String, dynamic>);

  final bools = <int, bool>{};
  (p['bools'] as Map<String, dynamic>).forEach((k, v) {
    bools[int.parse(k)] = v as bool;
  });

  final values = <int, int>{};
  (p['render_hashes'] as Map<String, dynamic>).forEach((k, v) {
    values[int.parse(k)] = v as int;
  });
  // 现算的特征覆盖/补充
  _computedFeatures(p).forEach((n, s) {
    values[n] = murmur3(s);
  });

  final body = Uint8List(34 * 5);
  final bd = ByteData.sublistView(body);
  for (var n = 1; n <= 34; n++) {
    final v = values[n];
    if (v == null) {
      throw StateError('dtrait: render_hashes 缺少 $n');
    }
    body[(n - 1) * 5] = _strTag(n);
    bd.setUint32((n - 1) * 5 + 1, v & 0xffffffff, Endian.big);
  }

  final reserved = (p['reserved'] as int?) ?? 0;
  final type = (p['dtrait_type'] as int?) ?? 1;
  final version = (p['version'] as int?) ?? 0;
  const accessType = 0;
  final head =
      ((reserved & 0x3) << 6) | ((type & 0x1) << 5) | ((accessType & 0x1) << 4) | (version & 0xf);

  final out = BytesBuilder()
    ..addByte(head)
    ..add(_boolBuffer(bools))
    ..add(body);
  return base64Encode(out.toBytes());
}

/// 一次会话的 dtrait 加密材料（AES 密钥 + RSA 加密结果）。
class DtraitMaterial {
  DtraitMaterial({required this.keyHex, required this.encKeyB64});

  /// 16 字节随机数的 32 位小写十六进制。
  final String keyHex;

  /// `base64(RSA_PKCS1v15(aesKeyHex))`。
  final String encKeyB64;
}

/// 构造 `x-tt-session-dtrait` 头。
///
/// [path] 是本次请求的 pathname（不含 query）。
/// [material] 为 null 时新建密钥（首次请求），否则复用。
///
/// 返回 (header 值, 材料)。
({String header, DtraitMaterial material}) buildSessionDtrait(
  String path, {
  String? blob,
  DtraitMaterial? material,
}) {
  final dtraitBlob = blob ?? buildDtraitBlob();
  final rnd = Random.secure();

  late DtraitMaterial m;
  if (material == null) {
    final keyBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => rnd.nextInt(256)),
    );
    final keyHex = keyBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    // RSA 加密的是 keyHex 这个**字符串本身**（32 个 ASCII 字节）
    final enc = rsaPkcs1v15Encrypt(
      _builtinPk1Pem,
      Uint8List.fromList(ascii.encode(keyHex)),
    );
    m = DtraitMaterial(keyHex: keyHex, encKeyB64: base64Encode(enc));
  } else {
    m = material;
  }

  final iv = Uint8List.fromList(List<int>.generate(16, (_) => rnd.nextInt(256)));
  final payload = jsonEncode({
    'dtrait': dtraitBlob,
    'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'sdkVersion': dtraitSdkVersion,
    'path': path,
  });
  final cipher = aes128CbcEncrypt(
    _hexToBytes(m.keyHex),
    iv,
    Uint8List.fromList(utf8.encode(payload)),
  );

  final header =
      '${dtraitPk1Version}_${m.encKeyB64}_${base64Encode([...iv, ...cipher])}';
  return (header: header, material: m);
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// ── RSA / AES 基础实现 ────────────────────────────────────────
//
// 这里不引第三方库：pointycastle 的 RSA 需要完整 ASN.1 解析，
// 而这里只需要 PKCS#1 v1.5 的"公钥加密"一个方向，手写更可控。

/// 解析 PKCS#1 `BEGIN RSA PUBLIC KEY` PEM，返回 (n, e)。
({BigInt n, BigInt e}) parseRsaPublicKey(String pem) {
  final body = pem
      .split('\n')
      .where((l) => !l.contains('-----'))
      .join()
      .trim();
  final der = base64Decode(body);

  var i = 0;
  if (der[i] != 0x30) throw StateError('不是 DER SEQUENCE');
  i++;
  final (_, i2) = _derLen(der, i);
  i = i2;

  if (der[i] != 0x02) throw StateError('缺少 modulus');
  final (ln, i3) = _derLen(der, i + 1);
  i = i3;
  final n = _bigFromBytes(der.sublist(i, i + ln));
  i += ln;

  if (der[i] != 0x02) throw StateError('缺少 exponent');
  final (le, i4) = _derLen(der, i + 1);
  i = i4;
  final e = _bigFromBytes(der.sublist(i, i + le));

  return (n: n, e: e);
}

(int, int) _derLen(Uint8List buf, int i) {
  var n = buf[i];
  i++;
  if (n < 0x80) return (n, i);
  final k = n & 0x7f;
  var len = 0;
  for (var j = 0; j < k; j++) {
    len = (len << 8) | buf[i + j];
  }
  return (len, i + k);
}

BigInt _bigFromBytes(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// RSA PKCS#1 v1.5 公钥加密。
Uint8List rsaPkcs1v15Encrypt(String pem, Uint8List message) {
  final key = parseRsaPublicKey(pem);
  final k = (key.n.bitLength + 7) ~/ 8;
  final psLen = k - message.length - 3;
  if (psLen < 8) throw StateError('RSA: 消息过长');

  final rnd = Random.secure();
  final ps = <int>[];
  while (ps.length < psLen) {
    final b = rnd.nextInt(256);
    if (b != 0) ps.add(b);
  }

  final em = <int>[0x00, 0x02, ...ps, 0x00, ...message];
  final m = _bigFromBytes(em);
  final c = m.modPow(key.e, key.n);
  return _bigToBytes(c, k);
}

Uint8List _bigToBytes(BigInt v, int len) {
  final hex = v.toRadixString(16).padLeft(len * 2, '0');
  final out = Uint8List(len);
  for (var i = 0; i < len; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// AES-128-CBC + PKCS7 加密（手写，避免依赖）。
///
/// 只实现加密方向，够用。
Uint8List aes128CbcEncrypt(Uint8List key, Uint8List iv, Uint8List plain) {
  // PKCS7 填充
  final pad = 16 - (plain.length % 16);
  final padded = Uint8List(plain.length + pad)
    ..setRange(0, plain.length, plain);
  for (var i = plain.length; i < padded.length; i++) {
    padded[i] = pad;
  }

  final out = Uint8List(padded.length);
  var prev = iv;
  for (var off = 0; off < padded.length; off += 16) {
    final block = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      block[i] = padded[off + i] ^ prev[i];
    }
    final enc = _aesEncryptBlock(key, block);
    out.setRange(off, off + 16, enc);
    prev = enc;
  }
  return out;
}

// AES S-box
const List<int> _sbox = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
  0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
  0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
  0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
  0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
  0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
  0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
  0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
  0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
  0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
  0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
  0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
  0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
  0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
  0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
  0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
  0xb0, 0x54, 0xbb, 0x16,
];

const List<int> _rcon = [
  0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
];

int _xtime(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? 0x1b : 0)) & 0xff;

List<int> _expandKey(Uint8List key) {
  final w = List<int>.filled(176, 0);
  for (var i = 0; i < 16; i++) {
    w[i] = key[i];
  }
  for (var i = 16; i < 176; i += 4) {
    var t0 = w[i - 4], t1 = w[i - 3], t2 = w[i - 2], t3 = w[i - 1];
    if (i % 16 == 0) {
      final tmp = t0;
      t0 = _sbox[t1] ^ _rcon[i ~/ 16 - 1];
      t1 = _sbox[t2];
      t2 = _sbox[t3];
      t3 = _sbox[tmp];
    }
    w[i] = w[i - 16] ^ t0;
    w[i + 1] = w[i - 15] ^ t1;
    w[i + 2] = w[i - 14] ^ t2;
    w[i + 3] = w[i - 13] ^ t3;
  }
  return w;
}

Uint8List _aesEncryptBlock(Uint8List key, Uint8List block) {
  final w = _expandKey(key);
  final s = List<int>.from(block);

  void addRoundKey(int round) {
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[round * 16 + i];
    }
  }

  addRoundKey(0);
  for (var round = 1; round <= 10; round++) {
    // SubBytes
    for (var i = 0; i < 16; i++) {
      s[i] = _sbox[s[i]];
    }
    // ShiftRows
    final t = List<int>.from(s);
    s[1] = t[5];
    s[5] = t[9];
    s[9] = t[13];
    s[13] = t[1];
    s[2] = t[10];
    s[6] = t[14];
    s[10] = t[2];
    s[14] = t[6];
    s[3] = t[15];
    s[7] = t[3];
    s[11] = t[7];
    s[15] = t[11];
    // MixColumns（最后一轮不做）
    if (round != 10) {
      for (var c = 0; c < 4; c++) {
        final i = c * 4;
        final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
        s[i] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3;
        s[i + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3;
        s[i + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3);
        s[i + 3] = (_xtime(a0) ^ a0) ^ a1 ^ a2 ^ _xtime(a3);
      }
    }
    addRoundKey(round);
  }
  return Uint8List.fromList(s);
}
