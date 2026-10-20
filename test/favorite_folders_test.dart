/// 「B站收藏修复 + 统一互动状态管理」的回归测试。
///
/// # 这组测试守护的是什么缺陷
///
///  1. **收藏点了只弹提示、按钮不高亮**。根因是互动状态解析把 B站
///     `archive/relation` 的字段当计数器用：`favorite` / `like` /
///     `attention` 实测是 **bool**，只有 `coin` 是 0/1/2 的次数。旧代码写
///     `(d['like'] as num?)?.toInt()`，在布尔形态上抛 TypeError，被外层
///     catch 静默吞成 `InteractionState.unknown` —— 于是写操作 code=0
///     成功、SnackBar 提示也对，但按钮的 `favorited` 永远是 false。
///  2. **假成功**。B站 `fav/resource/deal` 对**不存在**的收藏夹也返回
///     `code=0 message=OK`，且 `data.success_num` 恒为 0（两个方向都不能用）。
///     所以"返回 true"必须等于"复查后服务端归属真的达到用户期望"，
///     而不是"平台接受了请求"。
///  3. **两页状态不一致**。推荐页与详情页过去各建一份控制器。现在由
///     [InteractionRegistry] 按 `UnifiedVideo.id` 引用计数复用同一实例，
///     导入 Cookie 后 `recalibrateAll()` 必须让已打开的页面立刻变已知。
///  4. **限流下的假否定**。归属只能逐夹翻 `resource/list` 比对 bvid
///     （`fav_state` 实测与归属无关），而 B站连发第 6 个请求起返回
///     HTTP 412。扫描因此可能只跑完一部分夹：既没命中、也没核对完的夹
///     状态是**不知道**，UI 必须显示「未核对」而不是渲染成未勾选。
///
/// # 结论来源
///
/// 上述字段形态、错误码与限流阈值都是**真实接口实测**（2026-10-18/19）
/// 的结论（见 `lib/src/adapters/bilibili_adapter.dart` 与
/// `lib/src/adapters/platform_adapter.dart` 的 dartdoc）。本文件的响应
/// 结构照抄实测样本，全部离线、可重复：B站真实形态用假 HTTP 客户端喂
/// 构造响应，控制器行为用 `implements PlatformAdapter` 的可编程替身。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/cache.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/secure_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/interaction.dart';
import 'package:video_fusion/src/models/live.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

import 'support/no_im_support.dart';
import 'package:video_fusion/src/ui/interaction/interaction_controller.dart';
import 'package:video_fusion/src/ui/interaction/interaction_registry.dart';

// ── 夹具 ──────────────────────────────────────────────────────

const int folderA = 62851852; // 实测账号的默认收藏夹 ID
const int folderB = 4020481152; // 实测账号的自建夹「gay」
const int folderC = 3683371952; // 实测账号的自建夹「神人视频」（145 条）
const String bvid = 'BV1ySJx6YETj';

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

UnifiedVideo makeVideo({
  String platformId = 'fake',
  String platformVideoId = 'v1',
  String? authorId = '9871',
}) =>
    UnifiedVideo(
      id: makeVideoId(platformId, platformVideoId),
      platformId: platformId,
      platformVideoId: platformVideoId,
      originalUrl: 'https://fake.test/$platformVideoId',
      canonicalUrl: 'https://fake.test/$platformVideoId',
      title: '测试视频',
      author: VideoAuthor(name: '测试UP主', platformAuthorId: authorId),
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      diagnostics: const VideoDiagnostics(
        adapterId: 'fake',
        upstreamEndpoint: '/test',
        fromCache: false,
        fetchDurationMs: 0,
      ),
    );

PlatformSession makeSession({String platformId = 'fake'}) => PlatformSession(
      platformId: platformId,
      displayName: '测试用户',
      userId: '11066452',
      cookies: const {'SESSDATA': 'x', 'bili_jct': 'y'},
      loggedInAt: '2026-10-19T00:00:00Z',
    );

VideoService buildService(PlatformAdapter adapter) => VideoService(
      registry: PlatformRegistry(adapters: [adapter]),
      store: VideoStore(storage: MemoryStore()),
      cache: VideoCache(),
    );

CredentialVault vaultWithSession({bool login = true, String platformId = 'fake'}) {
  final vault = CredentialVault(storage: InMemorySecureStore());
  if (login) vault.save(makeSession(platformId: platformId));
  return vault;
}

