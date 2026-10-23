/// 视频服务：链接接入、元数据获取、列表聚合、播放解析的统一编排层。
///
/// 职责边界：
///  - 这是 UI 唯一需要依赖的业务入口。
///  - UI 层不得直接调用任何平台接口，也不得做平台判断。
///  - 单个平台的失败不得阻塞其它平台的可用内容。
library;

import '../adapters/douyin/web_signer.dart';
import '../adapters/platform_adapter.dart';
import '../adapters/platform_registry.dart';
import '../adapters/bilibili/im_upload_client.dart';
import '../core/cache.dart';
import '../core/credential_vault.dart';
import '../core/errors.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../core/playback_policy.dart';
import '../core/bilibili_translation_provider.dart';
import '../core/douyin_translation_provider.dart';
import '../core/translation_service.dart';
import '../models/feed.dart';
import '../models/translation.dart';
import '../models/im.dart';
import '../models/interaction.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'video_store.dart';

/// 推荐流拉取结果。
///
/// **失败与"没有内容"必须可区分**：失败时 [error] 非 null，
/// 且 [items] 为空。UI 据此分别展示错误态与空态。
class FeedFetchResult {
  const FeedFetchResult({
    required this.sourceId,
    this.page,
    this.error,
  });

  final String sourceId;
  final FeedPage? page;
  final FusionException? error;

  bool get ok => error == null;

  List<UnifiedVideo> get items => page?.items ?? const [];

  bool get hasMore => page?.hasMore ?? false;

  int get nextOffset => page?.nextOffset ?? 0;
}

/// 某平台支持的互动能力集合。UI 据此决定显示哪些按钮，
/// 不支持的按钮不渲染（而不是渲染后点了报错）。
class InteractionCapabilities {
  const InteractionCapabilities({
    required this.comments,
    required this.like,
    required this.coin,
    required this.favorite,
    this.favoriteFolders = false,
    this.coinBalance = false,
    this.watchLater = false,
    this.follow = false,
    this.savedContent = false,
    this.commentLike = false,
    this.commentReply = false,
    this.cloudHistory = false,
    this.commentReplies = false,
    this.cloudProgress = false,
  });

  final bool comments;
  final bool like;
  final bool coin;
  final bool favorite;

  /// 是否支持"选择收藏夹"（列出账号的收藏夹）。
  final bool favoriteFolders;

  /// 是否支持读取硬币余额。
  final bool coinBalance;

  /// 是否支持"稍后再看"。
  final bool watchLater;

  /// 是否支持关注 / 取关 UP 主。
  final bool follow;

  /// 是否支持浏览已保存内容（收藏夹内条目、稍后再看列表）。
  ///
  /// 与 [favoriteFolders] 分开：能列出夹 ≠ 能列出夹里的视频。
  /// UI 用这个决定"点开收藏夹看内容"是否可用，避免放死按钮。
  final bool savedContent;

  /// 是否支持给**评论**点赞（评论面板里的爱心按钮）。
  final bool commentLike;

  /// 是否支持发表评论 / 回复评论（评论面板底部的输入框）。
  final bool commentReply;

  /// 是否提供**云端**观看历史（「我的」页的入口）。
  final bool cloudHistory;

  /// 是否支持读取**楼中楼**（某条一级评论下的二级评论列表）。
  ///
  /// 与 [commentReply] 分开：能回复 ≠ 能列出回复。评论面板据此决定
  /// "展开 N 条回复"要不要出现。
  final bool commentReplies;

  /// 是否支持**云端播放进度上报**（跨设备续播）。
  ///
  /// 与 [cloudHistory] 也分开：能读历史 ≠ 能写进度。
  final bool cloudProgress;

  static const InteractionCapabilities none = InteractionCapabilities(
    comments: false,
    like: false,
    coin: false,
    favorite: false,
  );

  /// 任一能力可用。
  ///
  /// 语义保持与既有一致（`comments || like || coin || favorite`）：
  /// UI 早已按这个判断"要不要显示互动区"。新增的
  /// [favoriteFolders]/[coinBalance]/[watchLater]/[follow]/[savedContent]/
  /// [commentLike]/[commentReply]/[cloudHistory]
  /// **不计入**这里，否则一个只支持"稍后再看"的平台会被判成
  /// "有互动能力"，从而显示出点赞/收藏这类实际会失败的按钮。
  /// 评论点赞/回复依附于 [comments]（评论面板内），不单独点亮互动区。
  bool get hasAny => comments || like || coin || favorite;
}

/// 跨平台搜索结果。
///
/// 与 [FeedFetchResult] 相同的原则：**失败与"没有结果"必须可区分**。
/// 部分平台失败时 [items] 仍有内容，失败详情在 [failures] 中。
class SearchResult {  const SearchResult({
    required this.query,
    required this.items,
    required this.failures,
    this.error,
  });

  final String query;
  final List<UnifiedVideo> items;

  /// 平台 id → 该平台的失败原因。
  final Map<String, FusionException> failures;

  /// 全部平台失败时的统一错误；部分成功时为 null。
  final FusionException? error;

  bool get ok => error == null;

  bool get hasPartialFailure => failures.isNotEmpty && items.isNotEmpty;

  bool get isEmpty => items.isEmpty;
}

/// 链接接入结果。
class ResolveResult {
  const ResolveResult({
    this.video,
    this.error,
    this.match,
    this.fromCache = false,
  });

  final UnifiedVideo? video;
  final FusionException? error;
  final LinkMatch? match;
  final bool fromCache;

  /// 是否拿到了可用的视频实体。
  ///
  /// 注意：`refresh` 降级时会**保留旧实体并附带错误**，
  /// 此时 [ok] 为 true 但 [degraded] 也为 true。
  /// 需要判断"本次操作是否完全成功"时应使用 [succeeded]。
  bool get ok => video != null;

  /// 本次操作是否完全成功（无错误）。
  bool get succeeded => video != null && error == null;

