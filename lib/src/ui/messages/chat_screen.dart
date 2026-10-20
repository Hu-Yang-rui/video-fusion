/// 私信聊天页。
///
/// # 行为契约
///
///  - 打开即拉**最新一页**（服务端新→旧，store 内部转正序）。
///  - 滚到顶部自动往前翻（`end_seqno` = 上一页 `min_seqno`），
///    按 `msgKey` 去重，重复消息不会插两遍。
///  - 发送：本地先插"发送中"气泡 → 服务端确认后替换为正式消息 →
///    失败标红并可点重发。**不显示假成功**。
///  - 已读：拿到最新消息后对**这一个会话**调 `markImSessionRead`。
///
/// # 消息类型渲染（需求一·1）
///
/// | 类型 | 渲染方式 |
/// |---|---|
/// | 文本 | 气泡内文字；表情短代码原样显示（不伪造内联图） |
/// | 图片 | 按平台下发的宽高比占位 → 加载 → 可点开大图 |
/// | 自定义表情 | 小尺寸（96pt 上限）内联图，可点开大图 |
/// | 视频 | 封面图 + 播放角标，点击提示"请在原平台查看" |
/// | 撤回 | 居中的浅色提示 |
/// | 系统卡片 | 居中浅色卡片文本 |
/// | 未知 | "暂不支持的消息类型 N"，绝不显示原始 JSON |
///
/// **绝不显示原始 JSON、资源 URL 或空白占位**（需求明令）。
///
/// # 性能（需求一·1 最后一条）
///
///  - 图片用 `ResizeImage` 限制解码尺寸，避免大图吃内存
///  - 列表项有稳定 `ValueKey(msgKey)`，翻页追加时复用 element
///  - `cacheWidth` 按气泡最大宽度计算，不用原图分辨率解码
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/im.dart';
import 'emote_panel.dart';
import 'im_store.dart';
import 'image_viewer.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.store,
    required this.talkerId,
    required this.title,
  });

  final ImStore store;
  final int talkerId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final ImagePicker _picker = ImagePicker();

  bool _sending = false;

  /// 已选待发送的图片（预览阶段）。
  String? _pendingImagePath;

  /// 表情面板是否展开。
  bool _emoteOpen = false;

  ImChatState get _chat => widget.store.chatOf(widget.talkerId);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
    _scroll.addListener(_onScroll);
    _load();
  }

  Future<void> _load() async {
    await widget.store.loadMessages(widget.talkerId);
    if (!mounted) return;
    // 拿到最新消息后才标记已读（只这一个会话）
    await widget.store.markRead(widget.talkerId);
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
    // store 抛出的一次性错误（例如图片校验失败）用 SnackBar 呈现
    final err = widget.store.transientError;
    if (err != null) {
      widget.store.clearTransientError();
      _toast(err);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// reverse 列表：滚到"顶部"（视觉上方）= 加载更早的历史。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      widget.store.loadOlderMessages(widget.talkerId);
    }
  }

  // ── 发送文本 ────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    final ok = await widget.store.sendText(widget.talkerId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) {
      // 失败：把文本放回输入框，让用户能直接重发
      _input.text = text;
      final failed = _chat.messages.lastWhere(
        (m) => m.sendState == ImSendState.failed,
        orElse: () => _chat.messages.last,
      );
      _toast(failed.localError ?? '发送失败，请重试');
    }
  }

  // ── 选图 / 拍照 / 发送图片 ──────────────────────────────────

  Future<void> _pickFromGallery() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        // 不做压缩：平台侧有 20MB 上限，本地校验会拦住；
        // 主动压缩会改变用户原图质量，属于未经请求的处理。
        requestFullMetadata: false,
      );
      if (picked == null) return;
      setState(() => _pendingImagePath = picked.path);
    } catch (e) {
      _toast('无法打开相册，请检查系统权限。');
    }
  }

  Future<void> _pickFromCamera() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.camera,
        requestFullMetadata: false,
      );
      if (picked == null) return;
      setState(() => _pendingImagePath = picked.path);
    } catch (e) {
      _toast('无法打开相机，请检查系统权限。');
    }
  }

  void _cancelPendingImage() {
    setState(() => _pendingImagePath = null);
  }

  Future<void> _sendPendingImage() async {
    final path = _pendingImagePath;
    if (path == null || _sending) return;
    setState(() => _sending = true);
    final ok = await widget.store.sendImage(widget.talkerId, filePath: path);
    if (!mounted) return;
    setState(() {
      _sending = false;
      // 成功才清掉预览；失败保留，让用户能直接重试
      if (ok) _pendingImagePath = null;
    });
    if (!ok) {
      final failed = _chat.messages.lastWhere(
        (m) => m.sendState == ImSendState.failed,
        orElse: () => _chat.messages.last,
      );
      _toast(failed.localError ?? '图片发送失败，请重试');
    }
  }

  // ── 表情 ────────────────────────────────────────────────────

  void _toggleEmotePanel() {
    setState(() => _emoteOpen = !_emoteOpen);
    if (_emoteOpen) {
      _focus.unfocus();
      widget.store.loadEmotePanel();
    }
  }

  Future<void> _sendEmote(ImEmote emote) async {
    final ok = await widget.store.sendEmote(widget.talkerId, emote.shortcode);
    if (!mounted) return;
    if (!ok) _toast('表情发送失败，请重试');
  }

  // ── 构建 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final chat = _chat;

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.label,
      ),
      body: Column(
        children: [
          Expanded(child: _body(c, chat)),
          if (_pendingImagePath != null)
            _PendingImageBar(
              path: _pendingImagePath!,
              sending: _sending,
              onCancel: _cancelPendingImage,
              onSend: _sendPendingImage,
            ),
          if (_emoteOpen)
            EmotePanel(
              panel: widget.store.emotePanel,
              loading: widget.store.emoteLoading,
              onSelect: _sendEmote,
            ),
          _composer(c),
        ],
      ),
    );
  }

  Widget _body(AppleColors c, ImChatState chat) {
    if (chat.loading && chat.messages.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (chat.error != null && chat.messages.isEmpty) {
      return AppleErrorState(
        title: chat.error!.presentation.title,
        message: chat.error!.userMessage,
        onRetry: () => widget.store.loadMessages(widget.talkerId, refresh: true),
      );
    }

    if (chat.loadedOnce && chat.messages.isEmpty) {
      return const AppleEmptyState(
        icon: Icons.chat_bubble_outline_rounded,
        title: '还没有消息',
        message: '发一条消息开始对话。',
      );
    }

    // reverse: true → 传入的列表需要反转（store 存正序，最新在末尾）
    final items = chat.messages.reversed.toList();
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.lg,
        vertical: AppleSpace.md,
      ),
      itemCount: items.length + (chat.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return Padding(
            padding: const EdgeInsets.all(AppleSpace.md),
            child: Center(
              child: chat.loadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: () =>
                          widget.store.loadOlderMessages(widget.talkerId),
                      child: const Text('加载更早的消息'),
                    ),
            ),
          );
        }
        final m = items[index];
        return _Bubble(
          key: ValueKey<String>(m.msgKey),
          message: m,
          mine: m.isMine(widget.store.myUid),
          uploadProgress: widget.store.uploadProgressOf(m.msgKey),
          onRetry: m.sendState == ImSendState.failed
              ? () => widget.store.resend(m)
              : null,
        );
      },
    );
  }

  Widget _composer(AppleColors c) {
    final canSendImage = widget.store.supportsImageSend;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppleSpace.sm,
          AppleSpace.sm,
          AppleSpace.md,
          AppleSpace.sm,
        ),
        decoration: BoxDecoration(
          color: c.secondaryGroupedBackground,
          border: Border(top: BorderSide(color: c.separator, width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 图片入口（平台支持时才有）
            if (canSendImage)
              SizedBox(
                width: 40,
                height: 44,
                child: IconButton(
                  onPressed: _sending ? null : _showImageSourceSheet,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 22),
                  color: c.label,
                  tooltip: '发送图片',
                ),
              ),
            // 表情入口
            if (widget.store.supportsEmote)
              SizedBox(
                width: 40,
                height: 44,
                child: IconButton(
                  onPressed: _toggleEmotePanel,
                  icon: Icon(
                    _emoteOpen
                        ? Icons.keyboard_rounded
                        : Icons.emoji_emotions_outlined,
                    size: 22,
                  ),
                  color: _emoteOpen ? c.blue : c.label,
                  tooltip: '表情',
                ),
              ),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  onTap: () {
                    if (_emoteOpen) setState(() => _emoteOpen = false);
                  },
                  decoration: InputDecoration(
                    hintText: '发消息…',
                    isDense: true,
                    filled: true,
                    fillColor: c.fill,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppleSpace.md,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppleRadius.pill),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppleSpace.sm),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton.filled(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                tooltip: '发送',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 图片来源选择（相册 / 拍照）。
  Future<void> _showImageSourceSheet() async {
    final c = AppleColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.secondaryGroupedBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppleRadius.lg),
        ),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppleSpace.sm),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: c.label),
              title: Text('从相册选择', style: AppleType.body.copyWith(color: c.label)),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _pickFromGallery();
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: c.label),
              title: Text('拍照', style: AppleType.body.copyWith(color: c.label)),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _pickFromCamera();
              },
            ),
            const SizedBox(height: AppleSpace.sm),
          ],
        ),
      ),
    );
  }
}

