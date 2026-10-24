/// 进度条拖动预览的几何映射（B站 videoshot 拼图）。
///
/// # 数据结构（实测：101s 与 6867s 两个视频对账得出）
///
/// ```
/// GET /x/player/videoshot?aid=&index=1
/// → data.img_x_len / img_y_len      每张拼图的行列数（实测恒 10×10）
///   data.img_x_size / img_y_size    单格像素（实测 480×270）
///   data.image[]                    拼图地址（协议相对，需补 https:）
///   data.index[]                    第 i 帧对应的秒数（非均匀，约 5–8s）
/// ```
///
/// 两条硬事实，都是从数据本身推出来的，不是猜的：
///  1. **帧数 = index.length**，不是 `img_x_len × img_y_len × image.length`。
///     101s 的视频帧数 42 < 100，却仍返回 1 张整图（后 58 格是空白）——
///     按格子数算会取到空白区。
///  2. **第 f 帧在第 `f ~/ (x*y)` 张图**，格坐标 `f % (x*y)`。
///     6867s 的视频 1290 帧 / 13 张图 = 99.2，与 ⌈1290/100⌉=13 一致。
///
/// 帧间隔由视频时长自适应（短视频密、长视频疏），所以不做"每 N 秒一帧"的假设。
library;

/// 一次 videoshot 响应的解析结果。
class SpriteSheetSpec {
  const SpriteSheetSpec({
    required this.frames,
    required this.cols,
    required this.rows,
    required this.cellWidth,
    required this.cellHeight,
    required this.sheetUrls,
  });

  /// 每帧的时间点（秒），升序但**间隔非均匀**，首帧可能有重复 0。
  final List<double> frames;

  /// 单张拼图的列数 / 行数。
  final int cols;
  final int rows;

  /// 单格像素尺寸。
  final int cellWidth;
  final int cellHeight;

  /// 拼图地址（已补全 https:）。
  final List<String> sheetUrls;

  int get framesPerSheet => cols * rows;
  int get frameCount => frames.length;
  double get totalSeconds => frames.isEmpty ? 0 : frames.last;
  bool get isEmpty => frames.isEmpty || sheetUrls.isEmpty;

  /// 解析 `/x/player/videoshot` 的响应体。任何字段缺失都返回 null，
  /// 不猜默认值——宁可没有预览，也不要画错帧。
  static SpriteSheetSpec? parse(Map<String, Object?> json) {
    final data = json['data'];
    if (data is! Map) return null;
    final d = Map<String, Object?>.from(data);

    final cols = (d['img_x_len'] as num?)?.toInt() ?? 0;
    final rows = (d['img_y_len'] as num?)?.toInt() ?? 0;
    final cw = (d['img_x_size'] as num?)?.toInt() ?? 0;
    final ch = (d['img_y_size'] as num?)?.toInt() ?? 0;
    if (cols <= 0 || rows <= 0 || cw <= 0 || ch <= 0) return null;

    final rawIndex = d['index'];
    if (rawIndex is! List || rawIndex.isEmpty) return null;
    final frames = rawIndex
        .map((e) => e is num ? e.toDouble() : double.tryParse('$e'))
        .whereType<double>()
        .toList(growable: false);
    if (frames.isEmpty) return null;

    final rawImage = d['image'];
    if (rawImage is! List || rawImage.isEmpty) return null;
    final urls = rawImage
        .map((e) => _absolutize('$e'))
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    if (urls.isEmpty) return null;

    return SpriteSheetSpec(
      frames: frames,
      cols: cols,
      rows: rows,
      cellWidth: cw,
      cellHeight: ch,
      sheetUrls: urls,
    );
  }

  static String _absolutize(String raw) {
    final t = raw.trim();
    if (t.startsWith('//')) return 'https:$t';
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    return '';
  }
}

/// 帧在拼图上的位置。
class SpriteCell {
  const SpriteCell({
    required this.sheetIndex,
    required this.sheetUrl,
    required this.rect,
  });

  /// 第几张拼图（越界时已回绕到最后一张）。
  final int sheetIndex;
  final String sheetUrl;

  /// 该帧在拼图内的像素矩形。
  final SpriteRect rect;
}

/// 单格在拼图内的像素矩形（`dart:ui` 的 Rect 同名会打架，故独立命名）。
class SpriteRect {
  const SpriteRect(this.left, this.top, this.width, this.height);
  final double left;
  final double top;
  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      other is SpriteRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'SpriteRect($left,$top,$width x $height)';
}

/// 找到覆盖 [seconds] 的帧下标。
///
/// 用二分（帧表升序）。落在两帧之间时返回**不超过它的那一帧**——
/// 预览宁可显示刚过去的那一幕，也不要显示未来的内容。
/// 早于首帧返回 0。
int frameIndexAt(SpriteSheetSpec spec, double seconds) {
  final frames = spec.frames;
  if (frames.isEmpty) return 0;
  if (seconds <= frames.first) return 0;
  if (seconds >= frames.last) return frames.length - 1;
  var lo = 0, hi = frames.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (frames[mid] <= seconds) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// 帧下标 → 拼图位置。
///
/// 越界保护：帧数超过 `格数 × 图数` 时（平台偶尔多给帧）
/// 一律夹到已有图的格范围内，保证偏移量恒在图内。
SpriteCell cellFor(SpriteSheetSpec spec, int frameIndex) {
  final perSheet = spec.framesPerSheet;
  final maxFrame = perSheet * spec.sheetUrls.length - 1;
  final i = frameIndex.clamp(0, maxFrame);
  final sheet = (i ~/ perSheet).clamp(0, spec.sheetUrls.length - 1);
  final slot = i % perSheet;
  return SpriteCell(
    sheetIndex: sheet,
    sheetUrl: spec.sheetUrls[sheet],
    rect: SpriteRect(
      ((slot % spec.cols) * spec.cellWidth).toDouble(),
      ((slot ~/ spec.cols) * spec.cellHeight).toDouble(),
      spec.cellWidth.toDouble(),
      spec.cellHeight.toDouble(),
    ),
  );
}
