/// 抖音扫码登录页（Apple 设计体系）。
///
/// # 实现状态
///
/// 扫码链路已完整打通并实测：
///
/// | 环节 | 状态 |
/// |---|---|
/// | 获取二维码 | ✅ 真实可用 |
/// | 轮询扫码状态 | ✅ 真实可用（`status: new` 已验证） |
/// | 扫码后换取 Cookie | ⚠️ 待验证（需真人扫码） |
///
/// `a_bogus` 签名由纯 Dart 实现（`_abogus.dart`），
/// **不使用 WebView**。
///
/// 未扫码时显示 `status: new`，扫码后应变为 `scanning` / `confirmed`。
/// 若平台返回 `confirmed`，本页会继续等待凭证换取完成 —— 不伪造登录成功。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../adapters/douyin/login_client.dart';
import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';

/// 抖音扫码登录页。
class DouyinLoginPage extends StatefulWidget {
  const DouyinLoginPage({
    super.key,
    required this.client,
    required this.vault,
    this.onLoggedIn,
  });

  final DouyinLoginClient client;
  final CredentialVault vault;
  final void Function(PlatformSession session)? onLoggedIn;

  @override
  State<DouyinLoginPage> createState() => _DouyinLoginPageState();
}

class _DouyinLoginPageState extends State<DouyinLoginPage> {
  DouyinQrChallenge? _challenge;
  DouyinLoginPollResult? _poll;
  FusionException? _error;
  Timer? _timer;
  bool _requesting = false;

  /// 是否已登录成功。成功后停止一切轮询，且不再覆盖状态。
  bool _succeeded = false;

