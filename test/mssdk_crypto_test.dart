/// mssdk 加密原语回归（2026-10-23）。
///
/// # 为什么先测这个
///
/// 整条短信登录链第一步是 `/web/common` 上报，其 `strData` 字段 =
/// `base64Custom([0x41, nonce, ...RC4(nonce, plaintext)])`。
/// RC4 或 base64 只要错一个字节，服务端就不返回 msToken，后面全断。
/// 所以先用**公开标准测试向量**钉死 RC4，再谈上层。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/mssdk_crypto.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('RC4（对照公开标准测试向量）', () {
    // Wikipedia / RC4 官方测试向量
    test('Key="Key" Data="Plaintext" → BBF316E8D940AF0AD3', () {
      final out = rc4(utf8.encode('Key'), utf8.encode('Plaintext'));
      expect(_hex(out), 'bbf316e8d940af0ad3');
    });

    test('Key="Wiki" Data="pedia" → 1021BF0420', () {
      final out = rc4(utf8.encode('Wiki'), utf8.encode('pedia'));
      expect(_hex(out), '1021bf0420');
    });

    test('Key="Secret" Data="Attack at dawn" → 45A01F64...F5', () {
      final out = rc4(utf8.encode('Secret'), utf8.encode('Attack at dawn'));
      expect(_hex(out), '45a01f645fc35b383552544b9bf5');
    });

    test('单字节 key（mssdk 实际用法：key=[nonce]）', () {
      // 加密可逆：同 key 再跑一次还原明文
      const nonce = 0x7f;
      final plain = utf8.encode('hello douyin 抖音');
      final cipher = rc4([nonce], plain);
      final back = rc4([nonce], cipher);
      expect(back, plain);
    });

    test('输出长度 = 输入长度（流密码）', () {
      final plain = utf8.encode('a' * 500);
      expect(rc4([1, 2, 3], plain).length, 500);
    });
  });

  group('b64Custom', () {
    test('标准字母表时与 base64.encode 一致', () {
      for (final s in ['', 'f', 'fo', 'foo', 'foob', 'fooba', 'foobar']) {
        final bytes = utf8.encode(s);
        expect(
          b64Custom(bytes, stdAlphabet),
          base64.encode(bytes),
          reason: '「$s」($bytes.length 字节)',
        );
      }
    });

    test('自定义字母表长度与标准一致（每 3 字节→4 字符）', () {
      final bytes = utf8.encode('hello world test');
      expect(b64Custom(bytes, strDataAlphabet).length,
          base64.encode(bytes).length);
    });

    test('自定义字母表输出不含标准表独有字符冲突', () {
      // strData 表用 '+' 和 '/' 之外的排布；只验证输出字符都来自表
      final out = b64Custom(utf8.encode('some plaintext here'), strDataAlphabet);
      final allowed = strDataAlphabet.split('').toSet()..add('=');
      for (final ch in out.split('')) {
        expect(allowed, contains(ch), reason: '输出含表外字符 $ch');
      }
    });
  });

  group('encodeStrData', () {
    test('前缀是 [0x41, nonce]（解码可验证）', () {
      const nonce = 0x3c;
      final enc = encodeStrData('plaintext', nonce);
      // 反解 base64Custom
      final bytes = _decodeCustom(enc, strDataAlphabet);
      expect(bytes[0], 0x41);
      expect(bytes[1], nonce);
      // 剩余是 RC4 密文，用 nonce 解回应等于明文
      final cipher = bytes.sublist(2);
      expect(utf8.decode(rc4([nonce], cipher)), 'plaintext');
    });

    test('不同 nonce 产生不同输出（nonce 参与加密与头部）', () {
      expect(encodeStrData('same', 1), isNot(encodeStrData('same', 2)));
    });
  });
}

/// b64Custom 的逆（测试用，验证 encodeStrData 结构）。
List<int> _decodeCustom(String s, String alphabet) {
  final rev = <String, int>{
    for (var i = 0; i < alphabet.length; i++) alphabet[i]: i,
  };
  final clean = s.replaceAll('=', '');
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in clean.split('')) {
    buffer = (buffer << 6) | rev[ch]!;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return out;
}
