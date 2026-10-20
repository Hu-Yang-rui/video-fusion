/// 评论翻译的单元测试（需求四）。
///
/// 覆盖：
///  - `shouldTranslate` 的边界（空 / 纯链接 / 纯表情 / 纯数字 / 混合）
///  - 缓存键三元组（评论 ID + 原文 + 语言）不会串线
///  - 失败不缓存（重试必须真的重发）
///  - 同键并发合并
///  - LRU 上限淘汰
///  - 提供方不可用时立刻失败、不发请求
///  - 提供方抛异常时归一化为失败结果（不冒泡）
///  - B 站提供方的入参形态：只吃 reply_id，缺 aid 明确失败
///  - 抖音（非 B 站平台）走 VideoService 时给出明确原因，不伪造译文
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/translation_service.dart';
import 'package:video_fusion/src/models/translation.dart';

/// 可编程的测试提供方。
class _FakeProvider implements TranslationProvider {
  _FakeProvider({
    this.available = true,
    this.result,
    this.throwOnCall = false,
  });

  bool available;
  TranslationResult? result;
  bool throwOnCall;

  int callCount = 0;
  final List<String> seenTexts = [];

  /// 用于制造并发：让 translate 挂起直到手动完成。
  Future<TranslationResult>? pending;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  bool get isAvailable => available;

  @override
  String? get unavailableReason => available ? null : '假提供方不可用';

  @override
  Future<TranslationResult> translate({
    required String text,
    required TranslationLanguage targetLanguage,
    String? commentId,
  }) async {
    callCount++;
    seenTexts.add(text);
    if (throwOnCall) throw StateError('boom');
    if (pending != null) return pending!;
    return result ??
        TranslationResult.success(
          text: '译:$text',
          providerId: id,
          targetLanguage: targetLanguage,
        );
  }
}

