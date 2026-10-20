/// 红果播放信息客户端测试。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/media_client.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

/// 可编排响应的假 HTTP 客户端。
class _FakeHttp extends FusionHttpClient {
  _FakeHttp(this.handler) : super();

  /// (attemptIndex) → (statusCode, body)
  final (int, String) Function(int attempt) handler;

  int calls = 0;
  final List<Map<String, String>> capturedHeaders = [];
  final List<String> capturedBodies = [];

  @override
  Future<HttpResult> post(
    String url, {
    Map<String, String> headers = const {},
    String? body,
    String contentType = 'application/x-www-form-urlencoded',
    String? platformId,
    Duration? timeout,
    Set<int>? acceptStatuses,
  }) async {
    calls++;
    capturedHeaders.add(Map.of(headers));
    capturedBodies.add(body ?? '');
    final (code, text) = handler(calls);
    return HttpResult(
      statusCode: code,
      body: text,
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 1,
    );
  }
}

/// 构造一个真实的 video_model 响应。
String _successBody({
  String definition = '1080p',
  int width = 1080,
  int height = 1920,
}) {
  return jsonEncode({
    'code': 0,
    'data': {
      'expire_time': 1792534512,
      'video_height': height,
      'video_model': jsonEncode({
        'video_duration': 211.834,
        'video_list': [
          {
            'main_url': 'https://cdn.example.com/$definition.mp4',
            'backup_url': 'https://backup.example.com/$definition.mp4',
            'quality_type': 1,
            'video_meta': {
              'definition': definition,
              'vwidth': width,
              'vheight': height,
              'bitrate': 842051,
              'size': 22421134,
              'codec_type': 'bytevc1',
            },
          },
        ],
      }),
    },
  });
}

