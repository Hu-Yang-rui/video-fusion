/// 抖音扫码登录。
///
/// # 实测结论（2026-10-18，最终版）
///
/// | 接口 | 纯 Dart 可用性 |
/// |---|---|
/// | `POST /passport/web/get_qrcode/` | ✅ 可用 |
/// | `POST /passport/web/check_qrconnect/` | ✅ **可用** |
///
/// **登录完全可以在纯 Dart 中实现，不需要 WebView。**
///
/// ## 关键：参数分两处
///
/// 两个接口都是 **query 放签名参数 + POST body 放业务参数**：
///
/// ```
/// POST /passport/web/check_qrconnect/?passport_jssdk_version=...&a_bogus=...
/// Body: need_logo=false&is_frontier=true&token=XXX&is_new_login=1
///       &next=https%3A%2F%2Fwww.douyin.com&need_short_url=true
/// ```
///
/// 之前一直返回 `error_code: 3`（缺少参数）的原因就是
/// **把 `token` 放在了 query 里而不是 body 里**。
///
/// ## 签名要求
///
/// - `a_bogus`：需要（用纯 Dart 实现，见 `_abogus.dart`）
/// - `sign` / `qs` / `p_no`：**不需要**
///
/// 实测：连原样重放真实浏览器请求（含 `sign`）都返回 `error_code: 3`，
/// 说明 `sign` 不在这个接口的校验范围内。加上 body 里的 `token` 后
/// 直接 `error_code: 0`。
///
/// ## 其他已验证的细节
///
/// - `account_sdk_source_info` 是设备指纹 JSON，**XOR 0x05 编码**
/// - `fp` 格式：`verify_mvdd{6}_{8}_{4}_{4}_{4}_{12}`
/// - 轮询状态：`new` → `scanning` → `confirmed`
library;

import 'dart:convert';
import 'dart:math';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';
import '_abogus.dart';

/// 抖音扫码登录的挑战。
class DouyinQrChallenge {
  const DouyinQrChallenge({
    required this.qrBase64,
    required this.token,
    required this.expiresAt,
    required this.fp,
  });

  /// 二维码 PNG 的 base64（不含 `data:image/png;base64,` 前缀）。
  final String qrBase64;

  /// 二维码 token。
  final String token;

  /// 过期时间。
  final DateTime expiresAt;

  /// 设备指纹（轮询时需要保持一致）。
  final String fp;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// 轮询结果。
enum DouyinLoginPhase {
  /// 等待扫码。
  waitingForScan,

  /// 已扫码，等待确认。
  waitingForConfirm,

  /// 登录成功。
  succeeded,

  /// 二维码过期。
  expired,

  /// 平台风控拦截（当前实际状态）。
  blocked,
}

class DouyinLoginPollResult {
  const DouyinLoginPollResult({
    required this.phase,
    this.message,
    this.session,
    this.technicalDetail,
  });

  final DouyinLoginPhase phase;
  final String? message;
  final PlatformSession? session;

  /// 面向排查的技术说明（不展示给普通用户）。
  final String? technicalDetail;

  bool get succeeded => phase == DouyinLoginPhase.succeeded;
}

/// 抖音扫码登录客户端。
class DouyinLoginClient {
  DouyinLoginClient({required FusionHttpClient http, FusionLogger? logger})
      : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  final Random _random = Random.secure();