/// 支持收藏夹 + 归属扫描 + 余额/稍后再看/关注的可编程替身适配器。
///
/// 结构照抄 `test/interaction_test.dart` 里 `implements PlatformAdapter`
/// 的替身：**每个成员都必须写出来** —— Dart 的 `implements` 只继承签名，
/// 不继承接口中带 body 的默认实现，漏一个就报
/// non_abstract_class_inherits_abstract_member。
///
/// # 它模拟的是"服务端真相"
///
///  [serverFoldersOfVideo] 表示"该视频实际在哪些夹里"。写操作默认真的落到
///  这份真相上（[applyWrites]=true）；要复现 B站的**假成功**（code=0 但没
///  生效）就设为 false：写请求照样返回 accepted，服务端却纹丝不动。
///  这样"复查"才有东西可查 —— 否则测试只是在看返回值，没有在看契约。
class FolderCapableAdapter extends PlatformAdapter with NoImSupport {
  FolderCapableAdapter({
    this.supportsFolders = true,
    this.supportsScan = true,
    this.coinBalanceSupported = true,
    this.watchLaterSupported = true,
    this.followSupported = true,
    this.applyWrites = true,
    this.setFavoriteAccepted = true,
    this.setFavoriteMessage,
    this.reportsIdsInState = true,
    this.scanExhaustive = true,
    this.scanRateLimited = false,
    this.stateError,
    this.setFavoriteError,
    int? coinBalance,
    Set<int> serverFoldersOfVideo = const {},
    bool favorited = false,
    this.liked = false,
    this.coined = 0,
    this.following = false,
    this.watchLaterOnServer = false,
    List<FavoriteFolder>? folders,
  })  : _coinBalance = coinBalance,
        // `archive/relation.favorite` 的语义：有归属才是 true
        _favoritedFromState = favorited || serverFoldersOfVideo.isNotEmpty,
        serverFoldersOfVideo = {...serverFoldersOfVideo},
        folders = folders ??
            const [
              FavoriteFolder(
                id: folderA,
                title: '默认收藏夹',
                mediaCount: 32,
                isDefault: true,
              ),
              FavoriteFolder(id: folderB, title: 'gay', mediaCount: 1),
              FavoriteFolder(id: folderC, title: '神人视频', mediaCount: 145),
            ];

  // ── 服务端真相 ──────────────────────────────────────────────

  bool _favoritedFromState;
  bool liked;
  int coined;
  bool following;
  bool watchLaterOnServer;

  /// 余额：null = 平台不下发该字段（≠ 0 个币，这两种语义必须区分）。
  int? _coinBalance;

  /// 该视频实际所在的夹。
  final Set<int> serverFoldersOfVideo;

  final List<FavoriteFolder> folders;

  // ── 行为开关 ────────────────────────────────────────────────

  final bool supportsFolders;
  final bool supportsScan;
  final bool coinBalanceSupported;
  final bool watchLaterSupported;
  final bool followSupported;

  /// 写请求是否真的改服务端。false = 复现「code=0 但没生效」的假成功。
  final bool applyWrites;
  final bool setFavoriteAccepted;
  final String? setFavoriteMessage;

  /// `fetchInteractionState` 是否顺带给出归属夹 ID。
  ///
  /// B站**不给**（`archive/relation` 没有归属字段，真实适配器固定返回空
  /// 列表），所以 false 才是线上形态；true 是"能力更强的平台"的形态。
  final bool reportsIdsInState;

  final bool scanExhaustive;
  final bool scanRateLimited;

  final FusionException? stateError;
  final FusionException? setFavoriteError;

  // ── 调用记录（断言用）──────────────────────────────────────

  int fetchStateCalls = 0;
  int fetchFoldersCalls = 0;
  int scanCalls = 0;
  int setFavoriteCalls = 0;
  int setWatchLaterCalls = 0;
  int fetchWatchLaterCalls = 0;
  int setFollowCalls = 0;
  int fetchCoinBalanceCalls = 0;

  List<int>? lastFolderIds;
  List<int>? lastRemoveFolderIds;
  bool? lastFavoriteFlag;
  String? lastFollowMid;
  bool? lastFollowTarget;
  bool? lastWatchLaterAdd;

  /// 一次性互动状态响应队列 + 对齐的延迟（竞态用例用）。
  ///
  /// 用**独立游标**消费：`fetchStateCalls` 先被 init 的拉取占掉，
  /// 拿它当下标会让竞态用例错位取到别的响应。
  final List<InteractionState> _queuedResponses = [];
  final List<int> _queuedDelays = [];
  int _queueCursor = 0;

  void queueStates(
    List<InteractionState> states, {
    List<int> delaysMs = const [],
  }) {
    _queuedResponses
      ..clear()
      ..addAll(states);
    _queuedDelays
      ..clear()
      ..addAll(delaysMs);
    _queueCursor = 0;
  }

  InteractionState serverStateSnapshot() => InteractionState(
        known: true,
        liked: liked,
        coined: coined,
        favorited: _favoritedFromState,
        // 计数的权威来源是 view.stat，不是 relation：这里必须留 null，
        // 否则 UI 的 `state.likeCount ?? video.stats.likeCount` 回退被顶掉。
        likeCount: null,
        coinCount: null,
        favoriteCount: null,
        favoritedFolderIds:
            reportsIdsInState ? serverFoldersOfVideo.toList() : const [],
        following: following,
        watchLater: watchLaterOnServer,
      );

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
  bool get supportsComments => true;

  @override
  bool get supportsLike => true;

  @override
  bool get supportsCoin => true;

  @override
  bool get supportsFavorite => true;

  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async =>
      const CommentPage(
        items: [
          VideoComment(
            id: 'c1',
            authorName: '用户A',
            message: '第一条评论',
            createdAt: '2026-10-01T00:00:00Z',
          ),
        ],
        page: 1,
        totalCount: 1,
        hasMore: false,
      );

