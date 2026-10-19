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
///  - 消息类型：文本正常显示；图片/系统卡片/未知类型显示占位说明，
///    不让整页崩掉。
///
/// # 为什么用 reverse: true
///
/// 聊天场景默认停在最新消息。`reverse: true` 让"列表顶部"对应
/// 视觉底部，新消息插入时不用手动滚动到底，也避免了
/// "先渲染再跳转"造成的闪动。历史消息在视觉上方，符合直觉。
library;

import 'package:flutter/material.dart';

import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/im.dart';
import 'im_store.dart';

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
  bool _sending = false;

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
    if (mounted) setState(() {});
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failed.localError ?? '发送失败，请重试'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

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
          onRetry: m.sendState == ImSendState.failed
              ? () => widget.store.resend(m)
              : null,
        );
      },
    );
  }

  Widget _composer(AppleColors c) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppleSpace.md,
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
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
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
}

/// 一条消息气泡。
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.message,
    required this.mine,
    this.onRetry,
  });

  final ImMessage message;
  final bool mine;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final failed = message.sendState == ImSendState.failed;
    final sending = message.sendState == ImSendState.sending;

    // 消息类型降级：没有可读文本时显示占位，不让整页崩
    final body = message.text ?? _placeholderFor(message);

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
          Flexible(
            child: Container(
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
                  fontStyle: message.text == null ? FontStyle.italic : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 没有可读文本时的占位说明。
  ///
  /// 实测已知类型：2=图片、10=系统卡片（有文本）、未知类型。
  /// 图片暂不渲染（没验证图片域名是否需要 Referer），如实说明。
  static String _placeholderFor(ImMessage m) => switch (m.type) {
        ImMessageType.image => '[图片消息，暂不支持显示]',
        ImMessageType.systemCard => '[系统消息]',
        ImMessageType.text => '[空消息]',
        ImMessageType.unknown => '[暂不支持的消息类型 ${m.msgType}]',
      };
}
