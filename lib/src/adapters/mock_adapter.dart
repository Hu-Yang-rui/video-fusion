/// 模拟平台适配器 —— **仅用于扩展性与架构验证**。
///
/// 需求八「扩展测试」要求：新增一个模拟平台适配器，
/// 使用明确标注的测试数据验证平台注册机制、数据标准化和播放分流。
///
/// 严格的诚实性约束：
///  - 本适配器**不得**伪装成真实的抖音或 B 站数据。
///  - 所有内容都带 "【测试】" 前缀，平台标识为 `mock`，
///    来源标签为"模拟平台"，在 UI 中一眼可辨。
///  - 它**不发起任何真实网络请求**，播放走 EXTERNAL 分支，
///    用于验证"非应用内播放"的降级路径。
library;

import '../core/credential_vault.dart';
import '../core/errors.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../models/feed.dart';
import '../models/interaction.dart';
import '../models/live.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'platform_adapter.dart';

class MockAdapter implements PlatformAdapter {
  MockAdapter({required FusionHttpClient http, FusionLogger? logger})
      : _http = http,
        _logger = logger ?? appLogger;

  // ignore: unused_field
  final FusionHttpClient _http;

  // ignore: unused_field
  final FusionLogger _logger;

  @override
  String get id => 'mock';

  @override
  String get displayName => '模拟平台（测试）';

  @override
  String get shortLabel => '模拟';

  /// 模拟适配器不实现搜索：它是扩展性验证用的，不是真实平台。
  @override
  bool get supportsSearch => false;

