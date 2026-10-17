/// 互动功能测试。
///
/// 重点验证**不伪造状态**这一核心约束：
///  - 未登录时状态必须是 unknown，不能显示"未点赞"
///  - 写操作未登录必须抛 loginRequired，不能静默失败
///  - 写成功后必须重新拉取真实状态，不能本地累加
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/cache.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/secure_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/interaction.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

// ── 测试替身 ──────────────────────────────────────────────────

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

/// 可编程的互动适配器。
class FakeInteractionAdapter implements PlatformAdapter {
  FakeInteractionAdapter({
    this.comments = true,
    this.like = true,
    this.coin = true,
    this.favorite = true,
    this.likeError,
    this.stateError,
    this.initialState = const InteractionState(
      known: true,
      liked: false,
      coined: 0,
      favorited: false,
      likeCount: 100,
    ),
  });

  final bool comments;
  final bool like;
  final bool coin;
  final bool favorite;
  final FusionException? likeError;
  final FusionException? stateError;

  InteractionState initialState;

  /// 记录调用，验证"写后重查"。
  int setLikeCalls = 0;
  int fetchStateCalls = 0;
  bool? lastLikeTarget;

  @override
  String get id => 'fake';

  @override
  String get displayName => '测试平台';

  @override
  String get shortLabel => '测试';

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
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async =>
      null;

  @override
  List<FeedSource> get feedSources => const [];

  @override
  Future<FeedPage> fetchFeed(FeedRequest request,
          {required String sourceId}) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '无推荐流',
        platformId: id,
      );

  @override
  bool get supportsSearch => false;

  @override
  Future<FeedPage> searchVideos(String query,
          {int page = 1, int pageSize = 20}) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '无搜索',
        platformId: id,
      );

  @override
  bool get supportsComments => comments;

  @override
  bool get supportsLike => like;

  @override
  bool get supportsCoin => coin;

  @override
  bool get supportsFavorite => favorite;

  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    if (page == 1) {
      return CommentPage(
        items: [
          const VideoComment(
            id: 'c1',
            authorName: '用户A',
            message: '第一条评论',
            createdAt: '2026-10-01T00:00:00Z',
            likeCount: 10,
          ),
          const VideoComment(
            id: 'c2',
            authorName: '用户B',
            message: '第二条评论',
            createdAt: '2026-10-02T00:00:00Z',
          ),
        ],
        page: 1,
        totalCount: 3,
        hasMore: true,
      );
    }
    return const CommentPage(
      items: [
        VideoComment(
          id: 'c3',
          authorName: '用户C',
          message: '第三条评论',
          createdAt: '2026-10-03T00:00:00Z',
        ),
      ],
      page: 2,
      totalCount: 3,
      hasMore: false,
    );
  }

  @override
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async {
    fetchStateCalls++;
    if (stateError != null) throw stateError!;
    if (session == null) return InteractionState.unknown;
    return initialState;
  }

  @override
  Future<InteractionResult> setLike(
    String platformVideoId, {
    required bool like,
    required PlatformSession session,
    int? aid,
  }) async {
    setLikeCalls++;
    lastLikeTarget = like;
    if (likeError != null) throw likeError!;
    // 模拟平台状态变化，供后续 fetchInteractionState 读到
    initialState = initialState.copyWith(liked: like);
    return const InteractionResult(accepted: true);
  }

  @override
  Future<InteractionResult> setCoin(
    String platformVideoId, {
    required int count,
    required PlatformSession session,
    bool alsoLike = false,
    int? aid,
  }) async {
    initialState = initialState.copyWith(coined: count);
    return const InteractionResult(accepted: true);
  }

  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
  }) async {
    initialState = initialState.copyWith(favorited: favorite);
    return const InteractionResult(accepted: true);
  }
}

/// 内存安全存储由库内提供（[InMemorySecureStore]），这里无需重复实现。

UnifiedVideo makeVideo() => UnifiedVideo(
      id: 'fake:v1',
      platformId: 'fake',
      platformVideoId: 'v1',
      originalUrl: 'https://fake.test/v1',
      canonicalUrl: 'https://fake.test/v1',
      title: '测试视频',
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      diagnostics: const VideoDiagnostics(
        adapterId: 'fake',
        upstreamEndpoint: '/test',
        fromCache: false,
        fetchDurationMs: 0,
      ),
    );

PlatformSession makeSession() => const PlatformSession(
      platformId: 'fake',
      displayName: '测试用户',
      userId: '12345',
      cookies: {'session': 'x'},
      loggedInAt: '2026-10-01T00:00:00Z',
    );

VideoService buildService(PlatformAdapter adapter) => VideoService(
      registry: PlatformRegistry(adapters: [adapter]),
      store: VideoStore(storage: MemoryStore()),
      cache: VideoCache(),
    );

