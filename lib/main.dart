/// 应用入口与依赖装配。
///
/// 产品形态：**多平台视频融合应用**（移动端优先）。
///  - 推荐：全屏竖滑短视频流，滑到即播
///  - 发现：长视频浏览与跨平台搜索
///  - 媒体库：观看记录与续播
///  - 设置：多平台账号连接与能力说明
///
/// 设计语言：Apple Human Interface Guidelines
///  - 浅色为默认外壳，视频播放区域深色
///  - 语义化配色、连续圆角、克制动效
///
/// 依赖装配是唯一允许出现"新增平台"改动的地方：
/// 新增一个平台 = 在 adapters 列表加一行，其余全部自动生效。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'src/adapters/bilibili_adapter.dart';
import 'src/adapters/douyin_adapter.dart';
import 'src/adapters/hongguo_adapter.dart';
import 'src/adapters/mock_adapter.dart';
import 'src/adapters/platform_registry.dart';
import 'src/core/credential_vault.dart';
import 'src/core/cloud_progress_reporter.dart';
import 'src/core/http_client.dart';
import 'src/core/logger.dart';
import 'src/core/platform/flutter_secure_store.dart';
import 'src/core/platform/shared_preferences_store.dart';
import 'src/core/video_progress_store.dart';
import 'src/core/video_service.dart';
import 'src/core/video_store.dart';
import 'src/design/apple_theme.dart';
import 'src/models/feed.dart' as feed_models;
import 'src/models/unified_video.dart';
import 'src/ui/detail/video_detail_screen.dart';
import 'src/ui/discover/discover_screen.dart';
import 'src/ui/drama/drama_screen.dart';
import 'src/ui/feed/feed_screen.dart';
import 'src/ui/interaction/interaction_registry.dart';
import 'src/ui/live/live_screen.dart';
import 'src/ui/messages/im_store.dart';
import 'src/ui/messages/messages_screen.dart';
import 'src/ui/mobile/feed_controller.dart';
import 'src/ui/mobile/link_intake_sheet.dart';
import 'src/core/external_link.dart' show openInBrowser;
import 'src/ui/profile/profile_screen.dart';
import 'src/ui/settings/settings_screen.dart';
import 'src/ui/shell/app_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 media_kit（libmpv）播放内核。
  // 这是应用内播放的技术基础：解码在本进程内完成，
  // 不嵌入任何平台网页，不使用 WebView。
  MediaKit.ensureInitialized();

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(const VideoFusionApp());
}

class VideoFusionApp extends StatefulWidget {
  const VideoFusionApp({super.key});

  @override
  State<VideoFusionApp> createState() => _VideoFusionAppState();
}

class _VideoFusionAppState extends State<VideoFusionApp> {
  late final VideoService _service;
  late final CredentialVault _vault;
  late final FeedController _feedController;
  late final PlatformRegistry _registry;
  late final VideoProgressStore _progressStore;

  /// 云端播放进度旁路上报器。
  ///
  /// 与本地 `_progressStore` 完全分开：本地进度是权威，云端只是尽力
  /// 而为的跨设备同步。**上报失败绝不影响本地落盘**，也不弹窗。
  late final CloudProgressReporter _cloudProgress;

  /// 全局互动状态登记表。
  ///
  /// 推荐流、详情页、以及后续任何展示互动状态的位置**共用它**，
  /// 同一视频只有一份控制器，避免两个入口显示不同的点赞/收藏状态。
  late final InteractionRegistry _interactions;

  /// 私信状态仓库（会话列表 / 聊天页共享同一份）。
  late final ImStore _imStore;

  final GlobalKey<AppShellState> _shellKey = GlobalKey<AppShellState>();

  /// 应用内 Navigator 的 context。
  ///
  /// 关键：`_VideoFusionAppState.context` 位于 [MaterialApp] **之上**，
  /// 用它调用 `showModalBottomSheet` 会找不到 Navigator 而静默失败。
  /// 必须使用 [MaterialApp] 内部的 context。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  feed_models.FeedSource? _activeSource;
  String? _loggedInLabel;

