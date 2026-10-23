/// 互动功能的数据契约（平台无关）。
///
/// 覆盖：评论、点赞状态、投币、收藏。
///
/// 设计约束：
///  - **写操作必须登录**。未登录时明确抛 `loginRequired`，不得静默失败。
///  - 读操作（评论列表）在多数平台是公开的，登录后能读到更多。
///  - 计数以平台返回为准，本地不乐观累加——避免"点了但没生效"的假象。
///  - 所有失败都归一化为 [FusionException]，UI 只需按错误码分支。
library;

/// 一条评论。
class VideoComment {
  const VideoComment({
    required this.id,
    required this.authorName,
    required this.message,
    required this.createdAt,
    this.authorAvatarUrl,
    this.authorId,
    this.likeCount,
    this.replyCount,
    this.isUpAuthor = false,
    this.isPinned = false,
    this.floor,
    this.ipLocation,
    this.isLikedByMe = false,
    this.rootCommentId,
    this.parentCommentId,
    this.isSubComment = false,
    this.replyLevel,
  });

  /// 平台评论 ID。
  final String id;

  final String authorName;
  final String? authorAvatarUrl;
  final String? authorId;

  /// 评论正文（纯文本，已剥离平台的高亮标记）。
  final String message;

  /// 发布时间（ISO 8601）。
  final String createdAt;

  final int? likeCount;
  final int? replyCount;

  /// 是否为视频作者本人的评论。
  final bool isUpAuthor;

  /// 是否置顶。
  final bool isPinned;

  /// 楼层号。
  final int? floor;

  /// 平台公示的 IP 属地（如「广东」「日本」）。
  ///
  /// **只承载平台明确返回的值，绝不由客户端推断。**
  ///  - B 站：`reply_control.location`，格式为「IP属地：广东」，
  ///    适配器会剥离前缀。**实测该字段仅在登录态返回**，
  ///    未登录请求的响应里完全没有此字段。
  ///  - 抖音：评论接口未返回任何地区信息（已核实），恒为 null。
  ///
  /// 为 null 时 UI 不显示任何地区文字，不得用昵称/头像/网络位置猜测。
  final String? ipLocation;

  /// **当前登录用户**是否点赞过这条评论。
  ///
  /// 只承载平台明确下发的值，**绝不本地推断**：
  ///  - B 站：`up_action.like`（登录态才下发，实测语义为"我点赞过"）
  ///  - 抖音：`comment/digg` 无登录时不下发，恒 false
  ///
  /// 未登录时该字段没有意义，UI 在未登录时不渲染点亮状态，
  /// 而不是渲染成"未点赞"。
  final bool isLikedByMe;

  /// 所属**根评论** id（楼中楼归属的一级评论）。
  ///
  /// 顶层评论为 null。二级评论用它在平台接口里定位（B站 `root`、
  /// 抖音 `reply_id`）。来源是平台响应字段，不本地推断。
  final String? rootCommentId;

  /// 被回复的**那条**评论 id（可能是二级评论本身）。
  ///
  /// 抖音回复二级评论时要 `reply_to_reply_id` = 该值；
  /// B站回复二级评论时 `parent` = 该值、`root` = [rootCommentId]。
  /// 顶层评论为 null。
  final String? parentCommentId;

  /// 是否是二级评论（楼中楼里的一条）。
  ///
  /// 决定回复时的参数形态：回复顶层只带 root，回复二级要带
  /// root + parent 两个（B站实测只带一个会 -400 参数错误）。
  final bool isSubComment;

  /// 平台下发的评论层级（抖音 `level`）。
  ///
  /// 抖音的评论点赞 `comment/digg` 要回传**被点赞评论自己的 level**
  /// （bundle s86.js 的调用点直接解构 `level:r` 原样转发）。
  /// 只承载平台下发的值；B站没有这个概念时为 null。
  final int? replyLevel;

