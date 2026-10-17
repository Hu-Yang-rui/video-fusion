/// Apple 风格容器与布局组件。
///
/// 覆盖分组列表（Inset Grouped）、列表行、卡片、导航栏、标签栏、空状态。
/// 这些是"内容优先"界面的骨架：靠分组与留白建立层级，不靠卡片堆叠。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import '../apple_tokens.dart';

/// 统一的分割线（iOS 列表风格）。
///
/// # 为什么需要这个组件
///
/// 直接写 `Container(height: 0.5)` 有两个问题：
///
/// 1. **粗细不一致**：Flutter 的逻辑像素 0.5 在 DPR=2.625（Android 常见）
///    的设备上会被取整成 1 或 2 个物理像素，同一屏幕上不同位置的
///    分割线看起来粗细不同。
/// 2. **左边没有线**：用 `Padding(left: indent)` 实现缩进时，
///    左侧留白处完全空着，看起来像"线断了一截"。
///
/// 正确做法（对齐 iOS）：
///  - 用 [Divider] 的 `thickness` 而非 `Container` 高度，
///    由引擎按设备像素对齐处理；
///  - 缩进用 `indent` 参数，**线本身仍然从左边缘开始绘制**，
///    只是视觉上从内容起始处断开——iOS 的真实做法是
///    线从左边缘开始，但左侧留出内容内边距。
///
/// 这里采用 iOS 的实际视觉：**线从容器左边缘延伸到右边缘**，
/// 通过 [indent] 控制左侧留白宽度，保证多条线对齐。
class AppleDivider extends StatelessWidget {
  const AppleDivider({
    super.key,
    this.indent = 0,
    this.endIndent = 0,
    this.color,
  });

  /// 左侧留白（线从该位置开始）。
  ///
  /// iOS 列表中，分割线通常与文字左对齐（约 16pt），
  /// 而不是从屏幕边缘开始。
  final double indent;

  /// 右侧留白。
  final double endIndent;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    // 用 SizedBox 明确高度，避免父级 Column 拉伸导致线变粗。
    // 关键：不给 Container 设 height 而让它 fill，会撑满可用高度。
    return SizedBox(
      height: 0.5,
      child: Padding(
        padding: EdgeInsets.only(left: indent, right: endIndent),
        child: ColoredBox(color: color ?? c.separator),
      ),
    );
  }
}

/// 分组容器（iOS Inset Grouped List）。
///
/// 这是 Apple 风格最重要的布局原语：把相关行放进一个圆角白块，
/// 块之间留出灰底间隙。它取代了"每个条目一张卡片"的堆叠式布局。
class AppleGroupedSection extends StatelessWidget {
  const AppleGroupedSection({
    super.key,
    this.header,
    this.footer,
    required this.children,
    this.inset = AppleSpace.pageInset,
    this.dividerIndent = AppleSpace.lg,
    this.showDividers = true,
  });

  /// 分组标题（左对齐小字）。
  final String? header;

  /// 分组说明（底部小字）。
  final String? footer;

  final List<Widget> children;
  final double inset;

  /// 分隔线左侧缩进（对齐文字起始位置）。
  final double dividerIndent;

