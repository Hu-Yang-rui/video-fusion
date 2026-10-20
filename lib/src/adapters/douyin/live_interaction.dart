/// 抖音直播互动客户端（点赞 / 发弹幕 / 关注主播）。
///
/// # 实测依据（2026-10-19）
///
/// 在**正式 UIFID** + 应用内 WebView 环境下：
///
/// | 端点 | 未登录响应 | 结论 |
/// |---|---|---|
/// | `webcast/room/like/` | `20003 User doesn't login` | ✅ 可实现 |
/// | `webcast/room/chat/` | `20003 User doesn't login` | ✅ 可实现 |
///
/// 关键：`20003` 的语义是**未登录**（`prompts: "请登录后进入直播间"`），
/// **不是** 403 `Blocked by ArgusSecurityPlugin`。
///
/// 这推翻了旧结论「抖音直播互动需要设备侧签名、不可实现」——
/// 至少 Web 端路径不是被签名挡住的。
///
/// # 但不等于"已验证可用"
///
/// 本项目**没有抖音登录态**，因此只能验证到"未登录被正确拒绝"。
/// 登录后能否真正发出去，**未验证**。代码不谎报成功。
///
/// # 为什么走 WebView 而不是裸 HTTP
///
/// 这些端点要求 `UIFID` 会话 + 页面 SDK 签名，裸 HTTP 连 TEMP 都没有。
/// 复用 [DouyinWebSigner] 是最短路径，也与评论/详情保持一致。
library;

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/logger.dart';
import '../bilibili_live_interaction.dart' show LiveInteractionResult;
import 'web_signer.dart';

/// 抖音直播互动客户端。
class DouyinLiveInteraction {
  DouyinLiveInteraction({
    required DouyinWebSigner signer,
    FusionLogger? logger,
  })  : _signer = signer,
        _logger = logger ?? appLogger;

  final DouyinWebSigner _signer;
  final FusionLogger _logger;

  /// 直播间 Web 端 host。
  static const String _liveHost = 'https://live.douyin.com';

  /// 给直播间点赞。
  ///
  /// [roomKey] 是抖音的 19 位房间号字符串。
  ///
  /// 实测未登录返回 `20003`，因此这里先检查登录态：
  /// 没有登录就直接抛 `loginRequired`，不发注定失败的请求。
  Future<LiveInteractionResult> like({
    required String roomKey,
    required PlatformSession? session,
    int count = 1,
  }) async {
    if (session == null) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '请先登录抖音账号后再点赞。',
        technicalMessage: 'douyin live like requires login (20003 observed)',
        platformId: 'douyin',
      );
    }

    final ready = await _signer.ensureReady(requireFullUifid: true);
    if (!ready) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话初始化未完成，请稍后重试。',
        technicalMessage: 'live like: readiness=${_signer.readiness.name}',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final resp = await _signer.requestPost(
      path: '/webcast/room/like/',
      params: {
        'room_id': roomKey,
        'count': '$count',
        'device_platform': 'web',
        'aid': '6383',
        'live_id': '1',
        'identity': 'audience',
      },
      host: _liveHost,
    );

    return _parseWriteResult(resp, action: '点赞', successMessage: '已点赞');
  }

  /// 在直播间发弹幕。
  ///
  /// 实测未登录返回 `20003`（`prompts: "请登录后进入直播间"`）。
  ///
  /// [content] 为弹幕文本。抖音直播弹幕有长度限制，
  /// 这里按 50 字保守拦截（平台真实上限未逐值实测）。
  Future<LiveInteractionResult> sendDanmaku({
    required String roomKey,
    required String content,
    required PlatformSession? session,
  }) async {
    final text = content.trim();
    if (text.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '弹幕内容不能为空。',
        technicalMessage: 'empty danmaku content',
        platformId: 'douyin',
      );
    }
    if (text.length > 50) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '弹幕最多 50 个字。',
        technicalMessage: 'danmaku too long: ${text.length}',
        platformId: 'douyin',
      );
    }
    if (session == null) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '请先登录抖音账号后再发弹幕。',
        technicalMessage: 'douyin live chat requires login (20003 observed)',
        platformId: 'douyin',
      );
    }

    final ready = await _signer.ensureReady(requireFullUifid: true);
    if (!ready) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话初始化未完成，请稍后重试。',
        technicalMessage: 'live chat: readiness=${_signer.readiness.name}',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final resp = await _signer.requestPost(
      path: '/webcast/room/chat/',
      params: {
        'room_id': roomKey,
        'content': text,
        'device_platform': 'web',
        'aid': '6383',
        'live_id': '1',
        'identity': 'audience',
      },
      host: _liveHost,
    );

    return _parseWriteResult(
      resp,
      action: '发弹幕',
      successMessage: '弹幕已发送',
    );
  }

  /// 解析写操作响应。
  ///
  /// 抖音直播系用 `status_code`：`0` 成功，`20003` 未登录。
  LiveInteractionResult _parseWriteResult(
    DouyinCommentResponse resp, {
    required String action,
    required String successMessage,
  }) {
    final json = resp.tryParseJson();
    if (json == null) {
      _logger.warn('douyin live: non-json write response', {
        'len': resp.body.length,
        'status': resp.statusCode,
      });
      return LiveInteractionResult(
        ok: false,
        message: '$action失败：平台返回了无法解析的数据。',
        error: FusionException(
          code: FusionErrorCode.parseError,
          userMessage: '$action失败：平台返回了无法解析的数据。',
          technicalMessage: 'live write body not JSON (len=${resp.body.length})',
          platformId: 'douyin',
        ),
      );
    }

    final code = json['status_code'];
    if (code == 0) {
      return LiveInteractionResult(ok: true, message: successMessage);
    }

    // 20003 = 未登录（实测）
    if (code == 20003) {
      final data = json['data'];
      final msg = data is Map
          ? (Map<String, Object?>.from(data)['message']?.toString() ?? '')
          : '';
      final err = FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '请先登录抖音账号后再$action。',
        technicalMessage: 'live write returned 20003: $msg',
        upstreamCode: code,
        platformId: 'douyin',
        diagnostics: const {
          'observed': '20003 User doesn\'t login / 请登录后进入直播间',
          'note': '实测不是 403 Argus 拦截，只差登录态',
        },
      );
      return LiveInteractionResult(
        ok: false,
        message: err.userMessage,
        error: err,
      );
    }

    final err = FusionException(
      code: FusionErrorCode.upstreamError,
      userMessage: '$action失败（平台返回 $code）。',
      technicalMessage: 'live write returned $code',
      upstreamCode: code,
      platformId: 'douyin',
    );
    return LiveInteractionResult(ok: false, message: err.userMessage, error: err);
  }
}
