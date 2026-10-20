/// HTTP 传输层：统一超时、有限重试、限流识别、UA 管理。
///
/// 合规约束：
///  - 只使用公开的浏览器 UA 与平台要求的 Referer；不携带任何账号凭证。
///  - 重试必须有限，且尊重 Retry-After。
///  - 日志只记录 origin+path，不记录查询串。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'logger.dart';

/// 默认浏览器 UA。不使用账号态 UA，不携带 Cookie。
const String kDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 移动端 UA，用于需要触达移动版页面的场景（如抖音分享页）。
const String kMobileUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1';

/// 单次 HTTP 响应。
class HttpResult {
  const HttpResult({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.url,
    required this.attempts,
    required this.durationMs,
    this.redirectChain = const [],
    this.setCookies = const [],
    this.rawBytes,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final String url;
  final int attempts;
  final int durationMs;
  final List<String> redirectChain;

  /// 响应体的**原始字节**。
  ///
  /// [body] 是把字节按 UTF-8 解码后的文本，对 JSON / HTML 够用，
  /// 但对**二进制响应**（B站弹幕 `seg.so` 是 protobuf）会丢信息：
  /// 非 UTF-8 字节会被替换成 U+FFFD，无法还原。
  ///
  /// 因此二进制接口必须读这个字段，不能读 [body]。
  /// 为 null 表示调用方没有要求保留原始字节（默认不保留，省内存）。
  final Uint8List? rawBytes;

  /// 原始 `Set-Cookie` 头（未合并、未解析）。
  ///
  /// **必须**单独保存而不是塞进 [headers]：`dart:io` 的
  /// `headers.forEach` 会把同名多值用逗号拼成一个字符串，
  /// 而 Cookie 的 `Expires` 本身含逗号，拼接后无法可靠切分。
  ///
  /// 扫码登录类流程（抖音 passport）靠它下发会话凭证，
  /// 丢弃它等于永远换不到 Cookie。
  final List<String> setCookies;

  /// 把 [setCookies] 解析成 name → value。
  ///
  /// 只取第一个 `name=value` 段，忽略 Path/Domain/Expires 等属性。
  /// 值为空的 cookie（服务端用 Max-Age=0 删 cookie）会被跳过。
  Map<String, String> get parsedSetCookies {
    final out = <String, String>{};
    for (final raw in setCookies) {
      final pair = raw.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      out[name] = value;
    }
    return out;
  }

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// 解析 JSON 对象；失败抛 [FusionException]（parseError）。
  Map<String, Object?> jsonObject({String? platformId}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '平台返回了非预期的数据结构。',
        technicalMessage: 'Expected JSON object, got ${decoded.runtimeType}',
        platformId: platformId,
      );
    } on FusionException {
      rethrow;
    } catch (e) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '平台返回了无法解析的数据，接口结构可能已变化。',
        technicalMessage: 'JSON decode failed (body length=${body.length}): $e',
        platformId: platformId,
        cause: e,
      );
    }
  }
}

/// HTTP 客户端配置。
class HttpClientConfig {
  const HttpClientConfig({
    this.timeout = const Duration(seconds: 10),
    this.maxRetries = 2,
    this.retryBaseDelay = const Duration(milliseconds: 350),
    this.userAgent = kDefaultUserAgent,
    this.followRedirects = true,
  });

  final Duration timeout;
  final int maxRetries;
  final Duration retryBaseDelay;
  final String userAgent;
  final bool followRedirects;

  HttpClientConfig copyWith({
    Duration? timeout,
    int? maxRetries,
    Duration? retryBaseDelay,
    String? userAgent,
    bool? followRedirects,
  }) =>
      HttpClientConfig(
        timeout: timeout ?? this.timeout,
        maxRetries: maxRetries ?? this.maxRetries,
        retryBaseDelay: retryBaseDelay ?? this.retryBaseDelay,
        userAgent: userAgent ?? this.userAgent,
        followRedirects: followRedirects ?? this.followRedirects,
      );
}

