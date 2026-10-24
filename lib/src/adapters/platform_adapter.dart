/// 平台适配器契约。
///
/// 每个平台独立实现一个 [PlatformAdapter]。主界面与 UI 层
/// **不得**直接编写针对某个平台的请求逻辑或平台判断分支。
///
/// 新增平台 = 新增一个适配器实现 + 在注册表注册一行。
library;

import '../core/credential_vault.dart';
import '../core/errors.dart';
import '../core/http_client.dart';
import '../models/feed.dart';
import '../models/im.dart';
import '../models/interaction.dart';
import '../models/live.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import '../models/video_danmaku.dart';

/// 链接识别结果。
class LinkMatch {
  const LinkMatch({
    required this.platformId,
    required this.platformVideoId,
    required this.canonicalUrl,
    this.notes = const [],
  });

  /// 平台标识。
  final String platformId;

  /// 平台原始视频 ID。
  final String platformVideoId;

  /// 规范化后的平台视频页链接。
  final String canonicalUrl;

  /// 识别过程中的诊断说明（已脱敏）。
  final List<String> notes;

  Map<String, Object?> toJson() => {
        'platformId': platformId,
        'platformVideoId': platformVideoId,
        'canonicalUrl': canonicalUrl,
        'notes': notes,
      };
}

/// 平台元数据获取结果。
///
/// 适配器返回该结构，由 [VideoService] 统一包装为 [UnifiedVideo]。
/// 适配器不直接构造 [UnifiedVideo]，以保证 ID 生成、时间戳与
/// 诊断字段的一致性由核心层统一负责。
class VideoMetadata {
  const VideoMetadata({
    required this.title,
    this.description,
    this.author = VideoAuthor.empty,
    this.coverUrl,
    this.durationSeconds,
    this.width,
    this.height,
    this.publishedAt,
    this.stats = VideoStats.empty,
    this.availability = VideoAvailability.available,
    this.requiresAuth = false,
    this.limitations = const [],
    this.notes = const [],
    this.upstreamEndpoint = '',
  });

  final String title;
  final String? description;
  final VideoAuthor author;
  final String? coverUrl;
  final double? durationSeconds;
  final int? width;
  final int? height;
  final String? publishedAt;
  final VideoStats stats;
  final VideoAvailability availability;
  final bool requiresAuth;

  /// 该平台在当前环境下的固有限制（会进入 UnifiedVideo.diagnostics.limitations）。
  final List<String> limitations;

  /// 本次获取的可诊断信息。
  final List<String> notes;

  /// 实际使用的上游接口标识。
  final String upstreamEndpoint;
}

/// 播放源解析请求。
class PlaybackRequest {
  const PlaybackRequest({
    required this.platformVideoId,
    required this.canonicalUrl,
    this.preferredMode,
    this.preferQuality,
  });

  final String platformVideoId;
  final String canonicalUrl;

  /// 用户期望的播放模式；为 null 表示由策略层决定。
  final PlaybackMode? preferredMode;

  /// 期望的清晰度码值（平台相关），仅作为偏好提示。
  final int? preferQuality;
}

/// 平台适配器接口。
abstract class PlatformAdapter {
  /// 平台稳定标识，例如 'bilibili'。
  String get id;

  /// 平台展示名，例如 '哔哩哔哩'。
  String get displayName;

  /// 平台来源标识的短标签，用于列表角标（例如 'B站'）。
  String get shortLabel;

  /// 该适配器实现的能力声明，用于报告与 UI 如实展示。
  AdapterCapabilities get capabilities;

  /// 该平台可识别的域名（小写，不含协议）。
  List<String> get supportedHosts;

  /// 判断链接是否属于本平台。必须只依据域名/路径结构，不得猜测。
  bool matches(Uri uri);

  /// 从链接中提取平台视频 ID 与规范链接。
  ///
  /// 无法提取时返回 null（由上层映射为 videoIdNotFound）。
  /// 允许在此发起网络请求（例如展开短链）。
  Future<LinkMatch?> extract(Uri uri);

  /// 获取视频元数据。
  Future<VideoMetadata> fetchMetadata(LinkMatch match);

