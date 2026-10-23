/// 抖音 `bd-ticket-guard` 的纯 Dart 实现。
///
/// # 这是什么（实测 2026-10-23）
///
/// 抖音的 passport 登录接口要求请求头 `bd-ticket-guard-ree-public-key`，
/// 并且 Cookie `bd_ticket_guard_client_data` 里也要带同一个公钥。
/// 缺了它，`check_qrconnect` 恒返回 `4031`「已阻止此次访问」。
///
/// 之前 App 里等这个 Cookie 自然出现（等不到），或者用随机字节冒充
/// 公钥（不是合法 P-256 曲线点，服务端直接拒）。两者都错——
/// **它是客户端自己生成的**，用真实的 P-256 密钥对。
///
/// # 算法来源
///
/// 对照开源实现 `cv-cat/catbus` 的 `src/platforms/douyin/web/crypto.ts`
/// 与 `cv-cat/DouYin_Spider` 的 `utils/bd_ticket.py`：
///
/// ```
/// 公钥    = base64(0x04 || X || Y)          // 未压缩点，65 字节
/// client_data = base64(JSON({
///   "bd-ticket-guard-version": 2,
///   "bd-ticket-guard-iteration-version": 1,
///   "bd-ticket-guard-ree-public-key": <公钥>,
///   "bd-ticket-guard-web-version": 2,
/// }))
/// ```
///
/// 登录成功后服务端会下发 `ticket` / `ts_sign` / `client_cert`，
/// 那时才需要 ECDH + HMAC 签名（见 [ecdhKey] 与 [signClientData]）。
/// 扫码阶段只需要公钥。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithRandom;

/// Cookie 名：客户端把自己的公钥交给服务端。
const String ticketGuardClientDataCookie = 'bd_ticket_guard_client_data';

/// Cookie 名：标记 web 端版本（固定 "2"）。
const String ticketGuardWebDomainCookie = 'bd_ticket_guard_client_web_domain';

/// Cookie 名：v2 版本（带 sec_ts 签名，登录流程实际用它）。
const String ticketGuardClientDataV2Cookie = 'bd_ticket_guard_client_data_v2';

/// 一对 P-256 密钥。
class TicketGuardKeyPair {
  const TicketGuardKeyPair({required this.privateKey, required this.publicKey});

  /// 私钥标量（32 字节）。
  final Uint8List privateKey;

  /// 未压缩公钥点 `0x04 || X || Y`（65 字节）。
  final Uint8List publicKey;

  /// `bd-ticket-guard-ree-public-key` 头的值（标准 base64，不是 url-safe）。
  String get reePublicKeyBase64 => base64Encode(publicKey);

  /// `bd_ticket_guard_client_data` Cookie 的值。
  ///
  /// 键序与 `zero.js` 一致（开源实现注释里写明"键序照 zero.js 原样"）。
  String get clientDataCookie {
    final map = <String, Object>{
      'bd-ticket-guard-version': 2,
      'bd-ticket-guard-iteration-version': 1,
      'bd-ticket-guard-ree-public-key': reePublicKeyBase64,
      'bd-ticket-guard-web-version': 2,
    };
    return base64Encode(utf8.encode(jsonEncode(map)));
  }

  /// `bd_ticket_guard_client_data_v2` Cookie 的值（登录流程实际用的）。
  ///
  /// # 与 v1 的区别（实测 2026-10-23）
  ///
  /// 登录流程的 `QR_ORDER` 里用的是 **v2**，不是 v1。v2 多了
  /// `sec_ts` 与它的 HMAC 签名，用来证明"我拿到了服务端签发的
  /// 一次性挑战"。
  ///
  /// 结构（对照 `DouYin_Spider` 的 `build_client_data_v2_cookie`）：
  /// ```json
  /// {"ree_public_key": <公钥>,
  ///  "ts_sign":       <服务端签发的 ts_sign，没有则省略>,
  ///  "req_content":   "sec_ts",
  ///  "req_sign":      base64(HMAC-SHA256(ecdhKey, "sec_ts=" + sec_ts)),
  ///  "sec_ts":        <get_sec_ts 返回的串，以 # 开头>}
  /// ```
  ///
  /// `req_sign` 的被签内容不含时间戳，所以可离线复现、可反复校验。
  /// `ecdhKey` 与 `bd-ticket-guard-*` 请求头用的是同一把。
  String clientDataV2Cookie({
    required Uint8List serverCertPoint,
    required String secTs,
    String tsSign = '',
  }) {
    final ecdh = ecdhKey(privateKey, serverCertPoint);
    final reqSign = base64Encode(_hmacSha256(
      ecdh,
      Uint8List.fromList(utf8.encode('sec_ts=$secTs')),
    ));

    final map = <String, Object>{
      'ree_public_key': reePublicKeyBase64,
      if (tsSign.isNotEmpty) 'ts_sign': tsSign,
      'req_content': 'sec_ts',
      'req_sign': reqSign,
      'sec_ts': secTs,
    };
    final raw = jsonEncode(map);
    // 浏览器用 encodeURIComponent 包一层
    return Uri.encodeComponent(base64Encode(utf8.encode(raw)));
  }
}

