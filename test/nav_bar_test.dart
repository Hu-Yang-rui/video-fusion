/// 底部导航栏交互测试。
///
/// 覆盖：
///  - 默认隐藏（短视频页沉浸）
///  - 下滑显示 / 上滑隐藏
///  - 与视频上下切换的手势冲突（起点区域 + 位移阈值）
///  - 快速连续滑动不会导航错乱
///  - 非短视频页导航栏常驻、手势不参与
///  - 动画位移量单调
library;

import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/ui/shell/nav_gesture.dart';

/// 常见手机屏幕高度（逻辑像素），用于换算"屏幕下部区域"。
const double _h = 800;

void main() {
  group('默认隐藏：短视频页下滑唤出', () {
    test('屏幕下部下滑足够距离 → 显示导航栏', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700), // 800 * 0.72 = 576，700 在区域内
          end: const Offset(200, 780),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.reveal,
      );
    });

    test('视频区中部下滑（切回上一条）→ 不唤出导航栏', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 300), // 远高于 576
          end: const Offset(200, 700), // 位移很大，但起点不在唤出区
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.none,
        reason: '普通滑视频不能误触导航栏',
      );
    });

    test('位移不足 48pt → 不唤出（视为点击/抖动）', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 740), // 40 < 48
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.none,
      );
    });

    test('恰好 48pt 位移 → 唤出（边界包含）', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 748),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.reveal,
      );
    });

    test('起点恰在唤出区边界（0.72）→ 唤出', () {
      expect(
        decideNavGesture(
          start: const Offset(200, _h * kNavRevealZoneRatio),
          end: const Offset(200, _h * kNavRevealZoneRatio + 100),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.reveal,
      );
    });

    test('起点差 1pt 在边界外 → 不唤出', () {
      expect(
        decideNavGesture(
          start: Offset(200, _h * kNavRevealZoneRatio - 1),
          end: Offset(200, _h * kNavRevealZoneRatio - 1 + 100),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.none,
      );
    });
  });

  group('上滑隐藏', () {
    test('导航栏可见时上滑 → 隐藏', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 600),
          screenHeight: _h,
          navVisible: true,
          feedPageActive: true,
        ),
        NavGestureResult.hide,
      );
    });

    test('上滑起于任意位置都生效（收起是降低干扰的方向）', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 400),
          end: const Offset(200, 300),
          screenHeight: _h,
          navVisible: true,
          feedPageActive: true,
        ),
        NavGestureResult.hide,
      );
    });

    test('导航栏已隐藏时上滑 → 无动作（避免重复动画）', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 600),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.none,
      );
    });

    test('导航栏已显示时再下滑 → 无动作（不重复唤出）', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 790),
          screenHeight: _h,
          navVisible: true,
          feedPageActive: true,
        ),
        NavGestureResult.none,
      );
    });
  });

  group('手势冲突：与视频切换共存', () {
    test('横滑不改变导航栏', () {
      expect(
        decideNavGesture(
          start: const Offset(100, 700),
          end: const Offset(400, 720),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.none,
        reason: '水平位移大于垂直位移时不是垂直手势',
      );
    });

    test('斜向但垂直分量占优 → 仍按垂直处理', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(230, 780),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.reveal,
      );
    });

    test('非短视频页手势完全不参与', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 780),
          screenHeight: _h,
          navVisible: true,
          feedPageActive: false,
        ),
        NavGestureResult.none,
      );
    });

    test('零位移（纯点击）不改变导航栏', () {
      expect(
        decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 700),
          screenHeight: _h,
          navVisible: false,
          feedPageActive: true,
        ),
        NavGestureResult.none,
      );
    });
  });

  group('快速连续滑动：状态不震荡', () {
    test('下滑显示 → 上滑隐藏 → 下滑显示，序列正确', () {
      var visible = false;
      final down = decideNavGesture(
        start: const Offset(200, 700),
        end: const Offset(200, 780),
        screenHeight: _h,
        navVisible: visible,
        feedPageActive: true,
      );
      expect(down, NavGestureResult.reveal);
      visible = true;

      final up = decideNavGesture(
        start: const Offset(200, 780),
        end: const Offset(200, 700),
        screenHeight: _h,
        navVisible: visible,
        feedPageActive: true,
      );
      expect(up, NavGestureResult.hide);
      visible = false;

      final down2 = decideNavGesture(
        start: const Offset(200, 700),
        end: const Offset(200, 780),
        screenHeight: _h,
        navVisible: visible,
        feedPageActive: true,
      );
      expect(down2, NavGestureResult.reveal);
    });

    test('连续两次下滑只生效一次（幂等）', () {
      var visible = false;
      var reveals = 0;

      for (var i = 0; i < 2; i++) {
        final r = decideNavGesture(
          start: const Offset(200, 700),
          end: const Offset(200, 780),
          screenHeight: _h,
          navVisible: visible,
          feedPageActive: true,
        );
        if (r == NavGestureResult.reveal) {
          reveals++;
          visible = true;
        }
      }
      expect(reveals, 1, reason: '第二次下滑不应重复触发');
    });
  });

  group('动画位移', () {
    test('进度 0 → 完全在屏幕外', () {
      expect(navBarSlideOffset(progress: 0, navBarSpace: 83), 83);
    });

    test('进度 1 → 完全就位', () {
      expect(navBarSlideOffset(progress: 1, navBarSpace: 83), 0);
    });

    test('中间进度线性插值', () {
      expect(navBarSlideOffset(progress: 0.5, navBarSpace: 80), 40);
    });

    test('位移随进度单调递减', () {
      var prev = double.infinity;
      for (var p = 0.0; p <= 1.0; p += 0.1) {
        final offset = navBarSlideOffset(progress: p, navBarSpace: 83);
        expect(offset, lessThanOrEqualTo(prev),
            reason: '进度越大越接近屏幕内，位移必须单调减小');
        prev = offset;
      }
    });

    test('包含系统手势条的高度也被纳入位移', () {
      // tabBar 49 + 底部安全区 34 = 83
      expect(navBarSlideOffset(progress: 0, navBarSpace: 83), 83);
    });
  });
}
