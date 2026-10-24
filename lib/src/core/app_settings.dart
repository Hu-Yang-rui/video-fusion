/// 应用级设置（主题、连播、倍速、自动播放等）。
///
/// 走 [KeyValueStore] 抽象：核心层保持纯 Dart，可在 `flutter test` 里
/// 用 [InMemoryStore] 直接验证。
///
/// 用 [ChangeNotifier] 而不是每次读存储：主题这类设置会被多个页面同时
/// 读取，读一次缓存 + 变更通知才不会每个页面各自异步拉一次。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'key_value_store.dart';

/// 明暗模式。
enum ThemeModeChoice {
  system('system'),
  light('light'),
  dark('dark');

  const ThemeModeChoice(this.wire);
  final String wire;

  static ThemeModeChoice fromWire(String? v) => ThemeModeChoice.values
      .firstWhere((e) => e.wire == v, orElse: () => ThemeModeChoice.system);
}

class AppSettings extends ChangeNotifier {
  AppSettings({required KeyValueStore storage}) : _storage = storage;

  static const String _key = 'video_fusion.settings.v1';

  final KeyValueStore _storage;

  bool _loaded = false;
  bool _saving = false;

  ThemeModeChoice _themeMode = ThemeModeChoice.system;
  ThemeModeChoice get themeMode => _themeMode;
  set themeMode(ThemeModeChoice v) {
    if (_themeMode == v) return;
    _themeMode = v;
    _changed();
  }

  /// 短剧看完自动播下一集。
  bool _autoPlayNext = true;
  bool get autoPlayNext => _autoPlayNext;
  set autoPlayNext(bool v) {
    if (_autoPlayNext == v) return;
    _autoPlayNext = v;
    _changed();
  }

  /// 倍速（1.0 = 原速）。播放面板选档与长按临时加速都基于它。
  double _playbackRate = 1.0;
  double get playbackRate => _playbackRate;
  set playbackRate(double v) {
    final clamped = v.clamp(0.5, 3.0);
    if (_playbackRate == clamped) return;
    _playbackRate = clamped;
    _changed();
  }

  /// 从存储加载。加载前所有 getter 返回默认值，UI 不会闪。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = await _storage.read(_key);
      if (raw != null && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is Map) {
          final m = Map<String, Object?>.from(d);
          _themeMode = ThemeModeChoice.fromWire(m['themeMode'] as String?);
          _autoPlayNext = m['autoPlayNext'] as bool? ?? true;
          _playbackRate =
              ((m['playbackRate'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 3.0);
        }
      }
    } catch (_) {
      // 读失败按默认值继续：设置不是关键路径，不能因为它挡住启动。
    }
    _loaded = true;
    notifyListeners();
  }

  void _changed() {
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> _persist() async {
    // 连点开关时不并发写：写进行中就把最终状态留到最后一次落盘。
    if (_saving) return;
    _saving = true;
    try {
      await _storage.write(
        _key,
        jsonEncode({
          'themeMode': _themeMode.wire,
          'autoPlayNext': _autoPlayNext,
          'playbackRate': _playbackRate,
        }),
      );
    } catch (_) {
      // 落盘失败不影响本次会话内的生效
    } finally {
      _saving = false;
    }
  }
}
