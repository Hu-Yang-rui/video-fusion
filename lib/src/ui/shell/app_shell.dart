/// 应用主框架：底部导航栏 + 页面切换。
///
/// # 信息架构（抖音式短视频结构）
///
///  1. 推荐 —— 全屏竖滑短视频流（沉浸式，导航栏默认隐藏）
///  2. 发现 —— 长视频浏览、分类、跨平台搜索
///  3. 直播 —— B站 + 抖音统一直播入口（条件显示）
///  4. 我的 —— 账号、收藏夹/稍后再看/历史等内容入口
///
/// 「设置」**不再是**一级导航项：它是低频功能，收进「我的」页的次级入口。
/// 这样一级导航全部用于内容消费，符合短视频应用的使用习惯。
///
/// 直播页是**可选**的：只有当接入的平台声明 supportsLive 时才注入，
/// 否则导航栏保持三项，避免出现点了没内容的空页面。
///
/// # 短视频页的导航栏交互
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
///
/// ## 沉浸式页面用「标签 id」而不是下标判定
///
/// 直播标签是否出现会改变页面下标。因此"是否处于沉浸式页面"
/// 一律按 [AppTab] 判断，不按 index 硬编码 —— 否则接入/移除
/// 某个直播平台后，手势规则会错位到别的页面上。
library;

import 'package:flutter/material.dart';

import '../../design/apple_theme.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import 'nav_gesture.dart';

// 手势阈值与判定逻辑在 nav_gesture.dart（纯函数，可单元测试）。

/// 一级导航的标签定义。
///
/// 用枚举而不是下标：直播是否在场会改变下标，但不会改变语义。
enum AppTab { feed, discover, drama, live, messages, profile }

