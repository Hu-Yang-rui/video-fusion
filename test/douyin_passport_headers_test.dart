/// passport 三个签名头的离线验证（2026-10-23）。
///
/// 对照 `cv-cat/catbus` 的 `sign.ts`：
/// ```
/// aidSign(path, ts):
///   prk  = hex(HMAC-SHA256(key=ts, msg=appKey))
///   okm  = HMAC-SHA256(key=hexDecode(prk), msg=[0x01])
///   sign = hex(HMAC-SHA256(key=okm, msg="aid=6383&path={path}&ts={ts}"))
/// ```
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/passport_headers.dart';

void main() {
  group('sdkTs（当天 UTC 12:00）', () {
    test('取的是正午，不是当前时刻', () {
      final now = DateTime.utc(2026, 10, 23, 3, 45, 12);
      final ts = sdkTsSeconds(now);
      final expectNoon = DateTime.utc(2026, 10, 23, 12);
      expect(ts, expectNoon.millisecondsSinceEpoch ~/ 1000);
    });

    test('同一天不同时刻得到相同 ts', () {
      final a = sdkTsSeconds(DateTime.utc(2026, 10, 23, 0, 1));
      final b = sdkTsSeconds(DateTime.utc(2026, 10, 23, 23, 59));
      expect(a, b, reason: 'ts 按天固定，浏览器实录如此');
    });

    test('跨天会变', () {
      final a = sdkTsSeconds(DateTime.utc(2026, 10, 23, 12));
      final b = sdkTsSeconds(DateTime.utc(2026, 10, 24, 12));
      expect(a, isNot(b));
    });
  });

  group('aidSign', () {
    test('是 64 位十六进制（SHA-256 hex）', () {
      final s = aidSign('/passport/web/get_qrcode/', '1792756800');
      expect(s.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(s), isTrue);
    });

    test('同输入结果稳定（可复现）', () {
      const path = '/passport/web/check_qrconnect/';
      const ts = '1792756800';
      expect(aidSign(path, ts), aidSign(path, ts));
    });

    test('path 变化会影响签名', () {
      const ts = '1792756800';
      expect(
        aidSign('/passport/web/get_qrcode/', ts),
        isNot(aidSign('/passport/web/check_qrconnect/', ts)),
        reason: '签名绑定 path，不同接口必须不同',
      );
    });

    test('ts 变化会影响签名', () {
      const path = '/passport/web/get_qrcode/';
      expect(aidSign(path, '1792756800'), isNot(aidSign(path, '1792843200')));
    });

    test('aid 变化会影响签名', () {
      const path = '/a';
      const ts = '1';
      expect(aidSign(path, ts, aid: '6383'), isNot(aidSign(path, ts, aid: '24')));
    });
  });

  group('csrfTokenFromCookies', () {
    test('优先 passport_csrf_token', () {
      expect(
        csrfTokenFromCookies({
          'passport_csrf_token': 'aaa',
          'passport_csrf_token_default': 'bbb',
        }),
        'aaa',
      );
    });

    test('回退 passport_csrf_token_default', () {
      expect(
        csrfTokenFromCookies({'passport_csrf_token_default': 'bbb'}),
        'bbb',
      );
    });

    test('都没有返回 null（不返回空串）', () {
      expect(csrfTokenFromCookies({}), isNull);
      expect(csrfTokenFromCookies({'passport_csrf_token': ''}), isNull);
    });
  });

  group('buildVerifyPortrait', () {
    test('格式为 <uuid>.login', () {
      final p = buildVerifyPortrait();
      expect(p.endsWith('.login'), isTrue);
      final uuid = p.substring(0, p.length - '.login'.length);
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(uuid),
        isTrue,
        reason: '必须是 UUID v4 格式',
      );
    });

    test('每次生成不同（会话隔离）', () {
      expect(buildVerifyPortrait(), isNot(buildVerifyPortrait()));
    });

    test('传入 uuid 时原样使用（会话内复用）', () {
      const u = '1a317cd0-ce3a-42d4-bad8-3b5900fd29e6';
      expect(buildVerifyPortrait(u), '$u.login');
    });
  });
}