  /// 是否处于降级状态：保留了旧元数据，但本次刷新失败。
  bool get degraded => video != null && error != null;
}

/// 视频服务。
class VideoService {
  VideoService({
    required PlatformRegistry registry,
    required VideoStore store,
    VideoCache? cache,
    FusionLogger? logger,
    PlaybackPolicy? policy,
    FusionHttpClient? http,
  })  : _registry = registry,
        _store = store,
        _cache = cache ?? VideoCache(),
        _logger = logger ?? appLogger,
        _httpClient = http ?? FusionHttpClient(logger: logger),
        _policy = policy ?? PlaybackPolicy(registry: registry, logger: logger);

  final PlatformRegistry _registry;
  final VideoStore _store;
  final VideoCache _cache;
  final FusionLogger _logger;

  /// 翻译等"服务级"能力复用的 HTTP 客户端。
  ///
  /// 未显式注入时自建一个（与适配器各自持有的实例等价，
  /// 只是少了连接复用）。显式注入可让翻译与适配器共享超时/重试配置。
  final FusionHttpClient _httpClient;

  final PlaybackPolicy _policy;

  VideoCache get cache => _cache;

  PlatformRegistry get registry => _registry;

  /// 已接入平台的来源描述（首页"来源区域"使用）。
  List<PlatformDescriptor> describePlatforms() => _registry.describeAll();

  // ── 互动能力编排 ────────────────────────────────────────────
  //
  // 统一入口：UI 只调这里，不直接接触适配器。
  // 所有方法把失败归一化为 FusionException 并抛出，
  // 由 UI 决定如何呈现（登录引导 / 重试 / 明确报错）。

  /// 该视频所属平台支持哪些互动能力。
  InteractionCapabilities capabilitiesFor(String platformId) {
    final adapter = _registry.byId(platformId);
    if (adapter == null) return InteractionCapabilities.none;
    return InteractionCapabilities(
      comments: adapter.supportsComments,
      like: adapter.supportsLike,
      coin: adapter.supportsCoin,
      favorite: adapter.supportsFavorite,
      favoriteFolders: adapter.supportsFavoriteFolders,
      coinBalance: adapter.supportsCoinBalance,
      watchLater: adapter.supportsWatchLater,
      follow: adapter.supportsFollowAuthor,
      savedContent: adapter.supportsSavedContent,
      commentLike: adapter.supportsCommentLike,
      commentReply: adapter.supportsCommentReply,
      cloudHistory: adapter.supportsCloudHistory,
      commentReplies: adapter.supportsCommentReplies,
      cloudProgress: adapter.supportsCloudProgress,
    );
  }

  /// 该平台是否支持"选择收藏夹"。
  ///
  /// UI 据此决定渲染收藏夹选择面板还是只给一个收藏按钮——
  /// 不支持时按钮点了必然失败，不该显示。
  bool supportsFavoriteFoldersFor(String platformId) {
    final adapter = _registry.byId(platformId);
    return adapter?.supportsFavoriteFolders ?? false;
  }

  /// 该平台是否支持浏览已保存内容（收藏夹条目 / 稍后再看列表）。
  bool supportsSavedContentFor(String platformId) {
    final adapter = _registry.byId(platformId);
    return adapter?.supportsSavedContent ?? false;
  }

  /// 该平台是否支持"逐夹归属扫描"（回答"这个视频在哪些夹里"）。
  ///
  /// 不支持时 UI 退化为"只知道收藏过，不知道在哪个夹"，
  /// 收藏夹选择面板应据此不显示勾选状态。
  bool supportsFolderOwnershipScanFor(String platformId) {
    final adapter = _registry.byId(platformId);
    return adapter?.supportsFolderOwnershipScan ?? false;
  }

  // ── 私信（IM）──────────────────────────────────────────────
  //
  // UI 只调这里，不直接碰适配器（与其它能力一致）。

  /// 该平台是否支持应用内私信。
  bool supportsImFor(String platformId) {
    final adapter = _registry.byId(platformId);
    return adapter?.supportsIm ?? false;
  }

  /// 支持私信的平台 id 列表（消息页据此决定显示哪些平台）。
  List<String> get imPlatformIds => _registry.adapters
      .where((a) => a.supportsIm)
      .map((a) => a.id)
      .toList(growable: false);

  /// 拉一页会话。
  Future<ImSessionPage> fetchImSessions(
    String platformId, {
    required PlatformSession session,
    int count = 20,
    int endTs = 0,
  }) =>
      _adapterFor(platformId).fetchImSessions(
        session: session,
        count: count,
        endTs: endTs,
      );

  /// 拉一页历史消息（服务端新→旧）。
  Future<ImMessagePage> fetchImMessages(
    String platformId, {
    required PlatformSession session,
    required int talkerId,
    int size = 20,
    int endSeqno = 0,
  }) =>
      _adapterFor(platformId).fetchImMessages(
        session: session,
        talkerId: talkerId,
        size: size,
        endSeqno: endSeqno,
      );

  /// 发送文本消息。
  Future<ImSendResult> sendImMessage(
    String platformId, {
    required PlatformSession session,
    required int talkerId,
    required String content,
  }) =>
      _adapterFor(platformId).sendImMessage(
        session: session,
        talkerId: talkerId,
        content: content,
      );

  /// 未读汇总。
  Future<ImUnread> fetchImUnread(
    String platformId, {
    required PlatformSession session,
  }) =>
      _adapterFor(platformId).fetchImUnread(session: session);

  /// 批量取用户信息（昵称/头像）。
  Future<Map<int, ImUserInfo>> fetchImUserInfos(
    String platformId, {
    required PlatformSession session,
    required List<int> uids,
  }) =>
      _adapterFor(platformId).fetchImUserInfos(session: session, uids: uids);