  /// 解析播放源。返回 null 表示该模式当前不可用，
  /// 由播放策略层继续尝试下一优先级模式。
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request);

  /// 该适配器提供的推荐流来源列表。
  ///
  /// 返回空列表表示该平台不提供推荐流（例如仅支持链接接入的平台）。
  /// 主界面据此渲染"内容来源"切换，不在 UI 层硬编码任何平台判断。
  List<FeedSource> get feedSources => const [];

  /// 拉取一页推荐流。
  ///
  /// [sourceId] 来自 [feedSources] 中的 [FeedSource.id]。
  /// 未声明该来源时必须抛 [FusionException]（unsupportedPlatform），
  /// 不得静默返回空列表——那会让"不可用"伪装成"没有内容"。
  Future<FeedPage> fetchFeed(FeedRequest request, {required String sourceId}) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台未提供推荐流。',
      technicalMessage: 'Adapter $id does not implement fetchFeed (source=$sourceId)',
      platformId: id,
    );
  }

  /// 该平台是否支持搜索。
  ///
  /// 默认 false。只有真正实现并验证过搜索接口的适配器才返回 true，
  /// 避免 UI 展示一个点了必然失败的搜索入口。
  bool get supportsSearch => false;

  /// 搜索视频。
  ///
  /// [page] 从 1 开始（与多数平台语义一致）。
  /// 不支持搜索时必须抛 [FusionException]，不得返回空列表。
  Future<FeedPage> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持搜索。',
      technicalMessage: 'Adapter $id does not implement searchVideos',
      platformId: id,
    );
  }

  /// 是否支持**搜索联想词**（输入时的候选提示）。
  ///
  /// 与 [supportsSearch] 分开，因为两者的登录要求常常不同：
  /// 抖音的搜索结果接口要登录（`2483 请先登录`），但联想词接口
  /// **匿名可用**（实测 `code=0`）。UI 据此在未登录时也能给候选词，
  /// 而不是整个搜索框都是死的。
  bool get supportsSearchSuggestions => false;

  /// 拉取搜索联想词。
  ///
  /// [query] 是用户已输入的前缀。返回候选词列表（纯文本，已去重）。
  ///
  /// 不支持时抛 `unsupportedPlatform`；**返回空列表表示"这个前缀没有
  /// 候选词"**（平台确实没给），不是"能力不可用"。
  Future<List<String>> fetchSearchSuggestions(String query) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持搜索联想。',
      technicalMessage:
          'Adapter $id does not implement fetchSearchSuggestions',
      platformId: id,
    );
  }

  // ── 互动能力 ────────────────────────────────────────────────

  /// 是否支持读取评论列表。
  bool get supportsComments => false;

  /// 是否支持点赞（写操作，需要登录）。
  bool get supportsLike => false;

  /// 是否支持投币。
  bool get supportsCoin => false;

  /// 是否支持收藏。
  bool get supportsFavorite => false;

  /// 拉取评论列表。
  ///
  /// 多数平台评论读取是公开的；[session] 为 null 时按匿名访问。
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持评论。',
      technicalMessage: 'Adapter $id does not implement fetchComments',
      platformId: id,
    );
  }

  /// 查询当前用户对该视频的互动状态。
  ///
  /// 未登录时返回 [InteractionState.unknown]，
  /// **不得**伪造"未点赞"——那会让用户以为操作被重置了。
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async =>
      InteractionState.unknown;

  /// 点赞 / 取消点赞。
  ///
  /// 未登录时必须抛 `loginRequired`，不得静默失败。
  Future<InteractionResult> setLike(
    String platformVideoId, {
    required bool like,
    required PlatformSession session,
    int? aid,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持点赞。',
      technicalMessage: 'Adapter $id does not implement setLike',
      platformId: id,
    );
  }

  /// 投币。[count] 为 1 或 2。
  Future<InteractionResult> setCoin(
    String platformVideoId, {
    required int count,
    required PlatformSession session,
    bool alsoLike = false,
    int? aid,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持投币。',
      technicalMessage: 'Adapter $id does not implement setCoin',
      platformId: id,
    );
  }

  /// 收藏 / 取消收藏。
  ///
  /// 未登录时必须抛 `loginRequired`，不得静默失败。
  ///
  /// # 参数语义
  ///
  ///  - [folderIds]：要把视频**加入**的收藏夹 ID；
  ///  - [removeFolderIds]：要把视频**移出**的收藏夹 ID；
  ///  - 两者都为 null 时按 [favorite] 布尔走旧语义：
  ///    true → 加入默认收藏夹（由适配器自行确定，不得硬编码 ID），
  ///    false → 从该视频当前归属的所有收藏夹移出。
  ///
  /// # [favorite] 为什么还留着
  ///
  /// 既有调用方（`VideoService.setFavorite`、单测）只传布尔。
  /// 保留它保证向后兼容；一旦给出任一个夹列表参数，它就不再参与决策。
  ///
  /// # 关于 accepted
  ///
  /// `accepted` 只表示**平台接受了请求**（`code == 0`），
  /// **不表示归属真的变了**。实测（2026-10-19）两个坑：
  ///  - 向一个**不存在**的收藏夹收藏，平台返回 `code=0 message=OK`（假成功）；
  ///  - `data.success_num` **恒为 0**，即使写入真的生效，所以它也不能用来判成败。
  ///
  /// 因此需要如实回显的调用方必须在写入后调 [scanFoldersContainingVideo]
  /// 复查归属；适配器**不做**这次复查（一次扫描要 N 个请求，
  /// 时机该由 UI 决定，而不是写死在写操作里）。
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持收藏。',
      technicalMessage: 'Adapter $id does not implement setFavorite',
      platformId: id,
    );
  }

  /// 是否支持"选择收藏夹"。
  ///
  /// 只有真正实现并验证过收藏夹列表接口的适配器才返回 true，
  /// 避免 UI 展示一个点了必然失败的收藏夹选择面板。
  bool get supportsFavoriteFolders => false;

  /// 拉取当前账号的收藏夹列表。
  ///
  /// 未登录时抛 `loginRequired`。不支持时抛 `unsupportedPlatform`。
  ///
  /// **只负责"有哪些夹"**：id / 标题 / 条数 / 是否默认 / 是否公开。
  /// 平台列表接口上没有任何字段能说明"某个视频在不在这个夹里"
  /// （`fav_state` 是收藏夹自身的状态，见 [FavoriteFolder] 的说明），
  /// 所以归属必须走 [scanFoldersContainingVideo]。
  Future<List<FavoriteFolder>> fetchFavoriteFolders({
    required PlatformSession session,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持收藏夹。',
      technicalMessage: 'Adapter $id does not implement fetchFavoriteFolders',
      platformId: id,
    );
  }

  /// 是否支持"逐夹归属扫描"（回答"这个视频在哪些收藏夹里"）。
  ///
  /// 收藏夹选择面板要回显勾选状态，必须有这个能力；
  /// 不支持时 UI 退化为"只知道收藏过，不知道在哪个夹"。
  bool get supportsFolderOwnershipScan => false;

  /// 扫描"该视频在哪些收藏夹里"。
  ///
  /// [platformVideoId] 是平台的视频标识（B 站为 BV 号）。
  /// [maxRequests] 是**请求预算**：累计发出的请求数达到它就停止，
  /// 返回已经完成的部分，而不是继续打到平台限流。
  ///
  /// # 为什么必须带预算（成本核算，实测 2026-10-19）
  ///
  ///  1. 平台**没有**任何反查端点：`resource/list` 的 `keyword` 不参与
  ///     归属判定；`fav_state` 是收藏夹自身状态（理由见 [FavoriteFolder]）。
  ///     所以只能逐夹把内容翻页比 bvid。
  ///  2. `ps` 的服务端硬上限是 20（实测 ps=100/200/500/1000 仍只回 20 条）。
  ///  3. 一个 6 夹、内容合计 192 条的账号，全量核对需要
  ///     `⌈32/20⌉+1+1+1+1+⌈145/20⌉ = 14` 个请求。
  ///  4. B 站在**连续第 6 个请求**起返回 HTTP 412 /
  ///     `status_msg="triggered captcha"`（业务码 `-70103112`），
  ///     实测要等约 6 秒才恢复。
  ///
  /// 无界扫描因此**必然**被打死，用户看到的是"收藏面板转圈后失败"。
  /// 本方法的目标是"在预算内尽量多确认，并如实交代没确认的部分"，
  /// 而不是假装给出一个完整答案。
  ///
  /// 结果里的 [FolderOwnershipScan.exhaustive] 与
  /// [FolderOwnershipScan.checkedFolderIds] 必须被调用方如实对待：
  /// **既不在 containedFolderIds、也没被 checked 的夹，状态是"不知道"，
  /// 不是"不包含"**。UI 不得把它们渲染成未勾选。
  ///
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<FolderOwnershipScan> scanFoldersContainingVideo({
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 6,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持收藏夹归属查询。',
      technicalMessage:
          'Adapter $id does not implement scanFoldersContainingVideo',
      platformId: id,
    );
  }

  /// 复查"刚收藏的项是否真的进了**指定那几个夹**"。
  ///
  /// # 为什么单独有这条便宜路径
  ///
  /// 全量归属扫描的成本实测不可接受（6 夹账号去重后 144 个请求），
  /// 但写入后的复查**不需要**知道"还在哪些别的夹里"，只需要知道
  /// "我刚点的那几个夹到底收下了没有"。
  ///
  /// 依据实测（2026-10-19）：`resource/list` 默认按 `mtime` 倒序，
  /// **新加入的项出现在第 1 页**。所以每个目标夹只需 1 个请求
  /// （保守最多翻 [maxPages]=2 页），而不是把整个夹翻完。
  ///
  /// # 与 [scanFoldersContainingVideo] 的分工（必须分清）
  ///
  ///  - 本方法只回答"**这几个目标夹**里有没有" → 用于写后确认；
  ///  - 后者回答"这个视频一共在哪些夹里" → 需要逐夹扫描，
  ///    成本高且受预算限制，只在选择面板按需调用。
  ///
  /// 返回值是**已确认包含**的目标夹子集：不在返回列表里的目标夹
  /// 表示"未确认"，可能是真没进去，也可能是这一页没翻到或请求失败
  /// ——调用方不得据此断言"没收藏成功"，应提示"未确认，请刷新查看"。
  ///
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持收藏结果复查。',
      technicalMessage: 'Adapter $id does not implement verifyRecentFavorite',
      platformId: id,
    );
  }

  // ── 硬币余额 / 稍后再看 / 关注 ──────────────────────────────
  //
  // 这三项与"点赞/投币/收藏"不同：它们的操作对象不完全是单个视频
  // （余额属于账号，关注属于 UP 主），因此单独成组，
  // 不塞进 InteractionState 的写方法里。
  // 全部按"能力开关 + 默认抛 unsupportedPlatform"的模式给出，
  // UI 依据 supports* 决定是否渲染按钮，不得自行猜平台。

  /// 是否支持读取硬币余额。
  bool get supportsCoinBalance => false;

  /// 读取当前账号的可用硬币余额。
  ///
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  /// 返回 null 表示平台未下发该字段（调用方**不得**当成 0——
  /// 0 是"确实没有币"，null 是"不知道"）。
  Future<int?> fetchCoinBalance({required PlatformSession session}) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持硬币余额。',
      technicalMessage: 'Adapter $id does not implement fetchCoinBalance',
      platformId: id,
    );
  }

  /// 是否支持"稍后再看"。
  bool get supportsWatchLater => false;

  /// 查询该视频是否已在"稍后再看"列表里。
  ///
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<bool> fetchWatchLater({
    required String platformVideoId,
    required PlatformSession session,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持稍后再看。',
      technicalMessage: 'Adapter $id does not implement fetchWatchLater',
      platformId: id,
    );
  }

  /// 加入 / 移出"稍后再看"。
  ///
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<InteractionResult> setWatchLater({
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持稍后再看。',
      technicalMessage: 'Adapter $id does not implement setWatchLater',
      platformId: id,
    );
  }

  /// 是否支持关注 / 取关 UP 主。
  bool get supportsFollowAuthor => false;

  /// 是否支持"收藏内容浏览"（收藏夹里的条目列表、稍后再看列表）。
  ///
  /// 与 [supportsFavoriteFolders] 的区别：后者只回答"能不能列出夹"，
  /// 前者回答"能不能列出夹**里面的视频**"。UI 据此决定是否渲染
  /// "我的收藏夹 → 点开看内容"这条路径，不能放死按钮。
  bool get supportsSavedContent => false;

  /// 拉取某个收藏夹里的内容（分页）。
  ///
  /// [mediaId] 来自 [fetchFavoriteFolders] 的 [FavoriteFolder.id]。
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<SavedVideoPage> fetchFavoriteFolderVideos(
    int mediaId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持查看收藏夹内容。',
      technicalMessage:
          'Adapter $id does not implement fetchFavoriteFolderVideos',
      platformId: id,
    );
  }

  /// 拉取"稍后再看"列表（分页）。
  ///
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<SavedVideoPage> fetchWatchLaterVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持稍后再看列表。',
      technicalMessage: 'Adapter $id does not implement fetchWatchLaterVideos',
      platformId: id,
    );
  }

  /// 平台是否提供**云端**观看历史。
  ///
  /// 与本地 `VideoProgressStore` 是两回事：那个只记录本设备的播放位置，
  /// 不能冒充平台账号的历史记录。
  bool get supportsCloudHistory => false;

  /// 拉取账号的云端观看历史（分页）。
  ///
  /// 不支持时抛 `unsupportedPlatform`；未登录抛 `loginRequired`。
  Future<SavedVideoPage> fetchHistoryVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
    int cursor = 0,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持云端观看历史。',
      technicalMessage: 'Adapter $id does not implement fetchHistoryVideos',
      platformId: id,
    );
  }

  /// 关注 / 取关 UP 主。
  ///
  /// [targetMid] 为 UP 主的数字用户 ID 字符串。不支持时抛
  /// `unsupportedPlatform`；未登录抛 `loginRequired`。
  ///
  /// 关注**状态**的读取不需要单独方法：B 站在
  /// `archive/relation` 的 `data.attention` 里一并返回，
  /// 已由 [fetchInteractionState] 映射到 [InteractionState.following]。
  Future<InteractionResult> setFollowAuthor({
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持关注。',
      technicalMessage: 'Adapter $id does not implement setFollowAuthor',
      platformId: id,
    );
  }

  // ── 直播 ────────────────────────────────────────────────────
  //
  // 直播与普通视频是两套数据：房间有独立 ID、独立播放协议
  // （FLV / HLS）、独立的消息通道。因此不塞进 fetchMetadata /
  // resolvePlayback，而是单独一组方法，
  // 避免普通视频路径被直播的时效签名污染。
  //
  // 这些是**类成员而非 extension**：extension 方法无法被子类覆盖，
  // 通过 PlatformAdapter 类型调用时会命中默认实现而不是适配器实现。

  /// 是否支持直播。
  bool get supportsLive => false;

  /// 拉取直播列表。
  Future<LiveRoomPage> fetchLiveRooms({
    int page = 1,
    int pageSize = 20,
    int? parentAreaId,
    int? areaId,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持直播。',
      technicalMessage: 'Adapter $id does not implement fetchLiveRooms',
      platformId: id,
    );
  }

  /// 拉取直播间详情（按字符串房间号）。
  ///
  /// 默认实现把 [roomKey] 解析成数字后走 [fetchLiveRoomInfo]。
  /// 房间号不是数字的平台（抖音）必须覆盖本方法。
  Future<LiveRoomInfo> fetchLiveRoomInfoByKey(String roomKey) {
    final numeric = int.tryParse(roomKey);
    if (numeric == null) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持这种直播间标识。',
        technicalMessage:
            'Adapter $id: roomKey "$roomKey" is not numeric and '
            'fetchLiveRoomInfoByKey was not overridden',
        platformId: id,
      );
    }
    return fetchLiveRoomInfo(numeric);
  }

  /// 拉取直播间详情。
  Future<LiveRoomInfo> fetchLiveRoomInfo(int roomId) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持直播。',
      technicalMessage: 'Adapter $id does not implement fetchLiveRoomInfo',
      platformId: id,
    );
  }

  /// 解析直播播放流。
  ///
  /// 返回的地址带时效签名，调用方**不得持久化**。
  ///
  /// 默认实现把 [roomKey] 解析成数字后走 [resolveLiveStream]。
  /// 房间号不是数字的平台必须覆盖本方法。
  Future<LiveStream> resolveLiveStreamByKey(
    String roomKey, {
    int? quality,
  }) {
    final numeric = int.tryParse(roomKey);
    if (numeric == null) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持这种直播间标识。',
        technicalMessage:
            'Adapter $id: roomKey "$roomKey" is not numeric and '
            'resolveLiveStreamByKey was not overridden',
        platformId: id,
      );
    }
    return resolveLiveStream(numeric, quality: quality);
  }

  /// 解析直播播放流。
  ///
  /// 返回的地址带时效签名，调用方**不得持久化**。
  Future<LiveStream> resolveLiveStream(int roomId, {int? quality}) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持直播播放。',
      technicalMessage: 'Adapter $id does not implement resolveLiveStream',
      platformId: id,
    );
  }

  /// 是否支持读取视频内弹幕（不是直播弹幕）。
  ///
  /// 与 [fetchLiveDanmakuEndpoint]（直播间的实时弹幕流）是两回事：
  /// 这里指的是**点播视频时间轴上的弹幕**，用于在播放器上叠加显示。
  ///
  /// 默认 false。只有真正实现并验证过弹幕接口的适配器才返回 true，
  /// 避免 UI 展示一个点了必然失败的弹幕开关。
  bool get supportsVideoDanmaku => false;

  /// 拉取视频内弹幕。
  ///
  /// [platformVideoId] 是平台视频 ID（B站为 BV 号）。
  ///
  /// [durationSeconds] 用于计算需要拉几段：平台通常按固定时长切段
  /// （B站 6 分钟一段），不给时长就只能拉到第一段。调用方从
  /// [VideoMetadata.durationSeconds] 拿。
  ///
  /// [fromSeconds] / [toSeconds] 可选，用于只取某个时间区间的弹幕
  /// （例如播放器只预加载接下来 60 秒）。为 null 表示全量。
  ///
  /// 返回按 [VideoDanmaku.progressMs] 升序排列。
  ///
  /// 不支持时抛 [FusionException]（unsupportedPlatform），
  /// **不返回空列表**——那会把"能力不存在"伪装成"这个视频没有弹幕"。
  Future<List<VideoDanmaku>> fetchVideoDanmaku(
    String platformVideoId, {
    double? durationSeconds,
    double? fromSeconds,
    double? toSeconds,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持视频弹幕。',
      technicalMessage: 'Adapter $id does not implement fetchVideoDanmaku',
      platformId: id,
    );
  }

  /// 是否支持给**评论**点赞（不是给视频点赞）。
  bool get supportsCommentLike => false;

  /// 给评论点赞 / 取消点赞。
  ///
  /// [commentId] 是平台评论 ID（B站 `rpid`、抖音 `cid`）。
  /// [platformVideoId] 用于定位评论所属的视频（B站接口要求 `oid`）。
  /// [replyLevel] 是**被点赞评论自己的层级**（抖音 `level` 字段）：
  /// 抖音的 `comment/digg` 要原样回传该值（bundle s86.js 调用点直接
  /// 解构 `level:r` 转发），楼中楼里的二级评论与一级评论的 level 不同。
  /// 没有该概念的平台（B站）忽略此参数。
  ///
  /// 未登录必须抛 `loginRequired`，不得静默失败。
  Future<InteractionResult> setCommentLike(
    String platformVideoId, {
    required String commentId,
    required bool like,
    required PlatformSession session,
    int? replyLevel,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持评论点赞。',
      technicalMessage: 'Adapter $id does not implement setCommentLike',
      platformId: id,
    );
  }

  /// 是否支持回复评论。
  bool get supportsCommentReply => false;

  /// 是否支持读取**楼中楼**（某条评论下的二级评论）。
  ///
  /// 与 [supportsCommentReply] 分开：能回复到评论下 ≠ 能把那条评论的
  /// 二级评论列出来。多数平台一级评论列表**不内联**二级评论
  /// （抖音实测 `reply_comment_total=2` 但 `reply_comment` 为空数组），
  /// 所以"展开 N 条回复"必须单独一次请求。
  bool get supportsCommentReplies => false;

  /// 拉取某条评论下的二级评论（分页）。
  ///
  /// [parentCommentId] 是**根评论** id（楼中楼归属的那条一级评论）。
  /// 未登录时二级评论通常也能读（平台策略不同），因此 [session] 可空；
  /// 但 `isLikedByMe` 这类登录态字段会退化为 false。
  ///
  /// 不支持时抛 `unsupportedPlatform`，**不返回空列表**——
  /// 那会把"能力不存在"伪装成"这条评论没有回复"。
  Future<CommentPage> fetchCommentReplies(
    String platformVideoId, {
    required String parentCommentId,
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持查看楼中楼回复。',
      technicalMessage: 'Adapter $id does not implement fetchCommentReplies',
      platformId: id,
    );
  }

  /// 平台是否提供**云端播放进度上报**。
  ///
  /// 与本地 `VideoProgressStore` 是两回事：那个只记本设备的位置。
  bool get supportsCloudProgress => false;

  /// 把本次播放位置上报给平台账号（跨设备续播用）。
  ///
  /// 语义约束：
  ///  - 这是**旁路**操作。失败不得影响本地进度落盘，调用方必须
  ///    catch 后降级（本地进度是权威，云端是尽力而为）。
  ///  - 未登录抛 `loginRequired`；平台不支持抛 `unsupportedPlatform`。
  ///  - **不做乐观成功**：平台回非 0 码时如实抛错。
  Future<void> reportPlaybackProgress({
    required String platformVideoId,
    required Duration position,
    required Duration duration,
    required PlatformSession session,
    int? partNumber,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持云端播放进度。',
      technicalMessage: 'Adapter $id does not implement reportPlaybackProgress',
      platformId: id,
    );
  }

  /// 回复一条评论（发一条新评论，或回复到某条评论下）。
  ///
  /// [replyToCommentId] 为 null 表示发**顶层评论**；非 null 表示回复
  /// 到该评论下（B站二级评论）。
  ///
  /// [rootCommentId]：**回复二级评论**时才传——它是那条二级评论所属的
  /// 根评论 id。实测（B站 `reply/add`）回复二级评论必须同时带
  /// `root`（根）与 `parent`（被回复的那条二级评论）两个不同的值，
  /// 只带一个会 `-400 参数错误`。回复顶层时二者相同，可不传
  /// [rootCommentId]（适配器把 parent 也当 root）。
  ///
  /// 返回新评论的 ID（平台不给时返回 null）。
  ///
  /// 未登录必须抛 `loginRequired`。
  Future<String?> replyComment(
    String platformVideoId, {
    required String message,
    required PlatformSession session,
    String? replyToCommentId,
    String? rootCommentId,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持回复评论。',
      technicalMessage: 'Adapter $id does not implement replyComment',
      platformId: id,
    );
  }

  /// 是否支持"一键三连"（点赞 + 投币 + 收藏 一次完成）。
  bool get supportsTripleAction => false;

  /// 一键三连。
  ///
  /// 语义：对同一个视频**同时**点赞、投币、收藏。
  ///
  /// 返回值必须如实反映**每一项**的结果，不能因为其中两项成功就报成功。
  /// 某一项被平台拒绝（例如投币被风控）时，要在 [TripleActionResult]
  /// 里标出是哪一项、原因是什么。
  Future<TripleActionResult> tripleAction(
    String platformVideoId, {
    required PlatformSession session,
    int coinCount = 1,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持一键三连。',
      technicalMessage: 'Adapter $id does not implement tripleAction',
      platformId: id,
    );
  }

  /// 获取弹幕服务器连接参数。
  Future<LiveDanmakuEndpoint> fetchLiveDanmakuEndpoint(int roomId) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持直播弹幕。',
      technicalMessage:
          'Adapter $id does not implement fetchLiveDanmakuEndpoint',
      platformId: id,
    );
  }

  /// 拉取直播分区（一级）。
  Future<List<LiveArea>> fetchLiveAreas() async => const [];

  // ── 私信（IM）──────────────────────────────────────────────
  //
  // 与互动不同：私信是**账号之间的通信**，不是对某个视频的操作。
  // 因此不塞进 InteractionState，单独一组。
  //
  // 全部按"能力开关 + 默认抛 unsupportedPlatform"给出：
  // UI 依据 [supportsIm] 决定是否渲染消息入口，
  // 不支持的平台不会出现一个点进去空白的页面。

  /// 该平台是否支持应用内私信。
  bool get supportsIm => false;

  /// 拉一页会话。
  ///
  /// [endTs] 是上一页最后一条的 `session_ts`，首页传 0。
  /// 未登录抛 `loginRequired`；不支持抛 `unsupportedPlatform`。
  Future<ImSessionPage> fetchImSessions({
    required PlatformSession session,
    int count = 20,
    int endTs = 0,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持私信。',
      technicalMessage: 'Adapter $id does not implement fetchImSessions',
      platformId: id,
    );
  }

  /// 拉一页历史消息。
  ///
  /// **服务端按新→旧返回**，调用方负责排序。
  /// [endSeqno] 是上一页的 `min_seqno`，首页传 0。
  Future<ImMessagePage> fetchImMessages({
    required PlatformSession session,
    required int talkerId,
    int size = 20,
    int endSeqno = 0,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持私信。',
      technicalMessage: 'Adapter $id does not implement fetchImMessages',
      platformId: id,
    );
  }

  /// 发送一条文本消息。
  ///
  /// 返回的 [ImSendResult.accepted] 必须由**服务端确认**（code=0 且有 msg_key），
  /// 不能以"HTTP 200"代替。
  Future<ImSendResult> sendImMessage({
    required PlatformSession session,
    required int talkerId,
    required String content,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持私信。',
      technicalMessage: 'Adapter $id does not implement sendImMessage',
      platformId: id,
    );
  }

  /// 拉未读汇总（入口红点）。
  Future<ImUnread> fetchImUnread({required PlatformSession session}) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持私信。',
      technicalMessage: 'Adapter $id does not implement fetchImUnread',
      platformId: id,
    );
  }

  /// 批量取私信用户信息（昵称/头像）。
  Future<Map<int, ImUserInfo>> fetchImUserInfos({
    required PlatformSession session,
    required List<int> uids,
  }) async =>
      const {};

  /// 把某个会话标记为已读。
  ///
  /// 只能在用户真正打开会话、且已拉到最新消息后调用。
  Future<bool> markImSessionRead({
    required PlatformSession session,
    required int talkerId,
    required int ackSeqno,
  }) async =>
      false;

  // ── 私信：媒体能力 ──────────────────────────────────────────
  //
  // 与上面的"能力开关 + 默认抛"保持一致：不支持的平台不会出现
  // 点进去必然失败的按钮。

  /// 是否支持在私信里发送图片。
  ///
  /// **语义**：适配器实现了上传 + 图片消息构造。
  /// 与"是否已用真实登录态验证跑通"是两件事，验证状态写在文档里。
  bool get supportsImImageSend => false;

  /// 是否支持读取表情面板。
  bool get supportsImEmote => false;

  /// 是否支持**发送**自定义表情消息。
  ///
  /// 与 [supportsImEmote]（读取）分开：很多平台允许接收并渲染表情，
  /// 但发送自定义表情要求该表情已在用户收藏里，未验证前不该给入口。
  bool get supportsImCustomEmojiSend => false;

  /// 上传一张图片，返回可用于构造消息的媒体信息。
  ///
  /// 失败抛 `FusionException`（或适配器私有异常，由 service 归一化）。
  /// **不得返回本地路径或伪造地址**。
  Future<ImMedia> uploadImImage({
    required PlatformSession session,
    required List<int> bytes,
    required String filename,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持发送图片。',
      technicalMessage: 'Adapter $id does not implement uploadImImage',
      platformId: id,
    );
  }

  /// 发送一条图片消息。
  Future<ImSendResult> sendImImage({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持发送图片。',
      technicalMessage: 'Adapter $id does not implement sendImImage',
      platformId: id,
    );
  }

  /// 发送一条自定义表情消息。
  Future<ImSendResult> sendImCustomEmoji({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持发送自定义表情。',
      technicalMessage: 'Adapter $id does not implement sendImCustomEmoji',
      platformId: id,
    );
  }

  /// 拉取表情面板。
  ///
  /// 失败**不抛异常**，返回 `loaded: false` 的面板并带原因 ——
  /// 表情加载不出来不该让聊天页报错。
  Future<ImEmotePanel> fetchImEmotePanel({
    required PlatformSession session,
  }) async =>
      const ImEmotePanel(unavailableReason: '该平台不支持表情面板。');
}

