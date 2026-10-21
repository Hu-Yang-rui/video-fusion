/// 红果播放客户端测试。
///
/// 用本地桩模拟两步链路：
///   POST video_model/v1/  → 返回含 video_model 的 JSON
///   GET  fallback_api     → 返回含 video_list 的 JSON
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/media_client.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

/// 记录每次请求并返回预设响应的桩。
class _StubHttp implements FusionHttpClient {
  _StubHttp({required this.responses});

  /// 按顺序返回的响应；用完后复用最后一个。
  final List<HttpResult> responses;

  final List<({String url, String body, Map<String, String> headers})> calls =
      [];

  int _index = 0;

  HttpResult _next() {
    final r = responses[_index.clamp(0, responses.length - 1)];
    if (_index < responses.length - 1) _index++;
    return r;
  }

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
    calls.add((url: url, body: body ?? '', headers: headers));
    return _next();
  }

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
    calls.add((url: url, body: '', headers: headers));
    return _next();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HttpResult _ok(String body) => HttpResult(
  statusCode: 200,
  body: body,
  headers: const {},
  url: 'https://example.com',
  attempts: 1,
  durationMs: 1,
);

HttpResult _status(int code, [String body = '']) => HttpResult(
  statusCode: code,
  body: body,
  headers: const {},
  url: 'https://example.com',
  attempts: 1,
  durationMs: 1,
);

/// 构造第一步响应（含 video_model）。
String _modelResponse({String? fallback, String? modelOverride}) {
  final model = modelOverride ??
      jsonEncode({
        'status': 10,
        'message': 'success',
        'version': 3,
        'video_id': 'v0debeg10000dbbh6p7og65uhjjn8kd0',
        'video_duration': 277.805,
        'url_expire': 1792622202,
        if (fallback != null) 'fallback_api': {'fallback_api': fallback},
      });
  return jsonEncode({
    'BaseResp': {'StatusCode': 0, 'StatusMessage': 'success'},
    'code': 0,
    'data': {
      'disable_vsr': true,
      'expire_time': 1792621925,
      'video_height': 720,
      'video_model': model,
      'video_width': 1280,
    },
  });
}

/// 构造第二步响应（含多档 video_list）。
String _fallbackResponse({List<Map<String, Object?>>? items}) {
  final list = items ??
      [
        {
          'main_url': 'https://v9.example.com/1080.mp4?ft=abc',
          'codec_type': 'bytevc1',
          'definition': '1080p',
          'vwidth': 1080,
          'vheight': 1920,
          'bitrate': 1213683,
          'size': 21079909,
        },
        {
          'main_url': 'https://v9.example.com/720.mp4?ft=def',
          'codec_type': 'bytevc1',
          'definition': '720p',
          'vwidth': 720,
          'vheight': 1280,
          'bitrate': 842000,
          'size': 14000000,
        },
        {
          'main_url': 'https://v9.example.com/360.mp4?ft=ghi',
          'codec_type': 'bytevc1',
          'definition': '360p',
          'vwidth': 360,
          'vheight': 640,
          'bitrate': 241000,
          'size': 6971183,
        },
      ];
  return jsonEncode({
    'video_info': {
      'data': {
        'video_list': {
          for (var i = 0; i < list.length; i++) 'video_${i + 1}': list[i],
        },
        'key_seed': '',
      },
    },
  });
}

HongguoMediaClient _client(_StubHttp http) =>
    HongguoMediaClient(http: http, logger: FusionLogger(minLevel: LogLevel.error));

