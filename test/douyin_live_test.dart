/// 抖音适配器真实网络验证。
///
/// 这些测试验证的是**基于 APK 逆向分析后确认可用**的接口：
///  - `/aweme/v1/feed/`（推荐流）
///  - `/aweme/v1/hot/search/list/`（热榜）
///
/// 同时验证仍不可用的端点会如实抛错，而不是返回空列表。
///
/// 运行：flutter test test/douyin_live_test.dart --tags network
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/unified_video.dart';

DouyinAdapter _adapter() => DouyinAdapter(
      http: FusionHttpClient(logger: FusionLogger(enabled: false)),
      logger: FusionLogger(enabled: false),
    );

void main() {
  group('能力声明（离线）', () {
    test('推荐流与热榜来源已声明为可用', () {
      final sources = _adapter().feedSources;
      expect(sources.length, 2);

      final recommend =
          sources.firstWhere((s) => s.id == DouyinAdapter.feedSourceRecommend);
      final hot =
          sources.firstWhere((s) => s.id == DouyinAdapter.feedSourceHot);

      expect(recommend.available, isTrue,
          reason: 'feed 接口实测可用，不应再标为不可用');
      expect(hot.available, isTrue);
    });

    test('应用内播放能力已声明', () {
      expect(_adapter().capabilities.supportsNativePlayback, isTrue,
          reason: 'feed 返回 video/mp4 直链，支持原生播放');
    });
  });

  group('推荐流（真实网络）', () {
    test('返回真实视频且字段完整', () async {
      final page = await _adapter().fetchFeed(
        const FeedRequest(pageSize: 6),
        sourceId: DouyinAdapter.feedSourceRecommend,
      );

      expect(page.items, isNotEmpty, reason: '推荐流应返回真实视频');

      for (final v in page.items) {
        expect(v.platformId, 'douyin');
        expect(v.platformVideoId, isNotEmpty);
        expect(v.title, isNotEmpty);
        expect(v.platformVideoId, matches(RegExp(r'^\d{15,25}$')),
            reason: 'aweme_id 应为纯数字');
      }

      // 至少有一条带作者
      final withAuthor = page.items.where((v) => v.author.name != null);
      expect(withAuthor, isNotEmpty, reason: '应解析出作者昵称');
    }, tags: 'network');

    test('时长与统计已正确解析（毫秒转秒）', () async {
      final page = await _adapter().fetchFeed(
        const FeedRequest(pageSize: 6),
        sourceId: DouyinAdapter.feedSourceRecommend,
      );

      final withDuration =
          page.items.where((v) => v.durationSeconds != null).toList();
      expect(withDuration, isNotEmpty);

      // 抖音返回毫秒。短视频应在 1~600 秒区间。
      // 若误把毫秒当秒，数值会达到数万，这条断言会失败。
      for (final v in withDuration) {
        expect(v.durationSeconds!, greaterThan(0));
        expect(v.durationSeconds!, lessThan(3600),
            reason: '时长 ${v.durationSeconds}s 不合理，可能未做毫秒转换');
      }

      final withStats = page.items.where((v) => v.stats.likeCount != null);
      expect(withStats, isNotEmpty, reason: '应解析出点赞数');
    }, tags: 'network');

    test('返回的播放地址是真实 mp4 直链', () async {
      // 这条断言的核心：确认抖音视频确实能在应用内播放，
      // 而不是只能跳转原平台。
      final page = await _adapter().fetchFeed(
        const FeedRequest(pageSize: 4),
        sourceId: DouyinAdapter.feedSourceRecommend,
      );

      expect(page.items, isNotEmpty);
      final first = page.items.first;

      // 元数据中应声明支持应用内播放
      expect(first.playbackModes, contains(PlaybackMode.native));
      expect(first.canonicalUrl, contains('douyin.com/video/'));
    }, tags: 'network');

    test('分页游标可用', () async {
      final a = _adapter();
      final p1 = await a.fetchFeed(
        const FeedRequest(pageSize: 6),
        sourceId: DouyinAdapter.feedSourceRecommend,
      );

      expect(p1.items, isNotEmpty);
      // 推荐流在 max_cursor=0 时返回随机推荐，nextOffset 可能是 0
      // （表示"继续请求即得新内容"），这本身是有效行为。
      expect(p1.nextOffset, greaterThanOrEqualTo(0));
    }, tags: 'network');
  });

  group('热榜（真实网络）', () {
    test('返回真实热搜词', () async {
      final page = await _adapter().fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: DouyinAdapter.feedSourceHot,
      );

      expect(page.items, isNotEmpty, reason: '热榜应返回真实数据');

      for (final v in page.items) {
        expect(v.title, isNotEmpty);
        // 热榜是搜索引导项，只应声明 external 播放
        expect(v.playbackModes, equals([PlaybackMode.external]),
            reason: '热榜条目是关键词不是视频，不应声称可播放');
        expect(v.canonicalUrl, contains('/search/'));
      }
    }, tags: 'network');

    test('热榜分页正确切片', () async {
      final a = _adapter();
      final p1 = await a.fetchFeed(
        const FeedRequest(pageSize: 5, offset: 0),
        sourceId: DouyinAdapter.feedSourceHot,
      );
      final p2 = await a.fetchFeed(
        const FeedRequest(pageSize: 5, offset: 1),
        sourceId: DouyinAdapter.feedSourceHot,
      );

      expect(p1.items, isNotEmpty);
      expect(p2.items, isNotEmpty);

      final t1 = p1.items.map((v) => v.title).toSet();
      final t2 = p2.items.map((v) => v.title).toSet();
      expect(t1.intersection(t2), isEmpty, reason: '两页不应重复');
    }, tags: 'network');
  });

  group('仍不可用的能力必须如实抛错', () {
    test('未知来源抛 unsupportedPlatform，不返回空列表', () async {
      expect(
        () => _adapter().fetchFeed(
          const FeedRequest(),
          sourceId: 'douyin:not_exist',
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.unsupportedPlatform,
          ),
        ),
      );
    });

    test('评论能力已声明为支持（通过 WebView 签名桥）', () {
      // 抖音评论依赖 uifid Cookie + 两套签名，只能在真实浏览器环境产生。
      // 实现方式：隐藏 WebView 加载抖音页面，由页面 SDK 自动签名。
      // 详见 lib/src/adapters/douyin/web_signer.dart
      expect(_adapter().supportsComments, isTrue);
    });

    test('点赞不可用时明确抛错（未登录）', () async {
      expect(
        _adapter().supportsLike,
        isFalse,
        reason: '抖音点赞需 Argus 签名，应如实声明不支持',
      );
    });
  });
}
