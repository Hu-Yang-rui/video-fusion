/// 键值存储抽象。
///
/// # 为什么需要这层抽象
///
/// 直接依赖 `shared_preferences` 会把整个 Flutter 框架拉进依赖图，
/// 导致核心层（适配器 / 服务 / 缓存）**无法在纯 Dart 环境下运行**，
/// 也就无法用 `dart run` 做真实网络的冒烟验证。
///
/// 分层后：
///  - 核心层只依赖 [KeyValueStore] 接口，保持平台无关；
///  - Flutter 应用注入 `SharedPreferencesStore`；
///  - 测试与命令行验证注入 [InMemoryStore]，零平台依赖。
library;

/// 键值存储接口。
abstract class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// 列出所有键（用于批量清理）。
  Future<Set<String>> keys();
}

/// 内存实现。用于测试与命令行验证。
class InMemoryStore implements KeyValueStore {
  InMemoryStore([Map<String, String>? initial])
      : _data = {...?initial};

  final Map<String, String> _data;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<Set<String>> keys() async => _data.keys.toSet();

  /// 便于测试断言：当前全部内容。
  Map<String, String> get snapshot => Map.unmodifiable(_data);
}
