/// B站适配器解析逻辑的回归测试。
///
/// 本文件固化几个**真实踩过的坑**，防止回归：
///
///  1. 分区排行（ranking/region）的 `create` 字段是**日期字符串**
///     `"2025-03-31 18:47"`，不是 epoch 秒。早期误用只接受 num 的
///     解析函数，导致该来源 `publishedAt` 恒为 null。
///  2. 分区排行的 `duration` 是 `"49:20"` 字符串，不是秒数。
///  3. 分区排行使用**扁平结构**（author/mid/play 为顶层字段），
///     没有 owner/stat 嵌套对象。
///  4. `popular` 来源的条目**没有 `goto` 字段**，早期按 `goto=='av'`
///     过滤会导致整个热门来源被清空。
///  5. B站每条 DASH 流附带 backupUrl，CDN 节点可能单独失效，
///     必须保留回退链。
///
/// 这些用例使用**构造的响应数据**（结构照抄实测响应），
/// 因此完全离线、可重复。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/playback.dart';

/// 假 HTTP 客户端：返回预设 JSON，不触网。
///
/// 支持按 URL 分派不同响应——`resolvePlayback` 会先后请求
/// `view`（取 cid）与 `playurl`（取流），两者结构不同。
class _StubHttp extends FusionHttpClient {
  _StubHttp(this._response, {this.viewResponse})
      : super(logger: FusionLogger(enabled: false));

  final Map<String, Object?> _response;

  /// 请求 `x/web-interface/view` 时返回此响应；为 null 时回退到 [_response]。
  final Map<String, Object?>? viewResponse;

  final List<String> requestedUrls = [];

  @override
  Future<Map<String, Object?>> getJson(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    Set<int>? acceptStatuses,
  }) async {
    requestedUrls.add(url);
    if (url.contains('web-interface/view') && viewResponse != null) {
      return viewResponse!;
    }
    return _response;
  }
}

/// 构造一个最小可用的 view 响应（仅含 cid）。
Map<String, Object?> _viewResponse({int cid = 123456}) => {
      'code': 0,
      'message': 'OK',
      'data': {'cid': cid, 'bvid': 'BV1GJ411x7h7'},
    };

/// 构造 DASH 播放响应，用于验证回退链。
Map<String, Object?> _dashResponse({
  required String base,
  List<String> backups = const [],
  String? audioBase,
  List<String> audioBackups = const [],
}) =>
    {
      'code': 0,
      'message': 'OK',
      'data': {
        'quality': 64,
        'dash': {
          'duration': 100,
          'video': [
            {
              'id': 32,
              'width': 852,
              'height': 480,
              'codecs': 'avc1.64001F',
              'bandwidth': 500000,
              'baseUrl': base,
              'backupUrl': backups,
            },
          ],
          'audio': audioBase == null
              ? []
              : [
                  {
                    'id': 30216,
                    'bandwidth': 40000,
                    'baseUrl': audioBase,
                    'backupUrl': audioBackups,
                  },
                ],
        },
      },
    };

/// 照抄实测的 `ranking/region` 响应结构（已裁剪，保留关键字段）。
Map<String, Object?> _rankingRegionResponse() => {
      'code': 0,
      'message': 'OK',
      'data': [
        {
          'aid': 114256632618805,
          'bvid': 'BV1B8ZJYTEPg',
          'typename': '动画',
          'title': '现代修仙，没钱纯靠自律',
          'play': 1234567,
          'video_review': 890,
          'favorites': 12345,
          'mid': 928123,
          'author': '圆桌动漫',
          'description': '简介文本',
          // 关键：日期字符串，不是 epoch
          'create': '2025-03-31 18:47',
          // 关键：时长是 "mm:ss" 字符串
          'duration': '49:20',
          'pic': 'http://i0.hdslb.com/bfs/archive/abc.jpg',
          // 注意：没有 owner / stat / pubdate / dimension
        },
        {
          'aid': 114256632618806,
          'bvid': 'BV1xx411c7mD',
          'title': '第二条',
          'play': 500,
          'video_review': 10,
          'mid': 111,
          'author': '作者二',
          'create': '2024-01-02 03:04',
          'duration': '1:02:03',
          'pic': 'http://i0.hdslb.com/x.jpg',
        },
      ],
    };

