/// Apple 风格视频组件。
///
/// 包含：视频缩略卡（网格/列表）、平台来源标识、时长与统计标签、
/// 播放器控制条（自绘，基于 media_kit 内核）。
library;

import 'package:flutter/material.dart';

import '../../models/playback.dart';
import '../../models/unified_video.dart';
import '../apple_tokens.dart';

/// 平台来源的视觉标识。
///
/// 使用**中性色阶 + 首字符号**，不使用平台 Logo 与品牌色。
/// 这样多平台内容在同一界面中保持视觉统一，也不会产生商标使用问题。
class PlatformChip extends StatelessWidget {
  const PlatformChip({
    super.key,
    required this.platformId,
    this.compact = false,
    this.onDark = false,
  });

  final String platformId;
  final bool compact;

  /// 是否置于深色背景上（视频画面内）。
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final symbol = _symbolOf(platformId);
    final name = _nameOf(platformId);

    final bg = onDark
        ? Colors.white.withValues(alpha: 0.16)
        : c.fill;
    final fg = onDark ? Colors.white : c.secondaryLabel;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppleRadius.xs - 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            symbol,
            style: AppleType.caption2.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: fg,
              height: 1.2,
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 4),
            Text(
              name,
              style: AppleType.caption2.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                color: fg,
                height: 1.2,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _symbolOf(String platformId) => switch (platformId) {
        'bilibili' => '哔',
        'douyin' => '抖',
        'tiktok' => 'TK',
        'mock' => '测',
        _ => platformId.isNotEmpty ? platformId[0].toUpperCase() : '?',
      };

  static String _nameOf(String platformId) => switch (platformId) {
        'bilibili' => '哔哩哔哩',
        'douyin' => '抖音',
        'tiktok' => 'TikTok',
        'mock' => '测试',
        _ => platformId,
      };
}

/// 视频缩略卡（网格布局用，竖版封面）。
class VideoGridCard extends StatelessWidget {
  const VideoGridCard({
    super.key,
    required this.video,
    this.onTap,
    this.onLongPress,
  });

