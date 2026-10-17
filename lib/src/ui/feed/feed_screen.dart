/// 推荐页：全屏竖滑短视频流（沉浸式）。
///
/// 交互：
///  - 上滑/下滑切换视频
///  - 单击暂停/继续
///  - 双击快速点赞位（本阶段不实现点赞，保留手势位置）
///  - 顶部：内容来源切换、登录状态
///  - 右侧：平台标识、原平台入口、更多
///  - 底部：作者、标题、统计、进度条
///
/// 与旧版的主要差异：
///  - 视觉改为 Apple 风格（更克制的字号层级、更细的分隔、系统蓝色强调）
///  - 控制条改为可拖拽进度条 + 倍速/清晰度菜单（仅在实际支持时显示）
///  - 增加"长视频"角标与时长显示
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/video_widgets.dart';
import '../../models/feed.dart';
import '../../models/unified_video.dart';
import '../../player/player_controller.dart';
import '../interaction/interaction_controller.dart';
import '../interaction/interaction_widgets.dart';
import '../mobile/feed_controller.dart';

/// 让深层子组件（进度条）拿到控制器而不必层层传参。
///
/// 只暴露控制器本身，不触发 InheritedWidget 的依赖重建，
/// 因为控制器实例在页面生命周期内不变。
class FeedScreenScope extends InheritedWidget {
  const FeedScreenScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final FeedController controller;

  static FeedController? of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<FeedScreenScope>();
    return scope?.controller;
  }

  @override
  bool updateShouldNotify(FeedScreenScope oldWidget) =>
      controller != oldWidget.controller;
}

/// 推荐页（竖滑视频流）。
class FeedScreen extends StatefulWidget {
  const FeedScreen({
    super.key,
    required this.controller,
    required this.service,
    required this.vault,
    required this.onOpenSourcePicker,
    required this.onOpenLogin,
    required this.onOpenOriginal,
    required this.onOpenLinkIntake,
    this.loggedInLabel,
    this.onOpenDetail,
  });

  final FeedController controller;

  /// 互动功能所需的服务与凭证。
  final VideoService service;
  final CredentialVault vault;

  final VoidCallback onOpenSourcePicker;
  final VoidCallback onOpenLogin;
  final void Function(UnifiedVideo) onOpenOriginal;
  final VoidCallback onOpenLinkIntake;
  final String? loggedInLabel;

  /// 打开长视频详情页（用于时长较长的内容）。
  final void Function(UnifiedVideo)? onOpenDetail;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late final PageController _pageController;
  VideoController? _videoController;
  bool _showUi = true;
  Timer? _hideTimer;

  /// 按视频 ID 缓存互动控制器，避免滑动回来时状态丢失。
  final Map<String, InteractionController> _interactions = {};

  /// 取（或创建）某个视频的互动控制器。
  InteractionController _interactionFor(UnifiedVideo video) {
    final existing = _interactions[video.id];
    if (existing != null) return existing;

    final ctrl = InteractionController(
      video: video,
      service: widget.service,
      vault: widget.vault,
    );
    _interactions[video.id] = ctrl;
    // 异步初始化登录态与互动状态，不阻塞渲染
    ctrl.init();
    ctrl.addListener(_onInteractionChanged);
    return ctrl;
  }

  void _onInteractionChanged() {
    if (!mounted) return;
    setState(() {});
    // 一次性提示（登录引导 / 操作结果）
    final msg = _interactions.values
        .map((c) => c.lastMessage)
        .whereType<String>()
        .firstOrNull;
    if (msg != null) {
      final source =
          _interactions.values.firstWhere((c) => c.lastMessage == msg);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
      source.clearMessage();
    }
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    widget.controller.initPlayer();
    _attachVideoController();
    _subscribeSnapshot();
    widget.controller.addListener(_onControllerChanged);
    _scheduleHide();
  }

