/// 扫码登录页面（纯原生 UI，**不使用任何 web 组件**）。
///
/// 交互流程：
///  1. 进入页面 → 自动向平台申请二维码
///  2. APP 用 `qr_flutter` **在本地渲染**二维码图片（不是加载平台网页）
///  3. 用户在手机客户端扫码 → APP 轮询状态 → 实时更新提示
///  4. 确认成功 → 保存会话 → 返回
///
/// # 设计体系
///
/// 本页使用项目统一的 **Apple 设计系统**（`AppleColors` / `AppleType` /
/// `AppleSpace` / `AppleRadius`），与设置页、详情页、评论面板一致。
///
/// 历史说明：这里原本用的是另一套 `MobileTokens` / `MobileText` 令牌，
/// 导致从设置页点「连接」后界面风格突变（配色、字号、圆角全部不同）。
/// 现已统一，旧令牌只保留给仍在引用的旧组件。
///
/// 为什么不用 WebView：产品要求"APP 内做一个 UI，不能使用 web"。
/// 二维码的原始内容只是一个 URL 字符串，本地渲染即可，
/// 完全不需要加载任何网页。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../adapters/platform_adapter.dart';
import '../../core/qr_login.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';

/// 登录页。传入一个实现了 [QrLoginCapable] 的适配器。
class QrLoginPage extends StatefulWidget {
  const QrLoginPage({
    super.key,
    required this.adapter,
    required this.vault,
    required this.platformName,
    this.onLoggedIn,
  });

  final QrLoginCapable adapter;
  final CredentialVault vault;
  final String platformName;
  final void Function(PlatformSession session)? onLoggedIn;

