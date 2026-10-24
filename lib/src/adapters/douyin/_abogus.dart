/// 抖音 `a_bogus` 签名，纯 Dart 实现。
///
/// # 来源
///
/// 移植自 `_abogus_research/evil0ctal/Douyin_TikTok_Download_API-main`
/// 的 `src/dtk/signing/native/abogus.py`（Apache-2.0）。
/// 该实现是从抖音自己的 `bdms.js` 逆向而来：
/// 它是一个 webpack 打包的字节码 VM，程序体可离线解码
/// （base64 → 按字节 4..7 为 key 的 XOR → DEFLATE）得到 1001 个字符串
/// 与 796 个函数，`fn150` 是签名生成器。
///
/// # 为什么需要它
///
/// 抖音的 `check_qrconnect`（登录轮询）不带 `a_bogus` 会返回
/// `error_code: 4031`（安全风险，已阻止访问）。带上它之后才返回
/// `error_code: 0`。
///
/// # 结构
///
/// 签名 = base64( header + RC4(version + frame) )
///
///  - `header`：2 字节 magic（3, 82），用 0xAA/0x55 掩码扩成 4 字节
///  - `version`：SDK 版本 [1,0,1,0]，同样扩成 8 字节
///  - `frame`：50 个标量字段 + 浏览器几何串 + 尾部 + 校验和，
///    用 NOISE_MASKS 扩成 4/3 倍
///  - `RC4`：不是教科书 RC4（S-box 降序初始化 + key schedule 用乘法）
///  - `base64`：自定义字母表 `s4`
///
/// # 噪声
///
/// 签名里有多处随机噪声（`rng`）。**任何合法的噪声都能通过校验**，
/// 因为服务端校验的是结构（header magic、SDK 版本、校验和），
/// 不校验噪声值。因此可以用固定种子的伪随机，便于测试复现。
library;

import 'dart:math';

import 'sm3.dart';

/// `s4` 字母表（用于编码最终签名）。
const String _alphabetS4 =
    'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';

/// `s3` 字母表（用于编码 UA 的 RC4 结果）。
const String _alphabetS3 =
    'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';

/// 哈希前附加到 query 与 body 的常量。
const String _salt = 'dhzx';

/// header 的明文 magic。
const List<int> _headerMagic = [3, 82];

/// SDK 版本块。
const List<int> _sdkVersion = [1, 0, 1, 0];

/// RC4 的密钥（单字节）。
const int _payloadKey = 0xD3;

/// 2024-07-24T16:00:00Z，一个字段从此刻起算「双周数」。
const int _fortnightEpochMs = 1721836800000;

const int _aid = 6383;

const List<int> _noiseMasks = [0x91, 0x42, 0x2C];
const List<int> _dataMasks = [0x6E, 0xBD, 0xD3];

/// 50 个标量字段被打进 body 的顺序。
const List<String> _fieldOrder = [
  'L34', 'L44', 'L56', 'L61', 'L73', 'L29', 'L70', 'L45', 'L35', 'L49',
  'L38', 'L66', 'L51', 'L68', 'L28', 'L48', 'L64', 'L47', 'L30', 'L71',
  'L26', 'L55', 'L31', 'L69', 'L59', 'L40', 'L62', 'L63', 'L27', 'L72',
  'L41', 'L74', 'L57', 'L52', 'L42', 'L39', 'L33', 'L67', 'L53', 'L43',
  'L65', 'L46', 'L36', 'L24', 'L60', 'L32', 'L79', 'L80', 'L84', 'L85',
];

/// `L35/L36`：SDK 主版本号（catbus `SDK_VERSION_CODE = 1`）。
const int _envFlags = 1;

/// `L38/L39`：`1 | (Firefox << 5)`。Chrome 下就是 1。
///
/// 之前这里写死 `0x21`（含 Firefox 位），对 Chrome 的 UA 是错的——
/// 与 catbus 的 `flags = 1 | (browserName === 'Firefox') << 5` 对照才发现。
int _flagsFor(String ua) => 1 | (ua.toLowerCase().contains('firefox') ? 32 : 0);

const int _tripwireLocked = 3;
const int _callBucket = 6;

/// `L77`：`inner|inner|outer|outer|avail|avail|screen|screen|Win32`。
///
/// 与设备画像（2560×1440）一致；catbus 用 `[...PROFILE.geo, 'Win32'].join('|')`。
const String _defaultBrowserInfo =
    '2560|1215|2560|1392|2560|1392|2560|1440|Win32';

