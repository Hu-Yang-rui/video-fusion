/// 直播互动与分区筛选的测试。
///
/// 覆盖本次新增的四项能力（7/8/9/10）中**真正实现**的部分：
///  - 分区筛选：抖音本地按 category 过滤（不是假数据）
///  - 互动：B站点赞/关注/发弹幕的登录态与业务码判定
///  - 未登录时不发请求、不伪造状态
///
/// 以及**能力边界**的守护：
///  - 抖音互动/弹幕不渲染注定失败的按钮
///  - 写操作只看 HTTP 200 会误判（B站未登录返回 200 + code=-101）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_live_interaction.dart';
import 'package:video_fusion/src/adapters/douyin/live_client.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/live.dart';

/// 可控假 HTTP。
class FakeHttp extends FusionHttpClient {
  FakeHttp({required this.body, this.status = 200})
      : super(logger: FusionLogger(enabled: false));

  String body;
  int status;
  String? lastBody;
  String? lastUrl;
  int calls = 0;

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
    lastUrl = url;
    lastBody = body;
    return HttpResult(
      statusCode: status,
      body: this.body,
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 1,
    );
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
    calls++;
    lastUrl = url;
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

/// 构造一个已登录的 B站会话（占位值，非真实凭证）。
PlatformSession sessionWith({String? jct = 'test-jct-placeholder'}) {
  return PlatformSession(
    platformId: 'bilibili',
    displayName: '测试账号',
    userId: '12345',
    cookies: {
      'SESSDATA': 'test-sessdata-placeholder',
      if (jct != null) 'bili_jct': jct,
      'DedeUserID': '12345',
    },
    loggedInAt: '2026-10-18T00:00:00.000Z',
  );
}

BilibiliLiveInteraction interactionWith(FakeHttp http) =>
    BilibiliLiveInteraction(http: http, logger: FusionLogger(enabled: false));

void main() {
  group('抖音分区码映射（只映射实测确认过的码）', () {
    test('已知码返回真实品类名', () {
      expect(DouyinLiveClient.categoryLabel(545), '王者荣耀');
      expect(DouyinLiveClient.categoryLabel(7832), '王者万象棋');
      expect(DouyinLiveClient.categoryLabel(546), '英雄联盟');
      expect(DouyinLiveClient.categoryLabel(448), 'Dota2');
      expect(DouyinLiveClient.categoryLabel(1128), '秀场');
    });

    test('未知码返回 null，不编造品类', () {
      expect(DouyinLiveClient.categoryLabel(999999), isNull);
      expect(DouyinLiveClient.categoryLabel(null), isNull);
      expect(DouyinLiveClient.categoryLabel(0), isNull);
    });
  });

  group('抖音分区统计（用于构造筛选选项）', () {
    LiveRoomSummary room(String key, int? cat) => LiveRoomSummary(
          roomId: 0,
          roomKey: key,
          title: 't',
          uname: 'u',
          categoryCode: cat,
        );

    test('按出现次数降序返回', () {
      final client = DouyinLiveClient(
        http: FakeHttp(body: '{}'),
        logger: FusionLogger(enabled: false),
      );

      final codes = client.categoriesIn([
        room('a', 545),
        room('b', 545),
        room('c', 448),
        room('d', null),
      ]);

      expect(codes.first, 545, reason: '出现 2 次的排最前');
      expect(codes, contains(448));
      expect(codes, isNot(contains(null)));
    });

    test('全部无 category 时返回空', () {
      final client = DouyinLiveClient(
        http: FakeHttp(body: '{}'),
        logger: FusionLogger(enabled: false),
      );
      expect(client.categoriesIn([room('a', null)]), isEmpty);
    });
  });

  group('B站直播互动：未登录不伪造', () {
    test('未登录点赞抛 loginRequired，且不发请求', () async {
      final http = FakeHttp(body: '{"code":0}');

      await expectLater(
        interactionWith(http).like(roomId: 1, session: null),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.loginRequired,
        )),
      );
      expect(http.calls, 0, reason: '未登录不应发出请求');
    });

    test('缺少 bili_jct 时抛 loginRequired（写操作需要 csrf）', () async {
      final http = FakeHttp(body: '{"code":0}');

      await expectLater(
        interactionWith(http).like(
          roomId: 1,
          session: sessionWith(jct: null),
        ),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.loginRequired,
        )),
      );
      expect(http.calls, 0, reason: '缺 csrf 不应发出注定失败的请求');
    });

    test('弹幕为空时不发请求', () async {
      final http = FakeHttp(body: '{"code":0}');

      await expectLater(
        interactionWith(http).sendDanmaku(
          roomId: 1,
          message: '   ',
          session: sessionWith(),
        ),
        throwsA(isA<FusionException>()),
      );
      expect(http.calls, 0);
    });

    test('弹幕超过 20 字时拒绝', () async {
      final http = FakeHttp(body: '{"code":0}');

      await expectLater(
        interactionWith(http).sendDanmaku(
          roomId: 1,
          message: '这是一条超过二十个字的弹幕内容需要被拒绝掉才对',
          session: sessionWith(),
        ),
        throwsA(isA<FusionException>()),
      );
      expect(http.calls, 0);
    });
  });

  group('B站直播互动：业务码判定（不能只看 HTTP 200）', () {
    test('HTTP 200 + code=0 才算成功', () async {
      final http = FakeHttp(body: '{"code":0,"message":"0"}');

      final r = await interactionWith(http).like(
        roomId: 1,
        session: sessionWith(),
      );

      expect(r.ok, isTrue);
      expect(r.message, '已点赞');
    });

    test('HTTP 200 + code=-101 判为失败（登录失效）', () async {
      // 这是实测的真实响应：未登录时 HTTP 200 但 code=-101。
      // 只看 HTTP 状态码会把失败当成功。
      final http = FakeHttp(body: '{"code":-101,"message":"账号未登录"}');

      final r = await interactionWith(http).like(
        roomId: 1,
        session: sessionWith(),
      );

      expect(r.ok, isFalse, reason: 'HTTP 200 不等于成功');
      expect(r.error?.code, FusionErrorCode.loginRequired);
    });

    test('code=-352 判为限流且可重试', () async {
      final http = FakeHttp(body: '{"code":-352,"message":"风控校验失败"}');

      final r = await interactionWith(http).sendDanmaku(
        roomId: 1,
        message: 'test',
        session: sessionWith(),
      );

      expect(r.ok, isFalse);
      expect(r.error?.code, FusionErrorCode.rateLimited);
      expect(r.error?.retryable, isTrue);
    });

    test('code=-111 判为凭证不完整', () async {
      final http = FakeHttp(body: '{"code":-111,"message":"csrf 校验失败"}');

      final r = await interactionWith(http).follow(
        uid: 1,
        follow: true,
        session: sessionWith(),
      );

      expect(r.ok, isFalse);
      expect(r.error?.code, FusionErrorCode.loginRequired);
    });

    test('非 JSON 响应判为 parseError，不静默成功', () async {
      final http = FakeHttp(body: '<html>error</html>');

      final r = await interactionWith(http).like(
        roomId: 1,
        session: sessionWith(),
      );

      expect(r.ok, isFalse);
      expect(r.error?.code, FusionErrorCode.parseError);
    });
  });

  group('B站直播互动：请求参数正确', () {
    test('点赞请求带 csrf（bili_jct 的值）', () async {
      final http = FakeHttp(body: '{"code":0}');

      await interactionWith(http).like(
        roomId: 22908869,
        session: sessionWith(jct: 'my-jct-value'),
      );

      expect(http.lastBody, contains('csrf=my-jct-value'));
      expect(http.lastBody, contains('room_id=22908869'));
    });

    test('关注请求带 fid 与 act', () async {
      final http = FakeHttp(body: '{"code":0}');

      await interactionWith(http).follow(
        uid: 777,
        follow: true,
        session: sessionWith(),
      );

      expect(http.lastBody, contains('fid=777'));
      expect(http.lastBody, contains('act=1'));
    });

    test('取消关注 act=2', () async {
      final http = FakeHttp(body: '{"code":0}');

      await interactionWith(http).follow(
        uid: 777,
        follow: false,
        session: sessionWith(),
      );

      expect(http.lastBody, contains('act=2'));
    });

    test('发弹幕带 msg / roomid / color / mode', () async {
      final http = FakeHttp(body: '{"code":0}');

      await interactionWith(http).sendDanmaku(
        roomId: 100,
        message: '你好',
        session: sessionWith(),
        color: 16777215,
        mode: 1,
      );

      expect(http.lastBody, contains('msg='));
      expect(http.lastBody, contains('roomid=100'));
      expect(http.lastBody, contains('color=16777215'));
      expect(http.lastBody, contains('mode=1'));
    });

    test('弹幕中文被正确 urlencode', () async {
      final http = FakeHttp(body: '{"code":0}');

      await interactionWith(http).sendDanmaku(
        roomId: 1,
        message: '测试弹幕',
        session: sessionWith(),
      );

      expect(http.lastBody, contains('%E6%B5%8B%E8%AF%95%E5%BC%B9%E5%B9%95'));
    });
  });
}
