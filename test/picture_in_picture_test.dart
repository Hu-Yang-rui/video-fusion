/// 画中画（PiP）通道封装的行为约束。
///
/// 原生侧实现见 `android/app/src/main/kotlin/.../MainActivity.kt`；
/// 这里用 mock method channel 验证 Dart 侧的三条契约：
///  1. 原生拒绝/不存在时**返回 false**（不能假装成功）
///  2. 原生的 PiP 状态回调能真正驱动 [PictureInPicture.isActive]
///  3. 只有 Android 声明支持——桌面端不渲染小窗按钮
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/player/picture_in_picture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('video_fusion/pip');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final pip = PictureInPicture.instance;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    // 单例跨用例共享，复位成"不在小窗"
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onPipChanged', false),
      ),
      (_) {},
    );
  });

  test('原生返回 true → enter() 返回 true', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    expect(await pip.enter(), isTrue);
    expect(calls.single.method, 'enterPip');
  });

  test('宽高作为参数传给原生', () async {
    MethodCall? seen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return true;
    });

    await pip.enter(width: 1920, height: 1080);
    final args = (seen!.arguments as Map).cast<String, Object?>();
    expect(args['width'], 1920);
    expect(args['height'], 1080);
  });

  test('原生拒绝（返回 false/null）→ 如实返回 false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(await pip.enter(), isFalse);

    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await pip.enter(), isFalse);
  });

  test('原生抛异常（ROM 拒绝/通道异常）→ 返回 false，不往上冒', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'PIP_REJECTED'),
    );
    expect(await pip.enter(), isFalse);
  });

  test('原生回调能驱动 isActive 并通知监听者', () async {
    var notified = 0;
    void listener() => notified++;
    pip.addListener(listener);
    addTearDown(() => pip.removeListener(listener));

    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onPipChanged', true),
      ),
      (_) {},
    );
    expect(pip.isActive, isTrue);
    expect(notified, 1);

    // 重复同一状态不应再通知（避免整页无意义重建）
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onPipChanged', true),
      ),
      (_) {},
    );
    expect(notified, 1);
  });

  test('queryActive 读取原生当前状态', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isInPip');
      return true;
    });
    expect(await pip.queryActive(), isTrue);
  });

  test('只有 Android 声明支持小窗（桌面端不渲染按钮）', () {
    // 测试环境 defaultTargetPlatform 是 android（flutter_test 默认），
    // 这条断言的是"判据是平台能力，不是写死 true"。
    expect(pip.isSupported, defaultTargetPlatform == TargetPlatform.android);
  });
}