  @override
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async {
    fetchStateCalls++;
    // 未登录必须 unknown，不得伪造"未收藏"
    if (session == null) return InteractionState.unknown;
    if (stateError != null) throw stateError!;
    if (_queuedResponses.isNotEmpty) {
      final i = _queueCursor.clamp(0, _queuedResponses.length - 1);
      _queueCursor = i + 1;
      final delay = i < _queuedDelays.length ? _queuedDelays[i] : 0;
      if (delay > 0) {
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
      return _queuedResponses[i];
    }
    return serverStateSnapshot();
  }

  @override
  Future<InteractionResult> setLike(
    String platformVideoId, {
    required bool like,
    required PlatformSession session,
    int? aid,
  }) async {
    if (applyWrites) liked = like;
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
    if (applyWrites) {
      coined = count;
      if (_coinBalance != null) _coinBalance = _coinBalance! - count;
    }
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
    setFavoriteCalls++;
    lastFavoriteFlag = favorite;
    lastFolderIds = folderIds;
    lastRemoveFolderIds = removeFolderIds;
    if (setFavoriteError != null) throw setFavoriteError!;

    if (applyWrites) {
      // 按 add_media_ids / del_media_ids 的语义改服务端真相
      if (folderIds != null) serverFoldersOfVideo.addAll(folderIds);
      if (removeFolderIds != null) {
        serverFoldersOfVideo.removeAll(removeFolderIds);
      }
      if (folderIds == null && removeFolderIds == null) {
        // 旧语义：true → 默认夹，false → 从全部归属移出
        if (favorite) {
          serverFoldersOfVideo.add(folderA);
        } else {
          serverFoldersOfVideo.clear();
        }
      }
      _favoritedFromState = serverFoldersOfVideo.isNotEmpty;
    }

    return InteractionResult(
      accepted: setFavoriteAccepted,
      message: setFavoriteMessage,
      upstreamCode: setFavoriteAccepted ? 0 : 11010,
    );
  }

  @override
  bool get supportsFavoriteFolders => supportsFolders;

  @override
  Future<List<FavoriteFolder>> fetchFavoriteFolders({
    required PlatformSession session,
  }) async {
    fetchFoldersCalls++;
    if (!supportsFolders) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏夹。',
        platformId: id,
      );
    }
    return folders;
  }

  @override
  bool get supportsFolderOwnershipScan => supportsScan;

  @override
  Future<FolderOwnershipScan> scanFoldersContainingVideo({
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 12,
  }) async {
    scanCalls++;
    if (!supportsScan) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持归属查询。',
        platformId: id,
      );
    }
    final contained = serverFoldersOfVideo.toList();
    return FolderOwnershipScan(
      containedFolderIds: contained,
      // 没跑完时只交代"已翻到底的那几个"，其余留给调用方当"不知道"
      checkedFolderIds:
          scanExhaustive ? folders.map((f) => f.id).toList() : contained,
      exhaustive: scanExhaustive,
      rateLimited: scanRateLimited,
      requestsUsed: scanExhaustive ? 14 : 5,
    );
  }

  @override
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) async {
    if (!supportsFolders) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持收藏复查。',
        platformId: id,
      );
    }
    // 真实语义：只回答"这些目标夹里，服务端现在确实包含该视频的有哪些"。
    // 它读的是 [serverFoldersOfVideo]（写操作会改它），
    // 因此 `applyWrites: false` 时它必然返回空 ——
    // 这正是"接口返回 code=0 但服务端没变"的假成功场景。
    return folderIds
        .where(serverFoldersOfVideo.contains)
        .toList(growable: false);
  }

  @override
  bool get supportsCoinBalance => coinBalanceSupported;

  @override
  Future<int?> fetchCoinBalance({required PlatformSession session}) async {
    fetchCoinBalanceCalls++;
    if (!coinBalanceSupported) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台不下发硬币余额。',
        platformId: id,
      );
    }
    return _coinBalance;
  }

  @override
  bool get supportsWatchLater => watchLaterSupported;

  @override
  Future<bool> fetchWatchLater({
    required String platformVideoId,
    required PlatformSession session,
  }) async {
    fetchWatchLaterCalls++;
    if (!watchLaterSupported) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '测试替身不支持稍后再看。',
        platformId: id,
      );
    }
    return watchLaterOnServer;
  }

  @override
  Future<InteractionResult> setWatchLater({
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) async {
    setWatchLaterCalls++;
    lastWatchLaterAdd = add;
    if (applyWrites) watchLaterOnServer = add;
    return InteractionResult(
      accepted: setFavoriteAccepted,
      message: setFavoriteMessage,
    );
  }

  @override
  bool get supportsFollowAuthor => followSupported;

  @override
  Future<InteractionResult> setFollowAuthor({
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) async {
    setFollowCalls++;
    lastFollowMid = targetMid;
    lastFollowTarget = follow;
    if (applyWrites) following = follow;
    return const InteractionResult(accepted: true);
  }

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
        userMessage: '测试替身不浏览收藏夹内容。',
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
        userMessage: '测试替身不浏览稍后再看列表。',
        platformId: id,
      );

  // ── 直播：本替身一律不支持（同样因为 implements 不继承默认实现）
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

/// 返回一个已拉到服务端状态的控制器（走真实 init 路径：读会话 → refreshState）。
Future<InteractionController> boot(
  FolderCapableAdapter adapter, {
  bool login = true,
  UnifiedVideo? video,
  CredentialVault? vault,
}) async {
  final v = vault ?? vaultWithSession(login: login);
  final controller = InteractionController(
    video: video ?? makeVideo(),
    service: buildService(adapter),
    vault: v,
  );
  await controller.init();
  return controller;
}

/// 让 acquire() 里那次未 await 的 init() 落地。
///
/// 登记表为了不阻塞首帧故意不 await 初始化；测试若不 settle 就 release，
/// 会让 notifyListeners 打在已 dispose 的控制器上（ChangeNotifier 断言）。
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

// ── B站真实接口形态（照抄实测响应，离线喂给适配器）───────────

/// 只覆盖 GET：`fetchInteractionState` 走的是 `_http.get(...).jsonObject(...)`。
class _StubHttp extends FusionHttpClient {
  _StubHttp(this.responses) : super(logger: FusionLogger(enabled: false));

  /// URL 关键片段 → 响应体。
  final Map<String, Map<String, Object?>> responses;

  final List<String> requestedUrls = [];

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
    bool keepRawBytes = false,
  }) async {
    requestedUrls.add(url);
    final body = responses.entries
        .firstWhere(
          (e) => url.contains(e.key),
          orElse: () => const MapEntry('', <String, Object?>{}),
        )
        .value;
    return HttpResult(
      statusCode: 200,
      body: jsonEncode(body),
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 0,
    );
  }
}

