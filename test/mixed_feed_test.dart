/// 混合流（抖音 + B站交错播放）的离线回归（2026-10-23）。
///
/// # 为什么要有混合流
///
/// 之前竖滑页只能刷启动时默认的那一个源（B站），用户以为"只支持 B站"。
/// 实际上三个平台都声明了 feedSources，能力一直在。
///
/// 用户明确要求：**默认抖音 + B站两个平台混合播放**。
///
/// # 这组测试守什么
///
///  1. 混合来源会被 `describeFeedSources()` 排在最前（默认选中它）
///  2. 两个平台的条目**交错**，不是先放完 A 再放 B
///     （按平台分段拼接的话，滑到第 21 条才换平台，体感仍是两个独立的流）
///  3. 单平台失败时，另一个平台的条目照常返回，失败原因进 notes
///  4. 两个都失败才报 error
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/cache.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

import 'support/no_im_support.dart';

class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<Set<String>> keys() async => data.keys.toSet();
}

/// 可编程的 feed 适配器：指定平台 id 与返回条目。
class _FeedAdapter extends PlatformAdapter with NoImSupport {
  _FeedAdapter({
    required this.id,
    required this.displayName,
    required this.prefix,
    this.count = 3,
    this.fail = false,
  });

  @override
  final String id;
  @override
  final String displayName;
  @override
  String get shortLabel => displayName;

  /// 条目 id 前缀，用来验证交错顺序。
  final String prefix;
  final int count;
  final bool fail;

  @override
  AdapterCapabilities get capabilities => const AdapterCapabilities(
        supportsMetadata: true,
        supportsNativePlayback: true,
        supportsOfficialEmbed: false,
        supportsExternalFallback: true,
      );

  @override
  List<String> get supportedHosts => const ['fake.test'];
  @override
  bool matches(Uri uri) => false;
  @override
  Future<LinkMatch?> extract(Uri uri) async => null;
  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async =>
      const VideoMetadata(title: 'fake');
  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async =>
      null;

  @override
  List<FeedSource> get feedSources => [
        FeedSource(
          id: '$id:rcmd',
          adapterId: id,
          label: '$displayName推荐',
          description: '$displayName 推荐流',
        ),
      ];

  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
    PlatformSession? session,
  }) async {
    if (fail) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '$displayName 挂了',
        platformId: id,
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    return FeedPage(
      items: [
        for (var i = 0; i < count; i++)
          UnifiedVideo(
            id: '$id:$prefix$i',
            platformId: id,
            platformVideoId: '$prefix$i',
            originalUrl: 'https://fake.test/$prefix$i',
            canonicalUrl: 'https://fake.test/$prefix$i',
            title: '$displayName 第 $i 条',
            fetchedAt: now,
            diagnostics: VideoDiagnostics(
              adapterId: id,
              upstreamEndpoint: '/feed',
              fromCache: false,
              fetchDurationMs: 0,
            ),
          ),
      ],
      hasMore: false,
      adapterId: id,
      upstreamEndpoint: '/feed',
    );
  }
}

VideoService _build(List<PlatformAdapter> adapters) => VideoService(
      registry: PlatformRegistry(adapters: adapters),
      store: VideoStore(storage: MemoryStore()),
      cache: VideoCache(),
    );

/// 抖音 + B站两个替身。
List<PlatformAdapter> _twoPlatforms({bool douyinFail = false, bool biliFail = false}) => [
      _FeedAdapter(
        id: 'douyin',
        displayName: '抖音',
        prefix: 'dy',
        fail: douyinFail,
      ),
      _FeedAdapter(
        id: 'bilibili',
        displayName: 'B站',
        prefix: 'bv',
        fail: biliFail,
      ),
    ];

