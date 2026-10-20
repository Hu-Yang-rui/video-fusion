/// 统一的评论翻译服务。
///
/// # 架构（对应需求四·3 的建议结构，但贴合本仓库现有习惯）
///
/// ```
/// TranslationService            ← 唯一对外入口：缓存 / 去重 / 错误归一化 / 语言设置
///   └── TranslationProvider     ← 提供方契约（谁真的能翻译）
///         └── BilibiliTranslationProvider  ← 已验证的 B 站官方接口
/// ```
///
/// **抖音没有可用翻译接口**（见 `APK-API-REPORT.md` §八 的调查结论），
/// 因此抖音评论走的是同一个 [TranslationService]，由 B 站提供方产出译文。
/// 这就是需求里说的"抖音优先复用 B 站翻译能力"——但必须诚实标注
/// 提供方，不能让用户以为是抖音官方翻译。
///
/// # 为什么不用 `Adapter` 命名
///
/// 本仓库里 `Adapter` 专指 [PlatformAdapter]（平台内容接入）。
/// 翻译不是"接入一个平台"，而是"调用一个能力"，叫 Provider 更准确，
/// 也避免与 `BilibiliTranslationAdapter` 这种容易误解的名字混在一起。
///
/// # 缓存策略
///
///  - 键 = [TranslationCacheKey]（评论 ID + 原文 + 目标语言）
///  - 容量上限 200 条，LRU 淘汰（评论列表滚动时不会无限增长）
///  - 只缓存**成功**结果。失败不缓存，用户点重试必须真的重新请求
///  - 同一键的并发请求会合并（in-flight 去重），避免连点打爆接口
library;

import 'dart:collection';

import '../models/translation.dart';
import 'errors.dart';

/// 翻译提供方契约。
///
/// 实现方负责：调用平台接口、把平台响应映射成 [TranslationResult]、
/// 把平台错误码映射成可读中文原因。
///
/// **不得**在这里做缓存——缓存归 [TranslationService]，这样多个提供方
/// 共享同一份缓存语义。
abstract class TranslationProvider {
  /// 提供方标识（`bilibili` / ...）。会写进 [TranslationResult.providerId]。
  String get id;

  /// 面向用户的提供方名称（"B 站翻译"）。
  String get displayName;

  /// 该提供方当前是否可用（例如是否需要登录、登录态是否有效）。
  ///
  /// 返回 false 时 [TranslationService] 会立刻给出明确失败，
  /// 而不是发一个注定失败的请求。
  bool get isAvailable;

  /// 不可用的原因（面向用户）。可用时为 null。
  String? get unavailableReason;

  /// 翻译一段文本。
  ///
  /// 实现方**不得抛异常**：所有失败都要映射成
  /// [TranslationResult.failure]，否则一条评论的失败会冒泡成整页错误。
  Future<TranslationResult> translate({
    required String text,
    required TranslationLanguage targetLanguage,
    String? commentId,
  });
}

/// 统一的翻译服务：缓存 + 去重 + 错误归一化。
class TranslationService {
  TranslationService({
    required TranslationProvider provider,
    this.targetLanguage = TranslationLanguage.zhHans,
    this.maxCacheEntries = 200,
  }) : _provider = provider;

  TranslationProvider _provider;

  /// 当前目标语言（用户可在设置里改）。
  TranslationLanguage targetLanguage;

  /// 缓存容量上限。
  final int maxCacheEntries;

  /// LRU 缓存：LinkedHashMap 的插入顺序即访问顺序（get 时重插）。
  final LinkedHashMap<TranslationCacheKey, TranslationResult> _cache =
      LinkedHashMap<TranslationCacheKey, TranslationResult>();

  /// 正在进行的请求，用于合并同键并发。
  final Map<TranslationCacheKey, Future<TranslationResult>> _inFlight = {};

  /// 提供方（只读，供 UI 显示"由 XX 提供"）。
  TranslationProvider get provider => _provider;

  /// 替换提供方（例如登录态变化后切换实现）。会清空缓存。
  set provider(TranslationProvider p) {
    _provider = p;
    _cache.clear();
  }

  /// 当前提供方是否可用。
  bool get isAvailable => _provider.isAvailable;

