/// 协议专用字节变换（非标准 AES）。
///
/// 用于加密 `x-medusa` 载荷。按时间戳低 2 位选一套常量，
/// 再做 2 轮字节替换 + 行移位 + 列混合。
library;

import 'dart:typed_data';

import 'signer_bytes.dart';
import 'signer_tables.dart';

/// 协议专用的 AES 变体。
class AesV3 {
  AesV3(List<int> key, int timestamp) {
    _word = timestamp & 3;
    _box = Uint8List.fromList(
      signerSbox.sublist(_word * 256, (_word + 1) * 256),
    );
    _con = _cons[_word];
    _order = _orders[_word];
    _keys = _expandKey(key);
  }

  late final int _word;
  late final Uint8List _box;
  late final List<int> _con;
  late final List<int> _order;
  late final List<Uint8List> _keys;

  static const _cons = <List<int>>[
    [1, 0, 2, 3],
    [2, 0, 3, 1],
    [0, 1, 3, 2],
    [1, 0, 2, 3],
  ];

  static const _orders = <List<int>>[
    [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
    [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
    [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
  ];

  static const _initials = <int>[
    0xCA025DDC,
    0x823DC546,
    0xC9420583,
    0xC298225F,
  ];

  List<Uint8List> _expandKey(List<int> key) {
    final initial = _initials[_word];
    final four = concat([
      le32(initial),
      le32(initial),
      le32(initial),
      le32(initial),
    ]);
    final mixed = concat([xorBytes(four, key), Uint8List(32)]);
    final expanded = List<int>.from(mixed);

    var rounds = 8;
    for (var i = 4; i < 12; i++) {
      final at = 4 * (i - 1);
      var a = expanded[at];
      var b = expanded[at + 1];
      var c = expanded[at + 2];
      var d = expanded[at + 3];
      if (i & 3 == 0) {
        final t = ((initial >> (rounds & 24)) ^ _box[b]) & 255;
        b = _box[c];
        c = _box[d];
        d = _box[a];
        a = t;
      }
      rounds += 2;
      expanded[at + 4] = a ^ expanded[at - 12];
      expanded[at + 5] = b ^ expanded[at - 11];
      expanded[at + 6] = c ^ expanded[at - 10];
      expanded[at + 7] = d ^ expanded[at - 9];
    }

    return List<Uint8List>.generate(
      12,
      (i) => Uint8List.fromList(expanded.sublist(i * 4, i * 4 + 4)),
    );
  }

  Uint8List _block(List<int> value) {
    final rows = List<List<int>>.generate(
      4,
      (i) => List<int>.generate(4, (j) => value[i * 4 + j] & 0xFF),
    );

    void addCon(int offset) {
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          rows[i][j] = rows[i][j] ^ _keys[offset + i][_con[j]];
        }
      }
    }

    addCon(0);

    for (var round = 1; round <= 2; round++) {
      // 字节替换
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          rows[i][j] = _box[rows[i][j]];
        }
      }

      // 行置换
      final before = rows.map((r) => List<int>.from(r)).toList();
      for (var i = 0; i < 4; i++) {
        rows[i] = List<int>.from(before[_con[i]]);
      }

      // 按 order 打平重排
      final flat = <int>[];
      for (final r in rows) {
        flat.addAll(r);
      }
      for (var i = 0; i < 16; i++) {
        rows[i ~/ 4][i % 4] = flat[_order[i]];
      }

      if (round == 1) {
        // 列内置换
        for (var i = 0; i < 4; i++) {
          final old = List<int>.from(rows[i]);
          rows[i] = List<int>.generate(4, (k) => old[_con[k]]);
        }
        // 列混合
        int xt(int x) => ((x << 1) ^ ((x & 128) != 0 ? 0x1b : 0)) & 255;
        for (var i = 0; i < 4; i++) {
          final t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i];
          final u = rows[0][i];
          rows[0][i] = rows[0][i] ^ t ^ xt(rows[0][i] ^ rows[1][i]);
          rows[1][i] = rows[1][i] ^ t ^ xt(rows[1][i] ^ rows[2][i]);
          rows[2][i] = rows[2][i] ^ t ^ xt(rows[2][i] ^ rows[3][i]);
          rows[3][i] = rows[3][i] ^ t ^ xt(rows[3][i] ^ u);
        }
      }

      addCon(round * 4);
    }

    // 末轮密钥加
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        rows[i][j] = rows[i][j] ^ _keys[4 + i][j];
      }
    }

    final out = Uint8List(16);
    var k = 0;
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        out[k++] = rows[i][j] & 0xFF;
      }
    }
    return out;
  }

  /// 加密。
  ///
  /// [source] 至少 248 字节；[iv] 16 字节。
  /// 返回 `1 + source.length` 字节（首字节是密钥尾字节）。
  Uint8List encrypt(List<int> source, List<int> iv) {
    if (source.length < 248) {
      throw ArgumentError('source 至少需要 248 字节');
    }

    // 从 source 每 8 字节抽 1 位，拼成 32 字节的密钥材料
    final plaintext = Uint8List(32);
    for (var i = 0; i < 31; i++) {
      final at = i * 8;
      plaintext[i] =
          (((source[at] & 0xFF) >> 4) & 2) |
          ((source[at + 1] & 0xFF) & 64) |
          (((source[at + 2] & 0xFF) >> 2) & 1) |
          (((source[at + 3] & 0xFF) << 3) & 128) |
          (((source[at + 4] & 0xFF) >> 1) & 4) |
          (((source[at + 5] & 0xFF) << 3) & 16) |
          (((source[at + 6] & 0xFF) << 5) & 32) |
          (((source[at + 7] & 0xFF) >> 4) & 8);
    }
    plaintext[31] = 1;

    final first = _block(xorBytes(plaintext.sublist(0, 16), iv));
    final key = concat([
      first,
      _block(xorBytes(plaintext.sublist(16, 32), first)),
    ]);

    // 把密钥位分散写回 source 的空位
    final out = Uint8List.fromList(source);
    for (var i = 0; i < 31; i++) {
      final at = i * 8;
      final k = key[i] & 0xFF;
      out[at] = ((out[at] & 0xFF) & 0xDF) | ((k << 4) & 32);
      out[at + 1] = ((out[at + 1] & 0xFF) & 0xBF) | (k & 64);
      out[at + 2] = ((out[at + 2] & 0xFF) & 0xFB) | ((k << 2) & 4);
      out[at + 3] = ((out[at + 3] & 0xFF) & 0xEF) | ((k >> 3) & 16);
      out[at + 4] = ((out[at + 4] & 0xFF) & 0xF7) | ((k + k) & 8);
      out[at + 5] = ((out[at + 5] & 0xFF) & 0xFD) | ((k >> 3) & 2);
      out[at + 6] = ((out[at + 6] & 0xFF) & 0xFE) | ((k >> 5) & 1);
      out[at + 7] = ((out[at + 7] & 0xFF) & 0x7F) | ((k << 4) & 128);
    }

    return concat([
      Uint8List.fromList([key.last & 0xFF]),
      out,
    ]);
  }
}
