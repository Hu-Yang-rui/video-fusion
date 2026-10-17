/// Apple 风格设计令牌（Design Tokens）。
///
/// 依据 Apple Human Interface Guidelines 的语义化配色与字体层级建立，
/// 不是"把主题色换成蓝色 + 加圆角"。
///
/// ## 设计原则
///  - **语义化优先**：使用 label / separator / fill / background 等语义名，
///    而不是 red1 / blue2 这类数值名。语义名让暗色适配与对比度校验成为可能。
///  - **内容优先**：视频与图片是唯一视觉主体，UI 退居其次。
///  - **层级靠留白与字重**，不靠阴影与边框堆叠。
///  - **浅色为默认**：应用外壳（导航、列表、设置）使用浅色；
///    视频播放区域使用深色，因为画面需要纯黑背景才能正确呈现对比度。
///    这不是"主题不一致"，而是与 Apple TV / 照片 App 相同的做法。
///
/// ## 数值来源
/// 色彩取自 iOS 系统语义色（Light / Dark 两套），
/// 字体层级取自 iOS Dynamic Type 的字号与字重。
library;

import 'package:flutter/material.dart';

/// 应用配色令牌。
///
/// 同时提供浅色与深色两套值，由 [AppleTheme] 按当前亮度选择。
/// 直接使用 `AppleColors.of(context)` 获取当前生效的一套。
@immutable
class AppleColors extends ThemeExtension<AppleColors> {
  const AppleColors({
    required this.isDark,
    required this.background,
    required this.secondaryBackground,
    required this.tertiaryBackground,
    required this.groupedBackground,
    required this.secondaryGroupedBackground,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.quaternaryLabel,
    required this.placeholderText,
    required this.separator,
    required this.opaqueSeparator,
    required this.fill,
    required this.secondaryFill,
    required this.tertiaryFill,
    required this.quaternaryFill,
    required this.blue,
    required this.green,
    required this.indigo,
    required this.orange,
    required this.pink,
    required this.purple,
    required this.red,
    required this.teal,
    required this.yellow,
    required this.gray,
    required this.gray2,
    required this.gray3,
    required this.gray4,
    required this.gray5,
    required this.gray6,
  });

  /// 当前是否为深色。
  final bool isDark;

  // ── 背景层级 ────────────────────────────────────────────────
  /// 主背景（页面底）。
  final Color background;

  /// 次级背景（分组列表底）。
  final Color secondaryBackground;

  /// 三级背景（卡片/输入框底）。
  final Color tertiaryBackground;

  /// 分组列表页背景（比 background 略灰，让白色行浮起来）。
  final Color groupedBackground;

  /// 分组列表页中行内的次级背景。
  final Color secondaryGroupedBackground;

  // ── 文字层级 ────────────────────────────────────────────────
  /// 主文字。
  final Color label;

  /// 次文字（说明、副标题）。
  final Color secondaryLabel;

  /// 三级文字（时间戳、辅助信息）。
  final Color tertiaryLabel;

  /// 四级文字（占位、禁用）。
  final Color quaternaryLabel;

  /// 输入框占位文字。
  final Color placeholderText;

  // ── 分隔线 ──────────────────────────────────────────────────
  /// 半透明分隔线（叠在内容上）。
  final Color separator;

  /// 不透明分隔线（列表行之间）。
  final Color opaqueSeparator;

  // ── 填充（控件底）──────────────────────────────────────────
  final Color fill;
  final Color secondaryFill;
  final Color tertiaryFill;
  final Color quaternaryFill;

  // ── 系统强调色 ──────────────────────────────────────────────
  final Color blue;
  final Color green;
  final Color indigo;
  final Color orange;
  final Color pink;
  final Color purple;
  final Color red;
  final Color teal;
  final Color yellow;

  // ── 中性灰阶 ────────────────────────────────────────────────
  final Color gray;
  final Color gray2;
  final Color gray3;
  final Color gray4;
  final Color gray5;
  final Color gray6;

  /// 浅色配色（应用默认）。
  static const AppleColors light = AppleColors(
    isDark: false,
    background: Color(0xFFFFFFFF),
    secondaryBackground: Color(0xFFF2F2F7),
    tertiaryBackground: Color(0xFFFFFFFF),
    groupedBackground: Color(0xFFF2F2F7),
    secondaryGroupedBackground: Color(0xFFFFFFFF),
    label: Color(0xFF000000),
    secondaryLabel: Color(0x993C3C43),
    tertiaryLabel: Color(0x4D3C3C43),
    quaternaryLabel: Color(0x2E3C3C43),
    placeholderText: Color(0x4D3C3C43),
    separator: Color(0x4A3C3C43),
    opaqueSeparator: Color(0xFFC6C6C8),
    fill: Color(0x33787880),
    secondaryFill: Color(0x29787880),
    tertiaryFill: Color(0x1F767680),
    quaternaryFill: Color(0x14747480),
    blue: Color(0xFF007AFF),
    green: Color(0xFF34C759),
    indigo: Color(0xFF5856D6),
    orange: Color(0xFFFF9500),
    pink: Color(0xFFFF2D55),
    purple: Color(0xFFAF52DE),
    red: Color(0xFFFF3B30),
    teal: Color(0xFF5AC8FA),
    yellow: Color(0xFFFFCC00),
    gray: Color(0xFF8E8E93),
    gray2: Color(0xFFAEAEB2),
    gray3: Color(0xFFC7C7CC),
    gray4: Color(0xFFD1D1D6),
    gray5: Color(0xFFE5E5EA),
    gray6: Color(0xFFF2F2F7),
  );

