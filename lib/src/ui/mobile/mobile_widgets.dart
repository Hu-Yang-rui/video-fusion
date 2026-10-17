/// 移动端通用组件（原创设计）。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/feed.dart';
import '../../models/unified_video.dart';
import 'mobile_theme.dart';

/// 在系统浏览器中打开链接。
///
/// 这是"跳转原平台"的实现方式：交给系统处理，
/// 应用内不嵌入任何网页。
Future<void> openInBrowser(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url], runInShell: true);
    } else if (Platform.isAndroid) {
      await Process.run('am', ['start', '-a', 'android.intent.action.VIEW',
        '-d', url]);
    } else if (Platform.isIOS || Platform.isMacOS) {
      await Process.run('open', [url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } catch (_) {
    // 打开失败不抛出；由调用方决定是否提示
  }
}

/// 平台来源角标。使用统一几何符号，不使用平台 Logo 或品牌色。
class MobilePlatformBadge extends StatelessWidget {
  const MobilePlatformBadge({
    super.key,
    required this.platformId,
    required this.label,
    this.compact = false,
  });

  final String platformId;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mark = PlatformMark.of(platformId);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? MobileTokens.s2 : MobileTokens.s3,
        vertical: compact ? 2 : MobileTokens.s1 + 1,
      ),
      decoration: BoxDecoration(
        color: mark.tint.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(MobileTokens.rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            mark.symbol,
            style: MobileText.pill.copyWith(
              color: mark.onTint,
              fontSize: compact ? 9.5 : 11,
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: MobileTokens.s1 + 1),
            Text(
              label,
              style: MobileText.pill.copyWith(color: mark.onTint),
            ),
          ],
        ],
      ),
    );
  }
}

/// 底部弹出的选择面板（内容来源切换等）。
class MobilePickerSheet<T> extends StatelessWidget {
  const MobilePickerSheet({
    super.key,
    required this.title,
    required this.items,
    required this.labelOf,
    required this.onSelected,
    this.subtitleOf,
    this.enabledOf,
    this.selected,
    this.emptyHint,
  });

  final String title;
  final List<T> items;
  final String Function(T) labelOf;
  final String? Function(T)? subtitleOf;
  final bool Function(T)? enabledOf;
  final T? selected;
  final void Function(T) onSelected;
  final String? emptyHint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: MobileTokens.s3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: MobileTokens.lightBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: MobileTokens.s4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MobileTokens.s5),
            child: Row(
              children: [
                Text(title, style: MobileText.listTitle),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded,
                      size: 20, color: MobileTokens.inkTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(height: MobileTokens.s2),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(MobileTokens.s6),
              child: Text(
                emptyHint ?? '暂无可选项。',
                style: MobileText.body,
                textAlign: TextAlign.center,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: MobileTokens.s6),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  final enabled = enabledOf?.call(item) ?? true;
                  final isSelected = selected != null && item == selected;
                  return _PickerRow(
                    label: labelOf(item),
                    subtitle: subtitleOf?.call(item),
                    enabled: enabled,
                    selected: isSelected,
                    onTap: enabled
                        ? () {
                            Navigator.of(context).maybePop();
                            onSelected(item);
                          }
                        : null,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.label,
    this.subtitle,
    required this.enabled,
    required this.selected,
    this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool enabled;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTokens.s5,
          vertical: MobileTokens.s3 + 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: MobileText.body.copyWith(
                          fontSize: 14.5,
                          color: enabled
                              ? MobileTokens.ink
                              : MobileTokens.inkTertiary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (!enabled) ...[
                        const SizedBox(width: MobileTokens.s2),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: MobileTokens.s2,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: MobileTokens.lightBorder,
                            borderRadius:
                                BorderRadius.circular(MobileTokens.rPill),
                          ),
                          child: Text(
                            '不可用',
                            style: MobileText.pill.copyWith(
                              color: MobileTokens.inkTertiary,
                              fontSize: 9.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: MobileTokens.s1),
                    Text(
                      subtitle!,
                      style: MobileText.caption.copyWith(height: 1.5),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded,
                  size: 18, color: MobileTokens.accent),
          ],
        ),
      ),
    );
  }
}

/// 移动端错误卡片。
class MobileErrorCard extends StatelessWidget {
  const MobileErrorCard({
    super.key,
    required this.title,
    required this.detail,
    this.onRetry,
    this.onSecondary,
    this.secondaryLabel,
    this.extra,
  });