/// 适配器能力声明。用于报告与 UI 如实展示"已实现 / 受限"。
class AdapterCapabilities {
  const AdapterCapabilities({
    required this.supportsMetadata,
    required this.supportsNativePlayback,
    required this.supportsOfficialEmbed,
    required this.supportsExternalFallback,
    this.requiresAuthForMetadata = false,
    this.requiresSignature = false,
    this.maxQualityWithoutAuth,
    this.notes = const [],
  });

  /// 是否支持元数据获取。
  final bool supportsMetadata;

  /// 是否支持应用内播放（NATIVE）。
  final bool supportsNativePlayback;

  /// 是否支持官方嵌入播放（OFFICIAL_EMBED）。
  final bool supportsOfficialEmbed;

  /// 是否支持跳转原平台（EXTERNAL）。几乎总是 true。
  final bool supportsExternalFallback;

  /// 元数据获取是否需要登录。
  final bool requiresAuthForMetadata;

  /// 是否需要平台安全签名（如抖音 a_bogus）。
  final bool requiresSignature;

  /// 未登录时可获得的最高清晰度标签。
  final String? maxQualityWithoutAuth;

  /// 能力说明（会写入报告）。
  final List<String> notes;

  Map<String, Object?> toJson() => {
        'supportsMetadata': supportsMetadata,
        'supportsNativePlayback': supportsNativePlayback,
        'supportsOfficialEmbed': supportsOfficialEmbed,
        'supportsExternalFallback': supportsExternalFallback,
        'requiresAuthForMetadata': requiresAuthForMetadata,
        'requiresSignature': requiresSignature,
        'maxQualityWithoutAuth': maxQualityWithoutAuth,
        'notes': notes,
      };
}

