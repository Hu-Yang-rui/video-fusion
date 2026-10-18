/// Cookie 导入 / 导出的 UI。
///
/// 两个弹层：
///  - [showCookieImportSheet] —— 粘贴 Cookie 串导入
///  - [showCookieExportSheet] —— 查看并复制导出文本
///
/// 安全提示是强制的：导出内容含明文凭证，必须让用户看见。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cookie_portable.dart';
import '../../core/credential_vault.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';

/// 弹出导入面板。
///
/// 返回导入成功的会话；用户取消或失败返回 null。
Future<PlatformSession?> showCookieImportSheet(
  BuildContext context, {
  String? platformHint,
  String? platformLabel,
}) {
  return showModalBottomSheet<PlatformSession>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CookieImportSheet(
      platformHint: platformHint,
      platformLabel: platformLabel,
    ),
  );
}

/// 弹出导出面板。
Future<void> showCookieExportSheet(
  BuildContext context, {
  required PlatformSession session,
  required String platformLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CookieExportSheet(
      session: session,
      platformLabel: platformLabel,
    ),
  );
}

// ── 导入 ──────────────────────────────────────────────────────

class _CookieImportSheet extends StatefulWidget {
  const _CookieImportSheet({this.platformHint, this.platformLabel});

  final String? platformHint;
  final String? platformLabel;

  @override
  State<_CookieImportSheet> createState() => _CookieImportSheetState();
}

class _CookieImportSheetState extends State<_CookieImportSheet> {
  final TextEditingController _controller = TextEditingController();
  CookieImportResult? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _doParse() {
    final text = _controller.text;
    final result = CookiePortable.parse(
      text,
      platformHint: widget.platformHint,
    );
    setState(() => _result = result);
  }