/// `archive/relation` 实测形态之一：**布尔**（本地账号 2 个视频 × 5 次调用）。
Map<String, Object?> _relationBoolForm({
  bool favorite = true,
  bool like = false,
  bool attention = false,
  int coin = 0,
}) =>
    {
      'code': 0,
      'message': 'OK',
      'data': {
        'type': 1,
        'aid': 114256632618805,
        'unfollow': false,
        'attention': attention,
        'favorite': favorite,
        'season_fav': false,
        'like': like,
        'subtitle': {'allow_show': false, 'list': <Object?>[]},
        'dislike': false,
        'meta_follow': false,
        'coin': coin,
      },
    };

/// `archive/relation` 实测形态之二：**like 是数字计数器**
/// （未赞时等于总赞数、已赞时收敛为 1；`attention` 也是 0/1）。
Map<String, Object?> _relationNumericForm({
  Object? like = 1,
  Object? attention = 0,
  Object? coin = 0,
  Object? dislike = 18335,
  Object? favorite = false,
}) =>
    {
      'code': 0,
      'message': 'OK',
      'data': {
        'attention': attention,
        'like': like,
        'dislike': dislike,
        'coin': coin,
        if (favorite != null) 'favorite': favorite,
      },
    };

BilibiliAdapter _bilibili(Map<String, Map<String, Object?>> responses) =>
    BilibiliAdapter(
      http: _StubHttp(responses),
      logger: FusionLogger(enabled: false),
    );

const String _relationKey = '/x/web-interface/archive/relation';

Future<InteractionState> _parse(Map<String, Object?> relation) => _bilibili({
      _relationKey: relation,
    }).fetchInteractionState(
      bvid,
      session: makeSession(platformId: 'bilibili'),
    );

