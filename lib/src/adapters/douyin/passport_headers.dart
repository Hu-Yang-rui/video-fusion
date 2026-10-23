/// 抖音 passport 的三个签名头。
///
/// # 为什么需要（实测 2026-10-23）
///
/// 真实浏览器的 passport 请求带这三个头，缺任何一个
/// `check_qrconnect` 都可能返回 `4031`：
///
/// | 头 | 来源 |
/// |---|---|
/// | `x-tt-passport-aid-sign` | `aidSign(path, ts)` 三层 HMAC |
/// | `x-tt-passport-csrf-token` | Cookie `passport_csrf_token` 的值 |
/// | `x-tt-passport-verify-portrait` | 会话 UUID + `.login` |
///
/// 算法对照 `cv-cat/catbus` 的 `src/platforms/douyin/web/sign.ts`。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

/// passport SDK 的固定 app key（登录页 bundle 里读出）。
const String passportAppKey = '163e7ce78d58971a41f5b969996d85c2';

/// 抖音 Web 端的 aid。
const String douyinAid = '6383';

/// `ts` 取**当天 UTC 12:00**的秒级时间戳，不是当前秒。
///
/// 实测：浏览器所有 passport 请求的 `ts` 都是当天 UTC 正午。
/// 用当前秒会与 `aid-sign` 里的 ts 不一致，签名对不上。
int sdkTsSeconds([DateTime? now]) {
  final d = (now ?? DateTime.now()).toUtc();
  final noon = DateTime.utc(d.year, d.month, d.day, 12);
  return noon.millisecondsSinceEpoch ~/ 1000;
}

/// `x-tt-passport-aid-sign`。
///
/// 三层 HMAC-SHA256：
/// ```
/// prk  = hex(HMAC(key=ts,        msg=appKey))
/// okm  = HMAC(key=hexDecode(prk), msg=[0x01])
/// sign = hex(HMAC(key=okm,        msg="aid={aid}&path={path}&ts={ts}"))
/// ```
String aidSign(String path, String ts, {String aid = douyinAid}) {
  final prk = crypto.Hmac(crypto.sha256, utf8.encode(ts))
      .convert(utf8.encode(passportAppKey))
      .toString();
  final okm = crypto.Hmac(crypto.sha256, _hexToBytes(prk))
      .convert(const [0x01])
      .bytes;
  return crypto.Hmac(crypto.sha256, okm)
      .convert(utf8.encode('aid=$aid&path=$path&ts=$ts'))
      .toString();
}

/// `x-tt-passport-verify-portrait`。
///
/// 格式：`<uuid>.login`。浏览器里是会话级 UUID，登录流程内保持不变。
String buildVerifyPortrait([String? uuid]) {
  final u = uuid ?? _randomUuid();
  return '$u.login';
}

/// `x-tt-passport-csrf-token`：直接取 Cookie 里的值。
///
/// 优先 `passport_csrf_token`，回退 `passport_csrf_token_default`。
String? csrfTokenFromCookies(Map<String, String> cookies) {
  final v = cookies['passport_csrf_token'] ??
      cookies['passport_csrf_token_default'];
  return (v == null || v.isEmpty) ? null : v;
}

Uint8ListLike _hexToBytes(String hex) {
  final out = List<int>.filled(hex.length ~/ 2, 0);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 便于 `Hmac` 接受 List<int> 的类型别名。
typedef Uint8ListLike = List<int>;

/// 生成 UUID v4 格式字符串。
String _randomUuid() {
  final rnd = Random.secure();
  final b = List<int>.generate(16, (_) => rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-'
      '${h(4)}${h(5)}-'
      '${h(6)}${h(7)}-'
      '${h(8)}${h(9)}-'
      '${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}
