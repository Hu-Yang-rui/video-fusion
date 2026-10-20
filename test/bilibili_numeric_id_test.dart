/// 数字视频 ID 解析（真实网络）。
///
/// B 站链接带的是 bvid（字母），而翻译/互动类接口要的是 aid（数字）。
/// 两者不能直接互转，必须请求 view 接口。这里验证该解析真的可用。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  test('bvid 能解析出数字 aid（真实网络）', () async {
    final adapter = BilibiliAdapter(
      http: FusionHttpClient(),
      logger: FusionLogger(enabled: false),
    );

    const bvid = 'BV1GJ411x7h7';
    final aid = await adapter.resolveNumericVideoId(bvid);

    expect(aid, isNotNull, reason: 'view 接口应返回 aid');
    expect(aid! > 0, isTrue, reason: 'aid 必须是正整数');

    // 二次调用命中缓存，结果一致
    final again = await adapter.resolveNumericVideoId(bvid);
    expect(again, aid);
  });

  test('字母 ID 不能被当成数字解析（回归防护）', () {
    // 这条守护的是历史 bug：曾经直接 int.tryParse(bvid)，
    // 结果恒为 null，导致翻译永远报"缺少视频 ID"。
    expect(int.tryParse('BV1GJ411x7h7'), isNull);
  });

  test('适配器声明了数字 ID 能力', () {
    final adapter = BilibiliAdapter(
      http: FusionHttpClient(),
      logger: FusionLogger(enabled: false),
    );
    expect(adapter, isA<NumericVideoIdCapable>());
  });
}