  void _confirm() {
    final result = _result;
    if (result == null || !result.ok) return;
    Navigator.of(context).pop(result.session);
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.lg,
              AppleSpace.sm,
              AppleSpace.lg,
              AppleSpace.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
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

                Text(
                  widget.platformLabel == null
                      ? '导入 Cookie'
                      : '导入 ${widget.platformLabel} Cookie',
                  style: AppleType.title2.copyWith(color: c.label),
                ),
                const SizedBox(height: AppleSpace.xs),
                Text(
                  '从浏览器开发者工具复制 Cookie 后粘贴到下面。'
                  '支持原始 Cookie 串、JSON，或本应用导出的内容。',
                  style: AppleType.footnote.copyWith(
                    color: c.secondaryLabel,
                    height: 1.4,
                  ),
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
                    minLines: 5,
                    maxLines: 10,
                    autofocus: true,
                    style: AppleType.footnote.copyWith(
                      color: c.label,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                    decoration: InputDecoration(
                      hintText: 'SESSDATA=xxx; bili_jct=yyy; DedeUserID=zzz',
                      hintStyle: AppleType.footnote.copyWith(
                        color: c.tertiaryLabel,
                        fontFamily: 'monospace',
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(AppleSpace.md),
                    ),
                    onChanged: (_) {
                      // 输入变化后清掉上次结果，避免显示过期状态
                      if (_result != null) setState(() => _result = null);
                    },
                  ),
                ),

                // 结果
                if (_result != null) ...[
                  const SizedBox(height: AppleSpace.md),
                  _buildResult(c, _result!),
                ],

                const SizedBox(height: AppleSpace.lg),

                Row(
                  children: [
                    Expanded(
                      child: AppleSecondaryButton(
                        label: '取消',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: AppleSpace.md),
                    Expanded(
                      child: ApplePrimaryButton(
                        label: _result?.ok == true ? '保存' : '解析',
                        onPressed: _result?.ok == true ? _confirm : _doParse,
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

  Widget _buildResult(AppleColors c, CookieImportResult r) {
    if (!r.ok) {
      return Container(
        padding: const EdgeInsets.all(AppleSpace.md),
        decoration: BoxDecoration(
          color: c.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppleRadius.sm),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: c.red),
            const SizedBox(width: AppleSpace.sm),
            Expanded(
              child: Text(
                r.error ?? '解析失败',
                style: AppleType.footnote.copyWith(color: c.red, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    // 成功：只显示键名，不显示值
    return Container(
      padding: const EdgeInsets.all(AppleSpace.md),
      decoration: BoxDecoration(
        color: c.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppleRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 16, color: c.green),
              const SizedBox(width: AppleSpace.sm),
              Text(
                '识别到 ${r.cookieNames.length} 个 Cookie',
                style: AppleType.footnoteEmphasized.copyWith(color: c.green),
              ),
            ],
          ),
          const SizedBox(height: AppleSpace.xs),
          Text(
            r.cookieNames.join('、'),
            style: AppleType.caption1.copyWith(color: c.secondaryLabel),
          ),
        ],
      ),
    );
  }
}

// ── 导出 ──────────────────────────────────────────────────────

class _CookieExportSheet extends StatefulWidget {
  const _CookieExportSheet({
    required this.session,
    required this.platformLabel,
  });

  final PlatformSession session;
  final String platformLabel;

  @override
  State<_CookieExportSheet> createState() => _CookieExportSheetState();
}

class _CookieExportSheetState extends State<_CookieExportSheet> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final session = widget.session;
    final jsonText = CookiePortable.exportSession(session);
    final headerText = CookiePortable.exportCookieHeader(session);

    return Container(
      decoration: BoxDecoration(
        color: c.secondaryGroupedBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppleRadius.sheet),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppleSpace.lg,
            AppleSpace.sm,
            AppleSpace.lg,
            AppleSpace.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
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

              Text(
                '导出 ${widget.platformLabel} Cookie',
                style: AppleType.title2.copyWith(color: c.label),
              ),
              const SizedBox(height: AppleSpace.md),

              // 安全警告：必须显眼
              Container(
                padding: const EdgeInsets.all(AppleSpace.md),
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppleRadius.sm),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: c.orange,
                    ),
                    const SizedBox(width: AppleSpace.sm),
                    Expanded(
                      child: Text(
                        '下面的内容包含你的登录凭证（明文）。'
                        '任何拿到它的人都能以你的身份操作该账号。'
                        '请勿分享、截图或上传到任何地方。',
                        style: AppleType.footnote.copyWith(
                          color: c.orange,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: AppleSpace.lg),

              // 账号信息（脱敏）
              AppleGroupedSection(
                children: [
                  AppleListRow(
                    title: '账号',
                    trailingText: session.displayName,
                  ),
                  AppleListRow(
                    title: 'Cookie 数量',
                    trailingText: '${session.cookies.length}',
                  ),
                ],
              ),

              const SizedBox(height: AppleSpace.lg),

              // 默认折叠，点"显示"才展开
              if (!_revealed)
                ApplePrimaryButton(
                  label: '显示导出内容',
                  onPressed: () => setState(() => _revealed = true),
                )
              else ...[
                _buildCodeBlock(
                  c,
                  label: '完整格式（可再次导入本应用）',
                  text: jsonText,
                ),
                const SizedBox(height: AppleSpace.md),
                _buildCodeBlock(
                  c,
                  label: 'Cookie 头（可粘贴到别处）',
                  text: headerText,
                ),
              ],

              const SizedBox(height: AppleSpace.lg),

              Row(
                children: [
                  Expanded(
                    child: AppleSecondaryButton(
                      label: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  if (_revealed) ...[
                    const SizedBox(width: AppleSpace.md),
                    Expanded(
                      child: ApplePrimaryButton(
                        label: '复制完整格式',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: jsonText),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已复制到剪贴板，请妥善保管'),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCodeBlock(
    AppleColors c, {
    required String label,
    required String text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: AppleType.caption1.copyWith(color: c.secondaryLabel),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制')),
                  );
                }
              },
              child: Text(
                '复制',
                style: AppleType.caption1.copyWith(color: c.blue),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(AppleSpace.sm),
          decoration: BoxDecoration(
            color: c.background,
            borderRadius: BorderRadius.circular(AppleRadius.sm),
            border: Border.all(color: c.separator, width: 0.5),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: AppleType.caption2.copyWith(
                color: c.label,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
