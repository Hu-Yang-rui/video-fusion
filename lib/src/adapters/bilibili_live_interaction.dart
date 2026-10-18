/// B站直播互动：点赞、关注、发送弹幕。
///
/// # 为什么需要登录
///
/// 实测（2026-10-18，未登录）：
///
/// | 接口 | 结果 | 含义 |
/// |---|---|---|
/// | `POST /xlive/app-ucenter/v1/like_info_v3/like/likeReportV3` | -352 | 风控，需登录 |
/// | `POST /room/v1/Room/room_entry_action` | -400 | 参数错误（路径存在） |
/// | `POST /relation/v1/Feed/SetUserFollow` | **401 请登录** | 明确要求登录 |
/// | `POST /msg/send` | **-101 账号未登录** | 明确要求登录 |
///
/// 这四个都是**路径存在但需要登录**，不是"接口不存在"。
/// 因此只要用户登录（应用已有扫码登录 + Cookie 导入），就能用。
///
/// # 安全约束
///
///  - 所有写操作必须带 `csrf`（即 `bili_jct` Cookie 值），这是 B站
///    的 CSRF 防护，缺了会返回 -111。
///  - 未登录时**不发送请求**，直接抛 `loginRequired`，不静默失败。
///  - 凭证只从 `PlatformSession` 取，不落盘、不进日志。
library;

import '../core/credential_vault.dart';
import '../core/errors.dart';
import '../core/http_client.dart';
import '../core/logger.dart';

/// B站直播互动客户端。
class BilibiliLiveInteraction {
  BilibiliLiveInteraction({
    required FusionHttpClient http,
    FusionLogger? logger,
  })  : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _apiBase = 'https://api.live.bilibili.com';
  static const String _referer = 'https://live.bilibili.com/';

  /// 给直播间点赞。
  ///
  /// 未登录时抛 [FusionErrorCode.loginRequired]。
  ///
  /// 说明：B站的"点赞"是**连击**语义（一次请求可带 count），
  /// 服务端会累计。这里每次发 1 次，由 UI 决定连击频率。
  Future<LiveInteractionResult> like({
    required int roomId,
    required PlatformSession? session,
    int count = 1,
  }) async {
    _requireLogin(session, '点赞');
    final s = session!;

    final anchorId = _uidFromSession(s);
    final result = await _http.post(
      '$_apiBase/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3'
      '?room_id=$roomId&uid=${anchorId ?? 0}&anchor_id=${anchorId ?? 0}'
      '&like_num=$count&csrf=${_csrfOf(s)}',
      headers: {
        'Referer': '$_referer$roomId',
        'Cookie': s.cookieHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'room_id=$roomId&uid=${anchorId ?? 0}'
          '&anchor_id=${anchorId ?? 0}&like_num=$count'
          '&csrf=${_csrfOf(s)}',
      platformId: 'bilibili',
      acceptStatuses: const {200},
    );

    return _parseWriteResult(
      result,
      action: '点赞',
      successMessage: '已点赞',
    );
  }

  /// 关注主播。
  ///
  /// 未登录时抛 [FusionErrorCode.loginRequired]。
  ///
  /// [uid] 是**主播的 UID**，不是房间号。房间号 → UID 需要先查
  /// `fetchLiveRoomInfo`（其中 `uid` 字段就是主播 UID）。
  Future<LiveInteractionResult> follow({
    required int uid,
    required bool follow,
    required PlatformSession? session,
  }) async {
    _requireLogin(session, follow ? '关注' : '取消关注');
    final s = session!;

    final result = await _http.post(
      '$_apiBase/relation/v1/Feed/SetUserFollow'
      '?fid=$uid&act=${follow ? 1 : 2}&re_src=11'
      '&csrf=${_csrfOf(s)}',
      headers: {
        'Referer': _referer,
        'Cookie': s.cookieHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'fid=$uid&act=${follow ? 1 : 2}&re_src=11'
          '&csrf=${_csrfOf(s)}',
      platformId: 'bilibili',
      acceptStatuses: const {200},
    );

    return _parseWriteResult(
      result,
      action: follow ? '关注' : '取消关注',
      successMessage: follow ? '已关注' : '已取消关注',
    );
  }

  /// 发送弹幕。
  ///
  /// 未登录时抛 [FusionErrorCode.loginRequired]。
  ///
  /// [color] 是十进制颜色值（默认白色 16777215）。
  /// [mode] 1=滚动 4=底部 5=顶部。
  Future<LiveInteractionResult> sendDanmaku({
    required int roomId,
    required String message,
    required PlatformSession? session,
    int color = 16777215,
    int mode = 1,
  }) async {
    _requireLogin(session, '发送弹幕');
    final s = session!;

    final text = message.trim();
    if (text.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '弹幕内容不能为空。',
        technicalMessage: 'empty danmaku message',
        platformId: 'bilibili',
      );
    }
    // B站弹幕长度上限 20 字，超了服务端会拒
    final charCount = text.runes.length;
    if (charCount > 20) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '弹幕最多 20 个字。',
        technicalMessage: 'danmaku length $charCount > 20',
        platformId: 'bilibili',
      );
    }

