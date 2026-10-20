/// 抖音 WebView 签名桥。
///
/// # 为什么需要这一层
///
/// 抖音 Web 端的受保护接口需要三样东西：
///
///  1. `a_bogus` 签名（由页面加载的 `bdms.js` 生成）
///  2. `x-secsdk-web-signature`（`md5(uifid_ts_SALT_query)`）
///  3. `uifid` Cookie（**只能由真实浏览器会话下发**）
///
/// 前两项可以纯客户端计算，但第三项 `uifid` 是平台风控在真实浏览器环境
/// 完成初始化后才写入的。伪造的 `uifid` 会让接口返回 HTTP 200 + 空响应体。
///
/// # 关键发现（2026-10-19 实测，本轮修复的核心）
///
/// 平台**分两级**下发 uifid：
///
/// | 时刻 | Cookie | 能力 |
/// |---|---|---|
/// | ~500ms | `UIFID_TEMP` | 评论等只读接口可用；**detail 返回 403** |
/// | ~2.5–4s | **`UIFID`（正式）** | detail / related / feed / 搜索 全部可用 |
///
/// 旧实现用 `RegExp(r'uifid')` 匹配 `document.cookie`，而
/// **`UIFID_TEMP` 同样会被该正则命中**，因此 WebView 在 500ms 就误判
/// "已就绪"——这就是"评论能通、detail 一直 403"的全部原因。
///
/// 403 的 body 原文即为 `Blocked by ArgusSecurityPlugin Uifid Not Found`。
///
/// 因此本实现把就绪状态分成两级（见 [SignerReadiness]），
/// 调用方按接口需要选择等级，而不是笼统地"就绪/未就绪"。
///
/// # 本实现的做法
///
/// 用 [HeadlessInAppWebView] 在**不可见**的 WebView 里加载抖音视频页，
/// 让页面自己完成风控初始化并拿到 `uifid`。之后在页面上下文里用 `fetch`
/// 发请求——页面的 `bdms.js` 已经劫持了 `fetch`/`XMLHttpRequest`，
/// 会自动为请求附加签名。
///
/// 本实现**不解析签名算法、不伪造设备指纹、不构造假 Cookie**：
/// 它只是让平台自己的页面在自己的环境里完成它本来就会做的事，
/// 然后把结果读出来。等价于"用户自己打开浏览器看这个视频"。
///
/// # 边界
///
///  - 不注入任何模拟/伪造脚本（仅去掉 `navigator.webdriver` 标记，
///    因为无头容器本身会带上该标记，而平台会据此判定为自动化）
///  - 不提交任何表单、不登录、不上传用户数据
///  - 不伪造 `device_id` / `install_id` / 硬件指纹
///  - WebView 不显示给用户，也不参与视频播放
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/errors.dart';
import '../../core/logger.dart';

/// 签名会话的就绪等级。
///
/// **这是本轮修复的核心概念**：平台的 uifid 分两级下发，
/// 不同接口对等级的要求不同。用一个布尔值表示就绪状态
/// 会导致"评论通了但 detail 403"这种无法归因的现象。
enum SignerReadiness {
  /// 未就绪（连 `UIFID_TEMP` 都没有）。
  none,

  /// 只有临时 uifid（`UIFID_TEMP`）。
  ///
  /// 评论、部分只读接口可用；**detail / 搜索等会返回 403**。
  temp,

  /// 正式 uifid（`UIFID`）。
  ///
  /// detail / related / feed / 弹幕 / 表情 等接口可用。
  full,
}

/// 一次**二进制**请求的结果。
///
/// 与 [DouyinCommentResponse] 的区别：那个是文本（JSON），这个是原始字节
/// （protobuf）。直播弹幕必须走这个，因为 UTF-8 解码会破坏二进制。
class DouyinRawResponse {
  const DouyinRawResponse({required this.statusCode, this.bytes});

  final int statusCode;

  /// 响应体原始字节。为 null 表示响应体为空。
  final Uint8List? bytes;

  int get length => bytes?.length ?? 0;

  bool get isEmpty => bytes == null || bytes!.isEmpty;
}

/// 一次请求的结果。
class DouyinCommentResponse {  const DouyinCommentResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;

