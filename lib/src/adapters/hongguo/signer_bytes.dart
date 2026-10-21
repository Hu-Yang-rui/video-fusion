/// 字节工具函数。
///
/// 对应 Kotlin 侧的 `Bytes.kt`：hex、base64、大小端整数、位旋转、摘要。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// 十六进制串 → 字节。
Uint8List hex(String value) {
  final s = value.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 字节 → 小写十六进制串。
String hexOf(List<int> data) {
  final sb = StringBuffer();
  for (final b in data) {
    sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// urlsafe base64 解码（补填充）。
Uint8List decode64(String s) {
  var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
  final rem = t.length % 4;
  if (rem == 2) {
    t += '==';
  } else if (rem == 3) {
    t += '=';
  } else if (rem == 1) {
    t += '===';
  }
  return Uint8List.fromList(base64.decode(t));
}

/// 标准 base64 编码。
String base64Of(List<int> data) => base64.encode(data);

/// 小端 32 位。
Uint8List le32(int n) {
  final out = Uint8List(4);
  final v = n & 0xFFFFFFFF;
  out[0] = v & 0xFF;
  out[1] = (v >> 8) & 0xFF;
  out[2] = (v >> 16) & 0xFF;
  out[3] = (v >> 24) & 0xFF;
  return out;
}

/// 大端 32 位。
Uint8List be32(int n) {
  final out = Uint8List(4);
  final v = n & 0xFFFFFFFF;
  out[0] = (v >> 24) & 0xFF;
  out[1] = (v >> 16) & 0xFF;
  out[2] = (v >> 8) & 0xFF;
  out[3] = v & 0xFF;
  return out;
}

/// 小端 64 位。
Uint8List le64(int n) {
  final out = Uint8List(8);
  var v = n;
  for (var i = 0; i < 8; i++) {
    out[i] = v & 0xFF;
    v = v >> 8;
  }
  return out;
}

/// 从 [at] 读 32 位整数。
int i32(List<int> data, int at, {bool little = false}) {
  if (little) {
    return (data[at] & 0xFF) |
        ((data[at + 1] & 0xFF) << 8) |
        ((data[at + 2] & 0xFF) << 16) |
        ((data[at + 3] & 0xFF) << 24);
  }
  return ((data[at] & 0xFF) << 24) |
      ((data[at + 1] & 0xFF) << 16) |
      ((data[at + 2] & 0xFF) << 8) |
      (data[at + 3] & 0xFF);
}

/// 从 [at] 读 64 位整数（返回 Dart int，64 位有符号）。
int i64(List<int> data, int at, {bool little = false}) {
  var v = 0;
  if (little) {
    for (var i = 7; i >= 0; i--) {
      v = (v << 8) | (data[at + i] & 0xFF);
    }
  } else {
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | (data[at + i] & 0xFF);
    }
  }
  return v;
}

/// MD5 摘要。
Uint8List md5(List<int> data) =>
    Uint8List.fromList(crypto.md5.convert(data).bytes);

/// SHA-256 摘要。
Uint8List sha256(List<int> data) =>
    Uint8List.fromList(crypto.sha256.convert(data).bytes);

/// 循环左移 32 位。
int rol(int v, int n) {
  final x = v & 0xFFFFFFFF;
  final s = n & 31;
  if (s == 0) return x;
  return ((x << s) | (x >> (32 - s))) & 0xFFFFFFFF;
}

/// 循环右移 32 位。
int ror(int v, int n) {
  final x = v & 0xFFFFFFFF;
  final s = n & 31;
  if (s == 0) return x;
  return ((x >> s) | (x << (32 - s))) & 0xFFFFFFFF;
}

/// 循环右移 64 位（逻辑右移语义）。
///
/// Dart 的 `int` 是有符号 64 位，`>>` 会做算术右移（负数保留符号位）。
/// 这里需要与 Java 的 `Long.rotateRight` 一致，也就是逻辑右移，
/// 所以先拆成高低 32 位再拼，避免符号位干扰。
int ror64(int v, int n) {
  final s = n & 63;
  if (s == 0) return v;
  final hi = (v >> 32) & 0xFFFFFFFF;
  final lo = v & 0xFFFFFFFF;
  if (s >= 32) {
    final k = s - 32;
    final newHi = k == 0 ? lo : (((lo << k) | (hi >> (32 - k))) & 0xFFFFFFFF);
    final newLo = k == 0 ? hi : (((hi << k) | (lo >> (32 - k))) & 0xFFFFFFFF);
    return _join64(newHi, newLo);
  }
  final newHi = ((hi >> s) | (lo << (32 - s))) & 0xFFFFFFFF;
  final newLo = ((lo >> s) | (hi << (32 - s))) & 0xFFFFFFFF;
  return _join64(newHi, newLo);
}

/// 64 位运算工具。
///
/// Dart 的 `int` 是有符号 64 位，`0xcaa8e4d9f22d0710` 这类值会被当成负数。
/// 协议里的 64 位量是**无符号位模式**，用有符号 int 表示时符号位会污染
/// 后续 XOR 和比较。因此这里统一用 [BigInt] 承载 64 位无符号值。

/// 2^64 掩码。
final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

/// 转成 64 位无符号 BigInt。
BigInt toU64(int v) => BigInt.from(v) & _mask64;

/// 64 位无符号加法。
BigInt addU64(BigInt a, BigInt b) => (a + b) & _mask64;

/// 64 位无符号异或。
BigInt xorU64(BigInt a, BigInt b) => (a ^ b) & _mask64;

/// 64 位无符号循环右移。
BigInt rorU64(BigInt v, int n) {
  final s = n & 63;
  if (s == 0) return v & _mask64;
  final x = v & _mask64;
  return ((x >> s) | ((x << (64 - s)) & _mask64)) & _mask64;
}

/// 64 位无符号值 → 小端 8 字节。
Uint8List le64u(BigInt v) {
  final out = Uint8List(8);
  var x = v & _mask64;
  final b256 = BigInt.from(256);
  for (var i = 0; i < 8; i++) {
    out[i] = (x % b256).toInt();
    x = x ~/ b256;
  }
  return out;
}

/// 小端 8 字节 → 64 位无符号值。
BigInt u64FromLe(List<int> data, int at) {
  var v = BigInt.zero;
  for (var i = 7; i >= 0; i--) {
    v = (v << 8) | BigInt.from(data[at + i] & 0xFF);
  }
  return v & _mask64;
}

/// 把高/低 32 位拼回 64 位（保留位模式）。
int _join64(int hi, int lo) {
  final h = hi & 0xFFFFFFFF;
  final l = lo & 0xFFFFFFFF;
  return (h * 0x100000000) + l;
}

/// 按字节异或（[b] 循环使用）。
Uint8List xorBytes(List<int> a, List<int> b) {
  final out = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    out[i] = (a[i] & 0xFF) ^ (b[i % b.length] & 0xFF);
  }
  return out;
}

/// 反转字节数组。
Uint8List reversed(List<int> data) =>
    Uint8List.fromList(data.reversed.toList());

/// 拼接多个字节数组。
Uint8List concat(List<List<int>> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Uint8List(total);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

/// 取前 [n] 字节。
Uint8List head(List<int> data, int n) =>
    Uint8List.fromList(data.sublist(0, n.clamp(0, data.length)));

/// 取 [start] 到 [end]（不含）的字节。
Uint8List slice(List<int> data, int start, [int? end]) =>
    Uint8List.fromList(data.sublist(start, end ?? data.length));

/// 取单字节的无符号值。
int u8(int b) => b & 0xFF;