  /// 登录态版本号。
  ///
  /// 每次凭证变化（导入 Cookie / 退出登录 / 扫码成功）就 +1。
  /// 「我的」页据此在 `didUpdateWidget` 里重新拉取账号与收藏夹 ——
  /// 没有这个信号的话，用户在设置页导入 Cookie 后返回，
  /// 「我的」页仍会显示上一个登录态（"未登录"或旧账号）。
  int _sessionRevision = 0;

  @override
  void initState() {
    super.initState();
    _buildDependencies();
    // 私信未读数变化要反映到「我的」页的入口徽标上。
    // 用同一个 store 通知，避免各页各存一份未读。
    _imStore.addListener(_onImChanged);
    _bootstrap();
  }

  void _onImChanged() {
    if (mounted) setState(() {});
  }

  /// 依赖装配。
  void _buildDependencies() {
    final logger = FusionLogger(minLevel: LogLevel.info);
    final http = FusionHttpClient(logger: logger);
    final secureStore = FlutterSecureStore();

    // 抖音的签名与登录都在应用内隐藏 WebView 里完成，不需要额外装配。

    _registry = PlatformRegistry(adapters: [
      BilibiliAdapter(http: http, logger: logger),
      DouyinAdapter(http: http, logger: logger),
      HongguoAdapter(http: http, logger: logger),
      // 扩展性验证用适配器：本地测试数据，不伪装成真实平台。
      MockAdapter(http: http, logger: logger),
    ]);

    _service = VideoService(
      registry: _registry,
      store: VideoStore(storage: SharedPreferencesStore(), logger: logger),
      logger: logger,
    );

    _vault = CredentialVault(storage: secureStore, logger: logger);
    _feedController = FeedController(service: _service, logger: logger);
    _interactions = InteractionRegistry(service: _service, vault: _vault);
    _imStore = ImStore(service: _service, vault: _vault);
    _progressStore = VideoProgressStore(
      storage: SharedPreferencesStore(),
      logger: logger,
    );
    _cloudProgress = CloudProgressReporter(
      service: _service,
      vault: _vault,
      logger: logger,
    );
  }

  /// 启动：优先选**混合流**（抖音 + B站）→ 加载内容 → 后台恢复登录态。
  ///
  /// 为什么默认混合而不是"第一个可用来源"：
  /// `describeFeedSources()` 现在把混合流排在最前，但如果只按
  /// "第一个 available" 取，一旦混合流因平台缺失返回 null，
  /// 就会悄悄退化成单平台（用户看到的仍是"只有 B站"）。
  /// 这里显式优先混合，退化时也能从 [_activeSource] 看出来。
  Future<void> _bootstrap() async {
    final sources = _service.describeFeedSources();
    final mixed = _service.mixedFeedSource;
    final pick = mixed ??
        sources.where((s) => s.available).firstOrNull ??
        sources.firstOrNull;

    if (pick != null) {
      _activeSource = pick;
      unawaited(_feedController.loadSource(pick));
    }

    unawaited(_restoreSession());
  }

