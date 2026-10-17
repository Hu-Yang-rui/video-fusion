/// 跨平台搜索与观看进度测试。
///
/// 验证：
///  - 搜索失败与"没有结果"必须可区分
///  - 单平台失败不影响其它平台
///  - 观看进度的续播判定逻辑
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/cache.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/video_progress_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/live.dart';
import 'package:video_fusion/src/models/interaction.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

// ── 测试替身 ──────────────────────────────────────────────────

/// 内存键值存储。
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

/// 可配置的搜索适配器。
class FakeSearchAdapter implements PlatformAdapter {
  FakeSearchAdapter({
    required this.id,
    required this.displayName,
    this.supports = true,
    this.failWith,
    this.resultCount = 3,
  });

  @override
  final String id;

  @override
  final String displayName;

  final bool supports;
  final FusionException? failWith;
  final int resultCount;

  int searchCallCount = 0;

  @override
  String get shortLabel => displayName;

  @override
  bool get supportsSearch => supports;

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
  bool matches(Uri uri) => uri.host == 'fake.test';

  @override
  Future<LinkMatch?> extract(Uri uri) async => null;

  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async =>
      const VideoMetadata(title: 'fake');

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async => null;

  @override
  List<FeedSource> get feedSources => const [];

  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
  }) async {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '不支持推荐流',
      platformId: id,
    );
  }

  @override
  Future<FeedPage> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    searchCallCount++;
    if (failWith != null) throw failWith!;
    return FeedPage(
      items: [
        for (var i = 0; i < resultCount; i++)
          UnifiedVideo(
            id: '$id:v$i',
            platformId: id,
            platformVideoId: 'v$i',
            originalUrl: 'https://fake.test/v$i',
            canonicalUrl: 'https://fake.test/v$i',
            title: '$query 结果 $i',
            fetchedAt: DateTime.now().toUtc().toIso8601String(),
            diagnostics: VideoDiagnostics(
              adapterId: id,
              upstreamEndpoint: '/search',
              fromCache: false,
              fetchDurationMs: 0,
            ),
          ),
      ],
      hasMore: false,
      adapterId: id,
      upstreamEndpoint: '/search',
    );
  }

  // ── 互动能力（测试替身统一不支持）────────────────────────────
  @override
  bool get supportsComments => false;

  @override
  bool get supportsLike => false;

  @override
  bool get supportsCoin => false;

  @override
  bool get supportsFavorite => false;

  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持评论。',
        platformId: id,
      );

  @override
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async =>
      InteractionState.unknown;

  @override
  Future<InteractionResult> setLike(
    String platformVideoId, {
    required bool like,
    required PlatformSession session,
    int? aid,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持点赞。',
        platformId: id,
      );

  @override
  Future<InteractionResult> setCoin(
    String platformVideoId, {
    required int count,
    required PlatformSession session,
    bool alsoLike = false,
    int? aid,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持投币。',
        platformId: id,
      );

  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏。',
        platformId: id,
      );

  // ── 直播：测试桩不支持 ──────────────────────────────────────
  @override
  bool get supportsLive => false;

  @override
  Future<LiveRoomPage> fetchLiveRooms({
    int page = 1,
    int pageSize = 20,
    int? parentAreaId,
    int? areaId,
  }) =>
      throw UnimplementedError('live not supported in test stub');

  @override
  Future<LiveRoomInfo> fetchLiveRoomInfo(int roomId) =>
      throw UnimplementedError('live not supported in test stub');

  @override
  Future<LiveStream> resolveLiveStream(int roomId, {int? quality}) =>
      throw UnimplementedError('live not supported in test stub');

  @override
  Future<LiveDanmakuEndpoint> fetchLiveDanmakuEndpoint(int roomId) =>
      throw UnimplementedError('live not supported in test stub');

  @override
  Future<List<LiveArea>> fetchLiveAreas() async => const [];
}

VideoService buildService(List<PlatformAdapter> adapters) => VideoService(
      registry: PlatformRegistry(adapters: adapters),
      store: VideoStore(storage: MemoryStore()),
      cache: VideoCache(),
    );

