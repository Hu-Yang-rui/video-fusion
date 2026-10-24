/// 长视频详情页（Apple 风格）。
///
/// # 信息架构
///
/// 内容优先，不把每块信息包成卡片：
///
/// ```
/// ┌──────────────────────────┐
/// │  播放器（16:9，自绘控制条）  │
/// ├──────────────────────────┤
/// │  标题（大字号，视觉主体）    │
/// │  平台 · 播放数 · 日期        │
/// │                          │
/// │  ●头像  作者名      [+关注] │
/// │  ♡ 点赞 · ★ 收藏 · ◉ 投币 · ↗ 分享 · 🕐 稍后再看 │
/// │                          │
/// │  简介正文（可展开）          │
/// │                          │
/// │  💬 查看 2129 条评论    ›   │
/// │                          │
/// │  技术信息  ›（默认收起）     │
/// │                          │
/// │  [在原平台打开]             │
/// └──────────────────────────┘
/// ```
///
/// 设计要点：
///  - 标题、元信息、作者、简介用**留白与排版**分区，不靠卡片边框
///  - 评论入口是一行可点的内容行，不是按钮
///  - 互动条紧贴作者行：点赞/收藏/投币围绕**当前视频**组织，
///    状态与推荐流共享同一个会话（见 [InteractionRegistry]），
///    因此在一个入口收藏后，另一个入口立刻是高亮的
///  - 播放方式 / 分辨率 / 是否支持倍速这类**技术细节默认收起**，
///    普通用户不需要看到；需要排查时展开即可
///  - 与竖滑流的差异：这里支持完整播放、进度恢复、清晰度、全屏
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../adapters/platform_adapter.dart';
import '../../core/app_settings.dart';
import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/seek_preview.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/player_overlays.dart';
import '../../design/components/video_widgets.dart';
import '../../models/playback.dart';
import '../../models/subtitles.dart';
import '../../models/unified_video.dart';
import '../../player/picture_in_picture.dart';
import '../../player/player_controller.dart';
import '../interaction/interaction_controller.dart';
import '../interaction/interaction_registry.dart';
import '../interaction/interaction_widgets.dart';