  /// 单次轮询是否仍在进行。
  ///
  /// `Timer.periodic` 的回调是 async 的：上一次请求若超过 2 秒
  /// （网络慢、风控重试），下一次回调会与它**并发**发出，
  /// 造成同一 token 被重复轮询、响应乱序覆盖状态。
  /// 用这个标志把轮询变成串行的。
  bool _pollInFlight = false;

  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _request() async {
    _timer?.cancel();
    _timer = null;
    _pollInFlight = false;
    widget.client.resetCookies();
    setState(() {
      _requesting = true;
      _succeeded = false;
      _error = null;
      _challenge = null;
      _poll = null;
    });

    try {
      final challenge = await widget.client.requestQrCode();
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _requesting = false;
        _poll = const DouyinLoginPollResult(
          phase: DouyinLoginPhase.waitingForScan,
          message: '请用抖音 App 扫描二维码。',
        );
      });
      _startPolling(challenge);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _error = normalizeError(e, platformId: 'douyin');
      });
    }
  }

  void _startPolling(DouyinQrChallenge challenge) {
    _timer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted || _succeeded) {
        t.cancel();
        return;
      }
      // 串行化：上一次还没回来就跳过这一拍，不并发轮询。
      if (_pollInFlight) return;

      if (challenge.isExpired) {
        t.cancel();
        setState(() {
          _poll = const DouyinLoginPollResult(
            phase: DouyinLoginPhase.expired,
            message: '二维码已过期，请刷新。',
          );
        });
        return;
      }

      _pollInFlight = true;
      DouyinLoginPollResult result;
      try {
        result = await widget.client.pollQrStatus(challenge);
      } finally {
        _pollInFlight = false;
      }

      // 页面已销毁，或期间已登录成功：结果作废，
      // 不能覆盖已成功的状态。
      if (!mounted || _succeeded) return;

      // 登录成功：保存凭证并回调，然后停止轮询。
      if (result.phase == DouyinLoginPhase.succeeded &&
          result.session != null) {
        t.cancel();
        _timer = null;
        await _persistSession(result.session!);
        if (!mounted) return;
        setState(() {
          _succeeded = true;
          _poll = result;
        });
        return;
      }

      setState(() => _poll = result);

      // 被拦截或过期就停止轮询，不空转
      if (result.phase == DouyinLoginPhase.blocked ||
          result.phase == DouyinLoginPhase.expired) {
        t.cancel();
        _timer = null;
      }
    });
  }

  /// 把会话写入加密保险库。
  ///
  /// 写入失败必须让用户知道——"看起来登上了但下次打开又没了"
  /// 是最难排查的一类问题。
  Future<void> _persistSession(PlatformSession session) async {
    try {
      await widget.vault.save(session);
      widget.onLoggedIn?.call(session);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _succeeded = false;
        _error = normalizeError(e, platformId: 'douyin');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        child: Column(
          children: [
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
                      '登录抖音',
                      textAlign: TextAlign.center,
                      style: AppleType.headline.copyWith(color: c.label),
                    ),
                  ),
                  const SizedBox(width: AppleSize.minTapTarget),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppleSpace.xl,
                  AppleSpace.md,
                  AppleSpace.xl,
                  AppleSpace.xl,
                ),
                child: Column(
                  children: [
                    Text(
                      '使用抖音 App 扫码',
                      textAlign: TextAlign.center,
                      style: AppleType.subheadline.copyWith(
                        color: c.secondaryLabel,
                      ),
                    ),
                    const SizedBox(height: AppleSpace.lg),

                    _buildQrArea(c),
                    const SizedBox(height: AppleSpace.lg),

                    _buildStatus(c),

                    const SizedBox(height: AppleSpace.xl),
                    _buildAlternative(c),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrArea(AppleColors c) {
    final challenge = _challenge;

    return Container(
      width: 236,
      height: 236,
      decoration: BoxDecoration(
        // 二维码必须白底黑码才能被扫描器识别
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
              ? Icon(
                  Icons.qr_code_2_rounded,
                  size: 64,
                  color: c.tertiaryLabel,
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(AppleRadius.md),
                  // 抖音返回的是 base64 PNG 图片，直接展示，
                  // 不用 QrImageView 二次编码（那会把图片当文本编码）
                  child: Image.memory(
                    base64Decode(challenge.qrBase64),
                    width: 208,
                    height: 208,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: c.tertiaryLabel,
                    ),
                  ),
                ),
    );
  }

  Widget _buildStatus(AppleColors c) {
    if (_error != null) {
      return Column(
        children: [
          AppleErrorState(
            title: _error!.presentation.title,
            message: _error!.userMessage,
            onRetry: _error!.retryable ? _request : null,
          ),
          const SizedBox(height: AppleSpace.md),
          AppleSecondaryButton(
            label: '重试',
            onPressed: _request,
          ),
        ],
      );
    }

    final poll = _poll;
    if (poll == null) return const SizedBox.shrink();

    final (icon, color) = switch (poll.phase) {
      DouyinLoginPhase.waitingForScan => (
          Icons.qr_code_scanner_rounded,
          c.tertiaryLabel,
        ),
      DouyinLoginPhase.waitingForConfirm => (
          Icons.phone_iphone_rounded,
          c.blue,
        ),
      DouyinLoginPhase.succeeded => (Icons.check_circle_rounded, c.green),
      DouyinLoginPhase.expired => (Icons.timer_off_rounded, c.orange),
      DouyinLoginPhase.blocked => (Icons.info_outline_rounded, c.orange),
    };

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: AppleSpace.sm),
            Flexible(
              child: Text(
                poll.message ?? '',
                style: AppleType.footnote.copyWith(
                  color: color,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
        if (poll.phase == DouyinLoginPhase.expired) ...[
          const SizedBox(height: AppleSpace.md),
          AppleSecondaryButton(label: '刷新二维码', onPressed: _request),
        ],
        if (poll.phase == DouyinLoginPhase.blocked) ...[
          const SizedBox(height: AppleSpace.md),
          AppleSecondaryButton(label: '重新获取二维码', onPressed: _request),
        ],
        if (_succeeded) ...[
          const SizedBox(height: AppleSpace.md),
          ApplePrimaryButton(
            label: '完成',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ],
    );
  }

  /// 替代登录路径。
  ///
  /// 扫码是主路径；Cookie 导入作为备用（也适用于扫码失败的情况）。
  Widget _buildAlternative(AppleColors c) {
    final blocked = _poll?.phase == DouyinLoginPhase.blocked;

    return AppleGroupedSection(
      header: blocked ? '扫码遇到问题？' : '也可以导入 Cookie 登录',
      children: [
        Padding(
          padding: const EdgeInsets.all(AppleSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '在电脑浏览器登录抖音后，按 F12 打开开发者工具，'
                '从 Network 里任意请求的 Request Headers 复制 Cookie，'
                '然后到「设置 → 抖音 → 导入」粘贴。',
                style: AppleType.footnote.copyWith(
                  color: c.secondaryLabel,
                  height: 1.5,
                ),
              ),
              if (blocked && _poll?.technicalDetail != null) ...[
                const SizedBox(height: AppleSpace.md),
                Container(
                  padding: const EdgeInsets.all(AppleSpace.sm),
                  decoration: BoxDecoration(
                    color: c.fill,
                    borderRadius: BorderRadius.circular(AppleRadius.sm),
                  ),
                  child: Text(
                    '技术原因：${_poll!.technicalDetail}',
                    style: AppleType.caption2.copyWith(
                      color: c.tertiaryLabel,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
