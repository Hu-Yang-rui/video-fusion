/// shared_preferences 实现的键值存储。
///
/// 这是**唯一**接触 Flutter 插件的存储文件，被隔离在 `platform/` 下，
/// 使核心层保持纯 Dart、可在命令行下用真实网络验证。
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../key_value_store.dart';

class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore();

  SharedPreferences? _prefs;

  Future<SharedPreferences> _ensure() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  @override
  Future<String?> read(String key) async => (await _ensure()).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await _ensure()).setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await (await _ensure()).remove(key);
  }

  @override
  Future<Set<String>> keys() async => (await _ensure()).getKeys();
}