  void _attachVideoController() {
    final player = widget.controller.player;
    if (player == null) return;
    _videoController = VideoController(
      player.rawPlayer,
      configuration: player.videoConfiguration,
    );
    setState(() {});
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 订阅播放快照的流（只更新进度条，不重建页面）。
  StreamSubscription<PlayerSnapshot>? _snapSub;
  PlayerSnapshot _snap = PlayerSnapshot.initial;

  void _subscribeSnapshot() {
    _snapSub?.cancel();
    _snap = widget.controller.snapshot;
    _snapSub = widget.controller.snapshotStream.listen((s) {
      if (!mounted) return;
      setState(() => _snap = s);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    for (final c in _interactions.values) {
      c.removeListener(_onInteractionChanged);
      c.dispose();
    }
    _interactions.clear();
    _snapSub?.cancel();
    _hideTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && widget.controller.snapshot.phase == PlayerPhase.playing) {
        setState(() => _showUi = false);
      }
    });
  }

  /// 单击画面：切换播放/暂停，并让控制层可见。
  ///
  /// 之前这里只调 [_toggleUi]（显隐控制层），所以单击画面**不会**
  /// 暂停播放——这正是"单击无法暂停/恢复"的根因。
  ///
  /// 现在的行为对齐主流短视频应用：
  ///  - 单击播放中 → 暂停，同时显示控制层（让用户看到暂停状态）
  ///  - 单击已暂停 → 恢复播放，并重新安排自动隐藏
  ///  - 双击仍然只做触觉反馈（在 _FeedStage 里处理），
  ///    与单击不冲突：Flutter 的 GestureDetector 在有 onDoubleTap 时
  ///    会把单击延后约 300ms 再触发，保证不会误判。
  ///
  /// 只有当前屏处于可播放状态时才切换，加载中/失败态不响应，
  /// 避免在解析过程中把状态搅乱。
  void _onStageTap() {
    final c = widget.controller;

    // 以**播放器的实际状态**为准，而不是快照里的 phase。
    //
    // 快照的 phase 来自 media_kit 的事件流，暂停/恢复与事件到达之间
    // 有几十毫秒延迟。若用快照判断，连续两次点击会读到同一个旧
    // phase，导致第二次点击被判定为"不可切换"而不响应——
    // 表现为"暂停后点不回来"。
    //
    // 只有确实有媒体在播时才切换，加载中/失败态不响应，
    // 避免在解析过程中把状态搅乱。
    if (!c.canTogglePlay) {
      _toggleUi();
      return;
    }

    c.togglePlay();
    setState(() => _showUi = true);
    _scheduleHide();
  }