/// 已选图片的预览条（发送前）。
class _PendingImageBar extends StatelessWidget {
  const _PendingImageBar({
    required this.path,
    required this.sending,
    required this.onCancel,
    required this.onSend,
  });

  final String path;
  final bool sending;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.md,
        vertical: AppleSpace.sm,
      ),
      color: c.secondaryGroupedBackground,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppleRadius.sm),
            child: Image.file(
              File(path),
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              cacheWidth: 168,
              errorBuilder: (_, __, ___) => Container(
                width: 56,
                height: 56,
                color: c.fill,
                child: Icon(Icons.broken_image_outlined,
                    size: 18, color: c.tertiaryLabel),
              ),
            ),
          ),
          const SizedBox(width: AppleSpace.md),
          Expanded(
            child: Text(
              sending ? '正在发送…' : '将发送这张图片',
              style: AppleType.footnote.copyWith(color: c.secondaryLabel),
            ),
          ),
          if (!sending) ...[
            TextButton(
              onPressed: onCancel,
              child: const Text('取消'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: onSend,
              child: const Text('发送'),
            ),
          ] else
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

/// 一条消息气泡。
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.message,
    required this.mine,
    this.onRetry,
    this.uploadProgress,
  });

  final ImMessage message;
  final bool mine;
  final VoidCallback? onRetry;

  /// 上传进度（0..1），仅图片发送中有值。
  final double? uploadProgress;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final failed = message.sendState == ImSendState.failed;
    final sending = message.sendState == ImSendState.sending;

    // 撤回 / 系统消息：居中浅色，不参与左右气泡布局
    if (message.type == ImMessageType.withdraw) {
      return _CenteredNotice(
        text: message.text ?? '这条消息已被撤回',
        color: c.tertiaryLabel,
      );
    }
    if (message.type == ImMessageType.systemCard) {
      return _CenteredNotice(
        text: message.text ?? '系统消息',
        color: c.secondaryLabel,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (mine && (failed || sending))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: failed
                  ? GestureDetector(
                      onTap: onRetry,
                      child: Icon(Icons.error_rounded, size: 16, color: c.red),
                    )
                  : const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
            ),
          Flexible(child: _content(c)),
        ],
      ),
    );
  }

  Widget _content(AppleColors c) {
    final type = message.type;

    // 图片 / 自定义表情：无气泡底色，直接渲染图片
    if (type == ImMessageType.image) {
      return _ImageBubble(
        message: message,
        mine: mine,
        maxWidth: 200,
        uploadProgress: uploadProgress,
      );
    }
    if (type == ImMessageType.customEmoji) {
      return _ImageBubble(
        message: message,
        mine: mine,
        // 表情比图片小：上限 96，保持"内联小图"的语义
        maxWidth: 96,
        isEmote: true,
      );
    }
    if (type == ImMessageType.video) {
      return _VideoBubble(message: message, mine: mine);
    }

    // 文本 / 未知：气泡 + 文字
    final body = message.text ?? _placeholderFor(message);
    final isPlaceholder = message.text == null;

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.md,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: mine ? c.blue : c.secondaryGroupedBackground,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppleRadius.md),
          topRight: const Radius.circular(AppleRadius.md),
          bottomLeft: Radius.circular(mine ? AppleRadius.md : 4),
          bottomRight: Radius.circular(mine ? 4 : AppleRadius.md),
        ),
      ),
      child: Text(
        body,
        style: AppleType.subheadline.copyWith(
          color: mine ? Colors.white : c.label,
          height: 1.35,
          fontStyle: isPlaceholder ? FontStyle.italic : null,
        ),
      ),
    );
  }

  /// 没有可读文本时的占位说明。
  ///
  /// **绝不显示原始 JSON 或资源 URL**（需求明令）。
  static String _placeholderFor(ImMessage m) => switch (m.type) {
        ImMessageType.image => '[图片无法显示]',
        ImMessageType.customEmoji => '[表情无法显示]',
        ImMessageType.video => '[视频消息]',
        ImMessageType.shareCard => '[分享卡片]',
        ImMessageType.withdraw => '这条消息已被撤回',
        ImMessageType.systemCard => '[系统消息]',
        ImMessageType.text => '[空消息]',
        ImMessageType.unknown => '[暂不支持的消息类型 ${m.msgType}]',
      };
}