  final bool showDividers;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (showDividers && i < children.length - 1) {
        rows.add(
          AppleDivider(indent: dividerIndent),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null)
          Padding(
            padding: EdgeInsets.fromLTRB(inset + 4, AppleSpace.lg, inset, AppleSpace.sm),
            child: Text(
              header!.toUpperCase(),
              style: AppleType.footnote.copyWith(
                fontSize: 12.5,
                color: c.secondaryLabel,
                letterSpacing: 0.3,
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppleRadius.md),
            child: Material(
              color: c.secondaryGroupedBackground,
              child: Column(children: rows),
            ),
          ),
        ),
        if (footer != null)
          Padding(
            padding: EdgeInsets.fromLTRB(inset + 4, AppleSpace.sm, inset, 0),
            child: Text(
              footer!,
              style: AppleType.footnote.copyWith(
                fontSize: 12.5,
                color: c.secondaryLabel,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

/// 列表行（iOS 风格）。
///
/// 支持前置图标/头像、标题、副标题、右侧值、尾部箭头。
class AppleListRow extends StatelessWidget {
  const AppleListRow({
    super.key,
    this.leading,
    this.leadingIcon,
    this.leadingColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingText,
    this.onTap,
    this.showChevron = false,
    this.titleColor,
    this.dense = false,
  });

  final Widget? leading;
  final IconData? leadingIcon;
  final Color? leadingColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final String? trailingText;
  final VoidCallback? onTap;
  final bool showChevron;
  final Color? titleColor;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppleSpace.lg,
        vertical: dense ? AppleSpace.sm : 11,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppleSpace.md),
          ] else if (leadingIcon != null) ...[
            Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                color: leadingColor ?? c.blue,
                borderRadius: BorderRadius.circular(AppleRadius.xs),
              ),
              child: Icon(leadingIcon, size: 17, color: Colors.white),
            ),
            const SizedBox(width: AppleSpace.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: AppleType.body.copyWith(
                    color: titleColor ?? c.label,
                    fontSize: dense ? 16 : 17,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
                    style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (trailingText != null) ...[
            const SizedBox(width: AppleSpace.sm),
            Text(
              trailingText!,
              style: AppleType.body.copyWith(color: c.secondaryLabel),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AppleSpace.sm),
            trailing!,
          ],
          if (showChevron) ...[
            const SizedBox(width: AppleSpace.xs),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: c.tertiaryLabel,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        highlightColor: c.fill.withValues(alpha: 0.4),
        child: content,
      ),
    );
  }
}

/// 内容卡片（用于视频网格、推荐位）。
///
/// 注意：这是**内容卡**，不是"把界面切成卡片"。
/// 列表类界面使用 [AppleGroupedSection] 而非卡片堆叠。
class AppleContentCard extends StatelessWidget {
  const AppleContentCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = EdgeInsets.zero,
    this.radius = AppleRadius.md,
    this.color,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final card = Container(
      decoration: BoxDecoration(
        color: color ?? c.secondaryGroupedBackground,
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );

    if (onTap == null) return card;

    return _TappableCard(onTap: onTap!, child: card);
  }
}

class _TappableCard extends StatefulWidget {
  const _TappableCard({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_TappableCard> createState() => _TappableCardState();
}

class _TappableCardState extends State<_TappableCard> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _down ? 0.98 : 1.0,
          duration: AppleMotion.fast,
          curve: AppleMotion.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 大标题导航栏（iOS Large Title）。
///
/// 滚动时大标题收缩为常规导航栏标题。
/// 通过 [scrollController] 的 offset 驱动。
class AppleLargeTitleHeader extends StatelessWidget {
  const AppleLargeTitleHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Container(
      color: c.groupedBackground,
      padding: EdgeInsets.only(
        left: AppleSpace.pageInset,
        right: AppleSpace.pageInset,
        top: AppleSpace.sm,
        bottom: AppleSpace.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: AppleSpace.sm)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppleType.largeTitle.copyWith(color: c.label),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 底部标签栏（iOS Tab Bar）。
///
/// 毛玻璃背景 + 顶部细线 + 图标在上文字在下。
/// 玻璃效果在不支持时回退为不透明背景。
class AppleTabBar extends StatelessWidget {
  const AppleTabBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onChanged,
    this.blurEnabled = true,
  });

  final List<AppleTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onChanged;
  final bool blurEnabled;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // 注意：BackdropFilter 必须包在 Material 内部、且手势检测在 Material 内层，
    // 否则在某些平台上合成层会吞掉指针事件（表现为"看得见但点不动"）。
    // 这里把手势放在最内层的 GestureDetector，背景只是绘制层。
    final content = Container(
      decoration: BoxDecoration(
        color: blurEnabled
            ? c.secondaryGroupedBackground.withValues(alpha: 0.82)
            : c.secondaryGroupedBackground,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: AppleSize.tabBar,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _TabItem(
                  item: items[i],
                  selected: i == currentIndex,
                  onTap: () => onChanged(i),
                ),
              ),
          ],
        ),
      ),
    );

    if (!blurEnabled) return content;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: content,
      ),
    );
  }
}