  /// 不可用原因。
  String? get unavailableReason => _provider.unavailableReason;

  /// 缓存条目数（测试与诊断用）。
  int get cacheSize => _cache.length;

  /// 清空缓存。
  void clearCache() => _cache.clear();

  /// 判断这段文本是否**值得翻译**。
  ///
  /// 需求四·4 明确要求：空文本、纯表情短代码、纯链接、纯数字不翻译。
  /// 这条逻辑放在服务层而不是 UI，保证所有入口一致。
  static bool shouldTranslate(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    // 纯链接
    if (RegExp(r'^https?://\S+$').hasMatch(t)) return false;
    // 纯表情短代码，例如 [doge] / [笑哭][笑哭]
    if (RegExp(r'^(?:\[[^\[\]]{1,20}\])+$').hasMatch(t)) return false;
    // 纯数字 / 标点 / 空白（没有任何可译字符）
    if (!RegExp(r'[A-Za-z\u00C0-\u024F\u0400-\u04FF\u3040-\u30FF\u4E00-\u9FFF\uAC00-\uD7AF]')
        .hasMatch(t)) {
      return false;
    }
    return true;
  }

  /// 翻译一条评论。
  ///
  /// 返回的一定是 [TranslationResult]，不抛异常。
  Future<TranslationResult> translateComment({
    required String commentId,
    required String text,
    TranslationLanguage? language,
  }) async {
    final target = language ?? targetLanguage;

    if (!shouldTranslate(text)) {
      return TranslationResult.failure(
        errorMessage: '这条内容没有可翻译的文字。',
        providerId: _provider.id,
        targetLanguage: target,
      );
    }

    final key = TranslationCacheKey(
      commentId: commentId,
      text: text,
      targetLanguage: target,
    );

    // 1) 命中缓存
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // LRU：重新插入到末尾
      return cached;
    }

    // 2) 合并并发请求
    final pending = _inFlight[key];
    if (pending != null) return pending;

    // 3) 提供方不可用：立刻失败，不发注定失败的请求
    if (!_provider.isAvailable) {
      return TranslationResult.failure(
        errorMessage: _provider.unavailableReason ?? '翻译服务当前不可用。',
        providerId: _provider.id,
        targetLanguage: target,
      );
    }

    final future = _runProvider(key, text, target, commentId);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<TranslationResult> _runProvider(
    TranslationCacheKey key,
    String text,
    TranslationLanguage target,
    String commentId,
  ) async {
    TranslationResult result;
    try {
      result = await _provider.translate(
        text: text,
        targetLanguage: target,
        commentId: commentId,
      );
    } catch (e) {
      // 提供方契约要求不抛，但真抛了也不能冒泡到 UI
      final err = normalizeError(e, platformId: _provider.id);
      result = TranslationResult.failure(
        errorMessage: err.userMessage,
        providerId: _provider.id,
        upstreamCode: err.upstreamCode,
        targetLanguage: target,
      );
    }

    if (result.ok && (result.text ?? '').trim().isNotEmpty) {
      _putCache(key, result);
    }
    return result;
  }

  void _putCache(TranslationCacheKey key, TranslationResult result) {
    _cache[key] = result;
    while (_cache.length > maxCacheEntries) {
      // 淘汰最久未使用（LinkedHashMap 头部）
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
    }
  }
}

/// 一个"永远不可用"的提供方。
///
/// 用于平台确实没有翻译能力、且没有可复用的统一服务时。
/// **不给假译文**：调用即失败，UI 如实显示不可用。
class UnavailableTranslationProvider implements TranslationProvider {
  const UnavailableTranslationProvider({
    required this.id,
    required this.displayName,
    required this.reason,
  });

  @override
  final String id;

  @override
  final String displayName;

  /// 不可用的具体原因（会直接显示给用户）。
  final String reason;

  @override
  bool get isAvailable => false;

  @override
  String? get unavailableReason => reason;

  @override
  Future<TranslationResult> translate({
    required String text,
    required TranslationLanguage targetLanguage,
    String? commentId,
  }) async =>
      TranslationResult.failure(
        errorMessage: reason,
        providerId: id,
        targetLanguage: targetLanguage,
      );
}
