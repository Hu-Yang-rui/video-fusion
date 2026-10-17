/// 长视频详情页（Apple 风格）。
///
/// 结构（自上而下）：
///  1. 播放器区域（16:9，沉浸式黑色背景，自绘控制条）
///  2. 标题与统计
///  3. 作者行（头像 + 名称 + 关注位）
///  4. 描述（可展开）
///  5. 播放能力说明（如实展示当前使用的是哪种播放方式）
///  6. 相关推荐
///
/// 与竖滑流的关键差异：
///  - 这里是**长视频场景**：完整播放、进度恢复、清晰度切换、全屏
///  - 使用独立的播放器实例，不与推荐流共享
///  - 支持横屏（全屏时自动旋转）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';
import '../../design/components/video_widgets.dart';
import '../../models/playback.dart';
import '../../models/unified_video.dart';
import '../../player/player_controller.dart';

/// 长视频详情页。
class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({
    super.key,
    required this.video,
    required this.service,
    this.onOpenOriginal,
    this.initialPosition,
    this.onProgressChanged,
  });

  final UnifiedVideo video;
  final VideoService service;
  final void Function(UnifiedVideo)? onOpenOriginal;

  /// 续播位置（来自观看历史）。
  final Duration? initialPosition;

  /// 进度回调（用于持久化观看进度）。
  final void Function(Duration position, Duration duration)? onProgressChanged;

  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen> {
  FusionPlayerController? _player;
  VideoController? _videoController;
  PlayerSnapshot _snapshot = PlayerSnapshot.initial;
  StreamSubscription<PlayerSnapshot>? _sub;

  PlaybackSource? _source;
  FusionException? _error;
  bool _resolving = true;
  bool _showControls = true;
  bool _descriptionExpanded = false;
  bool _fullscreen = false;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _resolveAndLoad();
  }

  Future<void> _resolveAndLoad() async {
    setState(() {
      _resolving = true;
      _error = null;
    });

    final outcome = await widget.service.resolvePlayback(widget.video);

    if (!mounted) return;

    if (!outcome.ok) {
      setState(() {
        _resolving = false;
        _error = outcome.error ??
            FusionException(
              code: FusionErrorCode.capabilityUnavailable,
              userMessage: '无法解析该视频的播放地址。',
              platformId: widget.video.platformId,
            );
      });
      return;
    }

    final source = outcome.source!;
    if (source is! NativePlaybackSource) {
      // 非应用内播放：明确告知，不伪装
      setState(() {
        _resolving = false;
        _source = source;
      });
      return;
    }

    final player = FusionPlayerController();
    _player = player;
    _sub = player.stream.listen((s) {
      if (!mounted) return;
      setState(() => _snapshot = s);
      widget.onProgressChanged?.call(s.position, s.duration);
    });

    await player.load(source);
    _videoController = VideoController(
      player.rawPlayer,
      configuration: player.videoConfiguration,
    );

    // 续播
    final resume = widget.initialPosition;
    if (resume != null && resume > const Duration(seconds: 5)) {
      await player.seek(resume);
    }

    await player.play();

    if (mounted) {
      setState(() {
        _resolving = false;
        _source = source;
      });
      _scheduleHideControls();
    }
  }

  void _scheduleHideControls() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _snapshot.phase == PlayerPhase.playing) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    if (next) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
      );
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _sub?.cancel();
    _player?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildPlayerArea(fullscreen: true),
      );
    }

    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: CustomScrollView(
        slivers: [
          // 折叠式播放器头部
          SliverAppBar(
            pinned: true,
            expandedHeight: MediaQuery.sizeOf(context).width * 9 / 16,
            backgroundColor: Colors.black,
            surfaceTintColor: Colors.transparent,
            leading: _GlassBackButton(onTap: () => Navigator.pop(context)),
            title: const SizedBox.shrink(),
            flexibleSpace: FlexibleSpaceBar(
              background: _buildPlayerArea(fullscreen: false),
              collapseMode: CollapseMode.pin,
            ),
          ),

          // 内容
          SliverToBoxAdapter(
            child: _buildContent(c),
          ),
        ],
      ),
    );
  }

  /// 播放器区域。
  Widget _buildPlayerArea({required bool fullscreen}) {
    if (_resolving) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppleSpace.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_circle_outline_rounded,
                  size: 44,
                  color: Colors.white30,
                ),
                const SizedBox(height: AppleSpace.md),
                Text(
                  _error!.presentation.title,
                  style: AppleType.subheadlineEmphasized.copyWith(
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppleSpace.xs),
                Text(
                  _error!.userMessage,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppleType.caption1.copyWith(color: Colors.white54),
                ),
                const SizedBox(height: AppleSpace.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _PlayerPillButton(
                      label: '原平台',
                      onTap: () => widget.onOpenOriginal?.call(widget.video),
                    ),
                    const SizedBox(width: AppleSpace.sm),
                    _PlayerPillButton(
                      label: '重试',
                      onTap: _resolveAndLoad,
                      filled: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 非原生播放
    if (_source != null && _source is! NativePlaybackSource) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _source is ExternalPlaybackSource
                    ? '该视频需要在原平台播放'
                    : '该视频使用官方嵌入播放',
                style: AppleType.subheadlineEmphasized.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: AppleSpace.lg),
              _PlayerPillButton(
                label: '打开原平台',
                onTap: () => widget.onOpenOriginal?.call(widget.video),
                filled: true,
              ),
            ],
          ),
        ),
      );
    }

    final player = _player;
    if (player == null || _videoController == null) {
      return Container(color: Colors.black);
    }

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Video(
              controller: _videoController!,
              controls: NoVideoControls,
              fit: BoxFit.contain,
            ),
          ),
          // 点击切换控制条
          Positioned.fill(
            child: GestureDetector(
              onTap: _toggleControls,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // 缓冲
          if (_snapshot.isBuffering)
            const Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white70,
                ),
              ),
            ),
          // 控制条
          AnimatedOpacity(
            opacity: _showControls ? 1 : 0,
            duration: AppleMotion.fast,
            child: IgnorePointer(
              ignoring: !_showControls,
              child: PlayerControlBar(
                position: _snapshot.position,
                duration: _snapshot.duration,
                buffered: _snapshot.buffered,
                isPlaying: _snapshot.phase == PlayerPhase.playing,
                volume: _snapshot.volume,
                rate: 1.0,
                onPlayPause: () {
                  player.playOrPause();
                  _scheduleHideControls();
                },
                onSeek: (d) {
                  player.seek(d);
                  _scheduleHideControls();
                },
                onSeekStart: () => _controlsTimer?.cancel(),
                onSeekEnd: _scheduleHideControls,
                onVolumeChanged: (v) => player.setVolume(v),
                onRateChanged: (r) => player.rawPlayer.setRate(r),
                onFullscreen: _toggleFullscreen,
                title: widget.video.title,
                subtitle: widget.video.author.name,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 详情内容区。
  Widget _buildContent(AppleColors c) {
    final v = widget.video;
    final caps = _player?.capabilities;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppleSpace.huge),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题与统计 ────────────────────────────────
          Container(
            color: c.secondaryGroupedBackground,
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.lg,
              AppleSpace.lg,
              AppleSpace.lg,
              AppleSpace.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.title,
                  style: AppleType.title3.copyWith(
                    color: c.label,
                    height: 1.32,
                  ),
                ),
                const SizedBox(height: AppleSpace.sm),
                Row(
                  children: [
                    PlatformChip(platformId: v.platformId),
                    const SizedBox(width: AppleSpace.sm),
                    if (v.stats.viewCount != null)
                      Text(
                        '${_fmtCount(v.stats.viewCount!)}次播放',
                        style: AppleType.caption1.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                    if (v.publishedAt != null) ...[
                      Text(
                        ' · ',
                        style: AppleType.caption1.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                      Text(
                        _fmtDate(v.publishedAt!),
                        style: AppleType.caption1.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: AppleSpace.lg),

          // ── 作者 ──────────────────────────────────────
          AppleGroupedSection(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppleSpace.lg),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: c.fill,
                      backgroundImage: v.author.avatarUrl != null
                          ? NetworkImage(
                              v.author.avatarUrl!,
                              headers: const {
                                'Referer': 'https://www.bilibili.com/',
                              },
                            )
                          : null,
                      child: v.author.avatarUrl == null
                          ? Text(
                              (v.author.name ?? '?').characters.first,
                              style: AppleType.subheadlineEmphasized.copyWith(
                                color: c.secondaryLabel,
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: AppleSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            v.author.name ?? '未知作者',
                            style: AppleType.bodyEmphasized.copyWith(
                              color: c.label,
                            ),
                          ),
                          if (v.author.platformAuthorId != null)
                            Text(
                              'ID: ${v.author.platformAuthorId}',
                              style: AppleType.caption1.copyWith(
                                color: c.tertiaryLabel,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: AppleSpace.lg),

          // ── 描述 ──────────────────────────────────────
          if (v.description != null && v.description!.trim().isNotEmpty)
            AppleGroupedSection(
              header: '简介',
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppleSpace.lg),
                  child: GestureDetector(
                    onTap: () => setState(
                      () => _descriptionExpanded = !_descriptionExpanded,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          v.description!.trim(),
                          maxLines: _descriptionExpanded ? null : 3,
                          overflow: _descriptionExpanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                          style: AppleType.footnote.copyWith(
                            color: c.label,
                            height: 1.5,
                          ),
                        ),
                        if (v.description!.trim().length > 80) ...[
                          const SizedBox(height: AppleSpace.xs),
                          Text(
                            _descriptionExpanded ? '收起' : '展开',
                            style: AppleType.footnoteEmphasized.copyWith(
                              color: c.blue,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),

          const SizedBox(height: AppleSpace.lg),

          // ── 播放能力（如实说明）────────────────────────
          AppleGroupedSection(
            header: '播放信息',
            footer: '应用内播放使用设备本地解码，不经过网页容器。'
                '视频直链由平台签发，具有有效期，过期后需重新获取。',
            children: [
              AppleListRow(
                leadingIcon: Icons.play_circle_outline_rounded,
                title: '播放方式',
                trailingText: _playbackModeLabel(),
              ),
              if (caps != null) ...[
                AppleListRow(
                  leadingIcon: Icons.speed_rounded,
                  title: '可调节倍速',
                  trailingText: caps.canSetRate ? '支持' : '不支持',
                ),
                AppleListRow(
                  leadingIcon: Icons.timeline_rounded,
                  title: '可拖动进度',
                  trailingText: caps.canSeek ? '支持' : '不支持',
                ),
              ],
              if (v.width != null && v.height != null)
                AppleListRow(
                  leadingIcon: Icons.aspect_ratio_rounded,
                  title: '视频分辨率',
                  trailingText: '${v.width}×${v.height}',
                ),
              if (v.durationLabel != null)
                AppleListRow(
                  leadingIcon: Icons.schedule_rounded,
                  title: '时长',
                  trailingText: v.durationLabel!,
                ),
            ],
          ),

          const SizedBox(height: AppleSpace.lg),

          // ── 诊断（受限说明）────────────────────────────
          if (v.diagnostics.limitations.isNotEmpty)
            AppleGroupedSection(
              header: '当前环境限制',
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppleSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final l in v.diagnostics.limitations)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '· ',
                                style: AppleType.footnote.copyWith(
                                  color: c.secondaryLabel,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  l,
                                  style: AppleType.footnote.copyWith(
                                    color: c.secondaryLabel,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),

          const SizedBox(height: AppleSpace.xl),

          // ── 原平台入口 ────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
            ),
            child: AppleSecondaryButton(
              label: '在原平台打开',
              icon: Icons.open_in_new_rounded,
              expand: true,
              onPressed: () => widget.onOpenOriginal?.call(widget.video),
            ),
          ),
        ],
      ),
    );
  }

  String _playbackModeLabel() {
    final s = _source;
    if (s == null) return '未解析';
    return switch (s) {
      NativePlaybackSource() => '应用内播放',
      OfficialEmbedPlaybackSource() => '官方嵌入',
      ExternalPlaybackSource() => '跳转原平台',
    };
  }

  static String _fmtCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  static String _fmtDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

/// 毛玻璃返回按钮。
class _GlassBackButton extends StatelessWidget {
  const _GlassBackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppleSpace.sm),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 播放器内的胶囊按钮。
class _PlayerPillButton extends StatelessWidget {
  const _PlayerPillButton({
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
          horizontal: AppleSpace.lg,
          vertical: AppleSpace.sm,
        ),
        decoration: BoxDecoration(
          color: filled ? Colors.white : Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppleRadius.pill),
        ),
        child: Text(
          label,
          style: AppleType.buttonSmall.copyWith(
            fontSize: 13,
            color: filled ? Colors.black : Colors.white,
          ),
        ),
      ),
    );
  }
}
