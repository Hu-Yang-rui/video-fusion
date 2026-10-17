/// 短视频平台 · 移动端视觉设计系统（原创）
///
/// 产品定位：**中心化短视频平台 APP**，不是工具软件。
/// 打开即进入全屏视频流，上滑切换，滑到即播。
///
/// 设计理念：「暗幕 / Dark Stage」
///  - 视频即界面：全屏沉浸，UI 悬浮在视频之上，不占据布局空间。
///  - 暗色为底：视频流背景纯黑，让画面成为唯一视觉主体。
///  - 单一强调色：克制的暖青，只用于可操作元素与焦点态。
///  - 手势优先：上滑切换、单击暂停、双击点赞位（本阶段不实现点赞）。
///  - 安全区：所有悬浮控件避开系统状态栏与手势条。
///
/// 本设计不参考、不复制任何既有项目的 UI。
library;

import 'package:flutter/material.dart';

/// 移动端设计令牌。
class MobileTokens {
  MobileTokens._();

  // ── 色彩（短视频场景以暗色为主）────────────────────────────
  /// 视频流背景：纯黑，画面边缘无缝。
  static const Color stage = Color(0xFF000000);

  /// 悬浮面板底：半透明深色。
  static const Color scrim = Color(0xCC121212);

  /// 次级面板底。
  static const Color scrimSoft = Color(0x991A1A1A);

  /// 主文字：纯白。
  static const Color ink = Color(0xFFFFFFFF);

  /// 次文字：浅灰。
  static const Color inkSecondary = Color(0xCCFFFFFF);

  /// 三级文字。
  static const Color inkTertiary = Color(0x8AFFFFFF);

  /// 强调色：暖青，暗底上清晰但不刺眼。
  static const Color accent = Color(0xFF4DD8C8);

  /// 强调色的深色底。
  static const Color accentDim = Color(0xFF1E4A46);

  /// 危险/失败色。
  static const Color danger = Color(0xFFFF6B5E);

  /// 警示色。
  static const Color caution = Color(0xFFF0B450);

  /// 成功色。
  static const Color positive = Color(0xFF5ED17A);

  /// 亮色模式（设置页/弹层列表页使用）。
  static const Color lightCanvas = Color(0xFF101012);
  static const Color lightSurface = Color(0xFF1A1A1D);
  static const Color lightBorder = Color(0xFF2A2A2E);

  // ── 间距（4pt 基准）────────────────────────────────────────
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;

  // ── 圆角 ───────────────────────────────────────────────────
  static const double rPill = 999;
  static const double rCard = 16;
  static const double rSheet = 24;
  static const double rControl = 12;

  // ── 手势与动画 ─────────────────────────────────────────────
  /// 上滑切换的动画时长。
  static const Duration swipe = Duration(milliseconds: 260);

  /// 控件淡入淡出。
  static const Duration fade = Duration(milliseconds: 180);

  /// 单击暂停的判定窗口。
  static const Duration tapWindow = Duration(milliseconds: 220);

  // ── 布局 ───────────────────────────────────────────────────
  /// 右侧操作栏宽度。
  static const double actionRailWidth = 56;

  /// 底部信息区距手势条的最小间距。
  static const double bottomSafeGap = 12;
}

/// 移动端文字层级。
class MobileText {
  MobileText._();

  /// 视频标题（覆盖在视频上）。
  static const TextStyle videoTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.4,
    color: MobileTokens.ink,
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 1)),
    ],
  );

  /// 作者名。
  static const TextStyle author = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: MobileTokens.ink,
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1)),
    ],
  );

  /// 辅助信息（播放量等）。
  static const TextStyle meta = TextStyle(
    fontSize: 12,
    color: MobileTokens.inkSecondary,
    shadows: [
      Shadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 1)),
    ],
  );

  /// 页面主标题。
  static const TextStyle pageTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -0.3,
    color: MobileTokens.ink,
  );

  /// 列表项标题。
  static const TextStyle listTitle = TextStyle(
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: MobileTokens.ink,
  );

  /// 正文。
  static const TextStyle body = TextStyle(
    fontSize: 13.5,
    height: 1.55,
    color: MobileTokens.inkSecondary,
  );

  /// 小标签。
  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: MobileTokens.inkSecondary,
  );

  /// 极小标注。
  static const TextStyle caption = TextStyle(
    fontSize: 11,
    color: MobileTokens.inkTertiary,
  );

  /// 胶囊标签。
  static const TextStyle pill = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.1,
    color: MobileTokens.ink,
  );
}

/// 移动端主题。
class MobileTheme {
  MobileTheme._();

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: MobileTokens.stage,
      colorScheme: base.colorScheme.copyWith(
        primary: MobileTokens.accent,
        surface: MobileTokens.lightSurface,
        onSurface: MobileTokens.ink,
        error: MobileTokens.danger,
      ),
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: const DividerThemeData(
        color: MobileTokens.lightBorder,
        thickness: 1,
        space: 1,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: MobileTokens.accent,
        selectionColor: MobileTokens.accentDim,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: MobileTokens.lightSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(MobileTokens.rSheet),
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: MobileTokens.scrim,
        contentTextStyle: TextStyle(color: MobileTokens.ink, fontSize: 13),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 平台来源的视觉标识。
///
/// **不使用平台 Logo 或品牌色**，用统一几何符号 + 中性色阶区分，
/// 使多平台内容在同一竖滑流中保持视觉统一。
class PlatformMark {
  const PlatformMark({
    required this.symbol,
    required this.tint,
    required this.onTint,
  });

  /// 单字符号（取自平台名首字，非 Logo）。
  final String symbol;

  final Color tint;
  final Color onTint;

  static PlatformMark of(String platformId) => switch (platformId) {
        'bilibili' => const PlatformMark(
            symbol: '哔',
            tint: Color(0xFF2A2F3D),
            onTint: Color(0xFFA8B4D0),
          ),
        'douyin' => const PlatformMark(
            symbol: '抖',
            tint: Color(0xFF332B2B),
            onTint: Color(0xFFCFB4B4),
          ),
        'mock' => const PlatformMark(
            symbol: '测',
            tint: Color(0xFF32301F),
            onTint: Color(0xFFCBC48A),
          ),
        _ => PlatformMark(
            symbol: platformId.isNotEmpty ? platformId[0].toUpperCase() : '?',
            tint: MobileTokens.scrimSoft,
            onTint: MobileTokens.inkSecondary,
          ),
      };
}
