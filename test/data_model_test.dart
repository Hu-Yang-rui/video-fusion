/// 数据模型与缓存测试。
///
/// 覆盖需求八「数据测试」：
///  - 视频元数据完整
///  - 标题、封面或作者信息缺失
///  - 同一视频重复导入
///  - 不同平台的视频 ID 相同
///  - 原始 URL 与来源平台准确保留
///  - 元数据缓存失效后能够重新获取
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/cache.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

UnifiedVideo _video({
  required String platformId,
  required String platformVideoId,
  String? title,
  String? coverUrl,
  String? authorName,
  String? authorId = 'a1',
  int? width,
  int? height,
  double? duration,
}) =>
    UnifiedVideo(
      id: makeVideoId(platformId, platformVideoId),
      platformId: platformId,
      platformVideoId: platformVideoId,
      originalUrl: 'https://example.com/original/$platformVideoId?x=1',
      canonicalUrl: 'https://example.com/video/$platformVideoId',
      title: title ?? '测试标题',
      author: VideoAuthor(name: authorName, platformAuthorId: authorId),
      coverUrl: coverUrl,
      durationSeconds: duration,
      aspectRatio: normalizeAspectRatio(width, height),
      width: width,
      height: height,
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      diagnostics: const VideoDiagnostics(
        adapterId: 'test',
        upstreamEndpoint: '/test',
        fromCache: false,
        fetchDurationMs: 12,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('统一视频模型', () {
    test('完整元数据', () {
      final v = _video(
        platformId: 'bilibili',
        platformVideoId: 'BV1GJ411x7h7',
        title: '【官方 MV】Never Gonna Give You Up',
        coverUrl: 'https://i1.hdslb.com/x.jpg',
        authorName: '索尼音乐中国',
        width: 1920,
        height: 1080,
        duration: 213,
      );
      expect(v.title, isNotEmpty);
      expect(v.author.name, '索尼音乐中国');
      expect(v.coverUrl, isNotNull);
      expect(v.durationSeconds, 213);
      expect(v.aspectRatio, closeTo(1.777, 0.01));
      expect(v.durationLabel, '03:33');
      expect(v.isPortrait, isFalse);
    });

    test('标题、封面、作者缺失时模型仍然有效', () {
      final v = _video(
        platformId: 'mock',
        platformVideoId: 'x1',
        title: '仅有标题',
        coverUrl: null,
        authorName: null,
        authorId: null,
      );
      expect(v.coverUrl, isNull);
      expect(v.author.name, isNull);
      expect(v.author.platformAuthorId, isNull);
      expect(v.author.hasAny, isFalse, reason: '作者信息全缺失时不得生成占位数据');
      // 缺失字段不得被凭空生成
      expect(v.durationSeconds, isNull);
      expect(v.publishedAt, isNull);
      expect(v.durationLabel, isNull);
    });

    test('宽高比缺失时布局回退到 16:9，但不伪造数据', () {
      final v = _video(platformId: 'mock', platformVideoId: 'x2');
      expect(v.aspectRatio, isNull, reason: '数据本身必须保持 null');
      expect(v.layoutAspectRatio, closeTo(16 / 9, 0.001),
          reason: '布局回退值仅用于渲染');
    });

    test('竖屏视频识别正确', () {
      final v = _video(
        platformId: 'douyin',
        platformVideoId: '1',
        width: 1080,
        height: 1920,
      );
      expect(v.isPortrait, isTrue);
      expect(v.layoutAspectRatio, closeTo(0.5625, 0.001));
    });

    test('不同平台相同 ID 不冲突（身份由平台+ID 共同决定）', () {
      final a = _video(platformId: 'bilibili', platformVideoId: '12345');
      final b = _video(platformId: 'douyin', platformVideoId: '12345');
      expect(a.id, 'bilibili:12345');
      expect(b.id, 'douyin:12345');
      expect(a.id == b.id, isFalse, reason: '跨平台相同 ID 必须可区分');
    });

    test('原始 URL 与来源平台准确保留', () {
      const original = 'https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.999';
      final v = UnifiedVideo(
        id: 'bilibili:BV1GJ411x7h7',
        platformId: 'bilibili',
        platformVideoId: 'BV1GJ411x7h7',
        originalUrl: original,
        canonicalUrl: 'https://www.bilibili.com/video/BV1GJ411x7h7',
        title: 't',
        fetchedAt: DateTime.now().toUtc().toIso8601String(),
        diagnostics: const VideoDiagnostics(
          adapterId: 'bilibili',
          upstreamEndpoint: '/x/web-interface/view',
          fromCache: false,
          fetchDurationMs: 1,
        ),
      );
      expect(v.originalUrl, original, reason: '原始链接必须原样保留');
      expect(v.platformId, 'bilibili');
      expect(v.platformVideoId, 'BV1GJ411x7h7');
    });

    test('JSON 往返序列化保持字段完整', () {
      final v = _video(
        platformId: 'bilibili',
        platformVideoId: 'BV1',
        coverUrl: 'https://x/y.jpg',
        authorName: '作者',
        width: 1920,
        height: 1080,
        duration: 100,
      );
      final restored = UnifiedVideo.fromJson(v.toJson());
      expect(restored.id, v.id);
      expect(restored.title, v.title);
      expect(restored.coverUrl, v.coverUrl);
      expect(restored.author.name, v.author.name);
      expect(restored.width, v.width);
      expect(restored.durationSeconds, v.durationSeconds);
      expect(restored.originalUrl, v.originalUrl);
    });

    test('时长归一化：毫秒与秒', () {
      expect(normalizeDuration(213000, isMilliseconds: true), 213);
      expect(normalizeDuration(213, isMilliseconds: false), 213);
      expect(normalizeDuration(0, isMilliseconds: false), isNull);
      expect(normalizeDuration(-5, isMilliseconds: false), isNull);
      expect(normalizeDuration(null, isMilliseconds: false), isNull);
    });

    test('时长格式化边界', () {
      expect(formatDuration(null), isNull);
      expect(formatDuration(0), isNull);
      expect(formatDuration(59), '00:59');
      expect(formatDuration(60), '01:00');
      expect(formatDuration(3599), '59:59');
      expect(formatDuration(3600), '1:00:00');
      expect(formatDuration(3661), '1:01:01');
    });

    test('宽高比归一化拒绝非法值', () {
      expect(normalizeAspectRatio(null, 1080), isNull);
      expect(normalizeAspectRatio(1920, null), isNull);
      expect(normalizeAspectRatio(0, 1080), isNull);
      expect(normalizeAspectRatio(-1, 1080), isNull);
      expect(normalizeAspectRatio(1920, 1080), closeTo(1.777, 0.01));
    });
  });

  group('TTL 缓存', () {
    test('命中与未命中计数', () {
      final cache = TtlCache<String>(ttl: const Duration(minutes: 1));
      expect(cache.peek('k'), isNull);
      cache.put('k', 'v');
      expect(cache.peek('k')!.value, 'v');
      expect(cache.stats.hits, 1);
      expect(cache.stats.entries, 1);
    });

    test('过期后不再命中，但允许读取陈旧值', () async {
      final cache = TtlCache<String>(ttl: const Duration(milliseconds: 30));
      cache.put('k', 'v');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(cache.peek('k'), isNull, reason: '过期后默认不返回');
      final stale = cache.peek('k', allowStale: true);
      expect(stale, isNotNull);
      expect(stale!.stale, isTrue);
      expect(stale.value, 'v');
    });

    test('并发相同 key 的请求合并为一次上游调用', () async {
      final cache = TtlCache<int>(ttl: const Duration(minutes: 1));
      var calls = 0;
      Future<int> loader() async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 42;
      }

      final results = await Future.wait([
        cache.getOrLoad('k', loader),
        cache.getOrLoad('k', loader),
        cache.getOrLoad('k', loader),
      ]);
      expect(results, [42, 42, 42]);
      expect(calls, 1, reason: '并发请求必须合并，避免重复调用上游');
    });

    test('容量上限触发淘汰', () {
      final cache = TtlCache<int>(ttl: const Duration(minutes: 5), maxEntries: 3);
      for (var i = 0; i < 5; i++) {
        cache.put('k$i', i);
      }
      expect(cache.stats.entries, lessThanOrEqualTo(3));
      expect(cache.stats.evictions, greaterThan(0));
    });

    test('invalidate 与 clear', () {
      final cache = TtlCache<String>(ttl: const Duration(minutes: 1));
      cache.put('a', '1');
      cache.put('b', '2');
      cache.invalidate('a');
      expect(cache.peek('a'), isNull);
      expect(cache.peek('b'), isNotNull);
      cache.clear();
      expect(cache.stats.entries, 0);
    });

    test('pruneExpired 清理过期条目', () async {
      final cache = TtlCache<String>(ttl: const Duration(milliseconds: 20));
      cache.put('a', '1');
      cache.put('b', '2');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final removed = cache.pruneExpired();
      expect(removed, 2);
      expect(cache.stats.entries, 0);
    });

    test('缓存失效后能够重新获取（需求：元数据缓存失效后重新获取）', () async {
      final cache = TtlCache<String>(ttl: const Duration(milliseconds: 30));
      var calls = 0;
      Future<String> loader() async {
        calls++;
        return 'v$calls';
      }

      expect(await cache.getOrLoad('k', loader), 'v1');
      expect(await cache.getOrLoad('k', loader), 'v1', reason: '未过期应命中缓存');
      expect(calls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(await cache.getOrLoad('k', loader), 'v2', reason: '过期后应重新获取');
      expect(calls, 2);
    });
  });

  group('视频库存储（重复导入）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('同一视频重复导入时更新而非重复添加', () async {
      final store = VideoStore(storage: InMemoryStore(), logger: FusionLogger(enabled: false));
      final v1 = _video(
        platformId: 'bilibili',
        platformVideoId: 'BV1',
        title: '原标题',
      );
      await store.upsert(v1);
      expect(await store.count(), 1);

      final v2 = v1.copyWith(title: '更新后的标题');
      await store.upsert(v2);
      expect(await store.count(), 1, reason: '重复导入不得产生重复条目');

      final stored = await store.get('bilibili:BV1');
      expect(stored!.title, '更新后的标题');
    });

    test('不同平台的相同 ID 作为独立条目共存', () async {
      final store = VideoStore(storage: InMemoryStore(), logger: FusionLogger(enabled: false));
      await store.upsert(_video(platformId: 'bilibili', platformVideoId: '999'));
      await store.upsert(_video(platformId: 'douyin', platformVideoId: '999'));
      expect(await store.count(), 2);
      final byPlatform = await store.countByPlatform();
      expect(byPlatform['bilibili'], 1);
      expect(byPlatform['douyin'], 1);
    });

    test('移除条目', () async {
      final store = VideoStore(storage: InMemoryStore(), logger: FusionLogger(enabled: false));
      await store.upsert(_video(platformId: 'bilibili', platformVideoId: 'A'));
      await store.remove('bilibili:A');
      expect(await store.count(), 0);
      expect(await store.get('bilibili:A'), isNull);
    });

    test('导出与导入往返', () async {
      final store = VideoStore(storage: InMemoryStore(), logger: FusionLogger(enabled: false));
      await store.upsert(_video(platformId: 'bilibili', platformVideoId: 'A'));
      await store.upsert(_video(platformId: 'mock', platformVideoId: 'B'));
      final json = await store.exportJson();

      final store2 = VideoStore(storage: InMemoryStore(), logger: FusionLogger(enabled: false));
      await store2.importJson(json);
      expect(await store2.count(), 2);
    });

    test('导入非法数据抛出明确错误', () async {
      final store = VideoStore(storage: InMemoryStore(), logger: FusionLogger(enabled: false));
      expect(
        () => store.importJson('{"not":"an array"}'),
        throwsA(isA<FusionException>()),
      );
    });
  });

  group('播放模型', () {
    test('NATIVE 播放源只携带真实存在的字段', () {
      const src = NativePlaybackSource(
        videoId: 'bilibili:BV1',
        videoStreamUrl: 'https://cdn/x.m4s',
        audioStreamUrl: 'https://cdn/a.m4s',
        requiredHeaders: {},
        isDash: true,
      );
      expect(src.mode, PlaybackMode.native);
      expect(src.videoStreamUrl, isNotEmpty);
      expect(src.audioStreamUrl, isNotNull);
      expect(src.isDash, isTrue);
    });

    test('官方嵌入播放器能力默认保守（不虚构能力）', () {
      const caps = EmbedCapabilities();
      expect(caps.hasBuiltInControls, isTrue);
      expect(caps.supportsQualitySwitch, isFalse,
          reason: '未验证前不得声称支持清晰度切换');
      expect(caps.supportsPlaybackRate, isFalse,
          reason: '未验证前不得声称支持倍速');
    });

    test('播放模式 wireName 稳定且可往返', () {
      for (final m in PlaybackMode.values) {
        expect(PlaybackMode.fromWire(m.wireName), m);
      }
      expect(PlaybackMode.native.wireName, 'NATIVE');
      expect(PlaybackMode.officialEmbed.wireName, 'OFFICIAL_EMBED');
      expect(PlaybackMode.external.wireName, 'EXTERNAL');
    });

    test('播放源 JSON 序列化不泄漏请求头取值', () {
      const src = NativePlaybackSource(
        videoId: 'bilibili:BV1',
        videoStreamUrl: 'https://cdn/x.mp4',
        requiredHeaders: {'Referer': 'https://www.bilibili.com/'},
      );
      final json = src.toJson();
      // 只记录头名，不记录取值
      expect(json['requiredHeaders'], ['Referer']);
      expect(json.toString().contains('bilibili.com/'), isFalse);
    });
  });

  group('统一错误模型', () {
    test('错误码到展示信息的映射完整', () {
      for (final code in FusionErrorCode.values) {
        final e = FusionException(code: code, userMessage: '测试');
        expect(e.presentation.title, isNotEmpty,
            reason: '每个错误码都必须有面向用户的标题：$code');
        expect(e.presentation.detail, isNotEmpty);
      }
    });

    test('重试性推断合理', () {
      expect(
        FusionException(
          code: FusionErrorCode.timeout,
          userMessage: 'x',
        ).retryable,
        isTrue,
      );
      expect(
        FusionException(
          code: FusionErrorCode.videoNotFound,
          userMessage: 'x',
        ).retryable,
        isFalse,
        reason: '视频不存在不应建议重试',
      );
      expect(
        FusionException(
          code: FusionErrorCode.permissionDenied,
          userMessage: 'x',
        ).presentation.authRelated,
        isTrue,
      );
    });

    test('可显式覆盖 retryable', () {
      final e = FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: 'x',
        retryable: false,
      );
      expect(e.retryable, isFalse);
    });

    test('normalizeError 归一化未知异常', () {
      final e = normalizeError(StateError('boom'));
      expect(e.code, FusionErrorCode.internalError);
      expect(e.userMessage, isNotEmpty);
    });

    test('toJson 不包含 cause 对象（避免泄漏内部结构）', () {
      final e = FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: 'x',
        technicalMessage: 'y',
        cause: StateError('secret internal'),
      );
      expect(e.toJson().containsKey('cause'), isFalse);
    });
  });
}
