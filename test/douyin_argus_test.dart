/// 抖音 Argus / UIFID 会话等级的单元测试。
///
/// # 这组测试守护什么
///
/// 本轮修复的核心是：平台的 uifid **分两级**下发，
/// 旧代码用子串匹配 `RegExp(r'uifid')` 把 `UIFID_TEMP` 误判为就绪，
/// 导致 detail 一直 403 却无法归因。
///
/// 因此这里锁死：
///  1. `UIFID_TEMP` **绝不**能被判为 full
///  2. 只有精确名 `UIFID` 才算 full
///  3. 各种畸形 cookie 串不误判
///  4. 就绪等级枚举的语义（temp 可用但不够 full）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/web_signer.dart';

void main() {
  group('UIFID 等级判定（核心回归）', () {
    test('只有 UIFID_TEMP 时判为 temp，不是 full', () {
      // 这是本轮修复的根因：旧实现用子串匹配会把这里判成"已就绪"
      final level = DouyinWebSigner.readinessOfCookieString(
        'UIFID_TEMP=abc123; ttwid=xyz; x-web-secsdk-uid=1',
      );
      expect(level, SignerReadiness.temp);
      expect(
        level,
        isNot(SignerReadiness.full),
        reason: 'UIFID_TEMP 绝不能被当成正式 UIFID（detail 会 403）',
      );
    });

    test('出现精确名 UIFID 时判为 full', () {
      final level = DouyinWebSigner.readinessOfCookieString(
        'UIFID=full_value; UIFID_TEMP=temp_value; ttwid=xyz',
      );
      expect(level, SignerReadiness.full);
    });

    test('UIFID 与 UIFID_TEMP 并存时以 full 为准', () {
      final level = DouyinWebSigner.readinessOfCookieString(
        'UIFID_TEMP=t; UIFID=f',
      );
      expect(level, SignerReadiness.full);
    });

    test('两者都没有时判为 none', () {
      expect(
        DouyinWebSigner.readinessOfCookieString('ttwid=xyz; odin_tt=1'),
        SignerReadiness.none,
      );
    });

    test('空串与 "null"（evaluateJavascript 无返回值）判为 none', () {
      expect(DouyinWebSigner.readinessOfCookieString(''), SignerReadiness.none);
      expect(
        DouyinWebSigner.readinessOfCookieString('null'),
        SignerReadiness.none,
      );
    });

    test('名字包含 uifid 但不是这两个（如 UIFID_XXX）不算就绪', () {
      // 平台还有 x-web-secsdk-uid 等相似名，不能误判
      final level = DouyinWebSigner.readinessOfCookieString(
        'UIFID_OTHER=v; x-web-secsdk-uid=1; my_uifid_extra=2',
      );
      expect(level, SignerReadiness.none);
    });

    test('大小写敏感：小写 uifid 不算（平台下发的是大写）', () {
      final level = DouyinWebSigner.readinessOfCookieString('uifid=x');
      expect(level, SignerReadiness.none);
    });

    test('真实抓包形态的 cookie 串能正确分级', () {
      // 实测 ~500ms 的快照（只有 TEMP）
      const tempSnapshot =
          'UIFID_TEMP=0a1b2c; __ac_nonce=67; __ac_signature=abc; '
          'ttwid=xyz; x-web-secsdk-uid=1; enter_pc_once=1';
      expect(
        DouyinWebSigner.readinessOfCookieString(tempSnapshot),
        SignerReadiness.temp,
      );

      // 实测 ~4000ms 的快照（正式 UIFID 出现）
      const fullSnapshot =
          'UIFID=full_value_here; UIFID_TEMP=0a1b2c; __ac_nonce=67; '
          'ttwid=xyz; x-web-secsdk-uid=1; s_v_web_id=abc; '
          'odin_tt=def; passport_csrf_token=ghi';
      expect(
        DouyinWebSigner.readinessOfCookieString(fullSnapshot),
        SignerReadiness.full,
      );
    });

    test('带空格 / 分号结尾 / 多余分隔符都能解析', () {
      expect(
        DouyinWebSigner.readinessOfCookieString('  UIFID = v ; ; ttwid=x ; '),
        SignerReadiness.full,
      );
    });

    test('值里含分号不影响名字解析（按第一个 = 切分）', () {
      // 值里带 = 的情况：name 取第一个 = 之前
      expect(
        DouyinWebSigner.readinessOfCookieString('UIFID=a=b=c; ttwid=x'),
        SignerReadiness.full,
      );
    });
  });

  group('SignerReadiness 语义', () {
    test('temp 不是 full，full 也不是 none', () {
      expect(SignerReadiness.temp, isNot(SignerReadiness.full));
      expect(SignerReadiness.full, isNot(SignerReadiness.none));
      expect(SignerReadiness.temp, isNot(SignerReadiness.none));
    });

    test('枚举顺序体现等级（none < temp < full）', () {
      expect(
        SignerReadiness.none.index < SignerReadiness.temp.index,
        isTrue,
      );
      expect(
        SignerReadiness.temp.index < SignerReadiness.full.index,
        isTrue,
      );
    });

    test('枚举名稳定（写进诊断字段，不能随意改名）', () {
      expect(SignerReadiness.none.name, 'none');
      expect(SignerReadiness.temp.name, 'temp');
      expect(SignerReadiness.full.name, 'full');
    });
  });

  group('响应模型', () {
    test('空 body 可识别', () {
      const r = DouyinCommentResponse(statusCode: 200, body: '');
      expect(r.isEmpty, isTrue);
      expect(r.tryParseJson(), isNull);
    });

    test('非 JSON body 不抛异常', () {
      const r = DouyinCommentResponse(statusCode: 403, body: 'Blocked by Argus');
      expect(r.isEmpty, isFalse);
      expect(r.tryParseJson(), isNull);
    });

    test('合法 JSON 可解析', () {
      const r = DouyinCommentResponse(
        statusCode: 200,
        body: '{"status_code":0,"aweme_detail":{"aweme_id":"1"}}',
      );
      final json = r.tryParseJson();
      expect(json, isNotNull);
      expect(json!['status_code'], 0);
      expect(json['aweme_detail'], isA<Map>());
    });

    test('JSON 数组不当作对象（返回 null）', () {
      const r = DouyinCommentResponse(statusCode: 200, body: '[1,2,3]');
      expect(r.tryParseJson(), isNull);
    });
  });
}