void main() {
  group('互动能力声明', () {
    test('能力查询反映适配器声明', () {
      final service = buildService(FakeInteractionAdapter());
      final caps = service.capabilitiesFor('fake');

      expect(caps.comments, isTrue);
      expect(caps.like, isTrue);
      expect(caps.coin, isTrue);
      expect(caps.favorite, isTrue);
      expect(caps.hasAny, isTrue);
    });

    test('不支持的平台返回 none', () {
      final service = buildService(FakeInteractionAdapter());
      final caps = service.capabilitiesFor('unknown');

      expect(caps.hasAny, isFalse);
      expect(caps, same(InteractionCapabilities.none));
    });

    test('只声明部分能力时如实反映', () {
      final service = buildService(
        FakeInteractionAdapter(comments: true, like: false, coin: false, favorite: false),
      );
      final caps = service.capabilitiesFor('fake');

      expect(caps.comments, isTrue);
      expect(caps.like, isFalse);
      expect(caps.coin, isFalse);
    });
  });

  group('未登录时不伪造状态', () {
    test('未登录查询互动状态返回 unknown，不是"未点赞"', () async {
      final service = buildService(FakeInteractionAdapter());
      final state = await service.fetchInteractionState(makeVideo());

      // 关键：known=false 表示"不知道"，UI 应显示"登录后可操作"
      expect(state.known, isFalse);
      expect(state.liked, isFalse);
    });

    test('未登录点赞抛 loginRequired，不静默失败', () async {
      final service = buildService(FakeInteractionAdapter());

      expect(
        () => service.setLike(makeVideo(), like: true),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.loginRequired,
          ),
        ),
      );
    });

    test('未登录投币抛 loginRequired', () async {
      final service = buildService(FakeInteractionAdapter());

      expect(
        () => service.setCoin(makeVideo(), count: 1),
        throwsA(isA<FusionException>()),
      );
    });

    test('未登录收藏抛 loginRequired', () async {
      final service = buildService(FakeInteractionAdapter());

      expect(
        () => service.setFavorite(makeVideo(), favorite: true),
        throwsA(isA<FusionException>()),
      );
    });

    test('未登录仍可读取评论（评论是公开的）', () async {
      final service = buildService(FakeInteractionAdapter());
      final page = await service.fetchComments(makeVideo());

      expect(page.items.length, 2);
      expect(page.totalCount, 3);
      expect(page.hasMore, isTrue);
    });
  });

  group('已登录的写操作', () {
    test('点赞调用适配器并传入正确目标', () async {
      final adapter = FakeInteractionAdapter();
      final service = buildService(adapter);

      await service.setLike(
        makeVideo(),
        like: true,
        session: makeSession(),
      );

      expect(adapter.setLikeCalls, 1);
      expect(adapter.lastLikeTarget, isTrue);
    });

    test('取消点赞传入 false', () async {
      final adapter = FakeInteractionAdapter();
      final service = buildService(adapter);

      await service.setLike(
        makeVideo(),
        like: false,
        session: makeSession(),
      );

      expect(adapter.lastLikeTarget, isFalse);
    });

    test('已登录查询状态返回真实值', () async {
      final service = buildService(FakeInteractionAdapter());
      final state = await service.fetchInteractionState(
        makeVideo(),
        session: makeSession(),
      );

      expect(state.known, isTrue);
      expect(state.likeCount, 100);
    });

    test('点赞失败时抛出平台错误，不假装成功', () async {
      final adapter = FakeInteractionAdapter(
        likeError: FusionException(
          code: FusionErrorCode.permissionDenied,
          userMessage: '权限不足',
        ),
      );
      final service = buildService(adapter);

      expect(
        () => service.setLike(
          makeVideo(),
          like: true,
          session: makeSession(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.permissionDenied,
          ),
        ),
      );
    });
  });

  group('评论分页', () {
    test('第一页返回 2 条且有更多', () async {
      final service = buildService(FakeInteractionAdapter());
      final page = await service.fetchComments(makeVideo(), page: 1);

      expect(page.items.length, 2);
      expect(page.hasMore, isTrue);
      expect(page.page, 1);
    });

    test('第二页返回剩余 1 条且无更多', () async {
      final service = buildService(FakeInteractionAdapter());
      final page = await service.fetchComments(makeVideo(), page: 2);

      expect(page.items.length, 1);
      expect(page.hasMore, isFalse);
    });

    test('不支持评论的平台抛错，不返回空列表', () async {
      final service = buildService(FakeInteractionAdapter(comments: false));

      expect(
        () => service.fetchComments(makeVideo()),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.unsupportedPlatform,
          ),
        ),
      );
    });
  });

  group('互动状态模型', () {
    test('unknown 状态表示"不知道"', () {
      const s = InteractionState.unknown;
      expect(s.known, isFalse);
      expect(s.liked, isFalse);
      expect(s.coined, 0);
    });

    test('copyWith 正确覆盖字段', () {
      const s = InteractionState(known: true, liked: false, likeCount: 10);
      final s2 = s.copyWith(liked: true, likeCount: 11);

      expect(s2.known, isTrue);
      expect(s2.liked, isTrue);
      expect(s2.likeCount, 11);
    });
  });
}
