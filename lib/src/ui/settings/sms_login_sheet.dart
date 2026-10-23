/// 短信验证码登录弹窗。
///
/// # 为什么需要这条路径（实测 2026-10-23）
///
/// 抖音扫码登录卡在结构性死锁：
/// ```
/// 扫码 → 需要 v2 Cookie → v2 需要 sec_ts → sec_ts 需要已登录
/// ```
/// `get_sec_ts` 未登录返回空，`check_sec_connect` 因此恒返回 4031。
///
/// 短信登录走 `aid=6383` 的 passport-web 协议，没有这个环——
/// 只要手机号 + 验证码。
///
/// # 交互要点
///
///  - **发送后 60 秒倒计时**：平台侧有频率限制，让用户等一会儿比
///    反复点了被拒要好
///  - **号码与验证码本地校验**：明显错误的输入不该打服务端
///    （每次失败都会计入风控）
///  - **失败原因如实展示**：验证码错误 / 过期 / 风控，三者处理方式不同
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../../core/qr_login.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';

/// 短信登录弹窗。
///
/// [onSubmit] 收到 (手机号, 验证码) 后执行真正的登录；
/// 返回非空字符串表示失败原因，null 表示成功。
class SmsLoginSheet extends StatefulWidget {
  const SmsLoginSheet({
    super.key,
    required this.platformName,
    required this.capability,
    required this.onSucceeded,
  });

  final String platformName;
  final SmsLoginCapable capability;

  /// 登录成功回调（带回会话 Cookie 等）。
  final void Function(QrLoginPollResult result) onSucceeded;

  @override
  State<SmsLoginSheet> createState() => _SmsLoginSheetState();
}

class _SmsLoginSheetState extends State<SmsLoginSheet> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _phoneFocus = FocusNode();
  final _codeFocus = FocusNode();

  bool _sending = false;
  bool _submitting = false;
  String? _error;

  /// 发送成功后的倒计时（秒）。0 表示可以再次发送。
  int _countdown = 0;
  Timer? _timer;

  /// 验证码是否已发出（未发出时不允许提交）。
  bool _codeSent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _phoneFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _phoneFocus.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _countdown = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) t.cancel();
    });
  }

  Future<void> _sendCode() async {
    if (_sending || _countdown > 0) return;
    final phone = _phoneCtrl.text.trim();

    final phoneErr = validateSmsPhone(phone);
    if (phoneErr != null) {
      setState(() => _error = phoneErr);
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      await widget.capability.sendLoginSmsCode(phone);
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _sending = false;
      });
      _startCountdown();
      _codeFocus.requestFocus();
    } on FusionException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.userMessage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = '验证码发送失败，请稍后重试。';
      });
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final phone = _phoneCtrl.text.trim();
    final code = _codeCtrl.text.trim();

    final phoneErr = validateSmsPhone(phone);
    if (phoneErr != null) {
      setState(() => _error = phoneErr);
      return;
    }
    final codeErr = validateSmsCode(code);
    if (codeErr != null) {
      setState(() => _error = codeErr);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final r = await widget.capability.submitLoginSmsCode(phone, code);
      if (!mounted) return;
      if (r.phase == QrLoginPhase.succeeded) {
        widget.onSucceeded(r);
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _submitting = false;
        _error = r.message ?? '登录未完成，请重试。';
      });
    } on FusionException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.userMessage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '登录失败，请稍后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final canSend = !_sending && _countdown == 0;
    final canSubmit = _codeSent && !_submitting && !_sending;

    return Container(
      // 不透明底色：这是模态表单，不能让底层设置页透出来
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppleRadius.lg),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: AppleSpace.lg,
          right: AppleSpace.lg,
          top: AppleSpace.lg,
          // 键盘弹起时上推
          bottom: MediaQuery.viewInsetsOf(context).bottom + AppleSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.platformName} · 短信登录',
                    style: AppleType.title3.copyWith(color: c.label),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(false),
                  child: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: c.secondaryLabel,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppleSpace.xs),
            Text(
              '验证码由抖音官方下发。本应用不接触你的账号密码。',
              style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
            ),
            const SizedBox(height: AppleSpace.lg),

            // 手机号 + 发送
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneCtrl,
                    focusNode: _phoneFocus,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(11),
                    ],
                    style: AppleType.body.copyWith(color: c.label),
                    decoration: InputDecoration(
                      hintText: '手机号',
                      prefixIcon: Icon(
                        Icons.phone_iphone_rounded,
                        size: 19,
                        color: c.secondaryLabel,
                      ),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _codeFocus.requestFocus(),
                  ),
                ),
                const SizedBox(width: AppleSpace.sm),
                SizedBox(
                  width: 108,
                  child: ApplePrimaryButton(
                    label: _countdown > 0
                        ? '${_countdown}s'
                        : (_sending ? '发送中' : (_codeSent ? '重发' : '获取验证码')),
                    onPressed: canSend ? _sendCode : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppleSpace.md),

            // 验证码 + 登录
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    focusNode: _codeFocus,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: AppleType.body.copyWith(color: c.label),
                    decoration: InputDecoration(
                      hintText: '6 位验证码',
                      prefixIcon: Icon(
                        Icons.sms_outlined,
                        size: 19,
                        color: c.secondaryLabel,
                      ),
                      isDense: true,
                    ),
                    onSubmitted: (_) {
                      if (canSubmit) _submit();
                    },
                  ),
                ),
                const SizedBox(width: AppleSpace.sm),
                SizedBox(
                  width: 108,
                  child: ApplePrimaryButton(
                    label: _submitting ? '登录中' : '登录',
                    onPressed: canSubmit ? _submit : null,
                  ),
                ),
              ],
            ),

            // 错误提示
            if (_error != null) ...[
              const SizedBox(height: AppleSpace.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 15, color: c.red),
                  const SizedBox(width: AppleSpace.xs),
                  Expanded(
                    child: Text(
                      _error!,
                      style: AppleType.footnote.copyWith(color: c.red),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: AppleSpace.lg),

            // 说明
            Text(
              '凭证使用系统安全存储加密保存，不会出现在日志或界面中。',
              style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机号本地校验（与 `sms_login.dart` 的规则一致）。
///
/// 这里单独实现一份是为了 UI 层不 import 适配器内部文件——
/// 两者规则必须一致，有测试守着。
String? validateSmsPhone(String raw) {
  var s = raw.replaceAll(RegExp(r'[\s\-()]'), '');
  if (s.startsWith('+86')) s = s.substring(3);
  if (s.startsWith('86') && s.length == 13) s = s.substring(2);
  if (s.isEmpty) return '请输入手机号。';
  if (!RegExp(r'^1\d{10}$').hasMatch(s)) return '手机号格式不正确（应为 11 位）。';
  return null;
}

/// 验证码本地校验。
String? validateSmsCode(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '请输入验证码。';
  if (!RegExp(r'^\d{6}$').hasMatch(s)) return '验证码应为 6 位数字。';
  return null;
}