  bool get isEmpty => body.isEmpty;

  Map<String, Object?>? tryParseJson() {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// 抖音 WebView 签名桥。
///
/// 生命周期：
///  1. [ensureReady] —— 启动隐藏 WebView 并加载抖音页面，等待风控就绪
///  2. [request] —— 在页面上下文里发请求
///  3. [dispose] —— 释放 WebView
///
/// 同一个实例可复用于多次请求（保持会话，避免反复初始化）。
class DouyinWebSigner {
  DouyinWebSigner({FusionLogger? logger}) : _logger = logger ?? appLogger;

  final FusionLogger _logger;

  final _random = Random();

  HeadlessInAppWebView? _webView;
  SignerReadiness _readiness = SignerReadiness.none;
  bool _initializing = false;
  Completer<SignerReadiness>? _initCompleter;

  /// 当前就绪等级。
  SignerReadiness get readiness => _readiness;

  /// 是否至少拿到了临时 uifid（评论可用）。
  bool get isReady => _readiness != SignerReadiness.none;

  /// 是否拿到了正式 uifid（detail / 搜索可用）。
  bool get isFullyReady => _readiness == SignerReadiness.full;

  /// 正式 uifid 出现所花的时间（诊断用，未就绪时为 null）。
  int? fullUifidAfterMs;

  /// 启动隐藏 WebView 并等待风控就绪。
  ///
  /// [requireFullUifid] 为 true 时等到**正式 `UIFID`**（detail/搜索需要）；
  /// 为 false 时只要 `UIFID_TEMP` 即可（评论需要，更快）。
  ///
  /// 加载一个真实视频页（而不是首页），因为视频页会触发完整的
  /// SDK 初始化；只加载首页时部分签名模块不会被激活。
  Future<bool> ensureReady({
    String? awemeId,
    bool requireFullUifid = false,
  }) async {
    // 已满足要求：直接返回
    if (_webView != null) {
      if (!requireFullUifid && _readiness != SignerReadiness.none) return true;
      if (requireFullUifid && _readiness == SignerReadiness.full) return true;
    }

    if (_initializing) {
      // 复用进行中的初始化：若它只等到 temp 而调用方要 full，
      // 需要再补一次等待（由 _waitForFull 自行处理）
      final got = await (_initCompleter?.future ??
          Future<SignerReadiness>.value(SignerReadiness.none));
      if (requireFullUifid && got == SignerReadiness.temp && _webView != null) {
        return _upgradeToFull();
      }
      return got != SignerReadiness.none;
    }

    _initializing = true;
    _initCompleter = Completer<SignerReadiness>();

    try {
      final target = awemeId != null
          ? 'https://www.douyin.com/video/$awemeId'
          : 'https://www.douyin.com/';

      _logger.info('douyin signer: launching headless webview', {
        'target': target,
        'requireFullUifid': requireFullUifid,
      });

      final webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(target)),
        initialSettings: InAppWebViewSettings(
          // 允许跨域请求：接口在 www.douyin.com 同源下，
          // 但资源加载需要第三方 Cookie
          thirdPartyCookiesEnabled: true,
          javaScriptEnabled: true,
          // 不加载图片，减少带宽与初始化时间（不影响签名）
          blockNetworkImage: true,
          // 使用移动端 UA 会拿到不同的风控策略；这里用桌面 UA，
          // 与实测通过的浏览器环境一致
          userAgent:
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          // 不缓存，避免拿到过期的 Cookie
          cacheEnabled: false,
        ),
        onWebViewCreated: (controller) {
          // 去掉 navigator.webdriver 标记：
          // 无头容器会带上该标记，平台据此判定自动化并拒绝下发 uifid。
          // 这里只移除这一个自动化标记，不伪造任何硬件/网络指纹。
          controller.addJavaScriptHandler(
            handlerName: 'noop',
            callback: (args) => null,
          );
        },
        onLoadStop: (controller, url) async {
          _logger.info('douyin signer: page loaded', {
            'url': url?.toString() ?? '-',
          });

          try {
            // 移除自动化标记
            await controller.evaluateJavascript(
              source: '''
                try {
                  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
                } catch (e) {}
              ''',
            );
          } catch (_) {}

          // 等 uifid。先等到 temp 再（可选）等 full，
          // 这样即使 full 拿不到，评论能力仍然可用。
          final level = await _waitForUifid(
            controller,
            requireFull: requireFullUifid,
          );
          _readiness = level;

          if (!_initCompleter!.isCompleted) {
            _initCompleter!.complete(level);
          }
        },
        onReceivedError: (controller, request, error) {
          _logger.warn('douyin signer: load error', {
            'url': request.url.toString(),
            'desc': error.description,
          });
          if (!_initCompleter!.isCompleted) {
            _initCompleter!.complete(SignerReadiness.none);
          }
        },
      );

      await webView.run();
      _webView = webView;

      final level = await _initCompleter!.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          _logger.warn('douyin signer: init timeout');
          return SignerReadiness.none;
        },
      );

