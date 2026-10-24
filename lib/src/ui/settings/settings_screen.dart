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
import '../../core/app_settings.dart';
import '../../core/credential_vault.dart';
import '../../core/video_progress_store.dart';
import '../../core/video_service.dart';
import '../../core/qr_login.dart';
import '../../design/apple_tokens.dart';
import '../../design/apple_theme.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';
import '../mobile/qr_login_page.dart';
import 'cookie_sheet.dart';
import 'sms_login_sheet.dart';

/// 设置页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.service,
    required this.registry,
    required this.vault,
    required this.progressStore,
    this.settings,
    this.onSessionChanged,
  });

  final VideoService service;
  final PlatformRegistry registry;
  final CredentialVault vault;
  final VideoProgressStore progressStore;

  /// 应用设置（主题 / 连播 / 倍速）。为 null 时不渲染「外观与播放」分组。
  final AppSettings? settings;
  final VoidCallback? onSessionChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// 应用内登录方式。
enum _LoginMethod { qr, sms }

class _SettingsScreenState extends State<SettingsScreen> {
  /// 应用版本号（与 `pubspec.yaml` 的 `version:` 保持一致）。
  ///
  /// # 为什么是常量而不是运行时读取
  ///
  /// 运行时读真实 versionName 需要 `package_info_plus` 依赖。这里用一个
  /// 常量 + 测试守护（`settings_version_test` 断言它与 pubspec 一致），
  /// 避免为一个字符串引入插件。
  ///
  /// 之前这个值是硬编码的 `'1.0.0'`，而实际发布 0.9.0——
  /// 用户报问题时说的版本号是错的，排查方向直接被带偏。
  static const String _appVersion = '0.11.0';

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
                    if (widget.settings != null) ...[
                      _buildAppearance(c, widget.settings!),
                      const SizedBox(height: AppleSpace.lg),
                    ],
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