/// 浏览器族对应的 header 噪声基值。
const Map<String, int> _headerNoiseBands = {
  'edge': 0x08,
  'chrome': 0x10,
  'firefox': 0x18,
  'safari': 0x20,
  'huawei': 0x28,
  'other': 0x30,
};

/// 每个 host 的签名参数。
///
/// # 为什么必须区分（catbus `HOST_ABOGUS` / `HOST_APP_IDS`）
///
/// `a_bogus` 的 50 个标量字段里有三个是**按域名写死**的：SDK 次版本号
/// （`L44..47`）与 `l40/l41/l42`。签名时用错域名的那份，服务端直接判
/// 无效——而且不报错，只给"风控"话术。
///
/// | host | aid | pageId | sdkMinor | l40/l41/l42 |
/// |---|---|---|---|---|
/// | `www.douyin.com` | 6383 | 11881 | 8 | 132 / 1 / 1 |
/// | `login.douyin.com` | 6383 | 6241 | 14 | 0 / 0 / 0 |
class ABogusHost {
  const ABogusHost({
    required this.pageId,
    required this.sdkMinor,
    required this.nrTag,
  });

  final int pageId;
  final int sdkMinor;
  final List<int> nrTag;

  static const ABogusHost login = ABogusHost(
    pageId: 6241,
    sdkMinor: 14,
    nrTag: [0, 0, 0, 0],
  );

  /// `l40/l41/l42` 必须补齐到 4 个元素：`L40..L43` 全部参与签名，
  /// 少一个就会在组装 body 时取到 null（真实踩过的 bug）。
  static const ABogusHost www = ABogusHost(
    pageId: 11881,
    sdkMinor: 8,
    nrTag: [132, 1, 1, 0],
  );

  /// 按域名取配置；未收录的域名按主站处理（与 catbus 一致）。
  static ABogusHost forHost(String host) =>
      host.contains('login.douyin.com') ? login : www;
}

/// 计算 `a_bogus`。
class ABogus {
  ABogus({
    required this.userAgent,
    this.browserInfo = _defaultBrowserInfo,
    Random? rng,
  }) : _rng = rng ?? Random();

  final String userAgent;
  final String browserInfo;
  final Random _rng;

  /// 为一个请求计算 `a_bogus`。
  ///
  /// [query] 是即将发送的 query 串（**不含** `a_bogus` 本身）。
  /// [body] 是 POST 的请求体；它会被哈希，所以签名空 body 是错的。
  /// [host] 决定 [ABogusHost] 配置；默认主站（与 catbus 一致）。
  String getValue(
    String query, {
    String body = '',
    String host = 'www.douyin.com',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _fortnightEpochMs) {
      // 时钟早于纪元说明传了秒而不是毫秒，签出来的值会静默错误。
      throw StateError('clock is before the a_bogus epoch: $now');
    }

    final fields = _computeFields(query, body, now, ABogusHost.forHost(host));

    // version 块：4 个字节的 SDK 版本扩成 8 字节
    final version = <int>[
      ..._maskPair([_sdkVersion[0], _sdkVersion[1]]),
      ..._maskPair(
        [_sdkVersion[2], _sdkVersion[3]],
        low: _probeNoise(),
        high: _tripwireNoise(),
      ),
    ];

    // 校验和：version + 50 个标量字段的 XOR
    var checksum = 0;
    for (final b in version) {
      checksum ^= b;
    }
    for (final name in _fieldOrder) {
      checksum ^= fields[name]!;
    }

    // body：50 字段 + 几何串 + 尾部 + 校验和
    final bodyBytes = <int>[
      for (final name in _fieldOrder) fields[name]!,
      ...jsBytes(browserInfo),
      ...jsBytes('${(now + 3) & 0xFF},'),
      checksum,
    ];

    final header = _maskPair(
      _headerMagic,
      high: _headerNoise(),
    );

    final frame = _expandNoise(bodyBytes);
    final sealed = _rc4([_payloadKey], [...version, ...frame]);

    return _encodeBase64([...header, ...sealed], _alphabetS4);
  }

