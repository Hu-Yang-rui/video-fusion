/// 全屏竖滑视频流 —— 本 APP 的主界面。
///
/// 交互（对齐短视频平台习惯）：
///  - 打开即自动播放当前屏
///  - 上滑切下一个 / 下滑切上一个
///  - 单击暂停 / 继续
///  - 右侧操作栏：来源标识、原平台入口、播放信息
///  - 右上角切换内容来源
///
/// 视觉：全屏视频为底，UI 悬浮其上，暗色沉浸。
/// 所有悬浮控件避开系统状态栏与手势条（安全区）。
library;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/feed.dart';
import '../../models/playback.dart';
import '../../models/unified_video.dart';
import '../../player/player_controller.dart';
import 'feed_controller.dart';
import 'mobile_theme.dart';
import 'mobile_widgets.dart';

class VideoFeedPage extends StatefulWidget {
  const VideoFeedPage({
    super.key,
    required this.controller,
    required this.onOpenSourcePicker,
    required this.onOpenLogin,
    required this.onOpenLinkIntake,
    required this.onOpenOriginal,
    required this.onOpenSettings,
    this.loggedInLabel,
  });

  final FeedController controller;
  final VoidCallback onOpenSourcePicker;
  final VoidCallback onOpenLogin;
  final VoidCallback onOpenLinkIntake;
  final void Function(UnifiedVideo video) onOpenOriginal;
  final VoidCallback onOpenSettings;
  final String? loggedInLabel;

  @override
  State<VideoFeedPage> createState() => _VideoFeedPageState();
}

class _VideoFeedPageState extends State<VideoFeedPage> {
  final PageController _pageController = PageController();
  VideoController? _videoController;

  @override
  void initState() {
    super.initState();
    widget.controller.initPlayer();
    widget.controller.addListener(_onControllerChanged);
    _attachVideoController();
  }

  void _attachVideoController() {
    final p = widget.controller.player;
    if (p != null) {
      _videoController = VideoController(p.rawPlayer);
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return Scaffold(
      backgroundColor: MobileTokens.stage,
      body: Stack(
        children: [
          // ── 竖滑流主体 ────────────────────────────────────
          if (c.initialLoading && c.length == 0)
            const Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: MobileTokens.accent,
                ),
              ),
            )
          else if (c.feedError != null && c.length == 0)
            _buildFeedError(c)
          else if (c.length == 0)
            MobileEmptyState(
              title: '这个来源暂时没有内容',
              description: '可以换一个内容来源，或稍后下拉刷新。',
              actionLabel: '切换来源',
              onAction: widget.onOpenSourcePicker,
            )
          else
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: c.length,
              onPageChanged: (index) {
                c.setCurrentIndex(index);
                c.playIndex(index);
              },
              itemBuilder: (context, index) => _FeedItemView(
                video: c.items[index],
                index: index,
                isActive: index == c.currentIndex,
                state: c.stateOf(index),
                error: c.errorOf(index),
                playbackSource: c.playbackSourceOf(index),
                videoController: _videoController,
                snapshot: c.snapshot,
                platformLabel: _platformLabel(c.items[index].platformId),
                onRetry: c.retryCurrent,
                onTogglePlay: c.togglePlay,
                onOpenOriginal: () =>
                    widget.onOpenOriginal(c.items[index]),
                onSeek: c.seek,
                onVolume: c.setVolume,
                onRate: c.setRate,
              ),
            ),

          // ── 顶部悬浮栏 ────────────────────────────────────
          _buildTopBar(c),

          // ── 底部提示（分页加载状态）────────────────────────
          if (c.loadingMore && c.length > 0)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 84,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: MobileTokens.inkTertiary,
                  ),
                ),
              ),
            ),

          // ── 分页错误提示（不阻塞浏览）──────────────────────
          if (c.appendError != null)
            Positioned(
              left: MobileTokens.s4,
              right: MobileTokens.s4,
              bottom: 84,
              child: _AppendErrorToast(
                message: c.appendError!.userMessage,
                onRetry: c.loadMore,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopBar(FeedController c) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + MobileTokens.s2,
          left: MobileTokens.s4,
          right: MobileTokens.s4,
          bottom: MobileTokens.s4,
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
            // 内容来源切换
            FeedSourceButton(
              current: c.source,
              onTap: widget.onOpenSourcePicker,
            ),
            const Spacer(),
            // 链接接入（次要入口）
            _TopIconButton(
              icon: Icons.add_link_rounded,
              tooltip: '接入视频链接',
              onTap: widget.onOpenLinkIntake,
            ),
            const SizedBox(width: MobileTokens.s2),
            // 登录 / 账号
            _TopIconButton(
              icon: widget.loggedInLabel != null
                  ? Icons.account_circle_rounded
                  : Icons.login_rounded,
              tooltip: widget.loggedInLabel != null
                  ? '已登录：${widget.loggedInLabel}'
                  : '登录平台账号',
              highlighted: widget.loggedInLabel != null,
              onTap: widget.onOpenLogin,
            ),
            const SizedBox(width: MobileTokens.s2),
            // 设置
            _TopIconButton(
              icon: Icons.tune_rounded,
              tooltip: '设置',
              onTap: widget.onOpenSettings,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeedError(FeedController c) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(MobileTokens.s5),
        child: Center(
          child: MobileErrorCard(
            title: c.feedError!.presentation.title,
            detail: c.feedError!.userMessage,
            onRetry: c.feedError!.retryable ? c.retryInitial : null,
            onSecondary: widget.onOpenSourcePicker,
            secondaryLabel: '换个来源',
          ),
        ),
      ),
    );
  }

  String _platformLabel(String platformId) {
    for (final d in _descriptors) {
      if (d.id == platformId) return d.shortLabel;
    }
    return platformId;
  }

  List<({String id, String shortLabel})> _descriptors = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 平台短标签由上层通过 controller 的 service 提供；
    // 这里保持简单映射，避免 UI 层硬编码平台判断。
    _descriptors = const [
      (id: 'bilibili', shortLabel: 'B站'),
      (id: 'douyin', shortLabel: '抖音'),
      (id: 'mock', shortLabel: '模拟'),
    ];
  }
}