  /// 返回带新点赞状态的副本（评论是不可变值对象，写后回显用）。
  VideoComment copyWith({
    bool? isLikedByMe,
    int? likeCount,
    int? replyCount,
  }) =>
      VideoComment(
        id: id,
        authorName: authorName,
        authorAvatarUrl: authorAvatarUrl,
        authorId: authorId,
        message: message,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        replyCount: replyCount ?? this.replyCount,
        isUpAuthor: isUpAuthor,
        isPinned: isPinned,
        floor: floor,
        ipLocation: ipLocation,
        isLikedByMe: isLikedByMe ?? this.isLikedByMe,
        rootCommentId: rootCommentId,
        parentCommentId: parentCommentId,
        isSubComment: isSubComment,
        replyLevel: replyLevel,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'authorName': authorName,
        'authorAvatarUrl': authorAvatarUrl,
        'authorId': authorId,
        'message': message,
        'createdAt': createdAt,
        'likeCount': likeCount,
        'replyCount': replyCount,
        'isUpAuthor': isUpAuthor,
        'isPinned': isPinned,
        'floor': floor,
        'ipLocation': ipLocation,
        'isLikedByMe': isLikedByMe,
        'rootCommentId': rootCommentId,
        'parentCommentId': parentCommentId,
        'isSubComment': isSubComment,
        'replyLevel': replyLevel,
      };
}

/// 一页评论。
class CommentPage {
  const CommentPage({
    required this.items,
    required this.page,
    required this.totalCount,
    required this.hasMore,
    this.nextCursor = 0,
    this.upTopComment,
    this.notes = const [],
  });

  final List<VideoComment> items;

  /// 当前页码（从 1 开始）。
  final int page;

  /// 评论总数（平台口径）。
  final int totalCount;

  final bool hasMore;

  /// 下一页游标。
  ///
  /// B 站评论使用游标分页（`/x/v2/reply/main?next=N`），
  /// 无法随机访问第 N 页。适配器把游标原样带回，
  /// 调用方应把它作为下一次请求的 `page` 传入。
  /// 无游标分页的平台保持 0。
  final int nextCursor;

  /// 置顶的 UP 主评论（平台单独返回）。
  final VideoComment? upTopComment;

  final List<String> notes;

  bool get isEmpty => items.isEmpty;
}

/// 互动状态（当前用户对该视频的操作状态）。
///
/// 未登录时 [known] 为 false，UI 应显示"登录后可操作"而不是显示"未点赞"。
class InteractionState {
  const InteractionState({
    this.known = false,
    this.liked = false,
    this.coined = 0,
    this.favorited = false,
    this.likeCount,
    this.coinCount,
    this.favoriteCount,
    this.commentCount,
    this.favoritedFolderIds = const [],
    this.following = false,
    this.watchLater = false,
  });

  /// 未登录 / 未查询时的初始状态。
  ///
  /// 注意：`unknown` 的 [known] 为 false，此时 [following]、[watchLater]、
  /// [favoritedFolderIds] 等字段的默认值**只表示"不知道"**，
  /// 调用方不得把它们当"未关注 / 不在稍后再看 / 未收藏"展示给用户。
  static const InteractionState unknown = InteractionState();

  /// 是否已从平台拿到真实状态。
  final bool known;

  final bool liked;

  /// 已投币数（0–2）。
  final int coined;

  final bool favorited;

  /// 平台计数（用于展示，不本地累加）。
  ///
  /// # 来源约束
  ///
  /// 这些字段**不属于**互动关系接口。B 站 `archive/relation` 只返回
  /// 当前用户的关系布尔值，**不返回任何计数**（实测 2026-10-19：
  /// `like` / `favorite` 是 bool，`coin` 是 0–2 的次数）。
  /// 计数的唯一权威来源是 `/x/web-interface/view` 的 `data.stat`，
  /// 已由适配器映射到 `UnifiedVideo.stats`（VideoStats）。
  ///
  /// 因此 PlatformAdapter 的 `fetchInteractionState` 一律把这三个字段留空
  /// （null），UI 侧按 `state.likeCount ?? video.stats.likeCount` 回退。
  /// 保留字段而不删除，是为了让能一次性给出计数的平台有处可填；
  /// **绝不允许由客户端本地累加**。
  final int? likeCount;

  /// 该平台口径的投币总数（多数平台不返回，为 null）。
  ///
  /// 与 [coined]（当前用户在本视频投了几枚，0–2）是两回事。
  final int? coinCount;
  final int? favoriteCount;
  final int? commentCount;

