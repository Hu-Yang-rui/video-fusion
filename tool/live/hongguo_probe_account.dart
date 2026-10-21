/// 探测红果的账号类接口（历史 / 收藏 / 点赞 / 搜索）。
///
/// 只发请求看返回码，不依赖登录态。用来判断哪些能力真实存在。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/hongguo_signer.dart';

const _host = 'https://api5-normal-sinfonlineb.fqnovel.com';

const _deviceBase = <String, String>{
  'ac': 'wifi', 'channel': 'update_64', 'aid': '8662',
  'app_name': 'novelread', 'version_code': '71332', 'version_name': '7.1.3.32',
  'device_platform': 'android', 'os': 'android', 'ssmix': 'a',
  'device_type': '25053RT47C', 'device_brand': 'Redmi', 'language': 'zh',
  'os_api': '36', 'os_version': '16', 'manifest_version_code': '71332',
  'resolution': '1280*2772', 'dpi': '520', 'update_version_code': '71332',
  'host_abi': 'arm64-v8a', 'dragon_device_type': 'phone', 'pv_player': '71332',
  'compliance_status': '0', 'need_personal_recommend': '1',
  'player_so_load': '1', 'is_android_pad_screen': '0',
};

final _rng = Random.secure();
String _digits(int n) {
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(i == 0 ? 1 + _rng.nextInt(9) : _rng.nextInt(10));
  }
  return sb.toString();
}

/// 带签名 POST。
Future<(int, String)> signedPost(String path, Map<String, Object?> bodyObj) async {
  final signer = HongguoSigner();
  final device = <String, String>{
    ..._deviceBase, 'iid': _digits(16), 'device_id': _digits(16),
  };
  final body = utf8.encode(jsonEncode(bodyObj));
  final req = signer.sign('$_host$path', device, body: body);

  final client = HttpClient();
  try {
    final r = await client.postUrl(Uri.parse(req.url));
    req.headers.forEach(r.headers.set);
    r.add(body);
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    return (resp.statusCode, text);
  } finally {
    client.close();
  }
}

/// 不带签名 GET（很多读接口不需要）。
Future<(int, String)> plainGet(String path, Map<String, String> params) async {
  final qs = Uri(queryParameters: {
    ..._deviceBase,
    'iid': _digits(16),
    'device_id': _digits(16),
    ...params,
  }).query;
  final client = HttpClient();
  try {
    final r = await client.getUrl(Uri.parse('$_host$path?$qs'));
    r.headers.set('user-agent',
        'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)');
    r.headers.set('accept', 'application/json');
    final resp = await r.close();
    final text = await resp.transform(utf8.decoder).join();
    return (resp.statusCode, text);
  } finally {
    client.close();
  }
}

void _report(String tag, int status, String body) {
  var code = '?';
  var msg = '';
  try {
    final j = jsonDecode(body) as Map<String, dynamic>;
    code = '${j['code'] ?? j['Code'] ?? '?'}';
    msg = '${j['message'] ?? j['Message'] ?? ''}';
  } catch (_) {}
  final len = body.length;
  // ignore: avoid_print
  print('[$tag] $status len=$len code=$code ${msg.length > 60 ? "${msg.substring(0, 60)}..." : msg}');
}

void main() {
  test('探测账号类接口', () async {
    final probes = <(String, Future<(int, String)> Function())>[
      // 观看历史
      ('history(read_history)', () => plainGet('/reading/bookapi/read_history/list/v1/',
          {'page_count': '20', 'page_index': '0'})),
      // 收藏
      ('favorites', () => plainGet('/reading/bookapi/bookmall/favorite/list/v1/',
          {'page_count': '20'})),
      // 追更
      ('follow', () => plainGet('/reading/bookapi/bookmall/follow/list/v1/',
          {'page_count': '20'})),
      // 排行榜
      ('rank', () => plainGet('/reading/bookapi/bookmall/cell/change/v1/',
          {'cell_id': '1', 'page_count': '10'})),
      // 搜索
      ('search', () => plainGet('/reading/bookapi/search/page/v1/',
          {'query': '急诊', 'page_count': '10'})),
      // 用户信息
      ('user_info', () => plainGet('/reading/bookapi/user/info/v1/', {})),
    ];

    for (final (tag, fn) in probes) {
      try {
        final (s, b) = await fn();
        _report(tag, s, b);
      } catch (e) {
        // ignore: avoid_print
        print('[$tag] ERR ${'$e'.split('\n').first}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    // 需要签名的写接口
    // ignore: avoid_print
    print('\n=== 带签名的写接口 ===');
    final signedProbes = <(String, String, Map<String, Object?>)>[
      ('like', '/novel/player/video_digg/v1/', {'video_id': '7680951264905022488', 'action': 1}),
      ('favorite', '/novel/player/video_collect/v1/', {'video_id': '7680951264905022488', 'action': 1}),
      ('history_write', '/novel/player/video_history/v1/', {'video_id': '7680951264905022488', 'progress': 30}),
    ];
    for (final (tag, path, body) in signedProbes) {
      try {
        final (s, b) = await signedPost(path, body);
        _report(tag, s, b);
      } catch (e) {
        // ignore: avoid_print
        print('[$tag] ERR ${'$e'.split('\n').first}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
