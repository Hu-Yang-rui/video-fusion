/// 抖音短信登录的表单编码与本地校验。
///
/// 实际发请求的是 `passport_client.dart`；这里只放纯函数，便于离线验证。
library;

import 'dart:convert';

/// passport 字段加密：UTF-8 逐字节 XOR 5，输出**非定宽**小写 hex。
///
/// 例：`'24'` → `'3731'`。
String passportEncrypt(String text) =>
    utf8.encode(text).map((b) => (b ^ 5).toRadixString(16)).join();

/// 11 位大陆手机号归一成 `+86 1xxxxxxxxxx`。
///
/// `mobile` 字段必须带 `+86 ` 前缀再加密；只给 11 位会被判参数错误。
/// 校验用 [nationalPhone]，两者职责不同，不要合并。
String formatPassportPhone(String raw) {
  final digits = nationalPhone(raw);
  if (digits.length != 11) return raw.trim();
  return '+86 $digits';
}

/// 归一成 11 位纯数字，用于本地格式校验。
String nationalPhone(String raw) {
  var s = raw.replaceAll(RegExp(r'[\s\-()]'), '');
  if (s.startsWith('+86')) s = s.substring(3);
  if (s.startsWith('86') && s.length == 13) s = s.substring(2);
  return s;
}

/// 手机号格式校验。本地先拦，避免用明显错误的号码触发风控计数。
String? validatePhone(String raw) {
  final s = nationalPhone(raw);
  if (s.isEmpty) return '请输入手机号。';
  if (!RegExp(r'^1\d{10}$').hasMatch(s)) return '手机号格式不正确（应为 11 位）。';
  return null;
}

/// 验证码格式校验（6 位数字）。
String? validateSmsCode(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '请输入验证码。';
  if (!RegExp(r'^\d{6}$').hasMatch(s)) return '验证码应为 6 位数字。';
  return null;
}
