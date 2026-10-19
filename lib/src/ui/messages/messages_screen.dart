/// 私信会话列表页。
///
/// # 数据来源
///
/// 全部来自 [ImStore]（真实接口）：
///  - 会话列表：`session_svr/get_sessions`
///  - 昵称头像：`x/im/user_infos`
///  - 未读：`session_svr/single_unread`
///
/// # 刻意不做的事
///
///  - **不伪造最后一条消息摘要**。实测 `last_msg` 里只有 msg_type/timestamp，
///    没有可直接展示的正文。拿不到就显示"有新消息"，不编内容。
///  - **不在进页面时把所有会话标已读**。已读由聊天页在拿到最新消息后
///    对**单个会话**调用。
///  - **不做定时假消息**。刷新是用户下拉或页面重新可见时触发，
///    并有 5 秒节流（实测连发会触发风控）。
library;

import 'package:flutter/material.dart';

import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/im.dart';
import 'chat_screen.dart';
import 'im_store.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({
    super.key,
    required this.store,
    this.onOpenLogin,
  });

  final ImStore store;

  /// 未登录时的登录入口（复用「我的」页里的设置/登录流程）。
  final VoidCallback? onOpenLogin;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    widget.store.addListener(_onStoreChanged);
    _boot();
  }

  Future<void> _boot() async {
    final loggedIn = await widget.store.init();
    if (!mounted) return;
    setState(() => _initialized = true);
    if (loggedIn) await widget.store.loadSessions(refresh: true);
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_onStoreChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// 回到前台时校准一次（有节流），不是高频轮询。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.store.isLoggedIn) {
      widget.store.loadSessions(refresh: true);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      widget.store.loadMoreSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpace.lg,
                AppleSpace.md,
                AppleSpace.lg,
                AppleSpace.sm,
              ),
              child: Row(
                children: [
                  Text('消息', style: AppleType.largeTitle.copyWith(color: c.label)),
                  const Spacer(),
                  if (widget.store.isLoggedIn)
                    IconButton(
                      onPressed: () => widget.store.loadSessions(refresh: true),
                      icon: Icon(Icons.refresh_rounded,
                          color: c.secondaryLabel, size: 20),
                      tooltip: '刷新',
                    ),
                ],
              ),
            ),
            Expanded(child: _body(c)),
          ],
        ),
      ),
    );
  }

  Widget _body(AppleColors c) {
    final store = widget.store;

    if (!_initialized) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (!store.isLoggedIn) {
      return AppleEmptyState(
        icon: Icons.forum_outlined,
        title: '未登录',
        message: '私信需要登录 B 站账号。登录后这里会显示你的真实会话。',
        action: widget.onOpenLogin == null
            ? null
            : FilledButton(
                onPressed: widget.onOpenLogin,
                child: const Text('去登录'),
              ),
      );
    }

    if (store.sessionsLoading && store.sessions.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (store.sessionsError != null && store.sessions.isEmpty) {
      return AppleErrorState(
        title: store.sessionsError!.presentation.title,
        message: store.sessionsError!.userMessage,
        onRetry: () => store.loadSessions(refresh: true),
      );
    }

    if (store.sessionsLoadedOnce && store.sessions.isEmpty) {
      return const AppleEmptyState(
        icon: Icons.forum_outlined,
        title: '还没有私信',
        message: '在 B 站上与其他人开始对话后，会话会出现在这里。',
      );
    }

    return RefreshIndicator(
      onRefresh: () => store.loadSessions(refresh: true),
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: AppleSpace.xxxl),
        itemCount: store.sessions.length + (store.sessionsHasMore ? 1 : 0),
        separatorBuilder: (_, _) => const AppleDivider(indent: 68),
        itemBuilder: (context, index) {
          if (index >= store.sessions.length) {
            return Padding(
              padding: const EdgeInsets.all(AppleSpace.lg),
              child: Center(
                child: store.sessionsLoadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: store.loadMoreSessions,
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }
          final s = store.sessions[index];
          return _SessionRow(
            key: ValueKey<int>(s.talkerId),
            session: s,
            title: store.titleOf(s),
            avatarUrl: store.avatarOf(s),
            onTap: () => _openChat(s),
          );
        },
      ),
    );
  }

  Future<void> _openChat(ImSession s) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          store: widget.store,
          talkerId: s.talkerId,
          title: widget.store.titleOf(s),
        ),
      ),
    );
    // 返回后刷新一次列表（未读/最后一条可能变了），有节流
    if (mounted) widget.store.loadSessions(refresh: true);
  }
}

/// 会话行。
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    super.key,
    required this.session,
    required this.title,
    required this.avatarUrl,
    required this.onTap,
  });

  final ImSession session;
  final String title;
  final String? avatarUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.lg,
          vertical: AppleSpace.md,
        ),
        child: Row(
          children: [
            _Avatar(url: avatarUrl, name: title, colors: c),
            const SizedBox(width: AppleSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (session.isTop)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.push_pin_rounded,
                              size: 12, color: c.tertiaryLabel),
                        ),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppleType.bodyEmphasized.copyWith(color: c.label),
                        ),
                      ),
                      if (session.sessionTime != null)
                        Text(
                          _relTime(session.sessionTime!),
                          style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          // 实测列表不下发正文：能显示就显示，否则如实说"有新消息"
                          session.lastMsgText ??
                              (session.lastMsgType != null ? '有新消息' : ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                        ),
                      ),
                      if (session.unreadCount > 0)
                        Container(
                          margin: const EdgeInsets.only(left: AppleSpace.sm),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.red,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            session.unreadCount > 99 ? '99+' : '${session.unreadCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _relTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${t.month}/${t.day}';
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.name, required this.colors});

  final String? url;
  final String name;
  final AppleColors colors;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name.characters.first : '?';
    if (url == null || url!.isEmpty) {
      return CircleAvatar(
        radius: 22,
        backgroundColor: colors.fill,
        child: Text(initial,
            style: AppleType.headline.copyWith(color: colors.secondaryLabel)),
      );
    }
    return ClipOval(
      child: Image.network(
        url!,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        cacheWidth: 88,
        headers: const {'Referer': 'https://www.bilibili.com/'},
        errorBuilder: (_, _, _) => CircleAvatar(
          radius: 22,
          backgroundColor: colors.fill,
          child: Text(initial,
              style: AppleType.headline.copyWith(color: colors.secondaryLabel)),
        ),
      ),
    );
  }
}
