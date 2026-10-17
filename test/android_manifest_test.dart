/// Android 清单与构建配置的静态检查。
///
/// 这个测试文件守护一类**只在 release 版暴露**的缺陷：
/// Flutter 模板默认把 INTERNET 权限放在 debug/profile 的 manifest 里，
/// main/ 里没有。debug 版能联网、release 版全部请求失败，
/// 而且错误信息是笼统的"网络连接失败"，极难定位。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读取项目根目录下的文件。
String _read(String relative) {
  final file = File(relative);
  if (!file.existsSync()) {
    fail('文件不存在: $relative（当前目录 ${Directory.current.path}）');
  }
  return file.readAsStringSync();
}

void main() {
  group('Android 权限声明', () {
    test('main/AndroidManifest.xml 必须声明 INTERNET 权限', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');

      // 这是 release 版能否联网的**唯一**决定因素：
      // debug/profile 的 manifest 不会合并进 release 构建。
      expect(
        manifest.contains('android.permission.INTERNET'),
        isTrue,
        reason: 'main manifest 缺少 INTERNET 权限 → release 版所有网络请求都会失败',
      );
    });

    test('main manifest 声明了网络状态权限', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(
        manifest.contains('android.permission.ACCESS_NETWORK_STATE'),
        isTrue,
        reason: '缺少该权限时无法区分"无网络"与"服务端错误"',
      );
    });

    test('不允许全局开启明文流量', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');

      // 本项目所有接口都是 HTTPS。开启明文流量会降低安全性，
      // 且 Android 9+ 默认已禁止。
      expect(
        manifest.contains('android:usesCleartextTraffic="true"'),
        isFalse,
        reason: '不应全局允许明文 HTTP',
      );
    });

    test('应用名称为中文且非模板默认值', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');

      expect(
        manifest.contains('android:label="video_fusion"'),
        isFalse,
        reason: 'android:label 仍是 Flutter 模板的包名，应改为面向用户的中文名',
      );
    });
  });

  group('Gradle 配置', () {
    test('minSdk 不低于 24', () {
      final gradle = _read('android/app/build.gradle.kts');

      // media_kit 的 Android 实现要求 API 24+。
      // 若改为更低版本，播放会在旧设备上直接崩溃。
      expect(gradle.contains('minSdk'), isTrue);
      expect(gradle.contains('flutter.minSdkVersion'), isTrue,
          reason: 'minSdk 应沿用 Flutter 默认（24），不应硬编码更低值');
    });

    test('release 构建未开启 debuggable', () {
      final gradle = _read('android/app/build.gradle.kts');
      expect(
        gradle.contains('debuggable true') || gradle.contains('debuggable = true'),
        isFalse,
        reason: 'release 版不应可调试',
      );
    });
  });

  group('权限最小化', () {
    test('不申请位置、通讯录、短信等无关权限', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');

      const forbidden = [
        'ACCESS_FINE_LOCATION',
        'ACCESS_COARSE_LOCATION',
        'READ_CONTACTS',
        'READ_SMS',
        'CAMERA',
        'RECORD_AUDIO',
        'READ_EXTERNAL_STORAGE',
        'WRITE_EXTERNAL_STORAGE',
      ];

      for (final perm in forbidden) {
        expect(
          manifest.contains(perm),
          isFalse,
          reason: '本项目不需要 $perm，申请它会损害用户信任且过不了商店审核',
        );
      }
    });

    test('申请的系统权限不超过 3 个', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      final matches = RegExp(r'<uses-permission[^>]*>').allMatches(manifest);

      // 当前只应有 INTERNET + ACCESS_NETWORK_STATE。
      // 这个上限防止后续无意识地堆权限。
      expect(
        matches.length,
        lessThanOrEqualTo(3),
        reason: '权限数量异常增多，请确认每个都是必需的',
      );
    });
  });
}
