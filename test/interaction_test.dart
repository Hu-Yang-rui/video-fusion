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
import 'package:video_fusion/src/models/live.dart';
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
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async {
    // 记录本次操作的夹列表，供"选了哪几个夹"这类断言使用。
    lastFolderIds = folderIds;
    lastRemoveFolderIds = removeFolderIds;
    initialState = initialState.copyWith(favorited: favorite);
    return const InteractionResult(accepted: true);
  }

  /// 最近一次 setFavorite 传入的加入/移出收藏夹列表。
  List<int>? lastFolderIds;
  List<int>? lastRemoveFolderIds;

  // ── 收藏夹与扩展互动能力：本替身一律不支持 ──────────────────
  //
  // 为什么必须逐个写出来：本类用的是 `implements PlatformAdapter`。
  // Dart 里 `implements` 只继承**签名**，**不继承**接口中带 body 的
  // 默认实现（只有 `extends`/`with` 才继承实现）。所以哪怕
  // PlatformAdapter 已经给了 `supportsFavoriteFolders => false`
  // 和会抛 unsupportedPlatform 的默认 fetchFavoriteFolders，
  // 这里不重写就会报 non_abstract_class_inherits_abstract_member。
  //
  // 语义保持"如实不支持"：抛错而不是返回空列表——返回空列表会让
  // "能力不存在"伪装成"这个账号没有收藏夹"，把替身自己测错。
  @override
  bool get supportsFavoriteFolders => false;

  @override
  Future<List<FavoriteFolder>> fetchFavoriteFolders({
    required PlatformSession session,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏夹。',
        platformId: id,
      );

  @override
  bool get supportsFolderOwnershipScan => false;

  @override
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏结果复查。',
        platformId: id,
      );

  @override
  Future<FolderOwnershipScan> scanFoldersContainingVideo({
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 6,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏夹归属查询。',
        platformId: id,
      );

  @override
  bool get supportsCoinBalance => false;

  @override
  Future<int?> fetchCoinBalance({required PlatformSession session}) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持硬币余额。',
        platformId: id,
      );

  @override
  bool get supportsWatchLater => false;

  @override
  Future<bool> fetchWatchLater({
    required String platformVideoId,
    required PlatformSession session,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持稍后再看。',
        platformId: id,
      );

  @override
  Future<InteractionResult> setWatchLater({
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持稍后再看。',
        platformId: id,
      );

  @override
  bool get supportsFollowAuthor => false;

  @override
  Future<InteractionResult> setFollowAuthor({
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持关注。',
        platformId: id,
      );

  @override
  bool get supportsSavedContent => false;

  @override
  Future<SavedVideoPage> fetchFavoriteFolderVideos(
    int mediaId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持查看收藏夹内容。',
        platformId: id,
      );

  @override
  Future<SavedVideoPage> fetchWatchLaterVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持稍后再看列表。',
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
  Future<LiveRoomInfo> fetchLiveRoomInfoByKey(String roomKey) =>
      throw UnimplementedError('live not supported in test stub');


  @override
  Future<LiveRoomInfo> fetchLiveRoomInfo(int roomId) =>
      throw UnimplementedError('live not supported in test stub');

  @override
  Future<LiveStream> resolveLiveStreamByKey(String roomKey, {int? quality}) =>
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

/// 支持收藏夹与扩展互动能力的替身。
///
/// 存在的理由不是"多一个假适配器"，而是**契约本身需要被验证**：
/// VideoService 的透传（夹列表 / 归属扫描 / 余额 / 稍后再看 / 关注）
/// 和 capabilitiesFor 的新字段，用"一律不支持"的替身只能测到抛错分支，
/// 测不到"支持时数据是否原样到达调用方"。UI 的回显逻辑依赖这条通路。
///
/// 数据是真实语义的固定夹具（默认夹按名称识别、归属含 2 个夹），
/// 不是随手编的空壳。
class _FolderCapableAdapter extends FakeInteractionAdapter {
  _FolderCapableAdapter();

  static const int defaultFolderId = 62851852;
  static const int secondFolderId = 4020481152;

  List<FavoriteFolder>? lastFolderListRequest;

  /// 归属扫描被调用的次数（用于断言"未收藏时不该扫描"）。
  int scanCalls = 0;

  /// 最近一次扫描收到的请求预算（验证 maxRequests 真的透传到底）。
  int? lastMaxRequests;

  /// 最近一次复查收到的翻页上限与目标夹（验证参数透传）。
  int? lastMaxPages;
  List<int>? lastVerifyTargets;

  /// 这个替身自己的"视频 → 所在夹"状态。
  ///
  /// 复查与扫描都必须读**同一份**状态，否则测出来的"写后复查"
  /// 只是一场自说自话：真实闭环是 setFavorite 改状态 →
  /// verifyRecentFavorite 读状态，两者必须接得上。
  final Set<int> containedIn = {defaultFolderId};

  @override
  bool get supportsFavoriteFolders => true;

  @override
  bool get supportsFolderOwnershipScan => true;

  @override
  bool get supportsCoinBalance => true;

  @override
  bool get supportsWatchLater => true;

  @override
  bool get supportsFollowAuthor => true;

  @override
  bool get supportsSavedContent => true;

  @override
  Future<List<FavoriteFolder>> fetchFavoriteFolders({
    required PlatformSession session,
  }) async {
    final folders = const [
      FavoriteFolder(
        id: defaultFolderId,
        title: '默认收藏夹',
        mediaCount: 32,
        isDefault: true,
      ),
      FavoriteFolder(
        id: secondFolderId,
        title: 'gay',
        mediaCount: 1,
      ),
    ];
    lastFolderListRequest = folders;
    return folders;
  }

  @override
  Future<FolderOwnershipScan> scanFoldersContainingVideo({
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 6,
  }) async {
    scanCalls++;
    lastMaxRequests = maxRequests;
    // 读替身自己的状态，而不是写死一个答案——
    // 这样"收藏→复查→扫描"三步读到的是同一份事实。
    final hits = containedIn.toList();
    return FolderOwnershipScan(
      containedFolderIds: hits,
      checkedFolderIds: const [defaultFolderId, secondFolderId],
      exhaustive: true,
      requestsUsed: 3,
    );
  }

  @override
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) async {
    // 无条件记录收到的参数：这样才能验证**透传层**是否原样传参
    // （空列表是否被偷偷换成默认夹，是本用例要守住的回归点）。
    lastMaxPages = maxPages;
    lastVerifyTargets = folderIds;
    // 只回答"目标夹里有没有"，语义与真实适配器一致：
    // 返回目标夹与已包含集合的交集，顺序按传入的目标夹。
    return [for (final id in folderIds) if (containedIn.contains(id)) id];
  }

  /// 收藏写操作在替身里**真的改状态**，供复查读出。
  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async {
    if (folderIds != null) {
      for (final id in folderIds) {
        containedIn.add(id);
      }
    } else if (favorite) {
      containedIn.add(defaultFolderId);
    }
    if (removeFolderIds != null) {
      for (final id in removeFolderIds) {
        containedIn.remove(id);
      }
    } else if (!favorite) {
      containedIn.remove(defaultFolderId);
    }
    return super.setFavorite(
      platformVideoId,
      favorite: favorite,
      session: session,
      aid: aid,
      folderIds: folderIds,
      removeFolderIds: removeFolderIds,
    );
  }

  @override
  Future<int?> fetchCoinBalance({required PlatformSession session}) async => 7;

  @override
  Future<bool> fetchWatchLater({
    required String platformVideoId,
    required PlatformSession session,
  }) async =>
      true;

  @override
  Future<InteractionResult> setWatchLater({
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) async =>
      InteractionResult(accepted: true, message: add ? '已加入' : '已移出');

  @override
  Future<InteractionResult> setFollowAuthor({
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) async =>
      InteractionResult(accepted: true, message: follow ? '已关注' : '已取关');

  @override
  Future<SavedVideoPage> fetchFavoriteFolderVideos(
    int mediaId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async =>
      SavedVideoPage(
        items: [makeVideo()],
        hasMore: false,
        total: 1,
        adapterId: id,
        upstreamEndpoint: '/x/v3/fav/resource/list',
      );

  @override
  Future<SavedVideoPage> fetchWatchLaterVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async =>
      SavedVideoPage(
        items: [makeVideo()],
        hasMore: true,
        total: 21,
        adapterId: id,
        upstreamEndpoint: '/x/v2/history/toview/web',
      );
}

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
      // 新增字段在 unknown 态同样只表示"不知道"，不是"未关注/未加入"
      expect(s.following, isFalse);
      expect(s.watchLater, isFalse);
      expect(s.favoritedFolderIds, isEmpty);
    });

    test('copyWith 正确覆盖字段', () {
      const s = InteractionState(known: true, liked: false, likeCount: 10);
      final s2 = s.copyWith(liked: true, likeCount: 11);

      expect(s2.known, isTrue);
      expect(s2.liked, isTrue);
      expect(s2.likeCount, 11);
    });

    test('copyWith 覆盖收藏夹归属与新增状态字段', () {
      const s = InteractionState(known: true);
      final s2 = s.copyWith(
        favoritedFolderIds: const [1, 2],
        following: true,
        watchLater: true,
      );

      expect(s2.inFolder(1), isTrue);
      expect(s2.inFolder(2), isTrue);
      expect(s2.inFolder(3), isFalse);
      expect(s2.following, isTrue);
      expect(s2.watchLater, isTrue);
      // 未传的参数保持原值，不得被重置
      expect(s2.liked, isFalse);
    });
  });

  // ── 收藏夹与扩展互动能力的契约通路 ─────────────────────────
  //
  // 这些用例守护的是**契约**而不是平台细节：UI 只调 VideoService，
  // 所以"能力开关 → 数据透传"这条链必须原样通。
  // 平台细节（fav_state 的坑、翻页、csrf 码映射）在
  // 适配器里用注释与实测记录守护，需要网络，不进单测。
  group('收藏夹能力契约（VideoService 透传）', () {
    test('能力开关如实透传到 capabilitiesFor', () {
      final service = buildService(_FolderCapableAdapter());
      final caps = service.capabilitiesFor('fake');

      expect(caps.favoriteFolders, isTrue);
      expect(caps.coinBalance, isTrue);
      expect(caps.watchLater, isTrue);
      expect(caps.follow, isTrue);
      expect(caps.savedContent, isTrue);
    });

    test('不支持的适配器新能力一律 false（默认值不被误开）', () {
      final caps = buildService(FakeInteractionAdapter()).capabilitiesFor('fake');

      expect(caps.favoriteFolders, isFalse);
      expect(caps.coinBalance, isFalse);
      expect(caps.watchLater, isFalse);
      expect(caps.follow, isFalse);
      expect(caps.savedContent, isFalse);
      // 既有字段语义不变：hasAny 仍只看评论/点赞/投币/收藏，
      // 新增能力不得混进来（否则只支持余额的平台会显示点赞按钮）
      expect(caps.hasAny, isTrue);
    });

    test('supportsFavoriteFoldersFor / supportsSavedContentFor / '
        'supportsFolderOwnershipScanFor 如实回答', () {
      final capable = buildService(_FolderCapableAdapter());
      expect(capable.supportsFavoriteFoldersFor('fake'), isTrue);
      expect(capable.supportsSavedContentFor('fake'), isTrue);
      expect(capable.supportsFolderOwnershipScanFor('fake'), isTrue);

      final plain = buildService(FakeInteractionAdapter());
      expect(plain.supportsFavoriteFoldersFor('fake'), isFalse);
      expect(plain.supportsSavedContentFor('fake'), isFalse);
      expect(plain.supportsFolderOwnershipScanFor('fake'), isFalse);

      // 未接入的平台必须是 false，而不是抛错——UI 靠它决定渲不渲染
      expect(plain.supportsFavoriteFoldersFor('nope'), isFalse);
    });

    test('收藏夹列表按原样透传（默认夹标记不丢）', () async {
      final service = buildService(_FolderCapableAdapter());
      final folders = await service.fetchFavoriteFolders(
        'fake',
        session: makeSession(),
      );

      expect(folders.length, 2);
      // 默认夹靠**名称**识别，不靠数组下标——顺序变了也不能错
      expect(folders.first.isDefault, isTrue);
      expect(folders.last.isDefault, isFalse);
      expect(folders.first.mediaCount, 32);
    });

    test('归属扫描透传三态（命中/已核对/未核对）', () async {
      final adapter = _FolderCapableAdapter();
      // 显式设定归属：两个夹都包含该视频（替身的扫描读的就是这份状态）
      adapter.containedIn.addAll([
        _FolderCapableAdapter.defaultFolderId,
        _FolderCapableAdapter.secondFolderId,
      ]);
      final service = buildService(adapter);
      final scan = await service.scanFoldersContainingVideo(
        'fake',
        platformVideoId: 'BV1xx411c7mD',
        session: makeSession(),
      );

      expect(scan.containedFolderIds, [
        _FolderCapableAdapter.defaultFolderId,
        _FolderCapableAdapter.secondFolderId,
      ]);
      expect(adapter.scanCalls, 1);
      expect(scan.contains(_FolderCapableAdapter.defaultFolderId), isTrue);
      expect(scan.isChecked(_FolderCapableAdapter.defaultFolderId), isTrue);
      // 三态语义：没核对过 ≠ 不包含。UI 靠这两个判断显示"未核对"标记，
      // 若把 isUnknown 当成"未收藏"，就会给出假的否定。
      expect(scan.isUnknown(999999), isTrue);
      expect(scan.exhaustive, isTrue);
      expect(scan.rateLimited, isFalse);
    });

    test('归属扫描的预算参数透传到适配器', () async {
      final adapter = _FolderCapableAdapter();
      final service = buildService(adapter);

      await service.scanFoldersContainingVideo(
        'fake',
        platformVideoId: 'BV1xx411c7mD',
        session: makeSession(),
        maxRequests: 3,
      );

      // UI 会按面板自身大小给预算；透传丢了就等于预算失控
      expect(adapter.lastMaxRequests, 3);
    });

    test('收藏闭环：写入 → 复查目标夹 → 只读目标夹不越界', () async {
      final adapter = _FolderCapableAdapter();
      final service = buildService(adapter);
      final session = makeSession();
      const second = _FolderCapableAdapter.secondFolderId;

      // 初始只在默认夹
      expect(
        await service.verifyRecentFavorite(
          'fake',
          platformVideoId: 'v1',
          folderIds: const [_FolderCapableAdapter.defaultFolderId, second],
          session: session,
        ),
        [_FolderCapableAdapter.defaultFolderId],
      );

      // 加进第二个夹、同时从默认夹移出
      final result = await service.setFavorite(
        makeVideo(),
        favorite: true,
        session: session,
        folderIds: const [second],
        removeFolderIds: const [_FolderCapableAdapter.defaultFolderId],
      );
      expect(result.accepted, isTrue);

      // 复查必须如实反映状态变化
      expect(
        await service.verifyRecentFavorite(
          'fake',
          platformVideoId: 'v1',
          folderIds: const [second, _FolderCapableAdapter.defaultFolderId],
          session: session,
        ),
        [second],
      );

      // 复查只能碰**目标夹**：越界去扫别的夹就又变成高成本路径了
      expect(adapter.lastVerifyTargets,
          [second, _FolderCapableAdapter.defaultFolderId]);
      expect(adapter.scanCalls, 0);
    });

    test('复查：空目标夹列表原样返回空，不被替换成臆造的默认夹', () async {
      final adapter = _FolderCapableAdapter();
      final service = buildService(adapter);

      final got = await service.verifyRecentFavorite(
        'fake',
        platformVideoId: 'v1',
        folderIds: const [],
        session: makeSession(),
        maxPages: 3,
      );

      expect(got, isEmpty);
      // 真正的风险不是"返回空"，而是透传层把空列表悄悄当成
      // "那就查默认夹吧"——那会让一次取消收藏被误报成"没删掉"。
      // 替身无条件记录参数，所以这里断言的是**透传层有没有篡改入参**。
      expect(adapter.lastVerifyTargets, isEmpty);
      expect(adapter.lastMaxPages, 3);
    });

    test('复查：maxPages 与目标夹列表原样透传到适配器', () async {
      final adapter = _FolderCapableAdapter();
      final service = buildService(adapter);

      await service.verifyRecentFavorite(
        'fake',
        platformVideoId: 'v1',
        folderIds: const [
          _FolderCapableAdapter.defaultFolderId,
          _FolderCapableAdapter.secondFolderId,
        ],
        session: makeSession(),
        maxPages: 1,
      );

      expect(adapter.lastMaxPages, 1);
      expect(adapter.lastVerifyTargets, [
        _FolderCapableAdapter.defaultFolderId,
        _FolderCapableAdapter.secondFolderId,
      ]);
    });

    test('supportsFavoriteVerify 与 supportsFavoriteFoldersFor 同源', () {
      final capable = buildService(_FolderCapableAdapter());
      final plain = buildService(FakeInteractionAdapter());

      // 复查与选择面板是同一个能力的两种用法：要么都能，要么都不能。
      // UI 用这个决定"写后是否复查"，两者不一致就会给出死按钮。
      expect(capable.supportsFavoriteVerify('fake'),
          capable.supportsFavoriteFoldersFor('fake'));
      expect(plain.supportsFavoriteVerify('fake'), isFalse);
      expect(plain.supportsFavoriteFoldersFor('fake'), isFalse);
    });

    test('余额/稍后再看/关注 透传', () async {
      final service = buildService(_FolderCapableAdapter());
      final session = makeSession();

      expect(await service.fetchCoinBalance('fake', session: session), 7);
      expect(
        await service.fetchWatchLater(
          'fake',
          platformVideoId: 'BV1xx411c7mD',
          session: session,
        ),
        isTrue,
      );
      expect(
        (await service.setWatchLater(
          'fake',
          platformVideoId: 'BV1xx411c7mD',
          add: true,
          session: session,
        ))
            .accepted,
        isTrue,
      );
      expect(
        (await service.setFollowAuthor(
          'fake',
          targetMid: '9871',
          follow: true,
          session: session,
        ))
            .message,
        '已关注',
      );
    });

    test('已保存内容分页透传（总数与 hasMore 不丢）', () async {
      final service = buildService(_FolderCapableAdapter());
      final session = makeSession();

      final fav = await service.fetchFavoriteFolderVideos(
        'fake',
        _FolderCapableAdapter.defaultFolderId,
        session: session,
      );
      expect(fav.total, 1);
      expect(fav.hasMore, isFalse);
      expect(fav.items.single.platformVideoId, 'v1');

      final wl = await service.fetchWatchLaterVideos('fake', session: session);
      expect(wl.total, 21);
      expect(wl.hasMore, isTrue);
      expect(wl.adapterId, 'fake');
    });

    test('未接入平台的透传抛 unsupportedPlatform，不返回空数据', () async {
      final service = buildService(FakeInteractionAdapter());
      final session = makeSession();

      // 每条透传都必须"失败就说失败"：返回空列表/0/false 会把
      // "平台未接入"伪装成"这个账号没有收藏夹/没有币"。
      final calls = <String, Future<Object?> Function()>{
        'fetchFavoriteFolders':
            () => service.fetchFavoriteFolders('nope', session: session),
        'fetchCoinBalance':
            () => service.fetchCoinBalance('nope', session: session),
        'scanFoldersContainingVideo': () => service.scanFoldersContainingVideo(
              'nope',
              platformVideoId: 'v1',
              session: session,
            ),
        'fetchWatchLaterVideos':
            () => service.fetchWatchLaterVideos('nope', session: session),
      };

      for (final entry in calls.entries) {
        // 包一层 async：_adapterFor 是**同步**抛错的（它在返回 Future 之前
        // 就抛），直接把 entry.value() 交给 expectLater 会让异常逃出断言。
        Future<Object?> invoke() async => entry.value();
        await expectLater(
          invoke(),
          throwsA(
            isA<FusionException>().having(
              (e) => e.code,
              'code',
              FusionErrorCode.unsupportedPlatform,
            ),
          ),
          reason: '${entry.key} 在未接入平台上必须抛错',
        );
      }
    });

    test('setFavorite 把夹列表参数原样交给适配器', () async {
      final adapter = FakeInteractionAdapter();
      final service = buildService(adapter);
      final session = makeSession();

      await service.setFavorite(
        makeVideo(),
        favorite: true,
        session: session,
        folderIds: const [11, 22],
        removeFolderIds: const [33],
      );

      // 两个列表各走各的：加哪几个、移出哪几个，不能互相覆盖
      expect(adapter.lastFolderIds, const [11, 22]);
      expect(adapter.lastRemoveFolderIds, const [33]);
      expect(adapter.initialState.favorited, isTrue);
    });

    test('不传夹列表时 setFavorite 保持旧语义（只靠布尔）', () async {
      final adapter = FakeInteractionAdapter();
      final service = buildService(adapter);

      await service.setFavorite(
        makeVideo(),
        favorite: true,
        session: makeSession(),
      );

      expect(adapter.lastFolderIds, isNull);
      expect(adapter.lastRemoveFolderIds, isNull);
      expect(adapter.initialState.favorited, isTrue);
    });
  });
}
