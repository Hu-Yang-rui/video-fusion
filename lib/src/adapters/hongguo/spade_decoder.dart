/// 红果加密播放源解密。
///
/// # 背景
///
/// 接口返回的播放条目里可能带两组加密字段：
///
///  - `spade_a`：加密后的播放地址
///  - `kid`：派生 AES 内容密钥的种子
///
/// 两者都是自定义 base64 编码的二进制块，解码后按固定算法还原。
///
/// # 算法性质
///
/// 纯数学运算：字符替换、XOR、popcount、十六进制解析。
/// 不依赖设备指纹、不依赖服务端下发的密钥、不需要原生库。
///
/// # 覆盖范围
///
///  - [decodeSpadeBase64]：urlsafe → 标准 base64 + 补填充
///  - [deriveContentKey]：从 `kid` 派生 16 字节 AES 密钥
///  - [decryptSpadeUrl]：从 `spade_a` 解出明文地址
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// spade / kid 字段的解码器。
class SpadeDecoder {
  const SpadeDecoder();

  /// 自定义 base64 解码。
  ///
  /// 平台用的是 urlsafe 变体（`-` / `_`），需要先转回标准字符集，
  /// 再补 `=` 到 4 的倍数，最后按标准 base64 解码。
  Uint8List decodeSpadeBase64(String input) {
    var s = input.trim();
    if (s.isEmpty) return Uint8List(0);

    s = s.replaceAll('-', '+').replaceAll('_', '/');

    final rem = s.length & 3;
    if (rem != 0) {
      s = s + ('=' * (4 - rem));
    }

    return Uint8List.fromList(base64.decode(s));
  }

  /// 从 `kid` 派生 16 字节内容密钥。
  ///
  /// 步骤：
  ///  1. base64 解码得到 raw
  ///  2. 用前 3 字节异或算出有效区长度
  ///  3. 逐字节解混淆：`(base ^ cur) - popcount(i) - 0x15`
  ///     （base 在相邻两字节之间交替取前值）
  ///  4. 取解出结果的 `[1..33)` 作为 32 字符十六进制串
  ///  5. 两两解析成 16 字节密钥
  Uint8List? deriveContentKey(String kid) {
    final raw = decodeSpadeBase64(kid);
    if (raw.length < 3) return null;

    var len = raw.length - (raw[2] ^ raw[1] ^ raw[0]) + 0x2F;
    if (len > raw.length - 1) len = raw.length - 1;
    if (len < 0x21) return null;

    final buf = Uint8List.fromList(raw.sublist(1, 1 + len));

    var prev = 0xFFFFFFF6;
    var prevPrev = 0x55;
    for (var i = 0; i < buf.length; i++) {
      final cur = buf[i];
      int base;
      if (i & 1 != 0) {
        base = prevPrev;
        prevPrev = cur;
      } else {
        base = prev;
        prev = cur;
      }
      final pc = _popcount(i);
      buf[i] = ((base ^ cur) - pc - 0x15) & 0xFF;
    }

    // 需要至少 1 + 32 字节
    if (buf.length < 0x21) return null;
    final hexStr = String.fromCharCodes(buf.sublist(1, 1 + 0x20));

    final key = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final hi = _hexVal(hexStr.codeUnitAt(i * 2));
      final lo = _hexVal(hexStr.codeUnitAt(i * 2 + 1));
      if (hi < 0 || lo < 0) return null;
      key[i] = (hi << 4) | lo;
    }
    return key;
  }

  /// 从 `spade_a` 解出明文播放地址。
  ///
  /// [spade] 是接口给的 `spade_a` 字段。
  /// [seed] 是 `kid` 字段解码后的字节（作为 SHA-512 的输入之一）。
  ///
  /// 结构：
  ///  - 前 4 字节是头，校验 `A8 01 00`
  ///  - 其余是 AES-CBC 密文
  ///  - 密钥 = `SHA512(seed || salt)` 的前 16 字节
  ///  - IV  = 同一摘要的 `[16..32)`
  String? decryptSpadeUrl({
    required String spade,
    required List<int> seed,
    required List<int> salt,
  }) {
    final raw = decodeSpadeBase64(spade);
    if (raw.length < 5) return null;
    if (raw[0] != 0xA8 || raw[1] != 0x01 || raw[2] != 0x00) return null;

    final body = raw.sublist(4);
    if (body.isEmpty || body.length % 16 != 0) return null;

    final digest = crypto.sha512.convert([...seed, ...salt]).bytes;
    if (digest.length < 32) return null;

    final key = digest.sublist(0, 16);
    final iv = digest.sublist(16, 32);

    final plain = _aesCbcDecrypt(key, iv, body);
    if (plain == null) return null;

    // 去掉尾部填充的 0
    var end = plain.length;
    while (end > 0 && plain[end - 1] == 0) {
      end--;
    }
    if (end == 0) return null;

    return utf8.decode(plain.sublist(0, end), allowMalformed: true);
  }

  static int _popcount(int v) {
    var n = 0;
    while (v > 0) {
      n += v & 1;
      v >>= 1;
    }
    return n;
  }

  static int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
    if (c >= 0x61 && c <= 0x66) return c - 0x57; // a-f
    if (c >= 0x41 && c <= 0x46) return c - 0x37; // A-F
    return -1;
  }

  /// AES-CBC 解密（PKCS#7 或零填充都能处理，这里只去零）。
  ///
  /// Dart 的 `crypto` 包不提供 AES，这里用纯 Dart 实现。
  static Uint8List? _aesCbcDecrypt(
    List<int> key,
    List<int> iv,
    List<int> cipher,
  ) {
    if (cipher.length % 16 != 0) return null;
    final aes = _Aes(key);
    final out = Uint8List(cipher.length);
    var prev = Uint8List.fromList(iv);

    for (var off = 0; off < cipher.length; off += 16) {
      final block = Uint8List.fromList(cipher.sublist(off, off + 16));
      final dec = aes.decryptBlock(block);
      for (var i = 0; i < 16; i++) {
        out[off + i] = dec[i] ^ prev[i];
      }
      prev = block;
    }
    return out;
  }
}