/// 直播分区。
class LiveArea {
  const LiveArea({
    required this.id,
    required this.name,
    this.children = const [],
  });

  final int id;
  final String name;

  /// 二级分区。
  final List<LiveArea> children;
}

/// 一页直播房间。
class LiveRoomPage {
  const LiveRoomPage({
    required this.items,
    required this.page,
    required this.hasMore,
    this.totalCount = 0,
    this.notes = const [],
  });

  final List<LiveRoomSummary> items;
  final int page;
  final bool hasMore;
  final int totalCount;
  final List<String> notes;

  bool get isEmpty => items.isEmpty;
}

/// 适配器构造上下文：注入共享依赖，避免适配器自行创建网络栈。
class AdapterContext {
  const AdapterContext({required this.http, required this.logger});

  final FusionHttpClient http;
  final Object logger;
}

/// 一个收藏夹。
///
/// 来自平台真实接口，不做本地构造。`id` 是收藏操作的目标标识。
///
/// # 这里**不**带"某视频是否在此夹里"的字段
///
/// 结构上很想加一个 `favState`/`isFavorited`——B 站
/// `created/list-all` 的每个夹确实带 `fav_state`，看着就是归属。
/// 判别实验（实测 2026-10-19）证明**不是**：
///  - 取确定在夹内的样本：夹「gay」(id=4020481152) `media_count=1`，
///    `resource/list` 首屏就命中 `BV1ySJx6YETj`；
///  - 此时 `created/list-all?up_mid=&bvid=BV1ySJx6YETj` 里该夹
///    的 `fav_state` **仍为 0**；6 个夹全部为 0；
///  - 真实写入回环（add → media_count 32→33 → relation.favorite=true）
///    期间 `fav_state` **恒为 0**。
///
/// 语义：`fav_state` 描述的是**收藏夹自身**的状态（与 `like_state` 并列，
/// "我是否收藏/点赞了这个夹子"），对自己创建的夹永远是 0。
///
/// 因此归属判断必须走 [PlatformAdapter.scanFoldersContainingVideo]
/// （逐夹 `resource/list` 翻页比对 bvid），不能靠夹列表上的任何字段。
class FavoriteFolder {
  const FavoriteFolder({
    required this.id,
    required this.title,
    this.mediaCount,
    this.isDefault = false,
    this.isPublic = true,
  });

