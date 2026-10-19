/// 「我的」页：账号、内容入口、继续观看、设置次级入口。
///
/// # 为什么它在一级导航里
///
/// 短视频产品的通用结构是「推荐 / 发现 / 直播 / 我的」。
/// 之前本项目把「设置」直接放在一级导航，导致：
///  - 个人信息、观看历史、收藏夹这些**内容型**入口无处安放
///    （只挤在设置页的分组列表里，用户不会去设置里找自己的收藏）
///  - 一级导航被低频功能占用
///
/// 现在设置降为「我的」页里的次级入口，
/// 内容型入口（收藏夹 / 稍后再看 / 历史）升到首屏。
///
/// # 数据来源（全部真实）
///
///  - 账号卡片：[CredentialVault] 里的真实会话（昵称/UID/头像来自平台接口）。
///    **不显示任何 Cookie 值**，只显示平台侧的展示信息。
///  - 收藏夹数量与列表：平台真实接口（B站 `created/list-all`）。
///  - 继续观看：[VideoProgressStore] 的本机真实播放进度。
///    刻意标注"不是平台观看记录接口"，避免用户以为跨设备同步。
///  - 未登录时对应入口显示"未登录"并给出登录动作，
///    不用假数据填空，也不显示成"空的但可用"。
library;

import 'package:flutter/material.dart';