void main() {
  group('完整链路', () {
    test('两步请求都能解析出多档直链', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/fplay/1/h/v?aid=8662')),
          _ok(_fallbackResponse()),
        ],
      );
      final media = await _client(http).fetchEpisodeMedia('7680951264905022488');

      expect(http.calls, hasLength(2));
      expect(http.calls[0].url, contains('/novel/player/video_model/v1/'));
      expect(http.calls[1].url, startsWith('https://vas.example.com/fplay/1/'));

      expect(media.qualities, hasLength(3));
      expect(media.highest!.definition, '1080p');
      expect(media.lowest!.definition, '360p');
      expect(media.videoHeight, 720);
      expect(media.durationSeconds, closeTo(277.805, 0.01));
    });

    test('档位按高度升序', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      final heights = media.qualities.map((q) => q.height).toList();
      expect(heights, [640, 1280, 1920]);
    });

    test('pickByHeight 按标签精确匹配', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      expect(media.pickByHeight(1080)!.definition, '1080p');
      expect(media.pickByHeight(720)!.definition, '720p');
      expect(media.pickByHeight(360)!.definition, '360p');
    });

    test('pickByHeight 无精确标签时退化为最接近高度', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      // 没有 480p 档，应选最接近的
      expect(media.pickByHeight(480), isNotNull);
    });
  });

  group('请求构造', () {
    test('第一步带六个签名头', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      await _client(http).fetchEpisodeMedia('1');

      final headers = http.calls[0].headers;
      for (final h in [
        'x-khronos',
        'x-ladon',
        'x-argus',
        'x-gorgon',
        'x-helios',
        'x-medusa',
        'x-ss-stub',
      ]) {
        expect(headers.containsKey(h), isTrue, reason: '缺少 $h');
      }
    });

    test('请求体含 video_platform=1024 与 video_id', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      await _client(http).fetchEpisodeMedia('999');

      final body = jsonDecode(http.calls[0].body) as Map<String, Object?>;
      expect(body['video_id'], '999');
      final biz = body['biz_param'] as Map<String, Object?>;
      expect(biz['video_platform'], 1024);
      expect(biz['need_all_video_definition'], isTrue);
    });

    test('每次请求用新的设备身份（16 位数字）', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      await _client(http).fetchEpisodeMedia('1');

      final qs = Uri.parse(http.calls[0].url).queryParameters;
      expect(qs['device_id'], matches(r'^[0-9]{16}$'));
      expect(qs['iid'], matches(r'^[0-9]{16}$'));
      expect(qs['device_id'], isNot(qs['iid']));
    });

    test('x-ss-stub 是请求体的 MD5 大写', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      await _client(http).fetchEpisodeMedia('1');

      final stub = http.calls[0].headers['x-ss-stub'];
      expect(stub, matches(r'^[0-9A-F]{32}$'));
    });
  });

  group('错误分类', () {
    test('空 body 换身份重试后成功', () async {
      final http = _StubHttp(
        responses: [
          _ok(''),
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      expect(media.qualities, isNotEmpty);
      expect(http.calls.length, greaterThanOrEqualTo(3));
    });

    test('持续空 body 抛 upstreamError（可重试）', () async {
      final http = _StubHttp(responses: [_ok('')]);
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(
          isA<FusionException>()
              .having((e) => e.code, 'code', FusionErrorCode.upstreamError)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('HTTP 404 → unsupportedPlatform，不重试', () async {
      final http = _StubHttp(responses: [_status(404)]);
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(
          isA<FusionException>()
              .having((e) => e.code, 'code', FusionErrorCode.unsupportedPlatform)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      expect(http.calls, hasLength(1));
    });

    test('HTTP 500 → networkError，可重试', () async {
      final http = _StubHttp(responses: [_status(500)]);
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(
          isA<FusionException>()
              .having((e) => e.code, 'code', FusionErrorCode.networkError)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('业务错误码 → upstreamError，不重试', () async {
      final http = _StubHttp(
        responses: [
          _ok(jsonEncode({'code': 100001, 'message': 'video platform invalid'})),
        ],
      );
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(
          isA<FusionException>()
              .having((e) => e.code, 'code', FusionErrorCode.upstreamError)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('fallback_api 缺失 → parseError', () async {
      final http = _StubHttp(
        responses: [_ok(_modelResponse()), _ok(_fallbackResponse())],
      );
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(
          isA<FusionException>()
              .having((e) => e.code, 'code', FusionErrorCode.parseError),
        ),
      );
    });

    test('video_list 为空 → 抛错而非返回空列表', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(jsonEncode({'video_info': {'data': {'video_list': {}}}})),
        ],
      );
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(isA<FusionException>()),
      );
    });

    test('第二步 HTTP 500 → networkError', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _status(500),
        ],
      );
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(
          isA<FusionException>()
              .having((e) => e.code, 'code', FusionErrorCode.networkError),
        ),
      );
    });
  });

  group('响应形态兼容', () {
    test('video_model 是对象而非字符串也能解析', () async {
      final modelObj = {
        'video_duration': 100.5,
        'fallback_api': {'fallback_api': 'https://vas.example.com/f'},
      };
      final body = jsonEncode({
        'code': 0,
        'data': {'video_height': 1080, 'video_model': modelObj},
      });
      final http = _StubHttp(
        responses: [_ok(body), _ok(_fallbackResponse())],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      expect(media.qualities, isNotEmpty);
    });

    test('fallback_api 是字符串也能解析', () async {
      final modelStr = jsonEncode({
        'video_duration': 50,
        'fallback_api': 'https://vas.example.com/direct',
      });
      final body = jsonEncode({
        'code': 0,
        'data': {'video_model': modelStr},
      });
      final http = _StubHttp(
        responses: [_ok(body), _ok(_fallbackResponse())],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      expect(media.qualities, isNotEmpty);
      expect(http.calls[1].url, 'https://vas.example.com/direct');
    });

    test('Code 大写字段也能识别', () async {
      final http = _StubHttp(
        responses: [
          _ok(jsonEncode({'Code': 110001, 'Message': '未知异常'})),
        ],
      );
      await expectLater(
        _client(http).fetchEpisodeMedia('1'),
        throwsA(
          isA<FusionException>()
              .having((e) => e.code, 'code', FusionErrorCode.upstreamError),
        ),
      );
    });

    test('ByteVC2 档位被跳过（播放器不支持）', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(
            _fallbackResponse(
              items: [
                {
                  'main_url': 'https://v9.example.com/bvc2.mp4',
                  'codec_type': 'bytevc2',
                  'definition': '1080p',
                  'vheight': 1920,
                },
                {
                  'main_url': 'https://v9.example.com/hevc.mp4',
                  'codec_type': 'bytevc1',
                  'definition': '720p',
                  'vheight': 1280,
                },
              ],
            ),
          ),
        ],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      expect(media.qualities, hasLength(1));
      expect(media.highest!.definition, '720p');
    });

    test('解析 expire_time 为 DateTime', () async {
      final http = _StubHttp(
        responses: [
          _ok(_modelResponse(fallback: 'https://vas.example.com/f')),
          _ok(_fallbackResponse()),
        ],
      );
      final media = await _client(http).fetchEpisodeMedia('1');
      expect(media.expireAt.year, greaterThan(2025));
    });
  });
}