void main() {
  group('跨平台搜索', () {
    test('空关键词返回明确错误，不发起请求', () async {
      final adapter = FakeSearchAdapter(id: 'a', displayName: 'A');
      final service = buildService([adapter]);

      final result = await service.searchVideos('   ');

      expect(result.ok, isFalse);
      expect(result.error!.code, FusionErrorCode.invalidUrl);
      expect(adapter.searchCallCount, 0);
    });

    test('单个平台返回结果', () async {
      final service = buildService([
        FakeSearchAdapter(id: 'a', displayName: 'A', resultCount: 3),
      ]);

      final result = await service.searchVideos('猫');

      expect(result.ok, isTrue);
      expect(result.items.length, 3);
      expect(result.items.first.title, contains('猫'));
      expect(result.failures, isEmpty);
    });

    test('多平台结果合并', () async {
      final service = buildService([
        FakeSearchAdapter(id: 'a', displayName: 'A', resultCount: 2),
        FakeSearchAdapter(id: 'b', displayName: 'B', resultCount: 3),
      ]);

      final result = await service.searchVideos('猫');

      expect(result.ok, isTrue);
      expect(result.items.length, 5);
      expect(result.items.map((v) => v.platformId).toSet(), {'a', 'b'});
    });

    test('单平台失败不影响其它平台（部分失败可区分）', () async {
      final service = buildService([
        FakeSearchAdapter(id: 'a', displayName: 'A', resultCount: 2),
        FakeSearchAdapter(
          id: 'b',
          displayName: 'B',
          failWith: FusionException(
            code: FusionErrorCode.rateLimited,
            userMessage: '限流',
          ),
        ),
      ]);

      final result = await service.searchVideos('猫');

      // 仍有内容，但记录了失败
      expect(result.ok, isTrue);
      expect(result.items.length, 2);
      expect(result.hasPartialFailure, isTrue);
      expect(result.failures.containsKey('b'), isTrue);
      expect(result.failures['b']!.code, FusionErrorCode.rateLimited);
    });

    test('全部平台失败时返回错误，不是空结果', () async {
      final service = buildService([
        FakeSearchAdapter(
          id: 'a',
          displayName: 'A',
          failWith: FusionException(
            code: FusionErrorCode.networkError,
            userMessage: '网络失败',
          ),
        ),
      ]);

      final result = await service.searchVideos('猫');

      // 关键：失败不能被伪装成"没有搜到"
      expect(result.ok, isFalse);
      expect(result.error!.code, FusionErrorCode.networkError);
      expect(result.items, isEmpty);
    });

    test('没有支持搜索的平台时返回明确错误', () async {
      final service = buildService([
        FakeSearchAdapter(id: 'a', displayName: 'A', supports: false),
      ]);

      final result = await service.searchVideos('猫');

      expect(result.ok, isFalse);
      expect(result.error!.code, FusionErrorCode.capabilityUnavailable);
    });

    test('只向支持搜索的平台发起请求', () async {
      final searchable = FakeSearchAdapter(id: 'a', displayName: 'A');
      final notSearchable =
          FakeSearchAdapter(id: 'b', displayName: 'B', supports: false);
      final service = buildService([searchable, notSearchable]);

      await service.searchVideos('猫');

      expect(searchable.searchCallCount, 1);
      expect(notSearchable.searchCallCount, 0);
    });
  });

  group('观看进度', () {
    late MemoryStore storage;
    late VideoProgressStore store;

    setUp(() {
      storage = MemoryStore();
      store = VideoProgressStore(storage: storage);
    });

    test('保存后可读取', () async {
      await store.save(
        videoId: 'bilibili:BV1',
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 10),
      );

      final record = await store.get('bilibili:BV1');
      expect(record, isNotNull);
      expect(record!.position.inMinutes, 2);
      expect(record.duration.inMinutes, 10);
      expect(record.ratio, closeTo(0.2, 0.01));
    });

    test('播放时间过短（<3s）不记录，避免噪声', () async {
      await store.save(
        videoId: 'bilibili:BV1',
        position: const Duration(seconds: 1),
        duration: const Duration(minutes: 10),
      );

      expect(await store.get('bilibili:BV1'), isNull);
    });

    test('时长为零不记录', () async {
      await store.save(
        videoId: 'bilibili:BV1',
        position: const Duration(seconds: 30),
        duration: Duration.zero,
      );

      expect(await store.get('bilibili:BV1'), isNull);
    });

    test('看了 20% 属于可续播', () async {
      await store.save(
        videoId: 'v1',
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 10),
      );

      final record = await store.get('v1');
      expect(record!.isResumable, isTrue);
      expect(record.isFinished, isFalse);
    });

    test('看到 96% 视为已看完，不再续播', () async {
      await store.save(
        videoId: 'v1',
        position: const Duration(seconds: 96),
        duration: const Duration(seconds: 100),
      );

      final record = await store.get('v1');
      expect(record!.isFinished, isTrue);
      expect(record.isResumable, isFalse);
    });

    test('只看了 3 秒属于不可续播（太短）', () async {
      await store.save(
        videoId: 'v1',
        position: const Duration(seconds: 4),
        duration: const Duration(minutes: 10),
      );

      final record = await store.get('v1');
      // 超过 3s 会被记录，但 4s 太短不值得续播
      expect(record, isNotNull);
      expect(record!.isResumable, isFalse);
    });

    test('resumable 只返回未看完的记录', () async {
      await store.save(
        videoId: 'watched',
        position: const Duration(seconds: 99),
        duration: const Duration(seconds: 100),
      );
      await store.save(
        videoId: 'partial',
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 10),
      );

      final list = await store.resumable();
      expect(list.length, 1);
      expect(list.first.videoId, 'partial');
    });

    test('进度持久化到存储（重启后可恢复）', () async {
      await store.save(
        videoId: 'v1',
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 10),
      );

      // 模拟重启：新建 store 读取同一存储
      final reopened = VideoProgressStore(storage: storage);
      final record = await reopened.get('v1');

      expect(record, isNotNull);
      expect(record!.position.inMinutes, 3);
    });

    test('删除与清空', () async {
      await store.save(
        videoId: 'v1',
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 10),
      );
      await store.save(
        videoId: 'v2',
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 10),
      );

      await store.remove('v1');
      expect(await store.get('v1'), isNull);
      expect(await store.get('v2'), isNotNull);

      await store.clear();
      expect(await store.all(), isEmpty);
    });

    test('损坏的单条记录不影响其它记录', () async {
      // 直接写入一条损坏数据
      await storage.write(
        'video_fusion.progress.v1',
        '[{"videoId":"bad","positionMs":"not-a-number"}]',
      );

      final reopened = VideoProgressStore(storage: storage);
      // 不应抛异常
      final all = await reopened.all();
      expect(all, isEmpty);
    });
  });
}
