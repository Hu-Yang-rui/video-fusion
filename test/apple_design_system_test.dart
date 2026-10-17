/// Apple 设计系统测试。
///
/// 验证设计令牌的语义正确性、对比度与一致性约束。
/// 这些断言防止后续改动把设计系统"改回去"成普通 Material 主题。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/design/apple_theme.dart';
import 'package:video_fusion/src/design/apple_tokens.dart';
import 'package:video_fusion/src/design/components/apple_controls.dart';
import 'package:video_fusion/src/design/components/apple_layout.dart';

/// 计算两个颜色的对比度（WCAG 2.1）。
double contrastRatio(Color a, Color b) {
  double luminance(Color c) {
    double channel(double v) {
      return v <= 0.03928 ? v / 12.92 : _pow((v + 0.055) / 1.055, 2.4);
    }

    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  final la = luminance(a);
  final lb = luminance(b);
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

double _pow(double x, double e) {
  // 简单的幂运算（避免引入 dart:math 的额外依赖语义混淆）
  return _exp(e * _ln(x));
}

double _ln(double x) {
  if (x <= 0) return double.negativeInfinity;
  var y = (x - 1) / (x + 1);
  var y2 = y * y;
  var term = y;
  var sum = 0.0;
  for (var n = 1; n <= 60; n += 2) {
    sum += term / n;
    term *= y2;
  }
  return 2 * sum;
}

double _exp(double x) {
  var sum = 1.0;
  var term = 1.0;
  for (var n = 1; n <= 40; n++) {
    term *= x / n;
    sum += term;
  }
  return sum;
}

void main() {
  group('语义化配色', () {
    test('浅色与深色都提供完整令牌', () {
      for (final c in [AppleColors.light, AppleColors.dark]) {
        expect(c.background, isNotNull);
        expect(c.label, isNotNull);
        expect(c.secondaryLabel, isNotNull);
        expect(c.separator, isNotNull);
        expect(c.blue, isNotNull);
      }
    });

    test('浅色模式背景为白、文字为黑', () {
      expect(AppleColors.light.background, const Color(0xFFFFFFFF));
      expect(AppleColors.light.label, const Color(0xFF000000));
      expect(AppleColors.light.isDark, isFalse);
    });

    test('深色模式背景为黑、文字为白', () {
      expect(AppleColors.dark.background, const Color(0xFF000000));
      expect(AppleColors.dark.label, const Color(0xFFFFFFFF));
      expect(AppleColors.dark.isDark, isTrue);
    });

    test('视频沉浸区固定为深色（画面需要纯黑背景）', () {
      expect(AppleColors.immersive.background, const Color(0xFF000000));
      expect(AppleColors.immersive.isDark, isTrue);
    });

    test('强调色使用系统蓝，不是平台品牌色', () {
      // B站粉 / 抖音红 / 抖音青 都不得成为强调色
      const biliPink = Color(0xFFFB7299);
      const douyinRed = Color(0xFFFE2C55);
      const douyinCyan = Color(0xFF25F4EE);

      for (final c in [AppleColors.light, AppleColors.dark]) {
        expect(c.blue, isNot(biliPink));
        expect(c.blue, isNot(douyinRed));
        expect(c.blue, isNot(douyinCyan));
        expect(c.green, isNot(douyinCyan));
      }
    });
  });

  group('可访问性（WCAG 对比度）', () {
    test('浅色模式主文字对比度 ≥ 4.5:1', () {
      final ratio = contrastRatio(
        AppleColors.light.label,
        AppleColors.light.background,
      );
      expect(ratio, greaterThanOrEqualTo(4.5),
          reason: '主文字对比度 $ratio 不满足 AA 标准');
    });

    test('深色模式主文字对比度 ≥ 4.5:1', () {
      final ratio = contrastRatio(
        AppleColors.dark.label,
        AppleColors.dark.background,
      );
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    test('浅色模式次文字对比度 ≥ 3:1（AA 大字号标准）', () {
      // secondaryLabel 带透明度，先合成到背景上
      final composed = _composite(
        AppleColors.light.secondaryLabel,
        AppleColors.light.background,
      );
      final ratio = contrastRatio(composed, AppleColors.light.background);
      expect(ratio, greaterThanOrEqualTo(3.0));
    });

    test('深色模式次文字对比度 ≥ 3:1', () {
      final composed = _composite(
        AppleColors.dark.secondaryLabel,
        AppleColors.dark.background,
      );
      final ratio = contrastRatio(composed, AppleColors.dark.background);
      expect(ratio, greaterThanOrEqualTo(3.0));
    });

    test('系统蓝在浅色背景上对比度 ≥ 3:1（可点击元素）', () {
      final ratio = contrastRatio(
        AppleColors.light.blue,
        AppleColors.light.background,
      );
      expect(ratio, greaterThanOrEqualTo(3.0));
    });
  });

  group('字体层级', () {
    test('字号严格递减：largeTitle > title1 > title2 > title3 > headline', () {
      expect(AppleType.largeTitle.fontSize!, greaterThan(AppleType.title1.fontSize!));
      expect(AppleType.title1.fontSize!, greaterThan(AppleType.title2.fontSize!));
      expect(AppleType.title2.fontSize!, greaterThan(AppleType.title3.fontSize!));
      expect(AppleType.title3.fontSize!, greaterThan(AppleType.headline.fontSize!));
    });

    test('正文与脚注层级正确', () {
      expect(AppleType.body.fontSize!, greaterThan(AppleType.footnote.fontSize!));
      expect(AppleType.footnote.fontSize!, greaterThan(AppleType.caption1.fontSize!));
      expect(AppleType.caption1.fontSize!, greaterThan(AppleType.caption2.fontSize!));
    });

    test('标题使用 Semibold 及以上字重', () {
      expect(AppleType.headline.fontWeight, FontWeight.w600);
      expect(AppleType.title1.fontWeight, FontWeight.w700);
      expect(AppleType.title3.fontWeight, FontWeight.w600);
    });

    test('正文字重为 Regular（避免全局加粗）', () {
      expect(AppleType.body.fontWeight, FontWeight.w400);
    });
  });

  group('间距与尺寸', () {
    test('间距刻度全部为 4 的倍数', () {
      const values = [
        AppleSpace.xs,
        AppleSpace.sm,
        AppleSpace.md,
        AppleSpace.lg,
        AppleSpace.xl,
        AppleSpace.xxl,
        AppleSpace.xxxl,
        AppleSpace.huge,
      ];
      for (final v in values) {
        expect(v % 4, 0, reason: '$v 不是 4 的倍数');
      }
    });

    test('触控目标不小于 44pt（Apple HIG 最小尺寸）', () {
      expect(AppleSize.minTapTarget, greaterThanOrEqualTo(44));
    });

    test('标签栏高度符合 iOS 规范', () {
      expect(AppleSize.tabBar, 49);
      expect(AppleSize.navBar, 44);
    });
  });

  group('圆角与动效', () {
    test('圆角层级递增', () {
      expect(AppleRadius.xs, lessThan(AppleRadius.sm));
      expect(AppleRadius.sm, lessThan(AppleRadius.md));
      expect(AppleRadius.md, lessThan(AppleRadius.lg));
      expect(AppleRadius.lg, lessThan(AppleRadius.sheet));
    });

    test('动效时长克制（不超过 350ms）', () {
      expect(AppleMotion.standard.inMilliseconds, lessThanOrEqualTo(350));
      expect(AppleMotion.fast.inMilliseconds, lessThanOrEqualTo(200));
      expect(AppleMotion.page.inMilliseconds, lessThanOrEqualTo(350));
    });

    test('曲线使用 ease-out 类，不使用弹跳', () {
      // 弹跳曲线的特征是控制点超出 [0,1] 范围
      final c = AppleMotion.easeOut as Cubic;
      for (final v in [c.a, c.b, c.c, c.d]) {
        expect(v, inInclusiveRange(0.0, 1.0),
            reason: '控制点 $v 超出范围，说明使用了弹跳曲线');
      }
    });
  });

  group('主题装配', () {
    testWidgets('浅色主题注册了 AppleColors 扩展', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Builder(builder: (context) {
            ctx = context;
            return const SizedBox();
          }),
        ),
      );
      final colors = AppleColors.of(ctx);
      expect(colors.isDark, isFalse);
      expect(colors.background, const Color(0xFFFFFFFF));
    });

    testWidgets('深色主题注册了深色令牌', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.dark(),
          home: Builder(builder: (context) {
            ctx = context;
            return const SizedBox();
          }),
        ),
      );
      expect(AppleColors.of(ctx).isDark, isTrue);
    });

    test('沉浸主题强制纯黑背景', () {
      final theme = AppleTheme.immersive();
      expect(theme.scaffoldBackgroundColor, Colors.black);
      final ext = theme.extension<AppleColors>();
      expect(ext, isNotNull);
      expect(ext!.background, Colors.black);
    });

    test('浅色主题的 scaffold 背景为分组灰（让白色分组浮起）', () {
      final theme = AppleTheme.light();
      expect(theme.scaffoldBackgroundColor, AppleColors.light.groupedBackground);
      // 分组灰必须与纯白不同，否则分组列表失去层级
      expect(theme.scaffoldBackgroundColor, isNot(Colors.white));
    });
  });

  group('组件渲染', () {
    testWidgets('主按钮可渲染且可点击', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: Center(
              child: ApplePrimaryButton(
                label: '确定',
                onPressed: () => tapped = true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('确定'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });

    testWidgets('主按钮 loading 时不可点击', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: Center(
              child: ApplePrimaryButton(
                label: '提交',
                loading: true,
                onPressed: () => tapped = true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(ApplePrimaryButton));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tapped, isFalse);
    });

    testWidgets('分段控件切换会回调', (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: Center(
              child: AppleSegmentedControl<int>(
                segments: const [0, 1, 2],
                selected: 0,
                onChanged: (v) => selected = v,
                labelOf: (v) => '选项$v',
              ),
            ),
          ),
        ),
      );
      expect(find.text('选项0'), findsOneWidget);
      await tester.tap(find.text('选项2'));
      await tester.pumpAndSettle();
      expect(selected, 2);
    });

    testWidgets('分组容器渲染标题、内容与说明', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: AppleGroupedSection(
              header: '账号',
              footer: '这是说明文字',
              children: const [
                AppleListRow(title: '第一行'),
                AppleListRow(title: '第二行'),
              ],
            ),
          ),
        ),
      );
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('第一行'), findsOneWidget);
      expect(find.text('第二行'), findsOneWidget);
      expect(find.text('这是说明文字'), findsOneWidget);
    });

    testWidgets('列表行显示副标题与右侧值', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: AppleListRow(
              title: '播放内核',
              subtitle: '设备本地解码',
              trailingText: '原生',
            ),
          ),
        ),
      );
      expect(find.text('播放内核'), findsOneWidget);
      expect(find.text('设备本地解码'), findsOneWidget);
      expect(find.text('原生'), findsOneWidget);
    });

    testWidgets('标签栏渲染全部项目并响应点击', (tester) async {
      var index = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                AppleTabBar(
                  currentIndex: 0,
                  blurEnabled: false,
                  onChanged: (i) => index = i,
                  items: const [
                    AppleTabItem(
                      icon: Icons.home_outlined,
                      activeIcon: Icons.home,
                      label: '首页',
                    ),
                    AppleTabItem(
                      icon: Icons.search_outlined,
                      activeIcon: Icons.search,
                      label: '搜索',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('首页'), findsOneWidget);
      expect(find.text('搜索'), findsOneWidget);
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(index, 1);
    });

    testWidgets('空状态展示标题、说明与操作', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: AppleEmptyState(
              icon: Icons.inbox_outlined,
              title: '空空如也',
              message: '这里还没有内容',
              action: AppleSecondaryButton(
                label: '刷新',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('空空如也'), findsOneWidget);
      expect(find.text('这里还没有内容'), findsOneWidget);
      expect(find.text('刷新'), findsOneWidget);
    });

    testWidgets('错误状态与空状态可区分（错误有重试图标）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppleTheme.light(),
          home: Scaffold(
            body: AppleErrorState(
              title: '加载失败',
              message: '网络连接失败',
              onRetry: () {},
            ),
          ),
        ),
      );
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('网络连接失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // 错误态使用红色图标，空态不会
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });
  });
}

/// 把带透明度的颜色合成到不透明背景上。
Color _composite(Color fg, Color bg) {
  final a = fg.a;
  return Color.from(
    alpha: 1,
    red: fg.r * a + bg.r * (1 - a),
    green: fg.g * a + bg.g * (1 - a),
    blue: fg.b * a + bg.b * (1 - a),
  );
}
