/// 长视频详情页（Apple 风格）。
///
/// # 信息架构
///
/// 内容优先，不把每块信息包成卡片：
///
/// ```
/// ┌──────────────────────────┐
/// │  播放器（16:9，自绘控制条）  │
/// ├──────────────────────────┤
/// │  标题（大字号，视觉主体）    │
/// │  平台 · 播放数 · 日期        │
/// │                          │
/// │  ●头像  作者名              │
/// │                          │
/// │  简介正文（可展开）          │
/// │                          │
/// │  💬 查看 2129 条评论    ›   │
/// │                          │
/// │  技术信息  ›（默认收起）     │
/// │                          │
/// │  [在原平台打开]             │
/// └──────────────────────────┘
/// ```
///
/// 设计要点：
///  - 标题、元信息、作者、简介用**留白与排版**分区，不靠卡片边框
///  - 评论入口是一行可点的内容行，不是按钮
///  - 播放方式 / 分辨率 / 是否支持倍速这类**技术细节默认收起**，
///    普通用户不需要看到；需要排查时展开即可
///  - 与竖滑流的差异：这里支持完整播放、进度恢复、清晰度、全屏
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/video_widgets.dart';
import '../../models/playback.dart';
import '../../models/unified_video.dart';
import '../../player/player_controller.dart';
import '../interaction/interaction_controller.dart';
import '../interaction/interaction_widgets.dart';