/// 图片气泡：加载态 → 成功 / 失败 → 可点开大图。
class _ImageBubble extends StatelessWidget {
  const _ImageBubble({
    required this.message,
    required this.mine,
    required this.maxWidth,
    this.isEmote = false,
    this.uploadProgress,
  });

  final ImMessage message;
  final bool mine;
  final double maxWidth;

  /// 是否自定义表情（决定圆角与尺寸策略）。
  final bool isEmote;

  final double? uploadProgress;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final media = message.media;

    // 本地预览优先（发送中 / 刚发送成功、远端图还没下载完）
    final localPath = message.localPreviewPath;

    // 尺寸：优先用平台下发的宽高比；拿不到就用方形占位。
    // **不猜比例**——猜错了会导致列表跳动。
    final aspect = media?.aspectRatio;
    final double w = maxWidth;
    final double h = aspect == null
        ? (isEmote ? 96 : maxWidth * 0.75)
        : (w / aspect).clamp(isEmote ? 48.0 : 80.0, isEmote ? 96.0 : 320.0);

    final radius = BorderRadius.circular(isEmote ? AppleRadius.sm : AppleRadius.md);

    Widget placeholderIcon(IconData icon, String? label) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: radius,
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: c.tertiaryLabel),
              if (label != null) ...[
                const SizedBox(height: 4),
                Text(
                  label,
                  style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        );

    // 既没有远端地址也没有本地文件：如实说"无法显示"
    if ((media == null || media.url.isEmpty) && localPath == null) {
      return placeholderIcon(Icons.broken_image_outlined, '图片无法显示');
    }

    // 上传中：显示本地图 + 进度遮罩
    final uploading = message.sendState == ImSendState.sending &&
        uploadProgress != null &&
        uploadProgress! < 1;

    final image = localPath != null
        ? Image.file(
            File(localPath),
            width: w,
            height: h,
            fit: BoxFit.cover,
            // 按显示尺寸解码，避免原图吃内存
            cacheWidth: (w * 3).round(),
            errorBuilder: (_, __, ___) =>
                placeholderIcon(Icons.broken_image_outlined, '图片无法显示'),
          )
        : Image.network(
            media!.displayUrl,
            width: w,
            height: h,
            fit: BoxFit.cover,
            cacheWidth: (w * 3).round(),
            // B 站图床对部分资源要求 Referer；带上更稳
            headers: const {'Referer': 'https://message.bilibili.com/'},
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return placeholderIcon(Icons.image_outlined, null);
            },
            errorBuilder: (_, __, ___) =>
                placeholderIcon(Icons.broken_image_outlined, '图片加载失败'),
          );

    return GestureDetector(
      onTap: media != null && media.url.isNotEmpty
          ? () => showImImageViewer(
                context,
                url: media.url,
                animatedUrl: media.animatedUrl,
                localPath: localPath,
                title: isEmote ? '表情' : '图片',
              )
          : null,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(borderRadius: radius, child: image),
          if (uploading)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: radius,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: uploadProgress,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          if (message.sendState == ImSendState.failed)
            Positioned(
              right: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.error_rounded, size: 14, color: c.red),
              ),
            ),
        ],
      ),
    );
  }
}