  @override
  State<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<QrLoginPage> {
  QrLoginChallenge? _challenge;
  QrLoginPollResult? _lastPoll;
  Timer? _pollTimer;

  /// 平台下发图片的解码结果。
  ///
  /// 必须缓存：`Image.memory` 按字节实例判等，若在 build 里现算
  /// `base64Decode`，每次 setState（轮询每 2 秒一次）都会产出新实例，
  /// 导致图片被反复解码重绘——看起来像二维码在闪。
  Uint8List? _qrBytes;

  bool _requesting = false;
  FusionException? _error;

  /// 二维码全屏放大态。
  ///
  /// 用状态位而不是新路由：轮询发生在本 State 里，
  /// 推新路由后本页仍活着但状态更新传不过去；
  /// 同页覆盖层则阶段变化天然同步。
  bool _qrFullscreen = false;

  /// 秒级节拍，只用于刷新剩余时间显示。
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _requestQr();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  Future<void> _requestQr() async {
    _pollTimer?.cancel();

    setState(() {
      _requesting = true;
      _error = null;
      _lastPoll = null;
      _challenge = null;
    });

    try {
      final challenge = await widget.adapter.requestQrChallenge();
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _qrBytes = challenge.hasImage
            ? base64Decode(challenge.qrImageBase64!)
            : null;
        _requesting = false;
        _lastPoll = const QrLoginPollResult(
          phase: QrLoginPhase.waitingForScan,
          message: '请使用手机客户端扫描二维码。',
        );
      });
      _startTick();
      _startPolling(challenge);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _error = normalizeError(e);
      });
    }
  }

  void _startTick() {
    _tickTimer?.cancel();
    // 每秒重建一次，只为让「剩余时间」跟着走。
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {});
    });
  }

  /// 剩余有效时间；已过期或未取码时返回 null。
  Duration? get _remaining {
    final ch = _challenge;
    if (ch == null) return null;
    final left = ch.createdAt.add(ch.expiresIn).difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void _startPolling(QrLoginChallenge challenge) {
    // 每 2 秒轮询一次。这是有限频率，不构成对平台的滥用。
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (challenge.isExpired) {
        timer.cancel();
        setState(() {
          _lastPoll = const QrLoginPollResult(
            phase: QrLoginPhase.expired,
            message: '二维码已过期，请点击刷新。',
          );
        });
        return;
      }

      try {
        final result = await widget.adapter.pollQrChallenge(challenge);
        if (!mounted) return;

        setState(() => _lastPoll = result);

        if (result.phase == QrLoginPhase.expired) {
          timer.cancel();
        } else if (result.succeeded) {
          timer.cancel();
          await _persistSession(result);
        }
      } on FusionException catch (e) {
        // 单次轮询失败不终止流程（网络抖动），继续轮询
        if (!mounted) return;
        setState(
          () => _lastPoll = QrLoginPollResult(
            phase: QrLoginPhase.waitingForScan,
            message: '网络波动，正在重试…（${e.presentation.title}）',
          ),
        );
      }
    });
  }

  Future<void> _persistSession(QrLoginPollResult result) async {
    final session = PlatformSession(
      platformId: (widget.adapter as dynamic).id as String,
      displayName: result.displayName ?? widget.platformName,
      userId: result.userId ?? '',
      cookies: result.cookies,
      loggedInAt: DateTime.now().toUtc().toIso8601String(),
      username: result.username,
      avatarUrl: result.avatarUrl,
    );

    try {
      await widget.vault.save(session);
      if (!mounted) return;
      widget.onLoggedIn?.call(session);
      Navigator.of(context).maybePop(session);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = normalizeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                // 顶栏：返回 + 标题
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppleSpace.sm,
                    vertical: AppleSpace.sm,
                  ),
                  child: Row(
                    children: [
                      AppleIconButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Text(
                          '登录${widget.platformName}',
                          textAlign: TextAlign.center,
                          style: AppleType.headline.copyWith(color: c.label),
                        ),
                      ),
                      // 占位，保持标题居中
                      const SizedBox(width: AppleSize.minTapTarget),
                    ],
                  ),
                ),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      AppleSpace.xl,
                      AppleSpace.lg,
                      AppleSpace.xl,
                      AppleSpace.xl,
                    ),
                    child: Column(
                      children: [
                        Text(
                          '使用${widget.platformName}手机客户端扫码',
                          textAlign: TextAlign.center,
                          style: AppleType.subheadline.copyWith(
                            color: c.secondaryLabel,
                            height: 1.45,
                          ),
                        ),

                        // 抖音专用提示：**不要截图后从相册选图**。
                        //
                        // 实测（2026-10-18）：把本页二维码截图保存，用抖音
                        // 「扫一扫 → 相册」选这张图，抖音会拒绝并提示
                        //   "该抖音二维码用于登录，为保障安全，
                        //     请使用抖音扫一扫进行扫码"
                        //
                        // 这不是二维码无效 —— 恰恰相反，说明抖音正确识别了
                        // 这是一张登录码。抖音的安全策略要求**实时取景扫描**，
                        // 防止截图被转发给他人代扫。
                        //
                        // 只有抖音有这条限制，B站允许相册选图，因此按平台区分。
                        if (widget.adapter is PlatformAdapter &&
                            (widget.adapter as PlatformAdapter).id ==
                                'douyin') ...[
                          const SizedBox(height: AppleSpace.sm),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppleSpace.sm,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 1.5),
                                  child: Icon(
                                    Icons.info_outline_rounded,
                                    size: 12,
                                    color: c.tertiaryLabel,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    '点二维码可全屏放大，便于另一台设备扫描。'
                                    '截图后从相册选图会被抖音拒绝——'
                                    '这是抖音的安全策略，第三方客户端绕不过。',
                                    style: AppleType.caption2.copyWith(
                                      color: c.tertiaryLabel,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: AppleSpace.xl),

                        _buildQrArea(c),
                        if (_remaining != null) ...[
                          const SizedBox(height: AppleSpace.sm),
                          Text(
                            _remaining! == Duration.zero
                                ? '二维码已过期，点下方刷新'
                                : '二维码 ' + _fmtLeft(_remaining!) + ' 后过期',
                            style: AppleType.caption2.copyWith(
                              color: c.tertiaryLabel,
                            ),
                          ),
                        ],
                        const SizedBox(height: AppleSpace.lg),

                        _buildStatus(c),
                        const SizedBox(height: AppleSpace.xl),

                        _buildSecurityNotice(c),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 全屏放大层：点二维码即放大到整屏，
          // 便于「另一台设备直接扫」或「截图后相册识别」。
          if (_qrFullscreen && _qrBytes != null) _buildFullscreenQr(c),
        ],
      ),
    );
  }

  /// 全屏二维码。
  ///
  /// 白底、二维码尽量大、保留足够静默区——图库识别对尺寸与对比度敏感。
  Widget _buildFullscreenQr(AppleColors c) {
    final left = _remaining;
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _qrFullscreen = false),
        child: Container(
          // 纯白底：扫码识别要求白底黑码
          color: Colors.white,
          child: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.all(AppleSpace.sm),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      color: const Color(0xFF101012),
                      onPressed: () => setState(() => _qrFullscreen = false),
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        // 取短边做二维码边长，四周留出静默区
                        final side = box.biggest.shortestSide * 0.86;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.memory(
                              _qrBytes!,
                              width: side,
                              height: side,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(height: AppleSpace.lg),
                            if (left != null)
                              Text(
                                '剩余 ' + _fmtLeft(left),
                                style: AppleType.footnote.copyWith(
                                  color: const Color(0xFF8E8E93),
                                ),
                              ),
                            const SizedBox(height: AppleSpace.xs),
                            Text(
                              _phaseHint(),
                              textAlign: TextAlign.center,
                              style: AppleType.subheadline.copyWith(
                                color: const Color(0xFF101012),
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: AppleSpace.sm),
                            Text(
                              '点空白处返回',
                              style: AppleType.caption1.copyWith(
                                color: const Color(0xFF8E8E93),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 全屏态下的提示语。
  ///
  /// 优先用轮询给出的具体原因：它会说清"为什么不行"
  /// （例如风控拦截），比"登录失败"这种通用文案有用得多。
  String _phaseHint() {
    final msg = _lastPoll?.message;
    if (msg != null && msg.isNotEmpty) return msg;
    return '用 ' + widget.platformName + ' 扫描上方的二维码';
  }

  String _fmtLeft(Duration d) {
    final m = d.inMinutes;
    final sec = d.inSeconds % 60;
    return '$m:' + sec.toString().padLeft(2, '0');
  }

  Widget _buildQrArea(AppleColors c) {
    final challenge = _challenge;

    return GestureDetector(
      // 点一下放大到全屏：图库识别对二维码尺寸敏感，
      // 屏幕上的小图截图后往往识别不出来。
      onTap: challenge == null
          ? null
          : () => setState(() => _qrFullscreen = true),
      child: Container(
        width: 236,
        height: 236,
        decoration: BoxDecoration(
          // 二维码必须白底黑码才能被扫描器识别，
          // 因此这里固定白色，不随主题变化。
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppleRadius.lg),
        ),
        alignment: Alignment.center,
        child: _requesting
            ? const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : challenge == null
            ? Icon(Icons.qr_code_2_rounded, size: 64, color: c.tertiaryLabel)
            : Stack(
                alignment: Alignment.center,
                children: [
                  // 两种来源，二选一：
                  //
                  //  1. 平台直接下发图片（抖音）：直接展示，**不得**
                  //     再交给 QrImageView 编码——那会把 base64 字符串
                  //     本身编成二维码，画出来扫不出来。
                  //  2. 平台只给内容字符串（B站）：纯 Dart 本地渲染。
                  if (_qrBytes != null)
                    Image.memory(
                      _qrBytes!,
                      width: 208,
                      height: 208,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: c.tertiaryLabel,
                      ),
                    )
                  else
                    QrImageView(
                      data: challenge.qrContent,
                      version: QrVersions.auto,
                      size: 208,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Color(0xFF101012),
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Color(0xFF101012),
                      ),
                    ),
                  if (_isExpiredOrDone) _buildQrOverlay(c),
                ],
              ),
      ),
    );
  }

  bool get _isExpiredOrDone {
    final phase = _lastPoll?.phase;
    return phase == QrLoginPhase.expired || phase == QrLoginPhase.succeeded;
  }

  Widget _buildQrOverlay(AppleColors c) {
    final succeeded = _lastPoll?.phase == QrLoginPhase.succeeded;
    return Container(
      width: 208,
      height: 208,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppleRadius.md),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            succeeded ? Icons.check_circle_rounded : Icons.refresh_rounded,
            size: 34,
            color: succeeded ? c.green : c.tertiaryLabel,
          ),
          const SizedBox(height: AppleSpace.md),
          Text(
            succeeded ? '登录成功' : '二维码已过期',
            style: AppleType.footnoteEmphasized.copyWith(
              color: const Color(0xFF101012),
            ),
          ),
          if (!succeeded) ...[
            const SizedBox(height: AppleSpace.sm),
            TextButton(onPressed: _requestQr, child: const Text('点击刷新')),
          ],
        ],
      ),
    );
  }

  Widget _buildStatus(AppleColors c) {
    if (_error != null) {
      return AppleErrorState(
        title: _error!.presentation.title,
        message: _error!.userMessage,
        onRetry: _error!.retryable ? _requestQr : null,
      );
    }

    final poll = _lastPoll;
    if (poll == null) return const SizedBox.shrink();

    final (icon, color) = switch (poll.phase) {
      QrLoginPhase.waitingForScan => (
        Icons.qr_code_scanner_rounded,
        c.tertiaryLabel,
      ),
      QrLoginPhase.waitingForConfirm => (Icons.phone_iphone_rounded, c.blue),
      QrLoginPhase.succeeded => (Icons.check_circle_rounded, c.green),
      QrLoginPhase.expired => (Icons.timer_off_rounded, c.orange),
      _ => (Icons.info_outline_rounded, c.tertiaryLabel),
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: AppleSpace.sm),
        Flexible(
          child: Text(
            poll.message ?? '',
            textAlign: TextAlign.center,
            style: AppleType.footnote.copyWith(color: color, height: 1.4),
          ),
        ),
      ],
    );
  }

  /// 账号安全说明。
  ///
  /// 放在页面底部而不是顶部：用户是来登录的，不是来读条款的；
  /// 但登录涉及凭证，必须让用户能随时看到这些承诺。
  Widget _buildSecurityNotice(AppleColors c) {
    return AppleGroupedSection(
      header: '关于你的账号安全',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppleSpace.lg,
            AppleSpace.md,
            AppleSpace.lg,
            AppleSpace.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _notice(c, '本应用不索取、不接触你的账号密码。'),
              _notice(c, '登录由平台官方完成，本应用只接收平台下发的会话凭证。'),
              _notice(
                c,
                '凭证使用系统安全存储加密保存'
                '（Android Keystore / Windows 凭据管理器）。',
              ),
              _notice(c, '凭证不会写入任何日志，也不会发送到该平台以外的服务器。'),
              _notice(c, '你可随时在设置页解绑，解绑即彻底删除本地凭证。'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _notice(AppleColors c, String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppleSpace.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(
            width: 3.5,
            height: 3.5,
            decoration: BoxDecoration(
              color: c.tertiaryLabel,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: AppleSpace.sm),
        Expanded(
          child: Text(
            text,
            style: AppleType.caption1.copyWith(
              color: c.secondaryLabel,
              height: 1.55,
            ),
          ),
        ),
      ],
    ),
  );
}
