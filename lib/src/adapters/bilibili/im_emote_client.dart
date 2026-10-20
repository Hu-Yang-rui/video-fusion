/// B 站表情面板客户端。
///
/// # 接口（从 `bili-emoji-picker.js` 挖出，2026-10-19）
///
/// ```js
/// GET //api.bilibili.com/x/emote/user/panel/web
///     ?business=reply        // 注意：不是 "im"
/// ```
///
/// 响应：
/// ```json
/// {"code":0,"data":{
///   "setting":{"recent_limit":150,"attr":-1,"focus_pkg_id":1,"schema":"..."},
///   "packages":[
///     {"id":..,"text":"颜文字","type":..,"url":"<包封面>",
///      "emote":[
///        {"id":..,"name":"doge","text":"[doge]","type":1,
///         "url":"https://.../doge.png",
///         "gif_url":"https://.../doge.gif",   // 动图（部分表情有）
///         "webp_url":"https://.../doge.webp",
///         "size":1,"meta":{...}}
///      ]}
///   ]
/// }}
/// ```
///
/// # 实测边界（必须记住）
///
/// | 场景 | 实测结果 |
/// |---|---|
/// | 匿名请求 | `code=0` 但 `packages: null`（静默空，不是报错） |
/// | 带 Cookie（已失效） | 同样 `packages: null` |
/// | 带有效 Cookie | **未实测**（本地凭证失效） |
///
/// 也就是说：**接口存在、参数形态来自官方前端代码，但"能拿到表情包列表"
/// 这一步本项目没有验证过**。因此：
///  - 拿不到列表时，表情面板如实显示"当前无法加载表情"，**不放假表情**
///  - 不把 `packages: null` 当成"用户没有收藏表情"——那是两回事
///
/// # 与 `business=im` 的区别
///
/// 前端代码里写死的是 `business:"reply"`（回复场景）。
/// 实测 `business=im` 也返回 `code=0` 但同样是 `packages: null`，
/// 无法判断哪个才是私信场景的正确值。这里用前端实际使用的 `reply`，
/// 并把不确定性写进报告。
library;

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';
import '../../models/im.dart';

/// B 站表情面板客户端。
class BilibiliEmoteClient {
  BilibiliEmoteClient({
    required FusionHttpClient http,
    required this.platformId,
    FusionLogger? logger,
    String apiBase = 'https://api.bilibili.com',
  })  : _http = http,
        _logger = logger ?? appLogger,
        _apiBase = apiBase;

  final FusionHttpClient _http;
  final String platformId;
  final FusionLogger _logger;
  final String _apiBase;

  /// 拉取表情面板。
  ///
  /// 失败不抛异常，返回 [ImEmotePanel.loaded] 为 false 并带原因 ——
  /// 表情面板加载不出来不该让整个聊天页报错。
  Future<ImEmotePanel> fetchPanel({required PlatformSession session}) async {
    try {
      final json = await _http.getJson(
        '$_apiBase/x/emote/user/panel/web?business=reply',
        headers: {
          'Referer': 'https://message.bilibili.com/',
          'Cookie': session.cookieHeader,
          'Accept': 'application/json, text/plain, */*',
        },
        platformId: platformId,
      );

      final code = json['code'];
      if (code != 0) {
        return ImEmotePanel(
          unavailableReason: _reasonFor(code, json['message']),
        );
      }

      final data = json['data'];
      if (data is! Map) {
        return const ImEmotePanel(
          unavailableReason: '平台没有返回表情数据。',
        );
      }
      final d = Map<String, Object?>.from(data);
      final rawPackages = d['packages'];

      // ⚠️ 实测：未登录时 `packages` 是 **null**（不是空数组）。
      // 这是"拿不到"，不是"没有表情"。
      if (rawPackages == null) {
        return const ImEmotePanel(
          unavailableReason: '当前登录态下无法读取表情包列表。',
        );
      }
      if (rawPackages is! List) {
        return const ImEmotePanel(
          unavailableReason: '表情数据格式无法识别。',
        );
      }

      final packages = <ImEmotePackage>[];
      for (final raw in rawPackages) {
        if (raw is! Map) continue;
        final parsed = _parsePackage(Map<String, Object?>.from(raw));
        if (parsed != null && !parsed.isEmpty) packages.add(parsed);
      }

      return ImEmotePanel(packages: packages, loaded: true);
    } catch (e) {
      _logger.warn('emote panel: request failed', {
        'error': e.runtimeType.toString(),
      });
      return const ImEmotePanel(
        unavailableReason: '表情加载失败，请检查网络后重试。',
      );
    }
  }

  ImEmotePackage? _parsePackage(Map<String, Object?> m) {
    final id = _toInt(m['id']);
    final rawEmotes = m['emote'];
    if (id == null || rawEmotes is! List) return null;

    final name = (m['text'] as String?)?.trim();
    final emotes = <ImEmote>[];
    for (final raw in rawEmotes) {
      if (raw is! Map) continue;
      final e = Map<String, Object?>.from(raw);
      final url = (e['url'] as String?)?.trim();
      final emoteName = (e['name'] as String?)?.trim();
      if (url == null || url.isEmpty || emoteName == null || emoteName.isEmpty) {
        continue;
      }
      emotes.add(ImEmote(
        name: emoteName,
        shortcode: '[${(e['text'] as String?)?.trim().isNotEmpty == true ? (e['text'] as String).trim() : emoteName}]',
        url: url,
        animatedUrl: _firstNonEmpty([e['gif_url'], e['webp_url']]),
        id: _toInt(e['id']),
        packageId: id,
        packageName: name,
      ));
    }

    return ImEmotePackage(
      id: id,
      name: (name == null || name.isEmpty) ? '表情 $id' : name,
      coverUrl: (m['url'] as String?)?.trim(),
      emotes: emotes,
    );
  }

  String _reasonFor(Object? code, Object? message) {
    final msg = message?.toString() ?? '';
    return switch (code) {
      -101 => '需要登录 B 站账号后才能使用表情。',
      412 => '表情请求过于频繁，请稍后再试。',
      _ => msg.isEmpty ? '表情加载失败（平台返回 $code）。' : msg,
    };
  }

  static String? _firstNonEmpty(List<Object?> candidates) {
    for (final c in candidates) {
      if (c is String && c.trim().isNotEmpty) return c;
    }
    return null;
  }

  static int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// 把表情客户端失败归一化为 [FusionException]。
FusionException emoteErrorToFusion(Object error, {String? platformId}) {
  if (error is FusionException) return error;
  return FusionException(
    code: FusionErrorCode.upstreamError,
    userMessage: '表情加载失败，请稍后重试。',
    technicalMessage: '${error.runtimeType}: $error',
    platformId: platformId,
  );
}
