/// 真实网络验证：用完整签名打红果播放接口。
///
/// 只验证签名链路是否被服务端接受，不依赖任何本地桩。
/// 需要联网，因此归在 integration_test 之外、用 test 跑（手动执行）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// 生成 n 位随机数字串。
///
/// 必须真随机：同一对 iid/device_id 复用会被服务端静默封锁
/// （返回 200 + 空 body），表现为「请求成功但没数据」。
final _rng = Random.secure();

String _digits(int n) {
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    // 首位不给 0，避免被当成非法 ID
    sb.write(i == 0 ? 1 + _rng.nextInt(9) : _rng.nextInt(10));
  }
  return sb.toString();
}

void main() {
  test('完整签名打真接口', () async {
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

    for (var attempt = 1; attempt <= 3; attempt++) {
      // 每次用全新设备标识
      final device = <String, String>{
        ..._deviceBase,
        'iid': _digits(16),
        'device_id': _digits(16),
      };

      final req = signer.sign(_base, device, body: body);

      // ignore: avoid_print
      print('[尝试 $attempt] URL 长度=${req.url.length}');
      // ignore: avoid_print
      print('  headers: ${req.headers.keys.where((k) => k.startsWith('x-')).join(', ')}');
      // ignore: avoid_print
      print('  medusa 长度: ${req.headers['x-medusa']?.length}');
      // ignore: avoid_print
      print('  helios 长度: ${req.headers['x-helios']?.length}');

      final client = HttpClient();
      try {
        final uri = Uri.parse(req.url);
        final request = await client.postUrl(uri);
        req.headers.forEach(request.headers.set);
        request.add(req.body!);
        final response = await request.close();
        final text = await response.transform(utf8.decoder).join();

        // ignore: avoid_print
        print('  响应: ${response.statusCode} len=${text.length}');

        if (text.isNotEmpty) {
          // ignore: avoid_print
          print('  body: ${text.length > 600 ? text.substring(0, 600) : text}');
          if (text.contains('"code":0') || text.contains('"Code":0')) {
            // ignore: avoid_print
            print('\n★★★ 签名通过！');
            break;
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print('  异常: ${'$e'.split('\n').first}');
      } finally {
        client.close();
      }

      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