  /// 计算 50 个标量字段。
  Map<String, int> _computeFields(
    String query,
    String body,
    int nowMs,
    ABogusHost host,
  ) {
    final queryDigest = _digestOf(query);
    final bodyDigest = _digestOf(body);
    final uaDigest = _userAgentDigest(userAgent, host);

    final ink = nowMs - 1;
    final fortnights =
        (nowMs - _fortnightEpochMs) ~/ (1000 * 60 * 60 * 24 * 14);
    final infoBytes = jsBytes(browserInfo);
    final tailBytes = jsBytes('${(nowMs + 3) & 0xFF},');

    final fields = <String, int>{
      'L24': 41,
      'L26': fortnights,
      'L27': _callBucket,
      'L28': 3,
      'L35': _envFlags & 0xFF,
      'L36': (_envFlags ~/ 256) & 0xFF,
      'L38': _flagsFor(userAgent) & 0xFF,
      'L39': (_flagsFor(userAgent) >> 8) & 0xFF,
      'L66': _tripwireLocked,
      'L79': infoBytes.length & 0xFF,
      'L80': (infoBytes.length >> 8) & 0xFF,
      'L84': tailBytes.length & 0xFF,
      'L85': (tailBytes.length >> 8) & 0xFF,
    };

    final nowLe = _leBytes(nowMs, 6);
    for (var i = 0; i < nowLe.length; i++) {
      fields['L${29 + i}'] = nowLe[i];
    }

    final detectLe = _leBytes(host.sdkMinor, 4);
    for (var i = 0; i < detectLe.length; i++) {
      fields['L${44 + i}'] = detectLe[i];
    }

    // L40..L43 必须四个都在（缺一个会在 _fieldOrder 取值时 null check 崩）
    for (var i = 0; i < 4; i++) {
      fields['L${40 + i}'] = i < host.nrTag.length ? host.nrTag[i] : 0;
    }

    final inkLe = _leBytes(ink, 6);
    for (var i = 0; i < inkLe.length; i++) {
      fields['L${60 + i}'] = inkLe[i];
    }

    final pageLe = _leBytes(host.pageId, 4);
    for (var i = 0; i < pageLe.length; i++) {
      fields['L${67 + i}'] = pageLe[i];
    }

    final aidLe = _leBytes(_aid, 4);
    for (var i = 0; i < aidLe.length; i++) {
      fields['L${71 + i}'] = aidLe[i];
    }

    // 三条哈希链
    // query → L48, L49, L51
    fields['L48'] = queryDigest[9];
    fields['L49'] = queryDigest[18];
    fields['L51'] = _canary(queryDigest, 11, 12, 12);
    // body → L52, L53, L55
    fields['L52'] = bodyDigest[10];
    fields['L53'] = bodyDigest[19];
    fields['L55'] = _canary(bodyDigest, 8, 9, 9);
    // user agent → L56, L57, L59
    fields['L56'] = uaDigest[11];
    fields['L57'] = uaDigest[21];
    fields['L59'] = _canary(uaDigest, 12, 13, 13);

    return fields;
  }

  /// `SM3(SM3(text + SALT))`。
  List<int> _digestOf(String text) =>
      sm3Hash(sm3OfString(text + _salt));

  /// UA 链：RC4 → base64(s3) → 单次 SM3。
  ///
  /// key 的前两个字节是 SDK 版本号，第三个是**按域名不同**的次版本号——
  /// 这就是为什么同一份 UA 在不同 host 下算出的 `a_bogus` 不能互换。
  List<int> _userAgentDigest(String ua, ABogusHost host) {
    final key = [
      _envFlags ~/ 256,
      _envFlags % 256,
      host.sdkMinor % 256,
    ];
    final sealed = _rc4(key, jsBytes(ua.trim()));
    return sm3OfString(_encodeBase64(sealed, _alphabetS3));
  }

  // ── 噪声 ────────────────────────────────────────────────────

  int _headerNoise() {
    final family = _familyOf(userAgent);
    final base = _headerNoiseBands[family] ?? _headerNoiseBands['other']!;
    return (base + (_rng.nextDouble() * 40).floor()) & 0xFF;
  }

  int _probeNoise() {
    final value = (_rng.nextDouble() * 240).floor();
    return value > 109 ? value + value % 2 + 1 : value;
  }

  int _tripwireNoise() {
    const free = 0xF3;
    const set = 0x0C;
    return ((_rng.nextDouble() * 255).floor() & free) | set;
  }

  static String _familyOf(String ua) {
    final lower = ua.toLowerCase();
    for (final name in ['edg', 'huawei', 'firefox', 'chrome', 'safari']) {
      if (lower.contains(name)) {
        return name == 'edg' ? 'edge' : name;
      }
    }
    return 'other';
  }

  // ── 编解码 ──────────────────────────────────────────────────

  /// 两个字节扩成四个，每个输出字节一半来自载荷、一半来自噪声。
  List<int> _maskPair(
    List<int> pair, {
    int? low,
    int? high,
  }) {
    final noise = (_rng.nextDouble() * 65535).floor();
    final lo = low ?? (noise & 0xFF);
    final hi = high ?? ((noise >> 8) & 0xFF);
    return [
      (lo & 0xAA) | (pair[0] & 0x55),
      (lo & 0x55) | (pair[0] & 0xAA),
      (hi & 0xAA) | (pair[1] & 0x55),
      (hi & 0x55) | (pair[1] & 0xAA),
    ];
  }

