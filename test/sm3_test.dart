import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/sm3.dart';

void main() {
  group('SM3 标准测试向量（GB/T 32905-2016）', () {
    test('"abc" 的摘要', () {
      // 标准向量：abc → 66c7f0f4 62eeedd9 d1f2d46b dc10e4e2 4167c487 5cf2f7a2 297da02b 8f4ba8e0
      const expected =
          '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0';
      final out = sm3(utf8.encode('abc'));
      expect(out.length, 32);
      expect(
        out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        expected,
      );
    });

    test('"abcd" 重复 16 次的摘要', () {
      // 标准向量：abcd*16 → debe9ff9 2275b8a1 38604889 c18e5a4d 6fdb70e5 387e5765 293dcba3 9c0c5732
      const expected =
          'debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732';
      final input = utf8.encode('abcd' * 16);
      final out = sm3(input);
      expect(
        out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        expected,
      );
    });

    test('空串的摘要', () {
      // 空串 → 1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b
      const expected =
          '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b';
      final out = sm3(const []);
      expect(
        out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        expected,
      );
    });

    test('输出长度固定 32 字节', () {
      expect(sm3(const []).length, 32);
      expect(sm3(utf8.encode('a')).length, 32);
      expect(sm3(List.filled(1000, 0x41)).length, 32);
    });

    test('不同输入产出不同摘要', () {
      final a = sm3(utf8.encode('abc'));
      final b = sm3(utf8.encode('abd'));
      expect(a, isNot(b));
    });
  });
}