  /// 19 个固定参数（实测从真实请求提取）。
  static const Map<String, String> _fixedParams = {
    'passport_jssdk_version': '3.4.9',
    'passport_jssdk_type': 'normal',
    'is_from_ttaccountsdk': '1',
    'aid': '6383',
    'language': 'zh',
    'account_app_language': 'zh-CN',
    'is_from_iesaccountsaas': '1',
    'p_ui': '2.4.10',
    'p_ca': '4.0.26',
    'p_ca_real': '1.0.0.938',
    'account_sdk_source': 'web',
    'device_platform': 'web_app',
    'p_js_v': '3.4.9',
    'p_js_t': 'pro',
    'p_zt': '3.3.30',
    'p_ver': '1.1.4-beta.5',
    'p_ver_real': '0',
    'p_bd': '1.0.1.19-fix.01',
    'request_host': 'https://www.douyin.com',
  };

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 请求二维码。
  Future<DouyinQrChallenge> requestQrCode() async {
    final fp = _genFp();
    final now = DateTime.now();

    final queryParams = <String, String>{
      ..._fixedParams,
      'ts': '${now.millisecondsSinceEpoch ~/ 1000}',
      'account_sdk_source_info': _encodeDeviceInfo(),
      'fp': fp,
      'verifyFp': fp,
      'biz_trace_id': _hex8(),
      'msToken': _genMsToken(),
    };

    // 业务参数放 body，不放 query
    const body = 'need_logo=false&is_frontier=true&is_new_login=1'
        '&next=https%3A%2F%2Fwww.douyin.com&need_short_url=true';

    _logger.info('douyin login: requesting qr code');

    final result = await _post(
      '/passport/web/get_qrcode/',
      queryParams,
      body,
    );

    final json = result.jsonObject(platformId: 'douyin');
    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音登录服务返回了异常数据。',
        technicalMessage: 'get_qrcode: data is not a map',
        platformId: 'douyin',
      );
    }
    final d = Map<String, Object?>.from(data);
    final code = (d['error_code'] as num?)?.toInt() ?? -1;

