/// 安全存储抽象。
///
/// # 为什么需要这层抽象
///
/// 直接依赖 `flutter_secure_storage` 有两个问题：
///  1. 把 Flutter 插件拉进核心层，使核心无法在纯 Dart 下验证；
///  2. 其 Windows 实现依赖 ATL（atlstr.h），在未安装 ATL 的
///     构建环境上会导致整个桌面端编译失败。
///
/// 抽象后：
///  - 移动端（本产品的主目标）注入 [FlutterSecureStore]，使用
///    Android Keystore / iOS Keychain 做真正的硬件级加密；
///  - 测试与命令行验证注入 [InMemorySecureStore]（**不加密**，
///    仅用于验证流程，且会通过 [isEncrypted] 如实暴露这一点）。
///
/// 安全性约束：任何实现都**不得**把凭证明文写入普通文件。
library;

/// 安全存储接口。
abstract class SecureStore {
  /// 该实现是否提供真正的加密保护。
  ///
  /// 调用方（尤其是 UI）应据此如实告知用户当前凭证的保护级别，
  /// **不得**在未加密的实现上声称"已加密保存"。
  bool get isEncrypted;

  /// 实现名称，用于诊断与 UI 展示。
  String get implementationName;

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// 内存实现：**不提供加密**。
///
/// 仅用于单元测试与命令行验证。进程退出即丢失，
/// 因此不会产生持久化的明文凭证。
class InMemorySecureStore implements SecureStore {
  InMemorySecureStore([Map<String, String>? initial]) : _data = {...?initial};

  final Map<String, String> _data;

  @override
  bool get isEncrypted => false;

  @override
  String get implementationName => '内存（测试用，不加密）';

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
}
