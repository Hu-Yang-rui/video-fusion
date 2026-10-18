/// B站 wbi 签名。
///
/// # 为什么需要
///
/// `getDanmuInfo`（直播弹幕服务器配置）**需要 wbi 签名**。
/// 不带签名会返回 `code = -352`。
///
/// 之前本项目把这个 -352 误判为"需要登录"，实测证明不是：
/// 加上 wbi 签名后 `code = 0`，匿名即可拿到 token 与 host_list。
///
/// # 算法（与 blivedm / SocialSisterYi 文档一致）
///
/// ```
/// 1. GET /x/web-interface/nav 取 data.wbi_img.img_url / sub_url
/// 2. 取两个 URL 的文件名（去扩展名）拼成 raw
/// 3. 按 mixinKeyEncTab 重排 raw，取前 32 位 = mixin_key
/// 4. 参数 + wts 时间戳，按 key 排序，剥掉 !'()* 五个字符，urlencode
/// 5. md5(query + mixin_key) = w_rid
/// ```
///
/// # 缓存
///
/// wbi key 约 12 小时轮换。这里缓存 11 小时 50 分，与 blivedm 一致。
/// 服务端返回 -352 时调用 [invalidate] 强制刷新。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';

/// B站 wbi 签名器。
class WbiSigner {
  WbiSigner({required FusionHttpClient http, FusionLogger? logger})
      : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  /// mixinKeyEncTab（与官方前端一致）。
  static const List<int> _mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
  ];

  /// 缓存有效期：11 小时 50 分（官方 key 约 12 小时轮换）。
  static const Duration _ttl = Duration(hours: 11, minutes: 50);

  String? _mixinKey;
  DateTime? _fetchedAt;

  /// 是否已有可用 key。
  bool get hasKey => _mixinKey != null;

  /// 让缓存失效（服务端返回 -352 时调用）。
  void invalidate() {
    _mixinKey = null;
    _fetchedAt = null;
    _logger.debug('wbi: key invalidated');
  }

  /// 给参数加上 wbi 签名，返回完整的 query 串（含 `w_rid`）。
  ///
  /// 调用方把返回值直接拼到 URL 的 `?` 后面即可。
  Future<String> sign(Map<String, Object> params) async {
    final key = await _ensureKey();
    final withTs = <String, Object>{
      ...params,
      'wts': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    };

    final sortedKeys = withTs.keys.toList()..sort();
    final pairs = <String>[];
    for (final k in sortedKeys) {
      // 官方要求剥掉 !'()* 这五个字符，否则签名对不上
      final v = '${withTs[k]}'.replaceAll(RegExp(r"[!'()*]"), '');
      pairs.add('${Uri.encodeQueryComponent(k)}='
          '${Uri.encodeQueryComponent(v)}');
    }
    final query = pairs.join('&');
    final wRid = _md5Hex('$query$key');

    return '$query&w_rid=$wRid';
  }

  /// 确保有可用 key，必要时拉取。
  Future<String> _ensureKey() async {
    final cached = _mixinKey;
    final at = _fetchedAt;
    if (cached != null && at != null) {
      if (DateTime.now().difference(at) < _ttl) return cached;
    }
    return _fetchKey();
  }

  /// 拉取并计算 mixin key。
  Future<String> _fetchKey() async {
    final json = await _http.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      headers: const {
        'Referer': 'https://www.bilibili.com/',
        'Accept': 'application/json',
      },
      platformId: 'bilibili',
    );

    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '无法获取接口签名所需的密钥。',
        technicalMessage: 'wbi: nav.data is not a map',
        platformId: 'bilibili',
      );
    }
    final wbiImg = data['wbi_img'];
    if (wbiImg is! Map) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '无法获取接口签名所需的密钥。',
        technicalMessage: 'wbi: nav.data.wbi_img missing',
        platformId: 'bilibili',
      );
    }

    final imgUrl = '${wbiImg['img_url'] ?? ''}';
    final subUrl = '${wbiImg['sub_url'] ?? ''}';
    final imgKey = _fileStem(imgUrl);
    final subKey = _fileStem(subUrl);
    if (imgKey.isEmpty || subKey.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '接口签名密钥格式异常。',
        technicalMessage: 'wbi: img_key="$imgKey" sub_key="$subKey"',
        platformId: 'bilibili',
      );
    }

    final raw = '$imgKey$subKey';
    final buf = StringBuffer();
    for (final i in _mixinKeyEncTab) {
      if (i < raw.length) buf.write(raw[i]);
    }
    final full = buf.toString();
    final mixin = full.length >= 32 ? full.substring(0, 32) : full;

    _mixinKey = mixin;
    _fetchedAt = DateTime.now();
    _logger.info('wbi: key refreshed');
    return mixin;
  }

  /// 从 URL 取文件名（去扩展名）。
  static String _fileStem(String url) {
    final last = url.split('/').last;
    final dot = last.indexOf('.');
    return dot > 0 ? last.substring(0, dot) : last;
  }

  /// md5 hex（项目已依赖 crypto 包）。
  static String _md5Hex(String text) =>
      crypto.md5.convert(utf8.encode(text)).toString();
}