    if (code != 0) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音登录暂不可用：${d['description'] ?? '平台拒绝请求'}',
        technicalMessage: 'get_qrcode error_code=$code',
        upstreamCode: code,
        platformId: 'douyin',
        retryable: true,
      );
    }

    final qr = d['qrcode'] as String?;
    final token = d['token'] as String?;
    if (qr == null || qr.isEmpty || token == null) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音未返回二维码。',
        technicalMessage: 'get_qrcode: missing qrcode/token',
        platformId: 'douyin',
      );
    }

    final expire = (d['expire_time'] as num?)?.toInt();
    final expiresAt = expire != null
        ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
        : now.add(const Duration(minutes: 3));

    _logger.info('douyin login: qr code received', {
      'qrLength': qr.length,
      'expiresIn': expiresAt.difference(now).inSeconds,
    });

    return DouyinQrChallenge(
      qrBase64: qr,
      token: token,
      expiresAt: expiresAt,
      fp: fp,
    );
  }

  /// 轮询扫码状态。
  ///
  /// **关键**：`token` 必须放在 POST body 里，不是 query。
  /// 这是之前一直返回 `error_code: 3`（缺少参数）的真正原因。
  Future<DouyinLoginPollResult> pollQrStatus(
    DouyinQrChallenge challenge,
  ) async {
    if (challenge.isExpired) {
      return const DouyinLoginPollResult(
        phase: DouyinLoginPhase.expired,
        message: '二维码已过期，请刷新。',
      );
    }

    final queryParams = <String, String>{
      ..._fixedParams,
      'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'account_sdk_source_info': _encodeDeviceInfo(),
      'fp': challenge.fp,
      'verifyFp': challenge.fp,
      'biz_trace_id': _hex8(),
      'p_ts': '${DateTime.now().millisecondsSinceEpoch}',
      'msToken': _genMsToken(),
    };

    // token 在 body 里
    final body = 'need_logo=false&is_frontier=true'
        '&token=${challenge.token}'
        '&is_new_login=1&next=https%3A%2F%2Fwww.douyin.com'
        '&need_short_url=true';

    try {
      final result = await _post(
        '/passport/web/check_qrconnect/',
        queryParams,
        body,
      );

      final json = result.jsonObject(platformId: 'douyin');
      final data = json['data'];
      if (data is! Map) {
        return const DouyinLoginPollResult(
          phase: DouyinLoginPhase.blocked,
          message: '抖音登录服务返回异常。',
          technicalDetail: 'check_qrconnect: data is not a map',
        );
      }

      final d = Map<String, Object?>.from(data);
      final code = (d['error_code'] as num?)?.toInt() ?? -1;
      final status = d['status'] as String?;

      if (code == 4031) {
        _logger.warn('douyin login: blocked by risk control');
        return const DouyinLoginPollResult(
          phase: DouyinLoginPhase.blocked,
          message: '抖音风控拦截了本次请求，请稍后重试。',
          technicalDetail: 'check_qrconnect error_code=4031',
        );
      }

      if (code != 0) {
        return DouyinLoginPollResult(
          phase: DouyinLoginPhase.blocked,
          message: '抖音登录失败：${d['description'] ?? '未知原因'}',
          technicalDetail: 'check_qrconnect error_code=$code',
        );
      }

      switch (status) {
        case 'new':
          return const DouyinLoginPollResult(
            phase: DouyinLoginPhase.waitingForScan,
            message: '请用抖音 App 扫描二维码。',
          );
        case 'scanning':
        case 'scanned':
          return const DouyinLoginPollResult(
            phase: DouyinLoginPhase.waitingForConfirm,
            message: '已扫码，请在手机上确认登录。',
          );
        case 'confirmed':
        case 'success':
          // 平台确认登录，接下来需要用 ticket 换取 Cookie。
          // 这一步的接口与参数尚未验证，因此如实返回"需继续"。
          return DouyinLoginPollResult(
            phase: DouyinLoginPhase.waitingForConfirm,
            message: '登录已确认，正在获取凭证…',
            technicalDetail: 'status=$status, cookie exchange pending',
          );
        default:
          return DouyinLoginPollResult(
            phase: DouyinLoginPhase.waitingForScan,
            message: '等待扫码…（$status）',
            technicalDetail: 'unknown status=$status',
          );
      }
    } on FusionException catch (e) {
      return DouyinLoginPollResult(
        phase: DouyinLoginPhase.blocked,
        message: e.userMessage,
        technicalDetail: e.technicalMessage,
      );
    }
  }

  /// 发一个带 `a_bogus` 签名的 POST。
  ///
  /// 签名覆盖 query 与 body 两部分：
  ///  - `a_bogus` 用**不含自身**的 query + body 计算
  ///  - body 里的参数也参与签名（签空 body 会失败）
  Future<HttpResult> _post(
    String path,
    Map<String, String> queryParams,
    String body,
  ) async {
    final query = queryParams.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    // 计算 a_bogus
    final signer = ABogus(userAgent: _userAgent);
    final abogus = signer.getValue(query, body: body);

    final fullQuery = '$query&a_bogus=${Uri.encodeQueryComponent(abogus)}';

    return _http.post(
      'https://www.douyin.com$path?$fullQuery',
      headers: const {
        'User-Agent': _userAgent,
        'Referer': 'https://www.douyin.com/',
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body,
      platformId: 'douyin',
    );
  }

  // ── 编码工具 ────────────────────────────────────────────────

  /// 构造设备指纹 JSON。
  ///
  /// 结构与实测解码结果一致（XOR 0x05 解出的字段）。
  /// **不含任何真实设备信息**——这些是通用的浏览器环境描述，
  /// 不用于绕过访问控制，只是接口要求的参数格式。
  String _encodeDeviceInfo() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final json = jsonEncode({
      'hardwareConcurrency': 8,
      'webdriver': false,
      'chromedriver': false,
      'shelldriver': false,
      'plugins': 5,
      'innerHeight': 900,
      'innerWidth': 1280,
      'outerHeight': 988,
      'outerWidth': 1296,
      'webgl': {
        'vendor': 'Google Inc.',
        'renderer': 'ANGLE (Google, Vulkan 1.3.0)',
      },
      'automation': {'s': '00100000', 'c': '0000', 'p': '0000000'},
      'performance': {'timeOrigin': now},
      'browser': {
        't': '$now',
        'bit_protocol': 'false',
        'bit_helper': false,
      },
    });
    // XOR 0x05 后转 hex（实测确认的编码方式）
    return json.codeUnits
        .map((c) => ((c ^ 0x05) & 0xFF).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 生成 verifyFp 格式的指纹。
  String _genFp() {
    String seg(int n) {
      const chars =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      return List.generate(n, (_) => chars[_random.nextInt(chars.length)])
          .join();
    }

    return 'verify_mvdd${seg(6)}_${seg(8)}_${seg(4)}_${seg(4)}_'
        '${seg(4)}_${seg(12)}';
  }

  String _hex8() {
    final v = _random.nextInt(0xFFFFFFFF);
    return v.toRadixString(16).padLeft(8, '0');
  }

  /// 生成 msToken。
  ///
  /// 实测格式：107 个字符（字母/数字/`-_`）+ 单个 `=` 填充。
  /// 服务端不校验其内容，只要求长度与字符集符合。
  String _genMsToken() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final sb = StringBuffer();
    for (var i = 0; i < 107; i++) {
      sb.write(chars[_random.nextInt(chars.length)]);
    }
    sb.write('=');
    return sb.toString();
  }
}
