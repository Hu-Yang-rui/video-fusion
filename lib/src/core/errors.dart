/// 平台无关的统一错误模型。
///
/// 设计约束：
///  - 适配器只允许抛出 [FusionException]，不得把平台原始错误结构泄漏到上层。
///  - UI / Service 只依据 [FusionErrorCode] 分支，不认识任何平台专有错误码。
///  - 诊断信息必须已脱敏，不得包含 Cookie / Token / 账号凭证。
library;

/// 统一错误码。
enum FusionErrorCode {
  /// 链接为空或不是合法 URL。
  invalidUrl,

  /// 合法 URL，但不匹配任何已注册平台的链接规则。
  unsupportedPlatform,

  /// 平台匹配成功，但无法提取平台视频 ID。
  videoIdNotFound,

  /// 视频不存在 / 已删除 / 被 UP 主删除。
  videoNotFound,

  /// 视频存在但需要登录才能访问。
  loginRequired,

  /// 视频存在但当前会话权限不足（会员 / 付费 / 私有）。
  permissionDenied,

  /// 视频存在但受地域限制。
  regionRestricted,

  /// 上游请求超时。
  timeout,

  /// 上游返回非预期状态码或非预期结构。
  upstreamError,

  /// 被上游限流（HTTP 412 / 429 或平台限流业务码）。
  rateLimited,

  /// 网络层失败（DNS / 连接重置 / TLS）。
  networkError,

  /// 上游返回成功但内容不可解析（结构变化 / JSON 解析失败）。
  parseError,

  /// 平台能力在当前环境不可用。
  capabilityUnavailable,

  /// 本系统自身的内部错误。
  internalError,
}

/// 面向用户的错误呈现契约。UI 直接消费，不再自行拼装文案。
class ErrorPresentation {
  const ErrorPresentation({
    required this.title,
    required this.detail,
    required this.retryable,
    required this.suggestOpenOriginal,
    required this.authRelated,
  });

  final String title;
  final String detail;

  /// 是否建议重试（幂等的网络类错误）。
  final bool retryable;

  /// 是否应引导用户到原平台访问。
  final bool suggestOpenOriginal;

  /// 是否属于"需要登录/授权"类限制。
  final bool authRelated;
}

/// 统一异常。所有适配器与网络层失败都必须归一化为该类型。
class FusionException implements Exception {
  FusionException({
    required this.code,
    required this.userMessage,
    String? technicalMessage,
    this.upstreamCode,
    this.httpStatus,
    this.retryAfter,
    this.platformId,
    bool? retryable,
    Map<String, Object?>? diagnostics,
    this.cause,
  })  : technicalMessage = technicalMessage ?? userMessage,
        retryable = retryable ?? _defaultRetryable.contains(code),
        diagnostics = diagnostics ?? const {};

  final FusionErrorCode code;

  /// 面向用户的中文提示（不含平台内部术语）。
  final String userMessage;

  /// 面向开发者/报告的技术细节，可含平台业务码。
  final String technicalMessage;

  /// 平台业务错误码原值（仅用于诊断与报告）。
  final Object? upstreamCode;

  /// 上游 HTTP 状态码。
  final int? httpStatus;

  /// 建议的重试等待时长（来自 Retry-After 或平台提示）。
  final Duration? retryAfter;

  /// 归属平台 id；未知平台时为 null。
  final String? platformId;

  final bool retryable;

  /// 附加诊断字段（必须已脱敏）。
  final Map<String, Object?> diagnostics;

  final Object? cause;

  static const Set<FusionErrorCode> _defaultRetryable = {
    FusionErrorCode.timeout,
    FusionErrorCode.networkError,
    FusionErrorCode.rateLimited,
    FusionErrorCode.upstreamError,
    FusionErrorCode.internalError,
  };

  static const Set<FusionErrorCode> _authRelated = {
    FusionErrorCode.loginRequired,
    FusionErrorCode.permissionDenied,
  };

  ErrorPresentation get presentation => ErrorPresentation(
        title: _titleFor(code),
        detail: userMessage,
        retryable: retryable,
        suggestOpenOriginal: true,
        authRelated: _authRelated.contains(code),
      );

  static String _titleFor(FusionErrorCode code) => switch (code) {
        FusionErrorCode.invalidUrl => '链接格式无效',
        FusionErrorCode.unsupportedPlatform => '暂不支持该平台',
        FusionErrorCode.videoIdNotFound => '无法识别视频 ID',
        FusionErrorCode.videoNotFound => '视频不存在',
        FusionErrorCode.loginRequired => '需要登录',
        FusionErrorCode.permissionDenied => '权限不足',
        FusionErrorCode.regionRestricted => '地域受限',
        FusionErrorCode.timeout => '请求超时',
        FusionErrorCode.upstreamError => '平台服务异常',
        FusionErrorCode.rateLimited => '访问过于频繁',
        FusionErrorCode.networkError => '网络连接失败',
        FusionErrorCode.parseError => '数据解析失败',
        FusionErrorCode.capabilityUnavailable => '当前环境不支持',
        FusionErrorCode.internalError => '内部错误',
      };

  Map<String, Object?> toJson() => {
        'code': code.name,
        'userMessage': userMessage,
        'technicalMessage': technicalMessage,
        'upstreamCode': upstreamCode,
        'httpStatus': httpStatus,
        'retryAfterMs': retryAfter?.inMilliseconds,
        'platformId': platformId,
        'retryable': retryable,
        'diagnostics': diagnostics,
      };

  @override
  String toString() =>
      'FusionException(${code.name}, platform=$platformId, upstream=$upstreamCode): $technicalMessage';
}

/// 把任意异常归一化为 [FusionException]，避免上层出现未分类异常。
FusionException normalizeError(Object error, {String? platformId}) {
  if (error is FusionException) return error;
  if (error is FormatException) {
    return FusionException(
      code: FusionErrorCode.parseError,
      userMessage: '平台返回了无法解析的数据，接口结构可能已变化。',
      technicalMessage: 'FormatException: ${error.message}',
      platformId: platformId,
      cause: error,
    );
  }
  return FusionException(
    code: FusionErrorCode.internalError,
    userMessage: '发生未知错误，请稍后重试。',
    technicalMessage: '${error.runtimeType}: $error',
    platformId: platformId,
    cause: error,
  );
}
