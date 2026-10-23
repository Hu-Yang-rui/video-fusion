/// 抖音短信验证码登录（`/passport/web/send_code/` + `/passport/web/sms_login/`）。
///
/// # 为什么走短信而不是扫码（实测 2026-10-23）
///
/// 扫码登录卡在结构性死锁：
/// ```
/// 要扫码 → 需要 v2 Cookie → v2 需要 sec_ts
///                              ↓
///                        sec_ts 需要已登录
/// ```
/// `get_sec_ts` 未登录时返回空，`check_qrconnect` 因此恒 4031。
///
/// 短信登录没有这个环：它走 `aid=6383` 的 passport-web 协议，
/// 只需要手机号 + 验证码，不需要 `sec_ts`。
///
/// # 表单编码（严格照实录，顺序固定）
///
/// `send_code`：
/// ```
/// is6Digits=1&mix_mode=1&mobile=<enc>&type=3731&fixed_mix_mode=1
/// ```
/// `sms_login`：
/// ```
/// service=https://www.douyin.com&mix_mode=1&mobile=<enc>&code=<enc>&fixed_mix_mode=1
/// ```
///
/// 其中 `enc` = UTF-8 逐字节 **XOR 5** 后转非定宽小写 hex。
/// `type=3731` 是明文 `24` 加密后的值，**不能改成别的数**。
///
/// # 必须带 a_bogus
///
/// 不带会返回 `error_code=2156`「系统繁忙」——看起来像服务端故障，
/// 实际是风控兜底话术。实测确认：带 `a_bogus` 才进入正常流程。
library;

import 'dart:convert';

/// passport 字段加密：UTF-8 逐字节 XOR 5，输出非定宽小写 hex。
///
/// 例：`'24'` → `'3731'`（`0x32^5=0x37`, `0x34^5=0x31`）。
String passportEncrypt(String text) =>
    utf8.encode(text).map((b) => (b ^ 5).toRadixString(16)).join();

/// 一次短信登录会话。
class SmsLoginSession {
  SmsLoginSession({required this.phone, required this.createdAt});

  final String phone;
  final DateTime createdAt;

  /// 发送验证码成功后下发的票据（诊断用，提交时不发送）。
  String? mobileTicket;

  /// 验证码请求是否已发（`sms_login` 必须复用同一会话）。
  bool get codeSent => mobileTicket != null || _sent;

  bool _sent = false;

  void markCodeSent({String? ticket}) {
    _sent = true;
    if (ticket != null && ticket.isNotEmpty) mobileTicket = ticket;
  }
}

/// `send_code` 的表单 body（顺序固定）。
String buildSendCodeBody(String phone) {
  final mobile = passportEncrypt(_normalizePhone(phone));
  return 'is6Digits=1&mix_mode=1&mobile=$mobile&type=3731&fixed_mix_mode=1';
}

/// `sms_login` 的表单 body（顺序固定）。
String buildSmsLoginBody(String phone, String code) {
  final mobile = passportEncrypt(_normalizePhone(phone));
  final encCode = passportEncrypt(code.trim());
  return 'service=https://www.douyin.com'
      '&mix_mode=1'
      '&mobile=$mobile'
      '&code=$encCode'
      '&fixed_mix_mode=1';
}

/// 手机号归一化：去掉空格、`+86` 前缀、连字符。
///
/// 服务端只认 11 位纯数字，带前缀会返回参数错误。
String _normalizePhone(String raw) {
  var s = raw.replaceAll(RegExp(r'[\s\-()]'), '');
  if (s.startsWith('+86')) s = s.substring(3);
  if (s.startsWith('86') && s.length == 13) s = s.substring(2);
  return s;
}

/// 手机号格式校验（中国大陆 11 位，1 开头）。
///
/// 本地先拦，避免拿明显错误的号码去打服务端（会触发风控计数）。
String? validatePhone(String raw) {
  final s = _normalizePhone(raw);
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
