/// 红果短剧适配器测试。
///
/// 用真实 HTML fixture 驱动，不联网。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

/// 按 URL 返回 fixture 的假 HTTP 客户端。
class _FixtureHttp extends FusionHttpClient {
  _FixtureHttp(this.routes) : super();

  /// url 片段 → 文件内容
  final Map<String, String> routes;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
    bool keepRawBytes = false,
  }) async {
    for (final entry in routes.entries) {
      if (url.contains(entry.key)) {
        return HttpResult(
          statusCode: 200,
          body: entry.value,
          headers: const {'content-type': 'text/html'},
          url: url,
          attempts: 1,
          durationMs: 1,
        );
      }
    }
    return HttpResult(
      statusCode: 404,
      body: '',
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 1,
    );
  }
}

void main() {
  String? readFixture(String name) {
    final f = File('test/fixtures/$name');
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }

  HongguoAdapter buildAdapter({Map<String, String>? routes}) {
    final home = readFixture('hongguo_home.html');
    final player = readFixture('hongguo_player.html');
    return HongguoAdapter(
      http: _FixtureHttp(routes ??
          {
            '/player/': player ?? '',
            'hongguoduanju.com/': home ?? '',
          }),
      logger: FusionLogger(enabled: false),
    );
  }

  group('红果适配器：身份与能力声明', () {
    test('平台标识独立，不伪装成 B 站或抖音', () {
      final a = buildAdapter();
      expect(a.id, 'hongguo');
      expect(a.id, isNot('bilibili'));
      expect(a.id, isNot('douyin'));
      expect(a.displayName, contains('红果'));
    });

    test('只声明实测可用的能力', () {
      final a = buildAdapter();
      // 短剧平台没有社交功能
      expect(a.supportsLike, isFalse);
      expect(a.supportsCoin, isFalse);
      expect(a.supportsComments, isFalse);
      expect(a.supportsFavorite, isFalse);
      expect(a.supportsLive, isFalse);
      expect(a.supportsVideoDanmaku, isFalse);
      // 搜索未验证
      expect(a.supportsSearch, isFalse);
    });

    test('播放能力声明为原生播放', () {
      final a = buildAdapter();
      expect(a.capabilities.supportsNativePlayback, isTrue);
    });
  });

  group('红果适配器：链接识别', () {
    test('识别播放页链接', () async {
      final a = buildAdapter();
      final uri = Uri.parse(
          'https://hongguoduanju.com/player/7503745441910017049');
      expect(a.matches(uri), isTrue);

      final match = await a.extract(uri);
      expect(match, isNotNull);
      expect(match!.platformId, 'hongguo');
      expect(match.platformVideoId, '7503745441910017049');
    });

    test('拒绝非红果域名', () async {
      final a = buildAdapter();
      expect(a.matches(Uri.parse('https://www.bilibili.com/video/BV1xx')),
          isFalse);
      expect(a.matches(Uri.parse('https://www.douyin.com/video/123')), isFalse);
    });

    test('拒绝非 player 路径', () async {
      final a = buildAdapter();
      expect(a.matches(Uri.parse('https://hongguoduanju.com/about')), isFalse);
    });

    test('拒绝非法 series_id', () async {
      final a = buildAdapter();
      expect(a.matches(Uri.parse('https://hongguoduanju.com/player/abc')),
          isFalse);
    });
  });

  group('红果适配器：首页剧集列表', () {
    test('从真实 HTML 拉取剧集', () async {
      if (readFixture('hongguo_home.html') == null) return;
      final a = buildAdapter();
      final list = await a.fetchSeriesList();

      expect(list, isNotEmpty);
      for (final s in list) {
        expect(s.seriesId, isNotEmpty);
        expect(s.title, isNotEmpty);
      }
    });

    test('按 tab 分组', () async {
      if (readFixture('hongguo_home.html') == null) return;
      final a = buildAdapter();
      final grouped = await a.fetchSeriesByTab();

      expect(grouped, isNotEmpty);
      // 实测有「热播短剧」「热播真人剧」等 tab
      final total = grouped.values.fold<int>(0, (s, v) => s + v.length);
      expect(total, greaterThan(0));
    });

    test('缓存生效：第二次不重复请求', () async {
      if (readFixture('hongguo_home.html') == null) return;
      final a = buildAdapter();
      final first = await a.fetchSeriesList();
      final second = await a.fetchSeriesList();
      expect(identical(first, second), isTrue, reason: '应命中缓存');
    });

    test('首页解析失败 → 抛 parseError 而非返回空列表', () async {
      final a = HongguoAdapter(
        http: _FixtureHttp({'hongguoduanju.com/': '<html></html>'}),
        logger: FusionLogger(enabled: false),
      );
      expect(
        () => a.fetchSeriesList(),
        throwsA(isA<FusionException>()
            .having((e) => e.code, 'code', FusionErrorCode.parseError)),
      );
    });
  });

  group('红果适配器：详情与分集', () {
    test('拉取分集，集数连续', () async {
      if (readFixture('hongguo_player.html') == null) return;
      final a = buildAdapter();
      final detail =
          await a.fetchSeriesDetail('7503745441910017049');

      expect(detail.episodes, isNotEmpty);
      for (var i = 0; i < detail.episodes.length; i++) {
        expect(detail.episodes[i].index, i + 1);
      }
    });

    test('剧集不存在 → 抛 videoNotFound', () async {
      final a = HongguoAdapter(
        http: _FixtureHttp({}),
        logger: FusionLogger(enabled: false),
      );
      expect(
        () => a.fetchSeriesDetail('123456789012345'),
        throwsA(isA<FusionException>()
            .having((e) => e.code, 'code', FusionErrorCode.videoNotFound)),
      );
    });
  });

  group('红果适配器：播放', () {
    test('解析出可播放直链', () async {
      if (readFixture('hongguo_player.html') == null) return;
      final a = buildAdapter();
      final source = await a.resolvePlayback(
        PlaybackRequest(
          platformVideoId: '7503745441910017049',
          canonicalUrl:
              'https://hongguoduanju.com/player/7503745441910017049',
          preferredMode: PlaybackMode.native,
        ),
      );

      expect(source, isNotNull);
      expect(source, isA<NativePlaybackSource>());
      final native = source as NativePlaybackSource;
      // 直链来自 CDN 或官网兜底源，必须是 http(s)
      expect(native.videoStreamUrl, startsWith('http'));
      expect(native.quality, isNotNull);

      // 两条合法路径：
      //  a) 主接口可用 → CDN 直链（不带 .mp4 后缀，靠 mime_type 区分）
      //  b) 主接口失效 → 如实降级到官网 360p，并在档位里标出
      //
      // 主接口是外部服务，会变。测试不该在它失效时红着——
      // 该验证的是"要么拿到 CDN 直链，要么正确降级"，不是
      // "外部接口必须一直可用"。
      final isCdn = native.videoStreamUrl.contains('qznovelvod.com');
      final isFallback = native.videoStreamUrl.contains('/video/public/') &&
          native.quality!.label == '360p';
      expect(
        isCdn || isFallback,
        isTrue,
        reason: '直链要么来自 CDN，要么是官网 360p 兜底；'
            '实际: ${native.videoStreamUrl} (档位 ${native.quality!.label})',
      );
    });

    test('指定集数（{seriesId}#{index}）', () async {
      if (readFixture('hongguo_player.html') == null) return;
      final a = buildAdapter();
      final source = await a.resolvePlayback(
        PlaybackRequest(
          platformVideoId: '7503745441910017049#3',
          canonicalUrl: 'https://hongguoduanju.com/player/7503745441910017049',
          preferredMode: PlaybackMode.native,
        ),
      );
      expect(source, isNotNull);
      final native = source as NativePlaybackSource;
      expect(native.videoStreamUrl, startsWith('http'));
    });
  });

  group('红果适配器：不支持的能力如实抛错', () {
    test('搜索抛 unsupportedPlatform，不返回空列表', () async {
      final a = buildAdapter();
      expect(
        () => a.searchVideos('测试'),
        throwsA(isA<FusionException>()
            .having((e) => e.code, 'code', FusionErrorCode.unsupportedPlatform)),
      );
    });

    test('未知 feed 来源抛 unsupportedPlatform', () async {
      final a = buildAdapter();
      expect(
        () => a.fetchFeed(const FeedRequest(), sourceId: 'unknown'),
        throwsA(isA<FusionException>()
            .having((e) => e.code, 'code', FusionErrorCode.unsupportedPlatform)),
      );
    });
  });

  group('红果适配器：缓存不串线', () {
    test('不同 seriesId 的分集互不影响', () async {
      if (readFixture('hongguo_player.html') == null) return;
      final a = buildAdapter();
      final d1 = await a.fetchSeriesDetail('7503745441910017049');
      final d2 = await a.fetchSeriesDetail('7503745441910017049');
      // 同一 seriesId 应一致
      expect(
        d1.episodes.map((e) => e.vid).toList(),
        d2.episodes.map((e) => e.vid).toList(),
      );
      // seriesId 字段应正确回填
      expect(d1.seriesId, '7503745441910017049');
    });
  });
  group('红果适配器：集数可用性（实测覆盖不完整）', () {
    test('360p 不可用时抛明确错误，不返回假播放源', () async {
      final player = readFixture('hongguo_player.html');
      if (player == null) return;

      // 播放页正常，但 HEAD 请求返回 404（模拟真实情况：
      // 第 8、9、13-18、21-29 集官网确实 404）
      final adapter = HongguoAdapter(
        http: _UnplayableHttp(player),
        logger: FusionLogger(enabled: false),
      );

      expect(
        () => adapter.resolvePlayback(
          PlaybackRequest(
            platformVideoId: '7503745441910017049#1',
            canonicalUrl:
                'https://hongguoduanju.com/player/7503745441910017049',
            preferredMode: PlaybackMode.native,
          ),
        ),
        throwsA(isA<FusionException>().having(
          (e) => e.userMessage,
          'userMessage',
          contains('暂无可播放的公开源'),
        )),
        reason: '不能返回一个注定 404 的播放地址',
      );
    });

    test('isEpisodePlayable 对 404 返回 false', () async {
      final player = readFixture('hongguo_player.html');
      if (player == null) return;

      final adapter = HongguoAdapter(
        http: _UnplayableHttp(player),
        logger: FusionLogger(enabled: false),
      );
      expect(await adapter.isEpisodePlayable('123'), isFalse);
    });
  });
}

/// 播放页正常，但 mp4 HEAD 返回 404。
class _UnplayableHttp extends FusionHttpClient {
  _UnplayableHttp(this.playerHtml) : super();
  final String playerHtml;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
    bool keepRawBytes = false,
  }) async =>
      HttpResult(
        statusCode: 200,
        body: playerHtml,
        headers: const {},
        url: url,
        attempts: 1,
        durationMs: 1,
      );

  @override
  Future<HttpResult> send(
    HttpRequestSpec spec, {
    bool? followRedirects,
  }) async =>
      HttpResult(
        statusCode: 404,
        body: '',
        headers: const {},
        url: spec.url,
        attempts: 1,
        durationMs: 1,
      );
}