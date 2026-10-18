// 抖音扫码登录链路探针（真实网络）。
//
// 目的：把"二维码 → 轮询 → 凭证换取"每一跳的**原始响应头**打出来，
// 特别是 `set-cookie`，用于确认凭证到底在哪一跳下发、
// 应用是否把它接住了。
//
// 用法：
//   dart run tool/smoke_douyin_login.dart          # 只跑到拿到二维码
//   dart run tool/smoke_douyin_login.dart --poll   # 持续轮询（需要真人扫码）
//
// 安全：只打印 cookie 的**名字**与长度，绝不打印取值。
library;

import 'dart:async';
import 'dart:io';

import 'package:video_fusion/src/adapters/douyin/_abogus.dart';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const _fixedParams = {
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

/// 极简 cookie 罐：记录 name → value，只用于本次进程。
final Map<String, String> _cookies = {};

void main(List<String> args) async {
  final doPoll = args.contains('--poll');

  stdout.writeln('=== 1. get_qrcode ===');
  final qr = await _post('/passport/web/get_qrcode/',
      body: 'need_logo=false&is_frontier=true&is_new_login=1'
          '&next=https%3A%2F%2Fwww.douyin.com&need_short_url=true');
  _dump(qr);

  final token = _pick(qr.body, 'token');
  stdout.writeln('token 长度: ${token?.length ?? 0}');

  if (token == null) {
    stdout.writeln('!! 没拿到 token，终止');
    return;
  }

  if (!doPoll) {
    stdout.writeln('\n（加 --poll 可进入轮询；需要真人扫码）');
    return;
  }

  stdout.writeln('\n=== 2. 轮询 check_qrconnect ===');
  stdout.writeln('请用抖音 App 扫描二维码。每 2 秒轮询一次，最多 90 次。');
  stdout.writeln('扫码后本程序会打印服务端真实状态与 set-cookie。\n');

  String? lastStatus;
  for (var i = 0; i < 90; i++) {
    final r = await _post('/passport/web/check_qrconnect/',
        body: 'need_logo=false&is_frontier=true&token=$token'
            '&is_new_login=1&next=https%3A%2F%2Fwww.douyin.com'
            '&need_short_url=true');

    final status = _pick(r.body, 'status');
    final code = _pick(r.body, 'error_code');
    final changed = status != lastStatus;

    if (changed) {
      stdout.writeln('[$i] error_code=$code status=$status');
      if (changed) _dump(r);
      lastStatus = status;
    }

    if (status == 'confirmed' || status == 'success') {
      stdout.writeln('\n=== 3. 已确认，检查凭证下发情况 ===');
      stdout.writeln('当前 cookie 罐: ${_cookies.keys.join(', ')}');
      stdout.writeln('');
      stdout.writeln('set-cookie 是否出现在 confirmed 这一跳: '
          '${r.setCookies.isEmpty ? "否" : "是"}');
      stdout.writeln('\n完整响应体（脱敏后）:');
      stdout.writeln(_redact(r.body));
      return;
    }

    await Future<void>.delayed(const Duration(seconds: 2));
  }
  stdout.writeln('轮询结束，未确认。');
}

Future<_Resp> _post(String path, {required String body}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final params = <String, String>{
    ..._fixedParams,
    'ts': '${now ~/ 1000}',
    'p_ts': '$now',
    'msToken': _msToken(),
  };
  final query = params.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  final abogus = ABogus(userAgent: _ua).getValue(query, body: body);
  final url = 'https://www.douyin.com$path?$query'
      '&a_bogus=${Uri.encodeQueryComponent(abogus)}';

  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set('User-Agent', _ua);
    req.headers.set('Referer', 'https://www.douyin.com/');
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    if (_cookies.isNotEmpty) {
      req.headers.set('Cookie',
          _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    req.add(utf8Bytes(body));

    final resp = await req.close();
    final text = await resp.transform(const SystemEncoding().decoder).join();

    final setCookies = resp.headers['set-cookie'] ?? const <String>[];
    for (final raw in setCookies) {
      final pair = raw.split(';').first;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (value.isEmpty) {
        _cookies.remove(name);
      } else {
        _cookies[name] = value;
      }
    }

    return _Resp(
      status: resp.statusCode,
      body: text,
      setCookies: setCookies,
      location: resp.headers.value('location'),
    );
  } finally {
    client.close(force: true);
  }
}

List<int> utf8Bytes(String s) => const SystemEncoding().encode(s);

void _dump(_Resp r) {
  stdout.writeln('  HTTP ${r.status}');
  if (r.location != null) stdout.writeln('  location: ${r.location}');
  if (r.setCookies.isEmpty) {
    stdout.writeln('  set-cookie: （无）');
  } else {
    for (final c in r.setCookies) {
      // 只打印名字与长度，不打印取值
      final pair = c.split(';').first;
      final eq = pair.indexOf('=');
      final name = eq > 0 ? pair.substring(0, eq) : pair;
      final len = eq > 0 ? pair.length - eq - 1 : 0;
      stdout.writeln('  set-cookie: $name (len=$len)');
    }
  }
  stdout.writeln('  body: ${_redact(r.body)}');
  stdout.writeln('');
}

/// 脱敏：把疑似凭证字段的值打码。
String _redact(String body) {
  var out = body;
  for (final key in const [
    'sessionid',
    'sessionid_ss',
    'sid_tt',
    'uid_tt',
    'sid_guard',
    'passport_csrf_token',
    'ticket',
    'token',
  ]) {
    out = out.replaceAllMapped(
      RegExp('"$key"\\s*:\\s*"([^"]*)"'),
      (m) => '"$key":"<redacted:${m.group(1)!.length}>"',
    );
  }
  return out;
}

String? _pick(String body, String key) {
  final m = RegExp('"$key"\\s*:\\s*"?([^",}]*)"?').firstMatch(body);
  final v = m?.group(1);
  if (v == null || v.isEmpty) return null;
  return v;
}

String _msToken() {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final rnd = DateTime.now().microsecondsSinceEpoch;
  final sb = StringBuffer();
  for (var i = 0; i < 107; i++) {
    sb.write(chars[(rnd + i * 31) % chars.length]);
  }
  sb.write('=');
  return sb.toString();
}

class _Resp {
  _Resp({
    required this.status,
    required this.body,
    required this.setCookies,
    required this.location,
  });

  final int status;
  final String body;
  final List<String> setCookies;
  final String? location;
}
