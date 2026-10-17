/// 基于 flutter_secure_storage 的安全存储实现。
///
/// 这是**唯一**接触安全存储插件的文件，被隔离在 `platform/` 下，
/// 使核心层保持纯 Dart。
///
/// 各平台底层：
///  - Android：Android Keystore（RSA-OAEP 包裹密钥 + AES-GCM 加密数据）
///  - iOS/macOS：Keychain
///  - Windows：凭据管理器（**需要 ATL**；若构建环境缺少 ATL，
///    桌面端将无法编译——本产品主目标是移动端，故可接受）
///  - Linux：libsecret
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../secure_store.dart';

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
            );

  final FlutterSecureStorage _storage;

  @override
  bool get isEncrypted => true;

  @override
  String get implementationName => '系统安全存储（Android Keystore / iOS Keychain）';

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
