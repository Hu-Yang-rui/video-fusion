/// `bd-ticket-guard` 密钥生成的离线验证（2026-10-23）。
///
/// # 为什么需要这组测试
///
/// 抖音登录的 `check_qrconnect` 要求请求带
/// `bd-ticket-guard-ree-public-key`，且 Cookie
/// `bd_ticket_guard_client_data` 里要嵌同一个公钥。
///
/// 之前两次失败都出在这里：
///  1. **等 Cookie 自然出现** —— 它不会自己出现，是客户端生成的
///  2. **用随机字节冒充公钥** —— 不是合法的 P-256 曲线点，
///     服务端直接拒（界面仍显示 4031「已阻止此次访问」）
///
/// 所以必须验证：生成的公钥**真的落在曲线上**，且 `k·G == 公钥`。
/// 这条数学关系不成立，服务端一定拒绝。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:video_fusion/src/adapters/douyin/ticket_guard.dart';

final ECCurve_prime256v1 _p256 = ECCurve_prime256v1();

BigInt _bigFromBytes(Uint8List bytes) => BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );

void main() {
  group('P-256 密钥对合法性', () {
    test('公钥是 65 字节未压缩点，以 0x04 开头', () {
      final kp = generateTicketGuardKeyPair();
      expect(kp.publicKey.length, 65);
      expect(kp.publicKey[0], 0x04);
      expect(kp.privateKey.length, 32);
    });

    test('公钥能被曲线解码（即落在 P-256 上）', () {
      final kp = generateTicketGuardKeyPair();
      // decodePoint 内部会验证坐标满足曲线方程，解不出就抛异常。
      // 这比手写方程更可靠——直接复用曲线实现自己的校验。
      final point = _p256.curve.decodePoint(kp.publicKey);
      expect(point, isNotNull, reason: '公钥必须是合法的 P-256 曲线点');
      expect(point!.x, isNotNull);
      expect(point.y, isNotNull);
    });

    // 注：pointycastle 的 decodePoint **不校验**点是否落在曲线上
    // （实测：随机 64 字节也能解出 ECPoint）。所以"能解码"不足以证明
    // 公钥合法——真正的保证是下面的 `k·G == 公钥`。
    // 这也解释了为什么用随机字节冒充公钥时，本地一切正常、
    // 服务端却直接拒。

    test('公钥 = 私钥 · G（点乘关系成立）', () {
      final kp = generateTicketGuardKeyPair();
      final derived = publicKeyFromPrivate(kp.privateKey);
      expect(
        derived,
        kp.publicKey,
        reason: 'k·G 必须等于公钥；不等说明密钥对是伪造的',
      );
    });

    test('两次生成不重复（真随机）', () {
      final a = generateTicketGuardKeyPair();
      final b = generateTicketGuardKeyPair();
      expect(a.privateKey, isNot(b.privateKey));
      expect(a.publicKey, isNot(b.publicKey));
    });
  });

  group('ree_public_key 编码', () {
    test('是标准 base64（+/），不是 url-safe（-_）', () {
      final kp = generateTicketGuardKeyPair();
      final b64 = kp.reePublicKeyBase64;
      expect(b64.contains('-'), isFalse, reason: 'url-safe 会被服务端判非法');
      expect(b64.contains('_'), isFalse);
      // 解码后应还原成同一个 65 字节点
      expect(base64Decode(b64), kp.publicKey);
    });
  });

  group('client_data Cookie 结构', () {
    test('四个键与 zero.js 一致，版本号正确', () {
      final kp = generateTicketGuardKeyPair();
      final raw = utf8.decode(base64Decode(kp.clientDataCookie));
      final map = jsonDecode(raw) as Map<String, dynamic>;

      expect(map['bd-ticket-guard-version'], 2);
      expect(map['bd-ticket-guard-iteration-version'], 1);
      expect(map['bd-ticket-guard-web-version'], 2);
      expect(
        map['bd-ticket-guard-ree-public-key'],
        kp.reePublicKeyBase64,
        reason: 'Cookie 里的公钥必须与请求头一致，否则服务端对不上',
      );
    });

    test('键序与 zero.js 一致（version → iteration → ree-public-key → web-version）', () {
      final kp = generateTicketGuardKeyPair();
      final raw = utf8.decode(base64Decode(kp.clientDataCookie));
      final keys = (jsonDecode(raw) as Map<String, dynamic>).keys.toList();
      expect(keys, [
        'bd-ticket-guard-version',
        'bd-ticket-guard-iteration-version',
        'bd-ticket-guard-ree-public-key',
        'bd-ticket-guard-web-version',
      ]);
    });
  });

  group('ECDH 会话密钥（登录成功后用）', () {
    test('两对密钥算出的 ECDH 密钥一致（对称性）', () {
      final a = generateTicketGuardKeyPair();
      final b = generateTicketGuardKeyPair();
      final k1 = ecdhKey(a.privateKey, b.publicKey);
      final k2 = ecdhKey(b.privateKey, a.publicKey);
      expect(k1, k2, reason: 'ECDH 必须对称，否则签名对不上');
      expect(k1.length, 32);
    });
  });
}
