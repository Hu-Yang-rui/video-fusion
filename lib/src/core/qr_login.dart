/// 扫码登录流程（平台无关契约）。
///
/// # 为什么是扫码
///
/// 需求要求"APP 内做一个 UI，不能使用 web"。密码登录在这条约束下不可行：
///
///  实测（2026-10）：`passport.bilibili.com/x/passport-login/web/key`
///  返回 RSA 公钥，密码需加密提交；但真实登录流程还会触发**极验
///  (Geetest) 验证码**——那是一个 JS 组件，原生无法完成，
///  而绕过它属于"绕过验证码"，被需求三明确禁止。
///
/// 扫码登录则完全不同：
///  - 二维码内容是一个 URL 字符串，APP 用纯 Dart 渲染二维码图片即可；
///  - 用户在**自己的手机 APP** 上确认，凭证由平台直接下发给本客户端；
///  - 全程不出现任何 web 组件、WebView 或内嵌页面；
///  - 不涉及密码，不涉及验证码绕过。
library;

/// 扫码登录的状态机。
enum QrLoginPhase {
  /// 正在向平台申请二维码。
  requesting,

  /// 二维码已生成，等待用户扫码。
  waitingForScan,

  /// 用户已扫码，等待其在手机上确认。
  waitingForConfirm,

  /// 登录成功。
  succeeded,

  /// 二维码已过期，需要重新申请。
  expired,

  /// 失败（网络错误、平台拒绝等）。
  failed,
}

/// 一次扫码登录会话。
class QrLoginChallenge {
  const QrLoginChallenge({
    required this.platformId,
    required this.qrContent,
    required this.challengeKey,
    required this.createdAt,
    this.expiresIn = const Duration(minutes: 3),
  });

  /// 平台标识。
  final String platformId;

  /// 二维码要编码的内容（一个 URL 字符串，由平台提供）。
  final String qrContent;

  /// 轮询用的挑战标识。
  final String challengeKey;

  final DateTime createdAt;
  final Duration expiresIn;

  bool get isExpired =>
      DateTime.now().difference(createdAt) > expiresIn;
}

/// 轮询结果。
class QrLoginPollResult {
  const QrLoginPollResult({
    required this.phase,
    this.userId,
    this.displayName,
    this.username,
    this.avatarUrl,
    this.cookies = const {},
    this.message,
  });

  final QrLoginPhase phase;

  /// 登录成功时的平台用户 ID。
  final String? userId;

  /// 登录成功时的账号展示名。
  final String? displayName;

  final String? username;
  final String? avatarUrl;

  /// 登录成功时平台下发的会话 Cookie。
  final Map<String, String> cookies;

  /// 面向用户的提示。
  final String? message;

  bool get succeeded => phase == QrLoginPhase.succeeded;
}

/// 平台登录能力契约。
///
/// 适配器实现该接口即表示支持扫码登录。
abstract class QrLoginCapable {
  /// 申请一个新的二维码。
  Future<QrLoginChallenge> requestQrChallenge();

  /// 轮询扫码状态。
  Future<QrLoginPollResult> pollQrChallenge(QrLoginChallenge challenge);
}
