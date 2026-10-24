/// passport 签名层的离线回归。
///
/// 三处金标准全部来自真实 Chrome 会话的 challenge 请求：
/// `aid-sign` 头、query 的 `sign`/`qs`、`passportiv` → `bit_env`。
/// 自写两份实现互相对照会一起错，只有实录能定位到具体函数。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/passport_sign.dart';
import 'package:video_fusion/src/adapters/douyin/sms_login.dart'
    show passportEncrypt;

import 'support/douyin_login_golden.dart';

void main() {
  group('aidSign', () {
    test('与实录的 x-tt-passport-aid-sign 逐字节一致', () {
      expect(
        aidSign('/passport/web/challenge/', goldenTs),
        goldenAidSign,
      );
    });

    test('path 或 ts 变一个字符，签名就变', () {
      final base = aidSign('/passport/web/challenge/', goldenTs);
      expect(aidSign('/passport/web/send_code/', goldenTs), isNot(base));
      expect(aidSign('/passport/web/challenge/', '1792756801'), isNot(base));
    });
  });

  group('passportSign', () {
    test('sign / qs 与实录一致', () {
      final r = passportSign(goldenChallengeParams, goldenChallengeBody);
      expect(r.sign, goldenQuerySign);
      expect(r.qs, goldenQueryQs);
    });

    test('sign/qs/msToken/a_bogus 不参与计算', () {
      final withExtra = [
        ...goldenChallengeParams,
        ('sign', 'deadbeef'),
        ('qs', 'deadbeef'),
        ('msToken', 'deadbeef'),
        ('a_bogus', 'deadbeef'),
      ];
      final a = passportSign(goldenChallengeParams, goldenChallengeBody);
      final b = passportSign(withExtra, goldenChallengeBody);
      expect(b.sign, a.sign);
      expect(b.qs, a.qs);
    });

    test('body 变化会改变 sign', () {
      final a = passportSign(goldenChallengeParams, goldenChallengeBody);
      final b = passportSign(goldenChallengeParams, const [('sign', 'x')]);
      expect(b.sign, isNot(a.sign));
    });
  });

  group('uaAesUrlsafe', () {
    test('passportiv → bit_env 与实录一致', () {
      expect(
        uaAesUrlsafe(goldenPassportIv, userAgent: goldenUserAgent),
        goldenBitEnv,
      );
    });

    test('输出是 base64url（含 - _，不含 + /）', () {
      final out = uaAesUrlsafe('hello', userAgent: goldenUserAgent);
      expect(out.contains('+'), isFalse);
      expect(out.contains('/'), isFalse);
    });
  });

  group('quoteStrict / spliceUrl', () {
    test('只放行 A-Za-z0-9_.-~', () {
      expect(quoteStrict('aZ09_.-~'), 'aZ09_.-~');
      expect(quoteStrict('a b'), 'a%20b');
      expect(quoteStrict('a/b'), 'a%2Fb');
      expect(quoteStrict('a=b'), 'a%3Db');
      expect(quoteStrict("a'b"), 'a%27b');
    });

    test('中文按 UTF-8 百分号编码', () {
      expect(quoteStrict('中'), '%E4%B8%AD');
    });

    test('spliceUrl 只编码值，键原样，保持插入顺序', () {
      expect(
        spliceUrl([('b', 'x y'), ('a', '1')]),
        'b=x%20y&a=1',
      );
    });

    test('urlEncodePairs 键值都编码', () {
      expect(urlEncodePairs([('a b', 'c d')]), 'a%20b=c%20d');
    });
  });

  group('s_v_web_id / ts', () {
    test('形态为 verify_<base36>_<8>_<4>_4xxx_<8-9ab>xxx_<12>', () {
      final id = newSvWebId(DateTime.fromMillisecondsSinceEpoch(1792770994000));
      expect(
        RegExp(r'^verify_[0-9a-z]+_[0-9A-Za-z]{8}_[0-9A-Za-z]{4}_'
                r'4[0-9A-Za-z]{3}_[89ab][0-9A-Za-z]{3}_[0-9A-Za-z]{12}$')
            .hasMatch(id),
        isTrue,
        reason: id,
      );
    });

    test('sdkTs 取当天 UTC 12:00', () {
      final now = DateTime.utc(2026, 10, 24, 3, 15);
      final ts = sdkTsSeconds(now);
      expect(ts, DateTime.utc(2026, 10, 24, 12).millisecondsSinceEpoch ~/ 1000);
    });
  });

  group('passportEncrypt', () {
    test("'24' → '3731'（type 字段的实录值）", () {
      expect(passportEncrypt('24'), '3731');
    });
  });
}