  /// 收藏夹 ID（收藏操作的 `media_id`）。
  ///
  /// **不要假定默认收藏夹的 ID 固定**——不同账号、不同时间都可能不同，
  /// 必须每次都从接口取。
  final int id;

  /// 收藏夹名称。
  final String title;

  /// 内含内容数。
  ///
  /// # 平台缓存值，可能滞后于实际内容数
  ///
  /// 实测（2026-10-19）：往 32 条的夹里新增一条后，
  /// `created/list-all` 的 `media_count` **仍显示 32**；
  /// 另一个夹 list-all 给 145、`folder/info` 给 248。
  /// 唯一准确的内容数来自 `resource/mode/get`，但该接口有配额
  /// （实测每请求 +15s、约 4 次/分钟），**不能**用于批量或实时计数。
  ///
  /// 因此本字段只适合做**排序与粗略展示**（"约 32 个内容"），
  /// **不得**用于：
  ///  - "该视频是否已收藏"的判断（与内容数无关，且归属只能靠扫描）；
  ///  - 精确计数或"翻完没有"的边界判断（一律靠空页与 `has_more`）。
  final int? mediaCount;

  /// 是否为账号的默认收藏夹。
  final bool isDefault;

  /// 是否公开。
  ///
  /// 按 B 站前端惯例用 `attr` 的 **bit0** 判定（`isPublic = (attr & 1) == 0`）。
  /// 但本地实测未能证实这条规则：同一账号 5 个非默认夹 `attr=22`，
  /// 而 `22 & 1 = 0`（22 = `0b10110`，最低位是 0），按此规则它们全部
  /// 判为"公开"；`folder/info` 也没给出 `priv_reason` 键。
  /// 也就是说：bit0 目前**没有阳性样本**可验证。
  ///
  /// 因此 UI 不要把 [isPublic] 当成强约束去隐藏收藏夹；
  /// 若出现"某个夹被平台标记为私密"的真实样本，再回来收紧。
  final bool isPublic;
}