/// 长视频详情页。
class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({
    super.key,
    required this.video,
    required this.service,
    this.vault,
    this.interactions,
    this.settings,
    this.onOpenOriginal,
    this.onOpenLogin,
    this.initialPosition,
    this.onProgressChanged,
  });

  final UnifiedVideo video;
  final VideoService service;

  /// 应用设置：`autoPlayNext` 决定短剧看完是否自动播下一集。
  /// 为 null 时按"不连播"处理（不猜用户意图）。
  final AppSettings? settings;

  /// 凭证保险库。为 null 时详情页不显示评论入口
  /// （评论需要登录态判断，没有 vault 就无法确定能力）。
  final CredentialVault? vault;

  /// 全局互动状态登记表。
  ///
  /// 传入时详情页**复用**与推荐流同一个会话，因此在一个入口点赞/收藏后
  /// 另一个入口立刻一致。为 null 时退回页面自建会话（旧行为，
  /// 状态不跨页共享）——保持公共 API 兼容，不破坏现有调用方与测试。
  final InteractionRegistry? interactions;

  final void Function(UnifiedVideo)? onOpenOriginal;

  /// 未登录时点击互动按钮的跳转动作（通常去「我的」页登录）。
  /// 为 null 时互动条自己提示"请先登录"，不做跳转。
  final VoidCallback? onOpenLogin;

  /// 续播位置（来自观看历史）。
  final Duration? initialPosition;

  /// 进度回调（用于持久化观看进度）。
  final void Function(Duration position, Duration duration)? onProgressChanged;

  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen> {
  FusionPlayerController? _player;
  VideoController? _videoController;
  PlayerSnapshot _snapshot = PlayerSnapshot.initial;
  StreamSubscription<PlayerSnapshot>? _sub;

  PlaybackSource? _source;
  FusionException? _error;
  bool _resolving = true;
  bool _showControls = true;
  bool _descriptionExpanded = false;
  bool _fullscreen = false;
  bool _techExpanded = false;
  Timer? _controlsTimer;

  /// 互动控制器（评论、点赞等）。仅在有 vault 或登记表时创建。
  InteractionController? _interaction;

  /// 本页是否持有登记表的引用（决定 dispose 时是否 release）。
  bool _holdsRef = false;

  @override
  void initState() {
    super.initState();
    _resolveAndLoad();
    _bindInteraction();
    unawaited(_loadListing());
    unawaited(_loadEnhancements());
    // 原生侧在系统 PiP 回调里推状态：用户从小窗点 × 返回时，
    // 本页的小窗按钮必须复位，否则图标一直停在"已进小窗"的错态。
    _pip.addListener(_onPipChanged);
  }

  final PictureInPicture _pip = PictureInPicture.instance;

  void _onPipChanged() {
    if (!mounted) return;
    setState(() => _pipActive = _pip.isActive);
  }

  void _bindInteraction() {
    final registry = widget.interactions;
    if (registry != null) {
      _interaction = registry.acquire(widget.video);
      _holdsRef = true;
      return;
    }
    final vault = widget.vault;
    if (vault != null) {
      final ctrl = InteractionController(
        video: widget.video,
        service: widget.service,
        vault: vault,
      );
      // 异步初始化登录态，不阻塞首帧
      unawaited(ctrl.init());
      _interaction = ctrl;
    }
  }

  /// 是否正在解析播放地址（**防重入**）。
  ///
  /// # 为什么必须有这个守卫
  ///
  /// `_resolveAndLoad` 有两个调用方：`initState` 与"重试"按钮。
  /// 没有守卫时，用户在解析途中连点重试会：
  ///   1. 每次调用都 `FusionPlayerController()` 新建一个实例
  ///   2. `_player = player` 直接覆盖上一个，**旧实例永不 dispose**
  ///   3. `_sub` 被覆盖而不 cancel，**旧订阅仍在推 setState**
  ///   4. 两个 libmpv 实例同时持有音频输出 → 声音叠加
  ///
  /// 这是"快速连续点击导致播放器重复创建"的根因，属于确定性缺陷，
  /// 不是玄学卡顿。
  bool _resolveInFlight = false;

  Future<void> _resolveAndLoad() async {
    if (_resolveInFlight) return;
    _resolveInFlight = true;

    setState(() {
      _resolving = true;
      _error = null;
    });

    try {
      await _doResolveAndLoad();
    } finally {
      _resolveInFlight = false;
    }
  }

  Future<void> _doResolveAndLoad() async {
    debugPrint('[detail] resolve start: ${widget.video.id}');
    final outcome = await widget.service.resolvePlayback(widget.video);
    debugPrint(
      '[detail] resolve done: ok=${outcome.ok} '
      'source=${outcome.source?.runtimeType} '
      'error=${outcome.error?.technicalMessage}',
    );

    if (!mounted) return;

    if (!outcome.ok) {
      setState(() {
        _resolving = false;
        _error =
            outcome.error ??
            FusionException(
              code: FusionErrorCode.capabilityUnavailable,
              userMessage: '无法解析该视频的播放地址。',
              platformId: widget.video.platformId,
            );
      });
      return;
    }

    final source = outcome.source!;
    if (source is! NativePlaybackSource) {
      // 非应用内播放：明确告知，不伪装
      setState(() {
        _resolving = false;
        _source = source;
      });
      return;
    }

    // 重试路径：先把上一个播放器与订阅彻底拆掉再建新的。
    // 顺序很重要——先 cancel 订阅（否则 dispose 过程中仍会收到事件），
    // 再 dispose 播放器，最后才换引用。
    _teardownPlayer();

    final player = FusionPlayerController(settings: widget.settings);
    _player = player;
    _sub = player.stream.listen((s) {
      if (!mounted) return;
      final wasCompleted = _snapshot.phase == PlayerPhase.completed;
      setState(() => _snapshot = s);
      widget.onProgressChanged?.call(s.position, s.duration);
      if (!wasCompleted && s.phase == PlayerPhase.completed) {
        _onPlaybackCompleted();
      }
    });

    await player.load(source);
    if (!mounted) {
      // 解析途中页面已销毁：不能把 controller 挂到一个已卸载的 State 上
      _teardownPlayer();
      return;
    }
    _videoController = VideoController(
      player.rawPlayer,
      configuration: player.videoConfiguration,
    );

    // 续播
    final resume = widget.initialPosition;
    if (resume != null && resume > const Duration(seconds: 5)) {
      await player.seek(resume);
    }

    await player.play();

    if (mounted) {
      setState(() {
        _resolving = false;
        _source = source;
      });
      _scheduleHideControls();
    }
  }

  /// 拆掉当前播放器与订阅（幂等）。
  ///
  /// 与 `dispose()` 的区别：这里只清播放相关状态，不动互动控制器。
  /// 重试 / 重新解析前必须调用，否则旧 libmpv 实例会继续占着音频输出。
  void _teardownPlayer() {
    _sub?.cancel();
    _sub = null;
    _player?.dispose();
    _player = null;
    _videoController = null;
    _snapshot = PlayerSnapshot.initial;
  }

  void _scheduleHideControls() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _snapshot.phase == PlayerPhase.playing) {
        setState(() => _showControls = false);
      }
    });
  }

  // ── 选集与自动连播 ──────────────────────────────────────────

  /// 播完时尝试连播下一集。
  ///
  /// 三个条件缺一不可：开了连播、这视频确实属于某部剧的分集、
  /// 且还有下一集。任一不满足就什么都不做——不弹"已播完"也不假装切换。
  void _onPlaybackCompleted() {
    if (widget.settings?.autoPlayNext != true) return;
    final listing = _listing;
    if (listing == null || !listing.hasNext) return;
    unawaited(_switchEpisode(listing.next));
  }

  /// 当前视频的分集列表（null = 该平台/该视频没有分集概念）。
  EpisodeListing? _listing;
  bool _loadingListing = false;

  /// 拉取分集列表。只在真正支持的平台下拉一次，失败静默（不挡播放）。
  Future<void> _loadListing() async {
    if (_loadingListing || _listing != null) return;
    // 见 platform_adapter.dart：只有声明 EpisodeListCapable 的适配器有选集。
    final Object? adapter = widget.service.registry.byId(widget.video.platformId);
    if (adapter is! EpisodeListCapable) return;
    _loadingListing = true;
    try {
      _listing = await adapter
          .listEpisodesFor(widget.video.platformVideoId)
          .timeout(const Duration(seconds: 10));
      if (mounted) setState(() {});
    } catch (_) {
      // 选集是增强信息，拉不到只是不显示选集，绝不影响播放
    } finally {
      _loadingListing = false;
    }
  }

  /// 切到某一集：换视频并重解析。
  ///
  /// 用 pushReplacement 而不是 push：连播时如果堆栈里塞了 30 个详情页，
  /// 返回键要按 30 次才出得去。
  Future<void> _switchEpisode(UnifiedVideo? target) async {
    final video = target;
    if (video == null) return;
    if (!mounted) return;
    final nav = Navigator.of(context);
    await nav.pushReplacement(
      MaterialPageRoute(
        builder: (_) => VideoDetailScreen(
          video: video,
          service: widget.service,
          vault: widget.vault,
          interactions: widget.interactions,
          settings: widget.settings,
          onOpenOriginal: widget.onOpenOriginal,
          onOpenLogin: widget.onOpenLogin,
          onProgressChanged: widget.onProgressChanged,
        ),
      ),
    );
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  // ── 画中画 ──────────────────────────────────────────────────

  bool _pipActive = false;

  /// 点小窗按钮：请求进入画中画。
  ///
  /// 失败必须如实提示（多数 ROM 需在系统设置里允许小窗），
  /// 不能改了图标状态让用户以为已经进了小窗。
  /// 成功后不手动改 _pipActive——由原生侧的 PiP 回调统一驱动，
  /// 避免"我们以为进了、系统其实没进"的两套状态。
  Future<void> _onPictureInPicture() async {
    final player = _player;
    if (player == null) return;
    final ok = await player.enterPictureInPicture();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('这台设备未允许本应用使用小窗播放，可在系统设置里开启。'),
        ),
      );
    }
  }

  // ── 字幕与进度条预览 ────────────────────────────────────────
  //
  // 两项都只有 B站给得出（见 VideoService.supportsSubtitlesFor）。
  // 取不到就什么都不显示：不给一个点了没反应的按钮。

  SpriteSheetSpec? _sprite;
  List<SubtitleTrackInfo> _subtitleTracks = const [];

  /// 选中的字幕语言；null = 关闭字幕。
  String? _subtitleLan;
  List<SubtitleCue> _subtitleCues = const [];

  bool _loadingEnhancements = false;

  /// 已解码的拼图（按拼图序号）。一张 4800×2700 ≈ 50 MB，
  /// 所以最多留两张，切走就 dispose。
  final Map<int, ui.Image> _sheetCache = {};
  final Set<int> _sheetInFlight = {};

  SubtitleTrackInfo? get _activeSubtitleTrack {
    final lan = _subtitleLan;
    if (lan == null) return null;
    for (final t in _subtitleTracks) {
      if (t.lan == lan) return t;
    }
    return null;
  }

  SubtitleCue? get _currentCue =>
      _subtitleLan == null ? null : cueAt(_subtitleCues, _snapshot.position);

  /// 进页面后取字幕列表与拼图数据。
  ///
  /// 两者都是增强信息：任何一步失败都只是不显示，不影响播放，
  /// 也不弹错误——用户不需要知道"缩略图没取到"。
  Future<void> _loadEnhancements() async {
    if (_loadingEnhancements) return;
    if (!widget.service.supportsSubtitlesFor(widget.video.platformId)) return;
    _loadingEnhancements = true;
    try {
      final session = await widget.vault?.load(widget.video.platformId);
      final sprite = await widget.service.fetchSeekPreview(widget.video);
      if (!mounted) return;
      if (sprite != null) setState(() => _sprite = sprite);

      final tracks = await widget.service
          .fetchSubtitleTracks(widget.video, session: session)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() => _subtitleTracks = tracks);
    } catch (_) {
      // 增强信息失败不打扰用户
    } finally {
      _loadingEnhancements = false;
    }
  }

  /// 取某张拼图并解码（同一张只解码一次）。
  Future<ui.Image?> _loadSheet(int index) async {
    final spec = _sprite;
    if (spec == null || index < 0 || index >= spec.sheetUrls.length) {
      return null;
    }
    final cached = _sheetCache[index];
    if (cached != null) return cached;
    if (_sheetInFlight.contains(index)) return null;
    _sheetInFlight.add(index);
    try {
      final bytes = await widget.service
          .fetchSeekPreviewSheet(spec.sheetUrls[index])
          .timeout(const Duration(seconds: 20));
      if (bytes == null || bytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final image = frame.image;
      // 只留两张：长视频有 13 张拼图，全留着会吃掉几百 MB。
      final keep = <int>{index};
      if (_lastSheetIndex != null) keep.add(_lastSheetIndex!);
      for (final key in _sheetCache.keys.toList()) {
        if (keep.contains(key)) continue;
        _sheetCache.remove(key)?.dispose();
      }
      _lastSheetIndex = index;
      _sheetCache[index] = image;
      return image;
    } catch (_) {
      return null;
    } finally {
      _sheetInFlight.remove(index);
    }
  }

  int? _lastSheetIndex;

  /// 切换字幕（null = 关闭）。
  Future<void> _selectSubtitle(String? lan) async {
    if (lan == null) {
      setState(() {
        _subtitleLan = null;
        _subtitleCues = const [];
      });
      return;
    }
    final track = _activeSubtitleTrack ?? _trackFor(lan);
    if (track == null) return;
    setState(() => _subtitleLan = lan);
    final cues = await widget.service.fetchSubtitleCues(track);
    if (!mounted || _subtitleLan != lan) return;
    setState(() => _subtitleCues = cues);
  }

  SubtitleTrackInfo? _trackFor(String lan) {
    for (final t in _subtitleTracks) {
      if (t.lan == lan) return t;
    }
    return null;
  }

  /// 字幕菜单。只有平台真的给了字幕轨才出现。
  Widget? _buildSubtitleMenu() {
    if (_subtitleTracks.isEmpty) return null;
    final active = _subtitleLan;
    return PopupMenuButton<String>(
      tooltip: '字幕',
      color: const Color(0xE61C1C1E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadius.sm),
      ),
      onSelected: (v) => unawaited(_selectSubtitle(v.isEmpty ? null : v)),
      itemBuilder: (context) => [
        for (final item in <(String, String)>[
          ('', '关闭字幕'),
          for (final t in _subtitleTracks) (t.lan, t.displayLabel),
        ])
          PopupMenuItem(
            value: item.$1,
            height: 40,
            child: Row(
              children: [
                if (item.$1 == (active ?? ''))
                  const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(
                  item.$2,
                  style: AppleType.footnote.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          active == null
              ? Icons.subtitles_off_rounded
              : Icons.subtitles_rounded,
          size: 24,
          color: Colors.white,
        ),
      ),
    );
  }

  /// 拖动时的缩略图。没有拼图数据时返回 null，进度条行为与原来一致。
  Widget? _buildSeekPreview(double seconds) {
    final spec = _sprite;
    if (spec == null) return null;
    return SpriteSeekPreview(
      spec: spec,
      seconds: seconds,
      loader: _loadSheet,
    );
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    if (next) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _sub?.cancel();
    for (final image in _sheetCache.values) {
      image.dispose();
    }
    _sheetCache.clear();
    if (_holdsRef) {
      // 交还给登记表：引用归零时由登记表统一 dispose，
      // 这里直接 dispose 会破坏推荐流仍在使用的同一会话。
      widget.interactions?.release(widget.video.id);
      _holdsRef = false;
    } else {
      _interaction?.dispose();
    }
    _interaction = null;
    _player?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildPlayerArea(fullscreen: true),
      );
    }

    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: CustomScrollView(
        slivers: [
          // 折叠式播放器头部
          SliverAppBar(
            pinned: true,
            expandedHeight: MediaQuery.sizeOf(context).width * 9 / 16,
            backgroundColor: Colors.black,
            surfaceTintColor: Colors.transparent,
            leading: _GlassBackButton(onTap: () => Navigator.pop(context)),
            title: const SizedBox.shrink(),
            flexibleSpace: FlexibleSpaceBar(
              background: _buildPlayerArea(fullscreen: false),
              collapseMode: CollapseMode.pin,
            ),
          ),

          // 内容
          SliverToBoxAdapter(child: _buildContent(c)),
        ],
      ),
    );
  }

  /// 播放器区域。
  Widget _buildPlayerArea({required bool fullscreen}) {
    if (_resolving) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppleSpace.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.play_circle_outline_rounded,
                  size: 44,
                  color: Colors.white30,
                ),
                const SizedBox(height: AppleSpace.md),
                Text(
                  _error!.presentation.title,
                  style: AppleType.subheadlineEmphasized.copyWith(
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppleSpace.xs),
                Text(
                  _error!.userMessage,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppleType.caption1.copyWith(color: Colors.white54),
                ),
                const SizedBox(height: AppleSpace.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _PlayerPillButton(
                      label: '原平台',
                      onTap: () => widget.onOpenOriginal?.call(widget.video),
                    ),
                    const SizedBox(width: AppleSpace.sm),
                    _PlayerPillButton(
                      label: '重试',
                      onTap: _resolveAndLoad,
                      filled: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 非原生播放
    if (_source != null && _source is! NativePlaybackSource) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _source is ExternalPlaybackSource
                    ? '该视频需要在原平台播放'
                    : '该视频使用官方嵌入播放',
                style: AppleType.subheadlineEmphasized.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: AppleSpace.lg),
              _PlayerPillButton(
                label: '打开原平台',
                onTap: () => widget.onOpenOriginal?.call(widget.video),
                filled: true,
              ),
            ],
          ),
        ),
      );
    }

    final player = _player;
    if (player == null || _videoController == null) {
      return Container(color: Colors.black);
    }

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Video(
              controller: _videoController!,
              controls: NoVideoControls,
              fit: BoxFit.contain,
            ),
          ),
          // 单击画面：切换播放/暂停 + 显示控制条。
          //
          // 之前只调 _toggleControls（显隐控制条），单击画面不会暂停，
          // 与短视频页是同一个缺陷。
          //
          // 双击保留原有行为（全屏切换在别处，这里不占用双击手势），
          // 因此只注册 onTap，单击立即响应，无 300ms 判定延迟。
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                final phase = _snapshot.phase;
                if (phase == PlayerPhase.playing ||
                    phase == PlayerPhase.paused) {
                  player.playOrPause();
                  _scheduleHideControls();
                } else {
                  _toggleControls();
                }
                if (!_showControls) {
                  setState(() => _showControls = true);
                }
              },
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // 字幕：自绘一层，不挂 mpv（理由见 subtitles.dart 顶部）。
          // 未选字幕轨道时它自己渲染成空，不占位、不挡手势。
          SubtitleOverlay(
            cue: _currentCue,
            cornerLabel: _activeSubtitleTrack == null
                ? null
                : '字幕：${_activeSubtitleTrack!.displayLabel}',
          ),
          // 缓冲
          if (_snapshot.isBuffering)
            const Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white70,
                ),
              ),
            ),
          // 控制条：贴播放区底部。
          //
          // 必须用 Positioned —— Stack 的非定位子节点会被 StackFit.expand
          // 拉满整个播放区，控制条内容就会贴到顶部并和返回按钮重叠。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: AppleMotion.fast,
              child: IgnorePointer(
                ignoring: !_showControls,
                child: PlayerControlBar(
                  position: _snapshot.position,
                  duration: _snapshot.duration,
                  buffered: _snapshot.buffered,
                  isPlaying: _snapshot.phase == PlayerPhase.playing,
                  volume: _snapshot.volume,
                  rate: _snapshot.rate,
                  onPlayPause: () {
                    player.playOrPause();
                    _scheduleHideControls();
                  },
                  onSeek: (d) {
                    player.seek(d);
                    _scheduleHideControls();
                  },
                  onSeekStart: () => _controlsTimer?.cancel(),
                  onSeekEnd: _scheduleHideControls,
                  onVolumeChanged: (v) => player.setVolume(v),
                  onRateChanged: (r) {
                    // 同时写回设置：详情页选的倍速下次进来还在。
                    unawaited(player.setRate(r));
                    final s = widget.settings;
                    if (s != null) s.playbackRate = r;
                  },
                  onFullscreen: _toggleFullscreen,
                  // 只有真接了小窗通道的平台才给按钮；桌面上不装这个图标
                  onPictureInPicture:
                      _pip.isSupported ? _onPictureInPicture : null,
                  pipActive: _pipActive,
                  seekPreview: _sprite == null ? null : _buildSeekPreview,
                  subtitleMenu: _buildSubtitleMenu(),
                  title: widget.video.title,
                  subtitle: widget.video.author.name,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 详情内容区。
  ///
  /// 内容优先：用留白与排版分区，而不是把每块信息包成卡片。
  /// 技术细节（播放方式/分辨率/倍速支持）默认收起。
  Widget _buildContent(AppleColors c) {
    final v = widget.video;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppleSpace.huge),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题与元信息（无卡片，靠排版建立层级）──────
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.pageInset,
              AppleSpace.lg,
              AppleSpace.pageInset,
              AppleSpace.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.title,
                  style: AppleType.title3.copyWith(color: c.label, height: 1.3),
                ),
                const SizedBox(height: AppleSpace.sm),
                // 元信息一行，低视觉权重
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppleSpace.xs,
                  runSpacing: 4,
                  children: [
                    PlatformChip(platformId: v.platformId),
                    if (v.stats.viewCount != null)
                      _metaText(c, '${_fmtCount(v.stats.viewCount!)}次播放'),
                    if (v.publishedAt != null)
                      _metaText(c, _fmtDate(v.publishedAt!)),
                    if (v.durationLabel != null) _metaText(c, v.durationLabel!),
                  ],
                ),
              ],
            ),
          ),

          // ── 作者行 + 互动条 ───────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
              vertical: AppleSpace.sm,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: c.fill,
                  backgroundImage: v.author.avatarUrl != null
                      ? ResizeImage.resizeIfNeeded(
                          72,
                          72,
                          NetworkImage(
                            v.author.avatarUrl!,
                            headers: const {
                              'Referer': 'https://www.bilibili.com/',
                            },
                          ),
                        )
                      : null,
                  child: v.author.avatarUrl == null
                      ? Text(
                          (v.author.name ?? '?').characters.first,
                          style: AppleType.subheadlineEmphasized.copyWith(
                            color: c.secondaryLabel,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: AppleSpace.md),
                Expanded(
                  child: Text(
                    v.author.name ?? '未知作者',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.bodyEmphasized.copyWith(color: c.label),
                  ),
                ),
                // 关注按钮（平台接口实测支持时才出现）
                if (_interaction != null) _FollowButton(ctrl: _interaction!),
              ],
            ),
          ),

          // ── 互动条：点赞 / 评论 / 收藏 / 投币 / 稍后再看 / 分享 ──
          //
          // 围绕**当前视频**组织，状态与推荐流共享同一个会话。
          if (_interaction != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpace.pageInset,
                0,
                AppleSpace.pageInset,
                AppleSpace.sm,
              ),
              child: ListenableBuilder(
                listenable: _interaction!,
                builder: (context, _) => _InteractionBar(
                  video: v,
                  ctrl: _interaction!,
                  // 未登录时走外部给的登录入口（「我的」页），没有就原地提示
                  onOpenLogin: widget.onOpenLogin ?? () {},
                ),
              ),
            ),

          // ── 选集（短剧 / 多 P 平台才有）──────────────────
          if (_listing != null && _listing!.total > 1)
            _EpisodeSection(
              listing: _listing!,
              onPick: (target) => unawaited(_switchEpisode(target)),
            ),

          // ── 简介（无卡片）────────────────────────────
          if (v.description != null && v.description!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpace.pageInset,
                AppleSpace.sm,
                AppleSpace.pageInset,
                AppleSpace.sm,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(
                  () => _descriptionExpanded = !_descriptionExpanded,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.description!.trim(),
                      maxLines: _descriptionExpanded ? null : 3,
                      overflow: _descriptionExpanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: AppleType.subheadline.copyWith(
                        color: c.secondaryLabel,
                        height: 1.5,
                      ),
                    ),
                    if (v.description!.trim().length > 80) ...[
                      const SizedBox(height: 4),
                      Text(
                        _descriptionExpanded ? '收起' : '展开',
                        style: AppleType.caption1.copyWith(color: c.blue),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          const SizedBox(height: AppleSpace.sm),
          _hairline(c),

          // ── 评论入口（一行可点内容，不是按钮）────────
          if (_interaction != null) _buildCommentEntry(c, _interaction!),

          _hairline(c),

          // ── 技术信息（默认收起）──────────────────────
          _buildTechDisclosure(c),

          const SizedBox(height: AppleSpace.lg),

          // ── 原平台入口 ──────────────────────────────
          //
          // 原来是个**全宽灰底大按钮**，视觉权重比评论入口还高——
          // 但它是"离开本应用"的次要出口，不该是页面主操作。
          // 现在降级为居中的一行小字链接，位置留在底部（需要时能找到）。
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
            ),
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onOpenOriginal?.call(widget.video),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppleSpace.sm,
                    horizontal: AppleSpace.md,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '在原平台打开',
                        style: AppleType.footnote.copyWith(color: c.blue),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 13,
                        color: c.blue,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 元信息文字（低权重）。
  Widget _metaText(AppleColors c, String text) =>
      Text(text, style: AppleType.caption1.copyWith(color: c.tertiaryLabel));

  /// 细分割线（内容区之间）。
  Widget _hairline(AppleColors c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppleSpace.pageInset),
    child: SizedBox(height: 0.5, child: ColoredBox(color: c.separator)),
  );

  /// 评论入口。
  ///
  /// 做成"一行内容"而不是按钮：用户浏览视频时，
  /// 评论是内容的一部分，不是需要额外点击的工具。
  Widget _buildCommentEntry(AppleColors c, InteractionController ctrl) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final count = ctrl.commentTotal;
        final label = count > 0 ? '查看 ${_fmtCount(count)} 条评论' : '查看评论';
        return InkWell(
          onTap: () => _openComments(ctrl),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
              vertical: AppleSpace.md,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 17,
                  color: c.secondaryLabel,
                ),
                const SizedBox(width: AppleSpace.sm),
                Expanded(
                  child: Text(
                    label,
                    style: AppleType.subheadline.copyWith(color: c.label),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: c.tertiaryLabel,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openComments(InteractionController ctrl) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // onOpenLogin：评论面板里"未登录"时的登录引导入口
      builder: (_) => CommentSheet(
        controller: ctrl,
        onOpenLogin: widget.onOpenLogin,
      ),
    );
  }

  /// 技术信息折叠区。
  ///
  /// 播放方式、分辨率、是否支持倍速这类信息对普通用户没有意义，
  /// 只在需要排查问题时展开。这是本次去工具化的关键改动：
  /// 之前它们直接以两整块卡片占据详情页下半屏。
  Widget _buildTechDisclosure(AppleColors c) {
    final v = widget.video;
    final caps = _player?.capabilities;
    final limitations = v.diagnostics.limitations;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _techExpanded = !_techExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
              vertical: AppleSpace.md,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: c.tertiaryLabel,
                ),
                const SizedBox(width: AppleSpace.sm),
                Text(
                  '技术信息',
                  style: AppleType.caption1.copyWith(color: c.tertiaryLabel),
                ),
                const Spacer(),
                Icon(
                  _techExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: c.tertiaryLabel,
                ),
              ],
            ),
          ),
        ),
        if (_techExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.pageInset,
              0,
              AppleSpace.pageInset,
              AppleSpace.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _techRow(c, '播放方式', _playbackModeLabel()),
                if (caps != null) ...[
                  _techRow(c, '倍速调节', caps.canSetRate ? '支持' : '不支持'),
                  _techRow(c, '拖动进度', caps.canSeek ? '支持' : '不支持'),
                ],
                if (v.width != null && v.height != null)
                  _techRow(c, '分辨率', '${v.width}×${v.height}'),
                if (_qualityFallbackReason != null)
                  _techRow(c, '清晰度说明', _qualityFallbackReason!),
                if (limitations.isNotEmpty) ...[
                  const SizedBox(height: AppleSpace.sm),
                  for (final l in limitations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '· $l',
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _techRow(AppleColors c, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: AppleType.caption2.copyWith(color: c.secondaryLabel),
          ),
        ),
      ],
    ),
  );

  /// 只剩单一档位时的说明。
  ///
  /// 高清源是平台侧接口，可能整段时间不可用。用户看到"只有 360p"
  /// 时需要知道这是平台侧限制，不是应用故障。
  String? get _qualityFallbackReason {
    final s = _source;
    if (s is! NativePlaybackSource) return null;
    final qs = s.availableQualities;
    if (qs.length > 1) return null;
    final label = qs.isNotEmpty ? qs.first.label : (s.quality?.label ?? '');
    if (!label.contains('360')) return null;
    return '高清源当前不可用，已使用平台公开源';
  }

  String _playbackModeLabel() {
    final s = _source;
    if (s == null) return '未解析';
    return switch (s) {
      NativePlaybackSource() => '应用内播放',
      OfficialEmbedPlaybackSource() => '官方嵌入',
      ExternalPlaybackSource() => '跳转原平台',
    };
  }

  static String _fmtCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  static String _fmtDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

