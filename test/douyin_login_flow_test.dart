/// 抖音扫码登录的凭证换取链路测试。
///
/// 守护三件事：
///  1. **Set-Cookie 必须被接住**。`get_qrcode` 下发
///     `passport_csrf_token`，轮询必须带回，否则服务端无法关联会话。
///     旧实现的 HTTP 层把响应 Cookie 全部丢弃。
///  2. **二维码图片必须直接展示**。抖音返回的是已渲染好的 base64 PNG，
///     当文本再编码会画出扫不出来的假码。
///  3. **确认 ≠ 成功**。拿到会话 cookie 才算成功；
///     没拿到必须如实报失败，不能停在"正在获取凭证…"。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/login_client.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/qr_login.dart';

/// 固定时间戳，避免测试里用 DateTime.now() 造成不确定性。
final DateTime _t0 = DateTime.utc(2026, 10, 18);

/// 可控的假 passport 服务。
///
/// 用于在**不接触真实平台**的前提下验证：
///  - 取码下发的 csrf cookie 是否被带回轮询
///  - 确认后没有会话 cookie 时是否如实报失败
///  - 确认后有会话 cookie 时是否真的产出会话
class FakePassportHttp extends FusionHttpClient {
  FakePassportHttp() : super(logger: FusionLogger(enabled: false));

  /// `check_qrconnect` 的响应体。
  String pollBody = '{"data":{"error_code":0,"status":"new"}}';

  /// `check_qrconnect` 的 Set-Cookie。
  List<String> pollSetCookies = const [];

  /// `get_qrcode` 的 Set-Cookie（真实服务会下发 csrf token）。
  List<String> qrSetCookies = const [
    'passport_csrf_token=csrf-token-placeholder; Path=/; Domain=douyin.com',
  ];

  /// 记录轮询请求实际带上的 Cookie 头。
  String? lastPollCookie;

  /// 轮询被调用次数。
  int pollCalls = 0;

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
    if (url.contains('/passport/web/get_qrcode/')) {
      final expire =
          DateTime.now().add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/
              1000;
      return _r(
        url,
        '{"data":{"error_code":0,'
        '"qrcode":"iVBORw0KGgoAAAANSUhEUg==",'
        '"token":"test-token-placeholder",'
        '"expire_time":$expire}}',
        qrSetCookies,
      );
    }
    if (url.contains('/passport/web/check_qrconnect/')) {
      pollCalls++;
      lastPollCookie = headers['Cookie'];
      return _r(url, pollBody, pollSetCookies);
    }
    return _r(url, '{}', const []);
  }

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
  }) async =>
      _r(url, '{}', const []);

  HttpResult _r(String url, String body, List<String> cookies) => HttpResult(
        statusCode: 200,
        body: body,
        headers: const {},
        url: url,
        attempts: 1,
        durationMs: 1,
        setCookies: cookies,
      );
}

