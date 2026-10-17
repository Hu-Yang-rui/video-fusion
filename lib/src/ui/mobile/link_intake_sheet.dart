/// 链接接入底部弹层（次要入口）。
///
/// 在短视频平台里，链接接入不是主流程 —— 主流程是打开就刷。
/// 这里作为"把外部视频拉进来"的补充入口，从顶栏 + 号进入。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../models/unified_video.dart';
import 'mobile_theme.dart';
import 'mobile_widgets.dart';

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
  String? _detectedPlatform;

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
      _detectedPlatform = null;
    });

    final result = await widget.service.resolveLink(input);

    if (!mounted) return;
    setState(() {
      _busy = false;
      _detectedPlatform = result.match?.platformId;
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          MobileTokens.s5,
          MobileTokens.s3,
          MobileTokens.s5,
          MobileTokens.s6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: MobileTokens.lightBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: MobileTokens.s4),
            Row(
              children: [
                const Icon(Icons.add_link_rounded,
                    size: 18, color: MobileTokens.accent),
                const SizedBox(width: MobileTokens.s2),
                Text('接入视频链接', style: MobileText.listTitle),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded,
                      size: 20, color: MobileTokens.inkTertiary),
                ),
              ],
            ),
            const SizedBox(height: MobileTokens.s2),
            Text(
              '把 B 站或抖音的视频链接粘贴进来，即可加入你的视频流。',
              style: MobileText.caption.copyWith(height: 1.5),
            ),
            const SizedBox(height: MobileTokens.s4),

            // 输入框
            TextField(
              controller: _controller,
              focusNode: _focus,
              enabled: !_busy,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              style: MobileText.body.copyWith(
                color: MobileTokens.ink,
                fontSize: 13.5,
              ),
              decoration: InputDecoration(
                hintText: '粘贴链接…',
                hintStyle: MobileText.body.copyWith(
                  color: MobileTokens.inkTertiary,
                  fontSize: 13,
                ),
                filled: true,
                fillColor: MobileTokens.lightCanvas,
                contentPadding: const EdgeInsets.all(MobileTokens.s3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MobileTokens.rControl),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MobileTokens.rControl),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(MobileTokens.rControl),
                  borderSide:
                      const BorderSide(color: MobileTokens.accent, width: 1.4),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),

            const SizedBox(height: MobileTokens.s3),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.content_paste_rounded, size: 15),
                  label: const Text('粘贴'),
                  style: TextButton.styleFrom(
                    foregroundColor: MobileTokens.accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: MobileTokens.s2,
                    ),
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: MobileTokens.accent,
                    foregroundColor: const Color(0xFF06231F),
                    padding: const EdgeInsets.symmetric(
                      horizontal: MobileTokens.s6,
                      vertical: MobileTokens.s3,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(MobileTokens.rControl),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF06231F),
                          ),
                        )
                      : const Text('接入',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),

            // 成功
            if (_resolved != null) ...[
              const SizedBox(height: MobileTokens.s3),
              Container(
                padding: const EdgeInsets.all(MobileTokens.s3),
                decoration: BoxDecoration(
                  color: MobileTokens.positive.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(MobileTokens.rControl),
                  border: Border.all(
                    color: MobileTokens.positive.withValues(alpha: 0.28),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline_rounded,
                        size: 16, color: MobileTokens.positive),
                    const SizedBox(width: MobileTokens.s2),
                    Expanded(
                      child: Text(
                        '已接入：${_resolved!.title}',
                        style: MobileText.caption
                            .copyWith(color: MobileTokens.positive),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // 错误
            if (_error != null) ...[
              const SizedBox(height: MobileTokens.s3),
              MobileErrorCard(
                title: _error!.presentation.title,
                detail: _error!.userMessage,
                extra: _detectedPlatform != null
                    ? Text(
                        '识别到的来源：$_detectedPlatform',
                        style: MobileText.caption,
                      )
                    : null,
              ),
            ],

            const SizedBox(height: MobileTokens.s4),
            Row(
              children: [
                const Icon(Icons.shield_outlined,
                    size: 13, color: MobileTokens.inkTertiary),
                const SizedBox(width: MobileTokens.s2),
                Expanded(
                  child: Text(
                    '本应用不索取账号密码或 Cookie。',
                    style: MobileText.caption,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
