/// 抖音移动端网页登录方式探测。
///
/// # 要回答什么
///
/// 用户只有一台设备时，扫码不可行（不能自己扫自己屏幕），
/// 图库扫码被抖音安全策略拒绝。
///
/// 若移动端网页提供「打开抖音 App 授权登录」（URL scheme 深链），
/// 同一台手机就能完成登录：网页 → 唤起抖音 → 用户确认 → 回到网页拿到会话。
///
/// 本测试用移动端 UA 加载 douyin.com，检查：
///  1. 页面上是否有登录入口
///  2. 是否出现抖音的 URL scheme（snssdk / douyin:// / aweme://）
///  3. 登录后 cookie 是否含会话凭证
library;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _mobileUa =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('移动端网页是否支持唤起抖音授权', (tester) async {
    final schemes = <String>{};
    final pageTexts = <String>[];

    final webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('https://www.douyin.com/')),
      initialSettings: InAppWebViewSettings(
        userAgent: _mobileUa,
        javaScriptEnabled: true,
        thirdPartyCookiesEnabled: true,
        cacheEnabled: false,
      ),
      shouldOverrideUrlLoading: (controller, action) async {
        final url = action.request.url?.toString() ?? '';
        final scheme = Uri.tryParse(url)?.scheme ?? '';
        if (scheme.isNotEmpty && scheme != 'http' && scheme != 'https') {
          schemes.add('$scheme://');
        }
        return NavigationActionPolicy.ALLOW;
      },
    );

    await webView.run();
    await Future<void>.delayed(const Duration(seconds: 12));

    final controller = webView.webViewController;
    if (controller == null) {
      // ignore: avoid_print
      print('[web] controller 为空，跳过');
      await webView.dispose();
      return;
    }

    // 页面可见文本
    final text = await controller.evaluateJavascript(
      source: 'document.body ? document.body.innerText.slice(0, 1200) : ""',
    );
    pageTexts.add('$text');

    // DOM 里出现的 scheme
    final domSchemes = await controller.evaluateJavascript(
      source: r'''
        (function(){
          var out = [];
          var re = /(snssdk\d*|douyin|aweme|sslocal):\/\/[^\s"'<>]*/g;
          var html = document.documentElement.outerHTML;
          var m; while ((m = re.exec(html)) !== null) { out.push(m[0]); }
          return out.slice(0, 20).join('\n');
        })()
      ''',
    );

    // ignore: avoid_print
    print('[web] url = ${await controller.getUrl()}');
    // ignore: avoid_print
    print('[web] 页面文本前 400 字：\n${'$text'.substring(0, 400.clamp(0, '$text'.length))}');
    // ignore: avoid_print
    print('[web] DOM 里的 scheme 数：$schemes');
    // ignore: avoid_print
    print('[web] DOM scheme 命中：${'$domSchemes'}');

    // cookie
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri('https://www.douyin.com'),
    );
    final names = cookies.map((e) => e.name).toList();
    // ignore: avoid_print
    print('[web] cookie 名：${names.join(", ")}');

    await webView.dispose();
  });
}
