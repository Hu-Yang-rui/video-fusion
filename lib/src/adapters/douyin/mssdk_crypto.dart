/// mssdk 上报体加密原语（RC4 + 自定义 base64 + encodeStrData）。
///
/// # 为什么单独成文件、单独可测（2026-10-23）
///
/// 抖音 `/web/common` 与 `/web/r/token` 的上报体里，`strData` 字段是
/// `RC4(key=nonce, plaintext)` 前缀 `[0x41, nonce]` 后用**自定义字母表**
/// base64 编码。这一步字节序只要错一个，服务端就不返回 msToken，
/// 整条短信登录链在第一步就断。
///
/// 所以先把这三个纯函数独立出来、用标准测试向量钉死，再往上搭。
/// 对照来源：`cv-cat/catbus` 的 `sign.ts`（`rc4` / `b64Custom` /
/// `encodeStrData` / `STRDATA_ALPHABET`）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// strData 的自定义 base64 字母表（64 字符，非标准表）。
const String strDataAlphabet =
    'Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe';

/// 标准 base64 字母表，仅用于测试里做 round-trip 对照。
const String stdAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// RC4 流加密（key 与 data 均为字节）。加密解密同一函数。
///
/// 标准 RC4：KSA 用 key 循环初始化 S 盒，PRGA 逐字节 XOR。
/// 注意 catbus 的 `rc4([nonce], ...)` 传入的是**单字节 key**（nonce），
/// 这里 key 支持任意长度，单字节是其自然子集。
Uint8List rc4(List<int> key, List<int> data) {
  // KSA
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xff;
    final tmp = s[i];
    s[i] = s[j];
    s[j] = tmp;
  }
  // PRGA
  final out = Uint8List(data.length);
  var i = 0;
  j = 0;
  for (var k = 0; k < data.length; k++) {
    i = (i + 1) & 0xff;
    j = (j + s[i]) & 0xff;
    final tmp = s[i];
    s[i] = s[j];
    s[j] = tmp;
    out[k] = data[k] ^ s[(s[i] + s[j]) & 0xff];
  }
  return out;
}

/// 自定义 base64：按给定字母表编码，非 3 对齐处补 `=`。
///
/// 逐字节读入，按标准 base64 的 3→4 分组，但输出字符取自 [alphabet]。
/// 与标准库的差异只在字母表；换回标准表应与 `base64.encode` 一致（有测试）。
String b64Custom(List<int> data, String alphabet) {
  final out = StringBuffer();
  for (var i = 0; i < data.length; i += 3) {
    final n = data.length - i;
    final b0 = data[i];
    final b1 = n > 1 ? data[i + 1] : 0;
    final b2 = n > 2 ? data[i + 2] : 0;
    final v = (b0 << 16) | (b1 << 8) | b2;
    out.write(alphabet[(v >> 18) & 63]);
    out.write(alphabet[(v >> 12) & 63]);
    out.write(n > 1 ? alphabet[(v >> 6) & 63] : '=');
    out.write(n > 2 ? alphabet[v & 63] : '=');
  }
  return out.toString();
}

/// strData 编码：`base64Custom([0x41, nonce, ...rc4([nonce], utf8(plaintext))])`。
///
/// [nonce] 是 0–255 的随机字节，作为 RC4 的单字节密钥，同时明写在
/// 输出头部第二个字节，服务端据此解密。
String encodeStrData(String plaintext, int nonce) {
  final cipher = rc4([nonce], utf8.encode(plaintext));
  final bytes = Uint8List(cipher.length + 2)
    ..[0] = 0x41
    ..[1] = nonce & 0xff
    ..setRange(2, cipher.length + 2, cipher);
  return b64Custom(bytes, strDataAlphabet);
}
