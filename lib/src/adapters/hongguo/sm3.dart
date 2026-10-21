/// SM3 摘要算法（GB/T 32905-2016）。
///
/// 签名流程用它做 `query` 的摘要，是 `hashF13` 的输入之一。
library;

import 'dart:typed_data';

/// SM3 摘要（32 字节）。
Uint8List sm3(List<int> data) {
  const iv = <int>[
    0x7380166f,
    0x4914b2b9,
    0x172442d7,
    0xda8a0600,
    0xa96f30bc,
    0x163138aa,
    0xe38dee4d,
    0xb0fb0e4e,
  ];

  final v = List<int>.from(iv);

  // 填充：0x80 + 0x00... + 64 位大端比特长度
  final bitLen = data.length * 8;
  final padded = <int>[...data, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  // 64 位大端长度
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >> (i * 8)) & 0xFF);
  }

  // 逐块压缩
  for (var off = 0; off < padded.length; off += 64) {
    final w = List<int>.filled(68, 0);
    for (var i = 0; i < 16; i++) {
      w[i] =
          (padded[off + i * 4] << 24) |
          (padded[off + i * 4 + 1] << 16) |
          (padded[off + i * 4 + 2] << 8) |
          padded[off + i * 4 + 3];
    }
    for (var i = 16; i < 68; i++) {
      final x = w[i - 16] ^ w[i - 9] ^ _rol(w[i - 3], 15);
      w[i] = _p1(x) ^ _rol(w[i - 13], 7) ^ w[i - 6];
    }

    final w1 = List<int>.filled(64, 0);
    for (var i = 0; i < 64; i++) {
      w1[i] = w[i] ^ w[i + 4];
    }

    var a = v[0], b = v[1], c = v[2], d = v[3];
    var e = v[4], f = v[5], g = v[6], h = v[7];

    for (var j = 0; j < 64; j++) {
      final t = j < 16 ? 0x79cc4519 : 0x7a879d8a;
      final ss1 = _rol((_rol(a, 12) + e + _rol(t, j % 32)) & 0xFFFFFFFF, 7);
      final ss2 = ss1 ^ _rol(a, 12);
      final ff = j < 16 ? (a ^ b ^ c) : ((a & b) | (a & c) | (b & c));
      final gg = j < 16 ? (e ^ f ^ g) : ((e & f) | ((~e & 0xFFFFFFFF) & g));
      final tt1 = (ff + d + ss2 + w1[j]) & 0xFFFFFFFF;
      final tt2 = (gg + h + ss1 + w[j]) & 0xFFFFFFFF;

      d = c;
      c = _rol(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _rol(f, 19);
      f = e;
      e = _p0(tt2);
    }

    v[0] ^= a;
    v[1] ^= b;
    v[2] ^= c;
    v[3] ^= d;
    v[4] ^= e;
    v[5] ^= f;
    v[6] ^= g;
    v[7] ^= h;
  }

  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (v[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (v[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (v[i] >> 8) & 0xFF;
    out[i * 4 + 3] = v[i] & 0xFF;
  }
  return out;
}

int _rol(int v, int n) {
  final x = v & 0xFFFFFFFF;
  final s = n & 31;
  if (s == 0) return x;
  return ((x << s) | (x >> (32 - s))) & 0xFFFFFFFF;
}

int _p0(int x) {
  final v = x & 0xFFFFFFFF;
  return (v ^ _rol(v, 9) ^ _rol(v, 17)) & 0xFFFFFFFF;
}

int _p1(int x) {
  final v = x & 0xFFFFFFFF;
  return (v ^ _rol(v, 15) ^ _rol(v, 23)) & 0xFFFFFFFF;
}
