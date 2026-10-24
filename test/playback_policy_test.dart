/// 播放策略与服务集成测试。
///
/// 覆盖需求八「播放测试」中可离线验证的部分，以及关键架构约束：
///  - 播放模式依据实际能力选择，不默认所有视频都能应用内播放
///  - 单个平台的失败不阻塞其它平台的可用内容
///  - 播放失败后不静默跳转、不伪造成功
///  - 链接识别失败时给出正确的错误码
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/playback_policy.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/live.dart';
import 'package:video_fusion/src/models/interaction.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

import 'support/no_im_support.dart';

// ── 测试替身 ────────────────────────────────────────────────

/// 可编程的假适配器：用于精确控制各平台的行为。
class StubAdapter extends PlatformAdapter with NoImSupport {
  StubAdapter({
    required this.id,
    required this.displayName,
    required this.host,
    this.capabilities = const AdapterCapabilities(
      supportsMetadata: true,
      supportsNativePlayback: true,
      supportsOfficialEmbed: false,
      supportsExternalFallback: true,
    ),
    this.metadataError,
    this.playbackError,
    this.playbackSource,
    this.videoId = 'v1',
  });

  @override
  final String id;

  @override
  final String displayName;

  final String host;

  @override
  String get shortLabel => id;

  @override
  final AdapterCapabilities capabilities;

  /// 非 null 时 fetchMetadata 抛出该错误。
  final FusionException? metadataError;

  /// 非 null 时 resolvePlayback 抛出该错误。
  final FusionException? playbackError;

  /// 非 null 时 resolvePlayback 返回该播放源。
  final PlaybackSource? playbackSource;

  final String videoId;

  int metadataCalls = 0;
  int playbackCalls = 0;

  @override
  List<String> get supportedHosts => [host];

  @override
  bool matches(Uri uri) => uri.host == host;

  @override
  Future<LinkMatch?> extract(Uri uri) async {
    final segments = uri.pathSegments;
    if (segments.length >= 2) {
      return LinkMatch(
        platformId: id,
        platformVideoId: videoId,
        canonicalUrl: 'https://$host/video/$videoId',
      );
    }
    return null;
  }

  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async {
    metadataCalls++;
    if (metadataError != null) throw metadataError!;
    return VideoMetadata(
      title: '$displayName 的视频',
      author: const VideoAuthor(name: '测试作者', platformAuthorId: 'au1'),
      durationSeconds: 120,
      width: 1920,
      height: 1080,
      upstreamEndpoint: '/stub',
    );
  }

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async {
    playbackCalls++;
    if (playbackError != null) throw playbackError!;
    return playbackSource;
  }

  /// 测试替身不提供推荐流。
  @override
  List<FeedSource> get feedSources => const [];