void main() {
  group('A. 收藏状态以服务端为唯一真相', () {
    // 根因回归。`_relationLikeFlag` / `_relationLikeCount` / `_toBool` 是
    // BilibiliAdapter 的私有静态方法，无法直接单测；这里是**经由公开入口
    // fetchInteractionState** 的等价覆盖：两种形态都要解析得动，且都不许
    // 被外层 catch 吞成 unknown（吞掉就是"收藏成功但按钮永不高亮"）。
    //
    // 覆盖限制（如实交代）：判别实验（`fav_state` 与归属无关、ps 上限 20、
    // 第 6 个请求 412）需要真实登录态与网络，不在离线单测里，
    // 见 `test/interaction_live_test.dart` 与适配器 dartdoc。
    test('like 是布尔还是数字计数器都必须解析出真实状态，且不被吞成 unknown',
        () async {
      final boolForm = await _parse(_relationBoolForm(favorite: true));

      expect(
        boolForm.known,
        isTrue,
        reason: '布尔形态是本地实测的主要形态：这里一崩就退回 unknown，'
            '收藏按钮永远不高亮（本次故障的表现）',
      );
      expect(boolForm.favorited, isTrue);
      // 未赞：like:false 是布尔，与该视频总赞数（实测 2,957,453）无关
      expect(boolForm.liked, isFalse);
      expect(
        boolForm.likeCount,
        isNull,
        reason: 'relation 不返计数；填了会顶掉 UI 的 stats.likeCount 回退',
      );
      expect(boolForm.following, isFalse);
      expect(boolForm.coined, 0);
      expect(
        boolForm.favoritedFolderIds,
        isEmpty,
        reason: '归属要靠逐夹扫描，状态查询里硬塞会让每次开详情页都烧掉限流额度',
      );

      // 数字形态 · 已赞：该位收敛为 1，不能当"1 人点赞"显示
      final numericLiked = await _parse(_relationNumericForm(like: 1));
      expect(numericLiked.known, isTrue);
      expect(numericLiked.liked, isTrue);
      expect(
        numericLiked.likeCount,
        isNull,
        reason: '已赞时的 1 是标志位而不是总数，当成总数就显示"1 人点赞"',
      );

      // 数字形态 · 未赞：该位等于总赞数（样本 18335），此时才有计数
      final numericUnliked = await _parse(_relationNumericForm(like: 18335));
      expect(numericUnliked.known, isTrue);
      expect(numericUnliked.liked, isFalse, reason: '18335 是总数，不代表已赞');
      expect(numericUnliked.likeCount, 18335);

      // 0/1 数字形态的 attention 与 coin（bool 用 _toBool、次数用 _toInt）
      final numericFlags = await _parse(_relationNumericForm(
        like: 0,
        attention: 1,
        coin: 2,
        favorite: true,
      ));
      expect(numericFlags.known, isTrue);
      expect(numericFlags.following, isTrue);
      expect(numericFlags.coined, 2);
      expect(numericFlags.favorited, isTrue);

      // 状态层的等价契约：塌缩到同一个布尔语义，不给"把 bool 当 num"留位置
      const collapsed = InteractionState(known: true, liked: true, coined: 2);
      expect(collapsed.liked, isTrue);
      expect(collapsed.coined, 2);
      expect(InteractionState.unknown.known, isFalse);
      expect(
        InteractionState.unknown.favorited,
        isFalse,
        reason: 'unknown 的 false 只表示"不知道"，调用方不得当"未收藏"渲染',
      );
    });

    test('未登录：状态是 unknown，点收藏不发写请求，只提示登录且不高亮',
        () async {
      final adapter = FolderCapableAdapter();
      final controller = await boot(adapter, login: false);

      expect(
        controller.state.known,
        isFalse,
        reason: '未登录伪造"未收藏"会让用户以为自己的收藏被重置了',
      );
      expect(controller.isLoggedIn, isFalse);

      await controller.toggleFavorite();

      expect(
        adapter.setFavoriteCalls,
        0,
        reason: '未登录的写操作必须在前置检查处拦下，不能打到平台',
      );
      expect(controller.lastMessage, isNotNull);
      expect(controller.lastMessage, contains('登录'));
      expect(
        controller.state.favorited,
        isFalse,
        reason: '提示语不等于状态：按钮不得因为"点过了"就高亮',
      );
      expect(controller.favoritedFolderIds, isEmpty);
      expect(adapter.fetchFoldersCalls, 0, reason: '没有会话就不该去拉收藏夹');
    });

    test('写入成功 + 复查确认 → 返回 true，favorited 为真且归属含目标夹',
        () async {
      final adapter = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final controller = await boot(adapter);
      await controller.loadFavoriteFolders();
      expect(controller.favoritedFolderIds, {folderA});

      final ok = await controller.applyFavoriteFolders({folderA, folderB});

      expect(ok, isTrue, reason: '服务端归属确实达到期望集合，必须报成功');
      expect(controller.state.favorited, isTrue);
      expect(controller.favoritedFolderIds, {folderA, folderB});
      expect(adapter.lastFolderIds, [folderB]);
      expect(controller.lastMessage, contains('已收藏到'));
      expect(
        controller.lastMessage,
        contains('gay'),
        reason: '提示要说到具体夹名，"已收藏"三个字不足以让用户相信写对了',
      );
    });

    // 核心：B站 deal 对不存在的夹返回 code=0（实测 2026-10-19），
    // accepted 只代表"平台接受了请求"，不代表归属真的变了。
    test('平台回 code=0 但复查显示视频不在任何夹里 → 判为未生效', () async {
      final adapter = FolderCapableAdapter(applyWrites: false); // 假成功
      final controller = await boot(adapter);
      expect(controller.state.favorited, isFalse);

      final ok = await controller.applyFavoriteFolders({folderB});

      expect(
        ok,
        isFalse,
        reason: '只看 code 就产生"提示已收藏但按钮不高亮"的假成功，'
            '这正是本次修复要根治的东西',
      );
      expect(adapter.setFavoriteCalls, 1, reason: '确实发过写请求，不是没调');
      expect(controller.state.favorited, isFalse, reason: '不得因 accepted 就点亮');
      expect(controller.favoritedFolderIds, isEmpty);
      expect(
        controller.lastMessage,
        matches(RegExp('未(生效|确认)')),
        reason: '必须如实说明没生效，沉默或报成功都是骗人',
      );
      expect(controller.favoritePending, isFalse);
    });

    test('写请求抛网络异常 → 返回 false，状态保持写入前的服务端值', () async {
      final adapter = FolderCapableAdapter(
        serverFoldersOfVideo: {folderA},
        setFavoriteError: FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '网络连接失败，请检查网络连接后重试。',
        ),
      );
      final controller = await boot(adapter);
      await controller.loadFavoriteFolders();
      expect(controller.state.favorited, isTrue);
      expect(controller.favoritedFolderIds, {folderA});

      final ok = await controller.applyFavoriteFolders({folderA, folderB});

      expect(ok, isFalse);
      expect(
        controller.state.favorited,
        isTrue,
        reason: '写失败不能把已有的服务端收藏关系翻转成未收藏',
      );
      expect(
        controller.favoritedFolderIds,
        {folderA},
        reason: '"半途成功"最坏：既没写进去又显示写进去了',
      );
      expect(controller.lastMessage, contains('网络'));
      expect(controller.isLoggedIn, isTrue, reason: '网络错误不该清掉登录态');
      expect(controller.favoritePending, isFalse, reason: 'pending 必须在 finally 摘掉');
    });

    test('按服务端归属算增量：该加的加、该删的删、换夹一次写完', () async {
      // 情形 1：服务端 {A}，用户选 {A,B} → 只 add B，del 为空
      final addOnly = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final addController = await boot(addOnly);
      await addController.loadFavoriteFolders();
      expect(
        await addController.applyFavoriteFolders({folderA, folderB}),
        isTrue,
      );
      expect(addOnly.lastFolderIds, [folderB]);
      expect(
        addOnly.lastRemoveFolderIds,
        isNull,
        reason: '把仍在集合里的 A 也提交成 del，就是误删用户原有收藏',
      );

      // 情形 2：用户选 {} → del 为全部原归属（等价取消收藏）
      final removeAll = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final removeController = await boot(removeAll);
      await removeController.loadFavoriteFolders();
      expect(await removeController.applyFavoriteFolders(const {}), isTrue);
      expect(removeAll.lastRemoveFolderIds, [folderA]);
      expect(
        removeAll.lastFolderIds,
        isNull,
        reason: '没有要加的夹时必须传 null，而不是空列表',
      );
      expect(removeAll.serverFoldersOfVideo, isEmpty);
      expect(removeController.state.favorited, isFalse);
      expect(removeController.lastMessage, '已取消收藏');

      // 情形 3：用户选 {B} → 同一次调用里 add B + del A
      final swap = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final swapController = await boot(swap);
      await swapController.loadFavoriteFolders();
      expect(await swapController.applyFavoriteFolders({folderB}), isTrue);
      expect(swap.lastFolderIds, [folderB]);
      expect(
        swap.lastRemoveFolderIds,
        [folderA],
        reason: '一次 deal 同时带 add/del；换夹不该变成"先清空再添加"两次写',
      );
      expect(swap.serverFoldersOfVideo, {folderB});
      expect(swap.setFavoriteCalls, 1);
      expect(swapController.favoritedFolderIds, {folderB});
    });

    test('集合与服务端一致时不重复发写请求，仍返回 true 并校准 UI', () async {
      final adapter = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final controller = await boot(adapter);
      await controller.loadFavoriteFolders();

      final ok = await controller.applyFavoriteFolders({folderA});

      expect(
        ok,
        isTrue,
        reason: '"没变化"不是失败：返回 false 会让面板停在错误态不关',
      );
      expect(
        adapter.setFavoriteCalls,
        0,
        reason: '重复提交同一集合是纯粹的多余请求，还白耗全账号的限流额度',
      );
      expect(controller.state.favorited, isTrue);
      expect(controller.favoritedFolderIds, {folderA});
      expect(controller.favoritePending, isFalse);
    });

    test('登录态失效（-101）：清会话回到 unknown，不当成"未收藏"', () async {
      final adapter = _bilibili({
        _relationKey: {'code': -101, 'message': '账户未登录', 'data': null},
      });
      final vault = vaultWithSession(platformId: 'bilibili');
      final controller = InteractionController(
        video: makeVideo(platformId: 'bilibili', platformVideoId: bvid),
        service: VideoService(
          registry: PlatformRegistry(adapters: [adapter]),
          store: VideoStore(storage: MemoryStore()),
          cache: VideoCache(),
        ),
        vault: vault,
      );
      await controller.init();

      expect(
        controller.isLoggedIn,
        isFalse,
        reason: '会话已失效还留着，UI 会一直显示"登录后可操作"却点什么都失败',
      );
      expect(controller.state.known, isFalse);
      expect(controller.state.favorited, isFalse);
      expect(controller.lastMessage, isNotNull);
      expect(controller.lastMessage, contains('重新登录'));
    });
  });

  group('B. 部分扫描的诚实性（限流场景）', () {
    // 实测：B站连发第 6 个请求起返回 HTTP 412 / triggered captcha
    // （业务码 -70103112），而 6 夹账号全量核对要 14 个请求。
    // 所以"没核对到的夹"是**不知道**，渲染成未勾选就是假的否定。
    test('扫描被限流中断：未核对的夹不得当成"未收藏"，高亮也不得被清', () async {
      final adapter = FolderCapableAdapter(
        serverFoldersOfVideo: {folderA},
        favorited: true,
        scanExhaustive: false,
        scanRateLimited: true,
      );
      final controller = await boot(adapter);
      await controller.loadFavoriteFolders();

      expect(
        controller.favoriteFoldersResolved,
        isFalse,
        reason: '没核对完就不算解析完成：拿着残缺归属算 add/del 会漏删或重复添加',
      );
      expect(controller.favoriteFoldersRateLimited, isTrue);
      expect(controller.folderChecked(folderA), isTrue);
      expect(
        controller.folderChecked(folderB),
        isFalse,
        reason: 'B 既没命中也没核对完 = 状态未知，UI 靠它打「未核对」而不是未勾选',
      );
      expect(controller.folderChecked(folderC), isFalse);
      expect(
        controller.state.favorited,
        isTrue,
        reason: 'partial scan 时绝不能把 favorited 清掉：那会让高亮凭空消失',
      );
      expect(controller.favoritedFolderIds, {folderA});
      expect(controller.supportsFolderOwnershipScan, isTrue);
      expect(controller.supportsFavoriteFolders, isTrue);
    });

    test('服务端说未收藏时不触发归属扫描（省掉一整轮翻页请求）', () async {
      final adapter = FolderCapableAdapter();
      final controller = await boot(adapter);

      await controller.loadFavoriteFolders();

      expect(adapter.fetchFoldersCalls, 1);
      expect(
        adapter.scanCalls,
        0,
        reason: '没收藏还逐夹翻 resource/list 是纯浪费，而限流额度是全账号共享的',
      );
      expect(controller.favoriteFoldersResolved, isTrue);
      expect(controller.favoritedFolderIds, isEmpty);
      expect(controller.state.favorited, isFalse);
    });

    test('归属已解析后重复打开面板不重复扫描，forceScan 才会重扫', () async {
      final adapter = FolderCapableAdapter(
        serverFoldersOfVideo: {folderA},
        favorited: true,
      );
      final controller = await boot(adapter);

      await controller.loadFavoriteFolders();
      final first = adapter.scanCalls;
      expect(first, greaterThan(0));

      await controller.loadFavoriteFolders();
      expect(
        adapter.scanCalls,
        first,
        reason: '每次开面板都全量重扫必然被 412 打死，用户看到"转圈后失败"',
      );

      await controller.loadFavoriteFolders(forceScan: true);
      expect(
        adapter.scanCalls,
        greaterThan(first),
        reason: '写操作之后必须强制重扫，否则复查不到服务端的变化',
      );
    });
  });

  group('C. 跨页共享与竞态', () {
    test('同一视频 acquire 两次拿到同一个实例，release 两次后才销毁', () async {
      final adapter = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final registry = InteractionRegistry(
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      final video = makeVideo();

      final feed = registry.acquire(video);
      final detail = registry.acquire(video);
      await feed.init();
      await settle();

      expect(
        identical(feed, detail),
        isTrue,
        reason: '两个入口各建一份就是"推荐页已收藏、详情页未收藏"的根因',
      );
      expect(registry.activeCount, 1);
      expect(registry.peek(video.id), same(feed));

      registry.release(video.id);
      expect(
        registry.peek(video.id),
        isNotNull,
        reason: '还有一个持有者时释放一页不得销毁共享会话（用了就崩）',
      );
      expect(registry.activeCount, 1);

      registry.release(video.id);
      expect(registry.peek(video.id), isNull);
      expect(registry.activeCount, 0);
    });

    test('释放某页只销毁那个视频，别的视频的会话继续共享', () async {
      final adapter = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final registry = InteractionRegistry(
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      final videoA = makeVideo(platformVideoId: 'a');
      final videoB = makeVideo(platformVideoId: 'b');

      final a1 = registry.acquire(videoA);
      final a2 = registry.acquire(videoA);
      final b = registry.acquire(videoB);
      await a1.init();
      await b.init();
      await settle();

      registry.release(videoB.id);
      expect(registry.peek(videoB.id), isNull);
      expect(
        registry.peek(videoA.id),
        isNotNull,
        reason: '销毁必须只针对引用归零的那个视频',
      );
      expect(identical(registry.peek(videoA.id), a1), isTrue);
      expect(identical(a1, a2), isTrue);

      registry.release(videoA.id);
      expect(registry.peek(videoA.id), isNotNull, reason: 'A 还有第二个持有者');
      registry.release(videoA.id);
      expect(registry.peek(videoA.id), isNull);
      expect(registry.activeCount, 0);
    });

    test('慢的旧响应不得覆盖新拉到的状态（_stateSeq 竞态防护）', () async {
      final adapter = FolderCapableAdapter();
      final controller = await boot(adapter);
      expect(adapter.fetchStateCalls, 1);

      // 第 1 次：30ms 后返回"未收藏"的旧值；第 2 次：立刻返回"已收藏"的新值。
      adapter.queueStates(
        [
          const InteractionState(known: true, favorited: false, liked: false),
          const InteractionState(
            known: true,
            favorited: true,
            liked: true,
            favoritedFolderIds: [folderB],
          ),
        ],
        delaysMs: [30, 0],
      );

      final stale = controller.refreshState(); // seq=1，慢
      final fresh = controller.refreshState(); // seq=2，快
      await fresh;
      expect(controller.state.favorited, isTrue);

      await stale; // 旧响应晚到，必须被丢弃
      expect(
        controller.state.favorited,
        isTrue,
        reason: '写后复查与初始拉取并发时，晚到的旧响应会把新状态盖回未收藏，'
            '表现为"收藏成功了但按钮又变回未收藏"',
      );
      expect(controller.state.liked, isTrue);
      expect(controller.favoritedFolderIds, {folderB});
      expect(adapter.fetchStateCalls, 3);
    });

    test('导入 Cookie 后 recalibrateAll 让已打开的页面立刻变已知', () async {
      final vault = vaultWithSession(login: false);
      final adapter = FolderCapableAdapter(serverFoldersOfVideo: {folderA});
      final registry = InteractionRegistry(
        service: buildService(adapter),
        vault: vault,
      );

      final controller = registry.acquire(makeVideo());
      await controller.init();
      await settle();
      expect(controller.isLoggedIn, isFalse);
      expect(controller.state.known, isFalse);

      // 模拟设置页导入 Cookie 成功
      await vault.save(makeSession());
      await registry.recalibrateAll();

      expect(controller.isLoggedIn, isTrue);
      expect(
        controller.state.known,
        isTrue,
        reason: '不重算的话推荐流要切走再切回才显示登录态，用户以为导入没生效',
      );
      expect(controller.state.favorited, isTrue);
      expect(controller.favoritedFolderIds, {folderA});

      registry.release(controller.video.id);
      expect(registry.activeCount, 0);
    });

    test('pending 期间连点收藏只发一次写请求', () async {
      final adapter = FolderCapableAdapter(
        serverFoldersOfVideo: {folderA},
        favorited: true,
      );
      final controller = await boot(adapter);
      await controller.loadFavoriteFolders();
      expect(controller.state.favorited, isTrue);

      // 不 await：模拟用户连续快速点两次
      final first = controller.toggleFavorite();
      final second = controller.toggleFavorite();
      await Future.wait([first, second]);

      expect(
        adapter.setFavoriteCalls,
        1,
        reason: '重复写会出现"加了又删"的抖动，还白耗限流额度',
      );
      expect(controller.favoritePending, isFalse);
      expect(
        controller.state.favorited,
        isFalse,
        reason: '第二次点击在 pending 处被拦下：只发生了"取消收藏"这一条真实意图',
      );
    });
  });

  group('D. 投币余额前置与稍后再看/关注', () {
    test('余额 0 / 已投满 2 枚 / 未登录，投币前置检查都要拦下并给出原因',
        () async {
      final broke = FolderCapableAdapter(coinBalance: 0);
      final brokeController = await boot(broke);
      expect(
        await brokeController.loadCoinBalance(),
        0,
        reason: '实测该账号余额就是 0：不做前置检查，点"投 1 枚"只会收到平台失败码',
      );
      final brokeAvail = brokeController.coinAvailability();
      expect(brokeAvail.allowed, isFalse);
      expect(brokeAvail.reason, contains('余额'));
      expect(brokeController.coinBalance, 0);

      final maxed = FolderCapableAdapter(coined: 2, coinBalance: 7);
      final maxedController = await boot(maxed);
      final maxedAvail = maxedController.coinAvailability();
      expect(maxedAvail.allowed, isFalse, reason: '每视频上限 2 枚');
      expect(maxedController.state.coined, 2,
          reason: 'coined 是"本视频已投几枚"（0–2），不是平台总投币数');
      expect(maxedAvail.reason, isNotEmpty);

      final anonymous = FolderCapableAdapter(coinBalance: 7);
      final anonController = await boot(anonymous, login: false);
      final anonAvail = anonController.coinAvailability();
      expect(anonAvail.allowed, isFalse);
      expect(anonAvail.reason, contains('登录'));
    });

    test('平台不下发余额时 loadCoinBalance 返回 null，不把异常抛给调用方',
        () async {
      final adapter = FolderCapableAdapter(coinBalanceSupported: false);
      final controller = await boot(adapter);

      expect(
        await controller.loadCoinBalance(),
        isNull,
        reason: 'null=不知道，0=确实没币；混在一起会把"未知"说成"没钱"',
      );
      expect(controller.coinBalance, isNull);
      expect(adapter.fetchCoinBalanceCalls, 0, reason: '能力开关关着就不该发请求');
      expect(
        controller.coinAvailability().allowed,
        isTrue,
        reason: '余额未知但已投未满，不该被误判成不可投而禁用按钮',
      );
    });

    test('稍后再看：不支持时只说明不改状态；支持时以复查结果为准', () async {
      final unsupported = FolderCapableAdapter(watchLaterSupported: false);
      final offController = await boot(unsupported);
      await offController.toggleWatchLater();

      expect(
        unsupported.setWatchLaterCalls,
        0,
        reason: '能力不存在就不该发写请求，UI 也不该渲染这个按钮',
      );
      expect(offController.lastMessage, contains('不支持'));
      expect(offController.state.watchLater, isFalse);

      final supported = FolderCapableAdapter();
      final controller = await boot(supported);
      expect(controller.state.watchLater, isFalse);

      await controller.toggleWatchLater();

      expect(supported.setWatchLaterCalls, 1);
      expect(supported.lastWatchLaterAdd, isTrue);
      expect(
        supported.fetchWatchLaterCalls,
        1,
        reason: '写后必须复查服务端，只看 accepted 就是又一次假成功',
      );
      expect(controller.state.watchLater, isTrue);
      expect(controller.watchLaterPending, isFalse);
    });

    test('关注：UP 主 ID 缺失时不发请求；成功后状态跟随服务端复查值', () async {
      final noAuthor = FolderCapableAdapter();
      final blindController = await boot(
        noAuthor,
        video: makeVideo(authorId: null),
      );
      await blindController.toggleFollowAuthor();

      expect(
        noAuthor.setFollowCalls,
        0,
        reason: '拿不到 mid 就发请求，等于盲打平台接口并甩给用户一条莫名错误',
      );
      expect(blindController.lastMessage, isNotNull);
      expect(blindController.canFollowAuthor, isFalse);

      final adapter = FolderCapableAdapter();
      final controller = await boot(adapter);
      expect(controller.authorId, '9871');
      expect(controller.canFollowAuthor, isTrue);

      await controller.toggleFollowAuthor();
      expect(adapter.setFollowCalls, 1);
      expect(adapter.lastFollowMid, '9871');
      expect(adapter.lastFollowTarget, isTrue);
      expect(
        controller.state.following,
        isTrue,
        reason: 'following 来自 archive/relation 的 attention，写后要重新拉',
      );

      await controller.toggleFollowAuthor();
      expect(adapter.setFollowCalls, 2);
      expect(adapter.lastFollowTarget, isFalse);
      expect(controller.state.following, isFalse);
      expect(controller.followPending, isFalse);
    });
  });
}