/// 最小 AES 实现（仅解密单个块）。
class _Aes {
  _Aes(List<int> key) {
    final nk = key.length ~/ 4;
    _rounds = nk + 6;
    _roundKeys = _expandKey(key, nk);
  }

  late final int _rounds;
  late final Uint8List _roundKeys;

  static const _sbox = <int>[
    0x63,
    0x7c,
    0x77,
    0x7b,
    0xf2,
    0x6b,
    0x6f,
    0xc5,
    0x30,
    0x01,
    0x67,
    0x2b,
    0xfe,
    0xd7,
    0xab,
    0x76,
    0xca,
    0x82,
    0xc9,
    0x7d,
    0xfa,
    0x59,
    0x47,
    0xf0,
    0xad,
    0xd4,
    0xa2,
    0xaf,
    0x9c,
    0xa4,
    0x72,
    0xc0,
    0xb7,
    0xfd,
    0x93,
    0x26,
    0x36,
    0x3f,
    0xf7,
    0xcc,
    0x34,
    0xa5,
    0xe5,
    0xf1,
    0x71,
    0xd8,
    0x31,
    0x15,
    0x04,
    0xc7,
    0x23,
    0xc3,
    0x18,
    0x96,
    0x05,
    0x9a,
    0x07,
    0x12,
    0x80,
    0xe2,
    0xeb,
    0x27,
    0xb2,
    0x75,
    0x09,
    0x83,
    0x2c,
    0x1a,
    0x1b,
    0x6e,
    0x5a,
    0xa0,
    0x52,
    0x3b,
    0xd6,
    0xb3,
    0x29,
    0xe3,
    0x2f,
    0x84,
    0x53,
    0xd1,
    0x00,
    0xed,
    0x20,
    0xfc,
    0xb1,
    0x5b,
    0x6a,
    0xcb,
    0xbe,
    0x39,
    0x4a,
    0x4c,
    0x58,
    0xcf,
    0xd0,
    0xef,
    0xaa,
    0xfb,
    0x43,
    0x4d,
    0x33,
    0x85,
    0x45,
    0xf9,
    0x02,
    0x7f,
    0x50,
    0x3c,
    0x9f,
    0xa8,
    0x51,
    0xa3,
    0x40,
    0x8f,
    0x92,
    0x9d,
    0x38,
    0xf5,
    0xbc,
    0xb6,
    0xda,
    0x21,
    0x10,
    0xff,
    0xf3,
    0xd2,
    0xcd,
    0x0c,
    0x13,
    0xec,
    0x5f,
    0x97,
    0x44,
    0x17,
    0xc4,
    0xa7,
    0x7e,
    0x3d,
    0x64,
    0x5d,
    0x19,
    0x73,
    0x60,
    0x81,
    0x4f,
    0xdc,
    0x22,
    0x2a,
    0x90,
    0x88,
    0x46,
    0xee,
    0xb8,
    0x14,
    0xde,
    0x5e,
    0x0b,
    0xdb,
    0xe0,
    0x32,
    0x3a,
    0x0a,
    0x49,
    0x06,
    0x24,
    0x5c,
    0xc2,
    0xd3,
    0xac,
    0x62,
    0x91,
    0x95,
    0xe4,
    0x79,
    0xe7,
    0xc8,
    0x37,
    0x6d,
    0x8d,
    0xd5,
    0x4e,
    0xa9,
    0x6c,
    0x56,
    0xf4,
    0xea,
    0x65,
    0x7a,
    0xae,
    0x08,
    0xba,
    0x78,
    0x25,
    0x2e,
    0x1c,
    0xa6,
    0xb4,
    0xc6,
    0xe8,
    0xdd,
    0x74,
    0x1f,
    0x4b,
    0xbd,
    0x8b,
    0x8a,
    0x70,
    0x3e,
    0xb5,
    0x66,
    0x48,
    0x03,
    0xf6,
    0x0e,
    0x61,
    0x35,
    0x57,
    0xb9,
    0x86,
    0xc1,
    0x1d,
    0x9e,
    0xe1,
    0xf8,
    0x98,
    0x11,
    0x69,
    0xd9,
    0x8e,
    0x94,
    0x9b,
    0x1e,
    0x87,
    0xe9,
    0xce,
    0x55,
    0x28,
    0xdf,
    0x8c,
    0xa1,
    0x89,
    0x0d,
    0xbf,
    0xe6,
    0x42,
    0x68,
    0x41,
    0x99,
    0x2d,
    0x0f,
    0xb0,
    0x54,
    0xbb,
    0x16,
  ];

