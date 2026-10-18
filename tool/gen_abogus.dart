// 生成 a_bogus，参数从 JSON 文件读取（避免 shell 转义）。
import 'dart:convert';
import 'dart:io';

import 'package:video_fusion/src/adapters/douyin/_abogus.dart';

void main(List<String> args) {
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  // 优先从文件读参数
  final argsFile = File('_mint/_dart_args.json');
  String query = '';
  String body = '';

  if (argsFile.existsSync()) {
    final data = jsonDecode(argsFile.readAsStringSync()) as Map;
    query = (data['query'] as String?) ?? '';
    body = (data['body'] as String?) ?? '';
  } else if (args.isNotEmpty) {
    query = args[0];
    body = args.length > 1 ? args[1] : '';
  }

  final signer = ABogus(userAgent: ua);
  stdout.writeln(signer.getValue(query, body: body));
}