  /// 深色配色（系统深色模式 / 视频沉浸场景）。
  static const AppleColors dark = AppleColors(
    isDark: true,
    background: Color(0xFF000000),
    secondaryBackground: Color(0xFF1C1C1E),
    tertiaryBackground: Color(0xFF2C2C2E),
    groupedBackground: Color(0xFF000000),
    secondaryGroupedBackground: Color(0xFF1C1C1E),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    tertiaryLabel: Color(0x4DEBEBF5),
    quaternaryLabel: Color(0x2EEBEBF5),
    placeholderText: Color(0x4DEBEBF5),
    separator: Color(0x5A545458),
    opaqueSeparator: Color(0xFF38383A),
    fill: Color(0x5C787880),
    secondaryFill: Color(0x52787880),
    tertiaryFill: Color(0x47767680),
    quaternaryFill: Color(0x3D747480),
    blue: Color(0xFF0A84FF),
    green: Color(0xFF30D158),
    indigo: Color(0xFF5E5CE6),
    orange: Color(0xFFFF9F0A),
    pink: Color(0xFFFF375F),
    purple: Color(0xFFBF5AF2),
    red: Color(0xFFFF453A),
    teal: Color(0xFF64D2FF),
    yellow: Color(0xFFFFD60A),
    gray: Color(0xFF8E8E93),
    gray2: Color(0xFF636366),
    gray3: Color(0xFF48484A),
    gray4: Color(0xFF3A3A3C),
    gray5: Color(0xFF2C2C2E),
    gray6: Color(0xFF1C1C1E),
  );

  /// 读取当前生效的配色。未注册扩展时按亮度回退。
  static AppleColors of(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppleColors>();
    if (ext != null) return ext;
    return theme.brightness == Brightness.dark ? dark : light;
  }

  /// 视频沉浸区配色：无论应用外壳是浅色还是深色，
  /// 视频画面周边始终使用纯黑，保证画面边缘无缝且对比度正确。
  static const AppleColors immersive = dark;

  @override
  AppleColors copyWith({bool? isDark}) => this;

  @override
  AppleColors lerp(ThemeExtension<AppleColors>? other, double t) {
    if (other is! AppleColors) return this;
    // 明暗切换时不做颜色插值：中途插值会产生"脏色"（例如灰白过渡到纯黑时发绿）。
    // 直接按 t 的临界点切换，配合上层动画的淡入淡出完成过渡。
    return t < 0.5 ? this : other;
  }
}

/// 字体层级（对应 iOS Dynamic Type）。
///
/// 使用系统字体（Android 为 Roboto/思源，iOS 为 SF Pro），
/// 不内置字体文件，避免包体膨胀与授权问题。
/// 字号与字重严格对齐 iOS 规范，保证层级一致。
class AppleType {
  AppleType._();

  /// 大标题（页面顶部，随滚动收缩）。34 / Bold
  static const TextStyle largeTitle = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.37,
    height: 1.2,
  );

  /// 一级标题。28 / Bold
  static const TextStyle title1 = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.36,
    height: 1.25,
  );

  /// 二级标题。22 / Bold
  static const TextStyle title2 = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.35,
    height: 1.27,
  );

  /// 三级标题。20 / Semibold
  static const TextStyle title3 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.38,
    height: 1.25,
  );

  /// 标题（列表分组标题）。17 / Semibold
  static const TextStyle headline = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.41,
    height: 1.29,
  );

  /// 正文。17 / Regular
  static const TextStyle body = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.41,
    height: 1.29,
  );

  /// 强调正文。17 / Semibold
  static const TextStyle bodyEmphasized = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.41,
    height: 1.29,
  );

  /// 注音正文。16 / Regular
  static const TextStyle callout = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.32,
    height: 1.31,
  );

  /// 副标题。15 / Regular
  static const TextStyle subheadline = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.24,
    height: 1.33,
  );

  /// 副标题强调。15 / Semibold
  static const TextStyle subheadlineEmphasized = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.24,
    height: 1.33,
  );

  /// 脚注。13 / Regular
  static const TextStyle footnote = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.08,
    height: 1.38,
  );

  /// 脚注强调。13 / Semibold
  static const TextStyle footnoteEmphasized = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.08,
    height: 1.38,
  );

  /// 说明文字。12 / Regular
  static const TextStyle caption1 = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.33,
  );

  /// 极小说明。11 / Regular
  static const TextStyle caption2 = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.07,
    height: 1.36,
  );

  /// 按钮文字。17 / Semibold
  static const TextStyle button = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.41,
    height: 1.18,
  );

  /// 小按钮文字。15 / Semibold
  static const TextStyle buttonSmall = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.24,
    height: 1.2,
  );
}