  static const _invSbox = <int>[
    0x52,
    0x09,
    0x6a,
    0xd5,
    0x30,
    0x36,
    0xa5,
    0x38,
    0xbf,
    0x40,
    0xa3,
    0x9e,
    0x81,
    0xf3,
    0xd7,
    0xfb,
    0x7c,
    0xe3,
    0x39,
    0x82,
    0x9b,
    0x2f,
    0xff,
    0x87,
    0x34,
    0x8e,
    0x43,
    0x44,
    0xc4,
    0xde,
    0xe9,
    0xcb,
    0x54,
    0x7b,
    0x94,
    0x32,
    0xa6,
    0xc2,
    0x23,
    0x3d,
    0xee,
    0x4c,
    0x95,
    0x0b,
    0x42,
    0xfa,
    0xc3,
    0x4e,
    0x08,
    0x2e,
    0xa1,
    0x66,
    0x28,
    0xd9,
    0x24,
    0xb2,
    0x76,
    0x5b,
    0xa2,
    0x49,
    0x6d,
    0x8b,
    0xd1,
    0x25,
    0x72,
    0xf8,
    0xf6,
    0x64,
    0x86,
    0x68,
    0x98,
    0x16,
    0xd4,
    0xa4,
    0x5c,
    0xcc,
    0x5d,
    0x65,
    0xb6,
    0x92,
    0x6c,
    0x70,
    0x48,
    0x50,
    0xfd,
    0xed,
    0xb9,
    0xda,
    0x5e,
    0x15,
    0x46,
    0x57,
    0xa7,
    0x8d,
    0x9d,
    0x84,
    0x90,
    0xd8,
    0xab,
    0x00,
    0x8c,
    0xbc,
    0xd3,
    0x0a,
    0xf7,
    0xe4,
    0x58,
    0x05,
    0xb8,
    0xb3,
    0x45,
    0x06,
    0xd0,
    0x2c,
    0x1e,
    0x8f,
    0xca,
    0x3f,
    0x0f,
    0x02,
    0xc1,
    0xaf,
    0xbd,
    0x03,
    0x01,
    0x13,
    0x8a,
    0x6b,
    0x3a,
    0x91,
    0x11,
    0x41,
    0x4f,
    0x67,
    0xdc,
    0xea,
    0x97,
    0xf2,
    0xcf,
    0xce,
    0xf0,
    0xb4,
    0xe6,
    0x73,
    0x96,
    0xac,
    0x74,
    0x22,
    0xe7,
    0xad,
    0x35,
    0x85,
    0xe2,
    0xf9,
    0x37,
    0xe8,
    0x1c,
    0x75,
    0xdf,
    0x6e,
    0x47,
    0xf1,
    0x1a,
    0x71,
    0x1d,
    0x29,
    0xc5,
    0x89,
    0x6f,
    0xb7,
    0x62,
    0x0e,
    0xaa,
    0x18,
    0xbe,
    0x1b,
    0xfc,
    0x56,
    0x3e,
    0x4b,
    0xc6,
    0xd2,
    0x79,
    0x20,
    0x9a,
    0xdb,
    0xc0,
    0xfe,
    0x78,
    0xcd,
    0x5a,
    0xf4,
    0x1f,
    0xdd,
    0xa8,
    0x33,
    0x88,
    0x07,
    0xc7,
    0x31,
    0xb1,
    0x12,
    0x10,
    0x59,
    0x27,
    0x80,
    0xec,
    0x5f,
    0x60,
    0x51,
    0x7f,
    0xa9,
    0x19,
    0xb5,
    0x4a,
    0x0d,
    0x2d,
    0xe5,
    0x7a,
    0x9f,
    0x93,
    0xc9,
    0x9c,
    0xef,
    0xa0,
    0xe0,
    0x3b,
    0x4d,
    0xae,
    0x2a,
    0xf5,
    0xb0,
    0xc8,
    0xeb,
    0xbb,
    0x3c,
    0x83,
    0x53,
    0x99,
    0x61,
    0x17,
    0x2b,
    0x04,
    0x7e,
    0xba,
    0x77,
    0xd6,
    0x26,
    0xe1,
    0x69,
    0x14,
    0x63,
    0x55,
    0x21,
    0x0c,
    0x7d,
  ];

