/// B 站视频总结的解析测试。
///
/// 用**真实响应结构**做样本（2026-10-20 实测拿到的）。
/// 不联网——只验证解析逻辑与状态分类。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/bilibili_summary_provider.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/models/video_summary.dart';

/// 可控的假 HTTP 客户端。
class _FakeHttp extends FusionHttpClient {
  _FakeHttp(this.responder) : super();

  final HttpResult Function(String url) responder;

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
    // 拦截 wbi 密钥请求
    if (url.contains('/x/web-interface/nav')) {
      return HttpResult(
        statusCode: 200,
        headers: const {},
        url: url,
        attempts: 1,
        durationMs: 1,
        body: jsonEncode({
          'code': 0,
          'data': {
            'isLogin': true,
            'wbi_img': {
              'img_url':
                  'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
              'sub_url':
                  'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
            },
          },
        }),
      );
    }
    return responder(url);
  }
}

/// 真实的有总结响应（截断版，结构完整）。
const _withSummary = '''
{
  "code": 0,
  "data": {
    "model_result": {
      "result_type": 2,
      "summary": "团队探访OnlyFans平台，剖析成人创作者生态。",
      "outline": [
        {
          "title": "探索成人创作者生态",
          "timestamp": 1,
          "part_outline": [
            {"timestamp": 20, "content": "平台吸引创作者与粉丝付费互动"},
            {"timestamp": 50, "content": "年支付超60亿美元"}
          ]
        },
        {
          "title": "收入困境",
          "timestamp": 600,
          "part_outline": [
            {"timestamp": 632, "content": "自主拍摄个人写真在线销售"}
          ]
        }
      ],
      "subtitle": []
    },
    "stid": "abc",
    "status": 0,
    "like_num": 0,
    "dislike_num": 0
  }
}
''';

/// 真实的无总结响应（code=0 但 summary 为空）。
const _noSummary = '''
{
  "code": 0,
  "data": {
    "model_result": {
      "result_type": 0,
      "summary": "",
      "outline": [],
      "subtitle": []
    },
    "stid": "",
    "status": 0
  }
}
''';

void main() {
  BilibiliSummaryProvider providerReturning(String body, {int status = 200}) {
    final p = BilibiliSummaryProvider(
      http: _FakeHttp(
        (_) => HttpResult(statusCode: status, headers: const {}, body: body, url: 'x', attempts: 1, durationMs: 1),
      ),
    );
    p.cookieHeader = 'SESSDATA=test';
    return p;
  }

  group('B站视频总结解析', () {
    test('有总结：解析出正文与章节', () async {
      final p = providerReturning(_withSummary);
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.success);
      expect(r.source, VideoSummarySource.platform,
          reason: 'B站官方总结不得标为本项目生成');
      expect(r.summary, contains('OnlyFans'));
      expect(r.chapters.length, 2);

      final first = r.chapters.first;
      expect(first.title, '探索成人创作者生态');
      expect(first.timestampSeconds, 1);
      expect(first.canSeek, isTrue);
      expect(first.points.length, 2);
      expect(first.points.first.timestampSeconds, 20);
    });

    test('无总结：code=0 但 summary 为空 → noSummary 而非 failed', () async {
      final p = providerReturning(_noSummary);
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.noSummary,
          reason: '必须区分「无总结」与「请求失败」');
      expect(r.retryable, isFalse, reason: '无总结不该给重试按钮');
      expect(r.summary, isNull);
    });

    test('-403 权限不足 → failed，不是 noSummary', () async {
      final p = providerReturning(
        jsonEncode({'code': -403, 'message': '访问权限不足'}),
      );
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.failed);
      expect(r.upstreamCode, -403);
      expect(r.errorMessage, contains('权限'));
    });

    test('-101 未登录 → failed，提示登录', () async {
      final p = providerReturning(
        jsonEncode({'code': -101, 'message': '账号未登录'}),
      );
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.failed);
      expect(r.errorMessage, contains('登录'));
    });

    test('-412 限流 → 可重试', () async {
      final p = providerReturning(
        jsonEncode({'code': -412, 'message': '请求被拦截'}),
      );
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.failed);
      expect(r.retryable, isTrue);
    });

    test('HTTP 500 → failed', () async {
      final p = providerReturning('server error', status: 500);
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.failed);
      expect(r.upstreamCode, 500);
    });

    test('未登录（无 Cookie）→ 不发请求直接失败', () async {
      final p = BilibiliSummaryProvider(
        http: _FakeHttp(
          (_) => throw StateError('不应该发请求'),
        ),
      );
      // 不设 cookieHeader
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.failed);
      expect(r.errorMessage, contains('登录'));
    });

    test('缺 bvid 或 cid → 失败且不可重试', () async {
      final p = providerReturning(_withSummary);
      final r = await p.fetchSummary(bvid: '', cid: 0, upMid: 456);

      expect(r.status, VideoSummaryStatus.failed);
      expect(r.retryable, isFalse);
    });

    test('响应结构变化（model_result 缺失）→ noSummary 而非崩溃', () async {
      final p = providerReturning(
        jsonEncode({'code': 0, 'data': <String, Object?>{}}),
      );
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.noSummary);
    });

    test('summary 为空但有 outline → 用章节拼出正文', () async {
      final p = providerReturning(jsonEncode({
        'code': 0,
        'data': {
          'model_result': {
            'summary': '',
            'outline': [
              {
                'title': '第一章',
                'timestamp': 0,
                'part_outline': [
                  {'timestamp': 5, 'content': '要点一'}
                ]
              }
            ]
          }
        }
      }));
      final r = await p.fetchSummary(bvid: 'BV1xx', cid: 123, upMid: 456);

      expect(r.status, VideoSummaryStatus.success);
      expect(r.summary, contains('要点一'));
      expect(r.chapters.length, 1);
    });
  });
}