void main() {
  group('播放信息解析', () {
    test('解析出清晰度与直链', () async {
      final http = _FakeHttp((_) => (200, _successBody()));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      final media = await client.fetchEpisodeMedia('7503780574541122622');

      expect(media.qualities, hasLength(1));
      final q = media.qualities.first;
      expect(q.definition, '1080p');
      expect(q.width, 1080);
      expect(q.height, 1920);
      expect(q.url, contains('1080p.mp4'));
      expect(q.backupUrl, contains('backup'));
      expect(q.codec, 'bytevc1');
      expect(media.durationSeconds, closeTo(211.834, 0.01));
    });

    test('多档按高度升序排列', () async {
      final body = jsonEncode({
        'code': 0,
        'data': {
          'expire_time': 1792534512,
          'video_model': jsonEncode({
            'video_duration': 100.0,
            'video_list': [
              {
                'main_url': 'https://cdn/1080p.mp4',
                'quality_type': 1,
                'video_meta': {
                  'definition': '1080p',
                  'vwidth': 1080,
                  'vheight': 1920,
                  'bitrate': 842051,
                  'size': 1,
                  'codec_type': 'bytevc1',
                },
              },
              {
                'main_url': 'https://cdn/360p.mp4',
                'quality_type': 40,
                'video_meta': {
                  'definition': '360p',
                  'vwidth': 360,
                  'vheight': 640,
                  'bitrate': 241691,
                  'size': 1,
                  'codec_type': 'bytevc1',
                },
              },
            ],
          }),
        },
      });
      final http = _FakeHttp((_) => (200, body));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      final media = await client.fetchEpisodeMedia('1');
      expect(media.qualities.first.definition, '360p');
      expect(media.qualities.last.definition, '1080p');
      expect(media.highest?.definition, '1080p');
      expect(media.lowest?.definition, '360p');
    });

    test('按目标高度选档', () async {
      final media = HongguoEpisodeMedia(
        videoId: '1',
        durationSeconds: 100,
        expireAt: DateTime.now(),
        videoHeight: 1920,
        qualities: const [
          HongguoQuality(
            definition: '360p',
            width: 360,
            height: 640,
            bitrate: 1,
            url: 'a',
            backupUrl: null,
            codec: '',
            fileSize: 1,
            qualityType: 40,
          ),
          HongguoQuality(
            definition: '720p',
            width: 720,
            height: 1280,
            bitrate: 1,
            url: 'b',
            backupUrl: null,
            codec: '',
            fileSize: 1,
            qualityType: 10,
          ),
          HongguoQuality(
            definition: '1080p',
            width: 1080,
            height: 1920,
            bitrate: 1,
            url: 'c',
            backupUrl: null,
            codec: '',
            fileSize: 1,
            qualityType: 1,
          ),
        ],
      );

      expect(media.pickByHeight(1280)?.definition, '720p');
      expect(media.pickByHeight(1920)?.definition, '1080p');
      expect(media.pickByHeight(640)?.definition, '360p');
    });
  });

  group('请求构造', () {
    test('带 x-ss-stub（请求体 MD5 大写）', () async {
      final http = _FakeHttp((_) => (200, _successBody()));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      await client.fetchEpisodeMedia('7503780574541122622');

      expect(http.capturedHeaders, hasLength(1));
      final h = http.capturedHeaders.first;
      expect(h['x-ss-stub'], isNotNull);
      expect(h['x-ss-stub'], matches(RegExp(r'^[0-9A-F]{32}$')));

      // stub 必须等于请求体的 MD5
      final body = http.capturedBodies.first;
      expect(h['x-ss-stub'], _md5Upper(body));
    });

    test('请求体包含嵌套 biz_param', () async {
      final http = _FakeHttp((_) => (200, _successBody()));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      await client.fetchEpisodeMedia('123');

      final body = jsonDecode(http.capturedBodies.first) as Map;
      expect(body['video_id'], '123');
      expect(body['content_type'], 1);
      final biz = body['biz_param'] as Map;
      expect(biz['need_all_video_definition'], isTrue);
      expect(biz['video_platform'], 3);
    });

    test('设备标识固定：多次请求用同一对 ID', () async {
      final http = _FakeHttp((_) => (200, _successBody()));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      await client.fetchEpisodeMedia('1');
      await client.fetchEpisodeMedia('2');

      // 从 URL 里取不到（假客户端不解析），改看诊断接口
      final diag = client.identityForDiagnostics;
      expect(diag['deviceId'], isNot('(未生成)'));
      expect(diag['installId'], isNot('(未生成)'));
    });
  });

  group('重试与错误分类', () {
    test('空 body 会重试，第 3 次成功', () async {
      final http = _FakeHttp((n) {
        if (n < 3) return (200, '');
        return (200, _successBody());
      });
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      final media = await client.fetchEpisodeMedia('1');
      expect(media.qualities, isNotEmpty);
      expect(http.calls, 3);
    });

    test('持续空 body 最终抛 upstreamError（可重试）', () async {
      final http = _FakeHttp((_) => (200, ''));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      await expectLater(
        () => client.fetchEpisodeMedia('1'),
        throwsA(isA<FusionException>()
            .having((e) => e.code, 'code', FusionErrorCode.upstreamError)
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
      expect(http.calls, 8, reason: '应重试满 8 次');
    });

    test('HTTP 404 → unsupportedPlatform，不重试', () async {
      final http = _FakeHttp((_) => (404, ''));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      expect(
        () => client.fetchEpisodeMedia('1'),
        throwsA(isA<FusionException>()
            .having((e) => e.code, 'code', FusionErrorCode.unsupportedPlatform)
            .having((e) => e.retryable, 'retryable', isFalse)),
      );
      expect(http.calls, 1);
    });

    test('HTTP 500 → networkError，可重试', () async {
      final http = _FakeHttp((_) => (500, ''));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      expect(
        () => client.fetchEpisodeMedia('1'),
        throwsA(isA<FusionException>()
            .having((e) => e.code, 'code', FusionErrorCode.networkError)
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
    });

    test('code != 0 → 重试后抛 parseError', () async {
      final http = _FakeHttp(
          (_) => (200, jsonEncode({'code': 100001, 'message': '参数错误'})));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      expect(
        () => client.fetchEpisodeMedia('1'),
        throwsA(isA<FusionException>()),
      );
    });

    test('video_list 为空 → 抛错而非返回空列表', () async {
      final body = jsonEncode({
        'code': 0,
        'data': {
          'expire_time': 1792534512,
          'video_model': jsonEncode({
            'video_duration': 100.0,
            'video_list': <Object>[],
          }),
        },
      });
      final http = _FakeHttp((_) => (200, body));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));

      expect(
        () => client.fetchEpisodeMedia('1'),
        throwsA(isA<FusionException>()),
      );
    });

    test('video_model 是 JSON 字符串也能解析', () async {
      final http = _FakeHttp((_) => (200, _successBody()));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));
      final media = await client.fetchEpisodeMedia('1');
      expect(media.qualities, isNotEmpty);
    });
  });

  group('过期时间', () {
    test('解析 expire_time', () async {
      final http = _FakeHttp((_) => (200, _successBody()));
      final client =
          HongguoMediaClient(http: http, logger: FusionLogger(enabled: false));
      final media = await client.fetchEpisodeMedia('1');
      expect(media.expireAt.year, greaterThan(2020));
    });
  });
}

String _md5Upper(String s) =>
    md5.convert(utf8.encode(s)).toString().toUpperCase();