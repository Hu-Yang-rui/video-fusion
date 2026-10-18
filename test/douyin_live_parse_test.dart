/// 抖音直播的解析与错误处理测试。
///
/// 覆盖四类真实风险：
///  1. **`status_code: 0` + `status_msg: "url doesn't match"`** ——
///     HTTP 200 且业务码为 0，但没有任何数据。只看状态码会把失败当成功。
///  2. 房间号是 19 位字符串，超出安全整数范围，不能当 int 用。
///  3. 播放地址是 `http://`，而应用禁用了明文流量，必须升级到 https。
///  4. `stream_url` 有多种形态（hls_pull_url / hls_pull_url_map /
///     flv_pull_url），解析必须都能覆盖。
///
/// 这些 fixture 的字段结构来自 2026-10-18 对
/// `webcast.amemv.com/webcast/feed/` 的真实响应。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/live_client.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

/// 可控的假 HTTP 层。
class FakeLiveHttp extends FusionHttpClient {
  FakeLiveHttp({required this.body, this.status = 200})
      : super(logger: FusionLogger(enabled: false));

  String body;
  int status;

  /// 记录最后一次请求的 UA 与 URL。
  String? lastUserAgent;
  String? lastUrl;
  int calls = 0;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
  }) async {
    calls++;
    lastUrl = url;
    lastUserAgent = headers['User-Agent'];
    return HttpResult(
      statusCode: status,
      body: body,
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 1,
    );
  }
}

DouyinLiveClient clientWith(FakeLiveHttp http) =>
    DouyinLiveClient(http: http, logger: FusionLogger(enabled: false));

/// 构造一条 feed 条目。
String feedEntry({
  required String roomId,
  String title = '测试直播',
  String nickname = '测试主播',
  int userCount = 1234,
  int status = 2,
  bool withStream = true,
}) {
  // 注意：默认带 stream_url，因为实测推荐流里 6/6 都带。
  // 不带时必须整个字段省略，不能写成 `"stream_url": null,` 后面又跟逗号
  // （会产出非法 JSON）。
  final stream = withStream
      ? '''
    "stream_url": {
      "default_resolution": "FULL_HD1",
      "hls_pull_url": "http://pull-hls-t11.douyincdn.com/x/stream-1.m3u8?expire=1&sign=abc",
      "hls_pull_url_map": {
        "FULL_HD1": "http://pull-hls-t11.douyincdn.com/x/stream-1.m3u8?expire=1&sign=abc",
        "HD1": "http://pull-hls-t11.douyincdn.com/x/stream-1_hd.m3u8?expire=1&sign=def"
      },
      "flv_pull_url": {
        "FULL_HD1": "http://pull-flv-t11.douyincdn.com/x/stream-1.flv?expire=1&sign=ghi"
      }
    },'''
      : '';

  return '''
{
  "type": 1,
  "rid": "$roomId",
  "data": {
    "id_str": "$roomId",
    "status": $status,
    "title": "$title",
    "user_count": $userCount,
    "category": 1,
    "create_time": 1792320207,
    "cover": {"url_list": ["https://p3-webcast-sign.douyinpic.com/cover.jpg"]},
    "owner": {
      "id_str": "123456",
      "nickname": "$nickname",
      "avatar_thumb": {"url_list": ["https://p3.douyinpic.com/avatar.jpg"]}
    },
    $stream
    "_end": true
  }
}''';
}

String feedResponse(List<String> entries) =>
    '{"data":[${entries.join(',')}],"extra":{"now":1792320207},"status_code":0}';