/// 应用主框架。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.feedPage,
    required this.discoverPage,
    required this.profilePage,
    this.dramaPage,
    this.livePage,
    this.messagesPage,
    this.initialIndex = 0,
    this.onFeedVisibilityChanged,
  });

  final Widget feedPage;
  final Widget discoverPage;

  /// 「影视」页：短剧 / 电影 / 番剧等长内容。
  ///
  /// 与短视频推荐流分开：推荐流是沉浸式刷，影视是找剧、看剧。
  final Widget? dramaPage;

  /// 「我的」页：账号 + 内容入口 + 设置次级入口。
  final Widget profilePage;

  /// 直播页（可选）。为 null 时不显示直播标签。
  final Widget? livePage;

  /// 消息页（可选）。为 null 时不显示消息标签。
  ///
  /// 与直播同理：平台不支持私信时不渲染，避免出现点进去空白的入口。
  final Widget? messagesPage;

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

  /// 当前标签的语义。
  AppTab get currentTab => _tabs[_index];

  /// 页面顺序：推荐 / 发现 / 影视 / [直播] / [消息] / 我的。
  List<AppTab> get _tabs => [
        AppTab.feed,
        AppTab.discover,
        if (widget.dramaPage != null) AppTab.drama,
        if (widget.livePage != null) AppTab.live,
        if (widget.messagesPage != null) AppTab.messages,
        AppTab.profile,
      ];

  /// 短视频页的导航栏是否被手势唤出。
  ///
  /// 保留这个状态是为了手势逻辑不失效，但导航栏已改为**始终显示**，
  /// 不再依赖它决定可见性。
  bool _feedNavVisible = false;

  bool get feedNavVisible => _feedNavVisible;

  /// 导航栏始终显示。
  ///
  /// 此前推荐页默认隐藏、下滑才唤出，实际使用中用户找不到入口。
  /// 现在所有页面都常驻底栏。
  bool get navBarVisible => true;

  /// 沉浸式页面：无。底栏常驻后不再有沉浸页。
  bool get _immersive => false;

  /// 「我的」标签的下标（登录引导等外部动作需要按语义跳转）。
  int get profileIndex => _tabs.indexOf(AppTab.profile);

  late final AnimationController _navAnim = AnimationController(
    vsync: this,
    duration: AppleMotion.standard,
    value: 1,
  );

  late final Animation<double> _navCurve = CurvedAnimation(
    parent: _navAnim,
    curve: AppleMotion.easeOut,
    reverseCurve: AppleMotion.accelerate,
  );

  // ── 旁路指针观察（不参与手势竞技场）──────────────────────────
  Offset? _pointerDown;
  bool _pointerMoved = false;

  /// 按语义标签跳转（供 main.dart 与设置入口使用）。
  void goToTab(AppTab tab) {
    final i = _tabs.indexOf(tab);
    if (i < 0) return;
    goTo(i);
  }

  void goTo(int index) {
    if (index == _index) return;
    if (index < 0 || index >= _tabs.length) return;
    final wasFeed = currentTab == AppTab.feed;
    final tabs = _tabs;
    setState(() {
      _index = index;
      // 离开短视频页时收起唤出的导航栏，回来时保持隐藏（沉浸）。
      if (tabs[index] != AppTab.feed) _feedNavVisible = false;
    });
    final isFeed = _tabs[index] == AppTab.feed;
    if (wasFeed != isFeed) {
      widget.onFeedVisibilityChanged?.call(isFeed);
    }
    _syncNavAnimation();
  }

  void _setFeedNavVisible(bool visible) {
    if (!_immersive) return;
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
      feedPageActive: currentTab == AppTab.feed,
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
    final tabs = _tabs;

    final pages = <Widget>[
      for (final t in tabs)
        switch (t) {
          AppTab.feed => widget.feedPage,
          AppTab.discover => widget.discoverPage,
          AppTab.drama => widget.dramaPage ?? widget.discoverPage,
          AppTab.live => widget.livePage!,
          AppTab.messages => widget.messagesPage!,
          AppTab.profile => widget.profilePage,
        },
    ];

    // 标签项与 pages 一一对应。直播缺席时自动收起对应标签。
    final items = <AppleTabItem>[
      for (final t in tabs) _itemOf(t),
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
                          bottom: tabs[i] == AppTab.feed ? 0 : navBarSpace,
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

  static AppleTabItem _itemOf(AppTab tab) => switch (tab) {
        AppTab.feed => const AppleTabItem(
            icon: Icons.play_circle_outline_rounded,
            activeIcon: Icons.play_circle_rounded,
            label: '推荐',
          ),
        AppTab.discover => const AppleTabItem(
            icon: Icons.explore_outlined,
            activeIcon: Icons.explore_rounded,
            label: '发现',
          ),
        AppTab.drama => const AppleTabItem(
            icon: Icons.movie_outlined,
            activeIcon: Icons.movie_rounded,
            label: '影视',
          ),
        AppTab.live => const AppleTabItem(
            icon: Icons.live_tv_outlined,
            activeIcon: Icons.live_tv_rounded,
            label: '直播',
          ),
        AppTab.messages => const AppleTabItem(
            icon: Icons.forum_outlined,
            activeIcon: Icons.forum_rounded,
            label: '消息',
          ),
        AppTab.profile => const AppleTabItem(
            icon: Icons.person_outline_rounded,
            activeIcon: Icons.person_rounded,
            label: '我的',
          ),
      };

  /// 标签项（供测试与诊断）。
  ///
  /// 推荐/发现/我的 恒在；影视、直播与消息各自按能力条件注入。
  @visibleForTesting
  static List<AppleTabItem> itemsFor({
    required bool hasLive,
    bool hasMessages = false,
    bool hasDrama = true,
  }) =>
      [
        for (final t in [
          AppTab.feed,
          AppTab.discover,
          if (hasDrama) AppTab.drama,
          if (hasLive) AppTab.live,
          if (hasMessages) AppTab.messages,
          AppTab.profile,
        ])
          _itemOf(t),
      ];
}

/// 为使用导航栏的页面提供底部安全内边距。
///
/// 页面内容需要避开导航栏高度，否则最后一行会被遮挡。
EdgeInsets tabBarInsets(BuildContext context) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  return EdgeInsets.only(bottom: AppleSize.tabBar + bottom);
}
