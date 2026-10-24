/// 抖音 passport 纯 HTTP 登录链路，不加载 WebView。
///
/// 顺序照 catbus `Passport.bootstrap`：页面 cookie 档案 → www 落地页 →
/// ttwid → login_guiding_strategy → get_sec_ts（读响应头）→ challenge
/// （passportiv → bit_env）→ get_client_cert + ECDH（client_data_v2）→
/// send_code / sms_login。
///
/// 关键点：`sec_ts` 在响应头里，未登录也会下发；cookie 形状不齐才是
/// 被风控判 2156 / 4031 的真正原因。每步失败都要能定位到具体环节。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '_abogus.dart';
import 'dtrait.dart';
import 'login_assets_data.dart';
import 'mssdk.dart';
import 'passport_sign.dart';
import 'sms_login.dart';
import 'ticket_guard.dart';

/// 主站与登录站。
const String kDouyinWebHost = 'https://www.douyin.com';
const String kDouyinLoginHost = 'https://login.douyin.com';

/// 登录链路使用的设备画像。固化素材与它绑定，改这里必须重抓素材。
const String kLoginUserAgent = loginAssetUserAgent;
const String _secChUa = '"Chromium";v="151", "Not=A?Brand";v="99"';
const String _secChUaPlatform = '"Windows"';
const String _referer = '$kDouyinWebHost/jingxuan';

/// passport SDK 版本参数，须与固化素材同源。
const Map<String, String> _passportSdk = {
  'passport_jssdk_version': '3.4.13-beta.4',
  'passport_jssdk_type': 'normal',
  'is_from_ttaccountsdk': '1',
};

const Map<String, String> _sdkTail = {
  'p_ui': '2.4.10',
  'p_ca': '4.0.26',
  'p_ca_real': '1.0.0.983',
  'account_sdk_source': 'web',
  'p_js_v': '3.4.13-beta.4',
  'p_js_t': 'pro',
  'p_zt': '3.3.32-beta.7',
  'p_ver': '1.1.4-beta.5',
  'p_ver_real': '0',
  'p_bd': '1.0.1.19-fix.01',
};

/// 设备几何（catbus PROFILE.geo）：inner w/h、outer w/h、avail w/h、screen w/h。
const List<int> _geo = [2560, 1215, 2560, 1392, 2560, 1392, 2560, 1440];

/// 网页端会自己写的一批 cookie（对照 `_add_page_cookies`）。
const List<String> _onlyOnWww = [
  's_v_web_id',
  '__ac_nonce',
  '__ac_signature',
  'x-web-secsdk-uid',
  'dy_swidth',
  'dy_sheight',
  'device_web_cpu_core',
  'device_web_memory_size',
  'architecture',
  'fpk1',
  'fpk2',
];

/// 短信请求的 cookie 顺序（对照 catbus `SMS_ORDER`）。
const List<String> _smsOrder = [
  'enter_pc_once',
  'UIFID_TEMP',
  'odin_tt',
  'is_support_rtm_web_ts',
  'hevc_supported',
  'IsDouyinActive',
  'home_can_add_dy_2_desktop',
  'stream_recommend_feed_params',
  'strategyABtestKey',
  'is_dash_user',
  'passport_csrf_token',
  'passport_csrf_token_default',
  'ttwid',
  'biz_trace_id',
  '__security_mc_1_s_sdk_crypt_sdk',
  'bd_ticket_guard_regenerate_keys_time',
  'bd_ticket_guard_client_data',
  'bd_ticket_guard_client_web_domain',
  'bd_ticket_guard_client_data_v2',
  'sdk_source_info',
  'bit_env',
  'gulu_source_res',
  'passport_auth_mix_state',
];

/// challenge 的 cookie 顺序（对照 `CHALLENGE_ORDER`）。
const List<String> _challengeOrder = [
  'enter_pc_once',
  'UIFID_TEMP',
  'odin_tt',
  'is_support_rtm_web_ts',
  'hevc_supported',
  'IsDouyinActive',
  'home_can_add_dy_2_desktop',
  'stream_recommend_feed_params',
  'strategyABtestKey',
  'is_dash_user',
  'passport_csrf_token',
  'passport_csrf_token_default',
  'ttwid',
  'biz_trace_id',
  '__security_mc_1_s_sdk_crypt_sdk',
  'bd_ticket_guard_regenerate_keys_time',
  'bd_ticket_guard_client_data',
  'bd_ticket_guard_client_web_domain',
];

/// 只属于历史会话、不能带进短信请求的 cookie（`SMS_HISTORICAL_ONLY`）。
const List<String> _smsHistoricalOnly = ['MONITOR_WEB_ID', 'UIFID', 'download_guide'];

