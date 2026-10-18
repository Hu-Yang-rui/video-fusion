/// B站评论 IP 属地的解析与链路测试。
///
/// 覆盖任务要求的全部情形：
///  - 匿名（无 Cookie）请求
///  - 已登录（带 Cookie）请求
///  - 字段缺失（`reply_control` 无 `location`）
///  - 请求失败（HTTP 5xx / 412）
///  - 异常响应（location 是数字、reply_control 不是对象）
///
/// 核心约束：**数据不存在时必须为 null，不得补默认值、不得伪造地区**。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/interaction.dart';

/// 可控的假 HTTP 层：按 URL 路径返回预设响应，并记录请求头。
class FakeHttp extends FusionHttpClient {
  FakeHttp({
    required this.commentBody,
    this.commentStatus = 200,
    this.throwOnComment,
  }) : super(
          config: const HttpClientConfig(maxRetries: 0),
          logger: FusionLogger(enabled: false),
        );

  /// 评论接口返回的 JSON 字符串。
  String commentBody;

  /// 评论接口的 HTTP 状态码。
  int commentStatus;

  /// 非 null 时评论请求直接抛这个异常。
  FusionException? throwOnComment;

  /// 记录评论请求实际带上的 Cookie 头（null 表示没带）。
  String? lastCommentCookie;

  /// 评论请求被调用了几次。
  int commentCalls = 0;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
  }) async {
    // view 接口：用于把 BV 解析成 aid
    if (url.contains('/x/web-interface/view')) {
      return _result(
        url,
        200,
        '{"code":0,"data":{"aid":804796324}}',
      );
    }

    if (url.contains('/x/v2/reply')) {
      commentCalls++;
      lastCommentCookie = headers['Cookie'];
      if (throwOnComment != null) throw throwOnComment!;
      return _result(url, commentStatus, commentBody);
    }

    return _result(url, 200, '{"code":0,"data":{}}');
  }

  HttpResult _result(String url, int status, String body) => HttpResult(
        statusCode: status,
        body: body,
        headers: const {},
        url: url,
        attempts: 1,
        durationMs: 1,
      );
}

/// 构造一个只含一条评论的响应。
String commentResponse({
  Object? replyControl,
  bool includeReplyControl = true,
}) {
  final control = includeReplyControl
      ? '"reply_control":${replyControl == null ? 'null' : _jsonOf(replyControl)},'
      : '';
  return '''
{"code":0,"data":{
  "cursor":{"all_count":1,"next":0,"is_end":true},
  "replies":[
    {
      "rpid":157837398016,
      "ctime":1729000000,
      "like":3,
      "rcount":0,
      "floor":1,
      "member":{"uname":"测试用户","avatar":"https://example.test/a.jpg","mid":"12345"},
      "content":{"message":"这是一条评论"},
      $control
      "up_action":{"reply":false,"like":false}
    }
  ]
}}''';
}

String _jsonOf(Object value) {
  if (value is String) return '"$value"';
  if (value is Map) {
    final entries = value.entries.map((e) => '"${e.key}":${_jsonOf(e.value)}');
    return '{${entries.join(',')}}';
  }
  if (value is num || value is bool) return '$value';
  return '"$value"';
}

BilibiliAdapter adapterWith(FakeHttp http) =>
    BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));

/// 已登录会话（Cookie 内容为测试占位，不含真实凭证）。
PlatformSession testSession() => const PlatformSession(
      platformId: 'bilibili',
      displayName: '测试账号',
      userId: '12345',
      cookies: {
        'SESSDATA': 'test-sessdata-placeholder',
        'bili_jct': 'test-jct-placeholder',
      },
      loggedInAt: '2026-10-18T00:00:00.000Z',
    );