void main() {
  group('列表解析', () {
    test('解析出真实字段：房间号/标题/主播/封面/在线人数', () async {
      final http = FakeLiveHttp(
        body: feedResponse([
          feedEntry(
            roomId: '7697959724830018331',
            title: '国服心魔六耳手法拉满',
            nickname: '佳航-王者荣耀',
            userCount: 13179,
          ),
        ]),
      );

      final rooms = await clientWith(http).fetchFeed();

      expect(rooms, hasLength(1));
      final r = rooms.first;
      expect(r.roomKey, '7697959724830018331');
      expect(r.title, '国服心魔六耳手法拉满');
      expect(r.uname, '佳航-王者荣耀');
      expect(r.coverUrl, contains('cover.jpg'));
      expect(r.faceUrl, contains('avatar.jpg'));
      expect(r.online, 13179);
    });

    test('19 位房间号保持字符串精度（不能丢精度）', () async {
      // 7697959724830018331 超过 2^53，转 double 会丢精度。
      // roomKey 必须是原样字符串。
      final http = FakeLiveHttp(
        body: feedResponse([feedEntry(roomId: '7697959724830018331')]),
      );

      final rooms = await clientWith(http).fetchFeed();

      expect(rooms.first.roomKey, '7697959724830018331');
      expect(rooms.first.roomKey.length, 19);
    });

    test('多条房间全部解析', () async {
      final http = FakeLiveHttp(
        body: feedResponse([
          feedEntry(roomId: '1'),
          feedEntry(roomId: '2'),
          feedEntry(roomId: '3'),
        ]),
      );

      final rooms = await clientWith(http).fetchFeed();
      expect(rooms, hasLength(3));
    });

    test('缺少 id_str 的条目被跳过，不影响其它条目', () async {
      final http = FakeLiveHttp(
        body:
            '{"status_code":0,"data":[{"type":1,"data":{"title":"无id"}},${feedEntry(roomId: '42')}]}',
      );

      final rooms = await clientWith(http).fetchFeed();
      expect(rooms, hasLength(1));
      expect(rooms.first.roomKey, '42');
    });

    test('请求必须带 App 形态 UA（浏览器 UA 会被风控挡）', () async {
      final http = FakeLiveHttp(body: feedResponse([feedEntry(roomId: '1')]));

      await clientWith(http).fetchFeed();

      expect(http.lastUserAgent, isNotNull);
      expect(http.lastUserAgent, contains('com.ss.android.ugc.aweme'),
          reason: 'webcast.amemv.com 用浏览器 UA 会返回 HTTP 444');
    });
  });

  group('业务状态校验：不能只看 HTTP 200', () {
    test('status_msg="url doesn\'t match" 必须抛错，不能当成功', () async {
      // 这是实测到的真实响应：HTTP 200、status_code 0、但无数据。
      final http = FakeLiveHttp(
        body: '{"status_code":0,"status_msg":"url doesn\'t match"}',
      );

      await expectLater(
        clientWith(http).fetchFeed(),
        throwsA(isA<FusionException>()),
      );
    });

    test('status_code 非 0 抛 upstreamError', () async {
      final http = FakeLiveHttp(body: '{"status_code":10001,"data":[]}');

      await expectLater(
        clientWith(http).fetchFeed(),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.upstreamError,
        )),
      );
    });

    test('data 不是数组时抛 parseError', () async {
      final http = FakeLiveHttp(body: '{"status_code":0,"data":{}}');

      await expectLater(
        clientWith(http).fetchFeed(),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.parseError,
        )),
      );
    });

    test('有数据但一条都解析不出时抛 parseError（结构变了）', () async {
      final http = FakeLiveHttp(
        body: '{"status_code":0,"data":[{"type":1,"data":{}},{"type":1,"data":{}}]}',
      );

      await expectLater(
        clientWith(http).fetchFeed(),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.parseError,
        )),
      );
    });

    test('空列表是合法结果（确实没有直播），不抛错', () async {
      final http = FakeLiveHttp(body: '{"status_code":0,"data":[]}');

      final rooms = await clientWith(http).fetchFeed();
      expect(rooms, isEmpty);
    });
  });

  group('播放地址解析', () {
    Map<String, Object?> roomWithStream(Object? streamUrl) => {
          'id_str': '1',
          'status': 2,
          'stream_url': streamUrl,
        };

    test('优先 HLS（断线重连比 FLV 稳）', () {
      final http = FakeLiveHttp(body: '{}');
      final client = clientWith(http);

      final stream = client.parseStream(roomWithStream({
        'default_resolution': 'FULL_HD1',
        'hls_pull_url_map': {
          'FULL_HD1': 'http://hls.example/a.m3u8',
          'HD1': 'http://hls.example/b.m3u8',
        },
        'flv_pull_url': {'FULL_HD1': 'http://flv.example/a.flv'},
      }));

      expect(stream, isNotNull);
      expect(stream!.protocolName, 'http_hls');
      expect(stream.url, contains('.m3u8'));
      expect(stream.qualityLabel, '原画');
    });

    test('http:// 升级为 https://（应用禁用明文流量）', () {
      final http = FakeLiveHttp(body: '{}');
      final client = clientWith(http);

      final stream = client.parseStream(roomWithStream({
        'hls_pull_url': 'http://pull-hls-t11.douyincdn.com/x/stream.m3u8?sign=1',
      }));

      expect(stream, isNotNull);
      expect(stream!.url, startsWith('https://'),
          reason: 'usesCleartextTraffic=false，http 会直接失败');
      expect(stream.url, contains('douyincdn.com'));
    });

    test('已有 https 的不改动', () {
      final http = FakeLiveHttp(body: '{}');
      final stream = clientWith(http).parseStream(roomWithStream({
        'hls_pull_url': 'https://pull-hls.example/x.m3u8',
      }));

      expect(stream!.url, startsWith('https://'));
    });

    test('只有 flv 时回退 FLV', () {
      final http = FakeLiveHttp(body: '{}');
      final stream = clientWith(http).parseStream(roomWithStream({
        'flv_pull_url': {'FULL_HD1': 'http://flv.example/a.flv'},
      }));

      expect(stream, isNotNull);
      expect(stream!.protocolName, 'http_stream');
      expect(stream.isHls, isFalse);
      expect(stream.url, startsWith('https://'));
    });

    test('多清晰度被收集为 availableQualities', () {
      final http = FakeLiveHttp(body: '{}');
      final stream = clientWith(http).parseStream(roomWithStream({
        'hls_pull_url_map': {
          'FULL_HD1': 'http://a/x.m3u8',
          'HD1': 'http://b/y.m3u8',
          'SD1': 'http://c/z.m3u8',
        },
      }));

      expect(stream, isNotNull);
      expect(stream!.availableQualities, hasLength(2));
    });

    test('stream_url 缺失时返回 null（不是抛错）', () {
      final http = FakeLiveHttp(body: '{}');
      final stream = clientWith(http).parseStream({'id_str': '1'});
      expect(stream, isNull);
    });

    test('stream_url 是空对象时返回 null', () {
      final http = FakeLiveHttp(body: '{}');
      final stream = clientWith(http).parseStream(roomWithStream({}));
      expect(stream, isNull);
    });
  });

  group('房间查找', () {
    test('命中时返回该房间对象', () async {
      final http = FakeLiveHttp(
        body: feedResponse([
          feedEntry(roomId: '111'),
          feedEntry(roomId: '222', title: '目标房间'),
        ]),
      );

      final room = await clientWith(http).findRoomInFeed('222');

      expect(room, isNotNull);
      expect(room!['title'], '目标房间');
    });

    test('未命中时返回 null（调用方据此报 videoNotFound）', () async {
      final http = FakeLiveHttp(
        body: feedResponse([feedEntry(roomId: '111')]),
      );

      final room = await clientWith(http).findRoomInFeed('999');

      expect(room, isNull);
      expect(http.calls, 3, reason: '应重试 3 次提高命中率');
    });
  });
}