/// 一次"收藏夹归属扫描"的结果。
///
/// # 为什么不是一个简单的 `List<int>`
///
/// 归属只能靠**逐夹把内容翻页比对 bvid**得到（平台没有反查端点），
/// 而这条路径有硬成本：`ps` 服务端上限 20、B 站连续第 6 个请求起
/// 返回 HTTP 412（实测）。所以扫描必然可能出现"没扫完"。
///
/// 如果接口只返回"包含该视频的夹 ID 列表"，调用方**无法区分**：
///  - 这个夹里确实没有该视频（已核对，结论可靠）；
///  - 这个夹还没轮到核对（预算用尽 / 被限流，结论未知）。
/// 把后者当成前者，UI 会把用户**已经收藏进的夹显示成未勾选**——
/// 那是假的否定，比"不显示勾选状态"更糟。
///
/// 所以这里把三层分开：
///  - [containedFolderIds]：已确认**包含**该视频；
///  - [checkedFolderIds]：已**完整核对过**（翻到底）的夹；
///  - 两者都不在 = **不知道**，UI 必须如实表现为"未核对"，
///    不得渲染为未勾选。
class FolderOwnershipScan {
  const FolderOwnershipScan({
    required this.containedFolderIds,
    required this.checkedFolderIds,
    required this.exhaustive,
    this.rateLimited = false,
    this.requestsUsed = 0,
    this.notes = const [],
  });