/// 单屏视频视图。
class _FeedItemView extends StatelessWidget {
  const _FeedItemView({
    required this.video,
    required this.index,
    required this.isActive,
    required this.state,
    required this.error,
    required this.playbackSource,
    required this.videoController,
    required this.snapshot,
    required this.platformLabel,
    required this.onRetry,
    required this.onTogglePlay,
    required this.onOpenOriginal,
    required this.onSeek,
    required this.onVolume,
    required this.onRate,
  });

  final UnifiedVideo video;
  final int index;
  final bool isActive;
  final FeedItemState state;
  final Object? error;
  final PlaybackSource? playbackSource;
  final VideoController? videoController;
  final PlayerSnapshot snapshot;
  final String platformLabel;
  final Future<void> Function() onRetry;
  final Future<void> Function() onTogglePlay;
  final VoidCallback onOpenOriginal;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function(double) onVolume;
  final Future<void> Function(double) onRate;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (state == FeedItemState.ready) onTogglePlay();
      },
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 视频画面 / 封面 / 状态 ────────────────────────
          _buildStage(),

          // ── 底部信息区 ────────────────────────────────────
          if (state != FeedItemState.failed) _buildBottomInfo(context),

          // ── 右侧操作栏 ────────────────────────────────────
          if (state != FeedItemState.failed) _buildActionRail(context),

          // ── 暂停指示 ──────────────────────────────────────
          if (isActive && snapshot.phase == PlayerPhase.paused)
            const Center(
              child: Icon(
                Icons.play_arrow_rounded,
                size: 64,
                color: Color(0xCCFFFFFF),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStage() {
    switch (state) {
      case FeedItemState.failed:
        return _FailedStage(
          video: video,
          error: error,
          onRetry: onRetry,
          onOpenOriginal: onOpenOriginal,
        );

      case FeedItemState.externalOnly:
        return _ExternalOnlyStage(
          video: video,
          playbackSource: playbackSource,
          onOpenOriginal: onOpenOriginal,
        );

      case FeedItemState.idle:
      case FeedItemState.resolving:
        return _CoverStage(video: video, loading: true);

      case FeedItemState.loading:
        return isActive && videoController != null
            ? _VideoStage(controller: videoController!)
            : _CoverStage(video: video, loading: true);

      case FeedItemState.ready:
        if (!isActive) return _CoverStage(video: video, loading: false);
        if (videoController == null) {
          return _CoverStage(video: video, loading: true);
        }
        return _VideoStage(controller: videoController!);
    }
  }

  Widget _buildBottomInfo(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: MobileTokens.s4,
      right: MobileTokens.actionRailWidth + MobileTokens.s3,
      bottom: bottomInset + MobileTokens.bottomSafeGap + MobileTokens.s4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 进度条：仅当前屏且已就绪时显示。
          // 短视频平台的进度条通常很细，不抢视觉，但可点击跳转。
          if (isActive && state == FeedItemState.ready) ...[
            _FeedProgressBar(
              position: snapshot.position,
              duration: snapshot.duration,
              buffered: snapshot.buffered,
              onSeek: onSeek,
            ),
            const SizedBox(height: MobileTokens.s3),
          ],
          // 作者
          Row(
            children: [
              Flexible(
                child: Text(
                  video.author.name ?? '作者未知',
                  style: MobileText.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: MobileTokens.s2),
          // 标题（最多两行）
          Text(
            video.title,
            style: MobileText.videoTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: MobileTokens.s2),
          // 元信息：时长 / 播放量 / 实时分辨率
          Row(
            children: [
              if (video.durationLabel != null) ...[
                Text(video.durationLabel!, style: MobileText.meta),
                const SizedBox(width: MobileTokens.s3),
              ],
              if (video.stats.viewCount != null) ...[
                const Icon(Icons.play_arrow_rounded,
                    size: 13, color: MobileTokens.inkTertiary),
                const SizedBox(width: 2),
                Text(
                  _formatCount(video.stats.viewCount!),
                  style: MobileText.meta,
                ),
              ],
              // 播放中显示解码器实际输出的分辨率。
              // 数据来自播放内核，不是元数据，因此能如实反映当前画面。
              if (isActive && snapshot.videoWidth != null) ...[
                const SizedBox(width: MobileTokens.s3),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MobileTokens.s2,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${snapshot.videoWidth}×${snapshot.videoHeight}',
                    style: MobileText.meta.copyWith(fontSize: 10.5),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionRail(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Positioned(
      right: MobileTokens.s3,
      bottom: bottomInset + MobileTokens.bottomSafeGap + MobileTokens.s4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 平台来源标识
          MobilePlatformBadge(
            platformId: video.platformId,
            label: platformLabel,
            compact: true,
          ),
          const SizedBox(height: MobileTokens.s4),
          // 播放状态（仅当前屏）
          if (isActive)
            _RailItem(
              icon: snapshot.phase == PlayerPhase.playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              label: snapshot.phase == PlayerPhase.playing ? '暂停' : '播放',
              onTap: onTogglePlay,
            ),
          // 原平台入口
          _RailItem(
            icon: Icons.open_in_new_rounded,
            label: '原平台',
            onTap: () async => onOpenOriginal(),
          ),
        ],
      ),
    );
  }

  static String _formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

/// 视频渲染层。
class _VideoStage extends StatelessWidget {
  const _VideoStage({required this.controller});

  final VideoController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: MobileTokens.stage,
      child: Video(
        controller: controller,
        controls: NoVideoControls,
        fill: MobileTokens.stage,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// 封面层（未开始播放时展示，避免黑屏）。
class _CoverStage extends StatelessWidget {
  const _CoverStage({required this.video, required this.loading});

  final UnifiedVideo video;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final url = video.coverUrl;
    return Container(
      color: MobileTokens.stage,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url != null && url.isNotEmpty)
            Image.network(
              url,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          if (loading)
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: MobileTokens.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 失败层：明确原因 + 重试 + 原平台入口。不静默跳过。
class _FailedStage extends StatelessWidget {
  const _FailedStage({
    required this.video,
    required this.error,
    required this.onRetry,
    required this.onOpenOriginal,
  });

  final UnifiedVideo video;
  final Object? error;
  final Future<void> Function() onRetry;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final msg = error is Exception
        ? (error as dynamic).userMessage as String?
        : null;
    final title = error is Exception
        ? (error as dynamic).presentation.title as String?
        : null;

    return Container(
      color: MobileTokens.stage,
      padding: const EdgeInsets.all(MobileTokens.s6),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: MobileTokens.danger.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.priority_high_rounded,
                  size: 24, color: MobileTokens.danger),
            ),
            const SizedBox(height: MobileTokens.s4),
            Text(
              title ?? '无法播放',
              style: MobileText.listTitle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MobileTokens.s2),
            Text(
              msg ?? '该视频暂时无法在应用内播放。',
              style: MobileText.body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MobileTokens.s3),
            Text(
              video.title,
              style: MobileText.caption,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: MobileTokens.s6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _StageButton(
                  icon: Icons.refresh_rounded,
                  label: '重试',
                  primary: true,
                  onTap: () => onRetry(),
                ),
                const SizedBox(width: MobileTokens.s3),
                _StageButton(
                  icon: Icons.open_in_new_rounded,
                  label: '去原平台',
                  onTap: onOpenOriginal,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 仅支持外部播放的层。
class _ExternalOnlyStage extends StatelessWidget {
  const _ExternalOnlyStage({
    required this.video,
    required this.playbackSource,
    required this.onOpenOriginal,
  });

  final UnifiedVideo video;
  final PlaybackSource? playbackSource;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final isEmbed = playbackSource is OfficialEmbedPlaybackSource;

    return Container(
      color: MobileTokens.stage,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _CoverStage(video: video, loading: false),
          Container(color: Colors.black.withValues(alpha: 0.62)),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(MobileTokens.s6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.open_in_new_rounded,
                      size: 30, color: MobileTokens.inkSecondary),
                  const SizedBox(height: MobileTokens.s4),
                  Text(
                    isEmbed ? '该视频需使用官方播放器' : '该视频仅支持在原平台播放',
                    style: MobileText.listTitle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: MobileTokens.s2),
                  Text(
                    isEmbed
                        ? '当前平台未提供可用于应用内播放的直链，'
                            '可在原平台观看完整内容。'
                        : '当前环境无法在应用内播放该视频，'
                            '可在原平台观看完整内容。',
                    style: MobileText.body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: MobileTokens.s6),
                  _StageButton(
                    icon: Icons.open_in_new_rounded,
                    label: '在原平台观看',
                    primary: true,
                    onTap: onOpenOriginal,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StageButton extends StatelessWidget {
  const _StageButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MobileTokens.rControl),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTokens.s5,
          vertical: MobileTokens.s3,
        ),
        decoration: BoxDecoration(
          color: primary
              ? MobileTokens.accent
              : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(MobileTokens.rControl),
          border: primary
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: primary ? const Color(0xFF06231F) : MobileTokens.ink,
            ),
            const SizedBox(width: MobileTokens.s2),
            Text(
              label,
              style: MobileText.label.copyWith(
                color: primary ? const Color(0xFF06231F) : MobileTokens.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MobileTokens.s5),
      child: InkWell(
        onTap: () => onTap(),
        customBorder: const CircleBorder(),
        child: Column(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 21, color: MobileTokens.ink),
            ),
            const SizedBox(height: MobileTokens.s1 + 1),
            Text(label, style: MobileText.caption.copyWith(
              color: MobileTokens.inkSecondary,
              fontSize: 10,
            )),
          ],
        ),
      ),
    );
  }
}

/// 竖滑流内的细进度条。
///
/// 设计取舍：短视频平台不常驻粗控制条，但用户需要知道进度并能跳转。
/// 这里用 3px 细条 + 可点击/拖动，既保持沉浸又不失功能。
/// 仅在**当前屏且已就绪**时显示——未就绪的屏不该出现假进度。
class _FeedProgressBar extends StatefulWidget {
  const _FeedProgressBar({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final Future<void> Function(Duration) onSeek;

  @override
  State<_FeedProgressBar> createState() => _FeedProgressBarState();
}

class _FeedProgressBarState extends State<_FeedProgressBar> {
  bool _dragging = false;
  double _dragRatio = 0;

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    if (total <= 0) return const SizedBox(height: 3);

    final progress = _dragging
        ? _dragRatio
        : (widget.position.inMilliseconds / total).clamp(0.0, 1.0);
    final buffered = (widget.buffered.inMilliseconds / total).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        void seekTo(double dx) {
          final ratio = (dx / width).clamp(0.0, 1.0);
          widget.onSeek(Duration(milliseconds: (ratio * total).round()));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seekTo(d.localPosition.dx),
          onHorizontalDragStart: (d) => setState(() {
            _dragging = true;
            _dragRatio = (d.localPosition.dx / width).clamp(0.0, 1.0);
          }),
          onHorizontalDragUpdate: (d) => setState(() {
            _dragRatio = (d.localPosition.dx / width).clamp(0.0, 1.0);
          }),
          onHorizontalDragEnd: (_) {
            seekTo(_dragRatio * width);
            setState(() => _dragging = false);
          },
          child: SizedBox(
            // 触摸热区高于视觉高度，便于手指操作
            height: 16,
            child: Center(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: buffered,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.36),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: MobileTokens.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: highlighted
                ? MobileTokens.accent.withValues(alpha: 0.22)
                : MobileTokens.scrim,
            shape: BoxShape.circle,
            border: Border.all(
              color: highlighted
                  ? MobileTokens.accent.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.14),
            ),
          ),
          child: Icon(
            icon,
            size: 18,
            color: highlighted ? MobileTokens.accent : MobileTokens.ink,
          ),
        ),
      ),
    );
  }
}

class _AppendErrorToast extends StatelessWidget {
  const _AppendErrorToast({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MobileTokens.s4,
        vertical: MobileTokens.s3,
      ),
      decoration: BoxDecoration(
        color: MobileTokens.scrim,
        borderRadius: BorderRadius.circular(MobileTokens.rControl),
        border: Border.all(color: MobileTokens.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 15, color: MobileTokens.danger),
          const SizedBox(width: MobileTokens.s2),
          Expanded(
            child: Text(
              message,
              style: MobileText.caption.copyWith(color: MobileTokens.ink),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: MobileTokens.s2),
          InkWell(
            onTap: () => onRetry(),
            child: Text(
              '重试',
              style: MobileText.label.copyWith(
                color: MobileTokens.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