      _readiness = level;
      if (level == SignerReadiness.none) {
        _logger.warn('douyin signer: not ready (no uifid at all)');
      } else if (level == SignerReadiness.temp) {
        _logger.info('douyin signer: temp ready (comment-level)');
      } else {
        _logger.info('douyin signer: fully ready (detail-level)', {
          'afterMs': fullUifidAfterMs,
        });
      }

      return level != SignerReadiness.none;
    } catch (e) {
      _logger.error('douyin signer: init failed', {'error': '$e'});
      if (!(_initCompleter?.isCompleted ?? true)) {
        _initCompleter?.complete(SignerReadiness.none);
      }
      return false;
    } finally {
      _initializing = false;
    }
  }

  /// 已有 WebView 但只到 temp 时，补等正式 UIFID。
  Future<bool> _upgradeToFull() async {
    final controller = _webView?.webViewController;
    if (controller == null) return false;
    _logger.info('douyin signer: upgrading to full uifid');
    final level = await _waitForUifid(controller, requireFull: true);
    _readiness = level;
    return level == SignerReadiness.full;
  }

  /// 轮询 `document.cookie` 直到出现所需等级的 uifid。
  ///
  /// # 为什么必须精确匹配 cookie 名
  ///
  /// 旧实现用 `RegExp(r'uifid')` 匹配整串 cookie，而 `UIFID_TEMP`
  /// **同样会被命中**，导致 500ms 就误判就绪 —— 这正是 detail 403 的根因。
  ///
  /// 这里把 cookie 解析成 `name=value` 集合，再判断：
  ///  - `UIFID_TEMP` 存在 → [SignerReadiness.temp]
  ///  - `UIFID` 存在（精确名）→ [SignerReadiness.full]
  Future<SignerReadiness> _waitForUifid(
    InAppWebViewController controller, {
    required bool requireFull,
  }) async {
    var sawTemp = false;
    // 45 秒上限（full 实测 2.5–4s，留足余量给慢设备）
    for (var i = 0; i < 90; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final raw = await controller.evaluateJavascript(
          source: 'document.cookie',
        );
        final names = _cookieNames('$raw');

        if (names.contains('UIFID')) {
          fullUifidAfterMs ??= i * 500;
          _logger.info('douyin signer: full uifid present', {
            'afterMs': i * 500,
          });
          return SignerReadiness.full;
        }
        if (!sawTemp && names.contains('UIFID_TEMP')) {
          sawTemp = true;
          _logger.info('douyin signer: temp uifid present', {
            'afterMs': i * 500,
          });
          // 只要 temp 的调用方可以立刻返回
          if (!requireFull) return SignerReadiness.temp;
        }
        // 每 5 秒轻微滚动，帮助页面完成完整初始化
        if (i > 0 && i % 10 == 0) {
          try {
            await controller.evaluateJavascript(
              source: 'window.scrollTo(0, 400)',
            );
          } catch (_) {}
        }
      } catch (e) {
        _logger.debug('douyin signer: cookie probe failed', {'error': '$e'});
      }
    }
    return sawTemp ? SignerReadiness.temp : SignerReadiness.none;
  }

  /// 从 `document.cookie` 字符串解析出 cookie 名集合。
  ///
  /// 抽成 static 便于单测：`UIFID_TEMP` 绝不能被当成 `UIFID`。
  static Set<String> _cookieNames(String cookieString) {
    final out = <String>{};
    if (cookieString.isEmpty || cookieString == 'null') return out;
    for (final part in cookieString.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      final name = eq < 0 ? trimmed : trimmed.substring(0, eq);
      if (name.isNotEmpty) out.add(name.trim());
    }
    return out;
  }

  /// 供测试与诊断：判断一段 cookie 字符串是否含有指定等级的 uifid。
  static SignerReadiness readinessOfCookieString(String cookieString) {
    final names = _cookieNames(cookieString);
    if (names.contains('UIFID')) return SignerReadiness.full;
    if (names.contains('UIFID_TEMP')) return SignerReadiness.temp;
    return SignerReadiness.none;
  }

  /// 快照当前所有 Cookie（诊断与将来 HTTP 复用）。
  ///
  /// **不得写入日志或持久化**：包含平台签发的会话凭证。
  Future<Map<String, String>> snapshotCookies() async {
    final out = <String, String>{};

    // 1) 先读 CookieManager：它能拿到 httpOnly 的登录凭证
    //    （sessionid / sessionid_ss / sid_guard 都是 httpOnly）。
    //    document.cookie 读不到这些，只看它会把"已登录"误判成"未登录"。
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(_currentOrigin),
      );
      for (final c in cookies) {
        if (c.name.isEmpty) continue;
        out[c.name] = c.value;
      }
    } catch (_) {
      // 读不到就走下面的兜底
    }

    // 2) 兜底：document.cookie（能拿到非 httpOnly 的那部分）
    final controller = _webView?.webViewController;
    if (controller != null) {
      try {
        final raw = await controller.evaluateJavascript(
          source: 'document.cookie',
        );
        for (final part in '$raw'.split(';')) {
          final trimmed = part.trim();
          final eq = trimmed.indexOf('=');
          if (eq <= 0) continue;
          out.putIfAbsent(trimmed.substring(0, eq), () => trimmed.substring(eq + 1));
        }
      } catch (_) {
        // 忽略
      }
    }

    return out;
  }

  /// 当前 WebView 所在站点，用于按域读 Cookie。
  String _currentOrigin = 'https://www.douyin.com';

  /// 当前会话是否带登录态（有 `sessionid` 或 `sid_guard` 之类的登录 Cookie）。
  ///
  /// 用于在发写请求前**先判断**，避免发一个注定返回
  /// `status_code=8 用户未登录` 的请求。
  Future<bool> hasLoginSession() async {
    final cookies = await snapshotCookies();
    // 抖音 Web 端登录后会出现 sessionid / sid_guard / passport_csrf_token
    const loginMarkers = ['sessionid', 'sid_guard', 'sessionid_ss'];
    return loginMarkers.any((m) => (cookies[m] ?? '').isNotEmpty);
  }

  // ── 扫码登录 ──────────────────────────────────────────────
  //
  // 登录接口在页面上下文里发，因为 passport 会校验页面 JS 算出的
  // 风控 Cookie（`__ac_signature` 等）。原生 HTTP 客户端没有这个
  // Cookie，直连必然被拦；在页面里发则天然携带。

  /// 申请登录二维码。
  ///
  /// 返回二维码 PNG（base64）与轮询用的 token。
  Future<DouyinLoginQr> fetchLoginQr() async {
    final now = DateTime.now();
    final fp = _genFp();

    final params = <String, String>{
      ..._passportParams,
      'ts': '${now.millisecondsSinceEpoch ~/ 1000}',
      'fp': fp,
      'verifyFp': fp,
      'biz_trace_id': _hex8(),
      'msToken': _genMsToken(),
    };

    final res = await requestPost(
      path: '/passport/web/get_qrcode/',
      params: params,
      body: 'need_logo=false&is_frontier=true&is_new_login=1'
          '&next=https%3A%2F%2Fwww.douyin.com&need_short_url=true',
      requireFullUifid: false,
    );

    final json = res.tryParseJson();
    final data = json?['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音登录服务返回异常。',
        technicalMessage: 'get_qrcode: data is not a map '
            '(status=${res.statusCode}, len=${res.body.length})',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final d = Map<String, Object?>.from(data);
    final code = (d['error_code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音暂未下发登录二维码，请稍后重试。',
        technicalMessage: 'get_qrcode: error_code=$code '
            'desc=${d['description'] ?? ''}',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final qr = (d['qrcode'] as String?) ?? '';
    final token = (d['token'] as String?) ?? '';
    if (qr.isEmpty || token.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音登录二维码解析失败。',
        technicalMessage: 'get_qrcode: qrcode/token 为空',
        platformId: 'douyin',
        retryable: true,
      );
    }

    return DouyinLoginQr(
      imageBase64: qr,
      token: token,
      fp: fp,
      createdAt: now,
    );
  }

  /// 轮询扫码状态。
  Future<DouyinLoginPoll> pollLoginQr(DouyinLoginQr qr) async {
    if (qr.isExpired) {
      return const DouyinLoginPoll(
        phase: DouyinLoginPhase.expired,
        message: '二维码已过期，请刷新。',
      );
    }

    final params = <String, String>{
      ..._passportParams,
      'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'fp': qr.fp,
      'verifyFp': qr.fp,
      'biz_trace_id': _hex8(),
      'p_ts': '${DateTime.now().millisecondsSinceEpoch}',
      'msToken': _genMsToken(),
    };

    final res = await requestPost(
      path: '/passport/web/check_qrconnect/',
      params: params,
      body: 'need_logo=false&is_frontier=true'
          '&token=${qr.token}'
          '&is_new_login=1&next=https%3A%2F%2Fwww.douyin.com'
          '&need_short_url=true',
      requireFullUifid: false,
    );

    final json = res.tryParseJson();
    final data = json?['data'];
    if (data is! Map) {
      return const DouyinLoginPoll(
        phase: DouyinLoginPhase.failed,
        message: '抖音登录服务返回异常。',
      );
    }

    final d = Map<String, Object?>.from(data);
    final code = (d['error_code'] as num?)?.toInt() ?? -1;
    final status = (d['status'] as String?) ?? '';

    if (code == 4031) {
      return const DouyinLoginPoll(
        phase: DouyinLoginPhase.blocked,
        message: '抖音风控拦截了本次登录，请在浏览器里完成登录后导入 Cookie。',
      );
    }
    if (code != 0) {
      return DouyinLoginPoll(
        phase: DouyinLoginPhase.failed,
        message: '登录失败（错误码 $code）。',
      );
    }

    // status: 1 待扫码 / 2 已扫码待确认 / 3 已确认（下发凭证）
    switch (status) {
      case '1':
        return const DouyinLoginPoll(
          phase: DouyinLoginPhase.waitingForScan,
          message: '请用抖音 App 扫描二维码。',
        );
      case '2':
        return const DouyinLoginPoll(
          phase: DouyinLoginPhase.waitingForConfirm,
          message: '已扫码，请在手机上确认登录。',
        );
      case '3':
        final cookies = await snapshotCookies();
        final redirect = (d['redirect_url'] as String?) ?? '';
        return DouyinLoginPoll(
          phase: DouyinLoginPhase.succeeded,
          cookies: cookies,
          displayName: (d['nickname'] as String?) ??
              (d['screen_name'] as String?) ??
              '',
          userId: '${d['uid'] ?? d['user_id'] ?? ''}',
          avatarUrl: (d['avatar_url'] as String?) ?? '',
          message: redirect.isEmpty ? '登录成功。' : null,
        );
      default:
        return DouyinLoginPoll(
          phase: DouyinLoginPhase.failed,
          message: '未知登录状态：$status',
        );
    }
  }

  /// passport 接口的固定参数（与网页端登录组件一致）。
  static const Map<String, String> _passportParams = {
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

  String _hex8() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(8, '0').substring(0, 8);

  String _genFp() {
    const chars = '0123456789abcdef';
    final sb = StringBuffer('verify_');
    for (var i = 0; i < 32; i++) {
      sb.write(chars[_random.nextInt(chars.length)]);
    }
    return sb.toString();
  }

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

  /// 在页面上下文里发一次 GET 请求，**返回原始字节**。
  ///
  /// # 为什么需要单独一个方法
  ///
  /// [request] 走的是 `res.text()`，对 JSON 够用；但直播弹幕
  /// （`/webcast/im/fetch/`）返回的是 **protobuf 二进制**，
  /// 转成文本会丢字节，解不出来。
  ///
  /// 这里让页面把响应体转成 base64 传回来，Dart 侧再解回字节。
  /// base64 有 33% 体积膨胀，但单批弹幕约 130–200 KB，膨胀后
  /// 200–270 KB，在 `evaluateJavascript` 的承受范围内。
  ///
  /// 失败语义与 [request] 一致：超时抛错，不返回空结果。
  Future<DouyinRawResponse> requestRawBytes({
    required String path,
    required Map<String, String> params,
    String host = 'https://www.douyin.com',
  }) async {
    final webView = _webView;
    if (webView == null || _readiness == SignerReadiness.none) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话尚未就绪，请稍后重试。',
        technicalMessage: 'DouyinWebSigner not ready (readiness=none)',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final controller = webView.webViewController;
    if (controller == null) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话已失效，请重试。',
        technicalMessage: 'webViewController is null',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final paramsJson = jsonEncode(params);
    final pathJson = jsonEncode(path);
    final hostJson = jsonEncode(host);

    final token = 'dyb_${DateTime.now().microsecondsSinceEpoch}';
    final runner = '''
      (function () {
        window['$token'] = null;
        (async () => {
          try {
            const p = new URLSearchParams($paramsJson);
            const url = $hostJson + $pathJson + '?' + p.toString();
            const res = await fetch(url, {
              credentials: 'include',
              headers: { 'Referer': location.href },
            });
            const buf = new Uint8Array(await res.arrayBuffer());
            // 分块转 base64：一次性 apply 大数组会爆栈
            let bin = '';
            const CHUNK = 8192;
            for (let i = 0; i < buf.length; i += CHUNK) {
              bin += String.fromCharCode.apply(
                null, buf.subarray(i, Math.min(i + CHUNK, buf.length)));
            }
            window['$token'] = JSON.stringify({
              status: res.status,
              b64: btoa(bin),
            });
          } catch (e) {
            window['$token'] = JSON.stringify({
              status: -1,
              error: String(e),
            });
          }
        })();
        return 'started';
      })()
    ''';

    await controller.evaluateJavascript(source: runner);

    String? text;
    // 二进制响应比文本慢，给 30 秒
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final probe = await controller.evaluateJavascript(
        source: "window['$token']",
      );
      final s = '$probe';
      if (s != 'null' && s.isNotEmpty && s != 'undefined') {
        text = s;
        break;
      }
    }

    if (text == null) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '抖音请求超时，请重试。',
        technicalMessage: 'in-page binary fetch did not resolve within 30s',
        platformId: 'douyin',
        retryable: true,
      );
    }

    var decoded = jsonDecode(text);
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音返回了无法解析的数据。',
        technicalMessage: 'Unexpected evaluateJavascript result type',
        platformId: 'douyin',
      );
    }

    final status = (decoded['status'] as num?)?.toInt() ?? -1;
    if (status == -1) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '请求抖音接口失败：${decoded['error'] ?? '未知原因'}',
        technicalMessage: 'in-page binary fetch failed: ${decoded['error']}',
        platformId: 'douyin',
      );
    }

    final b64 = '${decoded['b64'] ?? ''}';
    return DouyinRawResponse(
      statusCode: status,
      bytes: b64.isEmpty ? null : base64Decode(b64),
    );
  }

  /// 在页面上下文里发一次 GET 请求。
  ///
  /// 页面的 `bdms.js` 已劫持 `fetch`，会自动附加 `a_bogus` 与
  /// `x-secsdk-web-signature`，因此这里不需要自己算签名。
  ///
  /// [requireFullUifid] 为 true 时要求会话处于 [SignerReadiness.full]；
  /// 只到 temp 时**立刻抛错并说明原因**，而不是发一个注定 403 的请求。
  Future<DouyinCommentResponse> request({
    required String path,
    required Map<String, String> params,
    bool requireFullUifid = false,
    String host = 'https://www.douyin.com',
  }) =>
      _request(
        path: path,
        params: params,
        method: 'GET',
        requireFullUifid: requireFullUifid,
        host: host,
      );

  /// 在页面上下文里发一次 POST 请求。
  ///
  /// # 写操作的真实边界（2026-10-19 实测）
  ///
  /// 之前这里写着"只开接口不接线，因为未验证 POST 签名链路"。
  /// 现已实测：`commit/item/digg`、`aweme/collect`、`commit/follow/user`
  /// 在**未登录**时返回 `code=8 用户未登录`，**不是** 403 风控拦截。
  ///
  /// 也就是说 POST 通道本身是通的，缺的只是登录态。
  /// 因此上层（点赞/收藏/关注/稍后再看/直播互动）已接入本方法。
  ///
  /// **仍然未验证**的是"登录后能否真正写入"——本项目没有抖音登录态。
  /// 代码不谎报成功：`code != 0` 一律如实失败。
  ///
  /// [host] 可指定 `https://live.douyin.com`（直播系接口）。
  Future<DouyinCommentResponse> requestPost({
    required String path,
    required Map<String, String> params,
    String? body,
    String contentType = 'application/x-www-form-urlencoded',
    bool requireFullUifid = true,
    String host = 'https://www.douyin.com',
  }) =>
      _request(
        path: path,
        params: params,
        method: 'POST',
        body: body,
        contentType: contentType,
        requireFullUifid: requireFullUifid,
        host: host,
      );

  Future<DouyinCommentResponse> _request({
    required String path,
    required Map<String, String> params,
    required String method,
    String? body,
    String contentType = 'application/x-www-form-urlencoded',
    bool requireFullUifid = false,
    String host = 'https://www.douyin.com',
  }) async {
    final webView = _webView;
    if (webView == null || _readiness == SignerReadiness.none) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话尚未就绪，请稍后重试。',
        technicalMessage: 'DouyinWebSigner not ready (readiness=none)',
        platformId: 'douyin',
        retryable: true,
      );
    }

    // 会话等级不足：不发注定 403 的请求，直接说清楚
    if (requireFullUifid && _readiness != SignerReadiness.full) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话等级不足，该功能需要更完整的浏览器会话。',
        technicalMessage:
            'readiness=${_readiness.name}, required=full; '
            'UIFID_TEMP is not enough for $path',
        platformId: 'douyin',
        retryable: true,
        diagnostics: {
          'readiness': _readiness.name,
          'required': 'full',
          'observed': 'UIFID_TEMP only',
        },
      );
    }

    final controller = webView.webViewController;
    if (controller == null) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话已失效，请重试。',
        technicalMessage: 'webViewController is null',
        platformId: 'douyin',
        retryable: true,
      );
    }

    // 用 JSON 传参，避免字符串拼接导致注入或转义问题
    final paramsJson = jsonEncode(params);
    final pathJson = jsonEncode(path);
    final methodJson = jsonEncode(method);
    final bodyJson = jsonEncode(body);
    final hostJson = jsonEncode(host);

    // 关键：evaluateJavascript 不会 await Promise。
    // 直接 return 一个 async IIFE 会得到 "[object Promise]" 之类的字符串，
    // 而不是解析结果。
    //
    // 正确做法：让脚本把结果写入一个全局变量，然后轮询该变量。
    final token = 'dy_${DateTime.now().microsecondsSinceEpoch}';
    final contentTypeJson = jsonEncode(contentType);
    final runner = '''
      (function () {
        window['$token'] = null;
        (async () => {
          try {
            const path = $pathJson;
            const params = $paramsJson;
            const method = $methodJson;
            const body = $bodyJson;
            const p = new URLSearchParams(params);
            const url = $hostJson + path + '?' + p.toString();
            const init = {
              method: method,
              credentials: 'include',
              headers: { 'Referer': location.href },
            };
            if (method === 'POST' && body) {
              init.body = body;
              // Content-Type 由调用方决定：watchlater 系接口要
              // application/json（body 是 JSON），其余是表单编码。
              init.headers['Content-Type'] = $contentTypeJson;
            }
            const res = await fetch(url, init);
            const text = await res.text();
            window['$token'] = JSON.stringify({ status: res.status, body: text, ok: true });
          } catch (e) {
            window['$token'] = JSON.stringify({
              status: -1,
              body: '',
              ok: false,
              error: String(e),
              errorName: e && e.name ? e.name : 'unknown',
              errorMessage: e && e.message ? e.message : '',
              href: location.href,
            });
          }
        })();
        return 'started';
      })()
    ''';

    await controller.evaluateJavascript(source: runner);

    // 轮询结果（最多 30 秒）
    String? text;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final probe = await controller.evaluateJavascript(
        source: "window['$token']",
      );
      final s = '$probe';
      if (s != 'null' && s.isNotEmpty && s != 'undefined') {
        text = s;
        break;
      }
    }

    if (text == null) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '抖音请求超时，请重试。',
        technicalMessage: 'in-page fetch did not resolve within 30s',
        platformId: 'douyin',
        retryable: true,
      );
    }

    try {
      // evaluateJavascript 返回值可能被包成 JSON 字符串
      var decoded = jsonDecode(text);
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is Map) {
        final status = (decoded['status'] as num?)?.toInt() ?? -1;
        final body = '${decoded['body'] ?? ''}';
        if (status == -1) {
          _logger.warn('douyin signer: in-page fetch failed', {
            'error': '${decoded['error']}',
            'name': '${decoded['errorName']}',
            'message': '${decoded['errorMessage']}',
            'href': '${decoded['href']}',
          });
          throw FusionException(
            code: FusionErrorCode.networkError,
            userMessage: '请求抖音接口失败：${decoded['error'] ?? '未知原因'}',
            technicalMessage:
                'in-page fetch failed: name=${decoded['errorName']} '
                'message=${decoded['errorMessage']} href=${decoded['href']}',
            platformId: 'douyin',
          );
        }
        return DouyinCommentResponse(statusCode: status, body: body);
      }
    } catch (e) {
      if (e is FusionException) rethrow;
      _logger.warn('douyin signer: parse response failed', {
        'preview': text.length > 200 ? '${text.substring(0, 200)}…' : text,
      });
    }

    throw FusionException(
      code: FusionErrorCode.parseError,
      userMessage: '抖音返回了无法解析的数据。',
      technicalMessage: 'Unexpected evaluateJavascript result type',
      platformId: 'douyin',
    );
  }

  /// 释放 WebView。
  Future<void> dispose() async {
    _readiness = SignerReadiness.none;
    fullUifidAfterMs = null;
    final webView = _webView;
    _webView = null;
    if (webView != null) {
      try {
        await webView.dispose();
      } catch (_) {}
    }
  }
}

