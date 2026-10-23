/// 版本号一致性回归（2026-10-23）。
///
/// # 为什么需要这个测试
///
/// 模拟器实测发现：设置页「关于」显示 `1.0.0`，而实际安装的 APK 是
/// `0.9.0`（`aapt2 dump badging` 确认 `versionName='0.9.0'`）。
///
/// 原因是版本号在 `settings_screen.dart` 里**硬编码**成 `'1.0.0'`，
/// 发版时只改了 `pubspec.yaml`，这里忘了跟着改。
///
/// 后果不是"显示难看"，而是**用户报问题时给的版本号是错的**——
/// 排查方向直接被带偏（以为在查 1.0.0 的行为）。
///
/// 这个测试断言三处必须一致：
///  1. `pubspec.yaml` 的 `version:`
///  2. `settings_screen.dart` 的 `_appVersion`
///  3. 当前 README 里写的版本（如果有）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从 pubspec.yaml 取版本号（`version: 0.9.0+11` → `0.9.0`）。
String _pubspecVersion() {
  final text = File('pubspec.yaml').readAsStringSync();
  final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
      .firstMatch(text);
  if (m == null) {
    fail('pubspec.yaml 里找不到 version:');
  }
  return m.group(1)!;
}

void main() {
  group('版本号一致性', () {
    test('设置页 _appVersion 与 pubspec.yaml 一致', () {
      final src = File('lib/src/ui/settings/settings_screen.dart')
          .readAsStringSync();
      final m = RegExp(r"_appVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
          .firstMatch(src);
      expect(m, isNotNull,
          reason: 'settings_screen.dart 里必须有 _appVersion 常量');

      expect(
        m!.group(1),
        _pubspecVersion(),
        reason: '发版时 pubspec.yaml 和设置页显示的版本必须同步——'
            '不一致会让用户报出错误的版本号',
      );
    });

    test('设置页不再硬编码 1.0.0', () {
      final src = File('lib/src/ui/settings/settings_screen.dart')
          .readAsStringSync();
      expect(
        src.contains("trailingText: '1.0.0'"),
        isFalse,
        reason: '这就是当初的 bug：硬编码 1.0.0 而实际发的是 0.9.0',
      );
    });

    test('pubspec version 格式合法（语义化 + build number）', () {
      final text = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*(\S+)$', multiLine: true).firstMatch(text);
      expect(m, isNotNull);
      final v = m!.group(1)!;
      expect(
        RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$').hasMatch(v),
        isTrue,
        reason: '应为 X.Y.Z+N（Flutter 用它生成 versionName/versionCode），实际=$v',
      );
    });
  });
}