  void _toggleUi() {
    setState(() => _showUi = !_showUi);
    if (_showUi) _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return FeedScreenScope(
      controller: c,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
          // ── 视频流主体 ─────────────────────────────────
          if (c.initialLoading && c.length == 0)
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white54,
                ),
              ),
            )
          else if (c.feedError != null && c.length == 0)
            _FeedErrorView(
              error: c.feedError!,
              onRetry: c.retryInitial,
              onSwitchSource: widget.onOpenSourcePicker,
            )
          else if (c.length == 0)
            _FeedEmptyView(onSwitchSource: widget.onOpenSourcePicker)
          else
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: c.length,
              onPageChanged: (index) {
                c.setCurrentIndex(index);
                c.playIndex(index);
                _scheduleHide();
              },
              itemBuilder: (context, index) => _FeedStage(
                video: c.items[index],
                index: index,
                isActive: index == c.currentIndex,
                state: c.stateOf(index),
                error: c.errorOf(index),
                videoController: _videoController,
                // 只传"是否在缓冲"这一低频布尔，不传完整快照，
                // 避免位置更新导致整个 PageView 子树重建。
                isBuffering: _snap.isBuffering,
                isPaused: _snap.phase == PlayerPhase.paused,
                interaction: _interactionFor(c.items[index]),
                onRetry: c.retryCurrent,
                onTogglePlay: c.togglePlay,
                onOpenOriginal: () => widget.onOpenOriginal(c.items[index]),
                onOpenLogin: widget.onOpenLogin,
                onOpenDetail: widget.onOpenDetail == null
                    ? null
                    : () => widget.onOpenDetail!(c.items[index]),
                onTap: _onStageTap,
              ),
            ),

          // ── 顶部栏 ─────────────────────────────────────
          AnimatedOpacity(
            opacity: _showUi ? 1 : 0,
            duration: AppleMotion.fast,
            child: IgnorePointer(
              ignoring: !_showUi,
              child: _TopBar(
                sources: c.source,
                loggedInLabel: widget.loggedInLabel,
                onOpenSourcePicker: widget.onOpenSourcePicker,
                onOpenLogin: widget.onOpenLogin,
                onOpenLinkIntake: widget.onOpenLinkIntake,
              ),
            ),
          ),

          // ── 分页加载指示 ────────────────────────────────
          if (c.loadingMore && c.length > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 120,
              child: Center(
                child: Container(
                  width: 20,
                  height: 20,
                  padding: const EdgeInsets.all(4),
                  child: const CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white38,
                  ),
                ),
              ),
            ),

          // ── 分页错误提示 ────────────────────────────────
          if (c.appendError != null)
            Positioned(
              left: AppleSpace.lg,
              right: AppleSpace.lg,
              bottom: 100,
              child: _AppendErrorBar(
                message: c.appendError!.userMessage,
                onRetry: c.loadMore,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单屏舞台。
class _FeedStage extends StatelessWidget {
  const _FeedStage({
    required this.video,
    required this.index,
    required this.isActive,
    required this.state,
    required this.error,
    required this.videoController,
    required this.isBuffering,
    required this.isPaused,
    required this.interaction,
    required this.onRetry,
    required this.onTogglePlay,
    required this.onOpenOriginal,
    required this.onOpenLogin,
    required this.onTap,
    this.onOpenDetail,
  });

  final UnifiedVideo video;
  final int index;
  final bool isActive;
  final FeedItemState state;
  final FusionException? error;
  final VideoController? videoController;

  /// 是否正在缓冲（低频布尔，不随播放位置变化）。
  final bool isBuffering;

  /// 是否处于暂停态（低频布尔）。
  final bool isPaused;

  /// 该视频的互动控制器（点赞/评论/投币/收藏）。
  final InteractionController interaction;
  final VoidCallback onRetry;
  final VoidCallback onOpenLogin;
  final VoidCallback onTogglePlay;
  final VoidCallback onOpenOriginal;
  final VoidCallback? onOpenDetail;
  final VoidCallback onTap;

  bool get _isLong => (video.durationSeconds ?? 0) >= 600;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: () {
        // 双击：短视频惯例是点赞。本版本未接入点赞写入，
        // 因此只给触觉反馈，不伪造"已点赞"的视觉状态。
        HapticFeedback.mediumImpact();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 画面 ────────────────────────────────────────
          // 短视频场景必须铺满全屏：竖版视频用 cover 裁切填充，
          // 横版视频用 contain 保留完整画面。
          //
          // 性能关键：只有**当前屏**才挂载 Video widget。
          // 非活跃屏挂 Video 会让 media_kit 持续把纹理合成到不可见层，
          // 是卡顿的主要来源之一（每屏一个纹理上传）。
          if (state == FeedItemState.ready &&
              videoController != null &&
              isActive)
            Positioned.fill(
              child: Video(
                controller: videoController!,
                controls: NoVideoControls,
                fit: video.isPortrait ? BoxFit.cover : BoxFit.contain,
              ),
            )
          else if (state == FeedItemState.ready && !isActive)
            // 非活跃屏只显示封面，不做视频合成
            _LoadingStage(video: video)
          else if (state == FeedItemState.failed)
            _FailedStage(
              error: error,
              onRetry: onRetry,
              onOpenOriginal: onOpenOriginal,
            )
          else if (state == FeedItemState.externalOnly)
            _ExternalStage(
              video: video,
              onOpenOriginal: onOpenOriginal,
            )
          else
            _LoadingStage(video: video),

          // ── 底部渐变遮罩（保证文字可读）──────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 280,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── 底部信息 ────────────────────────────────────
          Positioned(
            left: AppleSpace.lg,
            right: 76,
            bottom: MediaQuery.paddingOf(context).bottom + 28,
            child: _VideoInfoPanel(
              video: video,
              isLong: _isLong,
              onOpenDetail: onOpenDetail,
            ),
          ),

          // ── 右侧操作栏 ──────────────────────────────────
          Positioned(
            right: AppleSpace.sm,
            bottom: MediaQuery.paddingOf(context).bottom + 40,
            child: _ActionRail(
              video: video,
              onOpenOriginal: onOpenOriginal,
              interaction: interaction,
              onOpenLogin: onOpenLogin,
            ),
          ),

          // ── 播放器控制条 ────────────────────────────────
          if (state == FeedItemState.ready && isActive)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _MiniProgress(
                isActive: isActive,
                onTogglePlay: onTogglePlay,
              ),
            ),

          // ── 缓冲指示 ────────────────────────────────────
          if (state == FeedItemState.ready && isBuffering)
            const Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white70,
                ),
              ),
            ),

          // ── 暂停指示（短视频必备视觉反馈）────────────────
          if (state == FeedItemState.ready &&
              !isBuffering &&
              isPaused &&
              isActive)
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  size: 44,
                  color: Colors.white70,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 顶部悬浮栏。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.sources,
    required this.loggedInLabel,
    required this.onOpenSourcePicker,
    required this.onOpenLogin,
    required this.onOpenLinkIntake,
  });

  final FeedSource? sources;
  final String? loggedInLabel;
  final VoidCallback onOpenSourcePicker;
  final VoidCallback onOpenLogin;
  final VoidCallback onOpenLinkIntake;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      padding: EdgeInsets.only(
        top: top + AppleSpace.sm,
        left: AppleSpace.lg,
        right: AppleSpace.lg,
        bottom: AppleSpace.lg,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          // 内容来源
          _GlassButton(
            label: sources?.label ?? '推荐',
            icon: Icons.expand_more_rounded,
            onTap: onOpenSourcePicker,
          ),
          const Spacer(),
          // 链接接入
          _GlassIconButton(
            icon: Icons.add_link_rounded,
            onTap: onOpenLinkIntake,
          ),
          const SizedBox(width: AppleSpace.sm),
          // 账号
          _GlassIconButton(
            icon: loggedInLabel == null
                ? Icons.person_outline_rounded
                : Icons.person_rounded,
            onTap: onOpenLogin,
            highlighted: loggedInLabel != null,
          ),
        ],
      ),
    );
  }
}

