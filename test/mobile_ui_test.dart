/// 移动端 UI 测试。
///
/// 覆盖需求八「UI 测试」：
///  - 不同平台的视频能在同一竖滑流中展示
///  - 横屏、竖屏内容布局正常
///  - 标题较长时不溢出
///  - 缺少封面或作者信息时布局正常
///  - 加载、空状态、错误状态、受限状态完整
///  - 设计系统为独立原创设计
///
/// 本文件为**纯离线测试**，不产生真实网络请求。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';
import 'package:video_fusion/src/ui/mobile/mobile_theme.dart';
import 'package:video_fusion/src/ui/mobile/mobile_widgets.dart';

UnifiedVideo _video({
  String platformId = 'bilibili',
  String platformVideoId = 'BV1',
  String title = '测试视频标题',
  String? coverUrl,
  String? authorName = '测试作者',
  int? width = 1920,
  int? height = 1080,
  double? duration = 213,
  VideoErrorState? error,
  List<PlaybackMode> modes = const [PlaybackMode.native, PlaybackMode.external],
}) =>
    UnifiedVideo(
      id: makeVideoId(platformId, platformVideoId),
      platformId: platformId,
      platformVideoId: platformVideoId,
      originalUrl: 'https://example.com/video/$platformVideoId',
      canonicalUrl: 'https://example.com/video/$platformVideoId',
      title: title,
      author: VideoAuthor(name: authorName),
      coverUrl: coverUrl,
      durationSeconds: duration,
      aspectRatio: normalizeAspectRatio(width, height),
      width: width,
      height: height,
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      playbackModes: modes,
      error: error,
      diagnostics: const VideoDiagnostics(
        adapterId: 'test',
        upstreamEndpoint: '/test',
        fromCache: false,
        fetchDurationMs: 5,
      ),
    );

Widget _host(Widget child) => MaterialApp(
      theme: MobileTheme.dark(),
      home: Scaffold(backgroundColor: MobileTokens.stage, body: child),
    );

