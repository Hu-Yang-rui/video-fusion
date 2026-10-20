/// 抖音评论翻译。
///
/// # 接口来源
///
/// 从抖音前端 bundle（`s86.js`）挖到两个接口：
///
/// ```js
/// // 通用文本翻译（U2 = GET）
/// GET /aweme/v1/web/text/translate/?source_text={文本}&target_language={语言}
///
/// // 评论翻译（v_ = POST）
/// POST /aweme/v1/web/comment/translate/
///   body: { comment_id, target_language, comment_text, comment_text_extra }
/// ```
///
/// # 可用性（重要）
///
/// **本 Provider 的可达性取决于 WebView 会话**，而不是简单的"登录/未登录"。
///
/// 历史探测记录：
///
/// | 请求方式 | 结果 |
/// |---|---|
/// | 纯 Dart `ABogus` 签名，无 WebView 会话 | `blocked`（7 字节） |
/// | WebView 会话 + 页面内签名 | 待本 Provider 实测确认 |
///
/// `blocked` 是**网关层拦截**，既不是 404（路径不存在）也不是 `code=8`
/// （缺登录）。它说明请求没走到业务层，通常是缺少页面级会话环境
/// （UIFID / secsdk / 浏览器指纹），而不是接口不存在。
///
/// 因此本 Provider 的设计是：
///
///  1. **不声明"抖音没有翻译接口"**——那是已被推翻的结论。
///  2. 通过 [DouyinWebSigner] 在真实 WebView 会话里发请求。
///  3. 把每一次失败按**实际响应**分类，不猜测。
///  4. [isAvailable] 只反映会话是否就绪，不反映接口是否可用；
///     接口可用性由首次真实请求的结果决定（见 [lastProbeResult]）。
///
/// # 与 B 站翻译的关键区别
///
/// B 站 `/x/v2/reply/translate` 是 **rpid 驱动**的：服务端拿评论 ID
/// 去 B 站自己的评论库查原文再翻译，**不接收任意文本**。
///
/// 抖音的 `/comment/translate/` 同时接收 `comment_id` **和** `comment_text`，
/// 说明它可能不依赖服务端查库（文本随请求带上）。这一点尚未验证，
/// 但决定了"能否翻译任意文本"——如果成立，抖音翻译比 B 站更通用。
library;

import 'dart:convert';

import '../core/logger.dart';
import '../models/translation.dart';
import '../core/translation_service.dart' show TranslationProvider;
import '../adapters/douyin/web_signer.dart';

/// 一次翻译探测的结果分类。
///
/// 分类依据是**实际响应**，不是猜测。`blocked` 与 `404` 必须分开。
enum DouyinTranslateOutcome {
  /// 成功拿到译文。
  success,

  /// 网关拦截（响应体是 `blocked`）。
  ///
  /// 不是"接口不存在"，也不是"缺登录"。通常是会话环境不足。
  gatewayBlocked,

  /// 接口要求登录（`status_code=8`）。
  loginRequired,

  /// 路径不存在（HTTP 404 / `Unsupported path`）。
  pathNotFound,

  /// 会话未就绪（WebView 还没拿到 UIFID）。
  sessionNotReady,

  /// 其它失败（网络、超时、响应结构变化）。
  other,
}

/// 抖音评论翻译 Provider。
class DouyinTranslationProvider implements TranslationProvider {
  DouyinTranslationProvider({
    required DouyinWebSigner signer,
    FusionLogger? logger,
  })  : _signer = signer,
        _logger = logger ?? appLogger;

  final DouyinWebSigner _signer;
  final FusionLogger _logger;

  /// 最近一次真实请求的分类结果。null 表示还没发过请求。
  ///
  /// 用途：让 UI 能区分"会话没就绪"与"接口被拦"，
  /// 而不是笼统显示"翻译失败"。
  DouyinTranslateOutcome? lastProbeResult;

  /// 最近一次失败的原始信息（脱敏后），用于诊断。
  String? lastProbeDetail;

  @override
  String get id => 'douyin';

  @override
  String get displayName => '抖音翻译';

