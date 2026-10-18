/// 链接接入底部弹层（次要入口）。
///
/// 在短视频场景里，链接接入不是主流程 —— 主流程是打开就刷。
/// 这里作为"把外部视频拉进来"的补充入口，从顶栏进入。
///
/// 使用项目统一的 Apple 设计系统（与评论面板、投币面板一致）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../models/unified_video.dart';

class LinkIntakeSheet extends StatefulWidget {
  const LinkIntakeSheet({super.key, required this.service});

  final VideoService service;

  @override
  State<LinkIntakeSheet> createState() => _LinkIntakeSheetState();
}

class _LinkIntakeSheetState extends State<LinkIntakeSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _busy = false;
  FusionException? _error;
  UnifiedVideo? _resolved;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '请输入视频链接。',
        );
        _resolved = null;
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _resolved = null;
    });

    final result = await widget.service.resolveLink(input);

    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _resolved = result.video;
        _controller.clear();
      } else {
        _error = result.error;
      }
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty && mounted) {
      setState(() => _controller.text = text);
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: c.secondaryGroupedBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppleRadius.sheet),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.lg,
              AppleSpace.sm,
              AppleSpace.lg,
              AppleSpace.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 拖拽条
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.separator,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppleSpace.lg),

                Row(
                  children: [
                    Text(
                      '接入视频链接',
                      style: AppleType.title3.copyWith(color: c.label),
                    ),
                    const Spacer(),
                    AppleIconButton(
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: AppleSpace.xs),
                Text(
                  '粘贴 B 站或抖音的视频链接。',
                  style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                ),

                const SizedBox(height: AppleSpace.lg),

                // 输入框
                Container(
                  decoration: BoxDecoration(
                    color: c.background,
                    borderRadius: BorderRadius.circular(AppleRadius.md),
                    border: Border.all(color: c.separator, width: 0.5),
                  ),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    enabled: !_busy,
                    autofocus: true,
                    maxLines: 3,
                    minLines: 1,
                    style: AppleType.subheadline.copyWith(color: c.label),
                    decoration: InputDecoration(
                      hintText: '粘贴链接…',
                      hintStyle: AppleType.subheadline.copyWith(
                        color: c.tertiaryLabel,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(AppleSpace.md),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),

                const SizedBox(height: AppleSpace.md),

                Row(
                  children: [
                    AppleTextButton(
                      label: '粘贴',
                      onPressed: _busy ? null : _paste,
                    ),
                    const Spacer(),
                    ApplePrimaryButton(
                      label: _busy ? '接入中…' : '接入',
                      onPressed: _busy ? null : _submit,
                    ),
                  ],
                ),

                // 成功
                if (_resolved != null) ...[
                  const SizedBox(height: AppleSpace.md),
                  _Banner(
                    color: c.green,
                    icon: Icons.check_circle_outline_rounded,
                    text: '已接入：${_resolved!.title}',
                  ),
                ],

                // 错误
                if (_error != null) ...[
                  const SizedBox(height: AppleSpace.md),
                  _Banner(
                    color: c.red,
                    icon: Icons.error_outline_rounded,
                    text: _error!.userMessage,
                  ),
                ],

                const SizedBox(height: AppleSpace.md),
                Row(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 12,
                      color: c.tertiaryLabel,
                    ),
                    const SizedBox(width: AppleSpace.xs),
                    Expanded(
                      child: Text(
                        '本应用不索取账号密码或 Cookie。',
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条带底色的提示条。
class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppleSpace.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppleRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: AppleSpace.sm),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppleType.footnote.copyWith(color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
