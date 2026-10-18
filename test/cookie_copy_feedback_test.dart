/// Cookie 复制反馈的测试。
///
/// 背景：修复前复制后无任何提示。根因是 `showModalBottomSheet`
/// 的 context 找不到外层 ScaffoldMessenger，SnackBar 不显示。
/// 修复方案是改为 sheet 内的内联反馈条。
///
/// 这组测试用源码级断言守护修复不被回退。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/src/ui/settings/cookie_sheet.dart').readAsStringSync();
  });

  group('复制反馈实现', () {
    test('不再使用 ScaffoldMessenger（modal sheet 里不生效）', () {
      // 排除注释行：文档里会提到这个词来解释根因
      final codeLines = src
          .split('\n')
          .where((l) {
            final t = l.trim();
            return !t.startsWith('//') && !t.startsWith('///');
          })
          .join('\n');

      expect(
        codeLines.contains('ScaffoldMessenger.of(context)'),
        isFalse,
        reason: 'modal bottom sheet 的 context 找不到外层 messenger，'
            'SnackBar 不会显示——这是原缺陷的根因',
      );
    });

    test('使用内联反馈状态', () {
      expect(src, contains('_CopyFeedback'));
      expect(src, contains('_CopyFeedbackBar'));
    });

    test('成功与失败有不同文案', () {
      expect(src, contains('已复制'));
      expect(src, contains('复制失败'));
    });

    test('空内容有明确提示，不谎报成功', () {
      expect(src, contains('没有可复制'));
    });

    test('复制失败被 try/catch 捕获', () {
      // 必须真的 await 并捕获异常
      expect(src, contains('await Clipboard.setData'));
      expect(src, contains('catch'));
    });

    test('反馈自动消失（有定时器）', () {
      expect(src, contains('_feedbackTimer'));
      expect(src, contains('Timer('));
    });

    test('反馈文案不含凭证内容', () {
      // 提示文字只描述"复制了什么类别"（what 参数），
      // 不得插入 text / jsonText / headerText 等实际内容变量。
      final feedbackMessages = RegExp(
        r"message:\s*'([^']*)'",
      ).allMatches(src).map((m) => m.group(1)!).toList();

      expect(feedbackMessages, isNotEmpty);

      const forbidden = [
        'text',
        'jsonText',
        'headerText',
        'session',
        'cookies',
        'cookieHeader',
      ];

      for (final msg in feedbackMessages) {
        for (final bad in forbidden) {
          expect(
            msg.contains('\$$bad'),
            isFalse,
            reason: '提示文案 "$msg" 插入了 $bad，可能泄露凭证内容',
          );
        }
        // 不得包含已知的 Cookie 键名
        expect(msg.toLowerCase().contains('sessdata'), isFalse);
        expect(msg.toLowerCase().contains('bili_jct'), isFalse);
      }
    });

    test('反馈文案只使用 what 类别名', () {
      // what 是调用方传入的类别描述（如"完整凭证内容"），
      // 不是凭证本身。这是安全的分层。
      final messages = RegExp(
        r"message:\s*'([^']*)'",
      ).allMatches(src).map((m) => m.group(1)!).toList();

      final usesWhat = messages.where((m) => m.contains(r'$what')).toList();
      expect(
        usesWhat,
        isNotEmpty,
        reason: r'应通过 $what 插入类别名，而不是硬编码或插入内容',
      );
    });
  });

  group('复制入口覆盖', () {
    test('两个复制入口都走统一方法', () {
      // 完整格式按钮 + 每个 code block 的复制
      final copyCalls = RegExp(r'_copy\(').allMatches(src).length;
      expect(
        copyCalls,
        greaterThanOrEqualTo(3),
        reason: '至少 3 处调用：方法定义 + 完整格式按钮 + code block 复制',
      );
    });

    test('复制方法区分 what 参数', () {
      expect(src, contains('required String what'));
    });
  });
}
