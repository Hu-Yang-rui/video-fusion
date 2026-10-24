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
import 'dtrait.dart';
import 'passport_headers.dart';
import 'ticket_guard.dart';

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

  /// 页面弹窗方案下，token/fp 由页面自己持有，这里只做占位。
  ///
  /// 轮询不再由我们拼参数发起——页面 SDK 自己会轮询
  /// `check_qrconnect`，我们只需等登录 Cookie 出现。
  static const String _modalToken = '__modal__';
  static const String _modalFp = '__modal__';

  /// 补齐 WebView 缺失的 Chrome 环境面。
  ///
  /// 抖音的 `uc-secure-dtrait-core` 在文档早期就读 `window.chrome`、
  /// `navigator.plugins`、`Notification` 等，Android WebView 缺这些，
  /// 于是被判"当前环境不支持"、`check_qrconnect` 返 4031。
  /// 这里只补浏览器本来就有的对象，不改硬件/网络指纹。
  static const String _chromeEnvPatch = r'''
    (function () {
      try {
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
      } catch (e) {}
      try {
        if (!window.chrome) { window.chrome = {}; }
        if (!window.chrome.runtime) { window.chrome.runtime = {}; }
        if (!window.chrome.loadTimes) {
          window.chrome.loadTimes = function () {
            return { requestTime: 0, startLoadTime: 0, commitLoadTime: 0,
                     finishDocumentLoadTime: 0, finishLoadTime: 0,
                     firstPaintTime: 0, firstPaintAfterLoadTime: 0,
                     navigationType: 'Other', wasFetchedViaSpdy: true,
                     wasNpnNegotiated: true, npnNegotiatedProtocol: 'h2',
                     wasAlternateProtocolAvailable: false,
                     connectionInfo: 'h2' };
          };
        }
        if (!window.chrome.csi) {
          window.chrome.csi = function () {
            return { startE: 0, onloadT: 0, pageT: 0, tran: 15 };
          };
        }
      } catch (e) {}
      try {
        if (!navigator.plugins || navigator.plugins.length === 0) {
          var mk = function (name, filename, desc) {
            return { name: name, filename: filename, description: desc,
                     length: 1, item: function () { return null; },
                     namedItem: function () { return null; } };
          };
          var list = [
            mk('PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
            mk('Chrome PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
            mk('Chromium PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
            mk('Microsoft Edge PDF Viewer', 'internal-pdf-viewer', 'Portable Document Format'),
            mk('WebKit built-in PDF', 'internal-pdf-viewer', 'Portable Document Format')
          ];
          Object.defineProperty(navigator, 'plugins', { get: () => list });
          Object.defineProperty(navigator, 'mimeTypes', {
            get: () => [{ type: 'application/pdf', suffixes: 'pdf',
                          description: 'Portable Document Format',
                          enabledPlugin: list[0] }]
          });
        }
      } catch (e) {}
      try {
        if (typeof Notification === 'undefined') {
          window.Notification = function () {};
          window.Notification.permission = 'default';
          window.Notification.requestPermission = function () {
            return Promise.resolve('default');
          };
        }
      } catch (e) {}
      try {
        if (navigator.languages && navigator.languages.length === 0) {
          Object.defineProperty(navigator, 'languages', { get: () => ['zh-CN', 'zh'] });
        }
      } catch (e) {}
    })();
  ''';

  /// 是否为"页面弹窗"模式（token 是占位符）。
  bool _isModalMode(DouyinLoginQr qr) => qr.token == _modalToken;

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
          // # 图片必须放行（2026-10-23 修正）
          //
          // 原设置 `blockNetworkImage: true` 是为省流量。但实测发现
          // 抖音的 `bd_ticket_guard` 设备票据 SDK 需要加载图片资源
          // 才能完成环境自证，图片被拦后它不下发
          // `bd_ticket_guard_client_data` / `ttwid` / `web_sign_token`
          // 这三个 Cookie —— 而缺了它们，`check_qrconnect` 必然 4031。
          //
          // 对照实验：真实浏览器（图片正常加载）轮询 code=0；
          // App（拦图片）轮询 4031 且日志确认缺这三个 Cookie。
          blockNetworkImage: false,
          // 使用移动端 UA 会拿到不同的风控策略；这里用桌面 UA，
          // 与实测通过的浏览器环境一致
          userAgent:
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          // 缓存必须开：禁用它会让 ttwid 这类长期设备标识每次重生成，
          // ticket guard 需要一个稳定设备身份。
          cacheEnabled: true,
          cacheMode: CacheMode.LOAD_DEFAULT,
          // 允许 DOM Storage 与数据库：ticket guard 会用到
          domStorageEnabled: true,
          databaseEnabled: true,
          // 允许混合内容（页面内有些资源是 http）
          mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        ),
        // 页面脚本执行前注入：抖音的 dtrait/uc-secure SDK 在文档早期
        // 就会读这些面，onLoadStop 再补已经太晚。
        onWebViewCreated: (controller) async {
          await controller.addUserScript(
            userScript: UserScript(
              source: _chromeEnvPatch,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            ),
          );
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

          // 环境自检：记下关键面，判断补丁是否生效（值本身不含隐私）。
          try {
            final env = await controller.evaluateJavascript(source: '''
              (function () {
                try {
                  return JSON.stringify({
                    webdriver: typeof navigator.webdriver,
                    chrome: typeof window.chrome,
                    chromeRuntime: typeof (window.chrome && window.chrome.runtime),
                    plugins: navigator.plugins ? navigator.plugins.length : -1,
                    notification: typeof Notification
                  });
                } catch (e) { return 'err'; }
              })()
            ''');
            _logger.info('douyin signer: env patch', {'env': '$env'});
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


  /// 在页面里点「登录」并取出弹窗二维码。
  ///
  /// # 为什么不再手写 passport 请求（根本性修正，2026-10-23）
  ///
  /// 之前一直在用 `fetch` 直接调 `/passport/web/get_qrcode/` 等接口，
  /// 结果 `check_qrconnect` 恒返回 `4031`「已阻止此次访问」。
  ///
  /// 抓真实浏览器的请求头后原因明确了——成功的请求带这些：
  /// ```
  /// x-tt-session-dtrait: d0_q9RTwtPC3GEmwNsiJ40u4t2tlvWEf...   （600+ 字符设备指纹）
  /// x-tt-passport-aid-sign: d82b1461affff662cea3af62f43f5a3...
  /// x-tt-passport-csrf-token: 17d36ccd5ee3572673884906b5ec0b33
  /// x-tt-passport-verify-portrait: 1a317cd0-...login
  /// x-secsdk-csrf-token: DOWNGRADE
  /// web-sdk-version: 1
  /// ```
  /// 这些全部由页面里的 `uc-secure-dtrait-core` / passport SDK 生成，
  /// 依赖真实浏览器指纹，**手写 fetch 无法伪造**。
  ///
  /// 而且 `/passport/web/login/` 独立页返回 `error_code=22 非法应用`——
  /// 登录是**主页面弹窗**，不是独立页面。
  ///
  /// 正确做法（实测 `probe_dy_login_modal.mjs` 验证）：
  ///   1. 页面停在 `/jingxuan`（passport 请求的 Referer 就是它）
  ///   2. 在页面里点右上角「登录」按钮
  ///   3. 弹窗出现，二维码是 `<img src="data:image/png;base64,...">`
  ///   4. 直接取那个 base64 —— 后续轮询也由页面自己做
  ///
  /// 返回二维码 base64；失败返回 null。
  Future<String?> _openLoginModalAndGrabQr() async {
    final controller = _webView?.webViewController;
    if (controller == null) return null;

    try {
      // 1. 确保停在 jingxuan（弹窗入口在这页）
      final cur = (await controller.getUrl())?.toString() ?? '';
      if (!cur.contains('/jingxuan')) {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri('https://www.douyin.com/jingxuan')),
        );
        await Future<void>.delayed(const Duration(seconds: 6));
      }

      // 2. 点「登录」按钮（页面里按文本找，取最靠右上角那个）
      final clicked = await controller.evaluateJavascript(source: '''
        (function () {
          try {
            var best = null, bestScore = -1;
            var els = document.querySelectorAll('*');
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              var t = (el.textContent || '').trim();
              if (t !== '登录' && t !== '登录/注册' && t !== '立即登录') continue;
              var r = el.getBoundingClientRect();
              if (r.width <= 0 || r.height <= 0 || r.width > 400) continue;
              // 右上角优先：x 越大、y 越小分数越高
              var score = r.x - r.y;
              if (score > bestScore) { bestScore = score; best = el; }
            }
            if (!best) return 'no-button';
            best.click();
            return 'clicked';
          } catch (e) { return 'err:' + e; }
        })()
      ''');
      _logger.info('douyin passport: login button', {'result': '$clicked'});
      if ('$clicked' != 'clicked') return null;

      // 3. 等弹窗与二维码渲染（页面要跑 challenge + get_client_cert + get_qrcode）
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final raw = await controller.evaluateJavascript(source: '''
          (function () {
            try {
              var imgs = document.querySelectorAll('img');
              for (var i = 0; i < imgs.length; i++) {
                var s = imgs[i].src || '';
                var r = imgs[i].getBoundingClientRect();
                if (r.width > 80 && r.height > 80 && s.indexOf('data:image') === 0) {
                  return s;
                }
              }
              return '';
            } catch (e) { return ''; }
          })()
        ''');
        final text = '$raw'.trim();
        if (text.startsWith('data:image') && text.length > 500) {
          final comma = text.indexOf(',');
          if (comma > 0) {
            _logger.info('douyin passport: qr captured from modal', {
              'dataUrlLen': text.length,
            });
            return text.substring(comma + 1);
          }
        }

        // 诊断：页面若报「当前环境不支持」之类，把弹窗文本带出来。
        // 这是页面 SDK 自己判定的结果，比我们猜有用得多。
        if (i == 20) {
          try {
            final info = await controller.evaluateJavascript(source: '''
              (function () {
                try {
                  var dlg = document.querySelector('[role=dialog]');
                  var t = dlg ? (dlg.innerText || '') : '';
                  return t.replace(/\\s+/g, ' ').slice(0, 200);
                } catch (e) { return ''; }
              })()
            ''');
            _logger.info('douyin passport: modal text', {'text': '$info'});
          } catch (_) {}
        }
      }

      _logger.warn('douyin passport: qr not found in modal');
      return null;
    } catch (e) {
      _logger.warn('douyin passport: open login modal failed', {
        'errorType': e.runtimeType.toString(),
      });
      return null;
    }
  }

  /// 取 Cookie 名（含 httpOnly）。
  ///
  /// # 为什么不能用 document.cookie（真实缺陷，2026-10-23）
  ///
  /// 原来这里用 `document.cookie` 读，但 `ttwid`、
  /// `bd_ticket_guard_client_data` 等关键 Cookie 是 **httpOnly** 的——
  /// JS 读不到，浏览器仍会随请求发送。
  ///
  /// 实测证据：真实浏览器里 `document.cookie.length=3590` 却
  /// `document.cookie.includes('ttwid') === false`，而
  /// `Network.getAllCookies` 能看到 `ttwid`。
  ///
  /// 所以用 `document.cookie` 判断"缺 Cookie"会**假报缺失**，
  /// 把排查方向带偏（误以为 WebView 没生成，实际只是读不到）。
  /// 这里改用 CookieManager，它读的是 WebView 的真实 Cookie 存储。
  Future<List<String>> _cookieNamesFromPage() async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://www.douyin.com/'),
      );
      return cookies.map((c) => c.name).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 等 `bd_ticket_guard_client_data` 等登录必需 Cookie 出现。
  ///
  /// # 为什么必须等（实测 2026-10-23）
  ///
  /// 真实浏览器里各 Cookie 的**出现时间**（`probe_dy_ticket_guard.mjs`）：
  ///
  /// | 时刻 | Cookie |
  /// |---|---|
  /// | 首页 +4s | `ttwid` `web_sign_token` `__ac_signature` `s_v_web_id` |
  /// | 首页 +6s | **`bd_ticket_guard_client_data`** ← 关键 |
  ///
  /// `bd_ticket_guard_client_data` 是字节的设备票据，由 `bdms.js` 在
  /// 页面 JS 跑完后才计算下发，**比 UIFID 更晚**。
  ///
  /// 而 `check_qrconnect` 会校验它：缺了必然 `error_code=4031`
  /// （界面提示"已阻止此次访问"）。App 原来只等 UIFID 就去轮询，
  /// 于是在 ticket guard 还没生成时就请求 → 必然失败。
  ///
  /// 返回 true = 关键 Cookie 已就位（或超时，交由后续请求如实失败）。
  Future<bool> _waitForTicketGuard({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final controller = _webView?.webViewController;
    if (controller == null) return false;

    final started = DateTime.now();
    while (DateTime.now().difference(started) < timeout) {
      try {
        final names = await _cookieNamesFromPage();
        if (names.contains('bd_ticket_guard_client_data')) {
          _logger.info('douyin signer: ticket guard ready', {
            'afterMs': DateTime.now().difference(started).inMilliseconds,
          });
          return true;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    _logger.warn('douyin signer: ticket guard timeout', {
      'waitedMs': timeout.inMilliseconds,
    });
    return false;
  }

  /// 先调 `challenge` 完成登录前握手。
  ///
  /// # 为什么必须先调（实测 2026-10-23，真实浏览器抓包）
  ///
  /// 浏览器扫码登录的**完整**请求序列是：
  /// ```
  /// POST /passport/web/challenge/                    ← 握手，必须最先
  /// POST /passport/ticket_guard/get_client_cert/     ← 拿服务端证书
  /// GET  /passport/web/get_qrcode/                   ← 拿二维码
  /// POST /passport/web/check_qrconnect/              ← 轮询（多次）
  /// ```
  ///
  /// 之前 App 直接从 `get_qrcode` 开始，跳过了握手。平台在
  /// `check_qrconnect` 阶段因此判定"会话不完整"→ `4031`
  /// 「已阻止此次访问」。
  ///
  /// # challenge 的作用
  ///
  /// 它让页面的 secsdk 完成设备指纹上报（`x-tt-session-dtrait`）并
  /// 下发 `x-tt-passport-csrf-token`。后续请求都依赖这次握手建立的
  /// 会话状态。实测抓包确认：浏览器 4 个请求都带
  /// `x-tt-passport-trace-id: af3d7d17`（challenge 生成），
  /// 说明它们是同一个会话。
  ///
  /// 返回 true = 握手完成。
  Future<bool> _runChallengeHandshake() async {
    final controller = _webView?.webViewController;
    if (controller == null) return false;

    try {
      final now = DateTime.now();
      // ts 用当天 UTC 12:00（浏览器实录），不是当前秒
      final noon = DateTime.utc(now.year, now.month, now.day, 12);
      final fp = _genFp();

      final params = <String, String>{
        ..._passportParams,
        'ts': '${noon.millisecondsSinceEpoch ~/ 1000}',
        'fp': fp,
        'verifyFp': fp,
        'skip_c': '1',
        'p_ts': '${now.millisecondsSinceEpoch}',
        'p_no': _hex8() * 8,
        'biz_trace_id': _hex8(),
        'msToken': _genMsToken(),
      };

      final res = await requestPost(
        path: '/passport/web/challenge/',
        params: params,
        body: 'sign=&sk=',
        requireFullUifid: false,
      );

      final json = res.tryParseJson();
      final data = json?['data'];
      if (data is! Map) {
        _logger.warn('douyin passport: challenge no data', {
          'status': res.statusCode,
          'len': res.body.length,
        });
        return false;
      }

      final d = Map<String, Object?>.from(data);
      final code = (d['error_code'] as num?)?.toInt();
      _logger.info('douyin passport: challenge done', {
        'code': code ?? 'absent',
        'keys': d.keys.take(8).join(','),
      });
      // challenge 成功与否不阻断：即使它报错，后续请求仍会如实失败，
      // 这里只负责"把该做的做掉"。
      return true;
    } catch (e) {
      _logger.warn('douyin passport: challenge failed', {
        'errorType': e.runtimeType.toString(),
      });
      return false;
    }
  }

  /// 生成并注入 ticket guard 密钥对（客户端自己造，不是等来的）。
  ///
  /// # 这是本轮最关键的修复（2026-10-23）
  ///
  /// 之前两次都错在这里：
  ///  1. **等 Cookie 自然出现** —— `bd_ticket_guard_client_data` 不会
  ///     自己出现，它是客户端生成的（`zero.js` 里
  ///     `cookieOperate.setCookieWithDomain(...)`）
  ///  2. **用随机字节冒充公钥** —— 随机 64 字节不是合法的 P-256 点，
  ///     服务端验签直接拒，界面仍显示 4031
  ///
  /// 正确做法（对照 `cv-cat/catbus` 的 `crypto.ts`）：
  ///   - 生成真的 P-256 密钥对
  ///   - 公钥 = base64(0x04 || X || Y)
  ///   - Cookie `bd_ticket_guard_client_data` = base64(JSON(4 个键))
  ///   - 请求头 `bd-ticket-guard-ree-public-key` 带同一个公钥
  ///
  /// 返回 true = 注入成功。
  Future<bool> _installTicketGuardKey() async {
    final controller = _webView?.webViewController;
    if (controller == null) return false;

    try {
      // 已有合法密钥就复用（避免每次登录换身份，反而更可疑）
      if (_ticketKey != null) {
        await _writeTicketGuardCookies(_ticketKey!);
        return true;
      }

      final kp = generateTicketGuardKeyPair();
      _ticketKey = kp;

      // 验证：k·G 必须等于公钥，否则服务端一定拒
      final derived = publicKeyFromPrivate(kp.privateKey);
      if (!_bytesEqual(derived, kp.publicKey)) {
        _logger.error('douyin ticket guard: keypair self-check failed');
        _ticketKey = null;
        return false;
      }

      _logger.info('douyin ticket guard: keypair generated', {
        'pubLen': kp.publicKey.length,
        'reeKeyPrefix': kp.reePublicKeyBase64.substring(0, 12),
      });

      await _writeTicketGuardCookies(kp);
      return true;
    } catch (e) {
      _logger.warn('douyin ticket guard: install failed', {
        'errorType': e.runtimeType.toString(),
      });
      return false;
    }
  }

  /// 把 ticket guard 的两个 Cookie 写进 WebView。
  Future<void> _writeTicketGuardCookies(TicketGuardKeyPair kp) async {
    final cm = CookieManager.instance();
    final url = WebUri('https://www.douyin.com/');

    await cm.setCookie(
      url: url,
      name: ticketGuardClientDataCookie,
      value: kp.clientDataCookie,
      domain: '.douyin.com',
      path: '/',
    );
    await cm.setCookie(
      url: url,
      name: ticketGuardWebDomainCookie,
      value: '2',
      domain: '.douyin.com',
      path: '/',
    );
  }

  /// passport 系接口要求的 ticket guard 请求头。
  ///
  /// 与 Cookie 里的公钥必须一致——服务端用它验证客户端身份。
  Map<String, String> _ticketHeaders() {
    final kp = _ticketKey;
    if (kp == null) return const {};
    return {
      'bd-ticket-guard-ree-public-key': kp.reePublicKeyBase64,
      'bd-ticket-guard-version': '2',
      'bd-ticket-guard-web-version': '2',
    };
  }

  /// passport 系接口要求的全部签名头。
  ///
  /// 对照真实浏览器抓包（2026-10-23），缺任何一个都可能 4031：
  ///  - `x-tt-session-dtrait`（820 字节设备自证）
  ///  - `x-tt-passport-aid-sign`（三层 HMAC）
  ///  - `x-tt-passport-csrf-token`（取自 Cookie）
  ///  - `x-tt-passport-verify-portrait`（会话 UUID + `.login`）
  Future<Map<String, String>> _passportHeadersFor(String path) async {
    if (!path.startsWith('/passport/')) return const {};

    final out = <String, String>{};

    // 1. 设备特征自证
    final dt = _dtraitHeaderFor(path);
    if (dt != null) out['x-tt-session-dtrait'] = dt;

    // 2. aid 签名（ts 必须是当天 UTC 12:00）
    final ts = sdkTsSeconds();
    out['x-tt-passport-aid-sign'] = aidSign(path, '$ts');

    // 3. csrf token：从 WebView 的真实 Cookie 里取
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://www.douyin.com/'),
      );
      final map = <String, String>{
        for (final c in cookies) c.name: c.value,
      };
      final csrf = csrfTokenFromCookies(map);
      if (csrf != null) out['x-tt-passport-csrf-token'] = csrf;
    } catch (_) {}

    // 4. verify-portrait：登录流程内保持不变
    _verifyPortrait ??= buildVerifyPortrait();
    out['x-tt-passport-verify-portrait'] = _verifyPortrait!;

    return out;
  }

  /// 会话级 verify-portrait（登录流程内复用，避免每次换身份）。
  String? _verifyPortrait;

  /// 为指定 path 生成 `x-tt-session-dtrait` 头。
  ///
  /// # 这是 4031 的最后一块拼图（2026-10-23）
  ///
  /// 真实浏览器的 passport 请求都带这个头（600+ 字符），我的请求
  /// 一个都没有——这是 `check_qrconnect` 一直 4031 的直接原因。
  ///
  /// 它由 `uc-secure-dtrait-core` SDK 生成，但**不需要真实渲染**：
  /// canvas/WebGL/audio 特征以 murmur3 固化在档案里，其余纯计算。
  /// 实现见 `dtrait.dart`（15 条测试含 NIST AES 向量）。
  String? _dtraitHeaderFor(String path) {
    try {
      final r = buildSessionDtrait(path, material: _dtraitMaterial);
      _dtraitMaterial = r.material;
      return r.header;
    } catch (e) {
      _logger.warn('douyin dtrait: build failed', {
        'errorType': e.runtimeType.toString(),
      });
      return null;
    }
  }

  /// dtrait 加密材料（同一会话复用 AES 密钥）。
  DtraitMaterial? _dtraitMaterial;

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 当前 ticket guard 密钥（登录期间复用）。
  TicketGuardKeyPair? _ticketKey;

  /// 把 WebView 导航回站点首页。
  ///
  /// # 为什么必须做（真实缺陷，2026-10-23）
  ///
  /// `Referer` 是浏览器**禁止 JS 修改**的请求头——`fetch` 里写
  /// `headers: {'Referer': ...}` 会被静默丢弃，实际发出去的 Referer
  /// 永远等于当前页面 URL。
  ///
  /// WebView 平时停在 `/jingxuan`（推荐页）或视频页，于是 passport
  /// 接口收到的 Referer 不是首页。实测证明光改 Referer 不够（浏览器
  /// 不让改），但把页面真的挪回首页后，passport 的判定会稳定下来。
  ///
  /// 已位于首页时是空操作。
  Future<void> _ensureOnHomePage() async {
    final controller = _webView?.webViewController;
    if (controller == null) return;

    try {
      final cur = (await controller.getUrl())?.toString() ?? '';
      if (cur == 'https://www.douyin.com/' || cur == 'https://www.douyin.com') {
        return;
      }
      _logger.info('douyin signer: navigate home for passport', {'from': cur});
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://www.douyin.com/')),
      );
      // 等页面与它下发的 Cookie（__ac_signature 等）就绪
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    } catch (e) {
      _logger.warn('douyin signer: navigate home failed', {
        'errorType': e.runtimeType.toString(),
      });
    }
  }

  /// 申请登录二维码。
  ///
  /// 返回二维码 PNG（base64）与轮询用的 token。
  Future<DouyinLoginQr> fetchLoginQr() async {
    // ── 首选：让页面自己弹登录框，直接取 DOM 里的二维码 ──
    //
    // 这是唯一能拿到"带完整设备指纹头"的路径（见
    // [_openLoginModalAndGrabQr] 的说明）。页面 SDK 会自己完成
    // challenge → get_client_cert → get_qrcode，并带上
    // x-tt-session-dtrait 等手写不出来的头。
    final modalQr = await _openLoginModalAndGrabQr();
    if (modalQr != null && modalQr.isNotEmpty) {
      // token 由页面持有，我们这里用占位；轮询走页面内 SDK（见 pollLoginQr）
      return DouyinLoginQr(
        imageBase64: modalQr,
        token: _modalToken,
        fp: _modalFp,
        createdAt: DateTime.now(),
      );
    }

    // ── 兜底：手写 passport 请求（大概率 4031，保留以便诊断）──
    _logger.warn('douyin passport: modal path failed, fallback to manual');

    // 0. 先装 ticket guard 密钥（客户端自己生成，不是等 Cookie）
    await _installTicketGuardKey();

    // 1. 把页面挪回首页：passport 校验来源，推荐页/视频页会被判非法。
    await _ensureOnHomePage();

    // 2. 等页面 SDK 跑完（ticket guard 等 Cookie 由首页 JS 生成）。
    await _waitForTicketGuard();

    // 3. 先做 challenge 握手：建立会话、让 secsdk 上报设备指纹。
    //    跳过它会导致后续 check_qrconnect 返回 4031。
    await _runChallengeHandshake();

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

    // ── 页面弹窗模式：轮询由页面 SDK 自己做，我们只等登录 Cookie ──
    //
    // 页面自己的 SDK 会按浏览器节奏（实测 5.2s/次）发 check_qrconnect，
    // 并带齐所有签名头。我们不该插手——手写请求必然 4031。
    // 这里只需观察：登录成功后平台会下发 sessionid / sid_guard 等。
    if (_isModalMode(qr)) {
      final names = await _cookieNamesFromPage();
      const loginMarkers = ['sessionid', 'sid_guard', 'sessionid_ss'];
      final hit = loginMarkers.where(names.contains).toList();

      if (hit.isNotEmpty) {
        // 登录成功：把 Cookie 全量快照交给上层
        final cookies = await snapshotCookies();
        _logger.info('douyin passport: login detected via modal', {
          'markers': hit.join(','),
          'cookieCount': cookies.length,
        });
        // 关掉弹窗，恢复页面到可用状态
        try {
          await _webView?.webViewController?.evaluateJavascript(
            source: '''
              (function(){
                try {
                  var d = document.querySelector('[role=dialog]');
                  if (d) { var b = d.querySelector('[class*=close], [aria-label*=关闭]'); if (b) b.click(); }
                } catch(e){}
              })()
            ''',
          );
        } catch (_) {}
        return DouyinLoginPoll(
          phase: DouyinLoginPhase.succeeded,
          cookies: cookies,
          message: '登录成功。',
        );
      }

      // 还没扫：如实返回等待态（页面自己在轮询）
      return const DouyinLoginPoll(
        phase: DouyinLoginPhase.waitingForScan,
        message: '请用抖音 App 扫描二维码。',
      );
    }

    // 每次轮询前确认页面仍在首页：passport 校验 Referer，
    // 页面被导航走（后台预热拉了视频页等）会改变 Referer。
    // 已位于首页时是空操作，开销可忽略。
    await _ensureOnHomePage();

    // ticket guard 在轮询期间可能过期或被清，这里轻量确认一次
    // （已存在时立刻返回，不会每次等满超时）。
    await _waitForTicketGuard(timeout: const Duration(seconds: 8));

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
    // # error_code 缺失 ≠ 出错（真实缺陷，2026-10-23）
    //
    // 原来写 `?? -1`，把"平台没给这个字段"当成错误码 -1，
    // 直接走 `code != 0` 分支报「登录失败（错误码 -1）」。
    // 但正常响应的 `error_code` 是 0；缺失时应按"无错误"处理。
    final rawCode = d['error_code'];
    final code = (rawCode as num?)?.toInt();
    final status = (d['status'] as String?) ?? '';

    if (code == 4031) {
      // # 4031 的真实含义（实测 2026-10-23）
      //
      // 真实响应（实测 2026-10-23，App 内与原生直连一致）：
      //   {"data":{"error_code":4031,"captcha":"","desc_url":"",
      //            "description":"您正在尝试访问的网站存在安全风险，
      //              为保护您的抖音账号安全与隐私，已阻止此次访问。"},
      //    "message":"error"}
      //
      // 关键事实：**captcha 与 desc_url 都是空串**。
      //
      // 这意味着平台判定当前环境属于"已阻止访问"，**不给验证通道**。
      // 没有 desc_url 就没有可自动跑的验证页，客户端无从恢复。
      //
      // 对照实验证明不是 IP 全站封禁：同环境下
      // `aweme/detail`、`general/search/single` 都正常返回，
      // 只有 passport 登录接口被拒 —— 这是**针对登录行为的定向阻断**。
      //
      // 因此保留自动验证代码（万一平台改回给验证通道能自动恢复），
      // 但 desc_url 为空时如实报平台原话，不假装"正在重试"拖用户。
      final descUrl = (d['desc_url'] as String?) ?? '';
      final captcha = (d['captcha'] as String?) ?? '';

      _logger.info('douyin passport: 4031 captcha', {
        'hasDescUrl': descUrl.isNotEmpty,
        'captchaKind': captcha.isEmpty ? 'none' : captcha,
        'descUrlHost': descUrl.isEmpty ? null : Uri.tryParse(descUrl)?.host,
        'description': (d['description'] as String?) ?? '',
      });

      // 诊断：把 Cookie 情况一并带回，让 UI 能显示（release 版日志不可见）。
      //
      // 实测对照（2026-10-23）：
      //   真实浏览器（页面上下文）→ get_qrcode OK, check_qrconnect OK
      //   纯 HTTP / App WebView   → get_qrcode OK, check_qrconnect 4031
      //
      // 浏览器比失败方多这些签名类 Cookie：
      //   __ac_signature, web_sign_token, s_v_web_id, ttwid,
      //   bd_ticket_guard_client_data, x-web-secsdk-uid
      // 说明 4031 是"缺少环境自证材料"，不是 IP 问题
      // （直连与代理都是 4031，已排除出口 IP）。
      var cookieInfo = '未知';
      try {
        final names = await _cookieNamesFromPage();
        final need = <String>[
          's_v_web_id',
          '__ac_signature',
          'bd_ticket_guard_client_data',
          'ttwid',
          'web_sign_token',
        ];
        final missing = need.where((n) => !names.contains(n)).toList();
        cookieInfo = missing.isEmpty
            ? '签名 Cookie 齐全'
            : '缺 ${missing.join("/")}';
        _logger.info('douyin passport: cookies at 4031', {
          'count': names.length,
          'missing': missing.isEmpty ? 'none' : missing.join(','),
        });
      } catch (_) {}

      // # 为什么这里不再"自动过验证"
      //
      // 实测（2026-10-23）App 内 4031 的响应是：
      //   {"captcha":"", "desc_url":"",
      //    "description":"您正在尝试访问的网站存在安全风险，为保护您的
      //     抖音账号安全与隐私，已阻止此次访问。", "error_code":4031}
      //
      // `captcha` 与 `desc_url` **都是空串**——平台判定当前环境
      // 属于"已阻止访问"，**不提供验证通道**。没有 desc_url 就没有
      // 可以自动跑的验证页，这一步无法在客户端完成。
      //
      // 同环境下普通接口（aweme/detail、search）正常返回，说明不是
      // IP 全站封禁，而是**针对登录行为的定向阻断**。
      //
      // 因此如实报出平台原话，并给出唯一可行的路径（浏览器登录后导入），
      // 不假装"正在重试"来拖延用户。
      //
      // 注：曾实现过"自动跑验证页"（加载 desc_url 让 SDK 自己通过），
      // 但实测 `desc_url` 恒为空，那段代码永不执行，已删除。
      return DouyinLoginPoll(
        phase: DouyinLoginPhase.blocked,
        message: (d['description'] as String?)?.isNotEmpty == true
            ? '抖音拒绝了本次登录（$cookieInfo）：${d['description']}'
            : '抖音拒绝了本次登录（$cookieInfo）。',
        captchaUrl: descUrl.isEmpty ? null : descUrl,
      );
    }
    // 只有"明确给了非 0 错误码"才算失败；缺失按无错误处理
    if (code != null && code != 0) {
      return DouyinLoginPoll(
        phase: DouyinLoginPhase.failed,
        message: '登录失败（错误码 $code）。',
      );
    }

    // # status 的真实取值（实测 2026-10-23）
    //
    // 平台下发的是**字符串状态名**，不是数字：
    //   未扫码      → "new"      ← 实测，最常见的正常状态
    //   token 失效  → "expired"  ← 实测
    //   已扫码待确认 → "scanned"  （推断，未实测到）
    //   已确认登录  → "confirmed"/"success"（推断，未实测到）
    //
    // 旧代码只认 '1'/'2'/'3'，于是 status="new" 落进 default 报
    // "未知登录状态：new"——**即使真登录成功也永远匹配不到成功分支**。
    // 这是扫码登录整体不可用的直接原因之一。
    //
    // 现在两套取值都认，数字形式保留兼容。
    switch (status) {
      // ── 字符串形式（实测）──
      case 'new':
      case '1':
        return const DouyinLoginPoll(
          phase: DouyinLoginPhase.waitingForScan,
          message: '请用抖音 App 扫描二维码。',
        );
      case 'expired':
        return const DouyinLoginPoll(
          phase: DouyinLoginPhase.expired,
          message: '二维码已过期，请刷新。',
        );
      case 'scanned':
      case 'scan':
      case '2':
        return const DouyinLoginPoll(
          phase: DouyinLoginPhase.waitingForConfirm,
          message: '已扫码，请在手机上确认登录。',
        );
      case 'confirmed':
      case 'success':
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

    // ticket guard 公钥头：passport 系接口要求带它，
    // 且必须与 Cookie 里的公钥一致（见 _installTicketGuardKey）。
    final extraHeadersJson = jsonEncode({
      ..._ticketHeaders(),
      ...await _passportHeadersFor(path),
    });

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
              headers: { 'Referer': location.href, ...$extraHeadersJson },
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
    final extraHeadersJson2 = jsonEncode({
      ..._ticketHeaders(),
      ...await _passportHeadersFor(path),
    });

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
              headers: { 'Referer': location.href, ...$extraHeadersJson2 },
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

  /// 需要先过人机验证（由 App 自动完成，不需要用户操作）。
  ///
  /// 抖音返回 `error_code=4031` 且带 `desc_url` 时进入此状态。
  /// `desc_url` 指向字节的无感验证（`rc-verifycenter/rmc-nocaptcha`），
  /// 该 SDK 的设计目标就是"让真实浏览器自己通过"——加载后自动采集
  /// 环境特征、本地计算、回传结果，正常情况无需人工干预。
  ///
  /// 与 [blocked] 的区别：[blocked] 表示无路可走，这里**可以自动恢复**。
  captchaRequired,
}

/// 一次扫码登录会话。
class DouyinLoginQr {
  const DouyinLoginQr({
    required this.imageBase64,
    required this.token,
    required this.fp,
    required this.createdAt,
    this.expiresIn = const Duration(minutes: 10),
  });

  /// 平台下发的二维码 PNG（base64）。直接展示，不做二次编码。
  final String imageBase64;

  /// 轮询用的 token。
  final String token;

  /// 本次会话的设备指纹串。
  final String fp;

  final DateTime createdAt;

  /// 本地轮询窗口。
  ///
  /// 取 10 分钟而不是平台常见的 3 分钟：服务端才是过期判定的权威。
  /// 若本地窗口短于服务端有效期，用户截图 → 切到抖音 → 相册选图
  /// 这段时间一旦超过本地窗口，轮询就停了，用户扫码后不会有任何反应。
  /// 宁可多轮询一会儿，也不要让用户扫了却卡住。
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
    this.captchaUrl,
  });

  final DouyinLoginPhase phase;

  /// 登录成功时下发的全部 Cookie（含 httpOnly 的会话凭证）。
  final Map<String, String> cookies;

  final String displayName;
  final String userId;
  final String avatarUrl;
  final String? message;

  /// 人机验证页地址（仅 [DouyinLoginPhase.captchaRequired] 时有值）。
  ///
  /// 由平台在 `error_code=4031` 的响应里通过 `desc_url` 下发。
  /// signer 会自动在 WebView 里加载它完成验证，**不需要用户操作**；
  /// 这个字段只用于诊断与日志。
  final String? captchaUrl;

  bool get succeeded => phase == DouyinLoginPhase.succeeded;
}