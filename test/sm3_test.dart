import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/sm3.dart';

void main() {
  group('SM3 官方测试向量', () {
    test('"abc" 的摘要', () {
      // GB/T 32905-2016 标准测试向量
      final digest = sm3OfString('abc');
      final hex = digest
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(
        hex,
        '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
      );
    });

    test('"abcd" 重复 16 次的摘要', () {
      const input = 'abcdabcdabcdabcdabcdabcdabcdabcd'
          'abcdabcdabcdabcdabcdabcdabcdabcd';
      final digest = sm3OfString(input);
      final hex = digest
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(
        hex,
        'debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732',
      );
    });

    test('空字符串的摘要', () {
      final digest = sm3OfString('');
      final hex = digest
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(
        hex,
        '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b',
      );
    });
  });

  group('SM3 输出格式', () {
    test('固定 32 字节', () {
      expect(sm3OfString('x').length, 32);
      expect(sm3OfString('').length, 32);
      expect(sm3OfString('a' * 1000).length, 32);
    });

    test('字节值在 0-255 范围', () {
      for (final b in sm3OfString('test')) {
        expect(b, greaterThanOrEqualTo(0));
        expect(b, lessThanOrEqualTo(255));
      }
    });

    test('相同输入产生相同摘要', () {
      expect(sm3OfString('abc'), sm3OfString('abc'));
    });

    test('不同输入产生不同摘要', () {
      expect(sm3OfString('abc'), isNot(sm3OfString('abd')));
    });
  });

  group('UTF-8 编码', () {
    test('ASCII', () {
      expect(utf8Encode('abc'), [97, 98, 99]);
    });

    test('中文（3 字节）', () {
      // "中" = U+4E2D → E4 B8 AD
      expect(utf8Encode('中'), [0xE4, 0xB8, 0xAD]);
    });

    test('emoji（4 字节）', () {
      // "😀" = U+1F600 → F0 9F 98 80
      expect(utf8Encode('😀'), [0xF0, 0x9F, 0x98, 0x80]);
    });

    test('空字符串', () {
      expect(utf8Encode(''), isEmpty);
    });
  });
}
