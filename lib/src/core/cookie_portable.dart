/// Cookie 导入 / 导出。
///
/// # 用途
///
/// 让用户把已登录的 Cookie 从别处（浏览器开发者工具、另一台设备）
/// 搬进本应用，或者把本机的登录态备份出来。解决两个真实痛点：
///
///  1. 扫码登录偶尔失败（网络/风控），但用户在浏览器里是登录状态
///  2. 换设备后不想重新扫码
///
/// # 支持导入的格式
///
/// 1. **原始 Cookie 头**（最常用，从浏览器 F12 → Network → Request Headers 复制）
///    ```
///    SESSDATA=abc%2Cdef; bili_jct=xyz; DedeUserID=12345
///    ```
/// 2. **带 `Cookie:` 前缀**（从 curl 命令里复制）
///    ```
///    Cookie: SESSDATA=abc; bili_jct=xyz
///    ```
/// 3. **JSON 键值对象**
///    ```json
///    {"SESSDATA": "abc", "bili_jct": "xyz"}
///    ```
/// 4. **本应用导出的完整格式**（含平台与用户信息）
///
/// # 安全边界
///
///  - 导出的文本**包含明文凭证**，UI 必须明确警告
///  - 本模块不写日志、不落盘，只做内存中的字符串转换
///  - 解析失败不抛裸异常，统一返回带原因的 [CookieImportResult]
library;

import 'dart:convert';

import 'credential_vault.dart';

/// 导入结果。
class CookieImportResult {
  const CookieImportResult._({
    required this.ok,
    this.session,
    this.error,
    this.platformId,
    this.cookieNames = const [],
  });

  /// 成功。
  factory CookieImportResult.success({
    required PlatformSession session,
    required String platformId,
  }) =>
      CookieImportResult._(
        ok: true,
        session: session,
        platformId: platformId,
        cookieNames: session.cookies.keys.toList(),
      );

  /// 失败（附面向用户的原因）。
  factory CookieImportResult.failure(String error) =>
      CookieImportResult._(ok: false, error: error);

  final bool ok;

  /// 成功时的会话对象。
  final PlatformSession? session;

  /// 失败原因（面向用户，可直接展示）。
  final String? error;

  /// 识别出的平台 ID。
  final String? platformId;

  /// 解析到的 Cookie 名（**不含值**，可安全展示）。
  final List<String> cookieNames;
}

/// Cookie 导入导出工具。
class CookiePortable {
  const CookiePortable._();

  /// 各平台的特征 Cookie。
  ///
  /// 用于从裸 Cookie 串推断平台。只放**足以唯一识别**的键名，
  /// 不做模糊匹配——猜错平台比不猜更糟。
  static const Map<String, List<String>> _platformSignatures = {
    'bilibili': ['SESSDATA', 'bili_jct', 'DedeUserID'],
    'douyin': ['sessionid', 'sessionid_ss', 'sid_tt', 'passport_csrf_token'],
  };

  /// 判断一段 Cookie 名集合属于哪个平台。
  ///
  /// 返回 null 表示无法确定。调用方应要求用户手动指定，
  /// 而不是猜一个默认值。
  static String? detectPlatform(Iterable<String> cookieNames) {
    final names = cookieNames.map((e) => e.toLowerCase()).toSet();
    for (final entry in _platformSignatures.entries) {
      for (final sig in entry.value) {
        if (names.contains(sig.toLowerCase())) return entry.key;
      }
    }
    return null;
  }

  /// 解析用户粘贴的文本。
  ///
  /// [platformHint] 为已知平台（例如从某个平台的账号行里点的导入），
  /// 为 null 时自动识别。
  static CookieImportResult parse(
    String input, {
    String? platformHint,
    String? displayName,
    String? userId,
  }) {
    final text = input.trim();
    if (text.isEmpty) {
      return CookieImportResult.failure('内容为空，请粘贴 Cookie 后再试。');
    }

    // 1. 先尝试本应用导出的完整格式（含 platformId 字段）
    final asExport = _tryParseExportJson(text);
    if (asExport != null) {
      return _buildSession(
        asExport.cookies,
        platformId: platformHint ?? asExport.platformId,
        displayName: displayName ?? asExport.displayName,
        userId: userId ?? asExport.userId,
      );
    }

    // 2. 尝试 JSON 键值对象
    final asJson = _tryParseJsonMap(text);
    if (asJson != null) {
      return _buildSession(
        asJson,
        platformId: platformHint,
        displayName: displayName,
        userId: userId,
      );
    }

    // 3. 当作原始 Cookie 串
    final asRaw = parseCookieHeader(text);
    if (asRaw.isEmpty) {
      return CookieImportResult.failure(
        '无法识别该内容。请粘贴形如 `SESSDATA=xxx; bili_jct=yyy` 的 Cookie 串。',
      );
    }

    return _buildSession(
      asRaw,
      platformId: platformHint,
      displayName: displayName,
      userId: userId,
    );
  }