/// 毛玻璃按钮。
class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 8, top: 7, bottom: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppleRadius.pill),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppleType.footnoteEmphasized.copyWith(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
            Icon(icon, size: 16, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

/// 毛玻璃图标按钮。
class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: highlighted
              ? Colors.white.withValues(alpha: 0.28)
              : Colors.white.withValues(alpha: 0.16),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }
}

/// 底部视频信息。
class _VideoInfoPanel extends StatelessWidget {
  const _VideoInfoPanel({
    required this.video,
    required this.isLong,
    this.onOpenDetail,
  });

  final UnifiedVideo video;
  final bool isLong;
  final VoidCallback? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 作者（短视频惯例：@昵称，白色加粗，带投影）
        Row(
          children: [
            Flexible(
              child: Text(
                '@${video.author.name ?? '未知作者'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.2,
                  shadows: [
                    Shadow(color: Color(0xB3000000), blurRadius: 8),
                    Shadow(color: Color(0x80000000), blurRadius: 3),
                  ],
                ),
              ),
            ),
            if (isLong && onOpenDetail != null) ...[
              const SizedBox(width: AppleSpace.sm),
              GestureDetector(
                onTap: onOpenDetail,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(AppleRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text(
                        '详情',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          height: 1.2,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        // 标题（最多 2 行，短视频标准）
        Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w400,
            color: Colors.white,
            height: 1.4,
            shadows: [
              Shadow(color: Color(0xB3000000), blurRadius: 8),
              Shadow(color: Color(0x80000000), blurRadius: 3),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 元信息行：平台标 + 播放量 + 时长
        Row(
          children: [
            PlatformChip(
              platformId: video.platformId,
              compact: false,
              onDark: true,
            ),
            if (video.stats.viewCount != null) ...[
              const SizedBox(width: AppleSpace.sm),
              _MetaText('${_fmtCount(video.stats.viewCount!)}次播放'),
            ],
            if (video.durationLabel != null) ...[
              const SizedBox(width: AppleSpace.sm),
              _MetaText(video.durationLabel!),
            ],
          ],
        ),
      ],
    );
  }

  static String _fmtCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppleType.caption1.copyWith(
        color: Colors.white.withValues(alpha: 0.75),
        fontSize: 11.5,
        shadows: const [
          Shadow(color: Color(0x99000000), blurRadius: 4),
        ],
      ),
    );
  }
}

/// 右侧操作栏。
///
/// 接入真实的互动控制器：点赞/投币/收藏/评论全部走平台接口。
/// 未登录时点击给出登录引导，不伪造状态。
class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.video,
    required this.onOpenOriginal,
    required this.interaction,
    required this.onOpenLogin,
  });

  final UnifiedVideo video;
  final VoidCallback onOpenOriginal;
  final InteractionController interaction;
  final VoidCallback onOpenLogin;

  @override
  Widget build(BuildContext context) {
    final caps = interaction.capabilities;
    final state = interaction.state;

    // 点赞数：优先用实时状态，回退到视频元数据
    final likeCount = state.likeCount ?? video.stats.likeCount;
    // 评论数：优先用评论接口总数，回退到元数据
    final commentCount =
        interaction.commentTotal > 0
            ? interaction.commentTotal
            : video.stats.danmakuCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 作者头像（带关注加号）—— 短视频右侧栏的第一要素
        _AuthorAvatar(video: video),
        const SizedBox(height: AppleSpace.xl),

        // 点赞（真实写入）
        if (caps.like)
          InteractionRailButton(
            icon: Icons.favorite_border_rounded,
            activeIcon: Icons.favorite_rounded,
            label: likeCount != null ? _fmtCount(likeCount) : '点赞',
            active: state.liked,
            pending: interaction.likePending,
            onTap: () {
              if (!interaction.isLoggedIn) {
                onOpenLogin();
                return;
              }
              interaction.toggleLike();
            },
          ),
        const SizedBox(height: AppleSpace.lg),

        // 评论（真实读取）
        if (caps.comments)
          InteractionRailButton(
            icon: Icons.chat_bubble_outline_rounded,
            activeIcon: Icons.chat_bubble_rounded,
            label: commentCount != null ? _fmtCount(commentCount) : '评论',
            active: false,
            onTap: () => _openComments(context),
          ),
        const SizedBox(height: AppleSpace.lg),

        // 投币（B 站特有）
        if (caps.coin)
          InteractionRailButton(
            icon: Icons.monetization_on_outlined,
            activeIcon: Icons.monetization_on_rounded,
            label: state.coined > 0 ? '已投${state.coined}' : '投币',
            active: state.coined > 0,
            activeColor: const Color(0xFFFFB300),
            pending: interaction.coinPending,
            onTap: () {
              if (!interaction.isLoggedIn) {
                onOpenLogin();
                return;
              }
              _openCoin(context);
            },
          ),
        if (caps.coin) const SizedBox(height: AppleSpace.lg),

        // 收藏
        if (caps.favorite)
          InteractionRailButton(
            icon: Icons.star_border_rounded,
            activeIcon: Icons.star_rounded,
            label: state.favorited ? '已收藏' : '收藏',
            active: state.favorited,
            activeColor: const Color(0xFFFFC107),
            pending: interaction.favoritePending,
            onTap: () {
              if (!interaction.isLoggedIn) {
                onOpenLogin();
                return;
              }
              interaction.toggleFavorite();
            },
          ),
        if (caps.favorite) const SizedBox(height: AppleSpace.lg),

        // 分享
        InteractionRailButton(
          icon: Icons.share_rounded,
          activeIcon: Icons.share_rounded,
          label: '分享',
          active: false,
          onTap: () {
            Clipboard.setData(ClipboardData(text: video.canonicalUrl));
            _toast(context, '链接已复制');
          },
        ),
        const SizedBox(height: AppleSpace.lg),

        // 原平台
        InteractionRailButton(
          icon: Icons.open_in_new_rounded,
          activeIcon: Icons.open_in_new_rounded,
          label: '原平台',
          active: false,
          onTap: onOpenOriginal,
        ),
        const SizedBox(height: AppleSpace.lg),

        InteractionRailButton(
          icon: Icons.more_horiz_rounded,
          activeIcon: Icons.more_horiz_rounded,
          label: '更多',
          active: false,
          onTap: () => _showMore(context),
        ),
      ],
    );
  }

  Future<void> _openComments(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentSheet(controller: interaction),
    );
  }

  Future<void> _openCoin(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CoinSheet(
        controller: interaction,
        coinBalance: null,
      ),
    );
  }

  static String _fmtCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showMore(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(
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
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: AppleSpace.lg),
              _SheetAction(
                icon: Icons.link_rounded,
                label: '复制链接',
                onTap: () {
                  Clipboard.setData(ClipboardData(text: video.canonicalUrl));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('链接已复制')),
                  );
                },
              ),
              _SheetAction(
                icon: Icons.open_in_browser_rounded,
                label: '在浏览器中打开',
                onTap: () {
                  Navigator.pop(ctx);
                  onOpenOriginal();
                },
              ),
              const SizedBox(height: AppleSpace.md),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.xl,
          vertical: AppleSpace.md,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.white70),
            const SizedBox(width: AppleSpace.md),
            Text(
              label,
              style: AppleType.body.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}