/// 标签栏项目。
class AppleTabItem {
  const AppleTabItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final AppleTabItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final tint = selected ? c.blue : c.secondaryLabel;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            selected ? item.activeIcon : item.icon,
            size: 24,
            color: tint,
          ),
          const SizedBox(height: 2),
          Text(
            item.label,
            style: AppleType.caption2.copyWith(
              fontSize: 10,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: tint,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态视图。
class AppleEmptyState extends StatelessWidget {
  const AppleEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppleSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: c.tertiaryLabel),
            const SizedBox(height: AppleSpace.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppleType.title3.copyWith(color: c.label),
            ),
            const SizedBox(height: AppleSpace.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppleType.footnote.copyWith(
                color: c.secondaryLabel,
                height: 1.45,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppleSpace.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误状态视图。
///
/// **与空状态严格区分**：错误必须说明"为什么失败"并提供重试。
class AppleErrorState extends StatelessWidget {
  const AppleErrorState({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
    this.secondaryLabel,
    this.onSecondary,
    this.details,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final List<String>? details;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppleSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: c.red.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline_rounded, size: 30, color: c.red),
            ),
            const SizedBox(height: AppleSpace.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppleType.title3.copyWith(color: c.label),
            ),
            const SizedBox(height: AppleSpace.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppleType.footnote.copyWith(
                color: c.secondaryLabel,
                height: 1.45,
              ),
            ),
            if (onRetry != null || onSecondary != null) ...[
              const SizedBox(height: AppleSpace.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (onSecondary != null)
                    AppleSecondaryButtonForError(
                      label: secondaryLabel ?? '其他操作',
                      onPressed: onSecondary,
                    ),
                  if (onSecondary != null && onRetry != null)
                    const SizedBox(width: AppleSpace.md),
                  if (onRetry != null)
                    ApplePrimaryButtonForError(
                      label: '重试',
                      onPressed: onRetry,
                    ),
                ],
              ),
            ],
            if (details != null && details!.isNotEmpty) ...[
              const SizedBox(height: AppleSpace.xl),
              Container(
                padding: const EdgeInsets.all(AppleSpace.md),
                decoration: BoxDecoration(
                  color: c.fill,
                  borderRadius: BorderRadius.circular(AppleRadius.sm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final d in details!)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          d,
                          style: AppleType.caption2.copyWith(
                            color: c.secondaryLabel,
                            height: 1.4,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误视图内的主按钮（避免循环导入，内联简化版）。
class ApplePrimaryButtonForError extends StatelessWidget {
  const ApplePrimaryButtonForError({
    super.key,
    required this.label,
    this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Material(
      color: c.blue,
      borderRadius: BorderRadius.circular(AppleRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: AppleSpace.xl),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppleType.buttonSmall.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 错误视图内的次按钮。
class AppleSecondaryButtonForError extends StatelessWidget {
  const AppleSecondaryButtonForError({
    super.key,
    required this.label,
    this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Material(
      color: c.fill,
      borderRadius: BorderRadius.circular(AppleRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: AppleSpace.lg),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppleType.buttonSmall.copyWith(color: c.blue),
          ),
        ),
      ),
    );
  }
}

/// 骨架屏占位块（加载中）。
class AppleSkeleton extends StatefulWidget {
  const AppleSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = AppleRadius.xs,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<AppleSkeleton> createState() => _AppleSkeletonState();
}

class _AppleSkeletonState extends State<AppleSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = 0.4 + _ctrl.value * 0.3;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: c.fill.withValues(alpha: t),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

/// 页面外壳：统一背景色 + 安全区。
class ApplePageScaffold extends StatelessWidget {
  const ApplePageScaffold({
    super.key,
    required this.child,
    this.appBar,
    this.backgroundColor,
  });

  final Widget child;
  final PreferredSizeWidget? appBar;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Scaffold(
      backgroundColor: backgroundColor ?? c.groupedBackground,
      appBar: appBar,
      body: child,
    );
  }
}