  /// 该视频当前所在的收藏夹 ID 列表。
  ///
  /// # 为什么需要它
  ///
  /// 一个视频可以同时存在于多个收藏夹。只用一个 `favorited` 布尔值
  /// 无法表达"收藏在哪个夹"，也无法在收藏夹选择界面里正确回显勾选状态。
  ///
  /// 空列表表示**没有收藏到任何收藏夹**（此时 [favorited] 必为 false）。
  /// 平台接口不提供该信息时为空列表，UI 据此退化为"只知道是否收藏过"。
  final List<int> favoritedFolderIds;

  /// 是否已关注该视频的 UP 主。
  ///
  /// 来源字段（实测 2026-10-19）：
  ///  - B 站：`/x/web-interface/archive/relation` 的 `data.attention`（bool）。
  ///    该键**实测存在**，与 `favorite`/`like` 同批返回，因此关注状态
  ///    不需要额外请求。
  ///
  /// 仅在 [known] 为 true 时有意义；[InteractionState.unknown] 里它是
  /// false，**表示"不知道"**，UI 不得据此渲染成"未关注"。
  final bool following;

  /// 该视频是否已在"稍后再看"列表里。
  ///
  /// 来源字段：B 站 `/x/v2/history/toview/web` 的 `data.list[].aid`
  /// 比对结果（存在性判断，非计数）。
  ///
  /// 同样仅在 [known] 为 true 时有意义；false 在 unknown 态表示"不知道"。
  final bool watchLater;

  /// 是否收藏到了指定收藏夹。
  bool inFolder(int folderId) => favoritedFolderIds.contains(folderId);

  InteractionState copyWith({
    bool? known,
    bool? liked,
    int? coined,
    bool? favorited,
    int? likeCount,
    int? coinCount,
    int? favoriteCount,
    int? commentCount,
    List<int>? favoritedFolderIds,
    bool? following,
    bool? watchLater,
  }) =>
      InteractionState(
        known: known ?? this.known,
        liked: liked ?? this.liked,
        coined: coined ?? this.coined,
        favorited: favorited ?? this.favorited,
        likeCount: likeCount ?? this.likeCount,
        coinCount: coinCount ?? this.coinCount,
        favoriteCount: favoriteCount ?? this.favoriteCount,
        commentCount: commentCount ?? this.commentCount,
        favoritedFolderIds:
            favoritedFolderIds ?? this.favoritedFolderIds,
        following: following ?? this.following,
        watchLater: watchLater ?? this.watchLater,
      );
}

/// 平台风控拦截的细节。
///
/// # 为什么单独建模而不是塞进错误文案
///
/// 风控拦截和普通失败的区别在于**用户能做什么**：
///  - 余额不足 → 攒够再来
///  - 参数错误 → 修代码
///  - 风控要求人机验证 → **去网页端做一次验证**，重试无用
///
/// 如果把三者揉成"操作失败"，用户只会反复点重试然后被拦得更狠。
/// 因此把平台给的判据（要哪级验证码、哪个场景触发）如实带出来。
///
/// # 实测样本（B站 `coin/add`，2026-10-19）
///
/// ```json
/// {"code":-401,"message":"非法访问",
///  "data":{"ga_data":{
///    "decisions":["verify_captcha_level3"],
///    "risk_level":1,
///    "decision_ctx":{"scene":"video_coin",
///                    "verify_exempt_by_decision":"1",
///                    "v_voucher":"voucher_...",
///                    "grisk_id":"..."}}}}
/// ```
class PlatformRiskControl {
  const PlatformRiskControl({
    required this.decisions,
    this.riskLevel,
    this.scene,
    this.exemptByDecision = false,
  });

  /// 平台要求做的事，例如 `verify_captcha_level3`（三级验证码）。
  final List<String> decisions;

  /// 风险等级（平台口径，数字越小越低）。
  final int? riskLevel;

  /// 触发场景，例如 `video_coin` / `video_like`。
  final String? scene;

  /// 该账号是否本身在白名单里（只是本次临时被拦）。
  ///
  /// 为 true 时"过一会儿再试"可能就过了；为 false 说明是硬拦截。
  final bool exemptByDecision;

  /// 是否需要人机验证。
  bool get requiresCaptcha =>
      decisions.any((d) => d.contains('captcha') || d.contains('verify'));

