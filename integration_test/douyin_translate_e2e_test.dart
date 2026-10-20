/// 抖音评论翻译接口的端到端验证。
///
/// # 目的
///
/// 摸清 `/aweme/v1/web/comment/translate/` 与
/// `/aweme/v1/web/text/translate/` 在**真实 WebView 会话**下
/// 到底返回什么。
///
/// # 与之前探针的区别
///
/// 之前的 `tool/probe_douyin_translate.dart` 用纯 Dart `ABogus` 算签名，
/// 结果全是 `blocked`（7 字节）。但那**没有 WebView 会话**——
/// 缺 UIFID、缺 secsdk 环境、缺页面级 cookie。
///
/// 本测试走项目自己的 `DouyinWebSigner`，它在隐藏 WebView 里
/// 发请求，自带完整会话与签名。这是唯一能判定"接口是否可用"的路径。
///
/// # 运行
///
/// ```bash
/// flutter test integration_test/douyin_translate_e2e_test.dart
/// ```
///
/// 需要能访问抖音的网络。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_fusion/src/adapters/douyin/web_signer.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('抖音评论翻译：真实 WebView 会话下接口返回什么', (tester) async {
    final logger = FusionLogger(enabled: true);
    final adapter = DouyinAdapter(
      http: FusionHttpClient(logger: logger),
      logger: logger,
    );

    // 用一条真实视频的评论做样本（22.8 万条评论）
    const awemeId = '7690992782325240232';

    // ignore: avoid_print
    print('=== 1. 拉一条真实评论作为样本 ===');
    final page = await adapter.fetchComments(awemeId, page: 1, pageSize: 5);
    expect(page.items, isNotEmpty, reason: '先要拿到真实评论才能测翻译');

    final sample = page.items.first;
    // ignore: avoid_print
    print('  评论 ID: ${sample.id}');
    // ignore: avoid_print
    print('  内容: ${sample.message.length > 40 ? '${sample.message.substring(0, 40)}…' : sample.message}');
    // ignore: avoid_print
    print('  作者: ${sample.authorName}');

    await adapter.disposeComments();

    // ignore: avoid_print
    print('\n=== 2. 直接打翻译接口（复用适配器内部签名会话） ===');

    // 用适配器的内部签名器发请求。DouyinAdapter 没暴露 signer，
    // 这里单独建一个，行为一致（同一个 WebView 通道）。
    final signer = DouyinWebSigner(logger: logger);
    final ready = await signer.ensureReady(awemeId: awemeId);
    // ignore: avoid_print
    print('  签名会话就绪: $ready  等级: ${signer.readiness.name}');

    if (!ready) {
      // ignore: avoid_print
      print('  ⚠ 签名会话未就绪，无法继续。这是环境问题，不是接口问题。');
      await signer.dispose();
      return;
    }

    // ── 2.1 评论翻译（POST）
    // ignore: avoid_print
    print('\n  [2.1] POST /aweme/v1/web/comment/translate/');
    try {
      final res = await signer.requestPost(
        path: '/aweme/v1/web/comment/translate/',
        params: const {},
        body:
            '{"comment_id":"${sample.id}","target_language":"en",'
            '"comment_text":"${_escape(sample.message)}",'
            '"comment_text_extra":""}',
        contentType: 'application/json',
        requireFullUifid: false,
      );
      // ignore: avoid_print
      print('    status_code=${res.statusCode}');
      // ignore: avoid_print
      print('    body=${_truncate(res.body)}');
    } catch (e) {
      // ignore: avoid_print
      print('    抛异常: ${'$e'.split('\n').first}');
    }

    // ── 2.2 通用文本翻译（GET）
    // ignore: avoid_print
    print('\n  [2.2] GET /aweme/v1/web/text/translate/');
    try {
      final res = await signer.request(
        path: '/aweme/v1/web/text/translate/',
        params: {
          'source_text': sample.message,
          'target_language': 'en',
        },
        requireFullUifid: false,
      );
      // ignore: avoid_print
      print('    status_code=${res.statusCode}');
      // ignore: avoid_print
      print('    body=${_truncate(res.body)}');
    } catch (e) {
      // ignore: avoid_print
      print('    抛异常: ${'$e'.split('\n').first}');
    }

    // ── 2.3 对照组：确认会话本身是通的
    // ignore: avoid_print
    print('\n  [2.3] 对照组 GET /aweme/v1/web/comment/list/（已知可用）');
    try {
      final res = await signer.request(
        path: '/aweme/v1/web/comment/list/',
        params: {
          'aweme_id': awemeId,
          'cursor': '0',
          'count': '1',
          'item_type': '0',
        },
        requireFullUifid: false,
      );
      // ignore: avoid_print
      print('    status_code=${res.statusCode}  body 长度=${(res.body).length}');
    } catch (e) {
      // ignore: avoid_print
      print('    抛异常: ${'$e'.split('\n').first}');
    }

    await signer.dispose();
    // ignore: avoid_print
    print('\n=== 完成 ===');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String _escape(String s) =>
    s.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n');

String _truncate(String s, [int n = 300]) =>
    s.length <= n ? s : '${s.substring(0, n)}…（共 ${s.length} 字节）';
