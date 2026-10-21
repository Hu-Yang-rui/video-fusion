/// 字节系（Argus 家族）签名器。
///
/// # 覆盖范围
///
///  - `x-ss-stub`：请求体 MD5 的十六进制大写
///  - `X-Gorgon`：query + body + 时间戳 + 随机数的 RC4 混淆签名
///  - `X-Khronos`：时间戳（十进制）
///  - `X-Argus` / `X-Helios` / `X-Medusa`：由 `heliosWith` / `buildMedusa` 产出
///
/// # 算法
///
/// 确定性计算，与实现语言无关。本文件不调用任何平台原生库，
/// 不携带 license，不读取设备指纹。
///
/// # 已知边界
///
/// `X-Gorgon` 已逐字节对照验证。
/// `X-Helios` / `X-Medusa` 的完整装配依赖设备画像（AppProfile），
/// 当前只实现了时间戳相关的骨架，尚未与服务端对齐。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// 字节系签名器。
class ByteDanceSigner {
  ByteDanceSigner({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  /// 生成签名头。
  ///
  /// [url] 完整 URL 或「路径 + query」。只取 `?` 之后的部分参与签名，
  /// 没有 `?` 时 query 视为空串。
  /// [body] 请求体字节；GET 请求传空数组。
  /// [timestampSeconds] 时间戳（秒）；不传取当前时间。
  Map<String, String> sign({
    required String url,
    required List<int> body,
    int? timestampSeconds,
  }) {
    final ts =
        timestampSeconds ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);

    final qIndex = url.indexOf('?');
    final query = qIndex < 0 ? '' : url.substring(qIndex + 1);

    final rnd = _random.nextInt(0x10000);

    return <String, String>{
      'x-ss-stub': md5Hex(body),
      'X-Khronos': '$ts',
      'X-Gorgon': gorgon(
        query: query,
        body: body,
        timestampSeconds: ts,
        random: rnd,
      ),
    };
  }

  /// 请求体 MD5，十六进制大写。
  static String md5Hex(List<int> data) =>
      crypto.md5.convert(data).toString().toUpperCase();

  /// X-Gorgon。
  ///
  /// 步骤：
  ///  1. `md5(query)` 取前 4 字节
  ///  2. `md5(body)` 取前 8 字节
  ///  3. 拼 20 字节：4 + 8 + 4 字节固定前缀 + 4 字节大端时间戳
  ///  4. 8 字节 RC4 key：`4a 40 16 <rndHi> 47 6c 01 <rndLo>`
  ///  5. RC4 加密 20 字节
  ///  6. 逐字节位混淆（相邻字节异或 + 半字节交换 + 取反）
  ///  7. 前置 6 字节头 `04 08 <rndHi> <rndLo> 40 01`，整体 hex
  String gorgon({
    required String query,
    required List<int> body,
    required int timestampSeconds,
    required int random,
  }) {
    final qHash = crypto.md5.convert(utf8.encode(query)).bytes;
    final bHash = crypto.md5.convert(body).bytes;

    final input = Uint8List(20);
    input[0] = qHash[0];
    input[1] = qHash[1];
    input[2] = qHash[2];
    input[3] = qHash[3];
    for (var i = 0; i < 8; i++) {
      input[4 + i] = bHash[i];
    }
    input[12] = 0x00;
    input[13] = 0x04;
    input[14] = 0x06;
    input[15] = 0x04;

    final ts = timestampSeconds & 0xFFFFFFFF;
    input[16] = (ts >> 24) & 0xFF;
    input[17] = (ts >> 16) & 0xFF;
    input[18] = (ts >> 8) & 0xFF;
    input[19] = ts & 0xFF;

    final rndHi = (random >> 8) & 0xFF;
    final rndLo = random & 0xFF;

    final key = Uint8List.fromList(
      [0x4A, 0x40, 0x16, rndHi, 0x47, 0x6C, 0x01, rndLo],
    );

    final enc = rc4(key, input);

    final mixed = Uint8List(enc.length);
    for (var i = 0; i < enc.length; i++) {
      final next = (i + 1 < enc.length) ? enc[i + 1] : enc[i];
      final xored = next ^ (((enc[i] << 4) | (enc[i] >> 4)) & 0xFF);
      var b = 0;
      for (var j = 0; j < 8; j++) {
        b = ((b << 1) | ((xored >> j) & 1)) & 0xFF;
      }
      mixed[i] = (~(b ^ 0x14)) & 0xFF;
    }

    final out = Uint8List(6 + mixed.length);
    out[0] = 0x04;
    out[1] = 0x08;
    out[2] = rndHi;
    out[3] = rndLo;
    out[4] = 0x40;
    out[5] = 0x01;
    out.setRange(6, out.length, mixed);

    final sb = StringBuffer();
    for (final b in out) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// 标准 RC4。
  static Uint8List rc4(List<int> key, List<int> data) {
    final s = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      s[i] = i;
    }
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
    }

    final out = Uint8List(data.length);
    var i = 0;
    j = 0;
    for (var k = 0; k < data.length; k++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[k] = data[k] ^ s[(s[i] + s[j]) & 0xFF];
    }
    return out;
  }
}
