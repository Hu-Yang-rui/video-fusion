/// 平台识别测试。
///
/// 覆盖需求八「平台识别测试」全部用例：
///  - 正常的抖音视频链接
///  - 正常的 B站视频链接
///  - 不同形式的合法分享链接
///  - 无效链接
///  - 不支持的平台链接
///  - 无法提取视频 ID 的异常链接
///
/// 本文件为**纯离线测试**：使用注入的假 HTTP 客户端，不产生真实网络请求。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/adapters/mock_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

/// 测试用 HTTP 客户端：记录调用并返回预设响应，不触网。
class FakeHttpClient extends FusionHttpClient {
  FakeHttpClient({this.redirectTarget, this.jsonResponse})
      : super(logger: FusionLogger(enabled: false));

  final String? redirectTarget;
  final Map<String, Object?>? jsonResponse;

  final List<String> requestedUrls = [];

  @override
  Future<String?> resolveRedirect(String url, {String? platformId}) async {
    requestedUrls.add('REDIRECT $url');
    return redirectTarget;
  }

  @override
  Future<Map<String, Object?>> getJson(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    Set<int>? acceptStatuses,
  }) async {
    requestedUrls.add(url);
    if (jsonResponse == null) {
      throw FusionException(
        code: FusionErrorCode.internalError,
        userMessage: 'test: no response configured',
        technicalMessage: 'FakeHttpClient.getJson called with no jsonResponse',
      );
    }
    return jsonResponse!;
  }

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
  }) async {
    requestedUrls.add(url);
    throw FusionException(
      code: FusionErrorCode.internalError,
      userMessage: 'test: get() not configured',
      technicalMessage: 'FakeHttpClient.get called: $url',
    );
  }
}

