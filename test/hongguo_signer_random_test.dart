/// 用官方金标准验证 medusa / helios。
///
/// 上游测试用确定性 LCG 复现随机数：
///   seed = 17
///   seed = (seed * 1664525 + 1013904223) & 0xffffffff
///   random() = seed / 4294967296.0
///
/// 只要随机源一致，medusa / helios 的输出就能与金标准逐字节对上。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/hongguo_signer.dart';

const _oraclePath =
    'APK样本/逆向分析/红果短剧/第三方-miaoxiaohu-TV/signing.json';

/// 与上游测试一致的 LCG。
class LcgRandom implements Random {
  LcgRandom([int seed = 17]) : _seed = seed;
  int _seed;

  double nextDouble() {
    _seed = (_seed * 1664525 + 1013904223) & 0xFFFFFFFF;
    return _seed / 4294967296.0;
  }

  @override
  int nextInt(int max) => (nextDouble() * max).toInt().clamp(0, max - 1);

  @override
  bool nextBool() => nextDouble() < 0.5;
}

/// 金标准用的固定设备对。
const _oracleDevice = <String, String>{
  'iid': '1905892595382586',
  'device_id': '1905892595378490',
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

List<Map<String, Object?>> _loadRows() {
  final file = File(_oraclePath);
  if (!file.existsSync()) return const [];
  final raw = jsonDecode(file.readAsStringSync()) as List<Object?>;
  return raw.cast<Map<String, Object?>>();
}

void main() {
  final rows = _loadRows();

  test('金标准 12 条', () {
    expect(rows.length, 12);
  });

  group('helios 对照金标准', () {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      test('第 $i 条 (ts=${row['ts']})', () {
        final ts = row['ts'] as int;
        // 每条用独立 signer + 重置 LCG（与上游每条重新构造一致）
        final signer = HongguoSigner(random: LcgRandom(17));
        final actual = signer.helios(ts);
        expect(actual, row['helios'], reason: '第 $i 条 helios 不一致');
      });
    }
  });

  group('medusa 对照金标准', () {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      test('第 $i 条 (ts=${row['ts']})', () {
        final ts = row['ts'] as int;
        final url = row['url'] as String;
        final bodyStr = row['body'] as String?;
        final body = bodyStr == null
            ? null
            : Uint8List.fromList(utf8.encode(bodyStr));

        // 上游测试在同一个 signer 上按 branch → hash → gorgon → helios → medusa
        // 的顺序断言。gorgon 的随机数是显式传入的（42131），不消耗 LCG；
        // 但 helios 会消耗一次 rand()，所以 medusa 里的 r 实际是第 5 次调用。
        final signer = HongguoSigner(
          random: LcgRandom(17),
          clock: () => DateTime.fromMillisecondsSinceEpoch(ts * 1000),
        );
        signer.helios(ts); // 消耗一次 rand()，与上游调用顺序对齐
        final actual = signer.medusa(url, body, ts, _oracleDevice);
        expect(actual, row['medusa'], reason: '第 $i 条 medusa 不一致');
      });
    }
  });
}