  /// 会话就绪即可尝试。
  ///
  /// 注意：这不代表接口一定可用——接口可用性由真实请求决定。
  /// 这里只挡住"会话都没起来就发请求"这种注定失败的情况。
  @override
  bool get isAvailable => _signer.isReady;

  @override
  String? get unavailableReason {
    if (_signer.isReady) return null;
    return '抖音会话尚未就绪，无法使用翻译。请稍后重试。';
  }

  @override
  Future<TranslationResult> translate({
    required String text,
    required TranslationLanguage targetLanguage,
    String? commentId,
  }) async {
    if (!_signer.isReady) {
      lastProbeResult = DouyinTranslateOutcome.sessionNotReady;
      return TranslationResult.failure(
        errorMessage: '抖音会话尚未就绪，请稍后重试。',
        providerId: id,
        targetLanguage: targetLanguage,
      );
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return TranslationResult.failure(
        errorMessage: '没有可翻译的文本。',
        providerId: id,
        targetLanguage: targetLanguage,
      );
    }

    // 有评论 ID → 走评论翻译（能带上下文，质量更好）
    // 没有 → 走通用文本翻译
    final hasCommentId = (commentId ?? '').isNotEmpty;
    return hasCommentId
        ? _translateComment(
            commentId: commentId!,
            text: trimmed,
            targetLanguage: targetLanguage,
          )
        : _translateText(text: trimmed, targetLanguage: targetLanguage);
  }

  /// 评论翻译：`POST /aweme/v1/web/comment/translate/`
  Future<TranslationResult> _translateComment({
    required String commentId,
    required String text,
    required TranslationLanguage targetLanguage,
  }) async {
    final body = jsonEncode({
      'comment_id': commentId,
      'target_language': targetLanguage.code,
      'comment_text': text,
      'comment_text_extra': '',
    });

    try {
      final res = await _signer.requestPost(
        path: '/aweme/v1/web/comment/translate/',
        params: const {},
        body: body,
        contentType: 'application/json',
        requireFullUifid: false,
      );
      return _classify(
        res,
        targetLanguage: targetLanguage,
        path: '/aweme/v1/web/comment/translate/',
      );
    } catch (e) {
      return _onException(e, targetLanguage: targetLanguage);
    }
  }

  /// 通用文本翻译：`GET /aweme/v1/web/text/translate/`
  Future<TranslationResult> _translateText({
    required String text,
    required TranslationLanguage targetLanguage,
  }) async {
    try {
      final res = await _signer.request(
        path: '/aweme/v1/web/text/translate/',
        params: {
          'source_text': text,
          'target_language': targetLanguage.code,
        },
        requireFullUifid: false,
      );
      return _classify(
        res,
        targetLanguage: targetLanguage,
        path: '/aweme/v1/web/text/translate/',
      );
    } catch (e) {
      return _onException(e, targetLanguage: targetLanguage);
    }
  }

