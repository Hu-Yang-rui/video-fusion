/// 红果签名器测试。
///
/// 对照向量由 Python 参考实现生成（逐行重写自 Kotlin 版 Signer.kt）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/hongguo_signer.dart';
import 'package:video_fusion/src/adapters/hongguo/signer_bytes.dart';
import 'package:video_fusion/src/adapters/hongguo/sm3.dart';

void main() {
  const ts = 1761100000;
  const query =
      'aid=8662&app_name=novelread&iid=1234567890123456&device_id=9876543210987654';
  const bodyStr =
      '{"biz_param":{"detail_page_version":0},"video_id":"7680951264905022488"}';

  final body = Uint8List.fromList(utf8.encode(bodyStr));

  group('SM3 前置校验', () {
    test('query 的 SM3 与参考一致', () {
      expect(
        hexOf(sm3(utf8.encode(query))),
        '901c37b9a547d73eb9d15b4cfb4e666f1a57a43fdfc93449cbdb409eeace8b08',
      );
    });

    test('body 的 MD5 与参考一致', () {
      expect(
        hexOf(md5(body)),
        '49014575b5871d6101d88bc5edbd9042',
      );
    });
  });

  group('branch 判定', () {
    test('固定输入的 branch 与参考一致', () {
      final signer = HongguoSigner();
      expect(signer.branch(query, body, ts), 0);
    });

    test('branch 只在 0..2 之间', () {
      final signer = HongguoSigner();
      for (var i = 0; i < 20; i++) {
        final q = '${query}&_rticket=$i';
        final b = signer.branch(q, body, ts);
        expect(b, inInclusiveRange(0, 2));
      }
    });
  });

  group('sign 端到端', () {
    test('产出六个签名头', () {
      final signer = HongguoSigner();
      final device = <String, String>{
        'iid': '1234567890123456',
        'device_id': '9876543210987654',
        'version_name': '7.1.3.32',
        'aid': '8662',
      };

      final req = signer.sign(
        'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/',
        device,
        body: body,
      );

      const expected = [
        'x-khronos',
        'x-ladon',
        'x-argus',
        'x-gorgon',
        'x-helios',
        'x-medusa',
      ];
      for (final h in expected) {
        expect(req.headers.containsKey(h), isTrue, reason: '缺少 $h');
        expect(req.headers[h]!.isNotEmpty, isTrue, reason: '$h 为空');
      }
    });

    test('URL 带 ts 与 _rticket', () {
      final signer = HongguoSigner();
      final device = <String, String>{
        'iid': '1234567890123456',
        'device_id': '9876543210987654',
        'version_name': '7.1.3.32',
      };
      final req = signer.sign('https://example.com/api', device, body: body);
      expect(req.url, contains('ts='));
      expect(req.url, contains('_rticket='));
    });

    test('设备身份缺失时抛错（不静默发送）', () {
      final signer = HongguoSigner();
      expect(
        () => signer.sign('https://example.com/api', {'iid': ''}, body: body),
        throwsA(isA<StateError>()),
      );
    });

    test('x-ss-stub 是 body 的 MD5 大写', () {
      final signer = HongguoSigner();
      final device = <String, String>{
        'iid': '1234567890123456',
        'device_id': '9876543210987654',
        'version_name': '7.1.3.32',
      };
      final req = signer.sign('https://example.com/api', device, body: body);
      expect(req.headers['x-ss-stub'], hexOf(md5(body)).toUpperCase());
    });

    test('GET 请求不带 Content-Type / x-ss-stub', () {
      final signer = HongguoSigner();
      final device = <String, String>{
        'iid': '1234567890123456',
        'device_id': '9876543210987654',
        'version_name': '7.1.3.32',
      };
      final req = signer.sign('https://example.com/api', device);
      expect(req.headers.containsKey('Content-Type'), isFalse);
      expect(req.headers.containsKey('x-ss-stub'), isFalse);
      expect(req.body, isNull);
    });
  });

  group('medusa / helios 结构', () {
    test('medusa 是 base64', () {
      final signer = HongguoSigner();
      final device = <String, String>{
        'iid': '1234567890123456',
        'device_id': '9876543210987654',
        'version_name': '7.1.3.32',
      };
      final out = signer.medusa(
        'https://example.com/api?${query.replaceAll('&', '&')}',
        body,
        ts,
        device,
      );
      expect(RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(out), isTrue);
      expect(base64.decode(out).length, greaterThan(100));
    });

    test('helios 是 base64', () {
      final signer = HongguoSigner();
      final out = signer.helios(ts);
      expect(RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(out), isTrue);
    });

    test('同一 ts 下 helios 每次都不同（内含随机）', () {
      final signer = HongguoSigner();
      expect(signer.helios(ts), isNot(signer.helios(ts)));
    });
  });
}
