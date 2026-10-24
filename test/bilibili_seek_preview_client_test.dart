/// B站字幕 / 进度条拼图的数据层回归测试（离线，用真实抓包结构）。
///
/// 守住三件容易改错的事：
///  1. `videoshot` 的参数形态必须是 **aid + index**（bvid/cid 变体给空 index）
///  2. `av` 形式的 id 也要能解析（view 接口要给 aid= 而不是 bvid=）
///  3. 拼图是二进制，必须走 `keepRawBytes`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili/subtitles.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';

import 'support/local_fixtures.dart';

/// 记录请求 URL，按路径返回预置响应。
class _StubHttp extends FusionHttpClient {
  _StubHttp(this.routes) : super(logger: FusionLogger(enabled: false));

  final Map<String, String> routes;
  final List<String> calls = [];

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
    calls.add(url);
    for (final entry in routes.entries) {
      if (!url.contains(entry.key)) continue;
      final body = entry.value;
      return HttpResult(
        statusCode: 200,
        headers: const {},
        url: url,
        attempts: 1,
        durationMs: 1,
        body: body,
        rawBytes: keepRawBytes
            ? Uint8List.fromList(latin1.encode(body))
            : null,
      );
    }
    return HttpResult(
      statusCode: 404,
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 1,
      body: '{"code":-404}',
    );
  }
}

/// 真实 `/x/web-interface/view` 的字段形状（截断）。
const _viewJson = '''
{"code":0,"data":{"aid":42981787083,"bvid":"BV1z9nt6aE5H",
"cid":266919700,"duration":6867}}
''';

/// 真实抓包不入公开仓库，缺失时这一条显式跳过。
final Object _missing = skipIfMissing(['tool/live/_videoshot_A_anon.json']);

void main() {
  test('videoshot 用 aid+index 取，且解析出帧表', () async {
    final http = _StubHttp({
      '/x/web-interface/view': _viewJson,
      '/x/player/videoshot':
          File('tool/live/_videoshot_A_anon.json').readAsStringSync(),
    });
    final client = BilibiliSubtitleClient(
      http: http,
      logger: FusionLogger(enabled: false),
    );
    final ids = await client.resolveIds('BV1z9nt6aE5H');
    expect(ids, isNotNull);
    expect(ids!.aid, 42981787083);
    expect(ids.bvid, 'BV1z9nt6aE5H');

    final spec = await client.fetchSprite(ids.aid);
    expect(spec, isNotNull);
    expect(spec!.frameCount, 42);
    // 参数形态必须是 aid + index=1（bvid/cid 变体返回空 index，见探针）
    final url = http.calls.lastWhere((u) => u.contains('videoshot'));
    expect(url, contains('aid=42981787083'));
    expect(url, contains('index=1'));
    expect(url, isNot(contains('bvid=')));
    expect(url, isNot(contains('cid=')));
  }, skip: _missing);

  test('av 形式走 aid= 查询，并回填规范 bvid', () async {
    final http = _StubHttp({'/x/web-interface/view': _viewJson});
    final client = BilibiliSubtitleClient(
      http: http,
      logger: FusionLogger(enabled: false),
    );
    final ids = await client.resolveIds('av42981787083');
    expect(ids, isNotNull);
    expect(ids!.bvid, 'BV1z9nt6aE5H', reason: '字幕接口只认 bvid');
    expect(http.calls.single, contains('aid=42981787083'));
    expect(http.calls.single, isNot(contains('bvid=')));
  });

  test('index 为空 → 返回 null（不画一张空白预览）', () async {
    final empty = jsonEncode({
      'code': 0,
      'data': {
        'img_x_len': 10,
        'img_y_len': 10,
        'img_x_size': 480,
        'img_y_size': 270,
        'image': ['//bimp.hdslb.com/x-0001.jpg'],
        'index': <int>[],
      },
    });
    final http = _StubHttp({
      '/x/web-interface/view': _viewJson,
      '/x/player/videoshot': empty,
    });
    final client = BilibiliSubtitleClient(
      http: http,
      logger: FusionLogger(enabled: false),
    );
    expect(await client.fetchSprite(42981787083), isNull);
  });

  test('拼图字节走 rawBytes（二进制不能按文本读）', () async {
    final http = _StubHttp({'bimp.hdslb.com': 'PNGDATA'});
    final client = BilibiliSubtitleClient(
      http: http,
      logger: FusionLogger(enabled: false),
    );
    final bytes =
        await client.fetchSpriteBytes('https://bimp.hdslb.com/a-0001.jpg');
    expect(bytes, isNotNull);
    expect(bytes!.isNotEmpty, isTrue);
  });

  test('服务层只对 B站开启：其它平台不显示字幕/预览入口', () {
    final service = VideoService(
      registry: PlatformRegistry(
        adapters: [BilibiliAdapter(http: _StubHttp(const {}))],
      ),
      store: VideoStore(storage: InMemoryStore()),
      http: _StubHttp(const {}),
    );
    expect(service.supportsSubtitlesFor('bilibili'), isTrue);
    // 抖音/红果没有这两项能力 → UI 不会渲染按钮，也不会白跑请求
    expect(service.supportsSubtitlesFor('douyin'), isFalse);
    expect(service.supportsSubtitlesFor('hongguo'), isFalse);
  });
}
