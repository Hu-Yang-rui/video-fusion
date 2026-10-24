/// 本地抓包 fixture 的读取与"缺了就跳过"约定。
///
/// # 为什么会有这个文件
///
/// `tool/**/_*.json` 是**真实接口响应的抓包**，含平台下发的时效签名
/// （如 B站字幕的 `auth_key`），所以整体被 `.gitignore` 排除、不进公开仓库。
///
/// 但若测试直接 `readAsStringSync`，别人 clone 下来会因为**文件不存在**
/// 而红成一片——那是"缺样本"，不是"代码出错"，两件事不能混。
///
/// 所以统一走这里：文件在就跑真断言，不在就**显式跳过并说明原因**
/// （跳过不等于通过，见 AGENTS.md 4.1）。
library;

import 'dart:convert';
import 'dart:io';

/// 读一个本地抓包 fixture；不存在返回 null。
String? readLocalFixture(String relativePath) {
  final f = File(relativePath);
  if (!f.existsSync()) return null;
  return f.readAsStringSync();
}

/// 读一个本地 JSON fixture 并转成 Map；缺失或坏 JSON 返回 null。
Map<String, Object?>? readLocalJson(String relativePath) {
  final raw = readLocalFixture(relativePath);
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  } catch (_) {
    // 坏 JSON 也按"没有样本"处理，由调用方决定跳过还是失败
  }
  return null;
}

/// 构造 `skip:` 参数：缺样本时给出可读的跳过原因，否则返回 false（照常跑）。
///
/// 用法：
/// ```dart
/// test('...', () { ... }, skip: skipIfMissing(['tool/live/_x.json']));
/// ```
Object skipIfMissing(List<String> paths) {
  final missing = paths.where((p) => !File(p).existsSync()).toList();
  if (missing.isEmpty) return false;
  return '缺本地抓包样本（不入公开仓库）：${missing.join('、')}';
}