/// 选集区块：横滑集数 + 当前集高亮。
///
/// 行高 40 的紧凑格子：一部短剧可能上百集，用 GridView 会让详情页
/// 长到没法滚。当前集必须滚进视野，否则打开第 60 集看到的还是 1–20。
///
/// 用 [ScrollController] 定偏移而不是 `initialScrollIndex`：后者要求
/// `itemExtent` 且本 SDK 的 ListView 未暴露该参数。
class _EpisodeSection extends StatefulWidget {
  const _EpisodeSection({required this.listing, required this.onPick});

  final EpisodeListing listing;
  final void Function(UnifiedVideo target) onPick;

  /// 与 build 里 itemExtent 保持一致（44 宽 + 8 间距）。
  static const double _itemExtent = 52;

  @override
  State<_EpisodeSection> createState() => _EpisodeSectionState();
}

class _EpisodeSectionState extends State<_EpisodeSection> {
  late final ScrollController _scroll;

  /// 已对齐过的集下标。避免每次 build 都把用户的手动滚动拽回去。
  int? _alignedIndex;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(
      initialScrollOffset: _offsetFor(widget.listing.currentIndex),
    );
    _alignedIndex = widget.listing.currentIndex;
  }

  /// 让当前集落在视口偏左位置，而不是贴着左边缘。
  double _offsetFor(int index) =>
      (index * _EpisodeSection._itemExtent - 60)
          .clamp(0, double.infinity)
          .toDouble();

  @override
  void didUpdateWidget(_EpisodeSection old) {
    super.didUpdateWidget(old);
    final i = widget.listing.currentIndex;
    if (i == _alignedIndex) return;
    _alignedIndex = i;
    if (_scroll.hasClients) {
      _scroll.jumpTo(_offsetFor(i));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final listing = widget.listing;
    return Padding(
      padding: const EdgeInsets.only(top: AppleSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.pageInset,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${listing.seriesTitle} · 全 ${listing.total} 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.subheadlineEmphasized
                        .copyWith(color: c.label),
                  ),
                ),
                Text(
                  '第 ${listing.currentIndex + 1} 集',
                  style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppleSpace.sm),
          SizedBox(
            height: 40,
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(
                horizontal: AppleSpace.pageInset,
              ),
              scrollDirection: Axis.horizontal,
              itemExtent: _EpisodeSection._itemExtent,
              itemCount: listing.episodes.length,
              itemBuilder: (context, i) {
                final ep = listing.episodes[i];
                final isCurrent = i == listing.currentIndex;
                return GestureDetector(
                  onTap: isCurrent ? null : () => widget.onPick(ep),
                  child: Container(
                    width: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isCurrent ? c.blue : c.fill,
                      borderRadius: BorderRadius.circular(AppleRadius.xs),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: AppleType.subheadline.copyWith(
                        color: isCurrent ? Colors.white : c.secondaryLabel,
                        fontWeight: isCurrent
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 详情页互动条。
///
/// 与推荐流右侧栏使用**同一个会话对象**（由 [InteractionRegistry] 按
/// 视频 ID 复用），所以：
///  - 在推荐流里点了收藏，进详情页立刻是高亮的（不再各自一份状态）
///  - 这里发起的写操作成功后，推荐流的按钮也会同步更新
///
/// 只渲染平台真实支持的动作；不支持的动作**不出现**，
/// 而不是渲染一个点了报错的按钮。
class _InteractionBar extends StatelessWidget {
  const _InteractionBar({
    required this.video,
    required this.ctrl,
    required this.onOpenLogin,
  });

  final UnifiedVideo video;
  final InteractionController ctrl;
  final VoidCallback onOpenLogin;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final caps = ctrl.capabilities;
    final state = ctrl.state;
    final avail = ctrl.coinAvailability();

    // 未登录时状态未知：文案显示"登录后可操作"，不显示"未点赞"
    final unknownHint = !state.known && !ctrl.isLoggedIn;

    // # 为什么不再用 Wrap（真实观感问题）
    //
    // 原来所有动作塞进一个 Wrap，窄屏下自动折成两行：
    //   点赞 / 收藏 / 投币
    //   稍后再看 / 分享      ← 第二行左边挤着，右边空一大块
    // 看起来像"排版没做完"。
    //
    // 现在拆成两层：
    //  主操作（点赞/收藏/投币）→ 一行等宽铺满，是刷视频时高频用的
    //  低频动作（稍后再看/分享）→ 右对齐小号文字，视觉权重明显更低
    final primaryActions = <Widget>[
      if (caps.like)
        _PillAction(
            icon: state.liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: unknownHint
                ? '点赞'
                : _fmtMaybe(state.likeCount ?? video.stats.likeCount),
            active: state.liked,
            activeColor: c.pink,
            busy: ctrl.likePending,
            onTap: () => ctrl.isLoggedIn ? ctrl.toggleLike() : onOpenLogin(),
          ),
        if (caps.favorite)
          _PillAction(
            icon: state.favorited
                ? Icons.star_rounded
                : Icons.star_border_rounded,
            label: _favoriteLabel(),
            active: state.favorited,
            activeColor: c.orange,
            busy: ctrl.favoritePending,
            onTap: () {
              if (!ctrl.isLoggedIn) return onOpenLogin();
              if (ctrl.supportsFavoriteFolders) {
                _openFavorites(context);
              } else {
                ctrl.toggleFavorite();
              }
            },
          ),
        if (caps.coin)
          _PillAction(
            icon: state.coined > 0
                ? Icons.monetization_on_rounded
                : Icons.monetization_on_outlined,
            label: state.coined > 0 ? '已投 ${state.coined}' : '投币',
            active: state.coined > 0,
            activeColor: c.yellow,
            busy: ctrl.coinPending,
            // 余额不足 / 已达上限 → 不可点并说明原因
            enabled: avail.allowed,
            disabledReason: avail.reason.isEmpty ? null : avail.reason,
            onTap: () => ctrl.isLoggedIn ? _openCoin(context) : onOpenLogin(),
          ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (primaryActions.isNotEmpty)
          Row(
            children: [
              for (var i = 0; i < primaryActions.length; i++) ...[
                if (i > 0) const SizedBox(width: AppleSpace.sm),
                // 等宽铺满：有几个按钮就各占几分之一，不再参差不齐
                Expanded(child: primaryActions[i]),
              ],
            ],
          ),
        const SizedBox(height: AppleSpace.sm),
        // 低频动作：右对齐的小号文字按钮，视觉权重明显低于主操作。
        Row(
          children: [
            if (caps.watchLater)
              _TextAction(
                icon: state.watchLater
                    ? Icons.schedule_rounded
                    : Icons.schedule_outlined,
                label: state.watchLater ? '已加入稍后再看' : '稍后再看',
                active: state.watchLater,
                onTap: () =>
                    ctrl.isLoggedIn ? ctrl.toggleWatchLater() : onOpenLogin(),
              ),
            const Spacer(),
            _TextAction(
              icon: Icons.share_outlined,
              label: '分享',
              onTap: () => _share(context),
            ),
          ],
        ),
      ],
    );
  }

  String _favoriteLabel() {
    final n = ctrl.favoritedFolderIds.length;
    if (!ctrl.state.favorited) return '收藏';
    if (ctrl.supportsFavoriteFolders && n > 1) return '$n 个夹';
    return '已收藏';
  }

  Future<void> _openFavorites(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // 弹层是覆盖物，**不暂停播放**；关闭后播放器状态原样保留
      builder: (_) => FavoriteSheet(controller: ctrl),
    );
  }

  Future<void> _openCoin(BuildContext context) async {
    await ctrl.loadCoinBalance();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          CoinSheet(controller: ctrl, coinBalance: ctrl.coinBalance),
    );
  }

  /// 分享：真实复制到剪贴板并回读校验，失败给明确反馈。
  Future<void> _share(BuildContext context) async {
    final url = video.canonicalUrl;
    if (url.isEmpty) {
      _toast(context, '该视频没有可分享的链接。');
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: url));
      final read = await Clipboard.getData(Clipboard.kTextPlain);
      _toast(context, read?.text == url ? '链接已复制：$url' : '已尝试复制链接，请确认粘贴内容。');
    } catch (_) {
      _toast(context, '复制失败，可在「在原平台打开」后手动复制。');
    }
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  static String _fmtMaybe(int? n) {
    if (n == null) return '点赞';
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

/// 互动条的胶囊按钮。
class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.busy = false,
    this.enabled = true,
    this.disabledReason,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
  final bool busy;
  final bool enabled;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final color = active ? (activeColor ?? c.blue) : c.secondaryLabel;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (busy) return;
        if (!enabled) {
          if (disabledReason != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(disabledReason!),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.md,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: active
              ? (activeColor ?? c.blue).withValues(alpha: 0.10)
              : c.fill,
          borderRadius: BorderRadius.circular(AppleRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: color,
                ),
              )
            else
              Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppleType.footnote.copyWith(
                color: active ? color : c.label,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 关注按钮（平台接口实测支持写入时才渲染）。
class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.ctrl});

  final InteractionController ctrl;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (!ctrl.canFollowAuthor) return const SizedBox.shrink();
        final following = ctrl.state.following;
        return GestureDetector(
          onTap: ctrl.followPending ? null : ctrl.toggleFollowAuthor,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpace.lg,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: following ? c.fill : c.pink,
              borderRadius: BorderRadius.circular(AppleRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ctrl.followPending)
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: Colors.white,
                    ),
                  )
                else if (following)
                  const Icon(Icons.check_rounded, size: 13, color: Colors.white)
                else
                  const Icon(Icons.add_rounded, size: 13, color: Colors.white),
                const SizedBox(width: 4),
                Text(
                  following ? '已关注' : '关注',
                  style: AppleType.footnote.copyWith(
                    color: following ? c.secondaryLabel : Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 毛玻璃返回按钮。
class _GlassBackButton extends StatelessWidget {
  const _GlassBackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppleSpace.sm),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 播放器内的胶囊按钮。
class _PlayerPillButton extends StatelessWidget {
  const _PlayerPillButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.lg,
          vertical: AppleSpace.sm,
        ),
        decoration: BoxDecoration(
          color: filled ? Colors.white : Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppleRadius.pill),
        ),
        child: Text(
          label,
          style: AppleType.buttonSmall.copyWith(
            fontSize: 13,
            color: filled ? Colors.black : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 低频动作的文字按钮（无底色、小号）。
///
/// 与 [_PillAction] 的区别是**视觉权重**：稍后再看 / 分享一天用不了几次，
/// 做成带底色的胶囊会和点赞/收藏抢注意力，还会把主操作挤到第二行。
class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: active ? c.blue : c.secondaryLabel),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppleType.footnote.copyWith(
                color: active ? c.blue : c.secondaryLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