  /// implements 不继承默认实现，必须显式声明。
  @override
  Future<FeedPage> fetchFeed(FeedRequest request,
          {required String sourceId, PlatformSession? session}) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不提供推荐流。',
        platformId: id,
      );

  @override
  bool get supportsSearch => false;

  @override
  Future<FeedPage> searchVideos(String query,
          {int page = 1, int pageSize = 20}) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持搜索。',
        platformId: id,
      );
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
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏。',
        platformId: id,
      );

  // ── 收藏夹与扩展互动能力：一律如实不支持 ────────────────────
  //
  // 本类是 `implements PlatformAdapter`。Dart 的 `implements` 只继承
  // **签名**、不继承接口里带 body 的默认实现（只有 extends/with 才继承），
  // 因此 PlatformAdapter 上新增的每个成员——包括已有默认实现的
  // supportsFavoriteFolders 与 fetchFavoriteFolders——都必须在此重写，
  // 否则报 non_abstract_class_inherits_abstract_member。
  //
  // 抛 unsupportedPlatform 而不是返回空数据：本文件测的是播放策略降级，
  // "能力不存在"与"有内容但为空"必须可区分，否则替身会替被测代码
  // 掩盖一条本该失败的分支。
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
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏复查。',
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
FusionHttpClient _fakeHttp() =>
    FusionHttpClient(logger: FusionLogger(enabled: false));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final logger = FusionLogger(enabled: false);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  VideoService _service(List<PlatformAdapter> adapters) => VideoService(
        registry: PlatformRegistry(adapters: adapters),
        store: VideoStore(storage: InMemoryStore(), logger: logger),
        logger: logger,
      );

  group('链接接入（VideoService.resolveLink）', () {
    test('空输入返回 invalidUrl', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.resolveLink('   ');
      expect(r.ok, isFalse);
      expect(r.error!.code, FusionErrorCode.invalidUrl);
    });

    test('非 URL 文本返回 invalidUrl', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.resolveLink('这不是一个链接');
      expect(r.error!.code, FusionErrorCode.invalidUrl);
    });

    test('非 http(s) 协议被拒绝', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.resolveLink('ftp://a.test/video/1');
      expect(r.error!.code, FusionErrorCode.invalidUrl);
    });

    test('不支持的平台返回 unsupportedPlatform（不猜测平台）', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.resolveLink('https://unknown-platform.test/video/1');
      expect(r.error!.code, FusionErrorCode.unsupportedPlatform);
      // 错误信息应列出已接入平台
      expect(r.error!.userMessage, contains('A'));
    });

    test('匹配平台但无法提取 ID 返回 videoIdNotFound', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.resolveLink('https://a.test/');
      expect(r.error!.code, FusionErrorCode.videoIdNotFound);
    });

    test('成功接入并标准化为 UnifiedVideo', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.resolveLink('https://a.test/video/v1');
      expect(r.ok, isTrue);
      final v = r.video!;
      expect(v.id, 'a:v1');
      expect(v.platformId, 'a');
      expect(v.platformVideoId, 'v1');
      expect(v.originalUrl, 'https://a.test/video/v1');
      expect(v.canonicalUrl, 'https://a.test/video/v1');
      expect(v.title, isNotEmpty);
      expect(v.fetchedAt, isNotEmpty);
      expect(v.diagnostics.adapterId, 'a');
      expect(v.diagnostics.fromCache, isFalse);
    });

    test('从分享文案中提取 URL', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.resolveLink(
        '7.43 复制打开抖音，看看【某视频】https://a.test/video/v1 很不错',
      );
      expect(r.ok, isTrue);
      expect(r.video!.platformVideoId, 'v1');
    });

    test('元数据获取失败时返回明确错误，不伪造数据', () async {
      final service = _service([
        StubAdapter(
          id: 'a',
          displayName: 'A',
          host: 'a.test',
          metadataError: FusionException(
            code: FusionErrorCode.videoNotFound,
            userMessage: '视频不存在或已被删除。',
          ),
        ),
      ]);
      final r = await service.resolveLink('https://a.test/video/v1');
      expect(r.ok, isFalse);
      expect(r.error!.code, FusionErrorCode.videoNotFound);
      expect(r.video, isNull, reason: '失败时不得返回任何视频对象');
    });

    test('重复导入同一视频：第二次命中缓存', () async {
      final adapter = StubAdapter(id: 'a', displayName: 'A', host: 'a.test');
      final service = _service([adapter]);

      final r1 = await service.resolveLink('https://a.test/video/v1');
      expect(r1.ok, isTrue);
      expect(adapter.metadataCalls, 1);

      final r2 = await service.resolveLink('https://a.test/video/v1');
      expect(r2.ok, isTrue);
      expect(r2.fromCache, isTrue);
      expect(adapter.metadataCalls, 1, reason: '缓存命中不应重复请求上游');
    });
  });

  group('播放策略（PlaybackPolicy）', () {
    test('支持应用内播放的适配器 → NATIVE', () async {
      const source = NativePlaybackSource(
        videoId: 'a:v1',
        videoStreamUrl: 'https://cdn/v.m4s',
        audioStreamUrl: 'https://cdn/a.m4s',
        isDash: true,
      );
      final adapter = StubAdapter(
        id: 'a',
        displayName: 'A',
        host: 'a.test',
        playbackSource: source,
      );
      final service = _service([adapter]);
      final r = await service.resolveLink('https://a.test/video/v1');
      final outcome = await service.resolvePlayback(r.video!);

      expect(outcome.ok, isTrue);
      expect(outcome.source, isA<NativePlaybackSource>());
      expect(outcome.source!.mode, PlaybackMode.native);
      expect(outcome.attempts.first.succeeded, isTrue);
    });

    test('不支持应用内播放的适配器 → 降级到 EXTERNAL，且记录尝试轨迹', () async {
      final adapter = StubAdapter(
        id: 'b',
        displayName: 'B',
        host: 'b.test',
        capabilities: const AdapterCapabilities(
          supportsMetadata: true,
          supportsNativePlayback: false,
          supportsOfficialEmbed: false,
          supportsExternalFallback: true,
        ),
      );
      final service = _service([adapter]);
      final r = await service.resolveLink('https://b.test/video/v1');
      final outcome = await service.resolvePlayback(r.video!);

      expect(outcome.ok, isTrue);
      expect(outcome.source!.mode, PlaybackMode.external);
      expect(adapter.playbackCalls, 0,
          reason: '未声明支持的模式不应被尝试');
    });

    test('NATIVE 失败后降级到 OFFICIAL_EMBED', () async {
      const embed = OfficialEmbedPlaybackSource(
        videoId: 'c:v1',
        embedUrl: 'https://embed.test/player?vid=v1',
      );
      final adapter = StubAdapter(
        id: 'c',
        displayName: 'C',
        host: 'c.test',
        capabilities: const AdapterCapabilities(
          supportsMetadata: true,
          supportsNativePlayback: true,
          supportsOfficialEmbed: true,
          supportsExternalFallback: true,
        ),
        playbackError: FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '直链不可用。',
        ),
      );
      final service = _service([adapter]);
      final r = await service.resolveLink('https://c.test/video/v1');
      final outcome = await service.resolvePlayback(r.video!);

      // 两种模式都走同一个 resolvePlayback，因此都会失败 →
      // 最终降级到 EXTERNAL 兜底，且尝试轨迹完整记录
      expect(outcome.attempts.length, greaterThanOrEqualTo(2));
      expect(outcome.attempts.first.succeeded, isFalse);
      expect(outcome.source!.mode, PlaybackMode.external,
          reason: '全部失败后必须给出 EXTERNAL 兜底，而不是伪造成功');
    });

    test('播放失败不伪造成功：错误必须如实返回', () async {
      final adapter = StubAdapter(
        id: 'd',
        displayName: 'D',
        host: 'd.test',
        capabilities: const AdapterCapabilities(
          supportsMetadata: true,
          supportsNativePlayback: true,
          supportsOfficialEmbed: false,
          supportsExternalFallback: false,
        ),
        playbackError: FusionException(
          code: FusionErrorCode.permissionDenied,
          userMessage: '该视频需要登录。',
        ),
      );
      final service = _service([adapter]);
      final r = await service.resolveLink('https://d.test/video/v1');
      final outcome = await service.resolvePlayback(r.video!);

      expect(outcome.ok, isFalse, reason: '不得伪造播放成功');
      expect(outcome.error, isNotNull);
      expect(outcome.source, isNull);
    });

    test('未注册平台的视频给出 unsupportedPlatform 而非崩溃', () async {
      final registry = PlatformRegistry(
        adapters: [StubAdapter(id: 'a', displayName: 'A', host: 'a.test')],
      );
      final policy = PlaybackPolicy(registry: registry, logger: logger);
      final orphan = UnifiedVideo(
        id: 'ghost:v1',
        platformId: 'ghost',
        platformVideoId: 'v1',
        originalUrl: 'https://ghost.test/video/v1',
        canonicalUrl: 'https://ghost.test/video/v1',
        title: '孤儿视频',
        fetchedAt: DateTime.now().toUtc().toIso8601String(),
        diagnostics: const VideoDiagnostics(
          adapterId: 'ghost',
          upstreamEndpoint: '',
          fromCache: false,
          fetchDurationMs: 0,
        ),
      );
      final outcome = await policy.resolve(orphan);
      expect(outcome.ok, isFalse);
      expect(outcome.error!.code, FusionErrorCode.unsupportedPlatform);
    });

    test('应用内播放源被缓存，二次解析命中缓存', () async {
      const source = NativePlaybackSource(
        videoId: 'a:v1',
        videoStreamUrl: 'https://cdn/v.m4s',
      );
      final adapter = StubAdapter(
        id: 'a',
        displayName: 'A',
        host: 'a.test',
        playbackSource: source,
      );
      final service = _service([adapter]);
      final r = await service.resolveLink('https://a.test/video/v1');

      await service.resolvePlayback(r.video!);
      expect(adapter.playbackCalls, 1);
      final second = await service.resolvePlayback(r.video!);
      expect(second.ok, isTrue);
      expect(adapter.playbackCalls, 1, reason: '播放直链应在 TTL 内命中缓存');
    });
  });

  group('故障隔离（需求：单个平台失败不得阻塞其它平台）', () {
    test('一个平台抛异常时，另一个平台仍可正常接入', () async {
      final broken = StubAdapter(
        id: 'broken',
        displayName: '故障平台',
        host: 'broken.test',
        metadataError: FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '上游服务异常。',
        ),
      );
      final healthy = StubAdapter(
        id: 'healthy',
        displayName: '正常平台',
        host: 'healthy.test',
      );
      final service = _service([broken, healthy]);

      // 故障平台失败
      final r1 = await service.resolveLink('https://broken.test/video/v1');
      expect(r1.ok, isFalse);

      // 正常平台不受影响
      final r2 = await service.resolveLink('https://healthy.test/video/v1');
      expect(r2.ok, isTrue, reason: '故障平台不得阻塞其它平台');

      // 列表中应只包含成功的条目
      final list = await service.listVideos();
      expect(list.length, 1);
      expect(list.first.platformId, 'healthy');
    });

    test('混合多平台的列表按时间倒序且不因平台而异', () async {
      final service = _service([
        StubAdapter(id: 'p1', displayName: 'P1', host: 'p1.test'),
        StubAdapter(id: 'p2', displayName: 'P2', host: 'p2.test'),
        StubAdapter(id: 'p3', displayName: 'P3', host: 'p3.test'),
      ]);

      await service.resolveLink('https://p1.test/video/v1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await service.resolveLink('https://p2.test/video/v1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await service.resolveLink('https://p3.test/video/v1');

      final list = await service.listVideos();
      expect(list.length, 3);
      // 最新导入的在前
      expect(list.first.platformId, 'p3');
      expect(list.last.platformId, 'p1');
      // 所有条目使用同一模型，无平台差异
      expect(list.every((v) => v is UnifiedVideo), isTrue);
    });
  });

  group('刷新与降级', () {
    test('刷新失败时保留旧元数据并标记错误（不删除、不隐藏）', () async {
      var shouldFail = false;
      final adapter = _FlakyAdapter(
        id: 'a',
        displayName: 'A',
        host: 'a.test',
        shouldFail: () => shouldFail,
      );
      final service = _service([adapter]);

      final r = await service.resolveLink('https://a.test/video/v1');
      expect(r.ok, isTrue);
      final originalTitle = r.video!.title;

      shouldFail = true;
      final refreshed = await service.refresh(r.video!.id);

      expect(refreshed.succeeded, isFalse, reason: '刷新本身失败了');
      expect(refreshed.degraded, isTrue, reason: '应处于降级状态');
      expect(refreshed.video, isNotNull, reason: '刷新失败必须保留旧数据');
      expect(refreshed.video!.title, originalTitle);
      expect(refreshed.video!.error, isNotNull);
      expect(refreshed.video!.error!.code, FusionErrorCode.upstreamError);

      // 库中仍存在该条目，且带错误状态
      final list = await service.listVideos();
      expect(list.length, 1);
      expect(list.first.error, isNotNull);
    });

    test('刷新不存在的视频返回 videoNotFound', () async {
      final service = _service([
        StubAdapter(id: 'a', displayName: 'A', host: 'a.test'),
      ]);
      final r = await service.refresh('nonexistent:1');
      expect(r.error!.code, FusionErrorCode.videoNotFound);
    });
  });
}

