/// 播放器叠加层：进度条缩略图预览 + 自绘字幕。
///
/// 只画上层给的数据，不发请求、不判断平台（取数在 `core/video_service.dart`）。
/// 缩略图必须自己裁：B站给的是一张 4800×2700 的拼图，不是 100 张小图。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/seek_preview.dart';
import '../../models/subtitles.dart';

/// 拖动进度条时浮出的缩略图（B站 videoshot 拼图的某一格）。
///
/// [loader] 按拼图序号取已解码的整图；同一格内反复拖动不重复取。
/// 取不到（网络失败/正在加载）就返回 `SizedBox.shrink()`——
/// 预览是增强信息，宁可不显示，也不画错帧或转圈挡住操作。
class SpriteSeekPreview extends StatefulWidget {
  const SpriteSeekPreview({
    super.key,
    required this.spec,
    required this.seconds,
    required this.loader,
    this.width = 168,
  });

  final SpriteSheetSpec spec;

  /// 当前拖到的秒数。
  final double seconds;

  /// 取某张拼图的解码结果（失败返回 null）。
  final Future<ui.Image?> Function(int sheetIndex) loader;

  final double width;

  @override
  State<SpriteSeekPreview> createState() => _SpriteSeekPreviewState();
}

class _SpriteSeekPreviewState extends State<SpriteSeekPreview> {
  int? _wantedSheet;
  ui.Image? _image;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(SpriteSeekPreview old) {
    super.didUpdateWidget(old);
    _resolve();
  }

  /// 只在跨拼图时重新取图；同一张内拖动只换裁切矩形。
  void _resolve() {
    final frame = frameIndexAt(widget.spec, widget.seconds);
    final sheet = cellFor(widget.spec, frame).sheetIndex;
    if (_wantedSheet == sheet && (_image != null || _loading)) return;
    _wantedSheet = sheet;
    _image = null;
    _loading = true;
    unawaited(
      widget.loader(sheet).then(
        (img) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            if (_wantedSheet == sheet) _image = img;
          });
        },
        // 取图抛异常时也要复位，否则这一次拖动永远等不到结果。
        onError: (Object _) {
          if (!mounted) return;
          setState(() => _loading = false);
        },
      ),
    );
  }

  // 不 dispose `_image`：图由 loader 的缓存持有，这里只是借用者；
  // 在这里释放会让缓存留下死句柄，下次拖动画一张已销毁的图。

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    // 裁哪一格按**当前秒数**算；要不要重新取图只看拼图号。
    final cell = cellFor(widget.spec, frameIndexAt(widget.spec, widget.seconds));
    final ratio = cell.rect.width / cell.rect.height;
    return SizedBox(
      width: widget.width,
      height: widget.width / ratio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CustomPaint(
          painter: _SpritePainter(image: image, src: cell.rect),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _SpritePainter extends CustomPainter {
  _SpritePainter({required this.image, required this.src});

  final ui.Image image;
  final SpriteRect src;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(src.left, src.top, src.width, src.height),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_SpritePainter old) =>
      old.image != image || old.src != src;
}

/// 字幕层：居中的白字黑底，最多三行。自绘的理由见 subtitles.dart 文件头。
class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({super.key, required this.cue, this.cornerLabel});

  final SubtitleCue? cue;

  /// 右上角小字（如「字幕：中文（AI）」），让用户知道这是机器识别的。
  final String? cornerLabel;

  @override
  Widget build(BuildContext context) {
    final text = cue?.text.trim();
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 16,
      right: 16,
      bottom: 78,
      child: IgnorePointer(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        shadows: [
                          Shadow(
                            color: Colors.black54,
                            offset: Offset(0, 1),
                            blurRadius: 3,
                          ),
                        ],
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (cornerLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          cornerLabel!,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
