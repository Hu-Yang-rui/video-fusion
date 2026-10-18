/// 互动 UI 组件：点赞按钮、投币弹层、评论面板。
///
/// 设计要点（短视频场景）：
///  - 按钮无底色，靠投影保证在任何画面上可读
///  - 状态变化有明确视觉反馈（实心/空心、颜色、缩放）
///  - 进行中显示进度，防止重复点击
///  - 未登录时点击给出登录引导，不静默失败
library;

import 'package:flutter/material.dart';

import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/interaction.dart';
import 'interaction_controller.dart';

/// 短视频右侧栏的互动按钮。
class InteractionRailButton extends StatelessWidget {
  const InteractionRailButton({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
    this.pending = false,
    this.activeColor = const Color(0xFFFF2D55),
    this.enabled = true,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;

  /// 是否处于"已激活"状态（已点赞/已收藏）。
  final bool active;

  final VoidCallback onTap;
  final bool pending;
  final Color activeColor;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled && !pending ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 状态切换动画：图标轻微放大再回落
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: active ? 1.12 : 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            builder: (context, scale, child) => Transform.scale(
              scale: pending ? 1 : scale,
              child: child,
            ),
            child: pending
                ? const SizedBox(
                    width: 34,
                    height: 34,
                    child: Padding(
                      padding: EdgeInsets.all(6),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                  )
                : Icon(
                    active ? activeIcon : icon,
                    size: 34,
                    color: active ? activeColor : Colors.white,
                    shadows: const [
                      Shadow(color: Color(0xB3000000), blurRadius: 8),
                      Shadow(color: Color(0x80000000), blurRadius: 3),
                    ],
                  ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              height: 1.2,
              shadows: [
                Shadow(color: Color(0xB3000000), blurRadius: 6),
                Shadow(color: Color(0x80000000), blurRadius: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 投币选择弹层（B 站特有：1 枚或 2 枚）。
class CoinSheet extends StatefulWidget {
  const CoinSheet({
    super.key,
    required this.controller,
    required this.coinBalance,
  });

  final InteractionController controller;

  /// 当前硬币余额（平台未提供时为 null，显示"未知"）。
  final int? coinBalance;

  @override
  State<CoinSheet> createState() => _CoinSheetState();
}

class _CoinSheetState extends State<CoinSheet> {
  int _count = 1;
  bool _alsoLike = false;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final alreadyCoined = widget.controller.state.coined;
    final remaining = 2 - alreadyCoined;

    return Container(
      decoration: BoxDecoration(
        color: c.secondaryGroupedBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppleRadius.sheet),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppleSpace.sm),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: c.separator,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppleSpace.lg),

            Text(
              remaining <= 0 ? '已经投过币了' : '投币支持',
              style: AppleType.title3.copyWith(color: c.label),
            ),
            const SizedBox(height: AppleSpace.xs),
            Text(
              remaining <= 0
                  ? '每个视频最多投 2 枚硬币'
                  : (widget.coinBalance != null
                      ? '当前硬币余额：${widget.coinBalance}'
                      : '每个视频最多投 2 枚硬币'),
              style: AppleType.footnote.copyWith(color: c.secondaryLabel),
            ),
            const SizedBox(height: AppleSpace.xl),

            if (remaining > 0) ...[
              // 数量选择
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpace.xxxl,
                ),
                child: Row(
                  children: [
                    for (var i = 1; i <= remaining; i++) ...[
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _count = i),
                          child: AnimatedContainer(
                            duration: AppleMotion.fast,
                            height: 64,
                            decoration: BoxDecoration(
                              color: _count == i
                                  ? c.blue.withValues(alpha: 0.12)
                                  : c.fill,
                              borderRadius:
                                  BorderRadius.circular(AppleRadius.sm),
                              border: Border.all(
                                color: _count == i ? c.blue : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.monetization_on_rounded,
                                  size: 24,
                                  color: _count == i
                                      ? c.orange
                                      : c.secondaryLabel,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$i 枚',
                                  style: AppleType.footnoteEmphasized.copyWith(
                                    color: _count == i ? c.blue : c.label,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (i < remaining) const SizedBox(width: AppleSpace.md),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppleSpace.lg),

              // 同时点赞
              AppleCheckRow(
                label: '同时点赞',
                value: _alsoLike,
                onChanged: (v) => setState(() => _alsoLike = v),
              ),
              const SizedBox(height: AppleSpace.lg),

              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpace.xxl,
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: AppleSize.minTapTarget,
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      await widget.controller.giveCoin(
                        count: _count,
                        alsoLike: _alsoLike,
                      );
                    },
                    child: Text('投 $_count 枚'),
                  ),
                ),
              ),
            ],

            const SizedBox(height: AppleSpace.lg),
          ],
        ),
      ),
    );
  }
}

/// 勾选行（Apple 风格）。
class AppleCheckRow extends StatelessWidget {
  const AppleCheckRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppleSpace.xxl),
        child: Row(
          children: [
            Icon(
              value
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 22,
              color: value ? c.blue : c.tertiaryLabel,
            ),
            const SizedBox(width: AppleSpace.sm),
            Text(
              label,
              style: AppleType.body.copyWith(color: c.label),
            ),
          ],
        ),
      ),
    );
  }
}

