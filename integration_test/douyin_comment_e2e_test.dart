/// 抖音评论的端到端验证（不依赖 UI 点击）。
///
/// 这个测试直接调用适配器的 fetchComments，验证：
///  1. WebView 能启动并拿到 uifid
///  2. 评论接口返回真实数据
///  3. 字段解析正确
///
/// 运行：flutter test integration_test/douyin_comment_e2e_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('抖音评论：WebView 签名桥 + 真实数据', (tester) async {
    final adapter = DouyinAdapter(
      http: FusionHttpClient(logger: FusionLogger(enabled: true)),
      logger: FusionLogger(enabled: true),
    );

    // 22.8 万条评论的视频
    const awemeId = '7690992782325240232';

    // ignore: avoid_print
    print('=== 开始拉取评论 $awemeId ===');

    final page = await adapter.fetchComments(awemeId, page: 1, pageSize: 20);

    // ignore: avoid_print
    print('=== 结果: ${page.items.length} 条, total=${page.totalCount} ===');

    expect(page.items, isNotEmpty, reason: '应返回真实评论');
    expect(page.totalCount, greaterThan(0), reason: 'total 应大于 0');

    for (final c in page.items.take(5)) {
      // ignore: avoid_print
      print('  ${c.authorName}: ${c.message}  (赞 ${c.likeCount})');
      expect(c.id, isNotEmpty);
      expect(c.authorName, isNotEmpty);
      expect(c.message, isNotEmpty);
    }

    await adapter.disposeComments();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