import '../../adapters/platform_registry.dart';
import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_progress_store.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/unified_video.dart';
import '../shell/app_shell.dart' show tabBarInsets;
import 'favorites_screen.dart';
import 'history_screen.dart';
import 'watch_later_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.service,
    required this.registry,
    required this.vault,
    required this.progressStore,
    this.sessionRevision = 0,
    this.onOpenVideo,
    this.onOpenSettings,
    this.onOpenLogin,
    this.onResumeVideo,
    this.onOpenMessages,
    this.unreadCount = 0,
  });

  final VideoService service;
  final PlatformRegistry registry;
  final CredentialVault vault;
  final VideoProgressStore progressStore;

  /// 登录态版本号。
  ///
  /// 本页在 IndexedStack 里**不会随切页重建**，所以从设置页导入
  /// Cookie 或退出登录后返回，账号卡片会停在旧状态
  /// （显示"未登录"，或显示上一个账号的收藏夹数量）。
  /// 外层每改变一次凭证就把这个值 +1，本页在 [didUpdateWidget]
  /// 里检测到变化就重新拉取会话与收藏夹。
  final int sessionRevision;

  /// 打开视频（详情页）。
  final void Function(UnifiedVideo video)? onOpenVideo;

  /// 打开设置页（次级入口）。
  final VoidCallback? onOpenSettings;

  /// 打开登录（Cookie 导入 / 扫码）。
  final VoidCallback? onOpenLogin;

  /// 从"继续观看"打开：带上续播位置。
  final void Function(UnifiedVideo video, Duration resumeAt)? onResumeVideo;

  /// 打开消息页（底部标签之外的第二个入口）。
  ///
  /// 为什么两处都有：底部标签是"主动去看消息"，「我的」页这一行是
  /// "账号相关入口"，两者习惯都成立。共用同一个 [ImStore]，
  /// 所以未读数不会两边不一致。
  final VoidCallback? onOpenMessages;

  /// 未读私信总数（由外层从 [ImStore] 传入，保持单一真相）。
  final int unreadCount;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<PlatformSession> _sessions = const [];
  List<WatchProgress> _resumable = const [];
  bool _loading = true;

  /// 各平台真实收藏夹数量（接口统计，用于入口副标题）。
  final Map<String, int> _folderCounts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProfileScreen old) {
    super.didUpdateWidget(old);
    // 凭证变了就重新拉：IndexedStack 保住本页状态，
    // 不主动刷新就会停在"未登录"或上一个账号。
    if (old.sessionRevision != widget.sessionRevision) _load();
  }

  /// 重新读取登录态与数据。
  ///
  /// 从设置页导入 Cookie 后回到本页要能看到新账号，
  /// 所以 [didChangeDependencies] 之外还允许外部调用（见 [refreshFromOuter]）。
  Future<void> _load() async {
    final sessions = <PlatformSession>[];
    for (final adapter in widget.registry.adapters) {
      try {
        final s = await widget.vault
            .load(adapter.id)
            .timeout(const Duration(seconds: 5));
        if (s != null) sessions.add(s);
      } catch (_) {
        // 读不到就是未登录，不报错打断页面
      }
    }

    final resumable = await widget.progressStore.resumable();

    // 收藏夹计数只在已登录、且平台确实支持收藏夹接口时拉一次；
    // 失败不影响页面主体（计数留空而不是显示 0）。
    for (final s in sessions) {
      if (!widget.service.capabilitiesFor(s.platformId).favoriteFolders) {
        continue;
      }
      try {
        final folders = await widget.service.fetchFavoriteFolders(
          s.platformId,
          session: s,
        );
        _folderCounts[s.platformId] = folders.length;
      } on FusionException {
        _folderCounts.remove(s.platformId);
      } catch (_) {
        _folderCounts.remove(s.platformId);
      }
    }

    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _resumable = resumable;
      _loading = false;
    });
  }

  /// 外部（设置页 Cookie 变化后）触发的刷新。
  void refreshFromOuter() => _load();

  bool get _hasAnySession => _sessions.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.only(bottom: tabBarInsets(context).bottom),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpace.lg,
                AppleSpace.md,
                AppleSpace.lg,
                AppleSpace.sm,
              ),
              child: Text(
                '我的',
                style: AppleType.largeTitle.copyWith(color: c.label),
              ),
            ),

            _AccountCard(
              sessions: _sessions,
              loading: _loading,
              folderCounts: _folderCounts,
              onLogin: widget.onOpenLogin,
            ),

            const SizedBox(height: AppleSpace.lg),

            // ── 内容入口 ──────────────────────────────────────
            AppleGroupedSection(
              header: '内容',
              children: [
                AppleListRow(
                  leadingIcon: Icons.star_rounded,
                  leadingColor: c.orange,
                  title: '我的收藏夹',
                  subtitle: _folderSubtitle(),
                  trailingText: _folderCounts.isEmpty
                      ? null
                      : _folderCounts.values.fold<int>(0, (a, b) => a + b)
                          .toString(),
                  showChevron: _hasAnySession,
                  onTap: _hasAnySession ? _openFavorites : _requireLogin,
                ),
                AppleListRow(
                  leadingIcon: Icons.schedule_rounded,
                  leadingColor: c.blue,
                  title: '稍后再看',
                  subtitle: _watchLaterSubtitle(),
                  showChevron: _watchLaterUsable,
                  onTap: _watchLaterUsable ? _openWatchLater : _requireLogin,
                ),
                AppleListRow(
                  leadingIcon: Icons.history_rounded,
                  leadingColor: c.gray,
                  title: '观看历史',
                  subtitle: _resumable.isEmpty
                      ? '还没有观看记录'
                      : '${_resumable.length} 条本机记录',
                  showChevron: true,
                  onTap: _openHistory,
                ),
                // 消息入口：只在平台确实支持私信时出现（当前仅 B 站），
                // 不支持时整行不渲染 —— 不放点了没内容的死按钮。
                if (widget.service.imPlatformIds.isNotEmpty)
                  AppleListRow(
                    leadingIcon: Icons.forum_rounded,
                    leadingColor: c.green,
                    title: '私信',
                    subtitle: _hasAnySession
                        ? (widget.unreadCount > 0
                            ? '${widget.unreadCount} 条未读'
                            : '查看会话')
                        : '登录后查看私信',
                    trailingText: widget.unreadCount > 0
                        ? (widget.unreadCount > 99
                            ? '99+'
                            : '${widget.unreadCount}')
                        : null,
                    showChevron: true,
                    onTap: widget.onOpenMessages ?? _requireLogin,
                  ),
              ],
            ),

            // ── 继续观看（真实进度）─────────────────────────────
            if (_resumable.isNotEmpty)
              AppleGroupedSection(
                header: '继续观看',
                footer: '进度来自本设备上实际播放到的位置，'
                    '不是平台的观看记录接口，因此不跨设备同步。',
                children: [
                  for (final p in _resumable.take(5))
                    _ProgressRow(
                      progress: p,
                      onTap: () => _openProgress(p),
                    ),
                  if (_resumable.length > 5)
                    AppleListRow(
                      title: '查看全部历史',
                      trailingText: '${_resumable.length} 条',
                      showChevron: true,
                      onTap: _openHistory,
                    ),
                ],
              ),

            // ── 低频功能（次级入口）─────────────────────────────
            AppleGroupedSection(
              header: '应用',
              children: [
                AppleListRow(
                  leadingIcon: Icons.settings_rounded,
                  leadingColor: c.gray,
                  title: '设置',
                  subtitle: '账号管理、Cookie 导入、播放与隐私',
                  showChevron: true,
                  onTap: widget.onOpenSettings,
                ),
              ],
            ),

            const SizedBox(height: AppleSpace.xl),
          ],
        ),
      ),
    );
  }

  // ── 入口可用性判定 ──────────────────────────────────────────

  /// 该平台是否真实支持"稍后再看"接口（由适配器声明，UI 不做平台判断）。
  bool get _watchLaterUsable {
    if (!_hasAnySession) return false;
    return _sessions.any(
      (s) => widget.service.capabilitiesFor(s.platformId).watchLater,
    );
  }

  String _folderSubtitle() {
    if (!_hasAnySession) return '登录后查看并管理收藏夹';
    if (_loading && _folderCounts.isEmpty) return '收藏夹数量加载中';
    if (_folderCounts.isEmpty) return '当前平台未提供收藏夹接口';
    final parts = _folderCounts.entries
        .map((e) => '${_platformLabel(e.key)} ${e.value} 个')
        .join(' · ');
    return parts;
  }

  String _watchLaterSubtitle() {
    if (!_hasAnySession) return '登录后使用';
    if (!_watchLaterUsable) return '当前登录的平台不支持';
    return '来自 B 站真实稍后再看列表';
  }

  String _platformLabel(String id) => switch (id) {
        'bilibili' => 'B 站',
        'douyin' => '抖音',
        _ => id,
      };

  void _requireLogin() {
    if (widget.onOpenLogin != null) {
      widget.onOpenLogin!();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('请先登录平台账号。'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // ── 导航 ────────────────────────────────────────────────────

  void _openFavorites() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FavoritesScreen(
          service: widget.service,
          sessions: _sessions,
          onOpenVideo: (v) {
            Navigator.pop(context);
            widget.onOpenVideo?.call(v);
          },
        ),
      ),
    );
  }

  void _openWatchLater() {
    final session = _sessions.firstWhere(
      (s) => widget.service.capabilitiesFor(s.platformId).watchLater,
      orElse: () => _sessions.first,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchLaterScreen(
          service: widget.service,
          session: session,
          onOpenVideo: (v) {
            Navigator.pop(context);
            widget.onOpenVideo?.call(v);
          },
        ),
      ),
    );
  }

  Future<void> _openHistory() async {
    final picked = await Navigator.of(context).push<WatchProgress>(
      MaterialPageRoute<WatchProgress>(
        builder: (_) => HistoryScreen(progressStore: widget.progressStore),
      ),
    );
    if (picked != null && mounted) await _openProgress(picked);
  }

  /// 历史条目只有 videoId，需要回库里取完整实体再续播。
  Future<void> _openProgress(WatchProgress p) async {
    final videos = await widget.service.listVideos();
    final video = videos.where((v) => v.id == p.videoId).firstOrNull;
    if (!mounted) return;
    if (video == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('该视频已不在本机记录中，无法续播。'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final resume = widget.onResumeVideo;
    if (resume != null) {
      resume(video, p.position);
      return;
    }
    widget.onOpenVideo?.call(video);
  }
}

/// 账号卡片：真实会话列表（不含任何 Cookie 值）。
class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.sessions,
    required this.loading,
    required this.folderCounts,
    required this.onLogin,
  });

  final List<PlatformSession> sessions;
  final bool loading;
  final Map<String, int> folderCounts;
  final VoidCallback? onLogin;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppleSpace.pageInset),
      padding: const EdgeInsets.all(AppleSpace.lg),
      decoration: BoxDecoration(
        color: c.secondaryGroupedBackground,
        borderRadius: BorderRadius.circular(AppleRadius.md),
      ),
      child: sessions.isEmpty
          ? _loggedOut(c)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < sessions.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppleSpace.md),
                  _row(c, sessions[i]),
                ],
              ],
            ),
    );
  }

  Widget _loggedOut(AppleColors c) => Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: c.fill,
            child: Icon(Icons.person_rounded, color: c.tertiaryLabel, size: 22),
          ),
          const SizedBox(width: AppleSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '未登录',
                  style: AppleType.headline.copyWith(color: c.label),
                ),
                const SizedBox(height: 2),
                Text(
                  '登录后才能同步点赞、投币与收藏夹状态。',
                  style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
          ),
          if (onLogin != null)
            TextButton(onPressed: onLogin, child: const Text('登录')),
        ],
      );

  Widget _row(AppleColors c, PlatformSession s) => Row(
        children: [
          _Avatar(session: s, colors: c),
          const SizedBox(width: AppleSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppleType.headline.copyWith(color: c.label),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle(s),
                  style: AppleType.caption1.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
          ),
          if (onLogin != null)
            TextButton(
              onPressed: onLogin,
              child: Text(s.platformId == sessions.first.platformId
                  ? '管理'
                  : '连接'),
            ),
        ],
      );

  String _name(PlatformSession s) {
    final n = s.username;
    if (n != null && n.isNotEmpty) return n;
    if (s.displayName.isNotEmpty) return s.displayName;
    return '已登录';
  }

  String _subtitle(PlatformSession s) {
    final folders = folderCounts[s.platformId];
    final parts = <String>[
      if (s.userId.isNotEmpty) 'UID ${s.userId}',
      if (folders != null) '$folders 个收藏夹',
      if (folders == null && loading) '收藏夹加载中',
    ];
    return parts.isEmpty ? '已连接' : parts.join(' · ');
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.session, required this.colors});

  final PlatformSession session;
  final AppleColors colors;

  @override
  Widget build(BuildContext context) {
    final url = session.avatarUrl;
    if (url == null || url.isEmpty) {
      return CircleAvatar(
        radius: 22,
        backgroundColor: colors.fill,
        child: Text(
          _initial(),
          style: AppleType.headline.copyWith(color: colors.secondaryLabel),
        ),
      );
    }
    return ClipOval(
      child: Image.network(
        url,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        cacheWidth: 88,
        errorBuilder: (_, _, _) => ColoredBox(
          color: colors.fill,
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.person_rounded, size: 22),
          ),
        ),
      ),
    );
  }

  String _initial() {
    // username 可能为 null，displayName 一定非空，所以 ?? 之后仍是非空串
    final n = (session.username?.isNotEmpty ?? false)
        ? session.username!
        : session.displayName;
    if (n.isEmpty) return '?';
    return n.characters.first;
  }
}

/// 继续观看条目。
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.progress, required this.onTap});

  final WatchProgress progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final remainSec =
        (progress.duration - progress.position).inSeconds.clamp(0, 86400);

    return AppleListRow(
      title: _friendlyTitle(progress.videoId),
      subtitle: '看到 ${_fmt(progress.position)} · 还剩 ${_fmtShort(remainSec)}',
      trailing: Icon(
        Icons.play_circle_outline_rounded,
        size: 20,
        color: c.secondaryLabel,
      ),
      onTap: onTap,
    );
  }

  /// 历史条目的 videoId 形如 `bilibili:BV1xx411c7mD`。
  static String _friendlyTitle(String videoId) {
    final i = videoId.indexOf(':');
    if (i < 0) return videoId;
    final platform = videoId.substring(0, i);
    final id = videoId.substring(i + 1);
    final label = switch (platform) {
      'bilibili' => 'B 站',
      'douyin' => '抖音',
      _ => platform,
    };
    return '$label · $id';
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String _fmtShort(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    if (m < 60) return '$m 分钟';
    return '${(m / 60).toStringAsFixed(1)} 小时';
  }
}
