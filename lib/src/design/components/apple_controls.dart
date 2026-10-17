/// Apple 风格交互组件。
///
/// 覆盖按钮、分段控件、开关行、滑块等基础交互元素。
/// 所有组件读取 [AppleColors] 语义色，自动适配明暗。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../apple_tokens.dart';

/// 主按钮（填充蓝色）。
class ApplePrimaryButton extends StatelessWidget {
  const ApplePrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expand = true,
    this.loading = false,
    this.tint,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool loading;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final bg = tint ?? c.blue;
    final enabled = onPressed != null && !loading;

    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading) ...[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(width: AppleSpace.sm),
        ] else if (icon != null) ...[
          Icon(icon, size: 18, color: Colors.white),
          const SizedBox(width: AppleSpace.sm),
        ],
        Text(
          label,
          style: AppleType.button.copyWith(
            color: Colors.white,
            fontSize: 16,
          ),
        ),
      ],
    );

    return _PressScale(
      enabled: enabled,
      child: Material(
        color: enabled ? bg : bg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppleRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: Container(
            height: AppleSize.minTapTarget,
            padding: const EdgeInsets.symmetric(horizontal: AppleSpace.xl),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 次要按钮（灰色填充）。
class AppleSecondaryButton extends StatelessWidget {
  const AppleSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expand = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final fg = destructive ? c.red : c.blue;
    final enabled = onPressed != null;

    return _PressScale(
      enabled: enabled,
      child: Material(
        color: c.fill,
        borderRadius: BorderRadius.circular(AppleRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            height: AppleSize.minTapTarget,
            padding: const EdgeInsets.symmetric(horizontal: AppleSpace.lg),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 17, color: enabled ? fg : c.tertiaryLabel),
                  const SizedBox(width: AppleSpace.xs + 2),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.buttonSmall.copyWith(
                      color: enabled ? fg : c.tertiaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 纯文字按钮。
class AppleTextButton extends StatelessWidget {
  const AppleTextButton({
    super.key,
    required this.label,
    this.onPressed,
    this.color,
    this.bold = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final fg = color ?? c.blue;
    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.sm,
          vertical: AppleSpace.sm,
        ),
        child: Text(
          label,
          style: (bold ? AppleType.bodyEmphasized : AppleType.body).copyWith(
            color: onPressed == null ? c.tertiaryLabel : fg,
          ),
        ),
      ),
    );
  }
}

/// 图标按钮（44×44 触控区）。
class AppleIconButton extends StatelessWidget {
  const AppleIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.color,
    this.size = 20,
    this.tooltip,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final String? tooltip;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final fg = color ?? c.blue;

    final btn = SizedBox(
      width: AppleSize.minTapTarget,
      height: AppleSize.minTapTarget,
      child: Material(
        color: filled ? c.fill : Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Icon(
            icon,
            size: size,
            color: onPressed == null ? c.tertiaryLabel : fg,
          ),
        ),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}

/// 分段控件（iOS UISegmentedControl）。
class AppleSegmentedControl<T> extends StatelessWidget {
  const AppleSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.labelOf,
  });

  final List<T> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final String Function(T)? labelOf;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final index = segments.indexOf(selected);
    final count = segments.length;

    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(AppleRadius.xs + 1),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final segW = w / count;
          return Stack(
            children: [
              // 选中滑块
              AnimatedPositioned(
                duration: AppleMotion.fast,
                curve: AppleMotion.easeOut,
                left: index < 0 ? 0 : segW * index,
                top: 0,
                bottom: 0,
                width: segW,
                child: Container(
                  decoration: BoxDecoration(
                    color: c.isDark ? c.gray3 : Colors.white,
                    borderRadius: BorderRadius.circular(AppleRadius.xs),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  for (final seg in segments)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => onChanged(seg),
                        behavior: HitTestBehavior.opaque,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: AppleMotion.fast,
                            style: AppleType.footnote.copyWith(
                              fontWeight: seg == selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: c.label,
                            ),
                            child: Text(
                              labelOf?.call(seg) ?? '$seg',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 按压缩放反馈。
///
/// iOS 的按钮按下时整体轻微缩小（约 0.97），松开回弹。
/// 这是"克制"的反馈：不改变颜色、不加阴影。
class _PressScale extends StatefulWidget {
  const _PressScale({required this.child, required this.enabled});

  final Widget child;
  final bool enabled;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: widget.enabled ? (_) => setState(() => _down = true) : null,
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.97 : 1.0,
        duration: AppleMotion.fast,
        curve: AppleMotion.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// 开关行（列表中的 Switch）。
class AppleSwitchRow extends StatelessWidget {
  const AppleSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.lg,
        vertical: AppleSpace.sm,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: c.secondaryLabel),
            const SizedBox(width: AppleSpace.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppleType.body.copyWith(color: c.label),
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
          const SizedBox(width: AppleSpace.md),
          Transform.scale(
            scale: 0.85,
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

/// 滑杆（带触觉反馈）。
class AppleSlider extends StatelessWidget {
  const AppleSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.color,
    this.trackHeight = 4,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final Color? color;
  final double trackHeight;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final tint = color ?? c.blue;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: trackHeight,
        activeTrackColor: tint,
        inactiveTrackColor: c.fill,
        thumbColor: Colors.white,
        overlayColor: tint.withValues(alpha: 0.12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
        onChangeEnd: (v) {
          HapticFeedback.selectionClick();
          onChangeEnd?.call(v);
        },
      ),
    );
  }
}

/// 徽标（角标）。
class AppleBadge extends StatelessWidget {
  const AppleBadge({
    super.key,
    required this.text,
    this.color,
    this.filled = true,
  });

  final String text;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final tint = color ?? c.blue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: filled ? tint : tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppleRadius.pill),
      ),
      child: Text(
        text,
        style: AppleType.caption2.copyWith(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: filled ? Colors.white : tint,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 加载指示器（iOS 风格）。
class AppleSpinner extends StatelessWidget {
  const AppleSpinner({super.key, this.size = 20, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        valueColor: AlwaysStoppedAnimation(color ?? c.gray),
      ),
    );
  }
}
