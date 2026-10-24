/// 画中画（PiP）的平台通道封装。
///
/// # 为什么不直接用 media_kit
///
/// 项目锁定的 media_kit 1.2.6，其 NativePlayer 没有 `enterPip`（1.2.x 未实现，
/// 后续版本才有）。升级 media_kit 会连带要求升级 libs 与 VideoController API，
/// 风险远大于在 Android 侧写 40 行 PictureInPictureParams。
///
/// # 关键坑
///
/// 进入小窗时 Activity 走 `onPause`，Flutter 会收到
/// [AppLifecycleState.paused]。推荐页原本据此暂停播放——若不做处理，
/// 小窗里就是**静止画面**。因此所有"因生命周期暂停"的判断都必须先看
/// [isActive]：小窗期间不得暂停。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// PiP 状态。全局单例：原生侧只会往一个 channel 推事件。
class PictureInPicture extends ChangeNotifier {
  PictureInPicture._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static final PictureInPicture instance = PictureInPicture._();

  static const MethodChannel _channel = MethodChannel('video_fusion/pip');

  /// 当前平台是否真有这条通道。
  ///
  /// 只有 Android 侧实现了 `video_fusion/pip`。桌面/Web 调用会抛
  /// `MissingPluginException` 并返回 false——如果照样渲染按钮，
  /// 用户点下去只会看到"设备不支持小窗"的提示，那是界面在撒谎。
  /// 所以渲染前先问这一句。
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool _active = false;

  /// 当前是否处于画中画。
  bool get isActive => _active;

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'onPipChanged') return;
    final enabled = call.arguments == true;
    if (_active == enabled) return;
    _active = enabled;
    notifyListeners();
  }

  /// 请求进入画中画。
  ///
  /// 返回 false 表示设备/系统不支持或被 ROM 拒绝——调用方必须如实提示，
  /// **不得**当作成功去改 UI 状态。
  Future<bool> enter({int? width, int? height}) async {
    if (kIsWeb) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('enterPip', <String, Object>{
        if (width != null && height != null && width > 0 && height > 0) ...{
          'width': width,
          'height': height,
        }
      });
      return ok ?? false;
    } on MissingPluginException {
      // 桌面/未接通知的平台：能力不存在
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 查询当前是否已在小窗（主动问一次，不依赖事件时序）。
  Future<bool> queryActive() async {
    try {
      return await _channel.invokeMethod<bool>('isInPip') ?? false;
    } catch (_) {
      return false;
    }
  }
}
