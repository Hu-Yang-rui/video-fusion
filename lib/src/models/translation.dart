/// 评论翻译的数据契约（平台无关）。
///
/// # 为什么单独一个模型文件
///
/// 翻译是**跨平台能力**：B 站有官方翻译接口，抖音没有可用接口，
/// 但两者都要在同一个评论面板里呈现一致的状态机
/// （未翻译 / 翻译中 / 已翻译 / 失败可重试）。
///
/// 如果把翻译状态塞进 [VideoComment]，评论模型就会被平台差异污染，
/// 而且评论是不可变值对象、翻译是可变会话状态，生命周期不同。
///
/// # 设计约束（对应需求四·4「翻译功能边界」）
///
///  - **原文永不替换**。翻译结果是与原文并列的第二段文本，
///    模型层不提供"覆盖原文"的字段，从类型上杜绝误用。
///  - **只翻译用户点的那一条**。没有批量翻译入口。
///  - **缓存键必须带评论 ID**。用「评论 ID + 原文 + 目标语言」三元组，
///    避免把 A 评论的译文显示到 B 评论上（原文参与哈希是为了在
///    平台允许编辑评论时自动失效）。
///  - **失败就是失败**。没有"假成功"状态，[CommentTranslationState.failed]
///    必须带可读原因。
library;

/// 翻译请求的目标语言。
///
/// 只列平台**实际支持**的语言，不凭想象扩充。
enum TranslationLanguage {
  /// 简体中文。
  zhHans('zh-Hans', '简体中文'),

  /// 繁体中文。
  zhHant('zh-Hant', '繁體中文'),

  /// 英语。
  en('en', 'English'),

  /// 日语。
  ja('ja', '日本語');

  const TranslationLanguage(this.code, this.label);

  /// 传给平台的语言码。
  final String code;

  /// 面向用户的显示名。
  final String label;

  /// 平台语言码 → 枚举。未知码回退到 [zhHans]。
  static TranslationLanguage fromCode(String? code) {
    if (code == null || code.isEmpty) return TranslationLanguage.zhHans;
    final lower = code.toLowerCase();
    for (final l in TranslationLanguage.values) {
      if (l.code.toLowerCase() == lower) return l;
    }
    // 平台有时用 `zh-CN` / `zh` 表示简体
    if (lower == 'zh' || lower == 'zh-cn' || lower == 'zh_cn') {
      return TranslationLanguage.zhHans;
    }
    if (lower == 'zh-tw' || lower == 'zh_tw' || lower == 'zh-hk') {
      return TranslationLanguage.zhHant;
    }
    return TranslationLanguage.zhHans;
  }
}

/// 一次翻译的结果。
///
/// 不可变值对象；失败用 [ok] 区分，不抛异常（评论面板里
/// 单条翻译失败不该中断整页）。
class TranslationResult {
  const TranslationResult._({
    required this.ok,
    this.text,
    this.sourceLanguage,
    this.targetLanguage = TranslationLanguage.zhHans,
    this.providerId,
    this.errorMessage,
    this.upstreamCode,
  });

  /// 成功。
  factory TranslationResult.success({
    required String text,
    TranslationLanguage targetLanguage = TranslationLanguage.zhHans,
    String? sourceLanguage,
    required String providerId,
  }) =>
      TranslationResult._(
        ok: true,
        text: text,
        targetLanguage: targetLanguage,
        sourceLanguage: sourceLanguage,
        providerId: providerId,
      );

  /// 失败。**必须给出可读原因**，不允许空字符串。
  factory TranslationResult.failure({
    required String errorMessage,
    required String providerId,
    Object? upstreamCode,
    TranslationLanguage targetLanguage = TranslationLanguage.zhHans,
  }) =>
      TranslationResult._(
        ok: false,
        errorMessage: errorMessage,
        providerId: providerId,
        upstreamCode: upstreamCode,
        targetLanguage: targetLanguage,
      );

  /// 是否成功拿到译文。
  final bool ok;

  /// 译文。仅在 [ok] 为 true 时非 null。
  final String? text;

  /// 平台识别出的源语言（可能为 null，平台不总是返回）。
  final String? sourceLanguage;

  /// 目标语言。
  final TranslationLanguage targetLanguage;

  /// 哪个提供方产出的（`bilibili` / 未来其它）。
  ///
  /// UI 可以据此显示"由 XX 提供"，也便于排查。
  final String? providerId;

  /// 失败原因（面向用户的中文文案）。仅在 [ok] 为 false 时非 null。
  final String? errorMessage;

  final Object? upstreamCode;

  /// 译文是否与原文相同（平台有时原样返回，视为"无需翻译"）。
  bool sameAs(String original) =>
      ok && text != null && text!.trim() == original.trim();
}

/// 单条评论的翻译状态。
enum CommentTranslationState {
  /// 还没有请求过。
  idle,

  /// 请求进行中。
  loading,

  /// 已拿到译文。
  done,

  /// 请求失败，可重试。
  failed,
}

/// 一条评论的翻译会话（UI 直接消费）。
class CommentTranslation {
  const CommentTranslation({
    required this.commentId,
    this.state = CommentTranslationState.idle,
    this.result,
    this.visible = false,
  });

  /// 对应 [VideoComment.id]。
  final String commentId;

  final CommentTranslationState state;

  /// 成功时的结果。
  final TranslationResult? result;

  /// 用户是否选择显示译文（默认隐藏，原文优先）。
  final bool visible;

  /// 译文文本（没有则为 null）。
  String? get text => result?.ok == true ? result!.text : null;

  /// 失败原因。
  String? get errorMessage =>
      state == CommentTranslationState.failed ? result?.errorMessage : null;

  CommentTranslation copyWith({
    CommentTranslationState? state,
    TranslationResult? result,
    bool? visible,
  }) =>
      CommentTranslation(
        commentId: commentId,
        state: state ?? this.state,
        result: result ?? this.result,
        visible: visible ?? this.visible,
      );
}

/// 翻译缓存键。
///
/// # 为什么不是只用评论 ID
///
/// 平台允许作者编辑评论；只用 ID 会把旧译文套到新正文上。
/// 把原文也纳入键，正文一变键就变，旧缓存自然失效。
///
/// 目标语言也必须进键——同一评论翻成中文和日文是两份结果。
class TranslationCacheKey {
  const TranslationCacheKey({
    required this.commentId,
    required this.text,
    required this.targetLanguage,
  });

  final String commentId;
  final String text;
  final TranslationLanguage targetLanguage;

  @override
  bool operator ==(Object other) =>
      other is TranslationCacheKey &&
      other.commentId == commentId &&
      other.text == text &&
      other.targetLanguage == targetLanguage;

  @override
  int get hashCode => Object.hash(commentId, text, targetLanguage);

  @override
  String toString() => 'TranslationCacheKey($commentId, ${targetLanguage.code})';
}
