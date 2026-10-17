/// 抖音评论的 WebView 签名桥。
///
/// # 为什么需要这一层
///
/// 抖音的评论接口 `/aweme/v1/web/comment/list/` 需要三样东西：
///
///  1. `a_bogus` 签名（由页面加载的 `bdms.js` 生成）
///  2. `x-secsdk-web-signature`（`md5(uifid_ts_SALT_query)`）
///  3. `uifid` Cookie（**只能由真实浏览器会话下发**）
///
/// 前两项可以纯客户端计算，但第三项 `uifid` 是平台风控在真实浏览器环境
/// 完成初始化后才写入的。伪造的 `uifid` 会让接口返回 HTTP 200 + 空响应体
/// （实测：签名正确但 uifid 伪造 → 0 字节）。
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
/// 然后把结果读出来。
///
/// # 边界
///
///  - 不注入任何模拟/伪造脚本（仅去掉 `navigator.webdriver` 标记，
///    因为无头容器本身会带上该标记，而平台会据此判定为自动化）
///  - 不提交任何表单、不登录、不上传用户数据
///  - WebView 不显示给用户，也不参与视频播放
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/errors.dart';
import '../../core/logger.dart';

/// 一次评论请求的结果。
class DouyinCommentResponse {
  const DouyinCommentResponse({
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

  HeadlessInAppWebView? _webView;
  bool _ready = false;
  bool _initializing = false;
  Completer<bool>? _initCompleter;

  bool get isReady => _ready;

  /// 启动隐藏 WebView 并等待风控就绪。
  ///
  /// 加载一个真实视频页（而不是首页），因为视频页会触发评论相关的
  /// SDK 初始化；只加载首页时部分签名模块不会被激活。
  Future<bool> ensureReady({String? awemeId}) async {
    if (_ready && _webView != null) return true;
    if (_initializing) {
      return _initCompleter?.future ?? false;
    }

    _initializing = true;
    _initCompleter = Completer<bool>();

    try {
      final target = awemeId != null
          ? 'https://www.douyin.com/video/$awemeId'
          : 'https://www.douyin.com/';

      _logger.info('douyin signer: launching headless webview', {
        'target': target,
      });

      final webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(target)),
        initialSettings: InAppWebViewSettings(
          // 允许跨域请求：评论接口在 www.douyin.com 同源下，
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
            // 移除自动化标记（在页面脚本执行前注入更可靠，
            // 但 HeadlessInAppWebView 的 onLoadStop 时机同样有效）
            await controller.evaluateJavascript(
              source: '''
                try {
                  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
                } catch (e) {}
              ''',
            );
          } catch (_) {}

          // 等待风控 SDK 完成初始化并下发 uifid。
          // 实测：桌面 Chrome 约 1 秒内下发；WebView 可能稍慢，
          // 因此轮询 document.cookie 最多 15 秒。
          final hasUifid = await _waitForUifid(controller);
          _ready = hasUifid;

          if (!_initCompleter!.isCompleted) {
            _initCompleter!.complete(hasUifid);
          }
        },
        onReceivedError: (controller, request, error) {
          _logger.warn('douyin signer: load error', {
            'url': request.url.toString(),
            'desc': error.description,
          });
          if (!_initCompleter!.isCompleted) {
            _initCompleter!.complete(false);
          }
        },
      );

      await webView.run();
      _webView = webView;

      final ok = await _initCompleter!.future.timeout(
        const Duration(seconds: 40),
        onTimeout: () {
          _logger.warn('douyin signer: init timeout');
          return false;
        },
      );

      if (!ok) {
        _logger.warn('douyin signer: not ready (no uifid)');
      } else {
        _logger.info('douyin signer: ready');
      }

      return ok;
    } catch (e) {
      _logger.error('douyin signer: init failed', {'error': '$e'});
      if (!(_initCompleter?.isCompleted ?? true)) {
        _initCompleter?.complete(false);
      }
      return false;
    } finally {
      _initializing = false;
    }
  }

  /// 轮询 `document.cookie` 直到出现 uifid。
  Future<bool> _waitForUifid(InAppWebViewController controller) async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final cookie = await controller.evaluateJavascript(
          source: 'document.cookie',
        );
        final text = '$cookie';
        if (RegExp(r'uifid', caseSensitive: false).hasMatch(text)) {
          _logger.info('douyin signer: uifid present', {'afterMs': i * 500});
          return true;
        }
      } catch (e) {
        _logger.debug('douyin signer: cookie probe failed', {'error': '$e'});
      }
    }
    return false;
  }

  /// 在页面上下文里发一次请求。
  ///
  /// 页面的 `bdms.js` 已劫持 `fetch`，会自动附加 `a_bogus` 与
  /// `x-secsdk-web-signature`，因此这里不需要自己算签名。
  Future<DouyinCommentResponse> request({
    required String path,
    required Map<String, String> params,
  }) async {
    final webView = _webView;
    if (webView == null || !_ready) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话尚未就绪，请稍后重试。',
        technicalMessage: 'DouyinWebSigner not ready',
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

    // 用 JSON 传参，避免字符串拼接导致注入或转义问题
    final paramsJson = jsonEncode(params);
    final pathJson = jsonEncode(path);


    // 关键：evaluateJavascript 不会 await Promise。
    // 直接 return 一个 async IIFE 会得到 "[object Promise]" 之类的字符串，
    // 而不是解析结果。
    //
    // 正确做法：让脚本把结果写入一个全局变量，然后轮询该变量。
    // 或者用 callAsyncJavaScript（部分平台支持）。
    //
    // 这里采用"全局变量 + 轮询"：兼容性最好，不依赖平台实现差异。
    final token = 'dy_${DateTime.now().microsecondsSinceEpoch}';
    final runner = '''
      (function () {
        window['$token'] = null;
        (async () => {
          try {
            const path = $pathJson;
            const params = $paramsJson;
            const p = new URLSearchParams(params);
            const url = 'https://www.douyin.com' + path + '?' + p.toString();
            const res = await fetch(url, {
              method: 'GET',
              credentials: 'include',
              headers: { 'Referer': location.href },
            });
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
    _ready = false;
    final webView = _webView;
    _webView = null;
    if (webView != null) {
      try {
        await webView.dispose();
      } catch (_) {}
    }
  }
}