    final body = 'msg=${Uri.encodeQueryComponent(text)}'
        '&roomid=$roomId&color=$color&fontsize=25&mode=$mode'
        '&rnd=${DateTime.now().millisecondsSinceEpoch ~/ 1000}'
        '&csrf=${_csrfOf(s)}&csrf_token=${_csrfOf(session)}';

    final result = await _http.post(
      '$_apiBase/msg/send',
      headers: {
        'Referer': '$_referer$roomId',
        'Cookie': s.cookieHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body,
      platformId: 'bilibili',
      acceptStatuses: const {200},
    );

    return _parseWriteResult(
      result,
      action: '发送弹幕',
      successMessage: '已发送',
    );
  }

  // ── 内部 ────────────────────────────────────────────────────

  /// 未登录直接抛错，不发请求。
  void _requireLogin(PlatformSession? session, String action) {
    if (session != null) return;
    throw FusionException(
      code: FusionErrorCode.loginRequired,
      userMessage: '请先登录哔哩哔哩账号后再$action。',
      technicalMessage: '$action requires a bilibili session',
      platformId: 'bilibili',
    );
  }

  /// B站写操作必须带 `csrf`，值就是 `bili_jct` Cookie。
  ///
  /// 缺了会返回 -111（csrf 校验失败）。这里显式取，缺了也如实抛错，
  /// 而不是发一个注定失败的请求。
  String _csrfOf(PlatformSession session) {
    final jct = session.cookies['bili_jct'];
    if (jct == null || jct.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '登录凭证不完整（缺少 bili_jct），请重新登录。',
        technicalMessage:
            'session has no bili_jct cookie; write operations need it as csrf',
        platformId: 'bilibili',
      );
    }
    return jct;
  }

  /// 从会话里取 uid。取不到返回 null（接口允许传 0）。
  int? _uidFromSession(PlatformSession session) {
    final raw = session.cookies['DedeUserID'] ?? session.userId;
    return int.tryParse(raw);
  }

  /// 解析写操作结果。
  ///
  /// B站写操作的成功判据是 `code == 0`，**不是** HTTP 200。
  /// 实测未登录时 HTTP 200 + code=-101，只看 HTTP 会误判成功。
  ///
  /// 非 JSON 响应（例如网关返回 HTML 错误页）也归为失败结果，
  /// **不抛异常**——调用方统一看 `ok` 字段处理，
  /// 避免"有些失败抛异常、有些返回 false"的双轨制。
  LiveInteractionResult _parseWriteResult(
    HttpResult result, {
    required String action,
    required String successMessage,
  }) {
    Map<String, Object?> json;
    try {
      json = result.jsonObject(platformId: 'bilibili');
    } catch (_) {
      _logger.warn('live $action: unparsable response', {
        'status': result.statusCode,
        'bodyLength': result.body.length,
      });
      return LiveInteractionResult(
        ok: false,
        message: '$action失败：平台返回了无法解析的数据。',
        error: FusionException(
          code: FusionErrorCode.parseError,
          userMessage: '$action失败：平台返回了无法解析的数据。',
          technicalMessage:
              '$action response is not JSON (HTTP ${result.statusCode}, '
              '${result.body.length} bytes)',
          platformId: 'bilibili',
        ),
      );
    }

    final code = (json['code'] as num?)?.toInt() ?? -1;
    final message = json['message']?.toString() ?? '';

    if (code == 0) {
      _logger.info('live $action ok');
      return LiveInteractionResult(
        ok: true,
        message: successMessage,
      );
    }

    // 按 B站业务码映射成可理解的错误
    final (FusionErrorCode errCode, String userMsg) = switch (code) {
      -101 => (FusionErrorCode.loginRequired, '登录已失效，请重新登录。'),
      -111 => (FusionErrorCode.loginRequired, '登录凭证不完整，请重新登录。'),
      401 => (FusionErrorCode.loginRequired, '请先登录后再$action。'),
      -352 => (FusionErrorCode.rateLimited, '操作过于频繁，请稍后再试。'),
      -403 => (FusionErrorCode.permissionDenied, '没有$action的权限。'),
      _ => (
          FusionErrorCode.upstreamError,
          '$action失败：${message.isEmpty ? '平台返回 $code' : message}',
        ),
    };

    _logger.warn('live $action failed', {'code': code});
    return LiveInteractionResult(
      ok: false,
      message: userMsg,
      error: FusionException(
        code: errCode,
        userMessage: userMsg,
        technicalMessage: '$action returned code=$code message=$message',
        platformId: 'bilibili',
        upstreamCode: code,
        retryable: code == -352,
      ),
    );
  }
}

/// 一次直播互动操作的结果。
class LiveInteractionResult {
  const LiveInteractionResult({
    required this.ok,
    required this.message,
    this.error,
  });

  final bool ok;
  final String message;
  final FusionException? error;
}