  /// 按**实际响应**分类，不猜测。
  TranslationResult _classify(
    DouyinCommentResponse res, {
    required TranslationLanguage targetLanguage,
    required String path,
  }) {
    final raw = res.body;
    final trimmed = raw.trim();

    // ── 1. 网关拦截：响应体恰好是 blocked
    if (trimmed == 'blocked') {
      lastProbeResult = DouyinTranslateOutcome.gatewayBlocked;
      lastProbeDetail = 'body=blocked, status=${res.statusCode}, path=$path';
      _logger.warn('douyin translate: gateway blocked', {
        'path': path,
        'status': res.statusCode,
        'note': 'not a 404; request did not reach business layer',
      });
      return TranslationResult.failure(
        errorMessage: '抖音翻译请求被网关拦截（不是接口不存在）。'
            '通常是当前会话环境不足，可稍后重试。',
        providerId: id,
        targetLanguage: targetLanguage,
        upstreamCode: 'blocked',
      );
    }

    // ── 2. 路径不存在
    if (res.statusCode == 404 || trimmed.contains('Unsupported path')) {
      lastProbeResult = DouyinTranslateOutcome.pathNotFound;
      lastProbeDetail = 'status=${res.statusCode}, body=${_truncate(trimmed)}';
      return TranslationResult.failure(
        errorMessage: '翻译路径不可用（$path）。',
        providerId: id,
        targetLanguage: targetLanguage,
        upstreamCode: res.statusCode,
      );
    }

    // ── 3. 空响应
    if (trimmed.isEmpty) {
      lastProbeResult = DouyinTranslateOutcome.other;
      lastProbeDetail = 'empty body, status=${res.statusCode}';
      return TranslationResult.failure(
        errorMessage: '抖音翻译返回空响应（HTTP ${res.statusCode}）。',
        providerId: id,
        targetLanguage: targetLanguage,
        upstreamCode: res.statusCode,
      );
    }

    // ── 4. 解析 JSON
    final json = res.tryParseJson();
    if (json == null) {
      lastProbeResult = DouyinTranslateOutcome.other;
      lastProbeDetail = 'unparsable body=${_truncate(trimmed)}';
      return TranslationResult.failure(
        errorMessage: '抖音翻译返回了无法解析的内容。',
        providerId: id,
        targetLanguage: targetLanguage,
        upstreamCode: res.statusCode,
      );
    }

    final code = json['status_code'];
    // `status_code=8` = 用户未登录（与其它抖音写操作一致）
    if (code == 8) {
      lastProbeResult = DouyinTranslateOutcome.loginRequired;
      lastProbeDetail = 'status_code=8';
      return TranslationResult.failure(
        errorMessage: '抖音翻译需要登录后才能使用。',
        providerId: id,
        targetLanguage: targetLanguage,
        upstreamCode: code,
      );
    }
    if (code != null && code != 0) {
      lastProbeResult = DouyinTranslateOutcome.other;
      lastProbeDetail = 'status_code=$code msg=${json['status_msg']}';
      return TranslationResult.failure(
        errorMessage: '抖音翻译失败：${json['status_msg'] ?? 'code=$code'}',
        providerId: id,
        targetLanguage: targetLanguage,
        upstreamCode: code,
      );
    }

    // ── 5. 取译文
    final text = _extractTranslation(json);
    if (text == null || text.trim().isEmpty) {
      lastProbeResult = DouyinTranslateOutcome.other;
      lastProbeDetail = 'no translation field in ${_truncate(trimmed)}';
      return TranslationResult.failure(
        errorMessage: '抖音翻译返回成功但没有译文。',
        providerId: id,
        targetLanguage: targetLanguage,
        upstreamCode: code,
      );
    }

    lastProbeResult = DouyinTranslateOutcome.success;
    lastProbeDetail = null;
    return TranslationResult.success(
      text: text.trim(),
      targetLanguage: targetLanguage,
      providerId: id,
    );
  }

  /// 从响应里找译文。
  ///
  /// 字段名未在真实成功响应中确认过（历史探测都停在 blocked），
  /// 因此按**可能性从高到低**依次尝试，全部落空就如实失败，
  /// 不伪造内容。
  String? _extractTranslation(Map<String, Object?> json) {
    const candidates = [
      'translated_text',
      'translation',
      'translate_text',
      'target_text',
      'text',
      'result',
      'data',
    ];
    for (final key in candidates) {
      final v = json[key];
      if (v is String && v.trim().isNotEmpty) return v;
      if (v is Map) {
        for (final inner in const [
          'translated_text',
          'translation',
          'text',
          'content',
        ]) {
          final iv = v[inner];
          if (iv is String && iv.trim().isNotEmpty) return iv;
        }
      }
    }
    return null;
  }

  TranslationResult _onException(
    Object e, {
    required TranslationLanguage targetLanguage,
  }) {
    final text = '$e';
    lastProbeResult = DouyinTranslateOutcome.other;
    lastProbeDetail = _truncate(text, 200);
    _logger.warn('douyin translate: exception', {
      'error': _truncate(text, 160),
    });
    return TranslationResult.failure(
      errorMessage: '抖音翻译请求失败：${text.split('\n').first}',
      providerId: id,
      targetLanguage: targetLanguage,
    );
  }

  static String _truncate(String s, [int n = 120]) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}
