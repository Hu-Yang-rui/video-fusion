// 抖音翻译接口探针。
//
// # 目的
//
// 验证抖音是否自带评论翻译能力，从而判断「把 B站 评论翻译接到抖音」
// 这件事本身是否还有必要。
//
// # 背景
//
// 从 155 个前端 bundle 里挖到两个路径（s86.js）：
//
// ```js
// // 通用文本翻译（U2 = GET）
// GET /aweme/v1/web/text/translate/?source_text={文本}&target_language={语言}
//
// // 评论翻译（v_ = POST）
// POST /aweme/v1/web/comment/translate/
//   body: { comment_id, target_language, comment_text, comment_text_extra }
// ```
//
// 裸请求（无签名）两个都返回 `blocked`（7 字节）——
// 说明网关层拦下了，不是接口不存在。
//
// 本探针用项目的 `ABogus`（纯 Dart）算签名，看能否拿到真实响应。
//
// # 跑法
//
// ```bash
// dart run tool/probe_douyin_translate.dart
// ```

import 'dart:convert';
import 'dart:io';

import 'package:video_fusion/src/adapters/douyin/_abogus.dart';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 抖音 Web 端的公共参数（与项目里 `_detailParams` 同源）。
Map<String, String> _baseParams() => {
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'pc_client_type': '1',
      'version_code': '190500',
      'version_name': '19.5.0',
      'cookie_enabled': 'true',
      'screen_width': '1920',
      'screen_height': '1080',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '124.0.0.0',
      'browser_online': 'true',
      'engine_name': 'Blink',
      'engine_version': '124.0.0.0',
      'os_name': 'Windows',
      'os_version': '10',
      'cpu_core_num': '8',
      'device_memory': '8',
      'platform': 'PC',
      'downlink': '10',
      'effective_type': '4g',
      'round_trip_time': '0',
      'webid': '7500000000000000000',
      'uifid': '',
      'msToken': '',
    };

String _encodeQuery(Map<String, String> p) => p.entries
    .map((e) =>
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
    .join('&');

Future<void> _probe({
  required String label,
  required String path,
  required Map<String, String> params,
  String? body,
  String method = 'GET',
}) async {
  final abogus = ABogus(userAgent: _ua);
  final query = _encodeQuery(params);
  final signed = abogus.getValue(query, body: body ?? '');
  final url = 'https://www.douyin.com$path?$query&a_bogus=${Uri.encodeQueryComponent(signed)}';

  try {
    final client = HttpClient();
    final req = await client.openUrl(method, Uri.parse(url));
    req.headers.set('user-agent', _ua);
    req.headers.set('accept', 'application/json');
    req.headers.set('referer', 'https://www.douyin.com/');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(body);
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();

    var code = '?';
    var msg = '';
    try {
      final j = jsonDecode(text) as Map<String, Object?>;
      code = '${j['status_code'] ?? j['code'] ?? '?'}';
      msg = '${j['status_msg'] ?? j['message'] ?? ''}';
    } catch (_) {}

    // ignore: avoid_print
    print('$label'.padRight(18) +
        '${res.statusCode}  len=${text.length.toString().padLeft(5)}  '
            'code=$code  ${msg.length > 40 ? msg.substring(0, 40) : msg}');
    if (text.length > 30 && text.length < 600) {
      // ignore: avoid_print
      print('   ${text.replaceAll('\n', ' ')}');
    }
  } catch (e) {
    // ignore: avoid_print
    print('$label'.padRight(18) + 'FAIL  ${'$e'.split('\n').first}');
  }
}

Future<void> main() async {
  // ignore: avoid_print
  print('=== 抖音翻译接口探针（带 a_bogus 签名）===\n');

  // 0) 对照组：已知可用的评论列表接口
  //    如果它也 blocked，说明是签名/环境问题；如果它通，说明翻译接口确实被单独拦。
  final ctrl = _baseParams()
    ..['aweme_id'] = '7380000000000000000'
    ..['cursor'] = '0'
    ..['count'] = '1'
    ..['item_type'] = '0';
  await _probe(
    label: '对照:评论列表',
    path: '/aweme/v1/web/comment/list/',
    params: ctrl,
  );

  // 1) 通用文本翻译
  for (final pair in [
    ['英→中', 'hello world', 'zh'],
    ['中→英', '这是一条中文评论', 'en'],
    ['日→中', 'こんにちは', 'zh'],
  ]) {
    final p = _baseParams()
      ..['source_text'] = pair[1]
      ..['target_language'] = pair[2];
    await _probe(
      label: '文本翻译 ${pair[0]}',
      path: '/aweme/v1/web/text/translate/',
      params: p,
    );
  }

  // 2) 评论翻译（POST）
  await _probe(
    label: '评论翻译 POST',
    path: '/aweme/v1/web/comment/translate/',
    params: _baseParams(),
    method: 'POST',
    body: jsonEncode({
      'comment_id': '1',
      'target_language': 'en',
      'comment_text': '这是一条中文评论',
      'comment_text_extra': '',
    }),
  );

  // ignore: avoid_print
  print('\n=== 判定 ===');
  // ignore: avoid_print
  print('若 code=0 且有译文 → 抖音自带翻译，不需要接 B站 接口');
  // ignore: avoid_print
  print('若 code=8 → 接口存在，缺登录态');
  // ignore: avoid_print
  print('若 blocked / 404 → 接口不对公网开放');
}
