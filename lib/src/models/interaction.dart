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
  });

  /// 未登录 / 未查询时的初始状态。
  static const InteractionState unknown = InteractionState();

  /// 是否已从平台拿到真实状态。
  final bool known;

  final bool liked;

  /// 已投币数（0–2）。
  final int coined;

  final bool favorited;

  /// 平台计数（用于展示，不本地累加）。
  final int? likeCount;
  final int? coinCount;
  final int? favoriteCount;
  final int? commentCount;

  InteractionState copyWith({
    bool? known,
    bool? liked,
    int? coined,
    bool? favorited,
    int? likeCount,
    int? coinCount,
    int? favoriteCount,
    int? commentCount,
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
      );
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
  });

  final bool accepted;
  final String? message;
  final Object? upstreamCode;
}