  /// 连接账号。
  ///
  /// # 为什么先问「扫码还是短信」（实测 2026-10-23）
  ///
  /// 抖音的扫码登录被 4031 挡住（设备自证链路的死锁，见
  /// `web_signer.sendSmsCode` 的说明），而短信登录可用。
  ///
  /// 但扫码不是"已废弃"——它依赖平台策略，可能某天恢复。
  /// 所以不硬编码走哪条，而是**两个都给**，让用户选。
  /// 只支持扫码的平台不弹选择，直接进扫码页。
  Future<void> _connect(PlatformAdapter adapter) async {
    final qrCapable = adapter is QrLoginCapable ? adapter : null;
    final smsCapable = adapter is SmsLoginCapable ? adapter : null;

    if (qrCapable == null && smsCapable == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${adapter.displayName} 不支持应用内登录，请用导入。')),
        );
      }
      return;
    }

    // 只有一条路时不弹选择
    final method = (qrCapable != null && smsCapable != null)
        ? await _pickLoginMethod(adapter.displayName)
        : (smsCapable != null ? _LoginMethod.sms : _LoginMethod.qr);
    if (method == null || !mounted) return;

    final ok = method == _LoginMethod.sms
        ? await _connectViaSms(adapter, smsCapable as SmsLoginCapable)
        : await _connectViaQr(adapter, qrCapable as QrLoginCapable);

    if (ok == true) {
      await _loadSessions();
      widget.onSessionChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已连接 ${adapter.displayName}')),
        );
      }
    }
  }

  /// 选择登录方式。
  Future<_LoginMethod?> _pickLoginMethod(String platformName) {
    return showModalBottomSheet<_LoginMethod>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final c = AppleColors.of(ctx);
        return Container(
          margin: const EdgeInsets.all(AppleSpace.md),
          decoration: BoxDecoration(
            color: c.background,
            borderRadius: BorderRadius.circular(AppleRadius.lg),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppleSpace.lg),
                  child: Text(
                    '${platformName} · 选择登录方式',
                    style: AppleType.headline.copyWith(color: c.label),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.sms_outlined, color: c.blue),
                  title: const Text('短信验证码'),
                  subtitle: const Text('输入手机号接收验证码'),
                  onTap: () => Navigator.pop(ctx, _LoginMethod.sms),
                ),
                ListTile(
                  leading: Icon(Icons.qr_code_rounded, color: c.blue),
                  title: const Text('扫码登录'),
                  subtitle: const Text('用手机 App 扫描二维码'),
                  onTap: () => Navigator.pop(ctx, _LoginMethod.qr),
                ),
                const SizedBox(height: AppleSpace.sm),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 短信登录。
  Future<bool?> _connectViaSms(
    PlatformAdapter adapter,
    SmsLoginCapable capability,
  ) async {
    PlatformSession? pending;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Theme(
        data: AppleTheme.light(),
        child: SmsLoginSheet(
          platformName: adapter.displayName,
          capability: capability,
          onSucceeded: (r) {
            // Cookie 由适配器在成功时快照带回
            pending = PlatformSession(
              platformId: adapter.id,
              displayName: r.displayName?.isNotEmpty == true
                  ? r.displayName!
                  : '${adapter.displayName}用户',
              userId: r.userId ?? '',
              cookies: r.cookies,
              loggedInAt: DateTime.now().toUtc().toIso8601String(),
            );
          },
        ),
      ),
    );

    if (ok != true || pending == null) return false;
    await widget.vault.save(pending!);
    return true;
  }

  /// 扫码登录（原有流程）。
  Future<bool?> _connectViaQr(
    PlatformAdapter adapter,
    QrLoginCapable login,
  ) async {
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => QrLoginPage(
          adapter: login,
          vault: widget.vault,
          platformName: adapter.displayName,
        ),
      ),
    );
    return result != null;
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

  // ── 外观与播放偏好 ──────────────────────────────────────────

  Widget _buildAppearance(AppleColors c, AppSettings s) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => AppleGroupedSection(
        header: '外观与播放',
        children: [
          AppleListRow(
            leadingIcon: Icons.contrast_rounded,
            leadingColor: c.gray,
            title: '深色模式',
            subtitle: '跟随系统，或强制浅色 / 深色',
            trailingText: switch (s.themeMode) {
              ThemeModeChoice.system => '跟随系统',
              ThemeModeChoice.light => '浅色',
              ThemeModeChoice.dark => '深色',
            },
            showChevron: true,
            onTap: () => _pickThemeMode(s),
          ),
          AppleListRow(
            leadingIcon: Icons.playlist_play_rounded,
            leadingColor: c.green,
            title: '短剧自动连播',
            subtitle: '看完一集自动播下一集',
            trailing: Switch(
              value: s.autoPlayNext,
              onChanged: (v) => s.autoPlayNext = v,
            ),
          ),
          AppleListRow(
            leadingIcon: Icons.speed_rounded,
            leadingColor: c.blue,
            title: '默认倍速',
            subtitle: '长按画面可临时 3 倍速',
            trailingText: '${s.playbackRate.toStringAsFixed(2)}×',
            showChevron: true,
            onTap: () => _pickPlaybackRate(s),
          ),
        ],
      ),
    );
  }

  Future<void> _pickThemeMode(AppSettings s) async {
    final picked = await showModalBottomSheet<ThemeModeChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ChoiceSheet<ThemeModeChoice>(
        title: '深色模式',
        selected: s.themeMode,
        options: const [
          (ThemeModeChoice.system, '跟随系统'),
          (ThemeModeChoice.light, '浅色'),
          (ThemeModeChoice.dark, '深色'),
        ],
      ),
    );
    if (picked != null) s.themeMode = picked;
  }

  Future<void> _pickPlaybackRate(AppSettings s) async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ChoiceSheet<double>(
        title: '默认倍速',
        selected: s.playbackRate,
        options: const [
          (0.5, '0.5×'),
          (0.75, '0.75×'),
          (1.0, '1.0×（原速）'),
          (1.25, '1.25×'),
          (1.5, '1.5×'),
          (2.0, '2.0×'),
          (3.0, '3.0×'),
        ],
      ),
    );
    if (picked != null) s.playbackRate = picked;
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
          // 版本号从构建信息读，不硬编码。
          //
          // 之前这里写死 '1.0.0'，而实际发布的是 0.9.0 —— 设置页显示的
          // 版本和 APK 的真实 versionName 对不上，用户报问题时给了错版本。
          trailingText: _appVersion,
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

/// 通用单选底部面板。
///
/// 用于「深色模式」「默认倍速」这类 2–7 个选项的偏好，
/// 避免为每个开关各写一份 UI。
class _ChoiceSheet<T> extends StatelessWidget {
  const _ChoiceSheet({
    required this.title,
    required this.options,
    this.selected,
  });

  final String title;
  final List<(T, String)> options;
  final T? selected;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Container(
      margin: const EdgeInsets.all(AppleSpace.md),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(AppleRadius.lg),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppleSpace.lg),
              child: Text(
                title,
                style: AppleType.headline.copyWith(color: c.label),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (value, label) in options)
                    ListTile(
                      title: Text(label),
                      trailing: selected == value
                          ? Icon(Icons.check_rounded, color: c.blue)
                          : null,
                      onTap: () => Navigator.pop(context, value),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppleSpace.sm),
          ],
        ),
      ),
    );
  }
}