/// 一次纯 HTTP 响应的最小视图（只保留登录链路用得到的部分）。
class PassportHttpResult {
  const PassportHttpResult({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.setCookies,
    required this.url,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final List<String> setCookies;
  final String url;

  Map<String, Object?>? get json {
    try {
      final v = jsonDecode(body);
      return v is Map ? Map<String, Object?>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  /// passport 系响应的错误码：`data.error_code` 优先，回退顶层。
  int? get errorCode {
    final j = json;
    final data = j?['data'];
    if (data is Map && data['error_code'] != null) {
      return (data['error_code'] as num).toInt();
    }
    return (j?['error_code'] as num?)?.toInt();
  }

  /// 面向用户的原因（`description` 优先）。
  String get errorDescription {
    final j = json;
    final data = j?['data'];
    if (data is Map) {
      final d = data['description'];
      if (d is String && d.isNotEmpty) return d;
    }
    final m = j?['message'];
    return m is String ? m : '';
  }
}

/// 抖音 passport 纯 HTTP 客户端。
///
/// 一个实例 = 一次登录会话（cookie jar 独立）。
class DouyinPassportClient {
  DouyinPassportClient({
    FusionLogger? logger,
    Random? rng,
    String userAgent = kLoginUserAgent,
  })  : _logger = logger ?? appLogger,
        _rng = rng ?? Random.secure(),
        _ua = userAgent {
    _abogus = ABogus(userAgent: userAgent);
  }

  final FusionLogger _logger;
  final Random _rng;
  final String _ua;
  late final ABogus _abogus;

  /// cookie jar（名 → 值）。顺序由各 scope 的 order 决定，不靠插入序。
  final Map<String, String> _jar = {};

  TicketGuardKeyPair? _keyPair;
  DtraitMaterial? _dtraitMaterial;
  String _secTs = '';
  String _verifyPortrait = '';
  String _sourceInfo = '';
  String _msToken = '';
  String _tSuffix = '';
  String _tCookie = '';
  String _tQuery = '';
  bool _bootstrapped = false;

  /// 诊断用：记录每一步的结果（不含凭证）。
  final List<String> steps = [];

  String? cookie(String name) => _jar[name];

  /// 当前 jar 的只读快照（登录成功后交给凭证库）。
  Map<String, String> get cookies => Map.unmodifiable(_jar);

  // ── 公开流程 ────────────────────────────────────────────────

  /// 走完 bootstrap：从零到"可以发 send_code"的状态。
  ///
  /// [strict] 为 true 时任何一步失败都抛错（短信登录必须严格）；
  /// 为 false 时只记录、继续（排查用）。
  Future<void> bootstrap({bool strict = true}) async {
    if (_bootstrapped) return;
    _prepareCookies();
    await _step(strict, 'www/bootstrap', _fetchWwwBootstrap);
    if (cookie('ttwid') == null) {
      await _step(strict, 'ttwid/register', _registerTtwid);
    }
    _jar.remove('msToken');
    _seedPageCookiesAfterBootstrap();
    // ttwid/check 是探测项：已持有有效 ttwid 时服务端不发新的，no 属正常。
    await _observe('www/ttwid/check', _checkTtwidWww);
    await _step(
      strict,
      'login_guiding_strategy',
      () async => (await _loginGuidingStrategy())?.json?['message'] == 'success',
    );
    await _step(strict, 'get_sec_ts', () async {
      await _getSecTs();
      return true;
    });
    await _observe('ttwid/check', _checkTtwidLogin);
    _jar.remove('bd_ticket_guard_client_data_v2');
    await _step(
      strict,
      'challenge',
      () async => (await _challenge())?.json?['message'] == 'success',
    );
    if (strict && (cookie('bit_env') ?? '').isEmpty) {
      throw _risk('challenge 没有下发 passportiv，无法生成 bit_env');
    }
    await _step(strict, 'client_data_v2', _addClientDataV2);
    _bootstrapped = true;
  }

  /// 诊断用：暴露 login_guiding_strategy 的完整响应。
  ///
  /// 服务端在这个响应里说明"该账号可用哪些登录方式"，但正式流程
  /// 只看 `message=='success'`，内容被丢掉了。排查风控时要能看到它。
  @visibleForTesting
  Future<PassportHttpResult?> debugLoginGuidingStrategy() =>
      _loginGuidingStrategy();

  /// 诊断用：用指定 aid 发一次验证码。
  ///
  /// 不同 aid 对应不同 passport 服务与风控阈值，可用于判断
  /// "是这个 aid 被拦"还是"这个账号被拦"。
  @visibleForTesting
  Future<PassportHttpResult> debugSendCodeWithAid(
    String phone,
    String aid,
  ) async {
    await bootstrap();
    final data = <(String, String)>[
      ('is6Digits', '1'),
      ('mix_mode', '1'),
      ('mobile', passportEncrypt(formatPassportPhone(phone))),
      ('type', '3731'),
      ('fixed_mix_mode', '1'),
    ];
    final p = _sdkParams(
      extra: const {'is_from_iesaccountsaas': '1'},
      data: data,
      deviceFp: true,
    );
    p['aid'] = aid;
    p['a_bogus'] = _abogusFor(p, host: 'login.douyin.com', body: spliceUrl(data));
    return _send(
      'POST',
      '$kDouyinLoginHost/passport/web/send_code/',
      headers: {
        'web-sdk-version': '1',
        'x-tt-session-dtrait': _dtrait('/passport/web/send_code/'),
        'referer': _referer,
        'x-tt-passport-aid-sign': aidSign('/passport/web/send_code/', '${sdkTsSeconds()}'),
        'x-tt-passport-csrf-token': _csrf,
        'x-tt-passport-trace-id': cookie('biz_trace_id') ?? '',
        'accept': 'application/json, text/javascript',
        'content-type': 'application/x-www-form-urlencoded',
        'x-tt-passport-verify-portrait': _verifyPortrait,
        'origin': kDouyinWebHost,
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-site',
      },
      query: p,
      body: urlEncodePairs(data),
      cookieOrder: _smsOrder,
      historicalOnly: _smsHistoricalOnly,
    );
  }

  /// 发送短信验证码。
  Future<void> sendSmsCode(String phone) async {
    final err = validatePhone(phone);
    if (err != null) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: err,
        technicalMessage: 'invalid phone',
        platformId: 'douyin',
      );
    }
    await bootstrap();
    final res = await _smsPost(
      '/passport/web/send_code/',
      [
        ('is6Digits', '1'),
        ('mix_mode', '1'),
        ('mobile', passportEncrypt(formatPassportPhone(phone))),
        ('type', '3731'),
        ('fixed_mix_mode', '1'),
      ],
      'sms',
    );
    _logger.info('douyin passport: send_code', {
      'status': res.statusCode,
      'code': res.errorCode ?? 'absent',
      'desc': res.errorDescription,
    });
    if ((res.errorCode ?? 0) != 0) {
      _captureChallengeShape(res);
      throw _smsError(res);
    }
  }

  /// 提交验证码完成登录；成功时返回会话 cookie 快照。
  Future<Map<String, String>> submitSmsCode(String phone, String code) async {
    final err = validateSmsCode(code);
    if (err != null) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: err,
        technicalMessage: 'invalid sms code',
        platformId: 'douyin',
      );
    }
    await bootstrap();
    final res = await _smsPost(
      '/passport/web/sms_login/',
      [
        ('service', kDouyinWebHost),
        ('mix_mode', '1'),
        ('mobile', passportEncrypt(formatPassportPhone(phone))),
        ('code', passportEncrypt(code.trim())),
        ('fixed_mix_mode', '1'),
      ],
      'sms_login',
    );
    _logger.info('douyin passport: sms_login', {
      'status': res.statusCode,
      'code': res.errorCode ?? 'absent',
      'desc': res.errorDescription,
    });
    if ((res.errorCode ?? 0) != 0) {
      _captureChallengeShape(res);
      throw _smsError(res);
    }
    if (!_jar.keys.any(_sessionMarkers.contains)) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '登录接口已返回成功，但未拿到会话凭证。',
        technicalMessage: 'sms_login code=0 but no session cookie '
            '(jar has ${_jar.length} cookies)',
        platformId: 'douyin',
      );
    }
    return cookies;
  }

  static const _sessionMarkers = ['sessionid', 'sid_guard', 'sessionid_ss'];

  // ── 各步骤 ──────────────────────────────────────────────────

  /// 页面 cookie 档案（对照 `addPageCookies` + `prepareAuthCookies`）。
  void _prepareCookies() {
    final now = DateTime.now();
    final keyPair = generateTicketGuardKeyPair();
    _keyPair = keyPair;

    void seed(String k, String v) => _jar.putIfAbsent(k, () => v);

    seed('enter_pc_once', '1');
    seed('is_support_rtm_web_ts', '1');
    seed('hevc_supported', 'true');
    seed('IsDouyinActive', 'true');
    seed('is_dash_user', '1');
    seed('home_can_add_dy_2_desktop', '"0"');
    seed('strategyABtestKey', '"${now.millisecondsSinceEpoch / 1000}"');
    seed('dy_swidth', '2560');
    seed('dy_sheight', '1440');
    seed('device_web_cpu_core', '20');
    seed('device_web_memory_size', '32');
    seed('architecture', 'amd64');
    seed('x-web-secsdk-uid', _uuid4());
    seed(
      'stream_recommend_feed_params',
      jsonEncode('{"cookie_enabled":true,"screen_width":2560,'
          '"screen_height":1440,"browser_online":true,"cpu_core_num":20,'
          '"device_memory":32,"downlink":10,"effective_type":"4g",'
          '"round_trip_time":0}'),
    );
    seed('__security_mc_1_s_sdk_crypt_sdk',
        '${randomHex(_rng, 4)}-${randomHex(_rng, 2)}-${randomHex(_rng, 2)}');
    seed('bd_ticket_guard_regenerate_keys_time',
        shanghaiTime(now, 'keys'));
    seed('fpk2', md5Hex(_ua));
    seed('fpk1', fpk1B64);
    seed('passport_auth_mix_state', mixState(32, _rng));
    seed(
      'gulu_source_res',
      base64Encode(utf8.encode('{"p_in":"${randomHex(_rng, 32)}"}')),
    );
    seed(
      'sdk_source_info',
      passportEncrypt(jsonEncode(_probe(_browserT('cookie')))),
    );

    // 新鲜登录态的前置状态（服务端只校验存在性）
    seed('__security_server_data_status', '1');
    seed('__security_mc_1_s_sdk_cert_key',
        _uuid4().replaceAll('-', '').substring(0, 18));
    seed('__security_mc_1_s_sdk_sign_data_key_web_protect',
        _uuid4().replaceAll('-', '').substring(0, 18));
    seed('_bd_ticket_crypt_domain', '2');
    seed('csrf_session_id', randomHex(_rng, 16));
    seed('SEARCH_RESULT_LIST_TYPE', '"single"');
    seed('live_use_vvc', '"false"');
    seed('publish_badge_show_info', '0,0,0,0');

    // ticket guard：客户端自己生成的 P-256 公钥
    _jar['bd_ticket_guard_client_data'] = keyPair.clientDataCookie;
    _jar['bd_ticket_guard_client_web_domain'] = '2';

    _verifyPortrait = '${_uuid4()}.login';
  }

  /// bootstrap 之后补齐的页面 cookie（s_v_web_id / biz_trace_id 等）。
  void _seedPageCookiesAfterBootstrap() {
    _jar.putIfAbsent('s_v_web_id', () => newSvWebId(DateTime.now(), _rng));
    _jar.putIfAbsent('biz_trace_id', () => newBizTraceId(_rng));
    _jar.putIfAbsent('__ac_nonce', () => randomHex(_rng, 10));
  }

  Future<bool> _fetchWwwBootstrap() async {
    final res = await _send(
      'GET',
      '$kDouyinWebHost/?recommend=1',
      headers: {
        'upgrade-insecure-requests': '1',
        'sec-ch-ua': _secChUa,
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': _secChUaPlatform,
        'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,'
            'image/avif,image/webp,image/apng,*/*;q=0.8',
        'referer': '$kDouyinWebHost/?recommend=1',
        'priority': 'u=0, i',
        'sec-fetch-dest': 'document',
        'sec-fetch-mode': 'navigate',
        'sec-fetch-site': 'none',
      },
      cookieOrder: null,
    );
    return res.statusCode == 200;
  }

  Future<bool> _registerTtwid() async {
    final res = await _send(
      'POST',
      'https://ttwid.bytedance.com/ttwid/union/register/',
      headers: {
        'content-type': 'application/json',
        'accept': '*/*',
      },
      body: jsonEncode({
        'region': 'cn',
        'aid': 1768,
        'needFid': false,
        'service': 'www.douyin.com',
        'migrate_info': {'ticket': '', 'source': 'node'},
        'cbUrlProtocol': 'https',
        'union': true,
      }),
      cookieOrder: null,
    );
    return (cookie('ttwid') ?? '').isNotEmpty || res.statusCode == 200;
  }

  Future<bool> _checkTtwidWww() => _ttwidCheck(
        '$kDouyinWebHost/ttwid/check/',
        '$kDouyinWebHost/jingxuan',
        'same-origin',
        extra: const {'x-secsdk-csrf-token': 'DOWNGRADE'},
      );

  Future<bool> _checkTtwidLogin() => _ttwidCheck(
        '$kDouyinLoginHost/ttwid/check/',
        '$kDouyinWebHost/',
        'same-site',
      );

  Future<bool> _ttwidCheck(
    String url,
    String referer,
    String site, {
    Map<String, String> extra = const {},
  }) async {
    final res = await _send(
      'POST',
      url,
      headers: {
        'referer': referer,
        'accept': 'application/json, text/plain, */*',
        ...extra,
        'content-type': 'application/json',
        'origin': kDouyinWebHost,
        'priority': 'u=1, i',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': site,
      },
      body: '{"aid":6383,"service":"www.douyin.com"}',
    );
    return res.setCookies.any((c) => c.startsWith('ttwid='));
  }

  Future<PassportHttpResult?> _loginGuidingStrategy() async {
    const path = '/passport/general/login_guiding_strategy/';
    await _ensureMsToken();
    final p = _sdkParams(pUi: false);
    p['a_bogus'] = _abogusFor(p, host: 'www.douyin.com');
    final res = await _send(
      'GET',
      '$kDouyinWebHost$path',
      headers: {
        'x-tt-passport-csrf-token': _csrf,
        'referer': _referer,
        'accept': 'application/json, text/javascript',
        'x-tt-passport-aid-sign': aidSign(path, '${sdkTsSeconds()}'),
        'x-tt-passport-trace-id': cookie('biz_trace_id') ?? '',
        'origin': kDouyinWebHost,
        'priority': 'u=1, i',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
      },
      query: p,
      cookieOrder: _challengeOrder,
    );
    _raiseIfBlocked('login_guiding_strategy/', res);
    return res;
  }

  /// `get_sec_ts`：`sec_ts` 在**响应头**里。
  Future<void> _getSecTs() async {
    final query = <String, String>{
      'aid': '6383',
      'is_from_ttaccountsdk': '1',
      'msToken': await _ensureMsToken(),
    };
    query['a_bogus'] = _abogusOver(query, host: 'www.douyin.com');
    final res = await _send(
      'POST',
      '$kDouyinWebHost/passport/user_info/get_sec_ts/',
      headers: {
        'referer': '$kDouyinWebHost/user/self',
        'accept': 'application/json',
        'x-secsdk-csrf-token': 'DOWNGRADE',
        'content-type': 'application/x-www-form-urlencoded',
        'origin': kDouyinWebHost,
        'priority': 'u=1, i',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
      },
      query: query,
      body: 'aid=6383&is_from_ttaccountsdk=1',
      cookieOrder: _challengeOrder,
    );
    final secTs = res.headers['bd-ticket-guard-sec-ts'];
    if (secTs == null || secTs.isEmpty) {
      throw _risk('get_sec_ts 未在响应头下发 bd-ticket-guard-sec-ts'
          '（HTTP ${res.statusCode}，body=${_short(res.body)}）');
    }
    _secTs = secTs;
  }

  /// challenge：下发 `passportiv`（→ bit_env）与 `template`。
  ///
  /// `template` 是混淆 JS，Dart 执行不了；不执行它，`gulu_source_res` /
  /// `sdk_source_info` 已按页面默认值落地，诊断里如实标注。
  Future<PassportHttpResult?> _challenge() async {
    const path = '/passport/web/challenge/';
    final body = 'sign=$challengeSignB64&sk=$challengeSkHex';
    final data = <(String, String)>[
      ('sign', challengeSignB64),
      ('sk', challengeSkHex),
    ];
    await _ensureMsToken();
    final p = _sdkParams(
      extra: const {'request_host': kDouyinWebHost, 'skip_c': '1'},
      data: data,
      deviceFp: true,
      pUi: false,
      requestHost: false,
    );
    p['a_bogus'] = _abogusFor(p, host: 'login.douyin.com', body: spliceUrl(data));

    final res = await _send(
      'POST',
      '$kDouyinLoginHost$path',
      headers: {
        'web-sdk-version': '1',
        'sec-ch-ua-platform': _secChUaPlatform,
        'x-tt-session-dtrait': _dtrait(path),
        'referer': _referer,
        'sec-ch-ua': _secChUa,
        'x-tt-passport-aid-sign': aidSign(path, '${sdkTsSeconds()}'),
        'sec-ch-ua-mobile': '?0',
        'x-tt-passport-csrf-token': _csrf,
        'x-tt-passport-trace-id': cookie('biz_trace_id') ?? '',
        'accept': 'application/json, text/javascript',
        'content-type': 'application/x-www-form-urlencoded',
        'x-tt-passport-verify-portrait': _verifyPortrait,
        'origin': kDouyinWebHost,
        'priority': 'u=1, i',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-site',
      },
      query: p,
      body: body,
      cookieOrder: _challengeOrder,
    );

    final iv = (res.json?['data'] as Map?)?['passportiv'];
    if (iv is String && iv.isNotEmpty) {
      _jar['bit_env'] = uaAesUrlsafe(iv, userAgent: _ua);
    }
    final tpl = (res.json?['data'] as Map?)?['template'];
    if (tpl is String && tpl.isNotEmpty) {
      steps.add('challenge: 收到 template（${tpl.length} 字符，未执行：纯 Dart 无 JS 引擎）');
    }
    final secTs = res.headers['bd-ticket-guard-sec-ts'];
    if (secTs != null && secTs.isNotEmpty) _secTs = secTs;
    return res;
  }

  /// `bd_ticket_guard_client_data_v2`（ECDH + HKDF + HMAC）。
  Future<bool> _addClientDataV2() async {
    if (_secTs.isEmpty) return false;
    final keyPair = _keyPair;
    if (keyPair == null) return false;

    final cert = await _serverCert();
    if (cert == null) return false;
    _jar['bd_ticket_guard_client_data_v2'] = keyPair.clientDataV2Cookie(
      serverCertPoint: cert,
      secTs: _secTs,
    );
    return true;
  }

  Future<Uint8List?> _serverCert() async {
    const path = '/passport/ticket_guard/get_client_cert/';
    final query = <String, String>{
      'aid': '6383',
      'is_from_ttaccountsdk': '1',
      'msToken': await _ensureMsToken(),
    };
    query['a_bogus'] = _abogusOver(query, host: 'www.douyin.com');
    final res = await _send(
      'POST',
      '$kDouyinWebHost$path',
      headers: {
        'x-tt-session-dtrait': _dtrait(path),
        'referer': '$kDouyinWebHost/',
        'x-tt-passport-aid-sign': aidSign(path, '${sdkTsSeconds()}'),
        'accept': 'application/json',
        'x-secsdk-csrf-token': 'DOWNGRADE',
        'content-type': 'application/x-www-form-urlencoded',
        'origin': kDouyinWebHost,
        'priority': 'u=1, i',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
      },
      query: query,
      body: 'server_data=1&aid=6383',
      cookieOrder: _challengeOrder,
    );
    final pem = ((res.json?['data'] as Map?)?['server_cert']);
    if (pem is! String || pem.isEmpty) {
      steps.add('get_client_cert: 未拿到 server_cert（HTTP ${res.statusCode}）');
      return null;
    }
    return extractEcPoint(pem);
  }

  /// `send_code` / `sms_login` 共用：完整 query + a_bogus + dtrait + cookie。
  Future<PassportHttpResult> _smsPost(
    String path,
    List<(String, String)> data,
    String scope,
  ) async {
    await _ensureMsToken();
    final p = _sdkParams(
      extra: const {'is_from_iesaccountsaas': '1'},
      data: data,
      deviceFp: true,
    );
    // body 必须签**实际发出的那份**参数序列（catbus `spliceUrl(data)`）。
    p['a_bogus'] = _abogusFor(p, host: 'login.douyin.com', body: spliceUrl(data));
    final body = urlEncodePairs(data);
    final res = await _send(
      'POST',
      '$kDouyinLoginHost$path',
      headers: {
        'web-sdk-version': '1',
        'x-tt-session-dtrait': _dtrait(path),
        'referer': _referer,
        'x-tt-passport-aid-sign': aidSign(path, '${sdkTsSeconds()}'),
        'x-tt-passport-csrf-token': _csrf,
        'x-tt-passport-trace-id': cookie('biz_trace_id') ?? '',
        'accept': 'application/json, text/javascript',
        'content-type': 'application/x-www-form-urlencoded',
        'x-tt-passport-verify-portrait': _verifyPortrait,
        'accept-language': 'zh-CN,zh;q=0.9',
        'origin': kDouyinWebHost,
        'priority': 'u=1, i',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-site',
      },
      query: p,
      body: body,
      cookieOrder: _smsOrder,
      historicalOnly: _smsHistoricalOnly,
    );
    return res;
  }

  // ── 参数 / 签名 ─────────────────────────────────────────────

  /// 登录接口的公共 query（对照 `_sdk_params`）。
  ///
  /// 顺序有意义：`sign` 取**键名排序后前 10 个**，所以键集合必须稳定。
  Map<String, String> _sdkParams({
    Map<String, String> extra = const {},
    List<(String, String)> data = const [],
    bool deviceFp = false,
    bool pUi = true,
    bool requestHost = true,
  }) {
    final p = <String, String>{
      ..._passportSdk,
      'aid': '6383',
      'language': 'zh',
      'account_app_language': 'zh-CN',
      'ts': '${sdkTsSeconds()}',
      ...extra,
    };
    if (pUi) p['p_ui'] = _sdkTail['p_ui']!;
    if (deviceFp) {
      final fp = cookie('s_v_web_id') ?? newSvWebId(DateTime.now(), _rng);
      _jar['s_v_web_id'] = fp;
      p['p_ca'] = _sdkTail['p_ca']!;
      p['p_ca_real'] = _sdkTail['p_ca_real']!;
      p['fp'] = fp;
      p['verifyFp'] = fp;
    }
    p['account_sdk_source'] = _sdkTail['account_sdk_source']!;
    p['account_sdk_source_info'] = _sdkSourceInfo();
    for (final k in const ['p_js_v', 'p_js_t', 'p_zt', 'p_ver', 'p_ver_real']) {
      p[k] = _sdkTail[k]!;
    }
    if (requestHost) p['request_host'] = kDouyinWebHost;
    p['p_bd'] = _sdkTail['p_bd']!;
    p['p_ts'] = '${DateTime.now().millisecondsSinceEpoch}';
    p['p_no'] = randomHex(_rng, 32);
    p['biz_trace_id'] = cookie('biz_trace_id') ?? newBizTraceId(_rng);
    p['device_platform'] = 'web_app';

    final signed = passportSign(p.entries.map((e) => (e.key, e.value)).toList(), data);
    p['sign'] = signed.sign;
    p['qs'] = signed.qs;
    p['msToken'] = _msToken.isEmpty ? _syncMsTokenOrEmpty() : _msToken;
    return p;
  }

  /// `a_bogus` 覆盖 query（含 body 为空）+ 指定 host。
  String _abogusFor(
    Map<String, String> params, {
    required String host,
    String body = '',
  }) {
    final query = spliceUrl(
      params.entries
          .where((e) => e.key != 'a_bogus')
          .map((e) => (e.key, e.value)),
    );
    return _abogus.getValue(query, body: body, host: host);
  }

  /// 已经是完整 `k=v&...`（自身按顺序拼好）的签名入口。
  String _abogusOver(Map<String, String> params, {required String host}) =>
      _abogus.getValue(urlEncodePairs(params.entries.map((e) => (e.key, e.value))),
          host: host);

  /// `account_sdk_source_info`：会话内固定（对照 `sdkSourceInfo`）。
  String _sdkSourceInfo() {
    if (_sourceInfo.isNotEmpty) return _sourceInfo;
    final timeOrigin = (DateTime.now().millisecondsSinceEpoch -
            _rng.nextInt(57000) -
            3000) /
        1000.0;
    final info = <String, Object?>{
      'hardwareConcurrency': 20,
      'webdriver': false,
      'chromedriver': false,
      'shelldriver': false,
      'plugins': 5,
      'innerHeight': _geo[1],
      'innerWidth': _geo[0],
      'outerHeight': _geo[3],
      'outerWidth': _geo[2],
      'webgl': {
        'vendor': 'Google Inc. (NVIDIA)',
        'renderer': 'ANGLE (NVIDIA, NVIDIA GeForce RTX 5060 Ti (0x00002D04) '
            'Direct3D11 vs_5_0 ps_5_0, D3D11)',
      },
      'automation': {
        's': '00000000',
        'c': '0000',
        'p': '0000000',
        's1': '00000000',
        'c1': '0000',
        'p1': '0',
      },
      'performance': {
        'timeOrigin': '__TIME_ORIGIN__',
        'usedJSHeapSize': 472537551,
        'navigationTiming': {
          'decodedBodySize': 968454,
          'entryType': 'navigation',
          'initiatorType': 'navigation',
          'name': '$kDouyinWebHost/?recommend=1',
          'renderBlockingStatus': 'non-blocking',
          'serverTiming': 'cdn-cache,edge,origin,inner,tt_agw',
          'guleStart': 610.8999999761581,
          'guleDuration': 'none',
        },
      },
      'browser': {
        't': _browserT('query'),
        'bit_protocol': 'false',
        'bit_helper': false,
      },
    };
    final raw = jsonEncode(info).replaceFirst('"__TIME_ORIGIN__"', '$timeOrigin');
    _sourceInfo = passportEncrypt(raw);
    return _sourceInfo;
  }

  /// 反自动化探针默认值（键名与拼写照实录）。
  Map<String, String> _probe(String t) => {
        'automa_ele': 'false',
        'bit_helper': 'false',
        'chrome_extension_script': '[]',
        'console_lied': 'false',
        'global_variables': '[]',
        'swt_alt': 'false',
        'zn_cap': 'false',
        'hok_noti': 'false',
        'inj_zfb': 'false',
        't': t,
        'bit_protocol': 'false',
      };

  /// 页面随机量：9 位会话后缀共用，4 位前缀按 cookie / query 分开。
  String _browserT(String role) {
    if (_tSuffix.isEmpty) {
      _tSuffix = _rng.nextInt(1000000000).toString().padLeft(9, '0');
    }
    String make() => _rng.nextInt(10000).toString().padLeft(4, '0') + _tSuffix;
    if (role == 'cookie') return _tCookie.isEmpty ? _tCookie = make() : _tCookie;
    return _tQuery.isEmpty ? _tQuery = make() : _tQuery;
  }

  String _dtrait(String path) {
    final built = buildSessionDtrait(path, material: _dtraitMaterial);
    _dtraitMaterial = built.material;
    return built.header;
  }

  String get _csrf =>
      cookie('passport_csrf_token') ??
      cookie('passport_csrf_token_default') ??
      '';

  /// msToken：先尝试 /web/common 上报换新，失败沿用旧值。
  Future<String> _ensureMsToken() async {
    if (_msToken.isNotEmpty) return _msToken;
    final token = await _refreshMsToken();
    if (token.isNotEmpty) {
      _msToken = token;
      _jar['msToken'] = token;
    }
    return _msToken;
  }

  String _syncMsTokenOrEmpty() => cookie('msToken') ?? '';

  Future<String> _refreshMsToken() async {
    try {
      final req = prepareMsTokenRequest(current: _msToken);
      final res = await _send(
        'POST',
        req.url,
        headers: req.headers,
        body: req.body,
        cookieOrder: null,
      );
      final token = msTokenFromHeaderValues(
        res.headers['x-ms-token'],
        res.setCookies,
      );
      _logger.info('douyin passport: msToken', {
        'status': res.statusCode,
        'len': token.length,
      });
      return token;
    } catch (e) {
      steps.add('msToken: /web/common 失败（$e），沿用 cookie 里的值');
      return cookie('msToken') ?? '';
    }
  }

  // ── HTTP ───────────────────────────────────────────────────

  /// 发一次请求，吸收 Set-Cookie。
  ///
  /// [cookieOrder] 为 null 表示不带 cookie（首次落地页 / 第三方域）。
  Future<PassportHttpResult> _send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    Map<String, String>? query,
    String? body,
    List<String>? cookieOrder,
    List<String> historicalOnly = const [],
  }) async {
    final startedAt = DateTime.now();
    var target = url;
    if (query != null && query.isNotEmpty) {
      target = '$url?${urlEncodePairs(query.entries.map((e) => (e.key, e.value)))}';
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    client.userAgent = null; // 用自己设的头，避免 dart:io 追加第二份
    // dart:io **不读** http_proxy 环境变量（Node / Chrome 会读）。
    // 桌面/CI 里常常只能经代理出网，这里显式接上；没有代理变量时
    // findProxyFromEnvironment 返回 DIRECT，对真机无副作用。
    client.findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);
    try {
      final req = await client
          .openUrl(method, Uri.parse(target))
          .timeout(const Duration(seconds: 20));
      final h = <String, String>{
        'user-agent': _ua,
        'accept-language': 'zh-CN,zh;q=0.9',
        ...headers,
      };
      if (cookieOrder != null) {
        final c = _cookieHeader(cookieOrder, historicalOnly: historicalOnly);
        if (c.isNotEmpty) h['cookie'] = c;
      }
      h.forEach(req.headers.set);
      req.followRedirects = false;
      if (body != null) req.add(utf8.encode(body));

      final resp = await req.close().timeout(const Duration(seconds: 25));
      final text = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 25), onTimeout: () => '');

      final respHeaders = <String, String>{};
      resp.headers.forEach((name, values) {
        respHeaders[name.toLowerCase()] = values.join(', ');
      });
      final setCookies = resp.headers['set-cookie'] ?? const <String>[];

      _mergeSetCookies(setCookies);

      _logger.http(
        method: method,
        url: target,
        status: resp.statusCode,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      );

      return PassportHttpResult(
        statusCode: resp.statusCode,
        body: text,
        headers: respHeaders,
        setCookies: setCookies,
        url: target,
      );
    } on TimeoutException {
      throw FusionException(
        code: FusionErrorCode.timeout,
        userMessage: '请求超时，请重试。',
        technicalMessage: 'timeout @ ${Redactor.safeUrl(target)}',
        platformId: 'douyin',
        retryable: true,
      );
    } on SocketException catch (e) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '网络请求失败，请检查网络后重试。',
        technicalMessage: 'SocketException(${e.osError?.errorCode}) '
            '@ ${Redactor.safeUrl(target)}',
        platformId: 'douyin',
        retryable: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  void _mergeSetCookies(List<String> setCookies) {
    for (final raw in setCookies) {
      final pair = raw.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      if (value.isEmpty) {
        _jar.remove(name);
      } else {
        _jar[name] = value;
      }
    }
  }

  /// 按 scope 顺序拼 cookie 头（对照 `scoped` + `cookieHeader`）。
  String _cookieHeader(List<String> order, {List<String> historicalOnly = const []}) {
    final out = <String>[];
    final used = <String>{};
    for (final name in order) {
      final v = _jar[name];
      if (v == null || v.isEmpty) continue;
      out.add('$name=$v');
      used.add(name);
    }
    for (final entry in _jar.entries) {
      if (used.contains(entry.key) || entry.value.isEmpty) continue;
      if (historicalOnly.contains(entry.key)) continue;
      if (_onlyOnWww.contains(entry.key)) continue;
      if (entry.key == 'my_rd') continue;
      out.add('${entry.key}=${entry.value}');
    }
    return out.join('; ');
  }

  // ── 错误 ───────────────────────────────────────────────────

  Future<void> _step(
    bool strict,
    String name,
    Future<bool> Function() fn,
  ) async {
    var ok = false;
    try {
      ok = await fn();
      steps.add('$name: ${ok ? "ok" : "no"}');
    } catch (e) {
      steps.add('$name: 失败（$e）');
      if (strict) rethrow;
      return;
    }
    if (!ok) {
      if (strict) throw _risk('登录 bootstrap 的 $name 没有成功');
    }
  }

  /// 只记录结果、绝不抛错的诊断步骤（探测类接口用）。
  Future<void> _observe(String name, Future<bool> Function() fn) async {
    try {
      final ok = await fn();
      steps.add('$name: ${ok ? "ok" : "no"}（探测项，不作为失败依据）');
    } catch (e) {
      steps.add('$name: 失败（$e）（探测项，不作为失败依据）');
    }
  }

  void _raiseIfBlocked(String api, PassportHttpResult res) {
    final code = res.errorCode;
    if (code == null || code == 0) return;
    if (code == 4031) {
      throw _risk('$api 返回 4031「网站存在安全风险」'
          '：${res.errorDescription}');
    }
    if (code == 7) {
      throw FusionException(
        code: FusionErrorCode.rateLimited,
        userMessage: '$api 访问太频繁，请稍后再试。',
        technicalMessage: '$api error_code=7',
        upstreamCode: code,
        platformId: 'douyin',
      );
    }
    throw FusionException(
      code: FusionErrorCode.upstreamError,
      userMessage: res.errorDescription.isEmpty
          ? '$api 失败（错误码 $code）。'
          : res.errorDescription,
      technicalMessage: '$api error_code=$code ${res.errorDescription}',
      upstreamCode: code,
      platformId: 'douyin',
    );
  }

  FusionException _risk(String message) => FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音风控拦截了本次登录，请稍后重试。',
        technicalMessage: message,
        platformId: 'douyin',
        retryable: true,
      );

  FusionException _smsError(PassportHttpResult res) {
    final code = res.errorCode ?? -1;
    final desc = res.errorDescription;
    // 1203 = 验证码错误/过期，属于正常业务失败，不是风控。
    // 判据要盯"人机验证/滑块/captcha"，不能用宽泛的「验证」二字。
    if (code == 1203 || code == 1204) {
      return FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '验证码不正确或已过期，请重新获取。',
        technicalMessage: 'sms code rejected: code=$code desc=$desc',
        upstreamCode: code,
        platformId: 'douyin',
      );
    }
    final captcha = const [1105, 1104, 1107, 2046].contains(code) ||
        desc.contains('人机') ||
        desc.contains('滑块') ||
        desc.toLowerCase().contains('captcha');
    if (captcha) {
      // 区分两种"要验证"：能在网页里做的滑块，与只能去官方 APP 做的。
      // 后者客户端无论如何都代不了，文案必须直接告诉用户换路。
      final mustUseApp = desc.contains('APP') ||
          desc.contains('app') ||
          desc.contains('抖音客户端') ||
          desc.contains('账号安全');
      return FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: mustUseApp
            ? '抖音要求先在官方 APP 里完成账号安全验证。'
                '完成后回来重试，或改用「扫码登录」。'
            : '需要人机验证：${desc.isEmpty ? code : desc}',
        technicalMessage: 'sms captcha required: code=$code desc=$desc '
            'mustUseApp=$mustUseApp challenge=$_smsChallengeShape',
        upstreamCode: code,
        platformId: 'douyin',
        retryable: true,
      );
    }
    return FusionException(
      code: FusionErrorCode.upstreamError,
      userMessage: desc.isEmpty ? '短信登录失败（错误码 $code）。' : desc,
      technicalMessage: 'sms error code=$code desc=$desc',
      upstreamCode: code,
      platformId: 'douyin',
    );
  }

  /// 需要人机验证时，服务端下发的挑战形态（只记字段名与类型，不记取值）。
  ///
  /// 决定后续怎么做：
  ///  - 有 `captcha` / `challenge_code` → 网页滑块，理论上可在 WebView 完成；
  ///  - 只有 `mobile_verify_type` / 无挑战字段 → 服务端指定去官方 APP 验证，
  ///    客户端无从代做，如实告知用户。
  static const List<String> _smsChallengeFields = [
    'captcha',
    'captcha_version',
    'challenge_code',
    'verify_url',
    'desc_url',
    'mobile_verify_type',
    'user_verify_type',
    'verify_type',
    'sliding_token',
    'rush_rule',
  ];

  String get _smsChallengeShape => _lastChallengeShape;
  String _lastChallengeShape = 'unknown';

  /// 记录一次响应的挑战字段形态。
  void _captureChallengeShape(PassportHttpResult res) {
    final data = res.json?['data'];
    if (data is! Map) {
      _lastChallengeShape = 'no-data';
      return;
    }
    final found = <String>[];
    for (final f in _smsChallengeFields) {
      final v = data[f];
      if (v == null) continue;
      found.add(v is String ? '$f(str:${v.length})' : '$f(${v.runtimeType})');
    }
    _lastChallengeShape = found.isEmpty
        ? 'none-of:${_smsChallengeFields.join("|")}'
        : found.join(',');
    steps.add('challenge shape: $_lastChallengeShape');
  }

  String _uuid4() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }

  static String _short(String s) => s.length > 200 ? s.substring(0, 200) : s;
}

/// 从 X.509 PEM 里取 EC 公钥点 `0x04 || X || Y`（65 字节）。
///
/// P-256 未压缩点在 DER 里形态固定：`03 42 00 04 || X(32) || Y(32)`。
/// 手写四字节匹配即可，不必为此引入完整 ASN.1 解析。取不到返回 null。
Uint8List? extractEcPoint(String pem) {
  try {
    final body = pem
        .replaceAll(RegExp(r'-----[^-]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    final der = base64Decode(body);
    for (var i = 0; i + 68 <= der.length; i++) {
      if (der[i] == 0x03 && der[i + 1] == 0x42 && der[i + 2] == 0x00 &&
          der[i + 3] == 0x04) {
        return Uint8List.sublistView(der, i, i + 68).sublist(3);
      }
    }
  } catch (_) {
    // 落到 return null
  }
  return null;
}