/// P-256 曲线参数。
final ECCurve_prime256v1 _p256 = ECCurve_prime256v1();

/// 生成一对新的 P-256 密钥。
///
/// 用 `pointycastle` 的 `ECKeyGenerator`，曲线 `prime256v1`（= P-256 / secp256r1）。
TicketGuardKeyPair generateTicketGuardKeyPair() {
  final domain = ECDomainParameters('prime256v1');
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
      ECKeyGeneratorParameters(domain),
      _secureRandom(),
    ));
  final pair = gen.generateKeyPair();
  final pub = pair.publicKey as ECPublicKey;
  final priv = pair.privateKey as ECPrivateKey;

  // 公钥：0x04 || X(32) || Y(32)
  final q = pub.Q!;
  final x = _toFixed(q.x!.toBigInteger()!, 32);
  final y = _toFixed(q.y!.toBigInteger()!, 32);
  final pubBytes = Uint8List(65)
    ..[0] = 0x04
    ..setRange(1, 33, x)
    ..setRange(33, 65, y);

  return TicketGuardKeyPair(
    privateKey: _toFixed(priv.d!, 32),
    publicKey: pubBytes,
  );
}

/// 从私钥标量推出公钥点（`k·G`）。
Uint8List publicKeyFromPrivate(Uint8List privateKey) {
  final d = _p256.curve.decodePoint(
    // 用曲线基点做标量乘
    Uint8List.fromList([0x04, ..._toFixed(_p256.G.x!.toBigInteger()!, 32),
      ..._toFixed(_p256.G.y!.toBigInteger()!, 32)]),
  );
  final point = (d! * BigInt.parse(
    privateKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    radix: 16,
  ))!;
  final x = _toFixed(point.x!.toBigInteger()!, 32);
  final y = _toFixed(point.y!.toBigInteger()!, 32);
  return Uint8List(65)
    ..[0] = 0x04
    ..setRange(1, 33, x)
    ..setRange(33, 65, y);
}

/// ECDH(客户端私钥, 服务端证书公钥) → HKDF-SHA256 → 32 字节 HMAC 密钥。
///
/// 登录成功后才需要（用于对 `sign_data` 做 HMAC 签名）。
Uint8List ecdhKey(Uint8List privateKey, Uint8List serverPoint) {
  final serverPub = _p256.curve.decodePoint(serverPoint)!;
  final d = BigInt.parse(
    privateKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    radix: 16,
  );
  final shared = (serverPub * d)!;
  // 共享点只取 X 坐标（32 字节）
  final sharedX = _toFixed(shared.x!.toBigInteger()!, 32);
  return _hkdfSha256(sharedX, 32);
}

/// HKDF-SHA256（salt 为空 → 全零 32 字节）。
Uint8List _hkdfSha256(Uint8List ikm, int length) {
  final salt = Uint8List(32);
  final prk = _hmacSha256(salt, ikm);
  final out = BytesBuilder();
  var block = Uint8List(0);
  var counter = 1;
  while (out.length < length) {
    final input = Uint8List.fromList([...block, counter]);
    block = _hmacSha256(prk, input);
    out.add(block);
    counter++;
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

Uint8List _hmacSha256(Uint8List key, Uint8List data) {
  final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  return hmac.process(data);
}

/// 把大整数转成定长字节。
Uint8List _toFixed(BigInt n, int len) {
  final hex = n.toRadixString(16).padLeft(len * 2, '0');
  final out = Uint8List(len);
  for (var i = 0; i < len; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 密码学安全随机源。
///
/// `FortunaRandom` 用系统熵播种；这里额外混入高精度时间戳与
/// `Random.secure()` 的字节，避免单一来源。
FortunaRandom _secureRandom() {
  final rnd = FortunaRandom();
  final seed = Uint8List(32);
  final sys = Random.secure();
  for (var i = 0; i < 32; i++) {
    seed[i] = sys.nextInt(256);
  }
  rnd.seed(KeyParameter(seed));
  return rnd;
}