/// 作者头像 + 关注加号（短视频右侧栏第一要素）。
class _AuthorAvatar extends StatelessWidget {
  const _AuthorAvatar({required this.video});

  final UnifiedVideo video;

  @override
  Widget build(BuildContext context) {
    final avatar = video.author.avatarUrl;

    return SizedBox(
      width: 52,
      height: 62,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          // 头像：白色描边让它在任何背景上都有边界
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.6),
              boxShadow: const [
                BoxShadow(color: Color(0x66000000), blurRadius: 8),
              ],
            ),
            child: ClipOval(
              child: avatar != null && avatar.isNotEmpty
                  ? Image.network(
                      avatar,
                      fit: BoxFit.cover,
                      headers: const {
                        'Referer': 'https://www.bilibili.com/',
                      },
                      errorBuilder: (_, __, ___) =>
                          _AvatarFallback(name: video.author.name),
                    )
                  : _AvatarFallback(name: video.author.name),
            ),
          ),
          // 关注加号（短视频标配；本版本未接入关注写入，仅作视觉锚点）
          Positioned(
            bottom: 2,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                color: Color(0xFFFF2D55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.add_rounded,
                size: 15,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final initial = (name != null && name!.isNotEmpty)
        ? name!.characters.first
        : '?';
    return Container(
      color: const Color(0xFF3A3A3C),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 底部迷你进度条 + 播放/暂停。
///
/// **性能关键**：这是唯一订阅高频播放位置流的组件。
/// 它用 [StreamBuilder] 把重建范围限制在 3px 高的进度条内，
/// 而不是让整个 PageView 随播放进度重建。
class _MiniProgress extends StatelessWidget {
  const _MiniProgress({
    required this.isActive,
    required this.onTogglePlay,
  });

  final bool isActive;
  final VoidCallback onTogglePlay;

  @override
  Widget build(BuildContext context) {
    if (!isActive) return const SizedBox.shrink();

    return GestureDetector(
      onTap: onTogglePlay,
      child: SizedBox(
        height: 3,
        child: _ProgressStream(),
      ),
    );
  }
}

/// 进度条本体：独立订阅快照流。
class _ProgressStream extends StatelessWidget {
  const _ProgressStream();

  @override
  Widget build(BuildContext context) {
    // 从最近的 FeedScreen 状态取流；用 InheritedWidget 传递成本过高，
    // 这里用全局可访问的控制器引用。
    final controller = FeedScreenScope.of(context);
    if (controller == null) {
      return const LinearProgressIndicator(
        value: 0,
        minHeight: 3,
        backgroundColor: Color(0x29FFFFFF),
        valueColor: AlwaysStoppedAnimation(Colors.white),
      );
    }

    return StreamBuilder<PlayerSnapshot>(
      stream: controller.snapshotStream,
      initialData: controller.snapshot,
      builder: (context, snap) {
        final progress = snap.data?.progress ?? 0;
        return LinearProgressIndicator(
          value: progress,
          minHeight: 3,
          backgroundColor: Colors.white.withValues(alpha: 0.16),
          valueColor: const AlwaysStoppedAnimation(Colors.white),
        );
      },
    );
  }
}

/// 加载中舞台。
class _LoadingStage extends StatelessWidget {
  const _LoadingStage({required this.video});

  final UnifiedVideo video;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (video.coverUrl != null)
          Image.network(
            video.coverUrl!,
            fit: BoxFit.contain,
            headers: const {'Referer': 'https://www.bilibili.com/'},
            errorBuilder: (_, __, ___) => Container(color: Colors.black),
          ),
        const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Colors.white54,
            ),
          ),
        ),
      ],
    );
  }
}