  Uint8List _expandKey(List<int> key, int nk) {
    final total = 4 * (_rounds + 1);
    final w = Uint8List(total * 4);
    w.setRange(0, key.length, key);

    var rcon = 1;
    for (var i = nk; i < total; i++) {
      var t = w.sublist((i - 1) * 4, i * 4).toList();
      if (i % nk == 0) {
        t = <int>[t[1], t[2], t[3], t[0]];
        for (var j = 0; j < 4; j++) {
          t[j] = _sbox[t[j]];
        }
        t[0] ^= rcon;
        rcon = _xtime(rcon);
      } else if (nk > 6 && i % nk == 4) {
        for (var j = 0; j < 4; j++) {
          t[j] = _sbox[t[j]];
        }
      }
      for (var j = 0; j < 4; j++) {
        w[i * 4 + j] = w[(i - nk) * 4 + j] ^ t[j];
      }
    }
    return w;
  }

  static int _xtime(int b) => ((b << 1) ^ ((b & 0x80) != 0 ? 0x1b : 0)) & 0xFF;

  static int _mul(int a, int b) {
    var result = 0;
    var x = a;
    var y = b;
    while (y > 0) {
      if (y & 1 != 0) result ^= x;
      x = _xtime(x);
      y >>= 1;
    }
    return result & 0xFF;
  }

  Uint8List decryptBlock(Uint8List input) {
    final s = Uint8List.fromList(input);
    _addRoundKey(s, _rounds);

    for (var round = _rounds - 1; round >= 0; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      _addRoundKey(s, round);
      if (round != 0) _invMixColumns(s);
    }
    return s;
  }

  void _addRoundKey(Uint8List s, int round) {
    for (var i = 0; i < 16; i++) {
      s[i] ^= _roundKeys[round * 16 + i];
    }
  }

  static void _invSubBytes(Uint8List s) {
    for (var i = 0; i < 16; i++) {
      s[i] = _invSbox[s[i]];
    }
  }

  static void _invShiftRows(Uint8List s) {
    // 状态按列存放：s[c*4 + r]
    for (var r = 1; r < 4; r++) {
      final row = [s[r], s[4 + r], s[8 + r], s[12 + r]];
      for (var c = 0; c < 4; c++) {
        s[c * 4 + r] = row[(c - r + 4) % 4];
      }
    }
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final a = s.sublist(c * 4, c * 4 + 4);
      s[c * 4 + 0] =
          _mul(a[0], 14) ^ _mul(a[1], 11) ^ _mul(a[2], 13) ^ _mul(a[3], 9);
      s[c * 4 + 1] =
          _mul(a[0], 9) ^ _mul(a[1], 14) ^ _mul(a[2], 11) ^ _mul(a[3], 13);
      s[c * 4 + 2] =
          _mul(a[0], 13) ^ _mul(a[1], 9) ^ _mul(a[2], 14) ^ _mul(a[3], 11);
      s[c * 4 + 3] =
          _mul(a[0], 11) ^ _mul(a[1], 13) ^ _mul(a[2], 9) ^ _mul(a[3], 14);
    }
  }
}