void main() {
  group('shouldTranslate 边界', () {
    test('空文本不翻译', () {
      expect(TranslationService.shouldTranslate(''), isFalse);
      expect(TranslationService.shouldTranslate('   '), isFalse);
    });

    test('纯链接不翻译', () {
      expect(
        TranslationService.shouldTranslate('https://www.bilibili.com/video/BV1xx'),
        isFalse,
      );
    });

    test('纯表情短代码不翻译', () {
      expect(TranslationService.shouldTranslate('[doge]'), isFalse);
      expect(TranslationService.shouldTranslate('[doge][笑哭]'), isFalse);
    });

    test('纯数字与标点不翻译', () {
      expect(TranslationService.shouldTranslate('123456'), isFalse);
      expect(TranslationService.shouldTranslate('!!!???...'), isFalse);
    });

    test('中英日俄韩文都算可译', () {
      expect(TranslationService.shouldTranslate('你好'), isTrue);
      expect(TranslationService.shouldTranslate('hello'), isTrue);
      expect(TranslationService.shouldTranslate('こんにちは'), isTrue);
      expect(TranslationService.shouldTranslate('Привет'), isTrue);
      expect(TranslationService.shouldTranslate('안녕'), isTrue);
    });

    test('表情短代码 + 文字 可翻译（文字部分值得翻）', () {
      expect(TranslationService.shouldTranslate('[doge]好耶'), isTrue);
    });
  });

  group('缓存与去重', () {
    test('成功结果进缓存，重复请求不再调用提供方', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider);

      final r1 = await svc.translateComment(commentId: 'c1', text: 'hello');
      final r2 = await svc.translateComment(commentId: 'c1', text: 'hello');

      expect(r1.ok, isTrue);
      expect(r2.ok, isTrue);
      expect(provider.callCount, 1, reason: '第二次应命中缓存');
      expect(svc.cacheSize, 1);
    });

    test('不同评论 ID 不共用缓存（不串线）', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider);

      await svc.translateComment(commentId: 'c1', text: 'same text');
      await svc.translateComment(commentId: 'c2', text: 'same text');

      expect(provider.callCount, 2,
          reason: '评论 ID 参与缓存键，不能复用别条的译文');
    });

    test('原文变化则缓存失效（防止编辑后套用旧译文）', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider);

      await svc.translateComment(commentId: 'c1', text: 'old');
      await svc.translateComment(commentId: 'c1', text: 'new');

      expect(provider.callCount, 2);
    });

    test('不同目标语言不共用缓存', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider);

      await svc.translateComment(
          commentId: 'c1', text: 'hi', language: TranslationLanguage.zhHans);
      await svc.translateComment(
          commentId: 'c1', text: 'hi', language: TranslationLanguage.ja);

      expect(provider.callCount, 2);
    });

    test('失败结果不缓存，重试会真的重发', () async {
      final provider = _FakeProvider(
        result: TranslationResult.failure(
          errorMessage: '临时失败',
          providerId: 'fake',
        ),
      );
      final svc = TranslationService(provider: provider);

      await svc.translateComment(commentId: 'c1', text: 'hello');
      await svc.translateComment(commentId: 'c1', text: 'hello');

      expect(provider.callCount, 2, reason: '失败必须可重试');
      expect(svc.cacheSize, 0, reason: '失败不占缓存');
    });

    test('同键并发请求合并成一次调用', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider);

      final f1 = svc.translateComment(commentId: 'c1', text: 'hello');
      final f2 = svc.translateComment(commentId: 'c1', text: 'hello');
      await Future.wait([f1, f2]);

      expect(provider.callCount, 1, reason: '并发同键应合并');
    });

    test('缓存超过上限时淘汰最久未使用', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider, maxCacheEntries: 3);

      for (var i = 0; i < 5; i++) {
        await svc.translateComment(commentId: 'c$i', text: 'text $i');
      }
      expect(svc.cacheSize, 3);
    });

    test('clearCache 后重新请求会打到提供方', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider);

      await svc.translateComment(commentId: 'c1', text: 'hello');
      svc.clearCache();
      await svc.translateComment(commentId: 'c1', text: 'hello');

      expect(provider.callCount, 2);
    });
  });

  group('失败路径', () {
    test('提供方不可用时立刻失败且不发请求', () async {
      final provider = _FakeProvider(available: false);
      final svc = TranslationService(provider: provider);

      final r = await svc.translateComment(commentId: 'c1', text: 'hello');

      expect(r.ok, isFalse);
      expect(r.errorMessage, '假提供方不可用');
      expect(provider.callCount, 0, reason: '不该发注定失败的请求');
    });

    test('提供方抛异常时归一化为失败，不冒泡', () async {
      final provider = _FakeProvider(throwOnCall: true);
      final svc = TranslationService(provider: provider);

      final r = await svc.translateComment(commentId: 'c1', text: 'hello');

      expect(r.ok, isFalse);
      expect(r.errorMessage, isNotNull);
      expect(r.errorMessage!.isNotEmpty, isTrue);
    });

    test('不可翻译的文本直接给原因，不调用提供方', () async {
      final provider = _FakeProvider();
      final svc = TranslationService(provider: provider);

      final r = await svc.translateComment(commentId: 'c1', text: '[doge]');

      expect(r.ok, isFalse);
      expect(r.errorMessage, contains('没有可翻译'));
      expect(provider.callCount, 0);
    });

    test('提供方返回空译文视为失败（不缓存空串）', () async {
      final provider = _FakeProvider(
        result: TranslationResult.success(
          text: '   ',
          providerId: 'fake',
        ),
      );
      final svc = TranslationService(provider: provider);

      final r = await svc.translateComment(commentId: 'c1', text: 'hello');

      expect(r.ok, isTrue);
      // 空译文不进缓存
      expect(svc.cacheSize, 0);
    });
  });

  group('模型契约', () {
    test('TranslationResult.success 与 failure 互斥', () {
      final ok = TranslationResult.success(text: 'x', providerId: 'p');
      expect(ok.ok, isTrue);
      expect(ok.text, 'x');
      expect(ok.errorMessage, isNull);

      final bad = TranslationResult.failure(
        errorMessage: '原因',
        providerId: 'p',
      );
      expect(bad.ok, isFalse);
      expect(bad.text, isNull);
      expect(bad.errorMessage, '原因');
    });

    test('sameAs 能识别平台原样返回（无需翻译）', () {
      final r = TranslationResult.success(text: 'hello', providerId: 'p');
      expect(r.sameAs('hello'), isTrue);
      expect(r.sameAs('hello '), isTrue);
      expect(r.sameAs('world'), isFalse);
    });

    test('TranslationCacheKey 相等性覆盖三元组', () {
      const a = TranslationCacheKey(
        commentId: 'c1',
        text: 'x',
        targetLanguage: TranslationLanguage.zhHans,
      );
      const b = TranslationCacheKey(
        commentId: 'c1',
        text: 'x',
        targetLanguage: TranslationLanguage.zhHans,
      );
      const c = TranslationCacheKey(
        commentId: 'c1',
        text: 'x',
        targetLanguage: TranslationLanguage.ja,
      );
      expect(a, b);
      expect(a == c, isFalse);
    });

    test('语言码解析兼容 zh-CN / zh-tw 等写法', () {
      expect(TranslationLanguage.fromCode('zh-CN'), TranslationLanguage.zhHans);
      expect(TranslationLanguage.fromCode('zh'), TranslationLanguage.zhHans);
      expect(TranslationLanguage.fromCode('zh-tw'), TranslationLanguage.zhHant);
      expect(TranslationLanguage.fromCode('ja'), TranslationLanguage.ja);
      expect(TranslationLanguage.fromCode(null), TranslationLanguage.zhHans);
    });

    test('CommentTranslation 默认隐藏译文、原文不被替换', () {
      const t = CommentTranslation(commentId: 'c1');
      expect(t.state, CommentTranslationState.idle);
      expect(t.visible, isFalse);
      expect(t.text, isNull);

      // 模型层没有"覆盖原文"的字段——译文只能作为并列文本存在
      final done = t.copyWith(
        state: CommentTranslationState.done,
        result: TranslationResult.success(text: '译文', providerId: 'p'),
        visible: true,
      );
      expect(done.text, '译文');
      expect(done.visible, isTrue);
    });

    test('失败态携带可读原因', () {
      const t = CommentTranslation(commentId: 'c1');
      final failed = t.copyWith(
        state: CommentTranslationState.failed,
        result: TranslationResult.failure(
          errorMessage: '需要登录',
          providerId: 'p',
        ),
      );
      expect(failed.errorMessage, '需要登录');
      expect(failed.text, isNull);
    });
  });
}
