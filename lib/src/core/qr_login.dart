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
    this.qrImageBase64,
  });

  /// 平台标识。
  final String platformId;

  /// 二维码要编码的内容（一个 URL 字符串，由平台提供）。
  ///
  /// 仅当 [qrImageBase64] 为 null 时用于本地渲染二维码。
  final String qrContent;

  /// 平台**直接下发**的二维码图片（base64 PNG）。
  ///
  /// 抖音 passport 返回的是一张已渲染好的 PNG，不是待编码的字符串。
  /// 若把它当文本交给 `QrImageView` 二次编码，画出来的是一个
  /// 内容为"base64 字符串"的二维码——**扫不出来**，
  /// 用户看到的就是"二维码无效"。
  ///
  /// 因此有这个字段时，UI 必须直接展示图片，不做二次编码。
  final String? qrImageBase64;

  /// 是否由平台下发了现成图片。
  bool get hasImage => qrImageBase64 != null && qrImageBase64!.isNotEmpty;

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

/// 支持**短信验证码**登录的平台。
///
/// # 为什么与 [QrLoginCapable] 分开
///
/// 扫码和短信是两条独立通道，可用性也不同：
///  - 扫码依赖平台的设备自证链路（抖音上被 4031 挡住）
///  - 短信只需手机号 + 验证码，不依赖设备票据
///
/// 一个平台可能只有其中一条可用，所以分成两个接口，
/// UI 据此决定显示「扫码登录」还是「短信登录」。
abstract class SmsLoginCapable {
  /// 发送验证码到指定手机号。
  ///
  /// 号码或平台拒绝时抛 [FusionException]，**不静默失败**。
  Future<void> sendLoginSmsCode(String phone);

  /// 提交验证码。
  ///
  /// 成功时 `phase == succeeded` 且带回会话 Cookie；
  /// 失败时如实返回原因（验证码错误、过期、风控等）。
  Future<QrLoginPollResult> submitLoginSmsCode(String phone, String code);
}

/// 短信登录弹窗的结局。
///
/// 区分「用户主动放弃」与「平台要求换验证方式」：后者要自动接扫码，
/// 不能当成普通取消——否则用户被卡在一条走不通的路上。
enum SmsConnectOutcome {
  succeeded,
  cancelled,

  /// 平台要求去官方 APP / 做网页验证，短信这条路当前不通。
  blockedByPlatform,
}