  /// 恢复已登录会话（仅用于顶栏状态显示，凭证不进入 UI）。
  ///
  /// 登录态一变就递增 [_sessionRevision] 并校准所有互动会话：
  /// IndexedStack 会保住「我的」页的状态，不主动通知的话，
  /// 用户在设置页导入 Cookie 后返回，账号卡片仍显示"未登录"。
  Future<void> _restoreSession() async {
    String? label;
    for (final adapter in _registry.adapters) {
      try {
        final session = await _vault
            .load(adapter.id)
            .timeout(const Duration(seconds: 5));
        if (session != null) {
          label = session.displayName;
          break;
        }
      } catch (e) {
        FusionLogger(minLevel: LogLevel.warn).warn(
          'session restore skipped',
          {'platform': adapter.id, 'reason': '${e.runtimeType}'},
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _loggedInLabel = label;
      _sessionRevision++;
    });
    // 登录态变了：云端进度上报器丢掉会话缓存与节流窗口，
    // 否则刚导入 Cookie 的账号要等 5 分钟缓存过期才开始上报。
    _cloudProgress.invalidateSessions();
    // 已打开的推荐流/详情页要重新读登录态，否则导入 Cookie 后
    // 按钮仍显示"登录后可操作"，必须切走再切回才更新。
    await _interactions.recalibrateAll();
  }

  @override
  void dispose() {
    _feedController.dispose();
    _interactions.dispose();
    _imStore.dispose();
    super.dispose();
  }

  /// 构造消息页。
  ///
  /// 返回 null 表示当前没有任何平台支持私信 —— 此时 AppShell 不渲染
  /// 消息标签，避免"点进去什么都没有"。
  Widget? _messagesPage() {
    if (_service.imPlatformIds.isEmpty) return null;
    return MessagesScreen(
      store: _imStore,
      // 未登录时走现有的设置页登录流程（不新造一套登录）
      onOpenLogin: _openSettings,
    );
  }

  // ── 导航动作 ────────────────────────────────────────────────

  Future<void> _openSourcePicker() async {
    final navContext = _navigatorKey.currentContext;
    if (navContext == null) return;
    final sources = _service.describeFeedSources();
    await showModalBottomSheet<void>(
      context: navContext,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _SourcePickerSheet(
        sources: sources,
        selected: _activeSource,
        onSelected: (s) async {
          setState(() => _activeSource = s);
          await _feedController.loadSource(s);
        },
      ),
    );
  }

  Future<void> _openLinkIntake() async {
    final navContext = _navigatorKey.currentContext;
    if (navContext == null) return;
    await showModalBottomSheet<void>(
      context: navContext,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Theme(
        data: AppleTheme.light(),
        child: LinkIntakeSheet(service: _service),
      ),
    );
  }

  void _openOriginal(UnifiedVideo video) {
    openInBrowser(video.canonicalUrl);
  }

  /// 构造直播页。
  ///
  /// 返回 null 表示当前没有任何平台支持直播——此时 AppShell 不会
  /// 渲染直播标签，避免出现"点进去什么都没有"的空页面。
  ///
  /// 2026-10-18：抖音直播已接入（`webcast.amemv.com/webcast/feed` 匿名可用），
  /// 因此这里会把所有声明 `supportsLive` 的适配器一起传给直播页，
  /// 由页面内部提供平台切换。
  Widget? _livePage() {
    final liveAdapters =
        _registry.adapters.where((a) => a.supportsLive).toList();
    if (liveAdapters.isEmpty) return null;

    return LiveScreen(
      adapters: liveAdapters,
      vault: _vault,
      onOpenOriginal: (adapter, room) {
        // 原平台直播间地址按平台拼；拼不出就退回视频页链接。
        final url = switch (adapter.id) {
          'bilibili' => 'https://live.bilibili.com/${room.roomKey}',
          'douyin' => 'https://live.douyin.com/${room.roomKey}',
          _ => null,
        };
        if (url != null) openInBrowser(url);
      },
    );
  }

  /// 打开长视频详情页。
  Future<void> _openDetail(UnifiedVideo video, {Duration? resumeAt}) async {
    final navContext = _navigatorKey.currentContext;
    if (navContext == null) return;
    await Navigator.of(navContext).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailScreen(
          video: video,
          service: _service,
          vault: _vault,
          interactions: _interactions,
          onOpenOriginal: _openOriginal,
          onOpenLogin: _openLogin,
          initialPosition: resumeAt,
          onProgressChanged: (pos, dur) {
            // 每 5 秒落一次盘，避免频繁写入
            if (pos.inSeconds % 5 == 0) {
              unawaited(_progressStore.save(
                videoId: video.id,
                position: pos,
                duration: dur,
                // 带上展示信息，历史页才能显示剧名而不是一串 ID
                title: video.title,
                coverUrl: video.coverUrl,
                platformId: video.platformId,
              ));
              // 云端进度旁路（内部自带 30s 节流 + 失败静默）。
              // 本地进度是权威，这条挂了不影响上面那次落盘。
              _cloudProgress.maybeReport(
                videoId: video.id,
                platformId: video.platformId,
                platformVideoId: video.platformVideoId,
                position: pos,
                duration: dur,
              );
            }
          },
        ),
      ),
    );
  }

  /// 打开设置页。
  ///
  /// 设置是低频功能，不在一级导航里；从「我的」页进入独立路由，
  /// 返回后回到「我的」页原来的滚动位置（IndexedStack 保住了页面状态）。
  Future<void> _openSettings() async {
    final navContext = _navigatorKey.currentContext;
    if (navContext == null) return;
    await Navigator.of(navContext).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          service: _service,
          registry: _registry,
          vault: _vault,
          progressStore: _progressStore,
          onSessionChanged: _restoreSession,
        ),
      ),
    );
    // Cookie 导入/退出登录会改变登录态：返回后校准所有互动状态，
    // 否则已打开的推荐流会继续显示"登录后可操作"。
    await _interactions.recalibrateAll();
  }

  Future<void> _openLogin() async {
    // 登录入口现在在「我的」页里，按语义标签跳转而不是硬编码下标
    _shellKey.currentState?.goToTab(AppTab.profile);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '视频融合',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: AppleTheme.light(),
      darkTheme: AppleTheme.dark(),
      themeMode: ThemeMode.light,
      home: AppShell(
        key: _shellKey,
        feedPage: FeedScreen(
          controller: _feedController,
          service: _service,
          vault: _vault,
          interactions: _interactions,
          onOpenSourcePicker: _openSourcePicker,
          onOpenLogin: _openLogin,
          onOpenOriginal: _openOriginal,
          onOpenLinkIntake: _openLinkIntake,
          onOpenDetail: (v) => _openDetail(v),
          activeSource: _activeSource,
          loggedInLabel: _loggedInLabel,
        ),
        discoverPage: DiscoverScreen(
          service: _service,
          onOpenVideo: (v) => _openDetail(v),
          onOpenSourcePicker: _openSourcePicker,
          onOpenLinkIntake: _openLinkIntake,
        ),
        dramaPage: DramaScreen(
          service: _service,
          onOpenVideo: (v) => _openDetail(v),
        ),
        // 短视频页切走时暂停、切回时恢复（用户主动暂停过则不恢复）。
        onFeedVisibilityChanged: (visible) {
          unawaited(_feedController.setPageActive(visible));
        },
        // 直播页：只在平台确实声明 supportsLive 时注入，
        // 否则不出现空页面。
        livePage: _livePage(),
        // 消息页：只在平台确实支持私信时注入（当前仅 B 站）。
        // 与直播同理，不支持时不渲染标签，避免点进去空白。
        messagesPage: _messagesPage(),
        profilePage: ProfileScreen(
          service: _service,
          registry: _registry,
          vault: _vault,
          progressStore: _progressStore,
          sessionRevision: _sessionRevision,
          onOpenVideo: (v) => _openDetail(v),
          onResumeVideo: (v, at) => _openDetail(v, resumeAt: at),
          onOpenSettings: _openSettings,
          onOpenLogin: _openSettings,
          // 消息入口指向底部标签页（同一份 store，未读不会不一致）
          onOpenMessages: () => _shellKey.currentState?.goToTab(AppTab.messages),
          unreadCount: _imStore.unreadTotal,
        ),
      ),
    );
  }
}

