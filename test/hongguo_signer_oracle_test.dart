/// 用官方金标准 signing.json 验证签名实现。
///
/// 12 条向量来自上游项目的测试资源，每条给出固定输入下
/// hash / gorgon 的期望输出。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/hongguo_signer.dart';
import 'package:video_fusion/src/adapters/hongguo/signer_bytes.dart';
import 'package:video_fusion/src/adapters/hongguo/sm3.dart';

const _oraclePath =
    'APK样本/逆向分析/红果短剧/第三方-miaoxiaohu-TV/signing.json';

List<Map<String, Object?>> _loadRows() {
  final file = File(_oraclePath);
  if (!file.existsSync()) return const [];
  final raw = jsonDecode(file.readAsStringSync()) as List<Object?>;
  return raw.cast<Map<String, Object?>>();
}

void main() {
  final rows = _loadRows();

  test('金标准文件存在且共 12 条', () {
    expect(rows.length, 12, reason: '缺少或损坏: $_oraclePath');
  });

  group('hashF13 对照金标准', () {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      test('第 $i 条 (ts=${row['ts']})', () {
        final signer = HongguoSigner();
        final ts = row['ts'] as int;
        final url = row['url'] as String;
        final query = url.substring(url.indexOf('?') + 1);
        final bodyStr = row['body'] as String?;

        final q = sm3(utf8.encode(query));
        final b = bodyStr == null
            ? Uint8List(16)
            : md5(Uint8List.fromList(utf8.encode(bodyStr)));

        expect(hexOf(signer.hashF13(q, b, ts)), row['hash'],
            reason: '第 $i 条 hash 不一致');
      });
    }
  });

  group('gorgon 对照金标准', () {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      test('第 $i 条 (ts=${row['ts']})', () {
        final signer = HongguoSigner();
        final ts = row['ts'] as int;
        final url = row['url'] as String;
        final query = url.substring(url.indexOf('?') + 1);
        final bodyStr = row['body'] as String?;
        final body = bodyStr == null
            ? null
            : Uint8List.fromList(utf8.encode(bodyStr));

        expect(signer.gorgon(query, body, ts, 42131), row['gorgon'],
            reason: '第 $i 条 gorgon 不一致');
      });
    }
  });

  group('branch 对照金标准', () {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      test('第 $i 条', () {
        final signer = HongguoSigner();
        final ts = row['ts'] as int;
        final url = row['url'] as String;
        final query = url.substring(url.indexOf('?') + 1);
        final bodyStr = row['body'] as String?;
        final body = bodyStr == null
            ? null
            : Uint8List.fromList(utf8.encode(bodyStr));

        expect(signer.branch(query, body, ts), 0);
      });
    }
  });
}
