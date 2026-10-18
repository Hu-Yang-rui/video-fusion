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
import 'src/adapters/mock_adapter.dart';
import 'src/adapters/platform_registry.dart';
import 'src/core/credential_vault.dart';
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
import 'src/ui/feed/feed_screen.dart';
import 'src/ui/live/live_screen.dart';
import 'src/ui/mobile/feed_controller.dart';
import 'src/ui/mobile/link_intake_sheet.dart';
import 'src/core/external_link.dart' show openInBrowser;
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

  final GlobalKey<AppShellState> _shellKey = GlobalKey<AppShellState>();

  /// 应用内 Navigator 的 context。
  ///
  /// 关键：`_VideoFusionAppState.context` 位于 [MaterialApp] **之上**，
  /// 用它调用 `showModalBottomSheet` 会找不到 Navigator 而静默失败。
  /// 必须使用 [MaterialApp] 内部的 context。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  feed_models.FeedSource? _activeSource;
  String? _loggedInLabel;

  @override
  void initState() {
    super.initState();
    _buildDependencies();
    _bootstrap();
  }

  /// 依赖装配。
  void _buildDependencies() {
    final logger = FusionLogger(minLevel: LogLevel.info);
    final http = FusionHttpClient(logger: logger);

    _registry = PlatformRegistry(adapters: [
      BilibiliAdapter(http: http, logger: logger),
      DouyinAdapter(http: http, logger: logger),
      // 扩展性验证用适配器：本地测试数据，不伪装成真实平台。
      MockAdapter(http: http, logger: logger),
    ]);

    _service = VideoService(
      registry: _registry,
      store: VideoStore(storage: SharedPreferencesStore(), logger: logger),
      logger: logger,
    );

    _vault = CredentialVault(storage: FlutterSecureStore(), logger: logger);
    _feedController = FeedController(service: _service, logger: logger);
    _progressStore = VideoProgressStore(
      storage: SharedPreferencesStore(),
      logger: logger,
    );
  }

  /// 启动：选择首个可用来源 → 加载内容 → 后台恢复登录态。
  Future<void> _bootstrap() async {
    final sources = _service.describeFeedSources();
    final firstUsable = sources.where((s) => s.available).toList();
    final pick = firstUsable.isNotEmpty
        ? firstUsable.first
        : (sources.isNotEmpty ? sources.first : null);

    if (pick != null) {
      _activeSource = pick;
      unawaited(_feedController.loadSource(pick));
    }

    unawaited(_restoreSession());
  }

  /// 恢复已登录会话（仅用于顶栏状态显示，凭证不进入 UI）。
  Future<void> _restoreSession() async {
    for (final adapter in _registry.adapters) {
      try {
        final session = await _vault
            .load(adapter.id)
            .timeout(const Duration(seconds: 5));
        if (session != null && mounted) {
          setState(() => _loggedInLabel = session.displayName);
          return;
        }
      } catch (e) {
        FusionLogger(minLevel: LogLevel.warn).warn(
          'session restore skipped',
          {'platform': adapter.id, 'reason': '${e.runtimeType}'},
        );
      }
    }
  }

  @override
  void dispose() {
    _feedController.dispose();
    super.dispose();
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
  /// 目前只有 B 站实现了直播接口；未来其它平台接入时，
  /// 这里按 `supportsLive` 自动选中第一个可用适配器即可。
  Widget? _livePage() {
    final adapter = _registry.byId('bilibili');
    if (adapter == null || !adapter.supportsLive) return null;
    return LiveScreen(
      adapter: adapter,
      onOpenOriginal: (room) => openInBrowser(
        'https://live.bilibili.com/${room.roomId}',
      ),
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
          onOpenOriginal: _openOriginal,
          initialPosition: resumeAt,
          onProgressChanged: (pos, dur) {
            // 每 5 秒落一次盘，避免频繁写入
            if (pos.inSeconds % 5 == 0) {
              unawaited(_progressStore.save(
                videoId: video.id,
                position: pos,
                duration: dur,
              ));
            }
          },
        ),
      ),
    );
  }

  Future<void> _openLogin() async {
    // 切到设置页的账号区域
    _shellKey.currentState?.goTo(3);
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
          onOpenSourcePicker: _openSourcePicker,
          onOpenLogin: _openLogin,
          onOpenOriginal: _openOriginal,
          onOpenLinkIntake: _openLinkIntake,
          onOpenDetail: (v) => _openDetail(v),
          loggedInLabel: _loggedInLabel,
        ),
        discoverPage: DiscoverScreen(
          service: _service,
          onOpenVideo: (v) => _openDetail(v),
          onOpenSourcePicker: _openSourcePicker,
        ),
        // 直播页：只在平台确实声明 supportsLive 时注入，
        // 否则标签栏保持四项，不出现空页面。
        livePage: _livePage(),
        settingsPage: SettingsScreen(
          service: _service,
          registry: _registry,
          vault: _vault,
          progressStore: _progressStore,
          onSessionChanged: _restoreSession,
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