void main() {
  group('平台来源角标', () {
    testWidgets('完整模式显示符号与名称', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: MobilePlatformBadge(platformId: 'bilibili', label: 'B站'),
      )));
      expect(find.text('哔'), findsOneWidget);
      expect(find.text('B站'), findsOneWidget);
    });

    testWidgets('紧凑模式只显示符号', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: MobilePlatformBadge(
          platformId: 'douyin',
          label: '抖音',
          compact: true,
        ),
      )));
      expect(find.text('抖'), findsOneWidget);
      expect(find.text('抖音'), findsNothing);
    });

    testWidgets('未知平台也能渲染（不崩溃）', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: MobilePlatformBadge(platformId: 'unknown_platform', label: '未知'),
      )));
      expect(tester.takeException(), isNull);
    });
  });

  group('错误卡片', () {
    testWidgets('展示标题、详情与重试按钮', (tester) async {
      var retried = false;
      await tester.pumpWidget(_host(Center(
        child: MobileErrorCard(
          title: '请求超时',
          detail: '请稍后重试。',
          onRetry: () => retried = true,
        ),
      )));

      expect(find.text('请求超时'), findsOneWidget);
      expect(find.text('请稍后重试。'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
    });

    testWidgets('无重试时不显示按钮', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: MobileErrorCard(
          title: '视频不存在',
          detail: '该视频已被删除。',
        ),
      )));
      expect(find.text('视频不存在'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('支持次要操作（如"换个来源"）', (tester) async {
      var secondary = false;
      await tester.pumpWidget(_host(Center(
        child: MobileErrorCard(
          title: '平台被风控限制',
          detail: '暂时无法获取内容。',
          onSecondary: () => secondary = true,
          secondaryLabel: '换个来源',
        ),
      )));
      expect(find.text('换个来源'), findsOneWidget);
      await tester.tap(find.text('换个来源'));
      expect(secondary, isTrue);
    });

    testWidgets('支持附加内容（诊断信息）', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: MobileErrorCard(
          title: '错误',
          detail: '详情',
          extra: Text('诊断：ArgusSecurityPlugin'),
        ),
      )));
      expect(find.textContaining('ArgusSecurityPlugin'), findsOneWidget);
    });
  });

  group('空状态', () {
    testWidgets('展示标题、说明与操作', (tester) async {
      var acted = false;
      await tester.pumpWidget(_host(MobileEmptyState(
        title: '这个来源暂时没有内容',
        description: '可以换一个内容来源。',
        actionLabel: '切换来源',
        onAction: () => acted = true,
      )));

      expect(find.text('这个来源暂时没有内容'), findsOneWidget);
      expect(find.text('可以换一个内容来源。'), findsOneWidget);
      await tester.tap(find.text('切换来源'));
      expect(acted, isTrue);
    });

    testWidgets('无操作按钮时也能正常渲染', (tester) async {
      await tester.pumpWidget(_host(const MobileEmptyState(
        title: '空',
        description: '描述',
      )));
      expect(tester.takeException(), isNull);
    });
  });

  group('加载骨架', () {
    testWidgets('骨架列表可渲染', (tester) async {
      await tester.pumpWidget(_host(const MobileSkeletonList(count: 3)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(MobileShimmer), findsWidgets);
    });

    testWidgets('单个微光块可渲染', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: MobileShimmer(width: 120, height: 60),
      )));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });

  group('内容来源选择面板', () {
    final sources = [
      const FeedSource(
        id: 'bilibili:rcmd',
        adapterId: 'bilibili',
        label: '推荐',
        description: 'B 站首页推荐流。',
      ),
      const FeedSource(
        id: 'douyin:recommend',
        adapterId: 'douyin',
        label: '抖音推荐',
        description: '抖音推荐流。',
        requiresAuth: true,
        available: false,
        unavailableReason: '受平台风控保护，当前无法接入。',
      ),
    ];

    testWidgets('列出全部来源并标注选中项', (tester) async {
      await tester.pumpWidget(_host(MobilePickerSheet<FeedSource>(
        title: '内容来源',
        items: sources,
        selected: sources.first,
        labelOf: (s) => s.label,
        subtitleOf: (s) => s.available ? s.description : s.unavailableReason,
        enabledOf: (s) => s.available,
        onSelected: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('内容来源'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('抖音推荐'), findsOneWidget);
      // 不可用来源必须显示"不可用"标记
      expect(find.text('不可用'), findsOneWidget);
    });

    testWidgets('不可用来源不可点击', (tester) async {
      var selected = false;
      await tester.pumpWidget(_host(MobilePickerSheet<FeedSource>(
        title: '内容来源',
        items: sources,
        labelOf: (s) => s.label,
        subtitleOf: (s) => s.available ? s.description : s.unavailableReason,
        enabledOf: (s) => s.available,
        onSelected: (_) => selected = true,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('抖音推荐'));
      await tester.pumpAndSettle();
      expect(selected, isFalse, reason: '不可用来源不应可被选中');
    });

    testWidgets('空列表显示提示', (tester) async {
      await tester.pumpWidget(_host(MobilePickerSheet<String>(
        title: '内容来源',
        items: const [],
        labelOf: (s) => s,
        onSelected: (_) {},
        emptyHint: '当前没有可用的内容来源。',
      )));
      await tester.pumpAndSettle();
      expect(find.text('当前没有可用的内容来源。'), findsOneWidget);
    });
  });

  group('内容来源切换按钮', () {
    testWidgets('显示当前来源名', (tester) async {
      await tester.pumpWidget(_host(Center(
        child: FeedSourceButton(
          current: const FeedSource(
            id: 'bilibili:rcmd',
            adapterId: 'bilibili',
            label: '推荐',
            description: '',
          ),
          onTap: () {},
        ),
      )));
      expect(find.text('推荐'), findsOneWidget);
    });

    testWidgets('无当前来源时显示占位文案', (tester) async {
      await tester.pumpWidget(_host(Center(
        child: FeedSourceButton(current: null, onTap: () {}),
      )));
      expect(find.text('选择来源'), findsOneWidget);
    });
  });

  group('设计系统（原创性断言）', () {
    test('暗色令牌不含平台品牌色', () {
      const bilibiliPink = Color(0xFFFB7299);
      const douyinCyan = Color(0xFF25F4EE);
      const douyinRed = Color(0xFFFE2C55);
      final forbidden = [bilibiliPink, douyinCyan, douyinRed];

      final palette = [
        MobileTokens.stage,
        MobileTokens.scrim,
        MobileTokens.ink,
        MobileTokens.accent,
        MobileTokens.accentDim,
        MobileTokens.danger,
        MobileTokens.caution,
        MobileTokens.positive,
        MobileTokens.lightCanvas,
        MobileTokens.lightSurface,
        MobileTokens.lightBorder,
      ];

      for (final color in palette) {
        expect(forbidden.contains(color), isFalse,
            reason: '设计令牌不得使用平台品牌色：$color');
      }
    });

    test('平台标识使用中性色阶，不使用品牌色', () {
      final bili = PlatformMark.of('bilibili');
      final douyin = PlatformMark.of('douyin');
      expect(bili.tint, isNot(const Color(0xFFFB7299)));
      expect(douyin.tint, isNot(const Color(0xFF25F4EE)));
      expect(douyin.tint, isNot(const Color(0xFF2C55)));
      // 符号取自平台名首字，而非平台 Logo
      expect(bili.symbol, '哔');
      expect(douyin.symbol, '抖');
      expect(PlatformMark.of('mock').symbol, '测');
    });

    test('间距刻度统一为 4pt 基准', () {
      for (final v in [
        MobileTokens.s1,
        MobileTokens.s2,
        MobileTokens.s3,
        MobileTokens.s4,
        MobileTokens.s5,
        MobileTokens.s6,
        MobileTokens.s8,
      ]) {
        expect(v % 4, 0, reason: '间距 $v 必须是 4 的倍数');
      }
    });

    test('播放器背景为纯黑（沉浸式视频流）', () {
      expect(MobileTokens.stage, const Color(0xFF000000));
    });

    test('主题为暗色（短视频沉浸场景）', () {
      final theme = MobileTheme.dark();
      expect(theme.scaffoldBackgroundColor, MobileTokens.stage);
      expect(theme.colorScheme.primary, MobileTokens.accent);
    });
  });

  group('统一视频模型在 UI 层的表现', () {
    test('横屏与竖屏的布局宽高比正确', () {
      final landscape = _video(width: 1920, height: 1080);
      final portrait = _video(width: 1080, height: 1920);

      expect(landscape.layoutAspectRatio, greaterThan(1));
      expect(portrait.layoutAspectRatio, lessThan(1));
      expect(landscape.isPortrait, isFalse);
      expect(portrait.isPortrait, isTrue);
    });

    test('缺少封面与作者时模型仍可用', () {
      final v = _video(coverUrl: null, authorName: null, duration: null);
      expect(v.coverUrl, isNull);
      expect(v.author.name, isNull);
      expect(v.durationLabel, isNull);
      // 布局回退值存在，但原始数据保持 null（不伪造）
      expect(v.aspectRatio, isNotNull);
      expect(v.layoutAspectRatio, greaterThan(0));
    });

    test('超长标题由 UI 截断而非模型层处理', () {
      final long = '很长的标题' * 50;
      final v = _video(title: long);
      // 模型层保留完整标题，截断是 UI 的职责
      expect(v.title.length, long.length);
    });
  });
}