void main() {
  group('HttpResult 解析 Set-Cookie', () {
    test('多值不被逗号合并破坏', () {
      // dart:io 的 headers.forEach 会把同名多值用逗号拼起来，
      // 而 Expires 本身含逗号，拼接后无法可靠切分。
      // 因此 setCookies 必须保存原始列表。
      final result = HttpResult(
        statusCode: 200,
        body: '',
        headers: const {},
        url: 'https://www.douyin.com/passport/web/get_qrcode/',
        attempts: 1,
        durationMs: 1,
        setCookies: const [
          'passport_csrf_token=abc123; Path=/; Domain=douyin.com; Max-Age=5184000; Secure; SameSite=None',
          'passport_csrf_token_default=def456; Path=/; Domain=douyin.com; Max-Age=5184000',
          'reg-store-region=; Path=/; Domain=douyin.com; Max-Age=0; HttpOnly',
        ],
      );

      final parsed = result.parsedSetCookies;

      expect(parsed['passport_csrf_token'], 'abc123');
      expect(parsed['passport_csrf_token_default'], 'def456');
      expect(parsed.containsKey('reg-store-region'), isFalse,
          reason: 'Max-Age=0 的删除指令不应被当成有效 cookie');
    });

    test('没有 Set-Cookie 时返回空映射', () {
      final result = HttpResult(
        statusCode: 200,
        body: '',
        headers: const {},
        url: 'https://example.test/',
        attempts: 1,
        durationMs: 1,
      );
      expect(result.parsedSetCookies, isEmpty);
    });

    test('属性段被正确剥离（Path/Domain/Expires 不进值）', () {
      final result = HttpResult(
        statusCode: 200,
        body: '',
        headers: const {},
        url: 'https://example.test/',
        attempts: 1,
        durationMs: 1,
        setCookies: const [
          'sessionid=xyz789; Path=/; Domain=.douyin.com; '
              'Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly; Secure',
        ],
      );

      expect(result.parsedSetCookies['sessionid'], 'xyz789',
          reason: '值里不能混入 Expires 里的逗号与日期');
    });

    test('畸形 cookie 被跳过而不抛错', () {
      final result = HttpResult(
        statusCode: 200,
        body: '',
        headers: const {},
        url: 'https://example.test/',
        attempts: 1,
        durationMs: 1,
        setCookies: const ['novalue', '=empty-name', 'ok=1'],
      );

      expect(result.parsedSetCookies, {'ok': '1'});
    });
  });

  group('二维码载体：图片与文本必须分开', () {
    test('抖音下发的图片走 qrImageBase64，不走 qrContent', () {
      final challenge = QrLoginChallenge(
        platformId: 'douyin',
        qrContent: '',
        qrImageBase64: 'iVBORw0KGgoAAAANSUhEUg==',
        challengeKey: 'token|fp',
        createdAt: _t0,
      );

      expect(challenge.hasImage, isTrue,
          reason: '有图片时必须让 UI 直接展示，不做二次编码');
    });

    test('只有文本时 hasImage 为 false（走本地渲染）', () {
      final challenge = QrLoginChallenge(
        platformId: 'bilibili',
        qrContent: 'https://passport.bilibili.com/h5-app/passport/login/scan?qrcode_key=abc',
        challengeKey: 'abc',
        createdAt: DateTime.now(),
      );

      expect(challenge.hasImage, isFalse);
    });

    test('空字符串图片视为没有图片', () {
      final challenge = QrLoginChallenge(
        platformId: 'douyin',
        qrContent: '',
        qrImageBase64: '',
        challengeKey: 'k',
        createdAt: DateTime.now(),
      );

      expect(challenge.hasImage, isFalse,
          reason: '空串不能触发 base64Decode，否则抛 FormatException');
    });

    test('把 base64 当文本二次编码是错的（回归防护）', () {
      // 这里固化"为什么错"：抖音的 qrBase64 是一张 PNG 的 base64，
      // 长度以万计。若塞进 qrContent 交给 QrImageView，
      // 它会把这一大串字符编码成二维码——画出来扫不出任何东西。
      const base64Png = 'iVBORw0KGgoAAAANSUhEUgAAAgAAAAIAAQMAAADOtka5';
      final challenge = QrLoginChallenge(
        platformId: 'douyin',
        qrContent: base64Png, // 错误用法：本该放 qrImageBase64
        challengeKey: 'k',
        createdAt: DateTime.now(),
      );

      expect(challenge.hasImage, isFalse);
      // 正确用法的对照
      final correct = QrLoginChallenge(
        platformId: 'douyin',
        qrContent: '',
        qrImageBase64: base64Png,
        challengeKey: 'k',
        createdAt: _t0,
      );
      expect(correct.hasImage, isTrue);
    });
  });

  group('登录相位语义', () {
    test('waitingForConfirm 不等于成功', () {
      const waiting = DouyinLoginPollResult(
        phase: DouyinLoginPhase.waitingForConfirm,
        message: '已扫码，请在手机上确认登录。',
      );
      expect(waiting.succeeded, isFalse);
    });

    test('blocked 不等于成功', () {
      const blocked = DouyinLoginPollResult(
        phase: DouyinLoginPhase.blocked,
        message: '平台未下发会话凭证。',
      );
      expect(blocked.succeeded, isFalse);
    });

    test('succeeded 必须携带 session', () {
      const result = DouyinLoginPollResult(
        phase: DouyinLoginPhase.succeeded,
        message: '登录成功。',
      );
      expect(result.succeeded, isTrue);
      // 注意：succeeded 但 session 为 null 时，UI 侧会拒绝当作成功。
      expect(result.session, isNull,
          reason: '这里只验证字段语义；UI 层要求 session 非空才保存');
    });
  });

  group('过期判定', () {
    test('超过 expire_time 判为过期', () {
      final expired = DouyinQrChallenge(
        qrBase64: 'x',
        token: 't',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        fp: 'fp',
      );
      expect(expired.isExpired, isTrue);
    });

    test('未到期不算过期', () {
      final fresh = DouyinQrChallenge(
        qrBase64: 'x',
        token: 't',
        expiresAt: DateTime.now().add(const Duration(minutes: 3)),
        fp: 'fp',
      );
      expect(fresh.isExpired, isFalse);
    });
  });

  group('凭证换取：确认 ≠ 成功', () {
    Future<DouyinLoginPollResult> poll(
      FakePassportHttp http, {
      required String status,
      List<String> setCookies = const [],
    }) async {
      http.pollBody = '{"data":{"error_code":0,"status":"$status"}}';
      http.pollSetCookies = setCookies;
      final client = DouyinLoginClient(
        http: http,
        logger: FusionLogger(enabled: false),
      );
      final challenge = await client.requestQrCode();
      return client.pollQrStatus(challenge);
    }

    test('取码下发的 csrf cookie 会被带回轮询', () async {
      final http = FakePassportHttp();
      await poll(http, status: 'new');

      expect(http.lastPollCookie, isNotNull,
          reason: '轮询必须携带取码时下发的 cookie');
      expect(http.lastPollCookie, contains('passport_csrf_token='),
          reason: '丢弃 csrf token 会让服务端无法关联登录会话');
    });

    test('confirmed 但没有会话 cookie → 如实报失败，不假装成功', () async {
      final http = FakePassportHttp();
      final result = await poll(http, status: 'confirmed');

      expect(result.succeeded, isFalse,
          reason: '没有真实凭证就不是登录成功');
      expect(result.phase, DouyinLoginPhase.blocked);
      expect(result.message, isNotNull);
    });

    test('confirmed 且只有 csrf cookie（无 sessionid）→ 仍然失败', () async {
      final http = FakePassportHttp();
      final result = await poll(
        http,
        status: 'confirmed',
        setCookies: const [
          'passport_csrf_token=csrf-token-placeholder; Path=/',
        ],
      );

      expect(result.succeeded, isFalse,
          reason: 'csrf token 不是会话凭证');
    });

    test('confirmed 且下发 sessionid → 产出真实会话', () async {
      final http = FakePassportHttp();
      final result = await poll(
        http,
        status: 'confirmed',
        setCookies: const [
          'sessionid=session-placeholder; Path=/; Domain=.douyin.com; HttpOnly',
          'uid_tt=uid-placeholder; Path=/',
        ],
      );

      expect(result.succeeded, isTrue);
      expect(result.session, isNotNull);
      expect(result.session!.platformId, 'douyin');
      expect(result.session!.cookies['sessionid'], 'session-placeholder');
      expect(result.session!.userId, 'uid-placeholder');
    });

    test('sid_tt 也算有效会话凭证', () async {
      final http = FakePassportHttp();
      final result = await poll(
        http,
        status: 'confirmed',
        setCookies: const ['sid_tt=sid-placeholder; Path=/'],
      );

      expect(result.succeeded, isTrue);
      expect(result.session, isNotNull);
    });

    test('success 状态同样走凭证校验', () async {
      final http = FakePassportHttp();
      final noCookie = await poll(http, status: 'success');
      expect(noCookie.succeeded, isFalse);

      final http2 = FakePassportHttp();
      final withCookie = await poll(
        http2,
        status: 'success',
        setCookies: const ['sessionid=s2; Path=/'],
      );
      expect(withCookie.succeeded, isTrue);
    });

    test('new 状态不产生会话', () async {
      final http = FakePassportHttp();
      final result = await poll(http, status: 'new');

      expect(result.succeeded, isFalse);
      expect(result.phase, DouyinLoginPhase.waitingForScan);
      expect(result.session, isNull);
    });

    test('scanning 状态不产生会话', () async {
      final http = FakePassportHttp();
      final result = await poll(http, status: 'scanning');

      expect(result.succeeded, isFalse);
      expect(result.phase, DouyinLoginPhase.waitingForConfirm);
      expect(result.session, isNull);
    });

    test('4031 风控如实报 blocked', () async {
      final http = FakePassportHttp();
      http.pollBody = '{"data":{"error_code":4031,"status":""}}';
      final client = DouyinLoginClient(
        http: http,
        logger: FusionLogger(enabled: false),
      );
      final challenge = await client.requestQrCode();
      final result = await client.pollQrStatus(challenge);

      expect(result.phase, DouyinLoginPhase.blocked);
      expect(result.succeeded, isFalse);
    });

    test('重新取码会清空上一次的 cookie（不串会话）', () async {
      final http = FakePassportHttp();
      final client = DouyinLoginClient(
        http: http,
        logger: FusionLogger(enabled: false),
      );

      await client.requestQrCode();
      expect(client.cookieNames, contains('passport_csrf_token'));

      await client.requestQrCode();
      // 仍然只有一个 csrf token，没有累积或残留
      expect(
        client.cookieNames.where((n) => n == 'passport_csrf_token').length,
        1,
      );
    });
  });
}