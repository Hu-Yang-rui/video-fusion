/// 抖音扫码登录页（Apple 设计体系）。
///
/// # 诚实设计
///
/// 本页如实呈现两个阶段：
///
/// 1. **获取二维码** —— 真实可用，显示平台返回的二维码
/// 2. **轮询状态** —— 实测被平台风控拦截（缺 `sign`），
///    此时显示明确的说明与替代路径（导入 Cookie）
///
/// **不伪造登录成功**：如果轮询返回 blocked，就显示 blocked，
/// 不会把用户留在"正在登录"的假状态里。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
    setState(() {
      _requesting = true;
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
      if (!mounted) {
        t.cancel();
        return;
      }
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

      final result = await widget.client.pollQrStatus(challenge);
      if (!mounted) return;
      setState(() => _poll = result);

      // 被拦截或过期就停止轮询，不空转
      if (result.phase == DouyinLoginPhase.blocked ||
          result.phase == DouyinLoginPhase.expired) {
        t.cancel();
      }
    });
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
              : QrImageView(
                  data: challenge.qrBase64,
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
      ],
    );
  }

  /// 替代登录路径。
  ///
  /// 这是**当前唯一能真正让用户登录抖音**的方式：
  /// 从浏览器开发者工具复制 Cookie，用已实现的导入功能保存。
  Widget _buildAlternative(AppleColors c) {
    final blocked = _poll?.phase == DouyinLoginPhase.blocked;

    return AppleGroupedSection(
      header: blocked ? '改用这种方式登录' : '扫码不可用时的替代方式',
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