  /// 标记会话已读。
  Future<bool> markImSessionRead(
    String platformId, {
    required PlatformSession session,
    required int talkerId,
    required int ackSeqno,
  }) =>
      _adapterFor(platformId).markImSessionRead(
        session: session,
        talkerId: talkerId,
        ackSeqno: ackSeqno,
      );

  // ── 私信：媒体能力 ──────────────────────────────────────────

  /// 该平台是否支持在私信里发送图片。
  bool supportsImImageSendFor(String platformId) =>
      _registry.byId(platformId)?.supportsImImageSend ?? false;

  /// 该平台是否支持表情面板。
  bool supportsImEmoteFor(String platformId) =>
      _registry.byId(platformId)?.supportsImEmote ?? false;

  /// 该平台是否支持发送自定义表情。
  bool supportsImCustomEmojiSendFor(String platformId) =>
      _registry.byId(platformId)?.supportsImCustomEmojiSend ?? false;

  /// 上传一张图片，返回可用于构造消息的媒体信息。
  ///
  /// 失败归一化为 [FusionException]。
  Future<ImMedia> uploadImImage(
    String platformId, {
    required PlatformSession session,
    required List<int> bytes,
    required String filename,
  }) async {
    // 先在服务层做本地校验：UI 层不该知道"20MB 上限"这种平台知识，
    // 也不该 import 适配器实现文件。
    final validation = BilibiliImUploadClient.validateFile(
      filename,
      bytes.length,
    );
    if (!validation.ok) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: validation.reason!,
        technicalMessage: 'local upload validation failed for $filename',
        platformId: platformId,
        retryable: false,
      );
    }
    try {
      return await _adapterFor(platformId).uploadImImage(
        session: session,
        bytes: bytes,
        filename: filename,
      );
    } catch (e) {
      throw uploadErrorToFusion(e, platformId: platformId);
    }
  }

  /// 读取本地文件为字节（供 UI 层调用，集中处理 IO 错误）。
  ///
  /// 放在服务层而不是让 UI 直接 `File(...).readAsBytes()`：
  /// IO 失败要归一化成 [FusionException]，UI 只需按错误码分支。
  Future<List<int>> readLocalImage(String path) async {
    try {
      return await BilibiliImUploadClient.readFile(path);
    } catch (e) {
      throw uploadErrorToFusion(e);
    }
  }

  /// 发送图片消息。
  Future<ImSendResult> sendImImage(
    String platformId, {
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      _adapterFor(platformId).sendImImage(
        session: session,
        talkerId: talkerId,
        media: media,
      );

  /// 发送自定义表情消息。
  Future<ImSendResult> sendImCustomEmoji(
    String platformId, {
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      _adapterFor(platformId).sendImCustomEmoji(
        session: session,
        talkerId: talkerId,
        media: media,
      );

  /// 拉取表情面板。
  ///
  /// 失败不抛异常，返回 `loaded: false` 的面板。
  Future<ImEmotePanel> fetchImEmotePanel(
    String platformId, {
    required PlatformSession session,
  }) =>
      _adapterFor(platformId).fetchImEmotePanel(session: session);

  /// 扫描"该视频在哪些收藏夹里"。
  ///
  /// 归属判定的**唯一可靠途径**：B 站夹列表上的 `fav_state` 实测与
  /// "该视频是否在此夹"无关（它是收藏夹自身状态，对自建夹恒为 0），
  /// 所以这里必然是一次「夹数 × 翻页」的扫描。
  ///
  /// 代价真实存在（`ps` 上限 20、B 站第 6 个请求起 412、全量核对实测
  /// 需要 144 个请求），所以：
  ///  - [maxRequests] 是请求预算，超了就返回**部分结果**；
  ///  - 只在 `InteractionState.favorited == true` 时调用；
  ///  - 不要在轮询/滚动里调；
  ///  - **只用于面板首次打开的勾选回显**。
  ///
  /// # 写入后的复查不要用这个方法
  ///
  /// 复查"刚收藏的项进没进目标夹"请走 [verifyRecentFavorite]：
  /// 它只查目标夹的前 1~2 页（实测新项就在第 1 页），总共 2~3 个请求；
  /// 而本方法为了回答"还在别的哪些夹里"必然贵一个数量级，
  /// 放在每次写操作后面会把用户直接推进 412。
  ///
  /// 返回值是 [FolderOwnershipScan] 而不是夹 ID 列表：调用方必须能区分
  /// "确认不包含"与"没核对到"，否则会把用户已收藏的夹显示成未勾选。
  Future<FolderOwnershipScan> scanFoldersContainingVideo(
    String platformId, {
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 6,
  }) {
    return _adapterFor(platformId).scanFoldersContainingVideo(
      platformVideoId: platformVideoId,
      session: session,
      maxRequests: maxRequests,
    );
  }

  /// 该平台的收藏接口是否支持"带收藏夹"（选择面板 + 写后复查）。
  ///
  /// 复查（[verifyRecentFavorite]）与选择面板是**同一个能力**的两种用法，
  /// 所以这里复用 `supportsFavoriteFolders`，不另开一个 supports* 开关：
  /// 平台要么两个都给，要么一个都不给，不存在"能选夹但不能复查"。
  bool supportsFavoriteVerify(String platformId) =>
      supportsFavoriteFoldersFor(platformId);

  /// 复查"刚收藏/刚移出的项是否真的在目标夹里"（每夹 1~2 页，便宜）。
  ///
  /// [folderIds] 是**本次写入涉及的目标夹**：
  ///  - 加入方向：期望返回**包含**这些夹 → 差集就是没生效的；
  ///  - 移除方向：期望返回**空** → 非空就是没删掉的。
  ///
  /// 返回的是"已确认包含"的子集；**不在返回里不等于失败**
  /// （页序不稳定、平台缓存滞后都可能让刚写入的项暂时看不到），
  /// UI 应据此提示"未确认，请刷新"，而不是断言"收藏失败"。
  /// 详见 [PlatformAdapter.verifyRecentFavorite]。
  Future<List<int>> verifyRecentFavorite(
    String platformId, {
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) {
    return _adapterFor(platformId).verifyRecentFavorite(
      platformVideoId: platformVideoId,
      folderIds: folderIds,
      session: session,
      maxPages: maxPages,
    );
  }

  /// 取适配器，取不到就如实抛错（不返回空数据冒充"没有"）。
  PlatformAdapter _adapterFor(String platformId) {
    final adapter = _registry.byId(platformId);
    if (adapter == null) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台尚未接入。',
        technicalMessage: 'No adapter for $platformId',
        platformId: platformId,
      );
    }
    return adapter;
  }

  /// 拉取账号的收藏夹列表（id / 标题 / 条数 / 是否默认）。
  ///
  /// **不含**"某视频在哪些夹里"——平台没有这样的字段，
  /// 归属必须单独调 [scanFoldersContainingVideo]。
  Future<List<FavoriteFolder>> fetchFavoriteFolders(
    String platformId, {
    required PlatformSession session,
  }) {
    return _adapterFor(platformId).fetchFavoriteFolders(session: session);
  }

  /// 读取硬币余额。返回 null 表示平台没给这个字段（≠ 0 个币）。
  Future<int?> fetchCoinBalance(
    String platformId, {
    required PlatformSession session,
  }) {
    return _adapterFor(platformId).fetchCoinBalance(session: session);
  }

  /// 该视频是否已在"稍后再看"里。
  Future<bool> fetchWatchLater(
    String platformId, {
    required String platformVideoId,
    required PlatformSession session,
  }) {
    return _adapterFor(platformId).fetchWatchLater(
      platformVideoId: platformVideoId,
      session: session,
    );
  }

  /// 加入 / 移出"稍后再看"。
  Future<InteractionResult> setWatchLater(
    String platformId, {
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) {
    return _adapterFor(platformId).setWatchLater(
      platformVideoId: platformVideoId,
      add: add,
      session: session,
    );
  }

  /// 关注 / 取关 UP 主。
  Future<InteractionResult> setFollowAuthor(
    String platformId, {
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) {
    return _adapterFor(platformId).setFollowAuthor(
      targetMid: targetMid,
      follow: follow,
      session: session,
    );
  }

  /// 拉取某个收藏夹里的内容。
  Future<SavedVideoPage> fetchFavoriteFolderVideos(
    String platformId,
    int mediaId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) {
    return _adapterFor(platformId).fetchFavoriteFolderVideos(
      mediaId,
      session: session,
      page: page,
      pageSize: pageSize,
    );
  }

  /// 拉取"稍后再看"列表。
  Future<SavedVideoPage> fetchWatchLaterVideos(
    String platformId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) {
    return _adapterFor(platformId).fetchWatchLaterVideos(
      session: session,
      page: page,
      pageSize: pageSize,
    );
  }

  /// 拉取账号的**云端**观看历史（分页 / 游标）。
  ///
  /// 与本地 `VideoProgressStore` 无关：那个只记录本设备的播放位置。
  Future<SavedVideoPage> fetchHistoryVideos(
    String platformId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
    int cursor = 0,
  }) {
    return _adapterFor(platformId).fetchHistoryVideos(
      session: session,
      page: page,
      pageSize: pageSize,
      cursor: cursor,
    );
  }

  /// 某个平台是否提供云端观看历史。
  ///
  /// 用 `_registry.byId(...) ?? false` 而不是 `_adapterFor(...)`：
  /// 这是**能力查询**，UI（「我的」页）拿每个会话的平台 id 来问"要不要
  /// 渲染云端历史入口"。未接入/已移除的平台必须答"没有"，而不是抛异常——
  /// 一个残留会话就会让整个个人页崩掉。与 [supportsFavoriteFoldersFor]
  /// / [supportsSavedContentFor] 同一形态。
  bool platformSupportsCloudHistory(String platformId) {
    final adapter = _registry.byId(platformId);
    return adapter?.supportsCloudHistory ?? false;
  }

  /// 拉取评论列表。
  Future<CommentPage> fetchComments(
    UnifiedVideo video, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    final adapter = _registry.byId(video.platformId);
    if (adapter == null || !adapter.supportsComments) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持评论。',
        technicalMessage: 'No comment support for ${video.platformId}',
        platformId: video.platformId,
      );
    }
    final result = await adapter.fetchComments(
      video.platformVideoId,
      page: page,
      pageSize: pageSize,
      session: session,
    );
    // 翻译接口要的是数字 oid（B 站 aid），而链接里带的是字母 bvid。
    // 两者不能直接互转，需要一次 view 请求；适配器侧有缓存。
    await _rememberNumericVideoId(video);
    return result;
  }

  // ── 评论翻译 ────────────────────────────────────────────────
  //
  // 统一入口：UI 只调这里，不接触具体平台的翻译实现。
  //
  // 设计要点：
  //  1. **B 站有自己的官方翻译接口**，但只吃 `reply_id`，需要登录。
  //  2. **抖音没有可用翻译接口**（详见 APK-API-REPORT.md §八）。
  //  3. 抖音评论的翻译请求会走到 B 站提供方，但**必然失败**——
  //     因为没有 `reply_id`。这里如实返回失败原因，
  //     不用假译文冒充，也不假装"抖音支持翻译"。
  //
  // 换句话说：本服务现在提供的是「统一入口 + 诚实的边界」，
  // 而不是「两平台都能翻译」。后者需要抖音官方接口或第三方翻译服务，
  // 属于需求里说的"需要额外权限/费用"的范畴，已写进报告。

  /// 当前视频的数字 ID（B 站 aid，翻译接口入参）。
  ///
  /// 只在适配器声明支持 [NumericVideoIdCapable] 时解析；
  /// 解析失败保持原值，不覆盖成 null。
  int? _lastBilibiliAid;

  Future<void> _rememberNumericVideoId(UnifiedVideo video) async {
    // 声明成 Object? 而不是 PlatformAdapter?：
    // NumericVideoIdCapable 与 PlatformAdapter 无继承关系，
    // Dart 不会把前者提升到后者，声明成 Object? 才能提升。
    final Object? adapter = _registry.byId(video.platformId);
    if (adapter is! NumericVideoIdCapable) return;
    try {
      final id = await adapter.resolveNumericVideoId(video.platformVideoId);
      if (id != null && id > 0) _lastBilibiliAid = id;
    } catch (_) {
      // 解析失败不阻断评论加载
    }
  }

  /// B 站翻译提供方（延迟创建，复用同一个 HTTP 客户端）。
  BilibiliTranslationProvider? _biliTranslation;

  /// 抖音翻译提供方（延迟创建，复用调用方传入的 WebView 签名器）。
  DouyinTranslationProvider? _douyinTranslation;

  /// 统一的翻译服务。
  TranslationService? _translation;

  /// 取翻译服务（首次调用时创建）。
  ///
  /// [session] 用于注入登录态：B 站翻译接口需要 Cookie。
  TranslationService translationServiceFor({PlatformSession? session}) {
    final provider = _biliTranslation ??= BilibiliTranslationProvider(
      http: _httpClient,
      logger: _logger,
    );
    provider.cookieHeader = session?.cookieHeader;
    provider.currentAid = _lastBilibiliAid;

    return _translation ??= TranslationService(provider: provider);
  }

  /// 翻译一条评论。
  ///
  /// 返回的一定是 [TranslationResult]（失败也是结果，不抛异常），
  /// 因为评论面板里单条翻译失败不该中断整页。
  ///
  /// # 平台路由（2026-10-20 修正）
  ///
  /// 早期版本在这里硬编码 `platformId != 'bilibili'` 就返回失败，
  /// 理由是"抖音没有翻译接口"。**该结论已被推翻**——
  /// 抖音前端 bundle 里有 `/aweme/v1/web/comment/translate/` 与
  /// `/aweme/v1/web/text/translate/`。
  ///
  /// 现在按平台选 provider：
  ///  - `bilibili` → [BilibiliTranslationProvider]（rpid 驱动，需登录）
  ///  - `douyin`   → [DouyinTranslationProvider]（WebView 会话内签名）
  ///  - 其它       → 如实说明无可用翻译
  Future<TranslationResult> translateComment({
    required String platformId,
    required String commentId,
    required String text,
    PlatformSession? session,
    TranslationLanguage? language,
    DouyinWebSigner? douyinSigner,
  }) async {
    switch (platformId) {
      case 'bilibili':
        final service = translationServiceFor(session: session);
        return service.translateComment(
          commentId: commentId,
          text: text,
          language: language,
        );

      case 'douyin':
        // 抖音翻译依赖 WebView 会话（签名 + UIFID 在页面上下文里）。
        // 没有 signer 就如实说明，而不是发一个注定 blocked 的请求。
        if (douyinSigner == null) {
          return TranslationResult.failure(
            errorMessage: '抖音翻译需要页面会话，当前未就绪。',
            providerId: 'douyin',
            targetLanguage: language ?? TranslationLanguage.zhHans,
          );
        }
        final provider = _douyinTranslation ??=
            DouyinTranslationProvider(signer: douyinSigner, logger: _logger);
        return provider.translate(
          text: text,
          targetLanguage: language ?? TranslationLanguage.zhHans,
          commentId: commentId,
        );

      default:
        return TranslationResult.failure(
          errorMessage: '该平台没有可用的评论翻译接口。',
          providerId: 'none',
          targetLanguage: language ?? TranslationLanguage.zhHans,
        );
    }
  }


  /// 查询互动状态。
  Future<InteractionState> fetchInteractionState(
    UnifiedVideo video, {
    PlatformSession? session,
  }) async {
    final adapter = _registry.byId(video.platformId);
    if (adapter == null) return InteractionState.unknown;
    return adapter.fetchInteractionState(
      video.platformVideoId,
      session: session,
    );
  }

  /// 点赞 / 取消点赞。
  ///
  /// 未登录时抛 [FusionErrorCode.loginRequired]。
  Future<InteractionResult> setLike(
    UnifiedVideo video, {
    required bool like,
    PlatformSession? session,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '点赞');
    return adapter.setLike(
      video.platformVideoId,
      like: like,
      session: session!,
    );
  }

  /// 投币。
  Future<InteractionResult> setCoin(
    UnifiedVideo video, {
    required int count,
    PlatformSession? session,
    bool alsoLike = false,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '投币');
    return adapter.setCoin(
      video.platformVideoId,
      count: count,
      session: session!,
      alsoLike: alsoLike,
    );
  }

  /// 收藏 / 取消收藏。
  ///
  /// [folderIds] / [removeFolderIds] 直接透传给适配器；两者都不传时
  /// 按 [favorite] 走旧语义（true → 默认收藏夹，false → 从当前归属移出）。
  ///
  /// 返回值只表示"平台接受了请求"。B 站对不存在的收藏夹会回
  /// `code=0`，且 `data.success_num` 恒为 0（实测 2026-10-19），
  /// 都**不能**证明归属真的变了。因此**调用方要如实回显时
  /// 必须在写入后调一次** [scanFoldersContainingVideo] 复查；
  /// 这里不做复查，读写职责分开（复查开销由调用方按时机控制）。
  Future<InteractionResult> setFavorite(
    UnifiedVideo video, {
    required bool favorite,
    PlatformSession? session,
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '收藏');
    return adapter.setFavorite(
      video.platformVideoId,
      favorite: favorite,
      session: session!,
      folderIds: folderIds,
      removeFolderIds: removeFolderIds,
    );
  }

  /// 给**评论**点赞 / 取消点赞（不是给视频点赞）。
  ///
  /// 平台不支持（[PlatformAdapter.supportsCommentLike] = false）时
  /// 抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<InteractionResult> setCommentLike(
    UnifiedVideo video, {
    required String commentId,
    required bool like,
    PlatformSession? session,
    int? replyLevel,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '评论点赞');
    if (!adapter.supportsCommentLike) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持评论点赞。',
        technicalMessage: 'Adapter ${video.platformId} '
            'does not implement setCommentLike',
        platformId: video.platformId,
      );
    }
    return adapter.setCommentLike(
      video.platformVideoId,
      commentId: commentId,
      like: like,
      session: session!,
      replyLevel: replyLevel,
    );
  }

  /// 拉取某条一级评论下的**楼中楼**（二级评论）。
  ///
  /// 平台不支持读回复列表（[PlatformAdapter.supportsCommentReplies]=false）
  /// 时抛 `unsupportedPlatform`。多数平台楼中楼读取匿名可得，
  /// [session] 可空。
  Future<CommentPage> fetchCommentReplies(
    UnifiedVideo video, {
    required String parentCommentId,
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    final adapter = _registry.byId(video.platformId);
    if (adapter == null || !adapter.supportsCommentReplies) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持查看楼中楼回复。',
        technicalMessage:
            'No sub-reply support for ${video.platformId}',
        platformId: video.platformId,
      );
    }
    return adapter.fetchCommentReplies(
      video.platformVideoId,
      parentCommentId: parentCommentId,
      page: page,
      pageSize: pageSize,
      session: session,
    );
  }

  /// 该平台是否支持楼中楼读取（评论面板决定"展开 N 条回复"是否出现）。
  bool supportsCommentRepliesFor(String platformId) {
    final adapter = _registry.byId(platformId);
    return adapter?.supportsCommentReplies ?? false;
  }

  /// 上报**云端**播放进度（跨设备续播）。
  ///
  /// 参数直接收平台标识，不收整个 UnifiedVideo：播放进度每秒都在回调，
  /// 为它重建/传一个完整视频实体是没有必要的耦合。
  ///
  /// 这是旁路：调用方（播放进度落盘点）必须 catch 后降级——本地
  /// `VideoProgressStore` 才是权威，云端失败不能影响本机进度。
  /// 未登录抛 `loginRequired`；平台不支持抛 `unsupportedPlatform`。
  Future<void> reportPlaybackProgress(
    String platformId, {
    required String platformVideoId,
    required Duration position,
    required Duration duration,
    required PlatformSession session,
  }) async {
    final adapter = _registry.byId(platformId);
    if (adapter == null || !adapter.supportsCloudProgress) {
      // 不静默返回——那等于"假装上报过了"。调用方按异常降级即可。
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持云端播放进度。',
        technicalMessage: 'No cloud progress support for $platformId',
        platformId: platformId,
      );
    }
    await adapter.reportPlaybackProgress(
      platformVideoId: platformVideoId,
      position: position,
      duration: duration,
      session: session,
    );
  }

  /// 该平台是否支持云端播放进度上报。
  bool supportsCloudProgressFor(String platformId) {
    final adapter = _registry.byId(platformId);
    return adapter?.supportsCloudProgress ?? false;
  }

  /// 发表评论 / 回复评论。
  ///
  /// [replyToCommentId] 为 null 时发**顶层评论**，非 null 时回复到该评论。
  /// 返回新评论 ID（平台不回传时为 null）。
  Future<String?> replyComment(
    UnifiedVideo video, {
    required String message,
    PlatformSession? session,
    String? replyToCommentId,
    String? rootCommentId,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '评论');
    if (!adapter.supportsCommentReply) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持发表评论。',
        technicalMessage: 'Adapter ${video.platformId} '
            'does not implement replyComment',
        platformId: video.platformId,
      );
    }
    return adapter.replyComment(
      video.platformVideoId,
      message: message,
      session: session!,
      replyToCommentId: replyToCommentId,
      rootCommentId: rootCommentId,
    );
  }

  /// 互动写操作的统一前置校验：适配器存在 + 已登录。
  PlatformAdapter _requireInteractionAdapter(
    UnifiedVideo video,
    PlatformSession? session,
    String action,
  ) {
    final adapter = _registry.byId(video.platformId);
    if (adapter == null) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台尚未接入。',
        technicalMessage: 'No adapter for ${video.platformId}',
        platformId: video.platformId,
      );
    }
    if (session == null) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '请先登录 $action 所属的平台账号。',
        technicalMessage: 'No session for ${video.platformId} ($action)',
        platformId: video.platformId,
        retryable: false,
      );
    }
    return adapter;
  }

  /// 全部推荐流来源，按适配器注册顺序汇总。
  ///
  /// 这是唯一的"内容来源"清单入口。UI 层不得硬编码任何平台判断。
  List<FeedSource> describeFeedSources() {
    final out = <FeedSource>[];
    for (final adapter in _registry.adapters) {
      out.addAll(adapter.feedSources);
    }
    return out;
  }

  /// 拉取一页推荐流。
  ///
  /// 失败时返回带明确错误的 [FeedFetchResult]，不抛异常给 UI。
  /// **不把失败伪装成空列表**——两者在 UI 上是不同的状态。
  Future<FeedFetchResult> fetchFeed(
    String sourceId, {
    FeedRequest request = const FeedRequest(),
  }) async {
    PlatformAdapter? owner;
    for (final adapter in _registry.adapters) {
      if (adapter.feedSources.any((s) => s.id == sourceId)) {
        owner = adapter;
        break;
      }
    }

    if (owner == null) {
      return FeedFetchResult(
        sourceId: sourceId,
        error: FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage: '该内容来源不存在。',
          technicalMessage: 'No adapter declares feed sourceId=$sourceId',
        ),
      );
    }

    try {
      final page = await owner.fetchFeed(request, sourceId: sourceId);
      return FeedFetchResult(sourceId: sourceId, page: page);
    } on FusionException catch (e) {
      _logger.warn('feed fetch failed', {
        'source': sourceId,
        'platform': owner.id,
        'code': e.code.name,
      });
      return FeedFetchResult(sourceId: sourceId, error: e);
    } catch (e) {
      return FeedFetchResult(
        sourceId: sourceId,
        error: normalizeError(e, platformId: owner.id),
      );
    }
  }

  /// 链接接入：识别平台 → 提取 ID → 获取元数据 → 入库。
  ///
  /// 失败时返回带明确错误的 [ResolveResult]，不抛异常给 UI。
  Future<ResolveResult> resolveLink(String rawInput) async {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '请输入视频链接。',
          technicalMessage: 'Empty input',
        ),
      );
    }

    // 从分享文案中提取 URL（抖音/B站分享常带描述文字）
    final extracted = _extractUrl(input);
    final uri = Uri.tryParse(extracted);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '这不是一个有效的链接，请检查后重试。',
          technicalMessage: 'Unparsable URL: ${Redactor.safeUrl(extracted)}',
        ),
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '仅支持 http/https 链接。',
          technicalMessage: 'Unsupported scheme: ${uri.scheme}',
        ),
      );
    }

    // 唯一平台判定入口
    final adapter = _registry.match(uri);
    if (adapter == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage:
              '暂不支持该链接所属的平台。当前已接入：${_registry.adapters.map((a) => a.displayName).join('、')}。',
          technicalMessage: 'No adapter matched host=${uri.host}',
        ),
      );
    }

    LinkMatch? match;
    try {
      match = await adapter.extract(uri);
    } on FusionException catch (e) {
      return ResolveResult(error: e, match: null);
    } catch (e) {
      return ResolveResult(
        error: normalizeError(e, platformId: adapter.id),
      );
    }

    if (match == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.videoIdNotFound,
          userMessage: '无法从该链接中识别出视频 ID，请确认链接指向的是单个视频。',
          technicalMessage:
              'Adapter ${adapter.id} matched but returned no video id for ${Redactor.safeUrl(extracted)}',
          platformId: adapter.id,
        ),
      );
    }

    final videoId = makeVideoId(match.platformId, match.platformVideoId);

    // 同一视频重复导入：命中缓存直接返回
    final cached = _cache.metadata.peek(videoId);
    if (cached != null && !cached.stale) {
      final existing = _cache.markFromCache(cached.value);
      await _store.upsert(existing);
      return ResolveResult(video: existing, match: match, fromCache: true);
    }

    // 已在库中且未过期
    final stored = await _store.get(videoId);
    if (stored != null && _isFresh(stored)) {
      return ResolveResult(
        video: stored.copyWith(
          diagnostics: stored.diagnostics.copyWith(fromCache: true),
        ),
        match: match,
        fromCache: true,
      );
    }

    // 获取元数据
    try {
      final video = await _fetchAndBuild(adapter, match, extracted);
      await _store.upsert(video);
      return ResolveResult(video: video, match: match);
    } on FusionException catch (e) {
      _logger.warn('metadata fetch failed', {
        'platform': adapter.id,
        'videoId': match.platformVideoId,
        'code': e.code.name,
        'detail': e.technicalMessage,
      });
      return ResolveResult(error: e, match: match);
    } catch (e) {
      return ResolveResult(
        error: normalizeError(e, platformId: adapter.id),
        match: match,
      );
    }
  }

  /// 获取元数据并构造 [UnifiedVideo]。ID / 时间戳 / 诊断由核心层统一负责。
  Future<UnifiedVideo> _fetchAndBuild(
    PlatformAdapter adapter,
    LinkMatch match,
    String originalUrl,
  ) async {
    final startedAt = DateTime.now();
    final metadata = await adapter.fetchMetadata(match);
    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;

    final video = UnifiedVideo(
      id: makeVideoId(match.platformId, match.platformVideoId),
      platformId: match.platformId,
      platformVideoId: match.platformVideoId,
      originalUrl: originalUrl,
      canonicalUrl: match.canonicalUrl,
      title: metadata.title,
      description: metadata.description,
      author: metadata.author,
      coverUrl: metadata.coverUrl,
      durationSeconds: metadata.durationSeconds,
      aspectRatio: normalizeAspectRatio(metadata.width, metadata.height),
      width: metadata.width,
      height: metadata.height,
      publishedAt: metadata.publishedAt,
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: metadata.stats,
      availability: metadata.availability,
      playbackModes: _playbackModesFor(adapter),
      requiresAuth: metadata.requiresAuth,
      diagnostics: VideoDiagnostics(
        adapterId: adapter.id,
        upstreamEndpoint: metadata.upstreamEndpoint,
        fromCache: false,
        fetchDurationMs: durationMs,
        limitations: metadata.limitations,
        notes: [...match.notes, ...metadata.notes],
      ),
    );

    _cache.metadata.put(video.id, video);
    return video;
  }

  /// 适配器能力 → 该视频理论上可用的播放模式列表（按优先级）。
  ///
  /// 注意：这是"声明可用"，真实可用性由 [PlaybackPolicy] 在实际解析时验证。
  List<PlaybackMode> _playbackModesFor(PlatformAdapter adapter) {
    final caps = adapter.capabilities;
    return [
      if (caps.supportsNativePlayback) PlaybackMode.native,
      if (caps.supportsOfficialEmbed) PlaybackMode.officialEmbed,
      if (caps.supportsExternalFallback) PlaybackMode.external,
    ];
  }

  /// 支持搜索的平台适配器列表。
  List<PlatformAdapter> get searchableAdapters =>
      _registry.adapters.where((a) => a.supportsSearch).toList();

  /// 跨平台搜索。
  ///
  /// 并行请求所有支持搜索的平台，合并结果。
  /// **单个平台失败不影响其它平台**：失败记录在 [SearchResult.failures] 中，
  /// 成功的结果照常返回。
  Future<SearchResult> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SearchResult(
        query: query,
        items: const [],
        failures: const <String, FusionException>{},
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '请输入搜索关键词。',
          technicalMessage: 'Empty search query',
        ),
      );
    }

    final adapters = searchableAdapters;
    if (adapters.isEmpty) {
      return SearchResult(
        query: trimmed,
        items: const [],
        failures: const <String, FusionException>{},
        error: FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '当前没有支持搜索的平台。',
          technicalMessage: 'No adapter declares supportsSearch',
        ),
      );
    }

    final items = <UnifiedVideo>[];
    final failures = <String, FusionException>{};

    final results = await Future.wait<MapEntry<String, Object>>(
      adapters.map((a) async {
        try {
          final page0 = await a.searchVideos(
            trimmed,
            page: page,
            pageSize: pageSize,
          );
          return MapEntry<String, Object>(a.id, page0);
        } on FusionException catch (e) {
          return MapEntry<String, Object>(a.id, e);
        } catch (e) {
          return MapEntry<String, Object>(
            a.id,
            normalizeError(e, platformId: a.id),
          );
        }
      }),
    );

    for (final entry in results) {
      final value = entry.value;
      if (value is FeedPage) {
        items.addAll(value.items);
      } else if (value is FusionException) {
        failures[entry.key] = value;
      }
    }

    // 全部失败才算失败
    final allFailed = items.isEmpty && failures.length == adapters.length;
    return SearchResult(
      query: trimmed,
      items: items,
      failures: failures,
      error: allFailed
          ? (failures.values.firstOrNull ??
              FusionException(
                code: FusionErrorCode.capabilityUnavailable,
                userMessage: '搜索失败。',
                technicalMessage: 'All search adapters failed',
              ))
          : null,
    );
  }

  /// 解析播放源。
  Future<PlaybackOutcome> resolvePlayback(UnifiedVideo video) async {
    // 播放直链缓存（短 TTL）
    final cached = _cache.playback.peek(video.id);
    if (cached != null && !cached.stale) {
      _logger.info('playback: cache hit', {'video': video.id});
      return PlaybackOutcome(
        videoId: video.id,
        attempts: [
          PlaybackAttempt(
            mode: cached.value.mode,
            succeeded: true,
            detail: '使用缓存的播放地址。',
          ),
        ],
        source: cached.value,
      );
    }

    // 测量解析耗时：区分"缓存命中"与"真实网络解析"，
    // 便于定位 1–2 秒延迟到底出在哪一层。
    final sw = Stopwatch()..start();
    final outcome = await _policy.resolve(video);
    sw.stop();

    final source = outcome.source;
    if (source != null && source is NativePlaybackSource) {
      _cache.playback.put(video.id, source);
    }

    _logger.info('playback: resolved', {
      'video': video.id,
      'elapsedMs': sw.elapsedMilliseconds,
      'mode': source?.mode.name ?? 'none',
      'attempts': outcome.attempts.length,
    });

    return outcome;
  }

  /// 列表聚合：返回库中全部视频，按导入时间倒序。
  ///
  /// 平台间互不阻塞：单个视频的错误状态内嵌在实体中，不影响其它条目。
  Future<List<UnifiedVideo>> listVideos() => _store.all();

  /// 重新获取单个视频的元数据（忽略缓存）。
  Future<ResolveResult> refresh(String videoId) async {
    final existing = await _store.get(videoId);
    if (existing == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.videoNotFound,
          userMessage: '该视频不在库中。',
          technicalMessage: 'No stored video with id=$videoId',
        ),
      );
    }

    _cache.metadata.invalidate(videoId);
    _cache.playback.invalidate(videoId);

    final adapter = _registry.byId(existing.platformId);
    if (adapter == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage: '该平台适配器已不可用。',
          technicalMessage: 'Missing adapter ${existing.platformId}',
          platformId: existing.platformId,
        ),
      );
    }

    final match = LinkMatch(
      platformId: existing.platformId,
      platformVideoId: existing.platformVideoId,
      canonicalUrl: existing.canonicalUrl,
    );

    try {
      final video = await _fetchAndBuild(adapter, match, existing.originalUrl);
      await _store.upsert(video);
      return ResolveResult(video: video, match: match);
    } on FusionException catch (e) {
      // 刷新失败时保留旧元数据，只更新错误状态（不删除、不隐藏）
      final degraded = existing.copyWith(
        error: VideoErrorState.fromException(e),
        availability: _availabilityForError(e.code),
        playbackModes: const [],
        diagnostics: existing.diagnostics.copyWith(fromCache: true),
      );
      await _store.upsert(degraded);
      return ResolveResult(error: e, match: match, video: degraded);
    }
  }

  Future<void> remove(String videoId) async {
    _cache.metadata.invalidate(videoId);
    _cache.playback.invalidate(videoId);
    await _store.remove(videoId);
  }

  bool _isFresh(UnifiedVideo video) {
    final fetched = DateTime.tryParse(video.fetchedAt);
    if (fetched == null) return false;
    return DateTime.now().toUtc().difference(fetched.toUtc()) <
        _cache.config.metadataTtl;
  }

  static VideoAvailability _availabilityForError(FusionErrorCode code) =>
      switch (code) {
        FusionErrorCode.videoNotFound => VideoAvailability.unavailable,
        FusionErrorCode.permissionDenied ||
        FusionErrorCode.loginRequired ||
        FusionErrorCode.regionRestricted =>
          VideoAvailability.restricted,
        _ => VideoAvailability.unknown,
      };

  /// 从分享文案中提取第一个 URL。
  ///
  /// 抖音/B站分享文本形如：
  ///   `7.43 复制打开抖音，看看【xxx】https://v.douyin.com/xxxx/ ...`
  /// 这里只做保守提取，不猜测平台。
  static String _extractUrl(String input) {
    final match =
        RegExp(r'''https?://[^\s，,。、；;"'<>）)】\]]+''').firstMatch(input);
    if (match != null) return match.group(0)!;
    return input;
  }
}