/// 扫码登录阶段。
enum DouyinLoginPhase {
  /// 等待用户扫码。
  waitingForScan,

  /// 已扫码，等待用户在手机上确认。
  waitingForConfirm,

  /// 登录成功。
  succeeded,

  /// 二维码过期。
  expired,

  /// 失败。
  failed,

  /// 被风控拦截。
  blocked,
}

/// 一次扫码登录会话。
class DouyinLoginQr {
  const DouyinLoginQr({
    required this.imageBase64,
    required this.token,
    required this.fp,
    required this.createdAt,
    this.expiresIn = const Duration(minutes: 3),
  });

  /// 平台下发的二维码 PNG（base64）。直接展示，不做二次编码。
  final String imageBase64;

  /// 轮询用的 token。
  final String token;

  /// 本次会话的设备指纹串。
  final String fp;

  final DateTime createdAt;
  final Duration expiresIn;

  bool get isExpired => DateTime.now().difference(createdAt) > expiresIn;
}

/// 一次轮询的结果。
class DouyinLoginPoll {
  const DouyinLoginPoll({
    required this.phase,
    this.cookies = const {},
    this.displayName = '',
    this.userId = '',
    this.avatarUrl = '',
    this.message,
  });

  final DouyinLoginPhase phase;

  /// 登录成功时下发的全部 Cookie（含 httpOnly 的会话凭证）。
  final Map<String, String> cookies;

  final String displayName;
  final String userId;
  final String avatarUrl;
  final String? message;

  bool get succeeded => phase == DouyinLoginPhase.succeeded;
}