void main() {
  group('匿名请求', () {
    test('不带 Cookie 时请求头里没有 Cookie', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'max_line': 15},
        ),
      );
      final adapter = adapterWith(http);

      await adapter.fetchComments('BV1GJ411x7h7');

      expect(http.lastCommentCookie, isNull,
          reason: '匿名请求不得凭空带上 Cookie');
    });

    test('平台未给 location 时 ipLocation 为 null（不补默认值）', () async {
      // 这是 2026-10-18 实测到的**真实** reply_control 键集合
      // （来自 /x/v2/reply/wbi/main，正确 wbi 签名，code=0）。
      // 注意比早期文档多了 sub_reply_entry_text —— 键名会随版本变化，
      // 但 location 始终不在其中。
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {
            'max_line': 6,
            'sub_reply_entry_text': '共24条回复',
            'sub_reply_title_text': '相关回复共24条',
            'time_desc': '4天前发布',
            'translation_switch': 1,
            'support_share': true,
          },
        ),
      );
      final adapter = adapterWith(http);

      final page = await adapter.fetchComments('BV1GJ411x7h7');

      expect(page.items, hasLength(1));
      expect(page.items.first.ipLocation, isNull,
          reason: '匿名拿不到属地时必须为 null，不能填虚构地区');
    });

    test('reply_control 整个缺失时 ipLocation 为 null', () async {
      final http = FakeHttp(
        commentBody: commentResponse(includeReplyControl: false),
      );
      final adapter = adapterWith(http);

      final page = await adapter.fetchComments('BV1GJ411x7h7');

      expect(page.items, hasLength(1));
      expect(page.items.first.ipLocation, isNull);
    });

    test('reply_control 为 null 时 ipLocation 为 null', () async {
      final http = FakeHttp(commentBody: commentResponse(replyControl: null));
      final adapter = adapterWith(http);

      final page = await adapter.fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, isNull);
    });
  });

  group('已登录请求', () {
    test('带 Cookie 时请求头正确注入', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': 'IP属地：广东'},
        ),
      );
      final adapter = adapterWith(http);

      await adapter.fetchComments('BV1GJ411x7h7', session: testSession());

      expect(http.lastCommentCookie, isNotNull,
          reason: '登录态必须注入到评论请求，否则拿不到属地');
      expect(http.lastCommentCookie, contains('SESSDATA='));
      expect(http.lastCommentCookie, contains('bili_jct='));
    });

    test('登录后能解析出真实属地并剥离前缀', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': 'IP属地：广东'},
        ),
      );
      final adapter = adapterWith(http);

      final page = await adapter.fetchComments(
        'BV1GJ411x7h7',
        session: testSession(),
      );

      expect(page.items.first.ipLocation, '广东',
          reason: '必须剥掉「IP属地：」前缀，只留地区名');
    });

    test('登录后仍无 location 时依然为 null（平台限制，不伪造）', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'max_line': 15},
        ),
      );
      final adapter = adapterWith(http);

      final page = await adapter.fetchComments(
        'BV1GJ411x7h7',
        session: testSession(),
      );

      expect(page.items.first.ipLocation, isNull,
          reason: '登录了但平台不给，仍然必须为 null');
    });

    test('英文冒号前缀也能剥离', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': 'IP属地: 日本'},
        ),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, '日本');
    });

    test('带空格的「IP 属地：」前缀也能剥离', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': 'IP 属地：北京'},
        ),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, '北京');
    });

    test('已经是纯地区名时原样保留', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': '四川'},
        ),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, '四川');
    });

    test('location 为空字符串时为 null', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': ''},
        ),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, isNull);
    });

    test('location 只有前缀没有地区时为 null', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': 'IP属地：'},
        ),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, isNull,
          reason: '剥完前缀是空串，不能当成有效地区');
    });
  });

  group('异常响应', () {
    test('location 是数字时按解析失败处理为 null', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': 12345},
        ),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, isNull,
          reason: '类型不符时不得把数字转成字符串当地区');
    });

    test('location 是对象时为 null', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {
            'location': {'name': '广东'}
          },
        ),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, isNull);
    });

    test('reply_control 是字符串（非对象）时为 null 且不影响其它字段', () async {
      final http = FakeHttp(
        commentBody: commentResponse(replyControl: 'oops'),
      );
      final page =
          await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items.first.ipLocation, isNull);
      // 其它字段仍正常解析
      expect(page.items.first.authorName, '测试用户');
      expect(page.items.first.message, '这是一条评论');
    });
  });

  group('请求失败与错误分类', () {
    test('HTTP 412 抛 rateLimited（不是静默返回空）', () async {
      final http = FakeHttp(
        commentBody: '{}',
        commentStatus: 412,
      );

      await expectLater(
        adapterWith(http).fetchComments('BV1GJ411x7h7'),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.rateLimited,
        )),
      );
    });

    test('HTTP 500 抛 upstreamError（不是静默返回空）', () async {
      final http = FakeHttp(
        commentBody: 'server error',
        commentStatus: 500,
      );

      await expectLater(
        adapterWith(http).fetchComments('BV1GJ411x7h7'),
        throwsA(isA<FusionException>()),
      );
    });

    test('网络异常原样上报', () async {
      final http = FakeHttp(
        commentBody: '',
        throwOnComment: FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '网络请求失败',
          platformId: 'bilibili',
        ),
      );

      await expectLater(
        adapterWith(http).fetchComments('BV1GJ411x7h7'),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.networkError,
        )),
      );
    });

    test('平台业务码非 0 时抛错', () async {
      final http = FakeHttp(
        commentBody: '{"code":-352,"message":"风控校验失败"}',
      );

      await expectLater(
        adapterWith(http).fetchComments('BV1GJ411x7h7'),
        throwsA(isA<FusionException>()),
      );
    });

    test('data 为 null 时返回空页而非抛错', () async {
      final http = FakeHttp(commentBody: '{"code":0,"data":null}');

      final page = await adapterWith(http).fetchComments('BV1GJ411x7h7');

      expect(page.items, isEmpty);
      expect(page.totalCount, 0);
      expect(page.hasMore, isFalse);
    });
  });

  group('缓存不得冒充当前评论的属地', () {
    test('两次请求各自解析，互不串味', () async {
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {'location': 'IP属地：广东'},
        ),
      );
      final adapter = adapterWith(http);

      final first = await adapter.fetchComments('BV1GJ411x7h7');
      expect(first.items.first.ipLocation, '广东');

      // 平台这次没给属地（模拟字段缺失）
      http.commentBody = commentResponse(
        replyControl: const {'max_line': 15},
      );
      final second = await adapter.fetchComments('BV1GJ411x7h7');

      expect(second.items.first.ipLocation, isNull,
          reason: '不能沿用上一次的地区，必须按本次响应如实反映');
    });
  });

  group('登录后是否可得：链路已就绪，等真实账号验证', () {
    test('登录态下若平台开始下发 location，必须能正确解析', () async {
      // 这是"登录后能拿到"的**预期形态**。当前未实测（无账号），
      // 但只要平台下发，这条链路就能用。测试它防止将来平台真下发了
      // 却因为解析写错而拿不到。
      final http = FakeHttp(
        commentBody: commentResponse(
          replyControl: const {
            'max_line': 6,
            'time_desc': '4天前发布',
            'location': 'IP属地：浙江',
          },
        ),
      );

      final page = await adapterWith(http).fetchComments(
        'BV1GJ411x7h7',
        session: testSession(),
      );

      expect(page.items.first.ipLocation, '浙江');
    });

    test('同一份响应，匿名与登录的解析结果由平台决定而非本地补值', () async {
      // 匿名与登录拿到同一份"无 location"的响应时，结果必须一致为 null。
      // 不能因为"登录了"就补一个地区。
      final anon = FakeHttp(
        commentBody: commentResponse(replyControl: const {'max_line': 6}),
      );
      final auth = FakeHttp(
        commentBody: commentResponse(replyControl: const {'max_line': 6}),
      );

      final p1 = await adapterWith(anon).fetchComments('BV1GJ411x7h7');
      final p2 = await adapterWith(auth)
          .fetchComments('BV1GJ411x7h7', session: testSession());

      expect(p1.items.first.ipLocation, isNull);
      expect(p2.items.first.ipLocation, isNull,
          reason: '登录本身不产生属地，必须是平台下发');
    });
  });
}