  /// 一次什么都没核对到的空结果（未登录、无夹、或首个请求就被限流）。
  const FolderOwnershipScan.empty()
      : containedFolderIds = const [],
        checkedFolderIds = const [],
        exhaustive = false,
        rateLimited = false,
        requestsUsed = 0,
        notes = const [];

  /// 已确认**包含**该视频的收藏夹 ID。
  final List<int> containedFolderIds;

  /// 已**完整核对**（翻到列表末尾）的收藏夹 ID。
  ///
  /// 命中的夹也在这里——它当然被核对过了。
  /// "已核对且不包含" = `checkedFolderIds - containedFolderIds`。
  final List<int> checkedFolderIds;

  /// 是否把所有夹都核对完了。
  ///
  /// false 表示**仍有夹没核对**（预算用尽或被限流中断）。
  /// 调用方此时不得声称"该视频只在这些夹里"。
  final bool exhaustive;

  /// 是否因平台限流（HTTP 412 / 业务码 `-70103112`）提前停止。
  ///
  /// 与"预算用尽"区分开：限流意味着**再等一会儿**可能扫得动，
  /// UI 可以给"重新核对"的入口；预算用尽则是设计上的上限。
  final bool rateLimited;

  /// 本次实际发出的请求数（含重试），用于成本可观测与调参。
  final int requestsUsed;

