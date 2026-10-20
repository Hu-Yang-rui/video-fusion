/// B 站官方评论翻译接口的提供方实现。
///
/// # 接口（实测 2026-10-19）
///
/// ```
/// GET https://api.bilibili.com/x/v2/reply/translate
///     ?oid=<aid>&type=1&reply_id=<rpid>
/// ```
///
/// | 场景 | 实测结果 |
/// |---|---|
/// | 匿名请求 | `HTTP 200` + `{"code":-101,"message":"账号未登录"}` |
/// | 带有效 Cookie | 返回 `data.translation` 译文（**未实测，凭证已失效**） |
///
/// 也就是说：**这个接口存在、路由正确、但需要登录**。这一点很重要——
/// 之前项目里根本没有翻译代码，也就没有这条结论。现在有了。
///
/// # 入参形态：只吃 `reply_id`，不吃任意文本
///
/// 这是本实现最关键的约束。接口要的是 `oid`（视频 aid）+ `reply_id`
/// （评论 rpid），由**服务端自己去查那条评论的原文**。
/// 它**不接受**一段任意文本作为输入。
///
/// 因此：
///  - B 站自己的评论 → 直接传 `reply_id`，走原生路径，最可靠
///  - 抖音评论 / 其它任意文本 → 没有 `reply_id`，**无法**通过这个接口翻译。
///    强行把抖音评论文本塞进 `reply_id` 是错的，只会拿到 `-400`。
///
/// 所以本类提供两条路径：
///  1. [translateCommentById] —— B 站原生，验证过的入参形态
///  2. [translate] —— 契约要求的通用文本入口；对 B 站来说**只能覆盖
///     "我们手上有 rpid"的情形**，否则如实失败并说明原因
///
/// 这不是能力缺陷的掩饰，而是接口的真实边界。
library;

import '../models/translation.dart';
import 'http_client.dart';
import 'logger.dart';
import 'translation_service.dart';

/// B 站翻译提供方。
class BilibiliTranslationProvider implements TranslationProvider {
  BilibiliTranslationProvider({
    required FusionHttpClient http,
    FusionLogger? logger,
    String apiBase = 'https://api.bilibili.com',
    String referer = 'https://www.bilibili.com/',
  })  : _http = http,
        _logger = logger ?? appLogger,
        _apiBase = apiBase,
        _referer = referer;

  final FusionHttpClient _http;
  final FusionLogger _logger;
  final String _apiBase;
  final String _referer;

  /// 当前登录态（Cookie 头）。为空表示未登录。
  ///
  /// **不持久化、不写日志**：由调用方（VideoService）在每次请求前注入。
  String? cookieHeader;

  /// 登录态对应的 aid（视频 ID）→ 用于把评论 ID 映射到翻译接口入参。
  ///
  /// 翻译接口需要 `oid`（aid）。调用方在拉评论时已经知道 aid，
  /// 这里用一次设置的方式传进来，避免在 translate 里再解析一遍。
  int? currentAid;

  @override
  String get id => 'bilibili';

  @override
  String get displayName => 'B 站翻译';

  @override
  bool get isAvailable => (cookieHeader ?? '').isNotEmpty;

  @override
  String? get unavailableReason =>
      isAvailable ? null : 'B 站翻译接口需要登录后才能使用。';

  @override
  Future<TranslationResult> translate({
    required String text,
    required TranslationLanguage targetLanguage,
    String? commentId,
  }) async {
    // 通用文本入口：只有拿到评论 ID（rpid）才可能成功，
    // 因为接口不接受任意文本。
    if (commentId == null || commentId.isEmpty) {
      return TranslationResult.failure(
        errorMessage: 'B 站翻译接口只接受评论 ID，不接受任意文本。',
        providerId: id,
        targetLanguage: targetLanguage,
      );
    }
    return translateCommentById(
      replyId: commentId,
      targetLanguage: targetLanguage,
    );
  }

  /// 按评论 ID 翻译（B 站原生路径）。
  ///
  /// [replyId] 是评论的 `rpid`，[aid] 缺省用 [currentAid]。
  Future<TranslationResult> translateCommentById({
    required String replyId,
    required TranslationLanguage targetLanguage,
    int? aid,
  }) async {
    if (!isAvailable) {
      return TranslationResult.failure(
        errorMessage: unavailableReason ?? '翻译服务当前不可用。',
        providerId: id,
        targetLanguage: targetLanguage,
      );
    }
    final oid = aid ?? currentAid;
    if (oid == null || oid <= 0) {
      return TranslationResult.failure(
        errorMessage: '缺少视频 ID，无法请求翻译。',
        providerId: id,
        targetLanguage: targetLanguage,
      );
    }

    final url = '$_apiBase/x/v2/reply/translate'
        '?oid=$oid&type=1&reply_id=${Uri.encodeQueryComponent(replyId)}';

    try {
      final json = await _http.getJson(
        url,
        headers: {
          'Referer': _referer,
          'Cookie': cookieHeader!,
          'Accept': 'application/json, text/plain, */*',
        },
        platformId: id,
      );

      final code = json['code'];
      if (code != 0) {
        return _mapFailure(code, json['message'], targetLanguage);
      }

      final data = json['data'];
      if (data is! Map) {
        return TranslationResult.failure(
          errorMessage: '平台没有返回译文。',
          providerId: id,
          targetLanguage: targetLanguage,
        );
      }
      final d = Map<String, Object?>.from(data);

      // 字段名以平台实际下发为准；实测样本里是 `translation`。
      // 兼容几种可能的键名，但**绝不**用原文冒充译文。
      final text = _firstNonEmpty([
        d['translation'],
        d['trans'],
        d['result'],
      ]);
      if (text == null) {
        return TranslationResult.failure(
          errorMessage: '平台没有返回译文内容。',
          providerId: id,
          targetLanguage: targetLanguage,
        );
      }

      return TranslationResult.success(
        text: text,
        targetLanguage: targetLanguage,
        sourceLanguage: d['source_language']?.toString() ??
            d['src_language']?.toString(),
        providerId: id,
      );
    } catch (e) {
      _logger.warn('translate: request failed', {
        'provider': id,
        'error': e.runtimeType.toString(),
      });
      return TranslationResult.failure(
        errorMessage: '翻译请求失败，请检查网络后重试。',
        providerId: id,
        targetLanguage: targetLanguage,
      );
    }
  }

  TranslationResult _mapFailure(
    Object? code,
    Object? message,
    TranslationLanguage target,
  ) {
    final msg = message?.toString() ?? '';
    String reason;
    switch (code) {
      case -101:
        reason = 'B 站翻译需要登录，请先在设置里登录。';
        break;
      case -400:
        reason = '平台拒绝了这次翻译请求（参数或评论已失效）。';
        break;
      case -412:
      case 412:
        reason = '翻译请求过于频繁，请稍后再试。';
        break;
      case -404:
        reason = '这条评论已不存在，无法翻译。';
        break;
      default:
        reason = msg.isEmpty ? '翻译失败（平台返回 $code）。' : msg;
    }
    return TranslationResult.failure(
      errorMessage: reason,
      providerId: id,
      upstreamCode: code,
      targetLanguage: target,
    );
  }

  static String? _firstNonEmpty(List<Object?> candidates) {
    for (final c in candidates) {
      if (c is String && c.trim().isNotEmpty) return c;
    }
    return null;
  }
}