void main() {
  final logger = FusionLogger(enabled: false);
  late BilibiliAdapter bilibili;
  late DouyinAdapter douyin;
  late MockAdapter mock;

  setUp(() {
    final http = FakeHttpClient();
    bilibili = BilibiliAdapter(http: http, logger: logger);
    douyin = DouyinAdapter(http: http, logger: logger);
    mock = MockAdapter(http: http, logger: logger);
  });

  group('B站链接识别', () {
    test('标准视频链接', () async {
      final m = await bilibili.extract(
        Uri.parse('https://www.bilibili.com/video/BV1GJ411x7h7'),
      );
      expect(m, isNotNull);
      expect(m!.platformId, 'bilibili');
      expect(m.platformVideoId, 'BV1GJ411x7h7');
      expect(m.canonicalUrl, 'https://www.bilibili.com/video/BV1GJ411x7h7');
    });

    test('带查询参数的链接', () async {
      final m = await bilibili.extract(Uri.parse(
        'https://www.bilibili.com/video/BV1GJ411x7h7?spm_id_from=333.999&vd_source=abc',
      ));
      expect(m?.platformVideoId, 'BV1GJ411x7h7');
    });

    test('无 www 前缀', () async {
      final m = await bilibili.extract(
        Uri.parse('https://bilibili.com/video/BV1GJ411x7h7/'),
      );
      expect(m?.platformVideoId, 'BV1GJ411x7h7');
    });

    test('移动端 m.bilibili.com', () async {
      final m = await bilibili.extract(
        Uri.parse('https://m.bilibili.com/video/BV1GJ411x7h7'),
      );
      expect(m?.platformVideoId, 'BV1GJ411x7h7');
    });

    test('av 号链接', () async {
      final m = await bilibili.extract(
        Uri.parse('https://www.bilibili.com/video/av80433022'),
      );
      expect(m?.platformVideoId, 'av80433022');
    });

    test('播放器嵌入链接（bvid 查询参数）', () async {
      final m = await bilibili.extract(Uri.parse(
        'https://player.bilibili.com/player.html?bvid=BV1GJ411x7h7&page=1',
      ));
      expect(m?.platformVideoId, 'BV1GJ411x7h7');
    });

    test('播放器嵌入链接（aid 查询参数）', () async {
      final m = await bilibili.extract(
        Uri.parse('https://player.bilibili.com/player.html?aid=80433022'),
      );
      expect(m?.platformVideoId, 'av80433022');
    });

    test('b23.tv 短链展开', () async {
      final http = FakeHttpClient(
        redirectTarget: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      );
      final adapter = BilibiliAdapter(http: http, logger: logger);
      final m = await adapter.extract(Uri.parse('https://b23.tv/abcdefg'));
      expect(m?.platformVideoId, 'BV1GJ411x7h7');
      expect(http.requestedUrls.any((u) => u.startsWith('REDIRECT')), isTrue);
    });

    test('b23.tv 短链无法展开时抛出明确错误', () async {
      final http = FakeHttpClient(redirectTarget: null);
      final adapter = BilibiliAdapter(http: http, logger: logger);
      expect(
        () => adapter.extract(Uri.parse('https://b23.tv/abcdefg')),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.videoIdNotFound,
        )),
      );
    });

    test('无法提取 ID 的异常链接返回 null（不猜测）', () async {
      expect(
        await bilibili.extract(Uri.parse('https://www.bilibili.com/')),
        isNull,
      );
      expect(
        await bilibili.extract(
          Uri.parse('https://www.bilibili.com/video/notavalidid'),
        ),
        isNull,
      );
      expect(
        await bilibili.extract(Uri.parse('https://space.bilibili.com/12345')),
        isNull,
      );
      // 番剧/动态路径本阶段不接入，必须明确返回 null
      expect(
        await bilibili.extract(
          Uri.parse('https://www.bilibili.com/bangumi/play/ep123456'),
        ),
        isNull,
      );
    });

    test('域名匹配边界：不接受伪造子域', () {
      expect(bilibili.matches(Uri.parse('https://www.bilibili.com/video/x')), isTrue);
      expect(bilibili.matches(Uri.parse('https://b23.tv/x')), isTrue);
      // 关键安全边界：evil-bilibili.com 不应匹配
      expect(bilibili.matches(Uri.parse('https://evil-bilibili.com/video/x')), isFalse);
      expect(bilibili.matches(Uri.parse('https://bilibili.com.evil.com/x')), isFalse);
      expect(bilibili.matches(Uri.parse('https://youtube.com/watch?v=x')), isFalse);
    });
  });

  group('抖音链接识别', () {
    test('标准视频链接', () async {
      final m = await douyin.extract(
        Uri.parse('https://www.douyin.com/video/7216290450186583355'),
      );
      expect(m, isNotNull);
      expect(m!.platformId, 'douyin');
      expect(m.platformVideoId, '7216290450186583355');
      expect(m.canonicalUrl, 'https://www.douyin.com/video/7216290450186583355');
    });

    test('分享页链接 /share/video/{id}', () async {
      final m = await douyin.extract(
        Uri.parse('https://www.iesdouyin.com/share/video/7216290450186583355/'),
      );
      expect(m?.platformVideoId, '7216290450186583355');
    });

    test('modal_id 查询参数形态', () async {
      final m = await douyin.extract(
        Uri.parse('https://www.douyin.com/?modal_id=7216290450186583355'),
      );
      expect(m?.platformVideoId, '7216290450186583355');
    });

    test('v.douyin.com 短链展开', () async {
      final http = FakeHttpClient(
        redirectTarget:
            'https://www.iesdouyin.com/share/video/7298145681699622182/?region=CN&mid=123',
      );
      final adapter = DouyinAdapter(http: http, logger: logger);
      final m = await adapter.extract(Uri.parse('https://v.douyin.com/iRNBho6u/'));
      expect(m?.platformVideoId, '7298145681699622182');
    });

    test('短链无法展开时抛出明确错误', () async {
      final http = FakeHttpClient(redirectTarget: null);
      final adapter = DouyinAdapter(http: http, logger: logger);
      expect(
        () => adapter.extract(Uri.parse('https://v.douyin.com/xxxx/')),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.videoIdNotFound,
        )),
      );
    });

    test('非数字 ID 返回 null', () async {
      expect(
        await douyin.extract(Uri.parse('https://www.douyin.com/video/abc')),
        isNull,
      );
      expect(
        await douyin.extract(Uri.parse('https://www.douyin.com/video/123')),
        isNull, // 长度不足，不是合法 aweme_id
      );
    });

    test('域名匹配边界', () {
      expect(douyin.matches(Uri.parse('https://www.douyin.com/video/1')), isTrue);
      expect(douyin.matches(Uri.parse('https://v.douyin.com/x')), isTrue);
      expect(douyin.matches(Uri.parse('https://evil-douyin.com/video/1')), isFalse);
      expect(douyin.matches(Uri.parse('https://douyin.com.evil.com/x')), isFalse);
    });
  });

  group('平台注册表', () {
    test('注册与按 id 查找', () {
      final registry = PlatformRegistry(adapters: [bilibili, douyin, mock]);
      expect(registry.length, 3);
      expect(registry.byId('bilibili')!.displayName, '哔哩哔哩');
      expect(registry.byId('douyin')!.displayName, '抖音');
      expect(registry.byId('nonexistent'), isNull);
    });

    test('重复注册同一 id 必须抛错（不静默覆盖）', () {
      final registry = PlatformRegistry(adapters: [bilibili]);
      expect(
        () => registry.register(bilibili),
        throwsA(isA<FusionException>()),
      );
    });

    test('require 未注册平台抛出 unsupportedPlatform', () {
      final registry = PlatformRegistry(adapters: [bilibili]);
      expect(
        () => registry.require('douyin'),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.unsupportedPlatform,
        )),
      );
    });

    test('链接路由到正确的适配器', () {
      final registry = PlatformRegistry(adapters: [bilibili, douyin, mock]);
      expect(
        registry.match(Uri.parse('https://www.bilibili.com/video/BV1GJ411x7h7'))!.id,
        'bilibili',
      );
      expect(
        registry.match(Uri.parse('https://www.douyin.com/video/7216290450186583355'))!.id,
        'douyin',
      );
      expect(
        registry.match(Uri.parse('https://mock.video-fusion.test/video/m1'))!.id,
        'mock',
      );
      // 不支持的平台必须返回 null，不得猜测
      expect(registry.match(Uri.parse('https://www.youtube.com/watch?v=x')), isNull);
      expect(registry.match(Uri.parse('https://example.com/video/1')), isNull);
    });

    test('describeAll 返回全部平台描述', () {
      final registry = PlatformRegistry(adapters: [bilibili, douyin, mock]);
      final all = registry.describeAll();
      expect(all.length, 3);
      expect(all.map((d) => d.id), containsAll(['bilibili', 'douyin', 'mock']));
      // 能力声明必须如实
      final bili = all.firstWhere((d) => d.id == 'bilibili');
      expect(bili.capabilities.supportsNativePlayback, isTrue);
      final dy = all.firstWhere((d) => d.id == 'douyin');
      expect(dy.capabilities.supportsNativePlayback, isFalse);
      expect(dy.capabilities.requiresSignature, isTrue);
    });
  });

  group('模拟平台适配器（扩展性验证）', () {
    test('识别模拟平台链接', () async {
      final m = await mock.extract(
        Uri.parse('https://mock.video-fusion.test/video/test-1'),
      );
      expect(m?.platformId, 'mock');
      expect(m?.platformVideoId, 'test-1');
    });

    test('模拟数据必须明确标注为测试数据', () async {
      final m = await mock.extract(
        Uri.parse('https://mock.video-fusion.test/video/test-1'),
      );
      final meta = await mock.fetchMetadata(m!);
      // 标题必须带【测试】前缀，不得伪装成真实平台数据
      expect(meta.title, startsWith('【测试】'));
      expect(meta.upstreamEndpoint, '(local-test-data)');
    });

    test('模拟平台不声明应用内播放能力', () {
      expect(mock.capabilities.supportsNativePlayback, isFalse);
      expect(mock.capabilities.supportsOfficialEmbed, isFalse);
      expect(mock.capabilities.supportsExternalFallback, isTrue);
    });

    test('模拟平台 resolvePlayback 明确抛错而非伪造成功', () {
      expect(
        () => mock.resolvePlayback(
          const PlaybackRequest(
            platformVideoId: 'test-1',
            canonicalUrl: 'https://mock.video-fusion.test/video/test-1',
          ),
        ),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.capabilityUnavailable,
        )),
      );
    });

    test('模拟平台生成不同宽高比以覆盖布局用例', () async {
      final ratios = <double?>{};
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
        final m = await mock.extract(
          Uri.parse('https://mock.video-fusion.test/video/$id'),
        );
        final meta = await mock.fetchMetadata(m!);
        if (meta.width != null && meta.height != null) {
          ratios.add(meta.width! / meta.height!);
        }
      }
      // 应当产生横屏与竖屏两种比例，用于验证封面布局
      expect(ratios.any((r) => r! > 1.0), isTrue, reason: '应有横屏视频');
      expect(ratios.any((r) => r! < 1.0), isTrue, reason: '应有竖屏视频');
    });

    test('模拟平台部分条目缺少作者信息（覆盖缺失字段用例）', () async {
      var foundMissingAuthor = false;
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
        final m = await mock.extract(
          Uri.parse('https://mock.video-fusion.test/video/$id'),
        );
        final meta = await mock.fetchMetadata(m!);
        if (meta.author.name == null) foundMissingAuthor = true;
      }
      expect(foundMissingAuthor, isTrue, reason: '应有缺少作者的条目');
    });
  });
}