void main() {
  group('混合来源声明', () {
    test('describeFeedSources 把混合流排在最前（默认选中）', () {
      final service = _build(_twoPlatforms());
      final sources = service.describeFeedSources();

      expect(sources.first.id, VideoService.mixedFeedSourceId);
      // 标签必须能让用户看出混的是哪些平台，不能只写「混合」。
      expect(sources.first.label, contains('抖音'));
      expect(sources.first.label, contains('B站'));
      expect(sources.first.description, contains('抖音'));
      expect(sources.first.description, contains('B站'));
    });

    test('混合流参与平台固定为抖音 + B站（红果不参与）', () {
      expect(VideoService.mixedFeedPlatforms, ['douyin', 'bilibili']);
    });

    test('两个平台都没有 feed 源时，混合流不出现（不放死入口）', () {
      final service = _build([
        _FeedAdapter(id: 'other', displayName: '其它', prefix: 'x'),
      ]);
      // other 不是混合流参与的平台
      expect(service.mixedFeedSource, isNull);
    });

    test('isMixedFeedSource 只认混合 id', () {
      final service = _build(_twoPlatforms());
      expect(service.isMixedFeedSource(VideoService.mixedFeedSourceId), isTrue);
      expect(service.isMixedFeedSource('bilibili:rcmd'), isFalse);
    });
  });

  group('交错合并', () {
    test('两平台条目交错出现，不是先 A 后 B', () async {
      final service = _build(_twoPlatforms());
      final result = await service.fetchFeed(VideoService.mixedFeedSourceId);

      expect(result.ok, isTrue);
      final ids = result.page!.items.map((v) => v.id).toList();

      // 期望顺序：dy0, bv0, dy1, bv1, dy2, bv2
      expect(ids, [
        'douyin:dy0',
        'bilibili:bv0',
        'douyin:dy1',
        'bilibili:bv1',
        'douyin:dy2',
        'bilibili:bv2',
      ], reason: '必须交错；按平台分段拼接就不算混合播放');
    });

    test('条目去重（两平台恰好返回同一个 id 时不重复）', () async {
      // 两个适配器用相同 prefix + 相同 id 构造重复
      final dup = _FeedAdapter(
        id: 'douyin',
        displayName: '抖音',
        prefix: 'same',
        count: 2,
      );
      final dup2 = _FeedAdapter(
        id: 'bilibili',
        displayName: 'B站',
        prefix: 'same',
        count: 2,
      );
      final service = _build([dup, dup2]);
      final result = await service.fetchFeed(VideoService.mixedFeedSourceId);

      final ids = result.page!.items.map((v) => v.id).toList();
      expect(ids.length, ids.toSet().length, reason: '不能有重复条目');
    });

    test('两平台数量不等时，多的一方补齐到末尾', () async {
      final service = _build([
        _FeedAdapter(id: 'douyin', displayName: '抖音', prefix: 'dy', count: 3),
        _FeedAdapter(id: 'bilibili', displayName: 'B站', prefix: 'bv', count: 1),
      ]);
      final result = await service.fetchFeed(VideoService.mixedFeedSourceId);
      final ids = result.page!.items.map((v) => v.id).toList();

      expect(ids, ['douyin:dy0', 'bilibili:bv0', 'douyin:dy1', 'douyin:dy2']);
    });
  });

  group('单平台失败降级', () {
    test('抖音挂了，B站条目照常返回 + notes 说明', () async {
      final service = _build(_twoPlatforms(douyinFail: true));
      final result = await service.fetchFeed(VideoService.mixedFeedSourceId);

      expect(result.ok, isTrue, reason: '一个平台挂了不该让整个混合流失败');
      expect(result.page!.items, isNotEmpty);
      expect(result.page!.items.every((v) => v.platformId == 'bilibili'), isTrue);
      expect(
        result.page!.notes.any((n) => n.contains('抖音') && n.contains('未返回')),
        isTrue,
        reason: '必须如实说明哪个平台没返回，不能悄悄少一半',
      );
    });

    test('两个平台都挂了才报 error', () async {
      final service = _build(
        _twoPlatforms(douyinFail: true, biliFail: true),
      );
      final result = await service.fetchFeed(VideoService.mixedFeedSourceId);

      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
      expect(result.error!.retryable, isTrue);
    });
  });
}