/// 评论面板（底部弹层，可滚动分页）。
class CommentSheet extends StatefulWidget {
  const CommentSheet({
    super.key,
    required this.controller,
  });

  final InteractionController controller;

  @override
  State<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<CommentSheet> {
  // 注意：这里**不**自建 ScrollController。
  //
  // DraggableScrollableSheet 要求内部的滚动组件使用它通过 builder
  // 传进来的 controller，否则拖拽与滚动的坐标是两套，会出现
  // "拖不动"、"滚到顶不接管" 之类的交互冲突。
  //
  // 之前这里用独立的 _scroll，既和 sheetScroll 打架，
  // 又额外注册了一个每像素触发的监听器。现在改为：
  //  - ListView 直接用 sheetScroll
  //  - 触底加载改由 NotificationListener<ScrollNotification> 驱动

  @override
  void initState() {
    super.initState();
    if (!widget.controller.commentsLoadedOnce) {
      widget.controller.loadComments();
    }
  }

  /// 触底加载。由滚动通知驱动，不再每帧轮询位置。
  bool _onScrollNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final remaining = n.metrics.maxScrollExtent - n.metrics.pixels;
    if (remaining < 400) {
      widget.controller.loadMoreComments();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, sheetScroll) {
        return Container(
          decoration: BoxDecoration(
            color: c.secondaryGroupedBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppleRadius.sheet),
            ),
          ),
          // 用 ListenableBuilder 把"数据变化"的重建范围限制在内容区，
          // 不再用 setState 重建整个 DraggableScrollableSheet。
          //
          // 之前 _onChanged 里 setState(() {}) 会在每次
          // notifyListeners（含加载更多、点赞状态刷新）时重建
          // sheet 几何 + 标题 + 整个列表，滚动中触发会明显掉帧。
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final ctrl = widget.controller;
              return Column(
                children: [
                  // 拖拽条 + 标题
                  const SizedBox(height: AppleSpace.sm),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.separator,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppleSpace.lg,
                      AppleSpace.md,
                      AppleSpace.sm,
                      AppleSpace.sm,
                    ),
                    child: Row(
                      children: [
                        Text(
                          ctrl.commentTotal > 0
                              ? '评论 ${_fmtCount(ctrl.commentTotal)}'
                              : '评论',
                          style: AppleType.title3.copyWith(color: c.label),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                            Icons.close_rounded,
                            color: c.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const AppleDivider(indent: 0),

                  // IP 属地缺失时给一句明确说明（面板级，不是每条评论）。
                  if (_ipLocationNotice(ctrl) != null)
                    _IpLocationNotice(text: _ipLocationNotice(ctrl)!),

                  Expanded(
                    child: _buildBody(c, ctrl, sheetScroll),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 属地缺失说明文案。可得时不返回内容（不占位、不空行）。
  ///
  /// 三种缺失原因分开表述：未登录是可以改变的状态，
  /// 已登录仍无则是平台限制——混为一谈会让用户反复登录却始终拿不到。
  static String? _ipLocationNotice(InteractionController ctrl) {
    return switch (ctrl.ipLocationAvailability) {
      IpLocationAvailability.unavailableAnonymous =>
        '评论 IP 属地暂不可用：未登录时平台不下发该字段。登录后可能可得。',
      IpLocationAvailability.unavailableLoggedIn =>
        '评论 IP 属地暂不可用：当前账号下平台未下发该字段。',
      IpLocationAvailability.available ||
      IpLocationAvailability.unknown =>
        null,
    };
  }

  Widget _buildBody(
    AppleColors c,
    InteractionController ctrl,
    ScrollController sheetScroll,
  ) {
    // 首次加载中
    if (ctrl.commentsLoading && ctrl.comments.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // 加载失败：明确报错 + 重试
    if (ctrl.commentsError != null && ctrl.comments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppleSpace.xxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: AppleSpace.md),
              Text(
                ctrl.commentsError!.presentation.title,
                style: AppleType.bodyEmphasized.copyWith(color: c.label),
              ),
              const SizedBox(height: AppleSpace.xs),
              Text(
                ctrl.commentsError!.userMessage,
                textAlign: TextAlign.center,
                style: AppleType.footnote.copyWith(color: c.secondaryLabel),
              ),
              const SizedBox(height: AppleSpace.lg),
              FilledButton(
                onPressed: () => ctrl.loadComments(refresh: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 空评论
    if (ctrl.comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 40,
              color: c.tertiaryLabel,
            ),
            const SizedBox(height: AppleSpace.md),
            Text(
              '还没有评论',
              style: AppleType.body.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      );
    }

    // 用 sheet 提供的 controller，保证拖拽与滚动是同一套坐标。
    final comments = ctrl.comments;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.separated(
        controller: sheetScroll,
        padding: const EdgeInsets.only(bottom: AppleSpace.xxxl),
        itemCount: comments.length + (ctrl.commentsHasMore ? 1 : 0),
        separatorBuilder: (_, _) => const AppleDivider(indent: 60),
        itemBuilder: (context, index) {
          if (index >= comments.length) {
            // 加载更多指示
            return Padding(
              padding: const EdgeInsets.all(AppleSpace.lg),
              child: Center(
                child: ctrl.commentsLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: ctrl.loadMoreComments,
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }
          final comment = comments[index];
          // 稳定的 Key：翻页追加时 Flutter 能复用已构建的 element，
          // 而不是按位置错配导致整屏重建。
          return _CommentTile(
            key: ValueKey<String>(comment.id),
            comment: comment,
          );
        },
      ),
    );
  }

  static String _fmtCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

/// 单条评论。
///
/// 性能说明（列表滚动的关键路径）：
///  - 头像用 [ResizeImage] 限制解码宽度。评论头像原图常见 200×200，
///    不限制的话每条评论解码后占 160KB，滚动时内存与解码开销叠加明显。
///    限制到 64px 后单条约 16KB。
///  - 头像首字母在构造时算一次，避免每帧调用 `characters.first`
///    （字形簇分析，比取首个 code unit 贵得多）。
class _CommentTile extends StatelessWidget {
  _CommentTile({super.key, required this.comment})
      : _avatarInitial = _initialOf(comment.authorName);

  final VideoComment comment;

  /// 昵称首字（构造时计算一次）。
  final String _avatarInitial;

  static String _initialOf(String name) {
    if (name.isEmpty) return '?';
    return name.characters.first;
  }

  /// 头像解码目标宽度（逻辑像素 32 → 按 2x 屏取 64）。
  static const int _avatarDecodeWidth = 64;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.lg,
        vertical: AppleSpace.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像
          CircleAvatar(
            radius: 16,
            backgroundColor: c.fill,
            backgroundImage: comment.authorAvatarUrl == null
                ? null
                : ResizeImage.resizeIfNeeded(
                    _avatarDecodeWidth,
                    _avatarDecodeWidth,
                    NetworkImage(
                      comment.authorAvatarUrl!,
                      headers: const {'Referer': 'https://www.bilibili.com/'},
                    ),
                  ),
            child: comment.authorAvatarUrl == null
                ? Text(
                    _avatarInitial,
                    style: AppleType.caption1.copyWith(color: c.secondaryLabel),
                  )
                : null,
          ),
          const SizedBox(width: AppleSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppleType.footnoteEmphasized.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                    ),
                    if (comment.isUpAuthor) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: c.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'UP',
                          style: AppleType.caption2.copyWith(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: c.blue,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                    if (comment.isPinned) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.push_pin_rounded,
                        size: 11,
                        color: c.orange,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  comment.message,
                  style: AppleType.footnote.copyWith(
                    color: c.label,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      _relativeTime(comment.createdAt),
                      style: AppleType.caption2.copyWith(
                        color: c.tertiaryLabel,
                      ),
                    ),
                    // IP 属地：与时间同权重，不额外加底色或徽标。
                    // 仅在平台确实返回时显示，缺失时整段不渲染。
                    if (comment.ipLocation != null) ...[
                      const SizedBox(width: AppleSpace.sm),
                      Text(
                        comment.ipLocation!,
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ],
                    if (comment.likeCount != null && comment.likeCount! > 0) ...[
                      const SizedBox(width: AppleSpace.md),
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 11,
                        color: c.tertiaryLabel,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${comment.likeCount}',
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ],
                    if (comment.replyCount != null &&
                        comment.replyCount! > 0) ...[
                      const SizedBox(width: AppleSpace.md),
                      Text(
                        '${comment.replyCount} 条回复',
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _relativeTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inDays > 365) return '${diff.inDays ~/ 365} 年前';
    if (diff.inDays > 30) return '${diff.inDays ~/ 30} 个月前';
    if (diff.inDays > 0) return '${diff.inDays} 天前';
    if (diff.inHours > 0) return '${diff.inHours} 小时前';
    if (diff.inMinutes > 0) return '${diff.inMinutes} 分钟前';
    return '刚刚';
  }
}

/// 评论面板顶部的属地缺失说明条。
///
/// 刻意做得轻：一行小字 + 信息图标，不占卡片、不加重底色。
/// 它的作用是"如实告知"，不是提醒用户去做什么。
class _IpLocationNotice extends StatelessWidget {
  const _IpLocationNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpace.lg,
        AppleSpace.sm,
        AppleSpace.lg,
        AppleSpace.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(
              Icons.info_outline_rounded,
              size: 13,
              color: c.tertiaryLabel,
            ),
          ),
          const SizedBox(width: AppleSpace.xs),
          Expanded(
            child: Text(
              text,
              style: AppleType.caption2.copyWith(
                color: c.tertiaryLabel,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}