/// 失败舞台。
class _FailedStage extends StatelessWidget {
  const _FailedStage({
    required this.error,
    required this.onRetry,
    required this.onOpenOriginal,
  });

  final FusionException? error;
  final VoidCallback onRetry;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final presentation = error?.presentation;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(AppleSpace.xxxl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.play_circle_outline_rounded,
              size: 52,
              color: Colors.white30,
            ),
            const SizedBox(height: AppleSpace.lg),
            Text(
              presentation?.title ?? '无法播放',
              style: AppleType.title3.copyWith(color: Colors.white),
            ),
            const SizedBox(height: AppleSpace.sm),
            Text(
              presentation?.detail ?? '该视频暂时无法在应用内播放。',
              textAlign: TextAlign.center,
              style: AppleType.footnote.copyWith(
                color: Colors.white54,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AppleSpace.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _OutlineButton(
                  label: '原平台播放',
                  onTap: onOpenOriginal,
                ),
                const SizedBox(width: AppleSpace.md),
                _OutlineButton(
                  label: '重试',
                  onTap: onRetry,
                  filled: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 仅外部播放舞台。
class _ExternalStage extends StatelessWidget {
  const _ExternalStage({required this.video, required this.onOpenOriginal});

  final UnifiedVideo video;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (video.coverUrl != null)
            Image.network(
              video.coverUrl!,
              fit: BoxFit.contain,
              headers: const {'Referer': 'https://www.bilibili.com/'},
              errorBuilder: (_, __, ___) => Container(color: Colors.black),
            ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '该视频需要在原平台播放',
                  style: AppleType.subheadlineEmphasized.copyWith(
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppleSpace.lg),
                _OutlineButton(
                  label: '打开原平台',
                  onTap: onOpenOriginal,
                  filled: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  const _OutlineButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.xl,
          vertical: AppleSpace.md,
        ),
        decoration: BoxDecoration(
          color: filled ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(AppleRadius.pill),
          border: Border.all(
            color: filled ? Colors.transparent : Colors.white38,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: AppleType.buttonSmall.copyWith(
            color: filled ? Colors.black : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 推荐流错误视图。
class _FeedErrorView extends StatelessWidget {
  const _FeedErrorView({
    required this.error,
    required this.onRetry,
    required this.onSwitchSource,
  });

  final FusionException error;
  final VoidCallback onRetry;
  final VoidCallback onSwitchSource;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppleSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              size: 48,
              color: Colors.white30,
            ),
            const SizedBox(height: AppleSpace.lg),
            Text(
              error.presentation.title,
              style: AppleType.title3.copyWith(color: Colors.white),
            ),
            const SizedBox(height: AppleSpace.sm),
            Text(
              error.userMessage,
              textAlign: TextAlign.center,
              style: AppleType.footnote.copyWith(
                color: Colors.white54,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AppleSpace.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _OutlineButton(label: '换个来源', onTap: onSwitchSource),
                const SizedBox(width: AppleSpace.md),
                _OutlineButton(label: '重试', onTap: onRetry, filled: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 推荐流空视图。
class _FeedEmptyView extends StatelessWidget {
  const _FeedEmptyView({required this.onSwitchSource});

  final VoidCallback onSwitchSource;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppleSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.video_library_outlined,
              size: 48,
              color: Colors.white30,
            ),
            const SizedBox(height: AppleSpace.lg),
            Text(
              '这个来源暂时没有内容',
              style: AppleType.title3.copyWith(color: Colors.white),
            ),
            const SizedBox(height: AppleSpace.sm),
            Text(
              '可以换一个内容来源，或稍后重试。',
              textAlign: TextAlign.center,
              style: AppleType.footnote.copyWith(color: Colors.white54),
            ),
            const SizedBox(height: AppleSpace.xl),
            _OutlineButton(
              label: '切换来源',
              onTap: onSwitchSource,
              filled: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// 分页错误提示条。
class _AppendErrorBar extends StatelessWidget {
  const _AppendErrorBar({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.lg,
        vertical: AppleSpace.md,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppleRadius.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppleType.footnote.copyWith(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: Text(
              '重试',
              style: AppleType.footnoteEmphasized.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