  final UnifiedVideo video;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面
          AspectRatio(
            aspectRatio: 16 / 10,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppleRadius.sm),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _CoverImage(url: video.coverUrl),
                  // 底部渐变，保证时长标签可读
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 32,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 时长
                  if (video.durationLabel != null)
                    Positioned(
                      right: 6,
                      bottom: 5,
                      child: Text(
                        video.durationLabel!,
                        style: AppleType.caption2.copyWith(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          shadows: const [
                            Shadow(color: Color(0x99000000), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  // 平台标识
                  Positioned(
                    left: 6,
                    top: 6,
                    child: PlatformChip(
                      platformId: video.platformId,
                      compact: true,
                      onDark: true,
                    ),
                  ),
                  // 时长类型标记
                  if (video.durationSeconds != null && video.durationSeconds! >= 600)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '长视频',
                          style: AppleType.caption2.copyWith(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppleSpace.sm),
          // 标题
          Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppleType.subheadline.copyWith(
              color: c.label,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 3),
          // 作者 + 统计
          Row(
            children: [
              Expanded(
                child: Text(
                  video.author.name ?? '未知作者',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppleType.caption1.copyWith(color: c.secondaryLabel),
                ),
              ),
              if (video.stats.viewCount != null) ...[
                const SizedBox(width: 6),
                Text(
                  _formatCount(video.stats.viewCount!),
                  style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
                ),
              ],
            ],
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

/// 视频横向列表卡（用于"继续观看"、搜索结果）。
class VideoListTile extends StatelessWidget {
  const VideoListTile({
    super.key,
    required this.video,
    this.onTap,
    this.progress,
    this.trailing,
  });

  final UnifiedVideo video;
  final VoidCallback? onTap;

  /// 观看进度 0..1（用于"继续观看"）。
  final double? progress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.lg,
          vertical: AppleSpace.sm + 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图
            SizedBox(
              width: 132,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppleRadius.xs),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _CoverImage(url: video.coverUrl),
                      if (progress != null && progress! > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: progress!.clamp(0.0, 1.0),
                            minHeight: 2.5,
                            backgroundColor: Colors.white.withValues(alpha: 0.3),
                            valueColor: AlwaysStoppedAnimation(c.blue),
                          ),
                        ),
                      if (video.durationLabel != null)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              video.durationLabel!,
                              style: AppleType.caption2.copyWith(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppleSpace.md),
            // 文字信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.subheadline.copyWith(
                      color: c.label,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.author.name ?? '未知作者',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.caption1.copyWith(color: c.secondaryLabel),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      PlatformChip(platformId: video.platformId, compact: true),
                      if (video.stats.viewCount != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${VideoGridCard._formatCount(video.stats.viewCount!)}次播放',
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
            if (trailing != null) ...[
              const SizedBox(width: AppleSpace.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 封面图（带占位与失败回退）。
class _CoverImage extends StatelessWidget {
  const _CoverImage({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    if (url == null || url!.isEmpty) {
      return Container(
        color: c.fill,
        child: Icon(
          Icons.play_circle_outline_rounded,
          size: 28,
          color: c.tertiaryLabel,
        ),
      );
    }

    return Image.network(
      url!,
      fit: BoxFit.cover,
      // B 站图床需要 Referer，部分节点直接放行
      headers: const {'Referer': 'https://www.bilibili.com/'},
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(color: c.fill);
      },
      errorBuilder: (context, error, stack) => Container(
        color: c.fill,
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 24,
          color: c.tertiaryLabel,
        ),
      ),
    );
  }
}

/// 播放器控制条（自绘，覆盖在视频画面上）。
///
/// 设计要点：
///  - 半透明渐变底，不遮挡画面中心
///  - 进度条细，可拖动
///  - 控件按实际能力显示（不虚构）
class PlayerControlBar extends StatelessWidget {
  const PlayerControlBar({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.seekPreview,
    this.subtitleMenu,
    this.volume,
    this.onVolumeChanged,
    this.rate,
    this.onRateChanged,
    this.qualities,
    this.currentQuality,
    this.onQualityChanged,
    this.onFullscreen,
    this.onPictureInPicture,
    this.pipActive = false,
    this.title,
    this.subtitle,
    this.trailing,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  /// 拖动进度条时浮出的缩略图。参数是**当前拖到的秒数**，返回 null 就不显示。
  /// 为 null 时进度条行为与原来完全一致（平台没给拼图数据就别传）。
  final Widget? Function(double seconds)? seekPreview;

  /// 字幕选择菜单（平台给得出字幕列表时才传）。为 null 时不显示字幕按钮。
  final Widget? subtitleMenu;

  final double? volume;
  final ValueChanged<double>? onVolumeChanged;
  final double? rate;
  final ValueChanged<double>? onRateChanged;
  final List<PlaybackQuality>? qualities;
  final PlaybackQuality? currentQuality;
  final ValueChanged<PlaybackQuality>? onQualityChanged;
  final VoidCallback? onFullscreen;

  /// 进入画中画。为 null 时不渲染小窗按钮（平台不支持就不出现，
  /// 而不是出现一个点了没反应的按钮）。
  final VoidCallback? onPictureInPicture;

  /// 当前是否已在画中画。
  final bool pipActive;
  final String? title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final posMs = position.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 0);
    final bufMs = buffered.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 0);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.75),
          ],
        ),
      ),
      padding: const EdgeInsets.only(
        left: AppleSpace.lg,
        right: AppleSpace.lg,
        top: AppleSpace.xxxl,
        bottom: AppleSpace.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppleType.subheadlineEmphasized.copyWith(color: Colors.white),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppleType.caption1.copyWith(
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
            const SizedBox(height: AppleSpace.md),
          ],
          // 进度条
          _ProgressScrubber(
            position: posMs,
            duration: totalMs,
            buffered: bufMs,
            onSeek: onSeek,
            onSeekStart: onSeekStart,
            onSeekEnd: onSeekEnd,
            previewBuilder: seekPreview,
          ),
          const SizedBox(height: AppleSpace.xs),
          // 时间
          Row(
            children: [
              Text(
                _fmt(position),
                style: AppleType.caption2.copyWith(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                ' / ${_fmt(duration)}',
                style: AppleType.caption2.copyWith(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppleSpace.sm),
          // 控件行
          Row(
            children: [
              _CtlIcon(
                icon: isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                onTap: onPlayPause,
                size: 28,
              ),
              const Spacer(),
              // 字幕（平台给得出字幕列表时才出现，见详情页的取数逻辑）
              if (subtitleMenu != null) subtitleMenu!,
              // 倍速
              if (rate != null && onRateChanged != null)
                _RateMenu(
                  rate: rate!,
                  onChanged: onRateChanged!,
                ),
              // 清晰度
              if (qualities != null &&
                  qualities!.length > 1 &&
                  onQualityChanged != null)
                _QualityMenu(
                  qualities: qualities!,
                  current: currentQuality,
                  onChanged: onQualityChanged!,
                ),
              // 音量
              if (volume != null && onVolumeChanged != null)
                _VolumeMenu(
                  volume: volume!,
                  onChanged: onVolumeChanged!,
                ),
              if (onPictureInPicture != null)
                _CtlIcon(
                  icon: pipActive
                      ? Icons.picture_in_picture_alt_rounded
                      : Icons.picture_in_picture_alt_outlined,
                  onTap: onPictureInPicture!,
                  size: 24,
                ),
              if (onFullscreen != null)
                _CtlIcon(
                  icon: Icons.fullscreen_rounded,
                  onTap: onFullscreen!,
                  size: 24,
                ),
              if (trailing != null) trailing!,
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// 可拖动进度条（带缓冲显示）。
class _ProgressScrubber extends StatefulWidget {
  const _ProgressScrubber({
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.previewBuilder,
  });

  final int position;
  final int duration;
  final int buffered;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  /// 拖动时在指针上方浮出的预览。参数是**当前拖到的秒数**，返回 null 不显示。
  final Widget? Function(double seconds)? previewBuilder;

  @override
  State<_ProgressScrubber> createState() => _ProgressScrubberState();
}

/// 预览浮层宽度（拼图单格 480×270 等比到 168 宽）。
///
/// 写死是为了让"夹在轨道内"的定位可被单测断言，
/// 不依赖 builder 具体返回什么。
const double kSeekPreviewWidth = 168;

/// 让预览水平中心落在进度指针上，并夹在轨道 [0, trackWidth-width] 内。
double seekPreviewLeft(double trackWidth, double progress) {
  final center = trackWidth * progress;
  final max = (trackWidth - kSeekPreviewWidth).clamp(0.0, double.infinity);
  return (center - kSeekPreviewWidth / 2).clamp(0.0, max);
}

class _ProgressScrubberState extends State<_ProgressScrubber> {
  bool _dragging = false;
  double _dragValue = 0;

  @override
  Widget build(BuildContext context) {
    final max = widget.duration > 0 ? widget.duration.toDouble() : 1.0;
    final pos = _dragging
        ? _dragValue
        : widget.position.toDouble().clamp(0.0, max);
    final buf = widget.buffered.toDouble().clamp(0.0, max);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final progress = max > 0 ? (pos / max).clamp(0.0, 1.0) : 0.0;
        final bufProgress = max > 0 ? (buf / max).clamp(0.0, 1.0) : 0.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            setState(() {
              _dragging = true;
              _dragValue = pos;
            });
            widget.onSeekStart?.call();
          },
          onHorizontalDragUpdate: (d) {
            setState(() {
              _dragValue = (_dragValue + d.delta.dx / w * max).clamp(0.0, max);
            });
          },
          onHorizontalDragEnd: (_) {
            widget.onSeek(Duration(milliseconds: _dragValue.round()));
            setState(() => _dragging = false);
            widget.onSeekEnd?.call();
          },
          onTapDown: (d) {
            final v = (d.localPosition.dx / w * max).clamp(0.0, max);
            widget.onSeek(Duration(milliseconds: v.round()));
          },
          child: SizedBox(
            height: 22,
            child: Center(
              child: Stack(
                alignment: Alignment.centerLeft,
                // 预览浮层画在轨道**上方**（22px 之外），必须关掉裁剪，
                // 否则会被这个矮 Stack 直接切掉看不见。
                clipBehavior: Clip.none,
                children: [
                  // 轨道
                  Container(
                    height: _dragging ? 5 : 3,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // 缓冲
                  FractionallySizedBox(
                    widthFactor: bufProgress,
                    child: Container(
                      height: _dragging ? 5 : 3,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // 进度
                  FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(
                      height: _dragging ? 5 : 3,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // 拖拽圆点
                  if (_dragging)
                    Positioned(
                      left: (w * progress - 6).clamp(0.0, w - 12),
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Color(0x40000000), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  // 拖动预览：浮在指针上方（clipBehavior 已放行溢出）。
                  // previewBuilder 为空时一个像素都不占，行为与原来一致。
                  if (_dragging && widget.previewBuilder != null)
                    Positioned(
                      bottom: 30,
                      left: seekPreviewLeft(w, progress),
                      child: widget.previewBuilder!(pos / 1000.0) ??
                          const SizedBox.shrink(),
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

/// 控制图标。
class _CtlIcon extends StatelessWidget {
  const _CtlIcon({required this.icon, required this.onTap, this.size = 22});

  final IconData icon;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: size, color: Colors.white),
      ),
    );
  }
}

/// 倍速菜单。
class _RateMenu extends StatelessWidget {
  const _RateMenu({required this.rate, required this.onChanged});

  final double rate;
  final ValueChanged<double> onChanged;

  static const _options = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: '倍速',
      initialValue: rate,
      onSelected: onChanged,
      color: const Color(0xE61C1C1E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadius.sm),
      ),
      itemBuilder: (context) => [
        for (final r in _options)
          PopupMenuItem(
            value: r,
            height: 40,
            child: Row(
              children: [
                if (r == rate)
                  const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(
                  r == 1.0 ? '正常' : '${r}x',
                  style: AppleType.footnote.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(
          rate == 1.0 ? '1x' : '${rate}x',
          style: AppleType.caption1.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 清晰度菜单。
class _QualityMenu extends StatelessWidget {
  const _QualityMenu({
    required this.qualities,
    required this.current,
    required this.onChanged,
  });

  final List<PlaybackQuality> qualities;
  final PlaybackQuality? current;
  final ValueChanged<PlaybackQuality> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<PlaybackQuality>(
      tooltip: '清晰度',
      onSelected: onChanged,
      color: const Color(0xE61C1C1E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadius.sm),
      ),
      itemBuilder: (context) => [
        for (final q in qualities)
          PopupMenuItem(
            value: q,
            height: 40,
            child: Row(
              children: [
                if (q == current)
                  const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(
                  q.label,
                  style: AppleType.footnote.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(
          current?.label ?? '清晰度',
          style: AppleType.caption1.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 音量菜单。
class _VolumeMenu extends StatelessWidget {
  const _VolumeMenu({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final icon = volume <= 0
        ? Icons.volume_off_rounded
        : volume < 50
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;

    return PopupMenuButton<void>(
      tooltip: '音量',
      color: const Color(0xE61C1C1E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadius.sm),
      ),
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          height: 48,
          child: SizedBox(
            width: 160,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: volume.clamp(0, 100),
                max: 100,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Icon(icon, size: 22, color: Colors.white),
      ),
    );
  }
}