/// 长视频详情页。
class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({
    super.key,
    required this.video,
    required this.service,
    this.vault,
    this.onOpenOriginal,
    this.initialPosition,
    this.onProgressChanged,
  });

  final UnifiedVideo video;
  final VideoService service;

  /// 凭证保险库。为 null 时详情页不显示评论入口
  /// （评论需要登录态判断，没有 vault 就无法确定能力）。
  final CredentialVault? vault;

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
  bool _techExpanded = false;
  Timer? _controlsTimer;

  /// 互动控制器（评论、点赞等）。仅在有 vault 时创建。
  InteractionController? _interaction;

  @override
  void initState() {
    super.initState();
    _resolveAndLoad();

    final vault = widget.vault;
    if (vault != null) {
      final ctrl = InteractionController(
        video: widget.video,
        service: widget.service,
        vault: vault,
      );
      // 异步初始化登录态，不阻塞首帧
      unawaited(ctrl.init());
      _interaction = ctrl;
    }
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
    _interaction?.dispose();
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
          // 单击画面：切换播放/暂停 + 显示控制条。
          //
          // 之前只调 _toggleControls（显隐控制条），单击画面不会暂停，
          // 与短视频页是同一个缺陷。
          //
          // 双击保留原有行为（全屏切换在别处，这里不占用双击手势），
          // 因此只注册 onTap，单击立即响应，无 300ms 判定延迟。
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                final phase = _snapshot.phase;
                if (phase == PlayerPhase.playing ||
                    phase == PlayerPhase.paused) {
                  player.playOrPause();
                  _scheduleHideControls();
                } else {
                  _toggleControls();
                }
                if (!_showControls) {
                  setState(() => _showControls = true);
                }
              },
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
  ///
  /// 内容优先：用留白与排版分区，而不是把每块信息包成卡片。
  /// 技术细节（播放方式/分辨率/倍速支持）默认收起。
  Widget _buildContent(AppleColors c) {
    final v = widget.video;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppleSpace.huge),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题与元信息（无卡片，靠排版建立层级）──────
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.pageInset,
              AppleSpace.lg,
              AppleSpace.pageInset,
              AppleSpace.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.title,
                  style: AppleType.title3.copyWith(
                    color: c.label,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: AppleSpace.sm),
                // 元信息一行，低视觉权重
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppleSpace.xs,
                  runSpacing: 4,
                  children: [
                    PlatformChip(platformId: v.platformId),
                    if (v.stats.viewCount != null)
                      _metaText(c, '${_fmtCount(v.stats.viewCount!)}次播放'),
                    if (v.publishedAt != null)
                      _metaText(c, _fmtDate(v.publishedAt!)),
                    if (v.durationLabel != null)
                      _metaText(c, v.durationLabel!),
                  ],
                ),
              ],
            ),
          ),

          // ── 作者行（无卡片）──────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
              vertical: AppleSpace.sm,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: c.fill,
                  backgroundImage: v.author.avatarUrl != null
                      ? ResizeImage.resizeIfNeeded(
                          72,
                          72,
                          NetworkImage(
                            v.author.avatarUrl!,
                            headers: const {
                              'Referer': 'https://www.bilibili.com/',
                            },
                          ),
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
                  child: Text(
                    v.author.name ?? '未知作者',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.bodyEmphasized.copyWith(color: c.label),
                  ),
                ),
              ],
            ),
          ),

          // ── 简介（无卡片）────────────────────────────
          if (v.description != null && v.description!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpace.pageInset,
                AppleSpace.sm,
                AppleSpace.pageInset,
                AppleSpace.sm,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
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
                      style: AppleType.subheadline.copyWith(
                        color: c.secondaryLabel,
                        height: 1.5,
                      ),
                    ),
                    if (v.description!.trim().length > 80) ...[
                      const SizedBox(height: 4),
                      Text(
                        _descriptionExpanded ? '收起' : '展开',
                        style: AppleType.caption1.copyWith(color: c.blue),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          const SizedBox(height: AppleSpace.sm),
          _hairline(c),

          // ── 评论入口（一行可点内容，不是按钮）────────
          if (_interaction != null)
            _buildCommentEntry(c, _interaction!),

          _hairline(c),

          // ── 技术信息（默认收起）──────────────────────
          _buildTechDisclosure(c),

          const SizedBox(height: AppleSpace.lg),

          // ── 原平台入口 ──────────────────────────────
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

  /// 元信息文字（低权重）。
  Widget _metaText(AppleColors c, String text) => Text(
        text,
        style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
      );

  /// 细分割线（内容区之间）。
  Widget _hairline(AppleColors c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppleSpace.pageInset),
        child: SizedBox(
          height: 0.5,
          child: ColoredBox(color: c.separator),
        ),
      );

  /// 评论入口。
  ///
  /// 做成"一行内容"而不是按钮：用户浏览视频时，
  /// 评论是内容的一部分，不是需要额外点击的工具。
  Widget _buildCommentEntry(AppleColors c, InteractionController ctrl) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final count = ctrl.commentTotal;
        final label = count > 0
            ? '查看 ${_fmtCount(count)} 条评论'
            : '查看评论';
        return InkWell(
          onTap: () => _openComments(ctrl),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
              vertical: AppleSpace.md,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 17,
                  color: c.secondaryLabel,
                ),
                const SizedBox(width: AppleSpace.sm),
                Expanded(
                  child: Text(
                    label,
                    style: AppleType.subheadline.copyWith(
                      color: c.label,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: c.tertiaryLabel,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openComments(InteractionController ctrl) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentSheet(controller: ctrl),
    );
  }

  /// 技术信息折叠区。
  ///
  /// 播放方式、分辨率、是否支持倍速这类信息对普通用户没有意义，
  /// 只在需要排查问题时展开。这是本次去工具化的关键改动：
  /// 之前它们直接以两整块卡片占据详情页下半屏。
  Widget _buildTechDisclosure(AppleColors c) {
    final v = widget.video;
    final caps = _player?.capabilities;
    final limitations = v.diagnostics.limitations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _techExpanded = !_techExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
              vertical: AppleSpace.md,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: c.tertiaryLabel,
                ),
                const SizedBox(width: AppleSpace.sm),
                Text(
                  '技术信息',
                  style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
                ),
                const Spacer(),
                Icon(
                  _techExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: c.tertiaryLabel,
                ),
              ],
            ),
          ),
        ),
        if (_techExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.pageInset,
              0,
              AppleSpace.pageInset,
              AppleSpace.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _techRow(c, '播放方式', _playbackModeLabel()),
                if (caps != null) ...[
                  _techRow(c, '倍速调节', caps.canSetRate ? '支持' : '不支持'),
                  _techRow(c, '拖动进度', caps.canSeek ? '支持' : '不支持'),
                ],
                if (v.width != null && v.height != null)
                  _techRow(c, '分辨率', '${v.width}×${v.height}'),
                if (limitations.isNotEmpty) ...[
                  const SizedBox(height: AppleSpace.sm),
                  for (final l in limitations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '· $l',
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _techRow(AppleColors c, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            SizedBox(
              width: 80,
              child: Text(
                label,
                style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: AppleType.caption2.copyWith(color: c.secondaryLabel),
              ),
            ),
          ],
        ),
      );

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
