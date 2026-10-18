/// 详情页去工具化改造的验证。
///
/// 这些是**源码级断言**：确认详情页不再把技术参数堆在首屏，
/// 且评论入口存在。之所以用源码检查而不是 widget 测试，
/// 是因为详情页依赖 media_kit 原生解码，纯 Dart 测试无法构建播放器。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('详情页去工具化', () {
    late String src;

    setUpAll(() {
      src = _read('lib/src/ui/detail/video_detail_screen.dart');
    });

    test('技术信息默认收起，不是常驻卡片', () {
      // 必须有折叠开关
      expect(src, contains('_techExpanded'));
      // 默认值必须是 false（收起）
      expect(src, contains('bool _techExpanded = false;'));
    });

    test('不再有"播放信息"常驻分组', () {
      // 旧实现用 AppleGroupedSection(header: '播放信息')
      expect(
        src.contains("header: '播放信息'"),
        isFalse,
        reason: '技术参数不应以常驻分组出现在详情页',
      );
    });

    test('不再有"当前环境限制"常驻分组', () {
      expect(
        src.contains("header: '当前环境限制'"),
        isFalse,
        reason: '限制说明应并入折叠的技术信息，不单独占据首屏',
      );
    });

    test('不再有"简介"卡片式分组', () {
      expect(
        src.contains("header: '简介'"),
        isFalse,
        reason: '简介应以正文呈现，而不是包在卡片里',
      );
    });

    test('评论入口存在', () {
      expect(src, contains('_buildCommentEntry'));
      expect(src, contains('CommentSheet'));
    });

    test('评论入口是一行内容而非按钮', () {
      // 用 InkWell + Row + chevron，不是 ApplePrimaryButton
      expect(src, contains('Icons.chat_bubble_outline_rounded'));
      expect(src, contains('Icons.chevron_right_rounded'));
    });

    test('作者区不再是卡片', () {
      // 旧实现把作者包在 AppleGroupedSection 里
      final authorSection = RegExp(
        r'AppleGroupedSection\([\s\S]{0,200}v\.author\.avatarUrl',
      );
      expect(authorSection.hasMatch(src), isFalse);
    });

    test('有互动控制器且正确释放', () {
      expect(src, contains('InteractionController?'));
      expect(src, contains('_interaction?.dispose()'));
    });

    test('技术信息仍可展开查看（不丢信息）', () {
      // 折叠不等于删除：展开后仍能看到播放方式与限制
      expect(src, contains('_playbackModeLabel()'));
      expect(src, contains('limitations'));
    });
  });

  group('设置页去工具化', () {
    late String src;

    setUpAll(() {
      src = _read('lib/src/ui/settings/settings_screen.dart');
    });

    test('平台行不再暴露内部 ID', () {
      // 旧实现直接显示 adapter.id（如 "bilibili"）
      expect(
        src.contains('adapter.id,\n                style: AppleType.caption2'),
        isFalse,
        reason: '内部标识不应展示给用户',
      );
    });

    test('平台能力说明默认收起', () {
      expect(src, contains('_expandedPlatforms'));
      expect(src, contains("expanded ? '收起' : '详情'"));
    });

    test('不再用大量能力标签堆砌', () {
      // 旧实现用 Wrap + Container 生成一堆胶囊标签
      final tagLoop = RegExp(r"for \(final t in tags\)");
      expect(tagLoop.hasMatch(src), isFalse);
    });

    test('保留用户能感知的能力摘要', () {
      expect(src, contains('应用内播放'));
      expect(src, contains('搜索'));
      expect(src, contains('直播'));
    });
  });

  group('直播间去技术化', () {
    late String src;

    setUpAll(() {
      src = _read('lib/src/ui/live/live_room_screen.dart');
    });

    test('不向用户显示流协议名（HLS/FLV）', () {
      expect(
        src.contains('protocolLabel'),
        isFalse,
        reason: '协议名是技术细节，观众只关心画质',
      );
    });

    test('仍显示清晰度', () {
      expect(src, contains('qualityLabel'));
    });
  });

  group('评论列表性能约束', () {
    late String src;

    setUpAll(() {
      src = _read('lib/src/ui/interaction/interaction_controller.dart');
    });

    test('comments getter 缓存包装器，不每次新建', () {
      expect(
        src.contains('_commentsView ??= List.unmodifiable(_comments)'),
        isTrue,
        reason: '每次访问都 List.unmodifiable 会导致滚动掉帧',
      );
    });

    test('列表变更后使缓存失效', () {
      expect(src, contains('_invalidateCommentsView'));
    });
  });
}
