/// 应用主框架：底部导航栏 + 页面切换。
///
/// 结构（对应 Apple 风格的信息架构）：
///  1. 推荐 —— 全屏竖滑短视频流（沉浸式，导航栏默认隐藏）
///  2. 发现 —— 长视频浏览、分类、搜索（浅色列表界面）
///  3. 直播 —— 直播列表与直播间（可选）
///  4. 设置 —— 账号与平台管理
///
/// 直播页是**可选**的：只有当接入的平台声明 supportsLive 时才注入，
/// 否则导航栏保持三项，避免出现点了没内容的空页面。
///
/// # 短视频页的导航栏交互（本次改造）
///
/// 短视频是内容消费场景，导航栏常驻会持续遮挡画面。因此：
///  - **默认隐藏**，视频占满全屏
///  - **向下滑动显示**，**向上滑动隐藏**
///  - 显示/隐藏带轻量位移动画 + 淡入淡出，不突兀闪现
///
/// ## 为什么不直接拦截 PageView 的滑动手势
///
/// 竖滑流本身就在用垂直滑动切视频。若把导航栏手势也塞进同一套
/// 手势竞技场（GestureDetector），两个识别器会互相争抢，
/// 表现为"要么切不了视频、要么导航栏乱弹"。
///
/// 这里改用 [Listener]（原始指针事件）：它**不参与手势竞技场**，
/// 因此完全不干扰 PageView 的滚动。我们只旁路观察指针轨迹，
/// 在满足"刻意的下拉/上推"条件时才切换导航栏。
///
/// 判定条件（三条同时满足才算"刻意"）：
///  1. 位移超过 [kNavGestureMinDistance]（普通滑动切视频通常位移更大，
///     但短距离轻扫不会触发）
///  2. 垂直位移显著大于水平位移（排除横滑）
///  3. 显示导航栏时，手势必须**起于屏幕下部**（默认区域为底部 28%）。
///     这条是关键：视频区中上部的普通下滑是在切回上一条视频，
///     不应弹出导航栏。
///
/// 隐藏则宽松一些：导航栏可见时任意位置的上推都收起它。
library;

import 'package:flutter/material.dart';

import '../../design/apple_theme.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import 'nav_gesture.dart';

// 手势阈值与判定逻辑在 nav_gesture.dart（纯函数，可单元测试）。