  /// 面向用户的一句话说明。
  String get userHint {
    if (requiresCaptcha) {
      return '平台要求完成人机验证后才能继续，请到网页端操作一次再回来。';
    }
    if (exemptByDecision) {
      return '本次操作被平台临时拦截，请稍后重试。';
    }
    return '平台风控拦截了本次操作。';
  }

  /// 脱敏摘要（**不含** `v_voucher` / `grisk_id` 这类一次性凭据）。
  Map<String, Object?> get safeSummary => {
        'decisions': decisions,
        if (riskLevel != null) 'riskLevel': riskLevel,
        if (scene != null) 'scene': scene,
        'exemptByDecision': exemptByDecision,
      };

  Map<String, Object?> toJson() => safeSummary;
}

/// 一次互动写操作的结果。
///
/// 平台返回的是"操作是否被接受"，而不是新的计数。
/// 因此调用方应在成功后**重新拉取**互动状态，而不是本地 +1。
class InteractionResult {
  const InteractionResult({
    required this.accepted,
    this.message,
    this.upstreamCode,
    this.riskControl,
  });

  final bool accepted;
  final String? message;
  final Object? upstreamCode;

  /// 被风控拦截时的细节（未拦截为 null）。
  ///
  /// UI 据此区分"去验证一下就能过"与"这个操作本身不行"。
  final PlatformRiskControl? riskControl;
}

/// 一键三连里单项的结果。
class TripleActionStep {
  const TripleActionStep({
    required this.name,
    required this.ok,
    this.message,
    this.upstreamCode,
  });

  /// 步骤名（`like` / `coin` / `favorite`）。
  final String name;

  final bool ok;

  /// 失败原因（成功时为 null）。
  final String? message;

  /// 平台原始业务码。
  final Object? upstreamCode;

  Map<String, Object?> toJson() => {
        'name': name,
        'ok': ok,
        if (message != null) 'message': message,
        if (upstreamCode != null) 'upstreamCode': upstreamCode,
      };
}

/// 一键三连的结果。
///
/// # 为什么不是单个布尔
///
/// 三连是**三个独立请求**，任何一项都可能单独失败，而且失败原因不同：
///
///  - 点赞：一般不会被拦
///  - 投币：可能被风控（实测 B站返回 `-401 非法访问` +
///    `verify_captcha_level3`）或余额不足（`-104`）
///  - 收藏：没带 `add_media_ids` 会返回 `2001000 参数错误`
///
/// 如果只回一个 `accepted`，用户看到"三连成功"但硬币没投上，
/// 那就是谎报。因此这里逐项给出结果。
class TripleActionResult {
  const TripleActionResult({required this.steps});

  final List<TripleActionStep> steps;

  /// 三项是否**全部**成功。
  bool get allOk => steps.isNotEmpty && steps.every((s) => s.ok);

  /// 至少一项成功。
  bool get anyOk => steps.any((s) => s.ok);

  /// 失败的步骤。
  List<TripleActionStep> get failed =>
      steps.where((s) => !s.ok).toList(growable: false);

  /// 按名字取一步的结果。
  TripleActionStep? stepOf(String name) {
    for (final s in steps) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 面向用户的一句话总结。
  ///
  /// 全成功说"已三连"；部分成功要说清哪几项没成，**不能笼统说成功**。
  String get summary {
    if (steps.isEmpty) return '三连未执行。';
    if (allOk) return '已三连（点赞 · 投币 · 收藏）。';

    final okNames = steps.where((s) => s.ok).map(_label).toList();
    final failNames = failed.map(_label).toList();
    if (okNames.isEmpty) {
      return '三连失败：${failed.map((s) => '${_label(s)}（${s.message ?? '未知原因'}）').join('；')}';
    }
    return '部分成功：已完成${okNames.join('、')}；'
        '未完成${failNames.map((n) => n).join('、')}'
        '（${failed.map((s) => s.message ?? '未知原因').join('；')}）';
  }

  static String _label(TripleActionStep s) => switch (s.name) {
        'like' => '点赞',
        'coin' => '投币',
        'favorite' => '收藏',
        _ => s.name,
      };

  Map<String, Object?> toJson() => {
        'allOk': allOk,
        'anyOk': anyOk,
        'summary': summary,
        'steps': steps.map((s) => s.toJson()).toList(),
      };
}