/// 内容来源选择面板（Apple 风格）。
class _SourcePickerSheet extends StatelessWidget {
  const _SourcePickerSheet({
    required this.sources,
    required this.selected,
    required this.onSelected,
  });

  final List<feed_models.FeedSource> sources;
  final feed_models.FeedSource? selected;
  final void Function(feed_models.FeedSource) onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F7),
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0x4A3C3C43),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    '内容来源',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.38,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '内容来自各平台公开接口。标注「不可用」的来源是平台限制，不是本应用未实现。',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Color(0x993C3C43),
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < sources.length; i++) ...[
                          _SourceRow(
                            source: sources[i],
                            selected: sources[i].id == selected?.id,
                            onTap: sources[i].available
                                ? () {
                                    onSelected(sources[i]);
                                    Navigator.pop(context);
                                  }
                                : null,
                          ),
                          if (i < sources.length - 1)
                            const Padding(
                              padding: EdgeInsets.only(left: 16),
                              child: Divider(height: 0.5, thickness: 0.5),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final feed_models.FeedSource source;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.label,
                    style: TextStyle(
                      fontSize: 17,
                      letterSpacing: -0.41,
                      color: enabled ? Colors.black : const Color(0x4D3C3C43),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    enabled ? source.description : (source.unavailableReason ?? ''),
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: enabled
                          ? const Color(0x993C3C43)
                          : const Color(0x4D3C3C43),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded, size: 20, color: Color(0xFF007AFF)),
          ],
        ),
      ),
    );
  }
}