/// 应用主框架。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.feedPage,
    required this.discoverPage,
    required this.settingsPage,
    this.livePage,
    this.initialIndex = 0,
    this.onFeedVisibilityChanged,
  });

  final Widget feedPage;
  final Widget discoverPage;
  final Widget settingsPage;

  /// 直播页（可选）。为 null 时不显示直播标签。
  final Widget? livePage;

  final int initialIndex;

  /// 推荐页是否处于可见（前台）状态。
  ///
  /// 用于让短视频流在切走时暂停播放、切回时恢复——
  /// 否则用户切到「发现」页后，视频声音仍在后台播放。
  final ValueChanged<bool>? onFeedVisibilityChanged;

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell>
    with SingleTickerProviderStateMixin {
  late int _index = widget.initialIndex;

  int get currentIndex => _index;

  /// 短视频页的导航栏是否被手势唤出。
  ///
  /// 只在 [_index] == 0 时有意义；其它页面导航栏常驻。
  bool _feedNavVisible = false;

  bool get feedNavVisible => _feedNavVisible;

  /// 当前是否真的在显示导航栏。
  bool get navBarVisible => _index != 0 || _feedNavVisible;

  /// 视频流页面：导航栏默认隐藏，以获得沉浸感。
  bool get _immersive => _index == 0;

  late final AnimationController _navAnim = AnimationController(
    vsync: this,
    duration: AppleMotion.standard,
    value: _index == 0 ? 0 : 1,
  );

  late final Animation<double> _navCurve = CurvedAnimation(
    parent: _navAnim,
    curve: AppleMotion.easeOut,
    reverseCurve: AppleMotion.accelerate,
  );

  // ── 旁路指针观察（不参与手势竞技场）──────────────────────────
  Offset? _pointerDown;
  bool _pointerMoved = false;



  void goTo(int index) {
    if (index == _index) return;
    final wasFeed = _index == 0;
    setState(() {
      _index = index;
      // 离开短视频页时收起唤出的导航栏，回来时保持隐藏（沉浸）。
      if (index != 0) _feedNavVisible = false;
    });
    if (wasFeed != (index == 0)) {
      widget.onFeedVisibilityChanged?.call(index == 0);
    }
    _syncNavAnimation();
  }

  void _setFeedNavVisible(bool visible) {
    if (_index != 0) return;
    if (_feedNavVisible == visible) return;
    setState(() => _feedNavVisible = visible);
    _syncNavAnimation();
  }

  void _syncNavAnimation() {
    if (navBarVisible) {
      _navAnim.forward();
    } else {
      _navAnim.reverse();
    }
  }

  @override
  void dispose() {
    _navAnim.dispose();
    super.dispose();
  }

  // ── 手势判定 ────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e) {
    _pointerDown = e.position;
    _pointerMoved = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pointerDown == null) return;
    final d = e.position - _pointerDown!;
    if (d.distance > kNavGestureMinDistance / 2) _pointerMoved = true;
  }

  void _onPointerUp(PointerUpEvent e) {
    final start = _pointerDown;
    _pointerDown = null;
    if (start == null || !_pointerMoved) return;

    final result = decideNavGesture(
      start: start,
      end: e.position,
      screenHeight: MediaQuery.sizeOf(context).height,
      navVisible: _feedNavVisible,
      feedPageActive: _index == 0,
    );

    switch (result) {
      case NavGestureResult.reveal:
        _setFeedNavVisible(true);
      case NavGestureResult.hide:
        _setFeedNavVisible(false);
      case NavGestureResult.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasLive = widget.livePage != null;

    final pages = <Widget>[
      widget.feedPage,
      widget.discoverPage,
      if (hasLive) widget.livePage!,
      widget.settingsPage,
    ];

    // 标签项与 pages 一一对应。直播缺席时自动收起对应标签。
    final items = <AppleTabItem>[
      const AppleTabItem(
        icon: Icons.play_circle_outline_rounded,
        activeIcon: Icons.play_circle_rounded,
        label: '推荐',
      ),
      const AppleTabItem(
        icon: Icons.explore_outlined,
        activeIcon: Icons.explore_rounded,
        label: '发现',
      ),
      if (hasLive)
        const AppleTabItem(
          icon: Icons.live_tv_outlined,
          activeIcon: Icons.live_tv_rounded,
          label: '直播',
        ),
      const AppleTabItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings_rounded,
        label: '设置',
      ),
    ];

    // 导航栏占据的垂直空间（含系统手势条）。
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final navBarSpace = AppleSize.tabBar + bottomInset;

    return Theme(
      data: _immersive ? AppleTheme.immersive() : AppleTheme.light(),
      child: Listener(
        // Listener 不参与手势竞技场，因此不会与 PageView 争抢滑动。
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: (_) {
          _pointerDown = null;
          _pointerMoved = false;
        },
        child: Scaffold(
          body: Stack(
            children: [
              // 页面主体：用 IndexedStack 保持各页面状态
              // （切换页面不会重建播放器，也不会丢失滚动位置）。
              //
              // 非短视频页面必须**为导航栏留出底部空间**，
              // 否则页面会延伸到导航栏下方，其手势区域覆盖导航栏，
              // 导致导航栏看得见但点不动。
              Positioned.fill(
                child: IndexedStack(
                  index: _index,
                  children: [
                    for (var i = 0; i < pages.length; i++)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: i == 0 ? 0 : navBarSpace,
                        ),
                        child: pages[i],
                      ),
                  ],
                ),
              ),

              // 导航栏：位移 + 淡入淡出，不做突兀闪现。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !navBarVisible,
                  child: AnimatedBuilder(
                    animation: _navCurve,
                    builder: (context, child) {
                      final t = _navCurve.value;
                      if (t == 0) return const SizedBox.shrink();
                      return Opacity(
                        opacity: t,
                        child: Transform.translate(
                          offset: Offset(
                            0,
                            navBarSlideOffset(
                              progress: t,
                              navBarSpace: navBarSpace,
                            ),
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: AppleTabBar(
                      currentIndex: _index,
                      onChanged: goTo,
                      items: items,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 为使用导航栏的页面提供底部安全内边距。
///
/// 页面内容需要避开导航栏高度，否则最后一行会被遮挡。
EdgeInsets tabBarInsets(BuildContext context) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  return EdgeInsets.only(bottom: AppleSize.tabBar + bottom);
}
