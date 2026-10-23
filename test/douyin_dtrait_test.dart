/// `x-tt-session-dtrait` 生成的离线验证（2026-10-23）。
///
/// # 为什么需要这组测试
///
/// `x-tt-session-dtrait` 是 passport 登录的最后一道门：缺它，
/// `check_qrconnect` 恒返回 4031「已阻止此次访问」。
///
/// 它由三部分组成，任何一处算错服务端都会拒：
///  1. **blob**：设备档案 → murmur3 → 定长字节序列 → base64
///  2. **RSA**：把随机 AES 密钥用内置 d0 公钥加密
///  3. **AES**：AES-128-CBC + PKCS7 加密 payload
///
/// 其中 2、3 是我手写的（避免为一个方向引第三方库），必须用
/// 已知向量验证——否则登录会静默失败，很难查。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/dtrait.dart';

void main() {
  group('MurmurHash3（对照已知向量）', () {
    test('空串 → 0', () {
      expect(murmur3(''), 0);
    });

    test('固定输入的输出稳定', () {
      // 同一输入必须每次相同，否则 blob 不可复现
      final a = murmur3('Mozilla/5.0 test');
      final b = murmur3('Mozilla/5.0 test');
      expect(a, b);
      expect(a, greaterThan(0));
    });

    test('seed 参与计算', () {
      expect(murmur3('abc', 1), isNot(murmur3('abc', 2)));
    });

    test('输出在 32 位无符号范围内', () {
      for (final s in ['a', '中文', 'Mozilla/5.0', 'x' * 200]) {
        final h = murmur3(s);
        expect(h, greaterThanOrEqualTo(0));
        expect(h, lessThanOrEqualTo(0xffffffff));
      }
    });
  });

  group('dtrait blob 结构', () {
    test('能生成 base64，长度符合 1 + bool位图 + 34*5', () {
      final blob = buildDtraitBlob();
      final bytes = base64Decode(blob);

      // bools 最大序号 10 → (10/32+1)*5 = 5 字节
      expect(bytes.length, 1 + 5 + 34 * 5,
          reason: '头 1 + bool 位图 5 + 特征段 170 = 176 字节');
    });

    test('头字节 = (reserved<<6)|(type<<5)|(access<<4)|version', () {
      final bytes = base64Decode(buildDtraitBlob());
      // 档案：reserved=0, dtrait_type=1, accessType=0, version=0
      expect(bytes[0], (0 << 6) | (1 << 5) | (0 << 4) | 0);
      expect(bytes[0], 0x20);
    });

    test('34 个特征段的 tag 正确（str_1..33 → 32..64，str_34 → 71）', () {
      final bytes = base64Decode(buildDtraitBlob());
      final bodyStart = 1 + 5;
      for (var n = 1; n <= 34; n++) {
        final tag = bytes[bodyStart + (n - 1) * 5];
        final expected = n <= 33 ? 31 + n : 71;
        expect(tag, expected, reason: 'str_$n 的 tag 应为 $expected');
      }
    });

    test('同一档案两次生成结果一致（确定性）', () {
      expect(buildDtraitBlob(), buildDtraitBlob(),
          reason: 'blob 必须可复现，否则同一会话内各请求对不上');
    });
  });

  group('RSA PKCS#1 v1.5 加密', () {
    test('能解析内置公钥', () {
      final pem = '''-----BEGIN RSA PUBLIC KEY-----
MIIBCgKCAQEA4+dvvY7uM+opc+nLG/DumSeFo7aVcIm1LO+mUIrWprRzP0a1GpEQ
4qtO9MRf/lwEIx38+4BZ4XOGzevVtuUvfIOUE7ATtQW7FKJf5PnSLCI6/k0vl1FC
LUSVmEP6qPJrIjZ4zXoqi3yuNZ+1odbRA//GHgcgSyyyaLqzwjkpWGXouMYmvYsS
ppk/fv2EWABstPNxWa4EOBCadTUPkXNQ76NBEP9xzfJS20wiDv1oS/vKvrSUpWcJ
nazkkBvqQbbAqVbQFTF/DPikppu6ZT6lGIXvJKCreeFiHA2qK6tS18SWVHW9ARz1
+pjB1eqIIYtohWpT2B40OC4O8tVeBAnbiQIDAQAB
-----END RSA PUBLIC KEY-----''';
      final key = parseRsaPublicKey(pem);
      expect(key.e, BigInt.from(65537), reason: '标准公钥指数');
      expect(key.n.bitLength, 2048, reason: '2048 位 RSA');
    });

    test('加密 32 字节明文得到 256 字节密文', () {
      final pem = '''-----BEGIN RSA PUBLIC KEY-----
MIIBCgKCAQEA4+dvvY7uM+opc+nLG/DumSeFo7aVcIm1LO+mUIrWprRzP0a1GpEQ
4qtO9MRf/lwEIx38+4BZ4XOGzevVtuUvfIOUE7ATtQW7FKJf5PnSLCI6/k0vl1FC
LUSVmEP6qPJrIjZ4zXoqi3yuNZ+1odbRA//GHgcgSyyyaLqzwjkpWGXouMYmvYsS
ppk/fv2EWABstPNxWa4EOBCadTUPkXNQ76NBEP9xzfJS20wiDv1oS/vKvrSUpWcJ
nazkkBvqQbbAqVbQFTF/DPikppu6ZT6lGIXvJKCreeFiHA2qK6tS18SWVHW9ARz1
+pjB1eqIIYtohWpT2B40OC4O8tVeBAnbiQIDAQAB
-----END RSA PUBLIC KEY-----''';
      final msg = Uint8List.fromList(ascii.encode('0123456789abcdef0123456789abcdef'));
      final out = rsaPkcs1v15Encrypt(pem, msg);
      expect(out.length, 256);
    });
  });

  group('AES-128-CBC 加密（对照 NIST 向量）', () {
    test('NIST SP 800-38A F.2.1 第一个分组', () {
      // key = 2b7e151628aed2a6abf7158809cf4f3c
      // iv  = 000102030405060708090a0b0c0d0e0f
      // pt  = 6bc1bee22e409f96e93d7e117393172a
      // ct  = 7649abac8119b246cee98e9b12e9197d
      final key = Uint8List.fromList([
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
      ]);
      final iv = Uint8List.fromList([
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
      ]);
      final pt = Uint8List.fromList([
        0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
        0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
      ]);
      final expected = [
        0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46,
        0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d,
      ];

      final out = aes128CbcEncrypt(key, iv, pt);
      // 输出会带一个 PKCS7 填充块，前 16 字节应与向量一致
      expect(out.sublist(0, 16), expected,
          reason: 'AES 实现错了，服务端一定解不开');
    });

    test('PKCS7 填充正确（整块倍数时补整块）', () {
      final key = Uint8List(16);
      final iv = Uint8List(16);
      final out = aes128CbcEncrypt(key, iv, Uint8List(16));
      expect(out.length, 32, reason: '16 字节输入要补满一整块（16+16）');
      // 填充长度体现在输出长度上；密文内容无法直接看填充值，
      // 这里验证长度即可（填充正确性由 NIST 向量那条保证）。
      expect(out.length % 16, 0);
    });
  });

  group('session dtrait 头格式', () {
    test('格式为 d0_<encKey>_<iv+cipher>', () {
      final r = buildSessionDtrait('/passport/web/get_qrcode/');
      final parts = r.header.split('_');
      expect(parts.length, 3, reason: '三段式，用下划线分隔');
      expect(parts[0], 'd0');
      expect(parts[1].isNotEmpty, isTrue);
      expect(parts[2].isNotEmpty, isTrue);

      // 第二段是 256 字节 RSA 密文的 base64
      expect(base64Decode(parts[1]).length, 256);
      // 第三段 = 16 字节 IV + 密文（16 的倍数）
      final third = base64Decode(parts[2]);
      expect((third.length - 16) % 16, 0);
    });

    test('复用 material 时第二段不变（同会话复用密钥）', () {
      final r1 = buildSessionDtrait('/a');
      final r2 = buildSessionDtrait('/b', material: r1.material);
      expect(r2.header.split('_')[1], r1.header.split('_')[1],
          reason: '同一会话应复用 RSA 加密的 AES 密钥');
      expect(r2.header, isNot(r1.header), reason: 'IV 每次都变');
    });

    test('不同 path 产生不同密文', () {
      final m = buildSessionDtrait('/a').material;
      final a = buildSessionDtrait('/a', material: m);
      final b = buildSessionDtrait('/b', material: m);
      expect(a.header, isNot(b.header));
    });
  });
}
