/// 抖音扫码登录。
///
/// # 实测结论（2026-10-18）
///
/// | 接口 | 纯 Dart 可用性 |
/// |---|---|
/// | `POST /passport/web/get_qrcode/` | ✅ **完全可用** |
/// | `POST /passport/web/check_qrconnect/` | ❌ 被风控拦截 |
///
/// ## get_qrcode 为什么可用
///
/// 它只需要 19 个固定参数 + `fp` + `account_sdk_source_info`，
/// 不需要 `a_bogus`。实测返回 `error_code: 0` 与真实 base64 二维码。
///
/// ## check_qrconnect 为什么不可用
///
/// 实测对比三种情况：
///
/// | 请求 | 结果 |
/// |---|---|
/// | 不带 `a_bogus` | `error_code: 4031`（安全风险，已阻止） |
/// | 带 `a_bogus`（用 evil0ctal 的实现） | `error_code: 3`（缺少参数） |
/// | 补齐全部 19 个固定参数 + `msToken` + `a_bogus` | 仍 `error_code: 3` |
///
/// 缺的是 `sign` 参数。推导过程：
///
/// - `qs` 参数解码后是参与签名的参数名列表（XOR 0x05）
/// - 尝试了 md5/sha1/sha256 × 5 种拼接 × 4 种 salt × HMAC
///   **全部不匹配**
/// - 从 JS bundle 提取到候选 salt `566f58151b0ed37e`，也不匹配
///
/// 结论：`sign` 依赖 JS 运行时状态（`performance.timeOrigin` 等），
/// 不是纯参数哈希，**无法在纯 Dart 中复现**。
///
/// # 因此本实现的边界
///
/// - 二维码：真实获取、真实渲染
/// - 轮询：如实调用，被拦截时抛 `capabilityUnavailable` 并说明原因
/// - **不伪造登录成功**
///
/// 用户实际可用的登录路径是 **Cookie 导入**（`CookiePortable`），
/// 从浏览器开发者工具复制 Cookie 即可。
library;

import 'dart:convert';
import 'dart:math';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';

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
  ///
  /// 这一步**实测可用**，返回真实 base64 二维码。
  Future<DouyinQrChallenge> requestQrCode() async {
    final fp = _genFp();
    final now = DateTime.now();

    final params = <String, String>{
      ..._fixedParams,
      'ts': '${now.millisecondsSinceEpoch ~/ 1000}',
      'next': 'https://www.douyin.com',
      'need_short_url': 'true',
      'need_logo': 'false',
      'is_new_login': '1',
      'account_sdk_source_info': _encodeDeviceInfo(),
      'fp': fp,
      'verifyFp': fp,
      'biz_trace_id': _hex8(),
    };

    final query = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    _logger.info('douyin login: requesting qr code');

    final result = await _http.post(
      'https://www.douyin.com/passport/web/get_qrcode/?$query',
      headers: const {
        'User-Agent': _userAgent,
        'Referer': 'https://www.douyin.com/',
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: '',
      platformId: 'douyin',
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
  /// **当前实测会被风控拦截**（`error_code: 3` 缺少 `sign`）。
  /// 本方法如实返回 `blocked` 状态并附技术说明，
  /// **不会**伪造登录成功。
  Future<DouyinLoginPollResult> pollQrStatus(
    DouyinQrChallenge challenge,
  ) async {
    if (challenge.isExpired) {
      return const DouyinLoginPollResult(
        phase: DouyinLoginPhase.expired,
        message: '二维码已过期，请刷新。',
      );
    }

    final params = <String, String>{
      ..._fixedParams,
      'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'account_sdk_source_info': _encodeDeviceInfo(),
      'fp': challenge.fp,
      'verifyFp': challenge.fp,
      'biz_trace_id': _hex8(),
    };

    final query = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    try {
      final result = await _http.post(
        'https://www.douyin.com/passport/web/check_qrconnect/?$query',
        headers: const {
          'User-Agent': _userAgent,
          'Referer': 'https://www.douyin.com/',
          'Accept': 'application/json, text/plain, */*',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: '',
        platformId: 'douyin',
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

      // 4031 = 安全风控；3 = 缺少参数（实测缺 sign）
      if (code == 4031) {
        _logger.warn('douyin login: blocked by risk control', {
          'code': code,
        });
        return const DouyinLoginPollResult(
          phase: DouyinLoginPhase.blocked,
          message: '抖音登录需要平台安全签名，当前无法在应用内完成。'
              '请改用「导入 Cookie」方式登录。',
          technicalDetail:
              'check_qrconnect error_code=4031 (risk control)',
        );
      }

      if (code == 3) {
        _logger.warn('douyin login: missing sign parameter', {
          'code': code,
          'desc': '${d['description']}',
        });
        return const DouyinLoginPollResult(
          phase: DouyinLoginPhase.blocked,
          message: '抖音登录需要平台签名（sign），该签名依赖页面运行环境，'
              '无法在应用内生成。请改用「导入 Cookie」方式登录。',
          technicalDetail:
              'check_qrconnect error_code=3 (missing sign). '
              'sign requires JS runtime state (performance.timeOrigin), '
              'not reproducible in pure Dart.',
        );
      }

      if (code != 0) {
        return DouyinLoginPollResult(
          phase: DouyinLoginPhase.blocked,
          message: '抖音登录失败：${d['description'] ?? '未知原因'}',
          technicalDetail: 'check_qrconnect error_code=$code',
        );
      }

      // 正常状态机
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
          // 走到这里说明平台确实返回了成功，但当前实现拿不到
          // 有效的会话 Cookie（缺少后续换取步骤）。
          return DouyinLoginPollResult(
            phase: DouyinLoginPhase.blocked,
            message: '登录已确认，但无法完成凭证换取。请改用「导入 Cookie」。',
            technicalDetail: 'status=$status but no session exchange step',
          );
        default:
          return DouyinLoginPollResult(
            phase: DouyinLoginPhase.waitingForScan,
            message: '等待扫码…（status=$status）',
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
}