  /// 三个字节 + 一个噪声字节 → 四个载体字节。
  List<int> _expandNoise(List<int> body) {
    final out = <int>[];
    for (var offset = 0; offset < body.length; offset += 3) {
      final remain = body.length - offset;
      if (remain < 3) {
        out.add(body[offset]);
        if (remain > 1 && body[offset + 1] != 0) {
          out.add(body[offset + 1]);
        }
        continue;
      }
      final noise = ((_rng.nextDouble() * 1000).floor()) & 0xFF;
      final b0 = body[offset];
      final b1 = body[offset + 1];
      final b2 = body[offset + 2];
      out.add((noise & _noiseMasks[0]) | (b0 & _dataMasks[0]));
      out.add((noise & _noiseMasks[1]) | (b1 & _dataMasks[1]));
      out.add((noise & _noiseMasks[2]) | (b2 & _dataMasks[2]));
      // 第四个字节收集前三个让出的位
      out.add(
        ((b0 & _noiseMasks[0]) |
                (b1 & _noiseMasks[1]) |
                (b2 & _noiseMasks[2])) &
            0xFF,
      );
    }
    return out;
  }

  /// SDK 的 RC4：S-box 降序初始化 + key schedule 用乘法。
  static List<int> _rc4(List<int> key, List<int> data) {
    final box = List<int>.generate(256, (i) => 255 - i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j * box[i] + j + key[i % key.length]) % 256;
      final t = box[i];
      box[i] = box[j];
      box[j] = t;
    }

    final out = List<int>.filled(data.length, 0);
    var i = 0;
    j = 0;
    for (var k = 0; k < data.length; k++) {
      i = (i + 1) % 256;
      j = (j + box[i]) % 256;
      final t = box[i];
      box[i] = box[j];
      box[j] = t;
      final ks = box[(box[i] + box[j]) % 256];
      out[k] = data[k] ^ ks;
    }
    return out;
  }

  /// 用自定义字母表的 base64。
  static String _encodeBase64(List<int> data, String alphabet) {
    final out = StringBuffer();
    var count = 0;
    for (var offset = 0; offset < data.length; offset += 3) {
      final remain = data.length - offset;
      final b0 = data[offset];
      final b1 = remain > 1 ? data[offset + 1] : 0;
      final b2 = remain > 2 ? data[offset + 2] : 0;
      final block = (b0 << 16) | (b1 << 8) | b2;
      final digits = [
        (block >> 18) & 0x3F,
        (block >> 12) & 0x3F,
        (block >> 6) & 0x3F,
        block & 0x3F,
      ];
      final take = remain >= 3 ? 4 : remain + 1;
      for (var i = 0; i < take; i++) {
        out.write(alphabet[digits[i]]);
        count++;
      }
    }
    final pad = (4 - count % 4) % 4;
    for (var i = 0; i < pad; i++) {
      out.write('=');
    }
    return out.toString();
  }

  // ── 工具 ────────────────────────────────────────────────────

  /// 取 digest 中从 [offset] 起第一个不等于 [sentinel] 的字节。
  static int _canary(List<int> digest, int offset, int sentinel, int fallback) {
    for (var i = offset; i < digest.length; i++) {
      if (digest[i] != sentinel) return digest[i];
    }
    return fallback;
  }

  /// [count] 个小端字节。
  static List<int> _leBytes(int value, int count) =>
      [for (var i = 0; i < count; i++) (value >> (8 * i)) & 0xFF];
}

/// 按 JavaScript 的规则把字符串转成字节。
///
/// **不是 UTF-8**：SDK 走 UTF-16 码元，每个码元小于 U+0100 时输出 1 字节，
/// 否则输出 2 个大端字节。所以中文是 2 字节（UTF-8 是 3 字节），
/// 代理对是 4 字节。
List<int> jsBytes(String text) {
  final out = <int>[];
  for (final rune in text.runes) {
    if (rune <= 0xFFFF) {
      if (rune & 0xFF00 != 0) {
        out.add((rune >> 8) & 0xFF);
      }
      out.add(rune & 0xFF);
    } else {
      // 代理对：拆成高低两个码元
      final v = rune - 0x10000;
      final hi = 0xD800 | (v >> 10);
      final lo = 0xDC00 | (v & 0x3FF);
      for (final unit in [hi, lo]) {
        if (unit & 0xFF00 != 0) {
          out.add((unit >> 8) & 0xFF);
        }
        out.add(unit & 0xFF);
      }
    }
  }
  return out;
}
