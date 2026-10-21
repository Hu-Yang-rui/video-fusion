/// spade / kid 解码器测试。
///
/// 对照向量由 Python 参考实现生成（与平台客户端行为一致）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/spade_decoder.dart';

void main() {
  const dec = SpadeDecoder();

  group('自定义 base64 解码', () {
    test('urlsafe 的 - 和 _ 能正确还原', () {
      final std = dec.decodeSpadeBase64('Pz8/');
      final url = dec.decodeSpadeBase64('Pz8_');
      expect(url, std);
      expect(std, [0x3f, 0x3f, 0x3f]);
    });

    test('缺少填充会自动补 =', () {
      final out = dec.decodeSpadeBase64('QQ');
      expect(utf8.decode(out), 'A');
    });

    test('空串返回空', () {
      expect(dec.decodeSpadeBase64(''), isEmpty);
      expect(dec.decodeSpadeBase64('   '), isEmpty);
    });

    test('前后空白被忽略', () {
      expect(dec.decodeSpadeBase64('QQ=='), dec.decodeSpadeBase64('  QQ==  '));
    });
  });

  group('unwrapV1 对照向量（Python 参考实现生成）', () {
    // 真实抓到的 spade_a
    const realSpade =
        'orwswGK5L8VlihjNULYsy1CDK8RWiyrDV7gs8meLKsd7jTOPjw';
    // Python: _hg_unwrap_v1(base64decode(realSpade), 0)
    //   → 'cf7c6e29f00ddec2d0e8d0ddc22a4374'
    const expectedKey = 'cf7c6e29f00ddec2d0e8d0ddc22a4374';

    test('真实 spade 解出 32 字符 hex', () {
      final raw = dec.decodeSpadeBase64(realSpade);
      // 长度与 Python 一致
      expect(raw.length, 37);
      expect(
        raw.sublist(0, 4),
        [0xa2, 0xbc, 0x2c, 0xc0],
        reason: '解码后的头部字节必须与 Python 一致',
      );

      final key = dec.unwrapV1(raw);
      expect(key, expectedKey);
    });

    test('spadeToKey 端到端', () {
      expect(dec.spadeToKey(realSpade), expectedKey);
    });

    test('短片段解出非 32 字符 → spadeToKey 返回 null', () {
      // 这个是不完整片段，unwrap 能出 10 字符但不是合法 hex 密钥
      const short = 'obwv9FaNGMZliCvPVoQb';
      final raw = dec.decodeSpadeBase64(short);
      expect(raw.length, 15);
      // Python: _hg_unwrap_v1 → 'd2bc74e870'
      expect(dec.unwrapV1(raw), 'd2bc74e870');
      // 长度不是 32 → 拒绝
      expect(dec.spadeToKey(short), isNull);
    });

    test('长度不足 3 返回 null', () {
      expect(dec.unwrapV1(Uint8List.fromList([1, 2])), isNull);
    });

    test('空输入返回 null', () {
      expect(dec.unwrapV1(Uint8List(0)), isNull);
      expect(dec.spadeToKey(''), isNull);
    });

    test('随机数据不崩（返回 null 或字符串）', () {
      for (var len = 3; len < 60; len += 7) {
        final data = Uint8List.fromList(
          List.generate(len, (i) => (i * 37 + 11) & 0xFF),
        );
        expect(() => dec.unwrapV1(data), returnsNormally);
      }
    });
  });

  group('kid 派生密钥', () {
    test('合法 32 字符 hex 能解出 16 字节', () {
      const kid = '6a7d65cff8818b6cb21ccf310002ebeb';
      final key = dec.deriveContentKey(kid);
      expect(key, isNotNull);
      expect(key!.length, 16);
      // 前 4 字节应等于 hex 前 8 字符
      expect(key.sublist(0, 4), [0x6a, 0x7d, 0x65, 0xcf]);
    });

    test('非 hex 返回 null', () {
      expect(dec.deriveContentKey('zzzz'), isNull);
      expect(dec.deriveContentKey(''), isNull);
      expect(dec.deriveContentKey('6a7d65cff8818b6cb21ccf310002ebez'), isNull);
    });

    test('长度不对返回 null', () {
      expect(dec.deriveContentKey('6a7d65cf'), isNull);
      expect(
        dec.deriveContentKey('6a7d65cff8818b6cb21ccf310002ebebaa'),
        isNull,
      );
    });
  });

  group('AES-128-CBC 解密（NIST FIPS-197 向量）', () {
    test('单块解密与标准一致', () {
      final key = List.generate(16, (i) => i);
      final iv = List.filled(16, 0);
      final cipher = _hex('69c4e0d86a7b0430d8cdb78070b4c55a');

      final out = SpadeDecoder.aesCbcDecrypt(key, iv, cipher);
      expect(out, isNotNull);
      expect(
        out!.sublist(0, 16),
        _hex('00112233445566778899aabbccddeeff'),
        reason: 'FIPS-197 附录 C.1 标准向量',
      );
    });

    test('密钥长度非法返回 null', () {
      expect(SpadeDecoder.aesCbcDecrypt([1, 2, 3], List.filled(16, 0), List.filled(16, 0)), isNull);
    });

    test('IV 长度非法返回 null', () {
      expect(SpadeDecoder.aesCbcDecrypt(List.filled(16, 0), [1, 2], List.filled(16, 0)), isNull);
    });

    test('密文长度非 16 倍数返回 null', () {
      expect(SpadeDecoder.aesCbcDecrypt(List.filled(16, 0), List.filled(16, 0), List.filled(15, 0)), isNull);
    });
  });
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