/// 间距刻度。全部为 4 的倍数，保证视觉节奏一致。
class AppleSpace {
  AppleSpace._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;

  /// 页面左右安全边距（与 iOS 列表一致）。
  static const double pageInset = 16;

  /// 分组列表的行内边距。
  static const EdgeInsets rowInset =
      EdgeInsets.symmetric(horizontal: pageInset, vertical: 11);
}

/// 圆角刻度。
///
/// iOS 使用**连续圆角**（continuous corners / squircle），
/// 而不是正圆角。Flutter 的 [RoundedRectangleBorder] 是正圆角，
/// 在较大半径时视觉差异明显，因此这里统一使用
/// [ContinuousRectangleBorder] 的等效半径并在组件层封装。
class AppleRadius {
  AppleRadius._();

  /// 小控件（标签、小按钮）。
  static const double xs = 6;

  /// 输入框、小卡片。
  static const double sm = 10;

  /// 卡片、列表分组。
  static const double md = 14;

  /// 弹层、大卡片。
  static const double lg = 20;

  /// 底部弹层顶部圆角。
  static const double sheet = 24;

  /// 胶囊。
  static const double pill = 999;

  /// 生成连续圆角形状（iOS 风格）。
  static ShapeBorder continuous(
    double radius, {
    BorderSide side = BorderSide.none,
  }) =>
      ContinuousRectangleBorder(
        borderRadius: BorderRadius.circular(radius * 1.28),
        side: side,
      );
}

/// 动效令牌。
///
/// iOS 的动效特征是"快速启动 + 缓慢收敛"（ease-out），
/// 不使用弹跳。所有时长控制在 200–350ms，避免拖沓。
class AppleMotion {
  AppleMotion._();

  /// 标准转场。
  static const Duration standard = Duration(milliseconds: 280);

  /// 快速反馈（按压、高亮）。
  static const Duration fast = Duration(milliseconds: 160);

  /// 页面推入。
  static const Duration page = Duration(milliseconds: 320);

  /// 弹性收敛曲线（iOS 默认 ease-out 的近似）。
  static const Curve easeOut = Cubic(0.25, 0.1, 0.25, 1.0);

  /// 减速曲线（用于进入动画）。
  static const Curve decelerate = Cubic(0.0, 0.0, 0.2, 1.0);

  /// 加速曲线（用于退出动画）。
  static const Curve accelerate = Cubic(0.4, 0.0, 1.0, 1.0);

  /// 页面推入曲线。
  static const Curve pageCurve = Cubic(0.32, 0.72, 0, 1);
}

/// 触控目标与控件尺寸。
class AppleSize {
  AppleSize._();

  /// iOS 最小可点击尺寸。
  static const double minTapTarget = 44;

  /// 标准行高。
  static const double rowHeight = 44;

  /// 底部标签栏高度（不含安全区）。
  static const double tabBar = 49;

  /// 导航栏高度（不含状态栏）。
  static const double navBar = 44;

  /// 大标题导航栏高度（含大标题）。
  static const double largeNavBar = 96;

  /// 头像小尺寸。
  static const double avatarSm = 32;

  /// 头像中尺寸。
  static const double avatarMd = 44;

  /// 头像大尺寸。
  static const double avatarLg = 72;

  /// 缩略图小尺寸。
  static const double thumbSm = 64;

  /// 缩略图中尺寸。
  static const double thumbMd = 96;
}

/// 阴影令牌。
///
/// Apple 风格极少使用重阴影，主要靠层级色差区分平面。
/// 仅在需要"浮起"的控件（浮动按钮、弹层）上使用极轻阴影。
class AppleShadow {
  AppleShadow._();

  /// 浮动控件。
  static const List<BoxShadow> floating = [
    BoxShadow(
      color: Color(0x1A000000),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
    BoxShadow(
      color: Color(0x0D000000),
      blurRadius: 4,
      offset: Offset(0, 2),
    ),
  ];

  /// 轻微浮起（卡片）。
  static const List<BoxShadow> raised = [
    BoxShadow(
      color: Color(0x0F000000),
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ];
}