  final String title;
  final String detail;
  final VoidCallback? onRetry;
  final VoidCallback? onSecondary;
  final String? secondaryLabel;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MobileTokens.s4),
      decoration: BoxDecoration(
        color: MobileTokens.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(MobileTokens.rCard),
        border: Border.all(color: MobileTokens.danger.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 17, color: MobileTokens.danger),
              const SizedBox(width: MobileTokens.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: MobileText.label.copyWith(
                        color: MobileTokens.danger,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: MobileTokens.s1),
                    Text(detail, style: MobileText.body.copyWith(fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          if (extra != null) ...[
            const SizedBox(height: MobileTokens.s3),
            extra!,
          ],
          if (onRetry != null || onSecondary != null) ...[
            const SizedBox(height: MobileTokens.s3),
            Row(
              children: [
                if (onRetry != null)
                  _SmallButton(
                    label: '重试',
                    icon: Icons.refresh_rounded,
                    primary: true,
                    onTap: onRetry!,
                  ),
                if (onRetry != null && onSecondary != null)
                  const SizedBox(width: MobileTokens.s2),
                if (onSecondary != null)
                  _SmallButton(
                    label: secondaryLabel ?? '其他操作',
                    icon: Icons.open_in_new_rounded,
                    onTap: onSecondary!,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MobileTokens.rControl),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTokens.s4,
          vertical: MobileTokens.s2 + 2,
        ),
        decoration: BoxDecoration(
          color: primary ? MobileTokens.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(MobileTokens.rControl),
          border: primary
              ? null
              : Border.all(color: MobileTokens.lightBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: primary ? const Color(0xFF06231F) : MobileTokens.inkSecondary,
            ),
            const SizedBox(width: MobileTokens.s1 + 2),
            Text(
              label,
              style: MobileText.label.copyWith(
                color:
                    primary ? const Color(0xFF06231F) : MobileTokens.inkSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空状态。
class MobileEmptyState extends StatelessWidget {
  const MobileEmptyState({
    super.key,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MobileTokens.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: MobileTokens.lightSurface,
                borderRadius: BorderRadius.circular(MobileTokens.rCard),
                border: Border.all(color: MobileTokens.lightBorder),
              ),
              child: const Icon(Icons.video_library_outlined,
                  size: 26, color: MobileTokens.inkTertiary),
            ),
            const SizedBox(height: MobileTokens.s5),
            Text(title, style: MobileText.listTitle, textAlign: TextAlign.center),
            const SizedBox(height: MobileTokens.s2),
            Text(
              description,
              style: MobileText.body.copyWith(fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: MobileTokens.s5),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: MobileTokens.accent,
                  foregroundColor: const Color(0xFF06231F),
                  padding: const EdgeInsets.symmetric(
                    horizontal: MobileTokens.s6,
                    vertical: MobileTokens.s3,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(MobileTokens.rControl),
                  ),
                ),
                child: Text(
                  actionLabel!,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 加载骨架（列表形态）。
class MobileSkeletonList extends StatelessWidget {
  const MobileSkeletonList({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(MobileTokens.s4),
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: MobileTokens.s3),
      itemBuilder: (_, __) => Container(
        padding: const EdgeInsets.all(MobileTokens.s3),
        decoration: BoxDecoration(
          color: MobileTokens.lightSurface,
          borderRadius: BorderRadius.circular(MobileTokens.rCard),
          border: Border.all(color: MobileTokens.lightBorder),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MobileShimmer(width: 120, height: 76),
            SizedBox(width: MobileTokens.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MobileShimmer(height: 13),
                  SizedBox(height: MobileTokens.s2),
                  MobileShimmer(height: 13, width: 150),
                  SizedBox(height: MobileTokens.s4),
                  MobileShimmer(height: 10, width: 90),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 微光骨架块。
class MobileShimmer extends StatefulWidget {
  const MobileShimmer({
    super.key,
    this.width,
    this.height,
    this.radius = 6,
  });

  final double? width;
  final double? height;
  final double radius;

  @override
  State<MobileShimmer> createState() => _MobileShimmerState();
}

class _MobileShimmerState extends State<MobileShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 + t * 2, -0.3),
              end: Alignment(t * 2, 0.3),
              colors: const [
                Color(0xFF232327),
                Color(0xFF2E2E33),
                Color(0xFF232327),
              ],
              stops: const [0.25, 0.5, 0.75],
            ),
          ),
        );
      },
    );
  }
}

/// 内容来源切换按钮（右上角）。
class FeedSourceButton extends StatelessWidget {
  const FeedSourceButton({
    super.key,
    required this.current,
    required this.onTap,
  });

  final FeedSource? current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MobileTokens.rPill),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTokens.s3,
          vertical: MobileTokens.s2,
        ),
        decoration: BoxDecoration(
          color: MobileTokens.scrim,
          borderRadius: BorderRadius.circular(MobileTokens.rPill),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              current?.label ?? '选择来源',
              style: MobileText.pill,
            ),
            const SizedBox(width: MobileTokens.s1 + 1),
            const Icon(Icons.expand_more_rounded,
                size: 15, color: MobileTokens.ink),
          ],
        ),
      ),
    );
  }
}
