/// 设计系统一致性的源码级检查。
///
/// 项目历史上并存过两套 UI 令牌：新版 `Apple*`（当前标准）与
/// 旧版 `Mobile*`。混用会导致从设置页跳到登录页时风格突变
/// （配色、字号、圆角全部不同）。
///
/// 这组测试守护"只有一套设计体系"这个约束，防止旧令牌回流。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 递归收集 lib 下的所有 dart 文件。
List<File> _libFiles() {
  final dir = Directory('lib');
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

void main() {
  group('设计体系唯一性', () {
    test('lib 下不得引用旧版 MobileTokens', () {
      final offenders = <String>[];
      for (final f in _libFiles()) {
        final src = f.readAsStringSync();
        if (src.contains('MobileTokens.')) offenders.add(f.path);
      }
      expect(
        offenders,
        isEmpty,
        reason: '以下文件仍在使用旧版设计令牌：${offenders.join(', ')}',
      );
    });

    test('lib 下不得引用旧版 MobileText', () {
      final offenders = <String>[];
      for (final f in _libFiles()) {
        final src = f.readAsStringSync();
        if (src.contains('MobileText.')) offenders.add(f.path);
      }
      expect(
        offenders,
        isEmpty,
        reason: '以下文件仍在使用旧版文字样式：${offenders.join(', ')}',
      );
    });

    test('旧版 mobile_theme / mobile_widgets 文件已删除', () {
      expect(
        File('lib/src/ui/mobile/mobile_theme.dart').existsSync(),
        isFalse,
        reason: '旧版令牌文件应已删除，避免被重新引用',
      );
      expect(
        File('lib/src/ui/mobile/mobile_widgets.dart').existsSync(),
        isFalse,
        reason: '旧版组件文件应已删除，Apple 侧已有等价实现',
      );
    });

    test('不得残留 import mobile_theme 或 mobile_widgets', () {
      final offenders = <String>[];
      for (final f in _libFiles()) {
        final src = f.readAsStringSync();
        if (src.contains("import 'mobile_theme.dart'") ||
            src.contains("import 'mobile_widgets.dart'") ||
            src.contains("ui/mobile/mobile_theme.dart") ||
            src.contains("ui/mobile/mobile_widgets.dart")) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty, reason: offenders.join(', '));
    });
  });

  group('登录页使用统一设计体系', () {
    late String src;

    setUpAll(() {
      src = File('lib/src/ui/mobile/qr_login_page.dart').readAsStringSync();
    });

    test('使用 AppleColors 而非硬编码配色', () {
      expect(src, contains('AppleColors.of(context)'));
    });

    test('使用 AppleType 排版', () {
      expect(src, contains('AppleType.'));
    });

    test('二维码区域保持白底（扫描所需，不随主题）', () {
      // 这是唯一允许硬编码白色的地方
      expect(src, contains('color: Colors.white'));
    });
  });

  group('链接接入面板使用统一设计体系', () {
    late String src;

    setUpAll(() {
      src =
          File('lib/src/ui/mobile/link_intake_sheet.dart').readAsStringSync();
    });

    test('使用 Apple 组件而非裸 Material 按钮', () {
      expect(src, contains('ApplePrimaryButton'));
      expect(src, contains('AppleTextButton'));
    });

    test('使用 AppleColors 与 AppleType', () {
      expect(src, contains('AppleColors.of(context)'));
      expect(src, contains('AppleType.'));
    });
  });

  group('外部链接工具已独立到 core', () {
    test('core/external_link.dart 存在且导出 openInBrowser', () {
      final f = File('lib/src/core/external_link.dart');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), contains('Future<void> openInBrowser'));
    });

    test('main.dart 从 core 导入而非 UI 层', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src, contains("import 'src/core/external_link.dart'"));
      expect(
        src.contains('ui/mobile/mobile_widgets.dart'),
        isFalse,
        reason: '工具函数不应从 UI 层导入',
      );
    });
  });

  group('详情入口对所有视频开放', () {
    late String src;

    setUpAll(() {
      src = File('lib/src/ui/feed/feed_screen.dart').readAsStringSync();
    });

    test('详情胶囊不再受 isLong 限制', () {
      // 旧实现是 `if (isLong && onOpenDetail != null)`，
      // 导致 <10 分钟的视频完全无法进入详情页
      expect(
        src.contains('if (isLong && onOpenDetail != null)'),
        isFalse,
        reason: '详情入口应对所有视频开放',
      );
    });

    test('isLong 相关死代码已清理', () {
      expect(
        src.contains('bool get _isLong'),
        isFalse,
        reason: '入口开放后 isLong 不再有用途',
      );
    });
  });
}