/// 一次请求的参数。
class HttpRequestSpec {
  const HttpRequestSpec({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.timeout,
    this.maxRetries,
    this.platformId,
    this.followRedirects,
    this.acceptStatuses,
    this.keepRawBytes = false,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final Duration? timeout;
  final int? maxRetries;
  final String? platformId;
  final bool? followRedirects;

  /// 允许接受的状态码；为 null 时接受 2xx。
  final Set<int>? acceptStatuses;

  /// 是否保留响应体的原始字节（见 [HttpResult.rawBytes]）。
  ///
  /// 二进制接口（B站弹幕 protobuf）必须置 true，否则拿不到可解析的数据。
  /// 默认 false：文本响应保留字节只是浪费内存。
  final bool keepRawBytes;
}

/// 统一 HTTP 客户端。
///
/// 使用 dart:io 的 [HttpClient] 而非 package:http，原因是需要：
///  - 精确控制重定向行为（抖音短链需要读取 Location）
///  - 读取底层连接错误类型以区分 DNS/连接失败与超时
class FusionHttpClient {
  FusionHttpClient({HttpClientConfig? config, FusionLogger? logger})
      : _config = config ?? const HttpClientConfig(),
        _logger = logger ?? appLogger;

  final HttpClientConfig _config;
  final FusionLogger _logger;

  static const Set<int> _retryableStatuses = {408, 425, 429, 500, 502, 503, 504, 412};

  HttpClientConfig get config => _config;

  /// 执行一次带超时、有限重试的请求。
  Future<HttpResult> send(HttpRequestSpec spec) async {
    final timeout = spec.timeout ?? _config.timeout;
    final maxRetries = spec.maxRetries ?? _config.maxRetries;
    final followRedirects = spec.followRedirects ?? _config.followRedirects;

    final headers = <String, String>{
      'User-Agent': _config.userAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ...spec.headers,
    };

    final startedAt = DateTime.now();
    var attempt = 0;
    FusionException? lastError;
    final redirectChain = <String>[];

    while (attempt <= maxRetries) {
      final client = HttpClient()..connectionTimeout = timeout;
      client.userAgent = null; // 使用我们自己设置的 header
      try {
        final request = await client
            .openUrl(spec.method, Uri.parse(spec.url))
            .timeout(timeout);
        headers.forEach(request.headers.set);
        request.followRedirects = followRedirects;
        if (spec.body != null) {
          request.add(utf8.encode(spec.body!));
        }

        final response = await request.close().timeout(timeout);
        final status = response.statusCode;

        if (followRedirects == false && status >= 300 && status < 400) {
          final location = response.headers.value('location');
          if (location != null) redirectChain.add(location);
        }

        // 二进制响应必须保留原始字节：UTF-8 解码会把非 UTF-8 字节
        // 替换成 U+FFFD，protobuf 数据因此无法还原。
        Uint8List? rawBytes;
        String body;
        if (spec.keepRawBytes) {
          final chunks = <int>[];
          await response
              .timeout(timeout, onTimeout: (sink) => sink.close())
              .forEach(chunks.addAll);
          rawBytes = Uint8List.fromList(chunks);
          // 仍然给一个 body：调用方可能用它做错误信息（例如 403 的
          // 文本原因）。用 latin1 而不是 utf8，避免解码抛异常。
          body = latin1.decode(rawBytes, allowInvalid: true);
        } else {
          body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(timeout, onTimeout: () => '');
        }

        final responseHeaders = <String, String>{};
        response.headers.forEach((name, values) {
          responseHeaders[name] = values.join(', ');
        });

        // Set-Cookie 单独取原始多值，避免逗号合并破坏解析。
        final setCookies =
            response.headers['set-cookie'] ?? const <String>[];

        final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
        final accepted = spec.acceptStatuses != null
            ? spec.acceptStatuses!.contains(status)
            : status >= 200 && status < 300;

        _logger.http(
          method: spec.method,
          url: spec.url,
          status: status,
          durationMs: durationMs,
        );

        if (accepted) {
          return HttpResult(
            statusCode: status,
            body: body,
            headers: responseHeaders,
            url: spec.url,
            attempts: attempt + 1,
            durationMs: durationMs,
            redirectChain: redirectChain,
            setCookies: setCookies,
            rawBytes: rawBytes,
          );
        }

        final code = _classifyStatus(status);
        final retryAfter = _parseRetryAfter(responseHeaders['retry-after']);
        lastError = FusionException(
          code: code,
          userMessage: _describeStatus(code),
          technicalMessage:
              'HTTP $status from ${Redactor.safeUrl(spec.url)}',
          httpStatus: status,
          upstreamCode: status,
          retryAfter: retryAfter,
          platformId: spec.platformId,
        );

        if (!_retryableStatuses.contains(status) || attempt == maxRetries) {
          throw lastError;
        }
      } on FusionException {
        rethrow;
      } on TimeoutException catch (e) {
        lastError = FusionException(
          code: FusionErrorCode.timeout,
          userMessage: '请求超时，请稍后重试。',
          technicalMessage: 'TimeoutException @ ${Redactor.safeUrl(spec.url)}',
          platformId: spec.platformId,
          cause: e,
        );
        if (attempt == maxRetries) throw lastError;
      } on SocketException catch (e) {
        lastError = FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '网络请求失败，请检查网络连接后重试。',
          technicalMessage:
              'SocketException(${e.osError?.errorCode}): ${e.message} @ ${Redactor.safeUrl(spec.url)}',
          platformId: spec.platformId,
          cause: e,
        );
        if (attempt == maxRetries) throw lastError;
      } on HttpException catch (e) {
        lastError = FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '网络连接被中断，请稍后重试。',
          technicalMessage:
              'HttpException: ${e.message} @ ${Redactor.safeUrl(spec.url)}',
          platformId: spec.platformId,
          cause: e,
        );
        if (attempt == maxRetries) throw lastError;
      } on FormatException catch (e) {
        // URL 解析失败
        throw FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '请求地址无效。',
          technicalMessage: 'Invalid URL: ${e.message}',
          platformId: spec.platformId,
          cause: e,
        );
      } catch (e) {
        lastError = FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '网络请求失败，请稍后重试。',
          technicalMessage: '${e.runtimeType}: $e @ ${Redactor.safeUrl(spec.url)}',
          platformId: spec.platformId,
          cause: e,
        );
        if (attempt == maxRetries) throw lastError;
      } finally {
        client.close(force: true);
      }

