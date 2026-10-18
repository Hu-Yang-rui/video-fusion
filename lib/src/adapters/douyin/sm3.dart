/// SM3 哈希（GB/T 32905-2016），纯 Dart 实现。
///
/// 抖音的 `a_bogus` 用 SM3 而不是 SHA-256 来哈希输入。
///
/// 移植自 `_abogus_research/evil0ctal/.../native/sm3.py`（Apache-2.0），
/// 已用官方测试向量校验。
library;

/// SM3 初始向量。
const List<int> _iv = [
  0x7380166F,
  0x4914B2B9,
  0x172442D7,
  0xDA8A0600,
  0xA96F30BC,
  0x163138AA,
  0xE38DEE4D,
  0xB0FB0E4E,
];

const int _t0 = 0x79CC4519;
const int _t1 = 0x7A879D8A;
const int _mask = 0xFFFFFFFF;

int _rotl(int value, int bits) {
  final b = bits % 32;
  if (b == 0) return value & _mask;
  return ((value << b) & _mask) | (value >> (32 - b));
}

int _ff(int j, int x, int y, int z) =>
    j < 16 ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z));

int _gg(int j, int x, int y, int z) =>
    j < 16 ? (x ^ y ^ z) : ((x & y) | ((~x & _mask) & z));

List<int> _expand(List<int> block) {
  final w = List<int>.filled(68, 0);
  for (var i = 0; i < 16; i++) {
    w[i] = (block[i * 4] << 24) |
        (block[i * 4 + 1] << 16) |
        (block[i * 4 + 2] << 8) |
        block[i * 4 + 3];
  }
  for (var i = 16; i < 68; i++) {
    var x = w[i - 16] ^ w[i - 9] ^ _rotl(w[i - 3], 15);
    x = x ^ _rotl(x, 15) ^ _rotl(x, 23);
    w[i] = (x ^ _rotl(w[i - 13], 7) ^ w[i - 6]) & _mask;
  }
  return w;
}

List<int> _compress(List<int> state, List<int> block) {
  final w = _expand(block);
  final w1 = List<int>.filled(64, 0);
  for (var i = 0; i < 64; i++) {
    w1[i] = (w[i] ^ w[i + 4]) & _mask;
  }

  var a = state[0];
  var b = state[1];
  var c = state[2];
  var d = state[3];
  var e = state[4];
  var f = state[5];
  var g = state[6];
  var h = state[7];

  for (var j = 0; j < 64; j++) {
    final t = j < 16 ? _t0 : _t1;
    final ss1 = _rotl((_rotl(a, 12) + e + _rotl(t, j)) & _mask, 7);
    final ss2 = ss1 ^ _rotl(a, 12);
    final tt1 = (_ff(j, a, b, c) + d + ss2 + w1[j]) & _mask;
    final tt2 = (_gg(j, e, f, g) + h + ss1 + w[j]) & _mask;
    d = c;
    c = _rotl(b, 9);
    b = a;
    a = tt1;
    h = g;
    g = _rotl(f, 19);
    f = e;
    e = (tt2 ^ _rotl(tt2, 9) ^ _rotl(tt2, 17)) & _mask;
  }

  return [
    (state[0] ^ a) & _mask,
    (state[1] ^ b) & _mask,
    (state[2] ^ c) & _mask,
    (state[3] ^ d) & _mask,
    (state[4] ^ e) & _mask,
    (state[5] ^ f) & _mask,
    (state[6] ^ g) & _mask,
    (state[7] ^ h) & _mask,
  ];
}

List<int> _pad(List<int> message) {
  final bitLength = message.length * 8;
  final out = <int>[...message, 0x80];
  while (out.length % 64 != 56) {
    out.add(0);
  }
  // 64 位大端长度
  for (var i = 7; i >= 0; i--) {
    out.add((bitLength >> (i * 8)) & 0xFF);
  }
  return out;
}

/// 计算 SM3 摘要（32 字节）。
List<int> sm3Hash(List<int> message) {
  var state = List<int>.from(_iv);
  final padded = _pad(message);
  for (var offset = 0; offset < padded.length; offset += 64) {
    state = _compress(state, padded.sublist(offset, offset + 64));
  }
  final out = <int>[];
  for (final word in state) {
    out.addAll([
      (word >> 24) & 0xFF,
      (word >> 16) & 0xFF,
      (word >> 8) & 0xFF,
      word & 0xFF,
    ]);
  }
  return out;
}

/// UTF-8 字符串的 SM3 摘要。
List<int> sm3OfString(String text) => sm3Hash(utf8Encode(text));

/// 极简 UTF-8 编码（避免引入 dart:convert 只为这一个用途）。
List<int> utf8Encode(String s) {
  final out = <int>[];
  for (final rune in s.runes) {
    if (rune < 0x80) {
      out.add(rune);
    } else if (rune < 0x800) {
      out.add(0xC0 | (rune >> 6));
      out.add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      out.add(0xE0 | (rune >> 12));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    } else {
      out.add(0xF0 | (rune >> 18));
      out.add(0x80 | ((rune >> 12) & 0x3F));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    }
  }
  return out;
}