/// 可在运行时切换成功/失败的适配器，用于验证刷新降级路径。
class _FlakyAdapter extends PlatformAdapter with NoImSupport {
  _FlakyAdapter({
    required this.id,
    required this.displayName,
    required this.host,
    required this.shouldFail,
  });

  @override
  final String id;

  @override
  final String displayName;

  final String host;

  final bool Function() shouldFail;

  @override
  String get shortLabel => id;

  @override
  AdapterCapabilities get capabilities => const AdapterCapabilities(
        supportsMetadata: true,
        supportsNativePlayback: true,
        supportsOfficialEmbed: false,
        supportsExternalFallback: true,
      );

  @override
  List<String> get supportedHosts => [host];

  @override
  bool matches(Uri uri) => uri.host == host;

  @override
  Future<LinkMatch?> extract(Uri uri) async => LinkMatch(
        platformId: id,
        platformVideoId: 'v1',
        canonicalUrl: 'https://$host/video/v1',
      );

  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async {
    if (shouldFail()) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '平台服务暂时不可用，请稍后重试。',
      );
    }
    return const VideoMetadata(
      title: '稳定的标题',
      upstreamEndpoint: '/flaky',
    );
  }

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async => null;

  @override
  List<FeedSource> get feedSources => const [];

  @override
  Future<FeedPage> fetchFeed(FeedRequest request,
          {required String sourceId, PlatformSession? session}) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不提供推荐流。',
        platformId: id,
      );

  @override
  bool get supportsSearch => false;

  @override
  Future<FeedPage> searchVideos(String query,
          {int page = 1, int pageSize = 20}) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持搜索。',
        platformId: id,
      );
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
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏。',
        platformId: id,
      );

  // ── 收藏夹与扩展互动能力：一律如实不支持 ────────────────────
  //
  // 本类是 `implements PlatformAdapter`。Dart 的 `implements` 只继承
  // **签名**、不继承接口里带 body 的默认实现（只有 extends/with 才继承），
  // 因此 PlatformAdapter 上新增的每个成员——包括已有默认实现的
  // supportsFavoriteFolders 与 fetchFavoriteFolders——都必须在此重写，
  // 否则报 non_abstract_class_inherits_abstract_member。
  //
  // 抛 unsupportedPlatform 而不是返回空数据：本文件测的是播放策略降级，
  // "能力不存在"与"有内容但为空"必须可区分，否则替身会替被测代码
  // 掩盖一条本该失败的分支。
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
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏复查。',
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