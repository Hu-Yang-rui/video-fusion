/// 用应用的真实参数集取码并轮询，打印原始响应。
///
/// 最小参数集会拿到 4031；应用用的是完整 passport 参数集。
/// 本测试直接调 signer 的取码方法，再用同参数集手工轮询。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_fusion/src/adapters/douyin/web_signer.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('取码 + 手工轮询并打印原始响应', (tester) async {
    final signer = DouyinWebSigner(logger: FusionLogger(enabled: false));
    final ready = await signer.ensureReady();
    if (!ready) {
      // ignore: avoid_print
      print('[full] 页面未就绪');
      return;
    }

    DouyinLoginQr qr;
    try {
      qr = await signer.fetchLoginQr();
      // ignore: avoid_print
      print('[full] 取码成功 token=${qr.token.substring(0, 8)}… '
          'imageLen=${qr.imageBase64.length}');
    } catch (e) {
      // ignore: avoid_print
      print('[full] 取码失败: ${'$e'.split('\n').first}');
      return;
    }

    // 与 signer 内部一致的参数集
    final params = <String, String>{
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
      'ts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'fp': qr.fp,
      'verifyFp': qr.fp,
      'p_ts': '${DateTime.now().millisecondsSinceEpoch}',
    };

    for (var i = 1; i <= 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      params['ts'] = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      params['p_ts'] = '${DateTime.now().millisecondsSinceEpoch}';

      final res = await signer.requestPost(
        path: '/passport/web/check_qrconnect/',
        params: params,
        body: 'need_logo=false&is_frontier=true'
            '&token=${qr.token}'
            '&is_new_login=1&next=https%3A%2F%2Fwww.douyin.com'
            '&need_short_url=true',
        requireFullUifid: false,
      );
      // ignore: avoid_print
      print('[full] poll#$i status=${res.statusCode} 原始=${res.body}');
    }

    // 同时看 signer 自己的判定
    final v = await signer.pollLoginQr(qr);
    // ignore: avoid_print
    print('[full] signer 判定 phase=${v.phase} message=${v.message}');
  });
}
