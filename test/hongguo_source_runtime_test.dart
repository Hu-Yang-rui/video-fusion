/// 红果来源的运行时可见性。
///
/// 静态检查只能证明"代码里有这个字符串"。这里构造真实的
/// registry + service，验证红果来源真的出现在
/// `describeFeedSources()` 的返回里——发现页的 chip 就是从
/// 这个列表渲染的，所以这条通过就意味着 chip 会出现。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/adapters/hongguo_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';

VideoService _buildService() {
  final logger = FusionLogger(enabled: false);
  final http = FusionHttpClient(logger: logger);
  return VideoService(
    registry: PlatformRegistry(adapters: [
      BilibiliAdapter(http: http, logger: logger),
      DouyinAdapter(http: http, logger: logger),
      HongguoAdapter(http: http, logger: logger),
    ]),
    store: VideoStore(storage: InMemoryStore()),
    logger: logger,
  );
}

void main() {
  group('红果来源在发现页可见', () {
    test('describeFeedSources 里包含红果', () {
      final sources = _buildService().describeFeedSources();

      final hongguo = sources.where((s) => s.adapterId == 'hongguo').toList();
      expect(hongguo, isNotEmpty,
          reason: '红果适配器必须在 registry 里，否则发现页不会有它的来源');

      expect(hongguo.length, 1, reason: '目前红果只有一个首页来源');
    });

    test('红果 chip 的标签就是「红果短剧」', () {
      final sources = _buildService().describeFeedSources();
      final hongguo = sources.firstWhere((s) => s.adapterId == 'hongguo');

      expect(hongguo.label, '红果短剧',
          reason: '发现页的 chip 直接显示 label，'
              '用户靠它认出平台。不能是「首页推荐」这种通用词。');
      expect(hongguo.available, isTrue, reason: '可用才会渲染成 chip');
      expect(hongguo.description, isNotEmpty);
    });

    test('三个平台的来源都齐（红果没被漏掉）', () {
      final sources = _buildService().describeFeedSources();
      final platforms = sources.map((s) => s.adapterId).toSet();

      expect(platforms, containsAll(<String>['bilibili', 'douyin', 'hongguo']),
          reason: '发现页只渲染 describeFeedSources 的结果；'
              '任何平台缺席都等于没有入口');
    });

    test('来源 id 全仓库唯一（不会互相覆盖）', () {
      final sources = _buildService().describeFeedSources();
      final ids = sources.map((s) => s.id).toList();

      expect(ids.toSet().length, ids.length,
          reason: '来源 id 重复会让 fetchFeed 派发到错误的适配器');
    });
  });
}
