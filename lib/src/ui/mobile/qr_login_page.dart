/// 扫码登录页面（纯原生 UI，**不使用任何 web 组件**）。
///
/// 交互流程：
///  1. 进入页面 → 自动向平台申请二维码
///  2. APP 用 `qr_flutter` **在本地渲染**二维码图片（不是加载平台网页）
///  3. 用户在手机客户端扫码 → APP 轮询状态 → 实时更新提示
///  4. 确认成功 → 保存会话 → 返回
///
/// 为什么不用 WebView：产品要求"APP 内做一个 UI，不能使用 web"。
/// 二维码的原始内容只是一个 URL 字符串，本地渲染即可，
/// 完全不需要加载任何网页。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/qr_login.dart';
import 'mobile_theme.dart';
import 'mobile_widgets.dart';

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
  Timer? _expiryTimer;

  bool _requesting = false;
  FusionException? _error;

  @override
  void initState() {
    super.initState();
    _requestQr();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }

  Future<void> _requestQr() async {
    _pollTimer?.cancel();
    _expiryTimer?.cancel();

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
        _requesting = false;
        _lastPoll = const QrLoginPollResult(
          phase: QrLoginPhase.waitingForScan,
          message: '请使用手机客户端扫描二维码。',
        );
      });
      _startPolling(challenge);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _error = normalizeError(e);
      });
    }
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
        setState(() => _lastPoll = QrLoginPollResult(
              phase: QrLoginPhase.waitingForScan,
              message: '网络波动，正在重试…（${e.presentation.title}）',
            ));
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
    return Scaffold(
      backgroundColor: MobileTokens.lightCanvas,
      appBar: AppBar(
        backgroundColor: MobileTokens.lightCanvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded,
              size: 22, color: MobileTokens.ink),
        ),
        title: Text(
          '登录${widget.platformName}',
          style: MobileText.listTitle,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(MobileTokens.s5),
          child: Column(
            children: [
              const SizedBox(height: MobileTokens.s4),
              Text(
                '扫码登录',
                style: MobileText.pageTitle,
              ),
              const SizedBox(height: MobileTokens.s2),
              Text(
                '使用${widget.platformName}手机客户端扫码，'
                '在手机上确认即可完成登录。',
                style: MobileText.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: MobileTokens.s6),
              _buildQrArea(),
              const SizedBox(height: MobileTokens.s5),
              _buildStatus(),
              const SizedBox(height: MobileTokens.s6),
              _buildSecurityNotice(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQrArea() {
    final challenge = _challenge;

    return Container(
      width: 236,
      height: 236,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(MobileTokens.rCard),
      ),
      alignment: Alignment.center,
      child: _requesting
          ? const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: MobileTokens.accent,
              ),
            )
          : challenge == null
              ? const Icon(Icons.qr_code_2_rounded,
                  size: 64, color: Color(0xFFBDBDBD))
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    // 纯 Dart 本地渲染，不加载任何网页
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
                    if (_isExpiredOrDone) _buildQrOverlay(),
                  ],
                ),
    );
  }

  bool get _isExpiredOrDone {
    final phase = _lastPoll?.phase;
    return phase == QrLoginPhase.expired || phase == QrLoginPhase.succeeded;
  }

  Widget _buildQrOverlay() {
    final succeeded = _lastPoll?.phase == QrLoginPhase.succeeded;
    return Container(
      width: 208,
      height: 208,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            succeeded ? Icons.check_circle_rounded : Icons.refresh_rounded,
            size: 36,
            color: succeeded ? MobileTokens.positive : MobileTokens.inkTertiary,
          ),
          const SizedBox(height: MobileTokens.s3),
          Text(
            succeeded ? '登录成功' : '二维码已过期',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF101012),
            ),
          ),
          if (!succeeded) ...[
            const SizedBox(height: MobileTokens.s3),
            TextButton(
              onPressed: _requestQr,
              child: const Text('点击刷新'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatus() {
    if (_error != null) {
      return Column(
        children: [
          MobileErrorCard(
            title: _error!.presentation.title,
            detail: _error!.userMessage,
            onRetry: _error!.retryable ? _requestQr : null,
          ),
        ],
      );
    }

    final poll = _lastPoll;
    if (poll == null) return const SizedBox.shrink();

    final (icon, color) = switch (poll.phase) {
      QrLoginPhase.waitingForScan => (
          Icons.qr_code_scanner_rounded,
          MobileTokens.inkTertiary
        ),
      QrLoginPhase.waitingForConfirm => (
          Icons.phone_iphone_rounded,
          MobileTokens.accent
        ),
      QrLoginPhase.succeeded => (
          Icons.check_circle_rounded,
          MobileTokens.positive
        ),
      QrLoginPhase.expired => (Icons.timer_off_rounded, MobileTokens.caution),
      _ => (Icons.info_outline_rounded, MobileTokens.inkTertiary),
    };

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: MobileTokens.s2),
        Flexible(
          child: Text(
            poll.message ?? '',
            style: MobileText.body.copyWith(color: color),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildSecurityNotice() {
    return Container(
      padding: const EdgeInsets.all(MobileTokens.s4),
      decoration: BoxDecoration(
        color: MobileTokens.lightSurface,
        borderRadius: BorderRadius.circular(MobileTokens.rCard),
        border: Border.all(color: MobileTokens.lightBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined,
                  size: 15, color: MobileTokens.accent),
              const SizedBox(width: MobileTokens.s2),
              Text(
                '关于你的账号安全',
                style: MobileText.label.copyWith(
                  color: MobileTokens.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: MobileTokens.s3),
          _notice('本应用不索取、不接触你的账号密码。'),
          _notice('登录由平台官方完成，本应用只接收平台下发的会话凭证。'),
          _notice('凭证使用系统安全存储加密保存（Android Keystore / Windows 凭据管理器）。'),
          _notice('凭证不会写入任何日志，也不会发送到除该平台以外的任何服务器。'),
          _notice('你可随时在本页退出登录，退出即彻底删除本地凭证。'),
        ],
      ),
    );
  }

  Widget _notice(String text) => Padding(
        padding: const EdgeInsets.only(bottom: MobileTokens.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: 3.5,
                height: 3.5,
                decoration: const BoxDecoration(
                  color: MobileTokens.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: MobileTokens.s2),
            Expanded(
              child: Text(
                text,
                style: MobileText.caption.copyWith(height: 1.55),
              ),
            ),
          ],
        ),
      );
}