  @override
  Future<FeedPage> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '模拟平台不支持搜索。',
      technicalMessage: 'MockAdapter does not implement searchVideos',
      platformId: id,
    );
  }

  // ── 互动能力：模拟适配器不提供 ──────────────────────────────
  //
  // 它是扩展性验证用的假平台，没有真实后端，
  // 因此如实声明全部不支持，UI 不渲染互动按钮。

  @override
  bool get supportsComments => false;

  @override
  bool get supportsLike => false;

  @override
  bool get supportsCoin => false;

  @override
  bool get supportsFavorite => false;

  // 测试平台不提供直播。
  @override
  bool get supportsLive => false;

  @override
  Future<LiveRoomPage> fetchLiveRooms({
    int page = 1,
    int pageSize = 20,
    int? parentAreaId,
    int? areaId,
  }) =>
      throw _noLive('fetchLiveRooms');

  @override
  Future<LiveRoomInfo> fetchLiveRoomInfo(int roomId) =>
      throw _noLive('fetchLiveRoomInfo');

  @override
  Future<LiveRoomInfo> fetchLiveRoomInfoByKey(String roomKey) =>
      throw _noLive('fetchLiveRoomInfoByKey');

  @override
  Future<LiveStream> resolveLiveStream(int roomId, {int? quality}) =>
      throw _noLive('resolveLiveStream');

  @override
  Future<LiveStream> resolveLiveStreamByKey(
    String roomKey, {
    int? quality,
  }) =>
      throw _noLive('resolveLiveStreamByKey');

  @override
  Future<LiveDanmakuEndpoint> fetchLiveDanmakuEndpoint(int roomId) =>
      throw _noLive('fetchLiveDanmakuEndpoint');

  @override
  Future<List<LiveArea>> fetchLiveAreas() async => const [];

  FusionException _noLive(String method) => FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试平台不提供直播。',
        technicalMessage: 'MockAdapter does not implement $method',
        platformId: id,
      );

  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '模拟平台不支持评论。',
      technicalMessage: 'MockAdapter does not implement fetchComments',
      platformId: id,
    );
  }

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
  }) async {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '模拟平台不支持点赞。',
      technicalMessage: 'MockAdapter does not implement setLike',
      platformId: id,
    );
  }

  @override
  Future<InteractionResult> setCoin(
    String platformVideoId, {
    required int count,
    required PlatformSession session,
    bool alsoLike = false,
    int? aid,
  }) async {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '模拟平台不支持投币。',
      technicalMessage: 'MockAdapter does not implement setCoin',
      platformId: id,
    );
  }

  /// 收藏夹列表：模拟平台不提供。
  ///
  /// 这个适配器只用于验证"平台注册与数据标准化"机制（见 capabilities
  /// 的说明），不接任何真实平台接口，因此收藏夹能力如实声明为不支持并
  /// 抛错——返回空列表会把"能力不存在"伪装成"这个账号没有收藏夹"。
  @override
  Future<List<FavoriteFolder>> fetchFavoriteFolders({
    required PlatformSession session,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持收藏夹。',
        technicalMessage: 'favorite folders unsupported for this platform',
        platformId: id,
      );

  @override
  bool get supportsFavoriteFolders => false;

  // ── 其余互动能力：模拟平台一律不支持 ────────────────────────
  //
  // 必须逐个显式声明：本类用 `implements PlatformAdapter`，而 Dart 的
  // `implements` 只继承**签名**、**不继承**接口里带 body 的默认实现，
  // 少写一个成员就是 non_abstract_class_inherits_abstract_member 编译错误
  // （这些测试桩/适配器之前报错的确切原因）。

  @override
  bool get supportsFolderOwnershipScan => false;

  @override
  bool get supportsCoinBalance => false;

  @override
  bool get supportsWatchLater => false;

  @override
  bool get supportsFollowAuthor => false;

  @override
  bool get supportsSavedContent => false;

  @override
  Future<FolderOwnershipScan> scanFoldersContainingVideo({
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 12,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持收藏夹归属查询。',
        technicalMessage: 'MockAdapter does not implement folder scan',
        platformId: id,
      );

  @override
  Future<int?> fetchCoinBalance({required PlatformSession session}) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持硬币余额。',
        technicalMessage: 'MockAdapter does not implement fetchCoinBalance',
        platformId: id,
      );

  @override
  Future<bool> fetchWatchLater({
    required String platformVideoId,
    required PlatformSession session,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持稍后再看。',
        technicalMessage: 'MockAdapter does not implement fetchWatchLater',
        platformId: id,
      );

  @override
  Future<InteractionResult> setWatchLater({
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持稍后再看。',
        technicalMessage: 'MockAdapter does not implement setWatchLater',
        platformId: id,
      );

  @override
  Future<InteractionResult> setFollowAuthor({
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持关注。',
        technicalMessage: 'MockAdapter does not implement setFollowAuthor',
        platformId: id,
      );

  @override
  Future<SavedVideoPage> fetchFavoriteFolderVideos(
    int mediaId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持查看收藏夹内容。',
        technicalMessage:
            'MockAdapter does not implement fetchFavoriteFolderVideos',
        platformId: id,
      );

  @override
  Future<SavedVideoPage> fetchWatchLaterVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持稍后再看列表。',
        technicalMessage: 'MockAdapter does not implement fetchWatchLaterVideos',
        platformId: id,
      );

  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '模拟平台不支持收藏。',
      technicalMessage: 'MockAdapter does not implement setFavorite',
      platformId: id,
    );
  }

  /// 收藏结果复查：该平台不支持收藏夹，如实抛错。
  @override
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持收藏夹。',
        technicalMessage: 'MockAdapter has no favorite folders',
        platformId: id,
      );

  @override
  List<String> get supportedHosts => const ['mock.video-fusion.test'];

  @override
  AdapterCapabilities get capabilities => const AdapterCapabilities(
        supportsMetadata: true,
        supportsNativePlayback: false,
        supportsOfficialEmbed: false,
        supportsExternalFallback: true,
        requiresAuthForMetadata: false,
        requiresSignature: false,
        notes: [
          '这是一个用于验证平台注册机制与数据标准化的模拟适配器。',
          '其数据全部为明确标注的测试数据，不代表任何真实平台。',
          '不发起真实网络请求，播放走"跳转原平台"降级路径。',
        ],
      );

  @override
  bool matches(Uri uri) => uri.host.toLowerCase() == 'mock.video-fusion.test';

  // ── 推荐流（本地测试数据，用于验证竖滑流）─────────────────

  /// 模拟平台的"推荐流"完全由本地生成，**不发起任何网络请求**。
  ///
  /// 用途：在真实推荐流不可用或需要离线验证时，
  /// 验证竖滑流的分页、自动播放、上滑切换与布局适配。
  /// 所有内容都带【测试】前缀，不会与真实平台数据混淆。
  @override
  List<FeedSource> get feedSources => const [
        FeedSource(
          id: 'mock:local',
          adapterId: 'mock',
          label: '测试流',
          description: '本地生成的测试数据，用于验证竖滑流交互，不代表任何真实平台。',
        ),
      ];

  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
  }) async {
    if (sourceId != 'mock:local') {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '未知的测试流来源。',
        technicalMessage: 'Unknown mock feed sourceId=$sourceId',
        platformId: id,
      );
    }

    final items = <UnifiedVideo>[];
    final base = request.offset * request.safePageSize;

    for (var i = 0; i < request.safePageSize; i++) {
      final n = base + i;
      final match = await extract(
        Uri.parse('https://mock.video-fusion.test/video/feed-$n'),
      );
      if (match == null) continue;
      final meta = await fetchMetadata(match);
      items.add(UnifiedVideo(
        id: makeVideoId(id, match.platformVideoId),
        platformId: id,
        platformVideoId: match.platformVideoId,
        originalUrl: match.canonicalUrl,
        canonicalUrl: match.canonicalUrl,
        title: meta.title,
        description: meta.description,
        author: meta.author,
        coverUrl: meta.coverUrl,
        durationSeconds: meta.durationSeconds,
        aspectRatio: normalizeAspectRatio(meta.width, meta.height),
        width: meta.width,
        height: meta.height,
        publishedAt: meta.publishedAt,
        fetchedAt: DateTime.now().toUtc().toIso8601String(),
        stats: meta.stats,
        availability: VideoAvailability.available,
        playbackModes: const [PlaybackMode.external],
        diagnostics: const VideoDiagnostics(
          adapterId: 'mock',
          upstreamEndpoint: '(local-test-data)',
          fromCache: false,
          fetchDurationMs: 0,
          limitations: ['模拟数据不提供应用内播放。'],
          notes: ['本地生成的测试条目。'],
        ),
      ));
    }

    return FeedPage(
      items: items,
      // 测试流限制为 3 页，避免无限翻页
      hasMore: request.offset < 2,
      adapterId: id,
      upstreamEndpoint: '(local-test-data)',
      nextOffset: request.offset + 1,
      notes: const ['本地测试数据，未发起任何网络请求。'],
    );
  }

  @override
  Future<LinkMatch?> extract(Uri uri) async {
    // 支持的形态：https://mock.video-fusion.test/video/<id>
    final segments = uri.pathSegments;
    final idx = segments.indexOf('video');
    if (idx >= 0 && idx + 1 < segments.length) {
      final raw = segments[idx + 1];
      if (RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(raw)) {
        return LinkMatch(
          platformId: id,
          platformVideoId: raw,
          canonicalUrl: 'https://mock.video-fusion.test/video/$raw',
          notes: const ['该记录来自模拟适配器，为测试数据。'],
        );
      }
    }
    return null;
  }

  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async {
    final seed = match.platformVideoId;

    // 依据 id 稳定地产生不同特征，用于验证列表布局的多种情况：
    //  - 竖屏 / 横屏 / 方形
    //  - 有封面 / 无封面
    //  - 有作者 / 无作者
    //  - 有简介 / 无简介
    final hash = seed.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff);
    final variant = hash % 4;

    final (int? w, int? h, String? cover, String? author) = switch (variant) {
      0 => (1920, 1080, null, '测试作者甲'),
      1 => (1080, 1920, null, '测试作者乙'),
      2 => (1080, 1080, null, null),
      _ => (1280, 720, null, '测试作者丁'),
    };
    // cover 恒为 null：用于验证"缺少封面时布局正常"的 UI 要求
    final String? coverUrl = cover;

    return VideoMetadata(
      title: '【测试】模拟平台视频 $seed',
      description: variant == 2
          ? null
          : '这是由模拟适配器生成的测试条目，用于验证统一列表、'
              '封面比例适配与播放降级分流。它不代表任何真实平台的内容。',
      author: VideoAuthor(
        name: author,
        platformAuthorId: author == null ? null : 'mock_$seed',
        profileUrl: null,
        avatarUrl: null,
      ),
      coverUrl: coverUrl,
      durationSeconds: 60 + (hash % 600).toDouble(),
      width: w,
      height: h,
      publishedAt: DateTime.now()
          .subtract(Duration(days: hash % 400))
          .toUtc()
          .toIso8601String(),
      stats: VideoStats(
        viewCount: hash % 100000,
        likeCount: null,
        danmakuCount: null,
      ),
      availability: VideoAvailability.available,
      requiresAuth: false,
      limitations: const [
        '模拟适配器不提供应用内播放，用于验证播放降级分流路径。',
      ],
      notes: [
        '测试数据变体：$variant（用于覆盖不同宽高比与缺失字段组合）',
      ],
      upstreamEndpoint: '(local-test-data)',
    );
  }

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async {
    // 模拟平台不支持应用内播放：明确返回 null，
    // 由播放策略层降级到 EXTERNAL。这验证了"不伪造能力"的约束。
    throw FusionException(
      code: FusionErrorCode.capabilityUnavailable,
      userMessage: '模拟平台不提供应用内播放能力。',
      technicalMessage:
          'MockAdapter.resolvePlayback called; no native playback by design.',
      platformId: id,
    );
  }
}
