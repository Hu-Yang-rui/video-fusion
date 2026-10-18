/// 底部导航栏的手势判定（纯逻辑，无 Widget 依赖）。
///
/// # 为什么单独抽出来
///
/// 短视频页本身就在用垂直滑动切视频。导航栏的下拉唤出必须与它共存，
/// 判定规则错一点就会变成"普通滑视频时导航栏乱弹"。
///
/// 这类"滑动多少算刻意、从哪开始算刻意"的阈值逻辑，写在 Widget 里
/// 就只能靠人肉试，无法回归。抽成纯函数后可以直接单测边界。
library;

import 'dart:ui' show Offset;

/// 触发导航栏手势所需的最小垂直位移（逻辑像素）。
const double kNavGestureMinDistance = 48;

/// 下拉显示导航栏时，手势起点必须落在屏幕下部这个比例之下。
///
/// 0.72 表示屏幕最下方 28% 区域。取这个值的原因：
///  - 太靠上（如 0.5）：视频区中部的普通下滑会被误判成唤出导航栏，
///    而用户本意是切回上一条视频；
///  - 太靠下（如 0.85）：拇指自然上滑的落点常常够不到，
///    用户会觉得"手势没反应"。
const double kNavRevealZoneRatio = 0.72;

/// 一次指针轨迹的判定结果。
enum NavGestureResult {
  /// 不改变导航栏状态。
  none,

  /// 显示导航栏。
  reveal,

  /// 隐藏导航栏。
  hide,
}

/// 判定一次滑动是否应当改变导航栏状态。
///
/// [start] / [end] 是屏幕坐标下的指针按下点与抬起点。
/// [screenHeight] 用于换算"屏幕下部区域"。
/// [navVisible] 当前导航栏是否可见。
/// [feedPageActive] 是否处在短视频页（其它页面导航栏常驻，无需手势）。
///
/// 判定条件：
///  1. 垂直位移超过 [kNavGestureMinDistance]
///  2. 垂直位移显著大于水平位移（排除横滑）
///  3. 下拉唤出时，起点必须落在屏幕下部 [kNavRevealZoneRatio] 区域内
///
/// 上推收起比下拉唤出宽松（任意起点），因为收起是"减少干扰"的方向，
/// 误判代价低；唤出是"增加遮挡"的方向，必须严格。
NavGestureResult decideNavGesture({
  required Offset start,
  required Offset end,
  required double screenHeight,
  required bool navVisible,
  required bool feedPageActive,
  double minDistance = kNavGestureMinDistance,
  double revealZoneRatio = kNavRevealZoneRatio,
}) {
  // 非短视频页：导航栏常驻，手势不参与。
  if (!feedPageActive) return NavGestureResult.none;

  final dy = end.dy - start.dy;
  final dx = end.dx - start.dx;

  // 排除横滑：水平位移大于垂直位移时不是垂直手势。
  if (dx.abs() > dy.abs()) return NavGestureResult.none;

  // 位移不足：视为点击或轻微抖动。
  if (dy.abs() < minDistance) return NavGestureResult.none;

  if (dy > 0) {
    // 下拉 → 唤出。必须起于屏幕下部，否则是"切回上一条视频"。
    if (navVisible) return NavGestureResult.none;
    final inZone = start.dy >= screenHeight * revealZoneRatio;
    return inZone ? NavGestureResult.reveal : NavGestureResult.none;
  }

  // 上推 → 收起。任意起点，但仅在导航栏可见时有意义。
  if (!navVisible) return NavGestureResult.none;
  return NavGestureResult.hide;
}

/// 导航栏的动画进度（0 = 完全隐藏，1 = 完全显示）。
///
/// 导航栏跟随 `AnimationController` 的曲线值，位移量为
/// `navBarSpace * (1 - progress)`，即从屏幕下方滑入。
double navBarSlideOffset({
  required double progress,
  required double navBarSpace,
}) =>
    navBarSpace * (1 - progress);
