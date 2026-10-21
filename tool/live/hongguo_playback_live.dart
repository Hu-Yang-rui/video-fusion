/// 真实网络验证：完整播放链路。
///
/// 两步请求：
///   1. `video_model/v1/` 取 `video_model`（内含 fallback_api）
///   2. 请求 `fallback_api` 取 `video_info.data.video_list`
///
/// 只验证链路是否走通与档位是否齐全，不做下载。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/hongguo_signer.dart';

const _vid = '7680951264905022488';
const _base =
    'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/';

const _deviceBase = <String, String>{
  'ac': 'wifi',
  'channel': 'update_64',
  'aid': '8662',
  'app_name': 'novelread',
  'version_code': '71332',
  'version_name': '7.1.3.32',
  'device_platform': 'android',
  'os': 'android',
  'ssmix': 'a',
  'device_type': '25053RT47C',
  'device_brand': 'Redmi',
  'language': 'zh',
  'os_api': '36',
  'os_version': '16',
  'manifest_version_code': '71332',
  'resolution': '1280*2772',
  'dpi': '520',
  'update_version_code': '71332',
  'host_abi': 'arm64-v8a',
  'dragon_device_type': 'phone',
  'pv_player': '71332',
  'compliance_status': '0',
  'need_personal_recommend': '1',
  'player_so_load': '1',
  'is_android_pad_screen': '0',
};

final _rng = Random.secure();

String _digits(int n) {
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(i == 0 ? 1 + _rng.nextInt(9) : _rng.nextInt(10));
  }
  return sb.toString();
}

Future<String> _post(String url, Map<String, String> headers, List<int> body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    request.add(body);
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

Future<String> _get(String url, String ua) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('user-agent', ua);
    request.headers.set('accept', 'application/json');
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

void main() {
  test('完整播放链路：video_model → fallback_api → video_list', () async {
    final signer = HongguoSigner();

    final body = utf8.encode(jsonEncode({
      'biz_param': {
        'detail_page_version': 0,
        'device_level': 3,
        'disable_digg_stat': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'video_id': _vid,
    }));

    String? text;
    for (var attempt = 1; attempt <= 3; attempt++) {
      final device = <String, String>{
        ..._deviceBase,
        'iid': _digits(16),
        'device_id': _digits(16),
      };
      final req = signer.sign(_base, device, body: body);
      final t = await _post(req.url, req.headers, body);
      // ignore: avoid_print
      print('[第 1 步 尝试 $attempt] len=${t.length}');
      if (t.isNotEmpty) {
        text = t;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }

    expect(text, isNotNull, reason: 'video_model 三次都返回空');

    final json = jsonDecode(text!) as Map<String, dynamic>;
    expect(json['code'], 0, reason: 'code 非 0');

    final data = json['data'] as Map<String, dynamic>?;
    expect(data, isNotNull);

    // data 直接就是视频信息（不是以 vid 为 key 的 map）
    final height = data!['video_height'];
    // ignore: avoid_print
    print('  video_height = $height');

    final rawModel = data['video_model'];
    expect(rawModel, isNotNull, reason: 'video_model 缺失');
    final model = rawModel is String
        ? jsonDecode(rawModel) as Map<String, dynamic>
        : rawModel as Map<String, dynamic>;
    // ignore: avoid_print
    print('  video_model keys: ${model.keys.join(", ")}');

    // 取 fallback_api
    var fb = model['fallback_api'];
    if (fb is Map) fb = fb['fallback_api'] ?? (fb.values.isNotEmpty ? fb.values.first : null);
    expect(fb, isA<String>(), reason: 'fallback_api 缺失');
    // ignore: avoid_print
    print('[第 2 步] fallback_api = ${(fb as String).substring(0, 120)}...');

    final ua = req0Ua();
    final step2 = await _get(fb, ua);
    // ignore: avoid_print
    print('  响应 len=${step2.length}');
    expect(step2.isNotEmpty, isTrue, reason: 'fallback_api 返回空');

    final j2 = jsonDecode(step2) as Map<String, dynamic>;
    final info = (j2['video_info'] as Map?)?['data'] as Map?;
    expect(info, isNotNull, reason: 'video_info.data 缺失');

    final list = info!['video_list'] as Map?;
    expect(list, isNotNull, reason: 'video_list 缺失');

    // ignore: avoid_print
    print('\n★ video_list 共 ${list!.length} 档：');
    final rows = <MapEntry<String, Map>>[];
    for (final e in list.entries) {
      if (e.value is Map) {
        rows.add(MapEntry(e.key as String, e.value as Map));
      }
    }
    // 按 definition 里的数字降序
    int qualityOf(Map m) {
      final s = '${m['definition'] ?? m['quality_desc'] ?? m['height'] ?? ''}';
      final match = RegExp(r'\d{3,4}').firstMatch(s);
      return match == null ? 0 : int.parse(match.group(0)!);
    }

    rows.sort((a, b) => qualityOf(b.value).compareTo(qualityOf(a.value)));
    for (final r in rows) {
      final m = r.value;
      final q = qualityOf(m);
      final hasUrl = '${m['main_url'] ?? ''}'.isNotEmpty;
      final hasSpade = '${m['spade_a'] ?? ''}'.isNotEmpty;
      // ignore: avoid_print
      print('  ${q}P  key=${r.key}  codec=${m['codec_type']}  '
          'main_url=${hasUrl ? "✅" : "❌"}  spade_a=${hasSpade ? "✅" : "❌"}');
    }

    final best = rows.first;
    expect(qualityOf(best.value), greaterThanOrEqualTo(720),
        reason: '最高档应至少 720p');
    // ignore: avoid_print
    print('\n★★★ 最高档: ${qualityOf(best.value)}P');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String req0Ua() =>
    'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
    'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
    'QuicVersion:c67e9834 2025-09-08)';
