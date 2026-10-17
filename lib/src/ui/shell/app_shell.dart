/// 应用主框架：底部标签栏 + 页面切换。
///
/// 结构（对应 Apple 风格的信息架构）：
///  1. 推荐 —— 全屏竖滑短视频流（沉浸式，隐藏标签栏）
///  2. 发现 —— 长视频浏览、分类、搜索（浅色列表界面）
///  3. 直播 —— 直播列表与直播间（可选的第三个页面）
///  4. 媒体库 —— 观看历史、收藏、继续观看
///  5. 设置 —— 账号与平台管理
///
/// 直播页是**可选**的：只有当接入的平台声明 supportsLive 时才注入，
/// 否则标签栏保持四项，避免出现点了没内容的空页面。
///
/// 设计要点：
///  - 标签栏使用毛玻璃，但**不在视频流内显示**（避免遮挡画面）
///  - 页面切换使用淡入淡出 + 轻微位移，不使用 Material 的默认推入
///  - 每个页面保持独立的滚动位置与状态
library;

import 'package:flutter/material.dart';

import '../../design/apple_theme.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';

/// 应用主框架。
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.feedPage,
    required this.discoverPage,
    required this.libraryPage,
    required this.settingsPage,
    this.livePage,
    this.initialIndex = 0,
  });

  final Widget feedPage;
  final Widget discoverPage;
  final Widget libraryPage;
  final Widget settingsPage;

  /// 直播页（可选）。为 null 时不显示直播标签。
  final Widget? livePage;

  final int initialIndex;

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  late int _index = widget.initialIndex;

  int get currentIndex => _index;

  /// 视频流页面需要隐藏标签栏以获得沉浸感。
  bool get _immersive => _index == 0;

  void goTo(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final hasLive = widget.livePage != null;

    final pages = <Widget>[
      widget.feedPage,
      widget.discoverPage,
      if (hasLive) widget.livePage!,
      widget.libraryPage,
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
        icon: Icons.bookmark_outline_rounded,
        activeIcon: Icons.bookmark_rounded,
        label: '媒体库',
      ),
      const AppleTabItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings_rounded,
        label: '设置',
      ),
    ];

    // 标签栏占据的垂直空间（含系统手势条）。
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final tabBarSpace = AppleSize.tabBar + bottomInset;

    return Theme(
      data: _immersive ? AppleTheme.immersive() : AppleTheme.light(),
      child: Scaffold(
        body: Stack(
          children: [
            // 页面主体：用 IndexedStack 保持各页面状态。
            //
            // 关键：非沉浸页面必须**为标签栏留出底部空间**。
            // 否则页面会延伸到标签栏下方，其手势区域覆盖标签栏，
            // 导致标签栏看得见但点不动。
            Positioned.fill(
              child: IndexedStack(
                index: _index,
                children: [
                  for (var i = 0; i < pages.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: (i == 0 || _immersive) ? 0 : tabBarSpace,
                      ),
                      child: pages[i],
                    ),
                ],
              ),
            ),
            // 标签栏（沉浸页面隐藏）
            if (!_immersive)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AppleTabBar(
                  currentIndex: _index,
                  onChanged: goTo,
                  items: items,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 为使用标签栏的页面提供底部安全内边距。
///
/// 页面内容需要避开标签栏高度，否则最后一行会被遮挡。
EdgeInsets tabBarInsets(BuildContext context) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  return EdgeInsets.only(bottom: AppleSize.tabBar + bottom);
}
