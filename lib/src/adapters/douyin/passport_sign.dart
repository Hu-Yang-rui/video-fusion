/// passport 签名与编码原语，对照 catbus `sign.ts` / `passport.ts`。
///
/// 全部可用固定输入离线验证。最容易错的是百分号编码的安全字符集、
/// 排序规则、AES 的 IV 取法——都错在"看起来对"的地方。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart'
    show AESEngine, CBCBlockCipher, KeyParameter, ParametersWithIV;

import 'sms_login.dart' show passportEncrypt;

/// passport SDK 的固定 app key（登录页 bundle 里读出）。
const String passportAppKey = '163e7ce78d58971a41f5b969996d85c2';

/// Python `quote(safe='')`：只放行 `A-Za-z0-9_.-~`。
///
/// 不能用 `Uri.encodeComponent`——它会放行 `!*'()`，签名就对不上。
String quoteStrict(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final c = String.fromCharCode(byte);
    final unreserved = (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        c == '_' ||
        c == '.' ||
        c == '-' ||
        c == '~';
    if (unreserved) {
      out.write(c);
    } else {
      out.write('%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    }
  }
  return out.toString();
}

/// `splice_url`：**值**用 [quoteStrict] 编码，键原样，按插入顺序拼接。
String spliceUrl(Iterable<(String, String)> params) =>
    params.map((p) => '${p.$1}=${quoteStrict(p.$2)}').join('&');

/// `urlencode(params)`：键与值都编码（Python `urllib.parse.urlencode`）。
String urlEncodePairs(Iterable<(String, String)> params) =>
    params.map((p) => '${quoteStrict(p.$1)}=${quoteStrict(p.$2)}').join('&');

/// passport 的 `ts`：**当天 UTC 12:00** 的秒级时间戳，不是当前秒。
///
/// 实测浏览器所有 passport 请求的 `ts` 都是当天 UTC 正午。
int sdkTsSeconds([DateTime? now]) {
  final d = (now ?? DateTime.now()).toUtc();
  return DateTime.utc(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/ 1000;
}

/// `x-tt-passport-aid-sign`：三层 HMAC-SHA256。
///
/// ```
/// prk  = hex(HMAC(key=ts,        msg=appKey))
/// okm  = HMAC(key=hexDecode(prk), msg=[0x01])
/// sign = hex(HMAC(key=okm,        msg="aid={aid}&path={path}&ts={ts}"))
/// ```
String aidSign(String path, String ts, {String aid = '6383'}) {
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

/// Python 的字符串比较：按**码点**逐位比，不是按字节。
int _pyCompare(String a, String b) {
  final x = a.runes.toList();
  final y = b.runes.toList();
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// 不参与 passport `sign` 计算的参数（对照 `SIGN_EXCLUDE`）。
const Set<String> passportSignExclude = {'sign', 'qs', 'msToken', 'a_bogus'};

/// passport 的 `sign` / `qs`。
///
/// 取 query 中**键名排序后前 10 个**（排除 [passportSignExclude]），
/// 与 body 一起做 SHA-256；`qs` 是那 10 个键名用逗号连起来再逐字节 XOR 5。
({String sign, String qs}) passportSign(
  List<(String, String)> query, [
  List<(String, String)> data = const [],
]) {
  final signable = <String, String>{};
  for (final (k, v) in query) {
    if (!passportSignExclude.contains(k)) signable[k] = v;
  }
  final keys = signable.keys.toList()..sort(_pyCompare);
  final picked = keys.take(10).toList();

  final qstr = picked.map((k) => '$k=${signable[k]}').join('&');
  final body = <String, String>{for (final (k, v) in data) k: v};
  final bkeys = body.keys.toList()..sort(_pyCompare);
  final bstr = bkeys.map((k) => '$k=${body[k]}').join('&');

  final digest = crypto.sha256
      .convert(utf8.encode('$qstr&$bstr&app_key=$passportAppKey'))
      .toString();
  return (sign: digest, qs: passportEncrypt(picked.join(',')));
}

/// `uaAesUrlsafe`：key = SHA256(UA)，IV = key 后 16 字节，
/// AES-256-CBC + PKCS7，Base64URL（`-`/`_` 替换，**保留** `=`）。
///
/// # 为什么手写 PKCS7
///
/// pointycastle 的 `PaddedBlockCipherImpl` 在部分版本里对
/// `ParametersWithIV` 的接受方式不一致，直接用 `CBCBlockCipher` 更稳：
/// 补位规则本身只有三行，手写反而更可测。
String uaAesUrlsafe(String plaintext, {required String userAgent}) {
  final key = Uint8List.fromList(
    crypto.sha256.convert(utf8.encode(userAgent)).bytes,
  );
  final iv = Uint8List.fromList(key.sublist(16, 32));

  final plain = utf8.encode(plaintext);
  final padLen = 16 - (plain.length % 16);
  final padded = Uint8List.fromList([...plain, ...List.filled(padLen, padLen)]);

  final cbc = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));

  final out = Uint8List(padded.length);
  for (var off = 0; off < padded.length; off += 16) {
    cbc.processBlock(padded, off, out, off);
  }
  return base64Encode(out).replaceAll('+', '-').replaceAll('/', '_');
}

/// `s_v_web_id`：`verify_<base36 毫秒>_<8>_<4>_4<3>_[89ab]<3>_<12>`。
String newSvWebId([DateTime? now, Random? rng]) {
  final r = rng ?? Random.secure();
  final ts36 =
      (now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36);
  const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      'abcdefghijklmnopqrstuvwxyz';
  String pick(int n) =>
      List.generate(n, (_) => charset[r.nextInt(charset.length)]).join();
  final groups = [
    pick(8),
    pick(4),
    '4${pick(3)}',
    '${'89ab'[r.nextInt(4)]}${pick(3)}',
    pick(12),
  ];
  return 'verify_${ts36}_${groups.join('_')}';
}

/// `biz_trace_id`：8 位小写 hex。
String newBizTraceId(Random rng) =>
    List.generate(4, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();

/// 32 字节小写 hex（`rand.hex(32)`）。
String randomHex(Random rng, int bytes) => List.generate(
      bytes,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();

/// md5 小写 hex。
String md5Hex(String text) =>
    crypto.md5.convert(utf8.encode(text)).toString();

/// `passport_auth_mix_state`：固定字母表里随机取 n 个字符。
const String mixAlphabet = '1234567890qwertyuiopasdfghjklzxcvbnm';

String mixState(int length, Random rng) => List.generate(
      length,
      (_) => mixAlphabet[rng.nextInt(mixAlphabet.length)],
    ).join();

/// 北京时间日期串（catbus 固定 Asia/Shanghai，让结果与机器时区无关）。
///
/// [kind] 为 `keys` 时是 `YYYY-MM-DD/HH:MM:SS`，为 `date` 时是 `YYYYMMDD`。
String shanghaiTime(DateTime utc, String kind) {
  final t = utc.toUtc().add(const Duration(hours: 8));
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  if (kind == 'keys') {
    return '${p(t.year, 4)}-${p(t.month)}-${p(t.day)}/'
        '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }
  return '${p(t.year, 4)}${p(t.month)}${p(t.day)}';
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
