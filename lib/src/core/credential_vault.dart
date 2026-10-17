/// 凭证保险库 —— 登录态的安全存储。
///
/// # 安全约束（对应需求三、六、七）
///
///  - 凭证**必须**加密存储，不得明文落盘。使用平台原生安全存储：
///    Windows Credential Manager / Android Keystore / iOS Keychain
///    （由 flutter_secure_storage 提供）。
///  - 凭证**绝不**写入日志。本模块所有出口都经过 [Redactor]。
///  - 凭证**绝不**出现在 UI 文本、错误消息或诊断信息中。
///  - 提供显式登出，登出即彻底清除本地凭证。
///
/// # 关于"用户登录自己的账号"
///
/// 本系统让用户登录**自己的**平台账号，以访问该账号本就可访问的
/// 个性化内容。这不是绕过访问控制：
///  - 用户使用自己的凭证访问自己的数据；
///  - 系统不代用户执行任何未授权的操作；
///  - 系统不索取、不存储用户的密码（仅扫码登录产生的会话 Cookie）。
library;

import 'dart:convert';

import 'logger.dart';
import 'secure_store.dart';

/// 一个已登录的平台会话。
class PlatformSession {
  const PlatformSession({
    required this.platformId,
    required this.displayName,
    required this.userId,
    required this.cookies,
    required this.loggedInAt,
    this.username,
    this.avatarUrl,
  });

  /// 平台标识，例如 'bilibili'。
  final String platformId;

  /// 账号展示名。
  final String displayName;

  /// 平台内用户 ID。
  final String userId;

  /// 会话 Cookie（键值对）。**敏感，不得外泄。**
  final Map<String, String> cookies;

  /// 登录时间（ISO 8601）。
  final String loggedInAt;

  /// 用户名（可获取时）。
  final String? username;

  /// 头像（可获取时）。
  final String? avatarUrl;

  /// 把 Cookie 拼成请求头取值。**仅供 HTTP 层使用，不得记录日志。**
  String get cookieHeader =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// 脱敏摘要，可安全用于日志与 UI 展示。
  Map<String, Object?> get safeSummary => {
        'platformId': platformId,
        'userId': userId,
        'displayName': displayName,
        'cookieCount': cookies.length,
        'cookieNames': cookies.keys.toList(),
        'loggedInAt': loggedInAt,
      };

  Map<String, Object?> toJson() => {
        'platformId': platformId,
        'displayName': displayName,
        'userId': userId,
        'cookies': cookies,
        'loggedInAt': loggedInAt,
        'username': username,
        'avatarUrl': avatarUrl,
      };

  factory PlatformSession.fromJson(Map<String, Object?> json) => PlatformSession(
        platformId: json['platformId'] as String,
        displayName: json['displayName'] as String? ?? '',
        userId: json['userId'] as String? ?? '',
        cookies: (json['cookies'] as Map?)?.map(
              (k, v) => MapEntry('$k', '$v'),
            ) ??
            const {},
        loggedInAt: json['loggedInAt'] as String? ?? '',
        username: json['username'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
      );
}

/// 凭证保险库。
///
/// 通过 [SecureStore] 加密持久化，按平台分键存储。
/// 存储实现由外部注入（移动端注入系统安全存储）。
class CredentialVault {
  CredentialVault({required SecureStore storage, FusionLogger? logger})
      : _storage = storage,
        _logger = logger ?? appLogger;

  final SecureStore _storage;
  final FusionLogger _logger;

  /// 当前存储是否真正加密。UI 应据此如实告知用户保护级别。
  bool get isEncrypted => _storage.isEncrypted;

  /// 存储实现名称，用于诊断与 UI 展示。
  String get storageName => _storage.implementationName;

  static const String _keyPrefix = 'video_fusion.session.';

  /// 内存缓存，避免每次请求都读安全存储。
  final Map<String, PlatformSession> _cache = {};

  /// 读取某个平台的会话。无会话返回 null。
  Future<PlatformSession?> load(String platformId) async {
    final cached = _cache[platformId];
    if (cached != null) return cached;

    try {
      final raw = await _storage.read('$_keyPrefix$platformId');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final session =
          PlatformSession.fromJson(Map<String, Object?>.from(decoded));
      _cache[platformId] = session;
      // 只记录脱敏摘要
      _logger.info('session loaded', session.safeSummary);
      return session;
    } catch (e) {
      // 读取失败按"未登录"处理，并如实记录（不含凭证内容）
      _logger.warn('session load failed', {
        'platform': platformId,
        'error': Redactor.scrubText('$e'),
      });
      return null;
    }
  }

  /// 保存会话（加密写入）。
  Future<void> save(PlatformSession session) async {
    _cache[session.platformId] = session;
    try {
      await _storage.write(
        '$_keyPrefix${session.platformId}',
        jsonEncode(session.toJson()),
      );
      // 日志只记脱敏摘要，绝不记录 cookie 取值
      _logger.info('session saved', session.safeSummary);
    } catch (e) {
      _logger.error('session save failed', {
        'platform': session.platformId,
        'error': Redactor.scrubText('$e'),
      });
      rethrow;
    }
  }

  /// 登出：彻底清除本地凭证。
  Future<void> clear(String platformId) async {
    _cache.remove(platformId);
    try {
      await _storage.delete('$_keyPrefix$platformId');
      _logger.info('session cleared', {'platform': platformId});
    } catch (e) {
      _logger.warn('session clear failed', {
        'platform': platformId,
        'error': Redactor.scrubText('$e'),
      });
    }
  }

  /// 清除全部凭证。
  Future<void> clearAll() async {
    final ids = _cache.keys.toList();
    _cache.clear();
    for (final id in ids) {
      try {
        await _storage.delete('$_keyPrefix$id');
      } catch (_) {
        // 忽略单个失败，继续清理其余
      }
    }
    _logger.info('all sessions cleared', {'count': ids.length});
  }

  /// 当前内存中已加载的会话（不触发磁盘读取）。
  Map<String, PlatformSession> get loadedSessions =>
      Map.unmodifiable(_cache);
}