/// 视频消息气泡：封面 + 播放角标。
///
/// 点击**不内嵌播放**：本项目私信没有验证过视频消息的播放地址可用性，
/// 因此如实提示去原平台查看，而不是做一个打不开的播放器。
class _VideoBubble extends StatelessWidget {
  const _VideoBubble({required this.message, required this.mine});

  final ImMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final media = message.media;
    if (media == null || media.url.isEmpty) {
      return Container(
        width: 200,
        height: 120,
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(AppleRadius.md),
        ),
        alignment: Alignment.center,
        child: Text(
          '视频消息',
          style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
        ),
      );
    }

    return GestureDetector(
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('私信视频暂不支持应用内播放，请在 B 站客户端查看。'),
          duration: Duration(seconds: 3),
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppleRadius.md),
            child: Image.network(
              media.url,
              width: 200,
              height: 120,
              fit: BoxFit.cover,
              cacheWidth: 600,
              headers: const {'Referer': 'https://message.bilibili.com/'},
              errorBuilder: (_, __, ___) => Container(
                width: 200,
                height: 120,
                color: c.fill,
                alignment: Alignment.center,
                child: Icon(Icons.videocam_off_outlined,
                    size: 20, color: c.tertiaryLabel),
              ),
            ),
          ),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow_rounded,
                size: 22, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// 居中的浅色提示（撤回 / 系统消息）。
class _CenteredNotice extends StatelessWidget {
  const _CenteredNotice({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppleType.caption1.copyWith(color: color),
        ),
      ),
    );
  }
}
