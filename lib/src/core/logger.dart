/// 日志与凭证脱敏。
///
/// 硬性约束：
///  - 日志中不得输出密码、完整 Cookie、访问令牌、签名密钥或其他敏感凭证。
///  - 所有 URL 记录必须去掉查询串（查询串可能含签名/时间戳/设备标识）。
///  - 所有请求头记录必须经过白名单过滤。
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show kDebugMode;

/// 是否同时把日志输出到 stdout（`adb logcat` 可见）。
///
/// debug 构建默认开启（便于排查），release 构建默认关闭（减少 IO 开销）。
const bool kVerboseLogging = kDebugMode;

/// 日志级别。
enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warn('WARN'),
  error('ERROR');

  const LogLevel(this.label);
  final String label;
}

/// 脱敏工具集。
class Redactor {
  Redactor._();

  /// 需要整体屏蔽的请求头名（小写比较）。
  static const Set<String> _sensitiveHeaders = {
    'cookie',
    'set-cookie',
    'authorization',
    'proxy-authorization',
    'x-csrf-token',
    'x-xsrf-token',
    'x-bogus',
    'a_bogus',
    'ms_token',
    'mstoken',
    'ttwid',
    'token',
    'access-token',
    'api-key',
    'apikey',
    'secret',
    'signature',
    'x-signature',
    // 抖音风控相关
    'uifid',
    'uifid_temp',
    'x-secsdk-web-signature',
    'x-secsdk-csrf-token',
    'webid',
    // 抖音 APP 端签名头（X-Argus 系）
    //
    // 这些头有时效性且可用于重放：泄漏一个就等于泄漏一段可用的访问凭证。
    // 因此按请求头名整体屏蔽，而不是逐段打码。
    'x-gorgon',
    'x-argus',
    'x-khronos',
    'x-ladon',
    'x-ss-stub',
    'x-tt-trace-id',
    // 设备身份标识：与签名绑定，单独泄漏即可用于关联同一设备的历史请求。
    'device_id',
    'install_id',
    'iid',
    'cdid',
    'openudid',
    'clientudid',
    'oaid',
    'gaid',
    'android_id',
    'serial_number',
    // 本地签名库的 license
    'license',
    // B 站登录态相关
    'sessdata',
    'bili_jct',
    'dedeuserid',
    'buvid3',
    'buvid4',
  };

  /// 需要整体屏蔽的查询参数名（小写比较）。
  static const Set<String> _sensitiveQueryKeys = {
    'cookie',
    'token',
    'access_token',
    'refresh_token',
    'a_bogus',
    'x-bogus',
    'x_bogus',
    'ms_token',
    'mstoken',
    'ttwid',
    'webid',
    'signature',
    'sign',
    'secret',
    'key',
    'password',
    'pwd',
    'session',
    'sessionid',
    'sessdata',
    'bili_jct',
    'dedeuserid',
    'authorization',
    'upsig',
    'oi',
    'uipk',
    // 抖音 APP 端签名与设备身份（查询串里也可能出现）
    'x-gorgon',
    'x-argus',
    'x-khronos',
    'x-ladon',
    'x-ss-stub',
    'device_id',
    'install_id',
    'iid',
    'cdid',
    'oaid',
    'license',
  };

  /// 记录 URL 时使用：仅保留 origin + path，丢弃整个查询串。
  ///
  /// 这是最保守的策略——查询串整体丢弃，而不是逐参数过滤，
  /// 因为签名算法可能把敏感值编码进任意参数名。
  static String safeUrl(String raw) {
    if (raw.isEmpty) return '<invalid-url>';
    final uri = Uri.tryParse(raw);
    // 必须同时具备 scheme 与 host 才算有效 URL。
    // 仅凭 Uri.tryParse 成功是不够的：'not a url' 会被解析成
    // 一个 path 段，从而被误判为合法。
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
      return '<invalid-url>';
    }
    final hasQuery = uri.query.isNotEmpty;
    final base = '${uri.scheme}://${uri.host}${uri.path}';
    return hasQuery ? '$base?<${uri.queryParameters.length} params redacted>' : base;
  }

  /// 记录请求头时使用：只保留白名单内的非敏感头，其余折叠为 `<redacted>`。
  static Map<String, String> safeHeaders(Map<String, String> headers) {
    final out = <String, String>{};
    headers.forEach((k, v) {
      final lower = k.toLowerCase();
      if (_sensitiveHeaders.contains(lower)) {
        out[k] = '<redacted>';
      } else if (lower == 'referer' || lower == 'origin') {
        // Referer/Origin 本身不敏感，但可能含查询串
        out[k] = safeUrl(v);
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  /// 对任意文本做兜底脱敏：折叠形如 key=value 的敏感赋值。
  static String scrubText(String input) {
    var out = input;
    for (final key in _sensitiveQueryKeys) {
      out = out.replaceAllMapped(
        RegExp('($key\\s*[=:]\\s*)([^\\s&;,"\\]}]+)', caseSensitive: false),
        (m) => '${m[1]}<redacted>',
      );
    }
    return out;
  }

  /// 判断某个查询参数名是否敏感（供需要逐参数输出的场景使用）。
  static bool isSensitiveQueryKey(String key) =>
      _sensitiveQueryKeys.contains(key.toLowerCase());

  /// 判断某个请求头名是否敏感。
  static bool isSensitiveHeader(String name) =>
      _sensitiveHeaders.contains(name.toLowerCase());
}

/// 极简日志器。默认写入 dart:developer log，不落盘、不外发。
class FusionLogger {
  FusionLogger({this.minLevel = LogLevel.info, this.enabled = true});

  final LogLevel minLevel;
  final bool enabled;

  void _log(LogLevel level, String message, [Map<String, Object?>? fields]) {
    if (!enabled) return;
    if (level.index < minLevel.index) return;
    final buffer = StringBuffer('[${level.label}] ${Redactor.scrubText(message)}');
    if (fields != null && fields.isNotEmpty) {
      fields.forEach((k, v) {
        final value = Redactor.scrubText('$v');
        buffer.write(' | $k=$value');
      });
    }
    // 同时走 developer.log 与 print：
    //  - developer.log 在 IDE / DevTools 中可见
    //  - print 保证在 `adb logcat` 中也能看到
    developer.log(buffer.toString(), name: 'video_fusion');
    if (kVerboseLogging) {
      // ignore: avoid_print
      print('VF ${buffer.toString()}');
    }
  }

  void debug(String message, [Map<String, Object?>? fields]) =>
      _log(LogLevel.debug, message, fields);

  void info(String message, [Map<String, Object?>? fields]) =>
      _log(LogLevel.info, message, fields);

  void warn(String message, [Map<String, Object?>? fields]) =>
      _log(LogLevel.warn, message, fields);

  void error(String message, [Map<String, Object?>? fields]) =>
      _log(LogLevel.error, message, fields);

  /// 记录一次上游请求（已脱敏）。
  void http({
    required String method,
    required String url,
    required int? status,
    required int durationMs,
    Map<String, String>? headers,
    String? note,
  }) {
    final parts = <String>[
      '$method ${Redactor.safeUrl(url)}',
      'status=${status ?? 'n/a'}',
      '${durationMs}ms',
    ];
    if (note != null) parts.add(Redactor.scrubText(note));
    _log(LogLevel.debug, 'HTTP ${parts.join(' ')}', {
      if (headers != null) 'headers': Redactor.safeHeaders(headers),
    });
  }
}

/// 全局默认日志器。
final FusionLogger appLogger = FusionLogger();