/// 照抄实测的 `popular` 响应结构：条目**没有 goto 字段**。
Map<String, Object?> _popularResponse() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'no_more': false,
        'list': [
          {
            'aid': 113000000000001,
            'bvid': 'BV1KoJX6CEGT',
            'title': '挑战全程扛共享单车登顶峨眉山金顶',
            'desc': '简介',
            'duration': 512,
            'pubdate': 1750000000,
            'pic': 'http://i0.hdslb.com/bfs/archive/pop.jpg',
            'owner': {'mid': 555, 'name': '户外老王', 'face': 'https://x/f.jpg'},
            'stat': {'view': 999999, 'like': 88888, 'danmaku': 777},
            'dimension': {'width': 1920, 'height': 1080},
            // 关键：没有 goto
          },
        ],
      },
    };

void main() {
  final logger = FusionLogger(enabled: false);

  group('分区排行解析（扁平结构）', () {
    test('publishedAt 从日期字符串正确解析（回归：曾恒为 null）', () async {
      final http = _StubHttp(_rankingRegionResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourceRanking,
      );

      expect(page.items, isNotEmpty);
      final first = page.items.first;

      // 这是本次修复的核心：早期实现此处为 null
      expect(first.publishedAt, isNotNull);

      final parsed = DateTime.parse(first.publishedAt!);
      // "2025-03-31 18:47" 北京时间 → UTC 应为 2025-03-31 10:47
      expect(parsed.toUtc().year, 2025);
      expect(parsed.toUtc().month, 3);
      expect(parsed.toUtc().day, 31);
      expect(parsed.toUtc().hour, 10);
      expect(parsed.toUtc().minute, 47);
    });

    test('duration 从 "49:20" 字符串解析为秒', () async {
      final http = _StubHttp(_rankingRegionResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourceRanking,
      );

      final first = page.items.first;
      // 49*60 + 20 = 2960
      expect(first.durationSeconds, 2960);
      expect(first.durationLabel, '49:20');

      // 超过一小时的时长
      final second = page.items[1];
      // 1*3600 + 2*60 + 3 = 3723
      expect(second.durationSeconds, 3723);
      expect(second.durationLabel, '1:02:03');
    });

    test('从扁平字段提取作者与统计', () async {
      final http = _StubHttp(_rankingRegionResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourceRanking,
      );

      final first = page.items.first;
      expect(first.author.name, '圆桌动漫');
      expect(first.author.platformAuthorId, '928123');
      expect(first.author.profileUrl, 'https://space.bilibili.com/928123');
      expect(first.stats.viewCount, 1234567);
      expect(first.stats.danmakuCount, 890);
      // 该接口不返回点赞数，必须如实为 null
      expect(first.stats.likeCount, isNull);
      // 该接口不返回宽高
      expect(first.width, isNull);
      expect(first.height, isNull);
    });

    test('条目级诊断标注真实来源接口（回归：曾硬编码为 rcmd）', () async {
      final http = _StubHttp(_rankingRegionResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourceRanking,
      );

      expect(page.items.first.diagnostics.upstreamEndpoint,
          contains('ranking/region'));
    });

    test('分页按 offset 切片，越界页返回空', () async {
      final http = _StubHttp(_rankingRegionResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      // safePageSize 会把页大小夹在 [4,30]，构造的响应只有 2 条，
      // 因此第 0 页应返回全部 2 条。
      final p0 = await adapter.fetchFeed(
        const FeedRequest(pageSize: 4),
        sourceId: BilibiliAdapter.feedSourceRanking,
      );
      expect(p0.items, hasLength(2));
      expect(p0.hasMore, isFalse);

      // offset 前进一页后应超出范围，返回空而不是重复上一页
      final p1 = await adapter.fetchFeed(
        const FeedRequest(pageSize: 4, offset: 1),
        sourceId: BilibiliAdapter.feedSourceRanking,
      );
      expect(p1.items, isEmpty);
      expect(p1.hasMore, isFalse);
    });

    test('页大小被夹在 [4,30]，避免过度请求', () {
      expect(const FeedRequest(pageSize: 1).safePageSize, 4);
      expect(const FeedRequest(pageSize: 1000).safePageSize, 30);
      expect(const FeedRequest(pageSize: 12).safePageSize, 12);
    });
  });

  group('热门来源解析（无 goto 字段）', () {
    test('没有 goto 字段的条目仍被正确接受（回归：曾被整体过滤掉）', () async {
      final http = _StubHttp(_popularResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourcePopular,
      );

      expect(page.items, hasLength(1));
      final v = page.items.first;
      expect(v.platformVideoId, 'BV1KoJX6CEGT');
      expect(v.title, contains('峨眉山'));
    });

    test('嵌套的 owner/stat/dimension 正确解析', () async {
      final http = _StubHttp(_popularResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourcePopular,
      );

      final v = page.items.first;
      expect(v.author.name, '户外老王');
      expect(v.author.platformAuthorId, '555');
      expect(v.stats.viewCount, 999999);
      expect(v.stats.likeCount, 88888);
      // popular 返回 dimension，应被采用
      expect(v.width, 1920);
      expect(v.height, 1080);
      expect(v.aspectRatio, closeTo(16 / 9, 0.01));
      expect(v.publishedAt, isNotNull);
    });

    test('条目级诊断标注 popular 接口', () async {
      final http = _StubHttp(_popularResponse());
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourcePopular,
      );

      expect(page.items.first.diagnostics.upstreamEndpoint,
          contains('popular'));
    });
  });

  group('推荐流边界', () {
    test('非视频卡片被跳过并计数，不用假数据填充', () async {
      final http = _StubHttp({
        'code': 0,
        'message': 'OK',
        'data': {
          'item': [
            {
              'goto': 'av',
              'bvid': 'BV1GJ411x7h7',
              'cid': 1,
              'title': '真视频',
              'duration': 100,
              'pubdate': 1750000000,
              'pic': 'https://x/c.jpg',
              'owner': {'mid': 1, 'name': 'A'},
              'stat': {'view': 1},
            },
            // 直播卡片：goto 不是 av
            {'goto': 'live', 'title': '某直播间', 'room_info': {}},
            // 番剧卡片
            {'goto': 'ogv', 'title': '某番剧'},
          ],
        },
      });
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourceRcmd,
      );

      expect(page.items, hasLength(1));
      expect(page.items.first.title, '真视频');
      // 跳过情况必须如实说明
      expect(page.notes.join(), contains('跳过'));
      expect(page.notes.join(), contains('2'));
    });

    test('无效 bvid 被拒绝', () async {
      final http = _StubHttp({
        'code': 0,
        'message': 'OK',
        'data': {
          'item': [
            {'goto': 'av', 'bvid': 'INVALID', 'title': 'x'},
            {'goto': 'av', 'title': '没有 bvid'},
          ],
        },
      });
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final page = await adapter.fetchFeed(
        const FeedRequest(pageSize: 10),
        sourceId: BilibiliAdapter.feedSourceRcmd,
      );

      expect(page.items, isEmpty);
    });

    test('未知来源抛出错误', () async {
      final http = _StubHttp({'code': 0, 'data': {}});
      final adapter = BilibiliAdapter(http: http, logger: logger);

      expect(
        () => adapter.fetchFeed(
          const FeedRequest(),
          sourceId: 'bilibili:nonexistent',
        ),
        throwsA(isA<Object>()),
      );
    });
  });

  group('推荐流参数正确性', () {
    test('rcmd 使用 fresh_idx 分页（回归：曾误用 offset）', () async {
      final http = _StubHttp({'code': 0, 'data': {'item': []}});
      final adapter = BilibiliAdapter(http: http, logger: logger);

      await adapter.fetchFeed(
        const FeedRequest(pageSize: 10, offset: 0),
        sourceId: BilibiliAdapter.feedSourceRcmd,
      );
      await adapter.fetchFeed(
        const FeedRequest(pageSize: 10, offset: 2),
        sourceId: BilibiliAdapter.feedSourceRcmd,
      );

      expect(http.requestedUrls, hasLength(2));
      // 第一次 fresh_idx=1，第二次 fresh_idx=3
      expect(http.requestedUrls[0], contains('fresh_idx=1'));
      expect(http.requestedUrls[1], contains('fresh_idx=3'));
    });
  });

  group('流地址回退链（回归：CDN 节点单独失效导致 404）', () {
    test('播放源携带 backupUrl 作为回退候选', () async {
      final http = _StubHttp(
        _dashResponse(
          base: 'https://cdn1.example/video.m4s',
          backups: [
            'https://cdn2.example/video.m4s',
            'https://cdn3.example/video.m4s',
          ],
          audioBase: 'https://cdn1.example/audio.m4s',
          audioBackups: ['https://cdn2.example/audio.m4s'],
        ),
        viewResponse: _viewResponse(),
      );
      final adapter = BilibiliAdapter(http: http, logger: logger);

      final src = await adapter.resolvePlayback(const PlaybackRequest(
        platformVideoId: 'BV1GJ411x7h7',
        canonicalUrl: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      ));

      expect(src, isA<NativePlaybackSource>());
      final native = src! as NativePlaybackSource;

      expect(native.videoStreamUrl, 'https://cdn1.example/video.m4s');
      expect(native.videoFallbackUrls, hasLength(2));
      expect(native.videoFallbackUrls,
          contains('https://cdn2.example/video.m4s'));
      expect(native.videoFallbackUrls,
          contains('https://cdn3.example/video.m4s'));

      expect(native.audioStreamUrl, 'https://cdn1.example/audio.m4s');
      expect(native.audioFallbackUrls, hasLength(1));
    });

    test('allVideoUrls 把主地址排在最前且去重', () async {
      final http = _StubHttp(
        _dashResponse(
          base: 'https://a/x.m4s',
          backups: ['https://a/x.m4s', 'https://b/x.m4s'],
        ),
        viewResponse: _viewResponse(),
      );
      final adapter = BilibiliAdapter(http: http, logger: logger);
      final src = (await adapter.resolvePlayback(const PlaybackRequest(
        platformVideoId: 'BV1GJ411x7h7',
        canonicalUrl: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      )))! as NativePlaybackSource;

      final all = src.allVideoUrls;
      expect(all.first, 'https://a/x.m4s');
      expect(all, hasLength(2));
      expect(all, contains('https://b/x.m4s'));
    });

    test('只有 baseUrl 时回退链为空（不编造地址）', () async {
      final http = _StubHttp(
        _dashResponse(base: 'https://only.example/x.m4s'),
        viewResponse: _viewResponse(),
      );
      final adapter = BilibiliAdapter(http: http, logger: logger);
      final src = (await adapter.resolvePlayback(const PlaybackRequest(
        platformVideoId: 'BV1GJ411x7h7',
        canonicalUrl: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      )))! as NativePlaybackSource;

      expect(src.videoFallbackUrls, isEmpty);
      expect(src.allVideoUrls, hasLength(1));
      expect(src.audioStreamUrl, isNull);
      expect(src.allAudioUrls, isEmpty);
    });

    test('播放源序列化只记备用地址数量，不泄漏完整 URL', () async {
      final http = _StubHttp(
        _dashResponse(
          base: 'https://a/x.m4s',
          backups: ['https://b/x.m4s'],
        ),
        viewResponse: _viewResponse(),
      );
      final adapter = BilibiliAdapter(http: http, logger: logger);
      final src = (await adapter.resolvePlayback(const PlaybackRequest(
        platformVideoId: 'BV1GJ411x7h7',
        canonicalUrl: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      )))! as NativePlaybackSource;

      final json = src.toJson();
      expect(json['videoFallbackCount'], 1);
      expect(json.toString().contains('https://b/x.m4s'), isFalse);
    });

    test('播放源携带 Referer 请求头（防盗链必需）', () async {
      final http = _StubHttp(
        _dashResponse(base: 'https://a/x.m4s'),
        viewResponse: _viewResponse(),
      );
      final adapter = BilibiliAdapter(http: http, logger: logger);
      final src = (await adapter.resolvePlayback(const PlaybackRequest(
        platformVideoId: 'BV1GJ411x7h7',
        canonicalUrl: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      )))! as NativePlaybackSource;

      expect(src.requiredHeaders.containsKey('Referer'), isTrue);
      expect(src.requiredHeaders['Referer'], 'https://www.bilibili.com/');
    });
  });

  group('适配器能力声明如实', () {
    test('B站声明支持元数据、应用内播放、官方嵌入、外部降级', () {
      final adapter = BilibiliAdapter(
        http: _StubHttp(const {}),
        logger: logger,
      );
      final caps = adapter.capabilities;
      expect(caps.supportsMetadata, isTrue);
      expect(caps.supportsNativePlayback, isTrue);
      expect(caps.supportsOfficialEmbed, isTrue);
      expect(caps.supportsExternalFallback, isTrue);
      expect(caps.requiresSignature, isFalse);
      expect(caps.requiresAuthForMetadata, isFalse);
    });

    test('能力说明不得声称"无需 Referer"（回归：与实测矛盾）', () {
      final adapter = BilibiliAdapter(
        http: _StubHttp(const {}),
        logger: logger,
      );
      final notes = adapter.capabilities.notes.join();
      expect(notes.contains('无需 Referer'), isFalse);
    });

    test('声明三个推荐流来源且均可用', () {
      final adapter = BilibiliAdapter(
        http: _StubHttp(const {}),
        logger: logger,
      );
      final ids = adapter.feedSources.map((s) => s.id).toList();
      expect(ids, containsAll([
        BilibiliAdapter.feedSourceRcmd,
        BilibiliAdapter.feedSourcePopular,
        BilibiliAdapter.feedSourceRanking,
      ]));
      expect(adapter.feedSources.every((s) => s.available), isTrue);
    });
  });
}
