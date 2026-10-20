/// 设置页：账号与平台管理（Apple 风格分组列表）。
///
/// 内容：
///  - 已连接平台账号（登录状态、重新授权、解绑）
///  - 内容来源管理（哪些平台可提供内容）
///  - 播放设置
///  - 存储与隐私
///  - 关于与能力说明
///
/// 安全约束：凭证永不进入 UI。这里只展示脱敏的账号名与登录时间。
library;

import 'package:flutter/material.dart';

import '../../adapters/platform_adapter.dart';
import '../../adapters/platform_registry.dart';
import '../../core/credential_vault.dart';
import '../../core/video_progress_store.dart';
import '../../core/video_service.dart';
import '../../core/qr_login.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';
import '../mobile/qr_login_page.dart';
import 'cookie_sheet.dart';

/// 设置页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.service,
    required this.registry,
    required this.vault,
    required this.progressStore,
    this.onSessionChanged,
  });

  final VideoService service;
  final PlatformRegistry registry;
  final CredentialVault vault;
  final VideoProgressStore progressStore;
  final VoidCallback? onSessionChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Map<String, PlatformSession> _sessions = {};
  bool _loadingSessions = true;

  /// 已展开技术详情的平台 ID。
  ///
  /// 平台能力说明是长文本，默认收起，避免设置页被技术细节塞满。
  final Set<String> _expandedPlatforms = {};

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() => _loadingSessions = true);
    final loaded = <String, PlatformSession>{};
    for (final adapter in widget.registry.adapters) {
      try {
        final s = await widget.vault
            .load(adapter.id)
            .timeout(const Duration(seconds: 5));
        if (s != null) loaded[adapter.id] = s;
      } catch (_) {
        // 读取失败按未登录处理
      }
    }
    if (!mounted) return;
    setState(() {
      _sessions
        ..clear()
        ..addAll(loaded);
      _loadingSessions = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: AppleLargeTitleHeader(
                title: '设置',
                subtitle: '账号、播放与隐私',
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom +
                      AppleSize.tabBar +
                      AppleSpace.xxl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAccounts(c),
                    const SizedBox(height: AppleSpace.lg),
                    _buildPlatforms(c),
                    const SizedBox(height: AppleSpace.lg),
                    _buildPlayback(c),
                    const SizedBox(height: AppleSpace.lg),
                    _buildStorage(c),
                    const SizedBox(height: AppleSpace.lg),
                    _buildAbout(c),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 账号 ────────────────────────────────────────────────────

  Widget _buildAccounts(AppleColors c) {
    final loginCapable = widget.registry.adapters
        .whereType<QrLoginCapable>()
        .toList();

    // 只支持 Cookie 导入、没有应用内扫码的平台。
    // 这类平台如实告知用户走导入路径，不摆一个点了必然失败的入口。
    final importOnly = widget.registry.adapters
        .where((a) => a.id != 'mock')
        .where((a) => a is! QrLoginCapable)
        .toList();

    if (loginCapable.isEmpty && importOnly.isEmpty) {
      return AppleGroupedSection(
        header: '账号',
        children: [
          Padding(
            padding: const EdgeInsets.all(AppleSpace.lg),
            child: Text(
              '当前接入的平台都不支持应用内登录。',
              style: AppleType.footnote.copyWith(color: c.secondaryLabel),
            ),
          ),
        ],
      );
    }

    return AppleGroupedSection(
      header: '账号',
      footer: _sessions.isEmpty
          ? '登录后可访问你自己账号可见的个性化内容。凭证加密存储在本机，不会上传到任何服务器。'
          : '凭证使用系统安全存储加密保存（${widget.vault.storageName}），不会出现在日志或界面中。',
      children: [
        for (final adapter in loginCapable)
          _buildAccountRow(c, adapter as PlatformAdapter),
        for (final adapter in importOnly)
          _buildImportOnlyRow(c, adapter),
      ],
    );
  }

  /// 仅支持 Cookie 导入的平台行。
  ///
  /// 抖音的扫码登录需要平台 `sign` 参数，该签名依赖 JS 运行时状态，
  /// 无法在纯 Dart 中复现（详见 `DouyinLoginClient` 的文档）。
  /// 因此这里不显示「连接」（那会引导用户进入必然失败的流程），
  /// 只给「导入」，并说明原因。
  Widget _buildImportOnlyRow(AppleColors c, PlatformAdapter adapter) {
    final session = _sessions[adapter.id];
    final connected = session != null;

    return AppleListRow(
      leading: Container(
        width: 29,
        height: 29,
        decoration: BoxDecoration(
          color: connected ? c.green : c.fill,
          borderRadius: BorderRadius.circular(AppleRadius.xs),
        ),
        child: Icon(
          connected ? Icons.check_rounded : Icons.person_outline_rounded,
          size: 17,
          color: connected ? Colors.white : c.secondaryLabel,
        ),
      ),
      title: adapter.displayName,
      subtitle: connected
          ? '${session.displayName} · 已连接'
          : (_loadingSessions ? '正在检查…' : '需导入 Cookie 登录'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (connected)
            AppleTextButton(
              label: '导出',
              onPressed: () => _exportCookie(adapter, session),
            )
          else
            AppleTextButton(
              label: '导入',
              onPressed: () => _importCookie(adapter),
            ),
          const SizedBox(width: AppleSpace.sm),
          if (connected)
            AppleTextButton(
              label: '解绑',
              color: c.red,
              onPressed: () => _disconnect(adapter),
            ),
        ],
      ),
      onTap: connected ? null : () => _importCookie(adapter),
    );
  }

  Widget _buildAccountRow(AppleColors c, PlatformAdapter adapter) {
    final session = _sessions[adapter.id];
    final connected = session != null;

    return AppleListRow(
      leading: Container(
        width: 29,
        height: 29,
        decoration: BoxDecoration(
          color: connected ? c.green : c.fill,
          borderRadius: BorderRadius.circular(AppleRadius.xs),
        ),
        child: Icon(
          connected ? Icons.check_rounded : Icons.person_outline_rounded,
          size: 17,
          color: connected ? Colors.white : c.secondaryLabel,
        ),
      ),
      title: adapter.displayName,
      subtitle: connected
          ? '${session.displayName} · 已连接'
          : (_loadingSessions ? '正在检查…' : '未连接'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 未连接时给"导入"，已连接时给"导出"——
          // 两个动作在语义上是互斥的，不需要同时出现。
          if (connected)
            AppleTextButton(
              label: '导出',
              onPressed: () => _exportCookie(adapter, session),
            )
          else
            AppleTextButton(
              label: '导入',
              onPressed: () => _importCookie(adapter),
            ),
          const SizedBox(width: AppleSpace.sm),
          if (connected)
            AppleTextButton(
              label: '解绑',
              color: c.red,
              onPressed: () => _disconnect(adapter),
            )
          else
            AppleTextButton(
              label: '连接',
              onPressed: () => _connect(adapter),
            ),
        ],
      ),
      // 已连接时点整行 = 重新导入（换账号或修复过期凭证），
      // 未连接时点整行 = 扫码登录。
      onTap: connected
          ? () => _importCookie(adapter, replace: true)
          : () => _connect(adapter),
    );
  }

  /// 导入 Cookie。
  ///
  /// [replace] 为 true 表示覆盖已有会话（已连接状态下点整行触发）。
  Future<void> _importCookie(
    PlatformAdapter adapter, {
    bool replace = false,
  }) async {
    if (replace) {
      final ok = await _confirm(
        '重新导入 ${adapter.displayName} Cookie？',
        '当前登录状态会被粘贴的 Cookie 覆盖。',
      );
      if (ok != true) return;
    }

    final session = await showCookieImportSheet(
      context,
      platformHint: adapter.id,
      platformLabel: adapter.displayName,
    );
    if (session == null) return;

    await widget.vault.save(session);
    await _loadSessions();
    widget.onSessionChanged?.call();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 ${adapter.displayName} Cookie')),
      );
    }
  }

  /// 导出 Cookie。
  Future<void> _exportCookie(
    PlatformAdapter adapter,
    PlatformSession session,
  ) async {
    await showCookieExportSheet(
      context,
      session: session,
      platformLabel: adapter.displayName,
    );
  }

  Future<void> _connect(PlatformAdapter adapter) async {
    final login = adapter as QrLoginCapable;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => QrLoginPage(
          adapter: login,
          vault: widget.vault,
          platformName: adapter.displayName,
        ),
      ),
    );

    if (result != null) {
      await _loadSessions();
      widget.onSessionChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已连接 ${adapter.displayName}')),
        );
      }
    }
  }

  Future<void> _disconnect(PlatformAdapter adapter) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('解绑 ${adapter.displayName}？'),
        content: const Text('解绑后会清除本机保存的登录凭证，需要重新扫码才能再次连接。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '解绑',
              style: TextStyle(color: AppleColors.of(context).red),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await widget.vault.clear(adapter.id);
    await _loadSessions();
    widget.onSessionChanged?.call();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已解绑 ${adapter.displayName}')),
      );
    }
  }

  // ── 平台能力 ────────────────────────────────────────────────

  Widget _buildPlatforms(AppleColors c) {
    return AppleGroupedSection(
      header: '平台支持',
      footer: '标注依据实际验证结果，未验证的能力不会标注为可用。',
      children: [
        for (final adapter in widget.registry.adapters)
          if (adapter.id != 'mock') _buildPlatformRow(c, adapter),
      ],
    );
  }

  /// 平台支持行。
  ///
  /// 这里刻意只给**用户能感知的能力**（能不能在应用内播放、
  /// 能不能搜、有没有内容），不暴露内部标识、能力矩阵或
  /// 逐条技术说明——那些属于开发文档，不属于设置界面。
  /// 需要排查时展开「详情」才看到完整说明。
  Widget _buildPlatformRow(AppleColors c, PlatformAdapter adapter) {
    final caps = adapter.capabilities;
    final availableFeeds =
        adapter.feedSources.where((s) => s.available).length;

    // 面向用户的一句话总结
    final summary = <String>[
      if (caps.supportsNativePlayback) '应用内播放',
      if (adapter.supportsSearch) '搜索',
      if (availableFeeds > 0) '内容浏览',
      if (adapter.supportsLive) '直播',
    ];

    final expanded = _expandedPlatforms.contains(adapter.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpace.lg,
        AppleSpace.md,
        AppleSpace.lg,
        AppleSpace.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  adapter.displayName,
                  style: AppleType.body.copyWith(color: c.label),
                ),
              ),
              if (caps.notes.isNotEmpty)
                GestureDetector(
                  onTap: () => setState(() {
                    if (expanded) {
                      _expandedPlatforms.remove(adapter.id);
                    } else {
                      _expandedPlatforms.add(adapter.id);
                    }
                  }),
                  child: Text(
                    expanded ? '收起' : '详情',
                    style: AppleType.caption1.copyWith(color: c.blue),
                  ),
                ),
            ],
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              summary.join(' · '),
              style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ],
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(top: AppleSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final n in caps.notes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '· $n',
                        style: AppleType.caption2.copyWith(
                          color: c.secondaryLabel,
                          height: 1.45,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── 播放 ────────────────────────────────────────────────────

  Widget _buildPlayback(AppleColors c) {
    return AppleGroupedSection(
      header: '播放',
      children: [
        AppleListRow(
          leadingIcon: Icons.hd_rounded,
          leadingColor: c.orange,
          title: '播放内核',
          subtitle: '设备本地解码（libmpv），不经过网页容器',
          trailingText: '原生',
        ),
        AppleListRow(
          leadingIcon: Icons.wifi_rounded,
          leadingColor: c.blue,
          title: '移动网络下播放',
          subtitle: '当前版本不区分网络类型',
          trailingText: '始终允许',
        ),
      ],
    );
  }

  // ── 存储与隐私 ──────────────────────────────────────────────

  Widget _buildStorage(AppleColors c) {
    return AppleGroupedSection(
      header: '存储与隐私',
      footer: '所有数据仅保存在本机。应用不会上传观看记录、账号凭证或任何个人数据。',
      children: [
        AppleListRow(
          leadingIcon: Icons.lock_rounded,
          leadingColor: c.green,
          title: '凭证存储',
          subtitle: widget.vault.isEncrypted ? '系统安全存储（加密）' : '普通存储（未加密）',
          trailingText: widget.vault.isEncrypted ? '已加密' : '未加密',
        ),
        AppleListRow(
          leadingIcon: Icons.delete_outline_rounded,
          leadingColor: c.red,
          title: '清除观看记录',
          onTap: () => _clearProgress(),
        ),
        AppleListRow(
          leadingIcon: Icons.logout_rounded,
          leadingColor: c.red,
          title: '清除全部登录凭证',
          onTap: () => _clearAllSessions(),
        ),
      ],
    );
  }

  Future<void> _clearProgress() async {
    final ok = await _confirm('清除观看记录？', '所有续播进度将被删除，此操作不可撤销。');
    if (ok != true) return;
    await widget.progressStore.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('观看记录已清除')),
      );
    }
  }

  Future<void> _clearAllSessions() async {
    final ok = await _confirm('清除全部登录凭证？', '所有平台的登录状态都将失效，需要重新扫码。');
    if (ok != true) return;
    await widget.vault.clearAll();
    await _loadSessions();
    widget.onSessionChanged?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清除全部凭证')),
      );
    }
  }

  Future<bool?> _confirm(String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '确定',
              style: TextStyle(color: AppleColors.of(context).red),
            ),
          ),
        ],
      ),
    );
  }

  // ── 关于 ────────────────────────────────────────────────────

  Widget _buildAbout(AppleColors c) {
    return AppleGroupedSection(
      header: '关于',
      footer: '本应用不是视频解析工具。内容来自各平台公开接口与用户自身账号授权范围，'
          '不绕过任何访问控制，不下载受保护内容。',
      children: [
        AppleListRow(
          leadingIcon: Icons.info_outline_rounded,
          leadingColor: c.gray,
          title: '视频融合',
          subtitle: '多平台视频聚合 · Apple 风格设计',
          trailingText: '1.0.0',
        ),
        AppleListRow(
          leadingIcon: Icons.verified_user_outlined,
          leadingColor: c.blue,
          title: '内容来源',
          subtitle: '各平台公开接口 + 用户授权账号',
        ),
      ],
    );
  }
}