      attempt++;
      final backoff = lastError.retryAfter ??
          Duration(
            milliseconds: (_config.retryBaseDelay.inMilliseconds *
                    (1 << (attempt - 1)))
                .clamp(0, 30000),
          );
      _logger.debug('retrying (attempt $attempt/$maxRetries) after ${backoff.inMilliseconds}ms');
      await Future<void>.delayed(backoff);
    }

    throw lastError ??
        FusionException(
          code: FusionErrorCode.internalError,
          userMessage: '请求未能完成。',
          platformId: spec.platformId,
        );
  }

  /// 发起请求并解析 JSON 对象。
  Future<Map<String, Object?>> getJson(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    Set<int>? acceptStatuses,
  }) async {
    final result = await send(HttpRequestSpec(
      url: url,
      headers: headers,
      platformId: platformId,
      timeout: timeout,
      acceptStatuses: acceptStatuses,
    ));
    return result.jsonObject(platformId: platformId);
  }

  /// 发起 GET 并返回文本。
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
    bool keepRawBytes = false,
  }) =>
      send(HttpRequestSpec(
        url: url,
        headers: headers,
        platformId: platformId,
        timeout: timeout,
        followRedirects: followRedirects,
        acceptStatuses: acceptStatuses,
        keepRawBytes: keepRawBytes,
      ));

  /// 发起 POST 并返回文本。
  ///
  /// [body] 为表单或 JSON 字符串；[contentType] 默认表单编码。
  Future<HttpResult> post(
    String url, {
    Map<String, String> headers = const {},
    String? body,
    String contentType = 'application/x-www-form-urlencoded',
    String? platformId,
    Duration? timeout,
    Set<int>? acceptStatuses,
  }) =>
      send(HttpRequestSpec(
        url: url,
        method: 'POST',
        headers: {
          ...headers,
          if (body != null) 'Content-Type': contentType,
        },
        body: body,
        platformId: platformId,
        timeout: timeout,
        acceptStatuses: acceptStatuses,
      ));

  /// 发起 POST 并解析 JSON 对象。
  Future<Map<String, Object?>> postJson(
    String url, {
    Map<String, String> headers = const {},
    String? body,
    String contentType = 'application/x-www-form-urlencoded',
    String? platformId,
    Duration? timeout,
    Set<int>? acceptStatuses,
  }) async {
    final result = await post(
      url,
      headers: headers,
      body: body,
      contentType: contentType,
      platformId: platformId,
      timeout: timeout,
      acceptStatuses: acceptStatuses,
    );
    return result.jsonObject(platformId: platformId);
  }

  /// 解析重定向目标（不跟随），用于短链展开。
  Future<String?> resolveRedirect(String url, {String? platformId}) async {
    try {
      final result = await send(HttpRequestSpec(
        url: url,
        platformId: platformId,
        followRedirects: false,
        acceptStatuses: const {200, 201, 301, 302, 303, 307, 308},
        maxRetries: 1,
      ));
      final location = result.headers['location'];
      if (location != null && location.isNotEmpty) return location;
      // 部分平台用 HTML meta refresh 或 JS 跳转
      final metaMatch = RegExp(
        r'''<meta[^>]+http-equiv=["']?refresh["']?[^>]+content=["']?\d+\s*;\s*url=([^"'>\s]+)''',
        caseSensitive: false,
      ).firstMatch(result.body);
      if (metaMatch != null) return metaMatch.group(1);
      return null;
    } on FusionException {
      return null;
    }
  }

  static FusionErrorCode _classifyStatus(int status) {
    if (status == 412 || status == 429) return FusionErrorCode.rateLimited;
    if (status == 401 || status == 403) return FusionErrorCode.permissionDenied;
    if (status == 404) return FusionErrorCode.videoNotFound;
    if (status == 408 || status == 504) return FusionErrorCode.timeout;
    return FusionErrorCode.upstreamError;
  }

  static String _describeStatus(FusionErrorCode code) => switch (code) {
        FusionErrorCode.rateLimited => '平台暂时限制了访问频率，请稍后再试。',
        FusionErrorCode.permissionDenied => '平台拒绝了本次访问（可能需要登录或权限不足）。',
        FusionErrorCode.videoNotFound => '平台未找到该视频（可能已删除或链接失效）。',
        FusionErrorCode.timeout => '请求超时，请稍后重试。',
        _ => '平台服务暂时不可用，请稍后重试。',
      };

  static Duration? _parseRetryAfter(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds != null) {
      return Duration(milliseconds: (seconds * 1000).clamp(0, 30000));
    }
    final date = DateTime.tryParse(raw);
    if (date != null) {
      final diff = date.difference(DateTime.now()).inMilliseconds;
      return Duration(milliseconds: diff.clamp(0, 30000));
    }
    return null;
  }
}
