/// Apple 风格主题装配。
///
/// 把 [AppleColors] / [AppleType] / [AppleRadius] 组装为 [ThemeData]，
/// 并覆盖 Material 默认组件外观，使内置控件也呈现 iOS 观感。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apple_tokens.dart';

/// 主题装配入口。
class AppleTheme {
  AppleTheme._();

  /// 浅色主题（应用默认）。
  static ThemeData light() => _build(AppleColors.light, Brightness.light);

  /// 深色主题（系统深色模式 / 视频沉浸场景）。
  static ThemeData dark() => _build(AppleColors.dark, Brightness.dark);

  static ThemeData _build(AppleColors c, Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      // 使用 iOS 的字体度量，避免 Material 的默认行高造成层级松散
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: c.blue,
      onPrimary: Colors.white,
      primaryContainer: c.blue.withValues(alpha: 0.12),
      onPrimaryContainer: c.blue,
      secondary: c.gray,
      onSecondary: Colors.white,
      secondaryContainer: c.secondaryFill,
      onSecondaryContainer: c.label,
      tertiary: c.green,
      onTertiary: Colors.white,
      error: c.red,
      onError: Colors.white,
      errorContainer: c.red.withValues(alpha: 0.12),
      onErrorContainer: c.red,
      surface: c.background,
      onSurface: c.label,
      surfaceContainerHighest: c.secondaryBackground,
      onSurfaceVariant: c.secondaryLabel,
      outline: c.opaqueSeparator,
      outlineVariant: c.separator,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: c.label,
      onInverseSurface: c.background,
      inversePrimary: c.blue,
    );

    final textTheme = TextTheme(
      displayLarge: AppleType.largeTitle.copyWith(color: c.label),
      displayMedium: AppleType.title1.copyWith(color: c.label),
      displaySmall: AppleType.title2.copyWith(color: c.label),
      headlineMedium: AppleType.title3.copyWith(color: c.label),
      headlineSmall: AppleType.headline.copyWith(color: c.label),
      titleLarge: AppleType.headline.copyWith(color: c.label),
      titleMedium: AppleType.bodyEmphasized.copyWith(color: c.label),
      titleSmall: AppleType.subheadlineEmphasized.copyWith(color: c.label),
      bodyLarge: AppleType.body.copyWith(color: c.label),
      bodyMedium: AppleType.subheadline.copyWith(color: c.label),
      bodySmall: AppleType.footnote.copyWith(color: c.secondaryLabel),
      labelLarge: AppleType.button.copyWith(color: c.label),
      labelMedium: AppleType.footnoteEmphasized.copyWith(color: c.label),
      labelSmall: AppleType.caption2.copyWith(color: c.tertiaryLabel),
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: c.groupedBackground,
      canvasColor: c.groupedBackground,
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[c],

      // 系统状态栏 / 导航栏样式
      appBarTheme: AppBarTheme(
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.label,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: AppleType.headline.copyWith(color: c.label),
        systemOverlayStyle:
            brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),

      // 分隔线：iOS 习惯从左侧留出边距
      dividerTheme: DividerThemeData(
        color: c.separator,
        thickness: 0.5,
        space: 0.5,
      ),

      // 底部弹层：顶部连续圆角 + 拖拽指示条
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.secondaryGroupedBackground,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: c.secondaryGroupedBackground,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppleRadius.sheet),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),

      // 对话框
      dialogTheme: DialogThemeData(
        backgroundColor: c.secondaryGroupedBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppleRadius.md),
        ),
        titleTextStyle: AppleType.headline.copyWith(color: c.label),
        contentTextStyle: AppleType.footnote.copyWith(color: c.secondaryLabel),
      ),

      // 列表行
      listTileTheme: ListTileThemeData(
        iconColor: c.secondaryLabel,
        textColor: c.label,
        titleTextStyle: AppleType.body.copyWith(color: c.label),
        subtitleTextStyle: AppleType.footnote.copyWith(color: c.secondaryLabel),
        minVerticalPadding: 11,
        horizontalTitleGap: 12,
      ),

      // 输入框：iOS 使用填充色而非描边
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.fill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.md,
          vertical: AppleSpace.md,
        ),
        hintStyle: AppleType.body.copyWith(color: c.placeholderText),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppleRadius.sm),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppleRadius.sm),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppleRadius.sm),
          borderSide: BorderSide(color: c.blue, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppleRadius.sm),
          borderSide: BorderSide(color: c.red, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppleRadius.sm),
          borderSide: BorderSide(color: c.red, width: 1.5),
        ),
      ),

      // 按钮
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.blue,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, AppleSize.minTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: AppleSpace.xl),
          textStyle: AppleType.button,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppleRadius.sm),
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.blue,
          textStyle: AppleType.button.copyWith(fontSize: 15),
          minimumSize: const Size(0, AppleSize.minTapTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppleRadius.sm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.blue,
          minimumSize: const Size(0, AppleSize.minTapTarget),
          side: BorderSide(color: c.separator),
          textStyle: AppleType.button,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppleRadius.sm),
          ),
        ),
      ),

      // 开关使用 iOS 配色
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return c.background;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return c.green;
          return c.gray4;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),

      // 进度指示
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.blue,
        linearTrackColor: c.fill,
        circularTrackColor: Colors.transparent,
      ),

      // SnackBar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.isDark ? c.tertiaryBackground : const Color(0xE6303030),
        contentTextStyle: AppleType.subheadline.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppleRadius.sm),
        ),
        insetPadding: const EdgeInsets.all(AppleSpace.lg),
      ),

      // 滚动条：iOS 滚动时短暂显示
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.all(c.label.withValues(alpha: 0.25)),
        radius: const Radius.circular(AppleRadius.pill),
        thickness: WidgetStateProperty.all(3),
      ),

      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: c.fill.withValues(alpha: 0.5),
      focusColor: c.blue.withValues(alpha: 0.12),
    );
  }

  /// 沉浸式（视频播放）主题：强制深色，用于视频流与全屏播放页。
  static ThemeData immersive() {
    final c = AppleColors.immersive;
    final base = dark();
    return base.copyWith(
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      colorScheme: base.colorScheme.copyWith(
        surface: Colors.black,
        onSurface: Colors.white,
      ),
      extensions: <ThemeExtension<dynamic>>[c],
    );
  }
}