  /// 解析原始 Cookie 头字符串。
  ///
  /// 容忍：
  ///  - 前导 `Cookie:` / `cookie:` 前缀
  ///  - 换行（多行粘贴）
  ///  - 多余空格
  ///  - 值里带 `=`（只按第一个 `=` 切分）
  static Map<String, String> parseCookieHeader(String input) {
    var text = input.trim();

    // 去掉 "Cookie:" 前缀
    final prefixMatch = RegExp(r'^cookie\s*:\s*', caseSensitive: false)
        .firstMatch(text);
    if (prefixMatch != null) {
      text = text.substring(prefixMatch.end);
    }

    // 多行合并
    text = text.replaceAll(RegExp(r'[\r\n]+'), ' ');

    final out = <String, String>{};
    for (final part in text.split(';')) {
      final seg = part.trim();
      if (seg.isEmpty) continue;

      final eq = seg.indexOf('=');
      if (eq <= 0) continue; // 没有等号或键为空，跳过

      final key = seg.substring(0, eq).trim();
      var value = seg.substring(eq + 1).trim();

      // 去掉值两侧的引号（有些工具会加）
      if (value.length >= 2) {
        final first = value[0];
        final last = value[value.length - 1];
        if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
          value = value.substring(1, value.length - 1);
        }
      }

      if (key.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  /// 导出为可读文本。
  ///
  /// 输出是**明文凭证**，调用方必须向用户明确提示。
  static String exportSession(PlatformSession session) {
    final payload = <String, Object?>{
      'format': 'video-fusion.cookies',
      'version': 1,
      'platformId': session.platformId,
      'displayName': session.displayName,
      'userId': session.userId,
      'loggedInAt': session.loggedInAt,
      'cookies': session.cookies,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 导出为单行 Cookie 头（便于粘贴到别处）。
  static String exportCookieHeader(PlatformSession session) =>
      session.cookieHeader;

  /// 把 Cookie 名做脱敏预览，用于确认弹窗。
  ///
  /// 只显示键名与值长度，**不显示值本身**。
  static String describeCookies(Map<String, String> cookies) {
    if (cookies.isEmpty) return '（无 Cookie）';
    final parts = cookies.entries
        .map((e) => '${e.key}(${e.value.length}字符)')
        .toList();
    return parts.join('、');
  }

  // ── 内部 ────────────────────────────────────────────────────

  static CookieImportResult _buildSession(
    Map<String, String> cookies, {
    String? platformId,
    String? displayName,
    String? userId,
  }) {
    if (cookies.isEmpty) {
      return CookieImportResult.failure('未解析出任何 Cookie。');
    }

    final resolved = platformId ?? detectPlatform(cookies.keys);
    if (resolved == null) {
      return CookieImportResult.failure(
        '无法判断这些 Cookie 属于哪个平台。'
        '请从对应平台的账号行进入导入，或粘贴包含 '
        '`platformId` 字段的导出内容。',
      );
    }

    // 至少要有该平台的一个特征 Cookie，避免把 A 平台的 Cookie
    // 存进 B 平台的槽位
    final sigs = _platformSignatures[resolved];
    if (sigs != null) {
      final hasSig = sigs.any((s) => cookies.keys.any(
            (k) => k.toLowerCase() == s.toLowerCase(),
          ));
      if (!hasSig) {
        return CookieImportResult.failure(
          '这些 Cookie 里没有 $resolved 的关键字段'
          '（${sigs.join(' / ')}），可能复制错了。',
        );
      }
    }

    final session = PlatformSession(
      platformId: resolved,
      displayName: displayName ??
          _fallbackDisplayName(resolved, cookies, userId: userId),
      userId: userId ?? _extractUserId(resolved, cookies),
      cookies: cookies,
      loggedInAt: DateTime.now().toUtc().toIso8601String(),
    );

    return CookieImportResult.success(
      session: session,
      platformId: resolved,
    );
  }

  /// 从 Cookie 里尽量取出用户 ID（用于展示，不是鉴权依据）。
  static String _extractUserId(String platformId, Map<String, String> cookies) {
    switch (platformId) {
      case 'bilibili':
        return cookies['DedeUserID'] ?? '';
      case 'douyin':
        return cookies['uid_tt'] ?? cookies['odin_tt'] ?? '';
      default:
        return '';
    }
  }

  static String _fallbackDisplayName(
    String platformId,
    Map<String, String> cookies, {
    String? userId,
  }) {
    final label = switch (platformId) {
      'bilibili' => '哔哩哔哩',
      'douyin' => '抖音',
      _ => platformId,
    };
    final id = userId ?? _extractUserId(platformId, cookies);
    return id.isEmpty ? '$label（导入）' : '$label $id';
  }

  /// 尝试解析本应用的导出格式。
  static _ExportPayload? _tryParseExportJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final map = Map<String, Object?>.from(decoded);

      // 必须带 format 标记，避免把任意 JSON 误当导出文件
      if (map['format'] != 'video-fusion.cookies') return null;

      final cookiesRaw = map['cookies'];
      if (cookiesRaw is! Map) return null;

      return _ExportPayload(
        platformId: map['platformId'] as String? ?? '',
        displayName: map['displayName'] as String?,
        userId: map['userId'] as String?,
        cookies: cookiesRaw.map((k, v) => MapEntry('$k', '$v')),
      );
    } catch (_) {
      return null;
    }
  }

  /// 尝试解析普通 JSON 键值对象。
  static Map<String, String>? _tryParseJsonMap(String text) {
    if (!text.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final out = <String, String>{};
      for (final e in decoded.entries) {
        final v = e.value;
        if (v == null) continue;
        // 只接受标量值；嵌套对象不是 Cookie
        if (v is Map || v is List) continue;
        out['${e.key}'] = '$v';
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }
}

class _ExportPayload {
  const _ExportPayload({
    required this.platformId,
    required this.cookies,
    this.displayName,
    this.userId,
  });

  final String platformId;
  final Map<String, String> cookies;
  final String? displayName;
  final String? userId;
}