  /// 诊断说明（已脱敏，不含 Cookie）。
  final List<String> notes;

  /// 该夹是否已被完整核对过。
  bool isChecked(int folderId) => checkedFolderIds.contains(folderId);

  /// 该夹是否已确认包含该视频。
  bool contains(int folderId) => containedFolderIds.contains(folderId);

  /// 该夹的归属是否**未知**（没命中、也没核对完）。
  bool isUnknown(int folderId) => !isChecked(folderId);

  Map<String, Object?> toJson() => {
        'containedFolderIds': containedFolderIds,
        'checkedFolderIds': checkedFolderIds,
        'exhaustive': exhaustive,
        'rateLimited': rateLimited,
        'requestsUsed': requestsUsed,
        'notes': notes,
      };
}

/// 能把平台视频标识解析为数字 ID 的适配器。
///
/// # 为什么单独一个接口
///
/// 有些平台接口要的是**数字 ID**（B 站的 `aid`），而链接里带的是
/// 字母 ID（`bvid`）。解析需要额外一次请求，且只有部分平台有这个区分。
///
/// 做成独立接口而不是加到 [PlatformAdapter]：后者被 `implements` 时
/// 要求实现全部成员，加一个方法会让所有适配器（含测试用的）
/// 都要跟着改。
abstract class NumericVideoIdCapable {
  /// 解析数字视频 ID。平台没有该概念或解析失败时返回 null。
  Future<int?> resolveNumericVideoId(String platformVideoId);
}

/// 能列出「分集」的适配器（短剧 / 多 P 视频）。
///
/// 与 [PlatformAdapter] 分开：后者被 `implements` 时要求实现全部成员，
/// 加一个方法会连带改所有适配器与测试替身。理由同 [NumericVideoIdCapable]。
abstract class EpisodeListCapable {
  /// 用**当前这一集**的 `platformVideoId` 反查整部剧。
  ///
  /// 传入的可能是复合标识（如 `seriesId#7`），解析由适配器负责——
  /// 平台标识格式是适配器的知识，UI 不该知道。
  /// 没有分集概念或解析失败返回 null。
  Future<EpisodeListing?> listEpisodesFor(String platformVideoId);
}

/// 一次分集列举的结果。
class EpisodeListing {
  const EpisodeListing({
    required this.episodes,
    required this.currentIndex,
    required this.seriesTitle,
  });

  /// 全部分集，按集数升序。每项都有**自己**的 `platformVideoId`，
  /// 否则连播时进度会串线（见 `hongguo/playback_id.dart`）。
  final List<UnifiedVideo> episodes;

  /// 当前集在 [episodes] 里的下标（0 基）。找不到时为 0。
  final int currentIndex;

  /// 剧名（不含集数后缀），用于选集面板标题。
  final String seriesTitle;

  UnifiedVideo get current => episodes[currentIndex];

  /// 下一集；已是最后一集时返回 null。
  UnifiedVideo? get next =>
      currentIndex + 1 < episodes.length ? episodes[currentIndex + 1] : null;

  /// 上一集；已是第一集时返回 null。
  UnifiedVideo? get previous =>
      currentIndex > 0 ? episodes[currentIndex - 1] : null;

  int get total => episodes.length;
  bool get hasNext => next != null;
  bool get hasPrevious => previous != null;
}