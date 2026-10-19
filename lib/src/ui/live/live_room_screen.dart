/// B 站直播间：播放 + 实时弹幕。
///
/// # 与普通视频播放的边界
///
/// 直播**不**复用 `FusionPlayerController`：
///  - 直播没有总时长、不能 seek、不能倍速
///  - 断流要靠重连而不是 seek(0)
///  - 状态机不同（buffering / reconnecting）
///
/// 因此这里直接用 media_kit 的 `Player`，独立管理状态。
/// 退出时显式释放播放器与弹幕连接，避免后台继续拉流。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../adapters/bilibili_live_interaction.dart';
import '../../adapters/platform_adapter.dart';
import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/live_danmaku.dart';
import '../../core/logger.dart';
import '../../design/apple_tokens.dart';
import '../../models/live.dart';

class LiveRoomScreen extends StatefulWidget {
  const LiveRoomScreen({
    super.key,
    required this.adapter,
    required this.vault,
    required this.roomKey,
    this.initialTitle,
    this.initialUname,
    this.onOpenOriginal,
  });

  final PlatformAdapter adapter;

  /// 凭证保险库。互动写操作需要从这里读登录会话。
  final CredentialVault vault;

  /// 跨平台房间标识（字符串）。
  ///
  /// B站是数字房间号；抖音是 19 位长整型字符串，**不能**用 int 承载。
  final String roomKey;

  final String? initialTitle;
  final String? initialUname;

  /// 兜底：在原平台打开该直播间。
  final VoidCallback? onOpenOriginal;

  @override
  State<LiveRoomScreen> createState() => _LiveRoomScreenState();
}

class _LiveRoomScreenState extends State<LiveRoomScreen> {
  // ── 播放 ────────────────────────────────────────────────────
  Player? _player;
  VideoController? _videoController;

  // ── 数据 ────────────────────────────────────────────────────
  LiveRoomInfo? _info;
  LiveStream? _stream;
  FusionException? _error;
  bool _loading = true;

  // ── 弹幕 ────────────────────────────────────────────────────
  LiveDanmakuClient? _danmaku;
  final List<LiveMessage> _messages = [];
  DanmakuConnectionState _danmakuState = DanmakuConnectionState.idle;

  /// 消息列表上限。直播弹幕量大，保留最近 200 条即可，
  /// 超出丢弃最旧的，避免内存无限增长。
  static const int _maxMessages = 200;

  /// 消息更新节流：弹幕高频到达时不要每条都 setState，
  /// 否则 1 秒几十条会把 UI 线程打满。
  Timer? _flushTimer;
  bool _pendingFlush = false;

  /// 是否横屏全屏观看。
  bool _fullscreen = false;

  bool _showDanmakuOverlay = true;
  bool _showChat = true;

  /// 播放器状态的文字快照（用于"卡住 vs 停播"的可读提示）。
  String _playerState = 'unknown';

  // ── 互动 ────────────────────────────────────────────────────
  //
  // 能力边界（实测 2026-10-18）：
  //  - B站点赞/关注/发弹幕路径都存在，需登录凭证
  //  - 抖音只有 digg/chat 路径存在，且需设备侧签名 → 不渲染按钮

  late final BilibiliLiveInteraction _interaction;

  /// 当前平台的登录会话。null = 未登录。
  PlatformSession? _session;

  final TextEditingController _danmakuCtrl = TextEditingController();

  int _likeCount = 0;
  bool _following = false;
  bool _likeBusy = false;
  bool _followBusy = false;
  bool _danmakuBusy = false;

  @override
  void initState() {
    super.initState();
    _interaction = BilibiliLiveInteraction(
      http: FusionHttpClient(logger: appLogger),
    );
    _loadSession();
    _load();
  }

  /// 读取当前平台的登录会话。
  ///
  /// 互动写操作全部依赖它。读不到就按未登录处理，
  /// UI 显示"登录后可操作"而不是伪造"已点赞"。
  Future<void> _loadSession() async {
    try {
      final session = await widget.vault
          .load(widget.adapter.id)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() => _session = session);
    } catch (_) {
      if (!mounted) return;
      setState(() => _session = null);
    }
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _danmakuCtrl.dispose();
    _playbackSubs.clear();
    _danmaku?.dispose();
    // State.dispose 是同步的，播放器释放 fire-and-forget。
    // [_releasePlayer] 第一步就把 _player 置 null，因此不会二次释放。
    unawaited(_releasePlayer());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 1. 房间信息
      final info =
          await widget.adapter.fetchLiveRoomInfoByKey(widget.roomKey);
      if (!mounted) return;
      setState(() => _info = info);

      if (!info.isLive) {
        setState(() {
          _loading = false;
          _error = FusionException(
            code: FusionErrorCode.capabilityUnavailable,
            userMessage: '主播尚未开播（${info.statusLabel}）。',
            technicalMessage: 'live_status=${info.liveStatus}',
            platformId: widget.adapter.id,
            retryable: true,
          );
        });
        return;
      }

      // 2. 播放流
      final stream =
          await widget.adapter.resolveLiveStreamByKey(widget.roomKey);
      if (!mounted) return;
      setState(() {
        _stream = stream;
        _loading = false;
      });

      await _startPlayback(stream);

      // 3. 弹幕（失败不影响播放；抖音暂不支持，会抛 unsupportedPlatform）
      unawaited(_startDanmaku());
    } on FusionException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = normalizeError(e, platformId: widget.adapter.id);
        _loading = false;
      });
    }
  }

  Future<void> _startPlayback(LiveStream stream) async {
    // 先释放上一个播放器：从直播列表进 A 房间、返回、再进 B 房间时，
    // 若不释放，A 的拉流仍在后台运行 → 音频残留 + 两个播放器同时出声。
    await _releasePlayer();

    final player = Player();
    final controller = VideoController(player);
    _player = player;
    _videoController = controller;
    _watchPlayback(player);

    try {
      // 直播流需要 Referer，否则 CDN 403。
      //
      // **必须按平台取**：B站 CDN 认 live.bilibili.com，
      // 抖音 CDN 认 live.douyin.com。之前这里硬编码 B站 referer，
      // 等于所有平台的流都带同一个来源头 —— 抖音房间能出画面是
      // 侥幸（部分 CDN 节点不校验），不是实现正确。
      // 为什么还要带 User-Agent：
      //
      // 实测（2026-10-19）抖音直播 HLS 分片用 App UA 打是 HTTP 206
      // 且能拿到完整 TS；而 media_kit/libmpv 的默认 UA 在部分
      // douyincdn 节点上会拿到 `HTTP 200 + 空 body`。播放器初始化
      // 成功、地址也确实有效，但取不到分片 —— 表现就是"画面全黑
      // 且没有任何报错"。这是直播黑屏目前最可能的成因
      // （HEVC 解码已被排除：同源解码器 ffmpeg 能完整解出非黑帧，
      // 模拟器也有 c2.goldfish.hevc.decoder / OMX.google.hevc.decoder）。
      await player.open(
        Media(
          stream.url,
          httpHeaders: _streamHeaders(stream),
        ),
        play: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '直播流打开失败，可能是地址已过期。',
          technicalMessage: 'open failed: $e',
          platformId: widget.adapter.id,
          retryable: true,
        );
      });
    }
  }

  /// 拉流请求头。
  ///
  /// 优先用适配器随流给出的 [LiveStream.requestHeaders] —— 该带什么头
  /// 是平台知识，应由平台适配器决定，UI 不做平台判断。
  ///
  /// 未给出时（适配器还没填这个字段）退化为"只带 Referer"。
  /// 这条兜底是**临时**的：适配器补齐 requestHeaders 后就不会走到，
  /// 不要把它当长期设计。
  Map<String, String> _streamHeaders(LiveStream stream) {
    if (stream.requestHeaders.isNotEmpty) {
      return Map<String, String>.from(stream.requestHeaders);
    }
    return {'Referer': _refererFallback()};
  }

  /// 兜底 Referer（按平台）。
  ///
  /// 只在适配器没给 [LiveStream.requestHeaders] 时用到。
  /// B站 CDN 认 live.bilibili.com，抖音 CDN 认 live.douyin.com；
  /// 原来这里对所有平台硬编码 B站来源，抖音房间能出画面只是
  /// 部分节点不校验的侥幸。
  String _refererFallback() => switch (widget.adapter.id) {
        'douyin' => 'https://live.douyin.com/',
        _ => 'https://live.bilibili.com/',
      };

  /// 释放播放器（幂等）。
  Future<void> _releasePlayer() async {
    final p = _player;
    _player = null;
    _videoController = null;
    if (p == null) return;
    try {
      await p.stop();
    } catch (_) {
      // stop 失败也要 dispose，否则句柄泄漏
    }
    try {
      await p.dispose();
    } catch (_) {}
  }

  Future<void> _startDanmaku() async {
    // 弹幕端点只对 B站 有效（B站房间号是数字）。
    // 抖音等平台返回 unsupportedPlatform，此时不进入连接流程，
    // UI 依据 _danmakuUnsupported 隐藏弹幕区，而不是显示"连接中"。
    final numericRoom = int.tryParse(widget.roomKey);
    if (numericRoom == null) {
      if (mounted) {
        setState(() => _danmakuState = DanmakuConnectionState.idle);
      }
      return;
    }

    try {
      final endpoint =
          await widget.adapter.fetchLiveDanmakuEndpoint(numericRoom);
      if (!mounted) return;

      final client = LiveDanmakuClient();
      _danmaku = client;

      client.connectionState.listen((s) {
        if (mounted) setState(() => _danmakuState = s);
      });

      client.messages.listen(_onMessage);

      await client.connect(endpoint);
    } catch (e) {
      // 弹幕连不上不影响看直播
      if (mounted) {
        setState(() => _danmakuState = DanmakuConnectionState.failed);
      }
    }
  }

  void _onMessage(LiveMessage m) {
    _messages.add(m);
    if (_messages.length > _maxMessages) {
      _messages.removeRange(0, _messages.length - _maxMessages);
    }
    _scheduleFlush();
  }

  /// 节流刷新：最多每 250ms 重建一次消息列表。
  void _scheduleFlush() {
    if (_pendingFlush) return;
    _pendingFlush = true;
    _flushTimer ??= Timer(const Duration(milliseconds: 250), () {
      _pendingFlush = false;
      if (mounted) setState(() {});
    });
  }

  Future<void> _reconnect() async {
    // 完整释放再重建：只 dispose 播放器不够，
    // 弹幕连接与消息列表也要清空，否则重连后旧房间的弹幕仍在屏上。
    for (final s in _playbackSubs) {
      await s.cancel();
    }
    _playbackSubs.clear();
    await _releasePlayer();
    await _danmaku?.dispose();
    _danmaku = null;
    _messages.clear();
    if (mounted) {
      setState(() {
        _error = null;
        _stream = null;
      });
    }
    await _load();
  }

  // ── 播放状态监听：下播 / 断流 / 失败 ─────────────────────────
  //
  // 直播是持续拉流，"打开成功"不等于"能一直看"。主播下播、CDN
  // 地址过期（抖音的播放地址带 expire/sign）、网络中断都会表现为
  // 播放器事件，而不是 HTTP 错误。不监听这些事件的话，用户看到的是
  // 一帧静止画面 —— 他无法判断是卡了还是下播了。

  final List<StreamSubscription<Object?>> _playbackSubs = [];

  void _watchPlayback(Player player) {
    for (final s in _playbackSubs) {
      s.cancel();
    }
    _playbackSubs.clear();

    // 播放结束：直播正常不会 completed=true；出现即流被关闭（下播/地址过期）
    _playbackSubs.add(
      player.stream.completed.listen((done) {
        if (!mounted || !done) return;
        setState(() {
          _error = FusionException(
            code: FusionErrorCode.capabilityUnavailable,
            userMessage: '直播已结束或流地址已过期，可尝试重新进入。',
            technicalMessage: 'player completed (stream closed)',
            platformId: widget.adapter.id,
            retryable: true,
          );
        });
      }),
    );

    // 播放态变化：用户在直播里没暂停键，playing=false 且不是 completed
    // 时，通常是断流或缓冲耗尽 —— 必须可见，否则用户盯着一帧静止画面。
    _playbackSubs.add(
      player.stream.playing.listen((playing) {
        if (!mounted) return;
        setState(() => _playerState = playing ? 'playing' : 'stopped');
      }),
    );

    // 缓冲态：单独提示"正在缓冲"，与"已结束"区分开
    _playbackSubs.add(
      player.stream.buffering.listen((buffering) {
        if (!mounted) return;
        setState(() => _playerState = buffering ? 'buffering' : 'ready');
      }),
    );

    // 错误事件：直接呈现，不静默
    _playbackSubs.add(
      player.stream.error.listen((message) {
        if (!mounted) return;
        setState(() {
          _error = FusionException(
            code: FusionErrorCode.networkError,
            userMessage: '直播流中断，可能是网络或主播侧问题。',
            technicalMessage: 'player error: $message',
            platformId: widget.adapter.id,
            retryable: true,
          );
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 横竖屏由**房间真实数据**决定，不是猜：
    //  - 抖音直播大量是竖屏（feed 的 `orientation` 字段），B站以横屏为主
    //  - 竖屏房间用 9:16，横屏用 16:9，否则竖屏画面被压成小条
    //  - 用户手动全屏时固定 16:9（沉浸观看）
    final portrait = (_info?.isPortrait ?? false) && !_fullscreen;

    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildPlayerArea(),
            // 全屏时保留返回与状态：直播没有"进度条"可拖，
            // 但必须能退出全屏，否则用户被困在画面里。
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(AppleSpace.sm),
                  child: GestureDetector(
                    onTap: _toggleFullscreen,
                    child: const _LiveExitFullscreenButton(),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            // 播放区（按房间真实朝向选比例）
            AspectRatio(
              aspectRatio: portrait ? 9 / 16 : 16 / 9,
              child: _buildPlayerArea(),
            ),
            // 信息条
            if (_info != null) _buildInfoBar(),
            // 消息列表
            Expanded(child: _buildChat()),
          ],
        ),
      ),
    );
  }

  /// 全屏切换。
  ///
  /// 进入全屏时同时隐藏系统 UI，退出时恢复 —— 直播是"看画面"的场景，
  /// 状态栏占的那一条在横屏时尤其碍事。
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

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppleSpace.sm),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
          Expanded(
            child: Text(
              _info?.title ?? widget.initialTitle ?? '直播间',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppleType.headline.copyWith(color: Colors.white),
            ),
          ),
          // 全屏（横屏观看）
          IconButton(
            onPressed: _toggleFullscreen,
            icon: const Icon(
              Icons.fullscreen_rounded,
              color: Colors.white,
              size: 20,
            ),
            tooltip: '全屏',
          ),
          // 弹幕开关
          IconButton(
            onPressed: () =>
                setState(() => _showDanmakuOverlay = !_showDanmakuOverlay),
            icon: Icon(
              _showDanmakuOverlay
                  ? Icons.subtitles_rounded
                  : Icons.subtitles_off_rounded,
              color: _showDanmakuOverlay ? Colors.white : Colors.white38,
              size: 20,
            ),
            tooltip: '弹幕开关',
          ),
          IconButton(
            onPressed: _reconnect,
            icon: const Icon(
              Icons.refresh_rounded,
              color: Colors.white,
              size: 20,
            ),
            tooltip: '重连',
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerArea() {
    if (_loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppleSpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.videocam_off_outlined,
                  color: Colors.white38,
                  size: 32,
                ),
                const SizedBox(height: AppleSpace.sm),
                Text(
                  _error!.userMessage,
                  textAlign: TextAlign.center,
                  style: AppleType.footnote.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: AppleSpace.md),
                TextButton(
                  onPressed: _reconnect,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final controller = _videoController;
    if (controller == null) {
      return const ColoredBox(color: Colors.black);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Video(
          controller: controller,
          controls: NoVideoControls,
          // 竖屏房间（抖音直播大量是竖屏）用 cover 填满，
          // 横屏内容在竖屏布局里用 contain 保持比例不裁切。
          fit: (_info?.isPortrait ?? false) ? BoxFit.cover : BoxFit.contain,
        ),
        // 弹幕覆盖层（从消息流里取 chat 类型，横向滚动）
        if (_showDanmakuOverlay)
          Positioned.fill(
            child: IgnorePointer(
              child: _DanmakuOverlay(messages: _messages),
            ),
          ),
      ],
    );
  }

  Widget _buildInfoBar() {
    final info = _info!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.md,
        vertical: AppleSpace.sm,
      ),
      color: const Color(0xFF1C1C1E),
      child: Row(
        children: [
          // 直播状态
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: info.isLive
                  ? const Color(0xFFFF3B30)
                  : const Color(0xFF3A3A3C),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              info.statusLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: AppleSpace.sm),
          Expanded(
            child: Text(
              widget.initialUname ?? info.areaName ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppleType.caption1.copyWith(color: Colors.white70),
            ),
          ),
          if (info.online != null)
            Text(
              '人气 ${_fmt(info.online!)}',
              style: AppleType.caption2.copyWith(color: Colors.white54),
            ),
          // 只显示清晰度，不显示协议名（HLS/FLV 是技术细节，
          // 普通观众只关心"画质怎么样"）。
          if (_stream != null) ...[
            const SizedBox(width: AppleSpace.sm),
            Text(
              _stream!.qualityLabel,
              style: AppleType.caption2.copyWith(color: Colors.white38),
            ),
          ],
          // 播放推进状态：直播没有进度条，用户无法区分"卡住在缓冲"
          // 与"已经停播"。这里把他看得见的东西说出来。
          if (_error == null && _playerState != 'ready') ...[
            const SizedBox(width: AppleSpace.sm),
            Text(
              switch (_playerState) {
                'buffering' => '缓冲中',
                'playing' => '直播中',
                'stopped' => '已停止',
                _ => '',
              },
              style: AppleType.caption2.copyWith(color: Colors.white38),
            ),
          ],
          const SizedBox(width: AppleSpace.sm),
          // 弹幕连接状态
          _DanmakuStatusDot(state: _danmakuState),
        ],
      ),
    );
  }

  Widget _buildChat() {
    if (!_showChat) return const SizedBox.shrink();

    // 消息区 + 底部互动栏
    return Container(
      color: const Color(0xFF121212),
      child: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _buildChatPlaceholder()
                : ListView.builder(
                    // 反向列表：最新消息在底部，且自动跟随
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppleSpace.md,
                      vertical: AppleSpace.sm,
                    ),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final m = _messages[_messages.length - 1 - index];
                      return _ChatLine(
                        key: ValueKey(
                            '${m.receivedAt.microsecondsSinceEpoch}_$index'),
                        message: m,
                      );
                    },
                  ),
          ),
          _buildInteractionBar(),
        ],
      ),
    );
  }

  /// 消息区为空时的说明。
  ///
  /// 抖音直播没有可用弹幕端点，B站未登录也拿不到 token。
  /// 这里**如实说明原因**，不放假弹幕、不显示"连接中"。
  Widget _buildChatPlaceholder() {
    final reason = widget.adapter.id == 'douyin'
        ? '抖音直播暂不提供弹幕'
        : (_danmakuState == DanmakuConnectionState.failed
            ? '弹幕连接失败（需要登录）'
            : '暂无弹幕');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppleSpace.lg),
        child: Text(
          reason,
          textAlign: TextAlign.center,
          style: AppleType.footnote.copyWith(color: Colors.white38),
        ),
      ),
    );
  }

  /// 底部互动栏：点赞 / 关注 / 发弹幕。
  ///
  /// 能力边界（实测）：
  ///  - B站：点赞、关注、发弹幕**路径都存在**，需要登录凭证
  ///  - 抖音：`digg`/`chat` 路径存在但需签名，其余路径不存在
  ///
  /// 因此：
  ///  - B站显示全部三个入口，未登录时点击引导登录
  ///  - 抖音只显示"点赞"（digg 路径存在），且未登录时如实说明
  ///  - **不渲染注定失败的按钮**
  Widget _buildInteractionBar() {
    final isDouyin = widget.adapter.id == 'douyin';
    final loggedIn = _session != null;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.md,
        vertical: AppleSpace.sm,
      ),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // 点赞
          _InteractionButton(
            icon: Icons.favorite_rounded,
            label: _likeCount > 0 ? '$_likeCount' : '点赞',
            active: _likeCount > 0,
            activeColor: const Color(0xFFFF3B30),
            busy: _likeBusy,
            onTap: () => _doLike(isDouyin: isDouyin, loggedIn: loggedIn),
          ),
          const SizedBox(width: AppleSpace.lg),

          // 关注（抖音无可用接口，不显示）
          if (!isDouyin)
            _InteractionButton(
              icon: _following ? Icons.person_rounded : Icons.person_add_rounded,
              label: _following ? '已关注' : '关注',
              active: _following,
              busy: _followBusy,
              onTap: () => _doFollow(loggedIn: loggedIn),
            ),
          if (!isDouyin) const SizedBox(width: AppleSpace.lg),

          // 发弹幕输入框（仅 B站；抖音无可用端点）
          if (!isDouyin)
            Expanded(
              child: _buildDanmakuInput(loggedIn: loggedIn),
            )
          else
            Expanded(
              child: Text(
                '抖音直播暂不支持互动',
                style: AppleType.caption1.copyWith(color: Colors.white38),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDanmakuInput({required bool loggedIn}) {
    return SizedBox(
      height: 34,
      child: TextField(
        controller: _danmakuCtrl,
        enabled: loggedIn,
        maxLength: 20,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _sendDanmaku(),
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          counterText: '',
          isDense: true,
          hintText: loggedIn ? '发个弹幕…' : '登录后可发弹幕',
          hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
          filled: true,
          fillColor: const Color(0x14FFFFFF),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppleSpace.md,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(17),
            borderSide: BorderSide.none,
          ),
          suffixIcon: loggedIn
              ? IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _danmakuBusy ? null : _sendDanmaku,
                  icon: _danmakuBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: Colors.white54,
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          size: 16,
                          color: Colors.white54,
                        ),
                )
              : null,
        ),
      ),
    );
  }

  // ── 互动动作 ────────────────────────────────────────────────

  Future<void> _doLike({
    required bool isDouyin,
    required bool loggedIn,
  }) async {
    if (_likeBusy) return;

    if (isDouyin) {
      // 抖音 digg 路径存在但需设备侧签名，未实现
      _toast('抖音直播点赞需要设备签名，暂未实现');
      return;
    }

    if (!loggedIn) {
      _toast('请先登录哔哩哔哩账号');
      return;
    }

    setState(() => _likeBusy = true);
    try {
      final r = await _interaction.like(
        roomId: _numericRoomId,
        session: _session!,
      );
      if (!mounted) return;
      if (r.ok) {
        setState(() => _likeCount += 1);
      } else {
        _toast(r.message);
      }
    } on FusionException catch (e) {
      if (mounted) _toast(e.userMessage);
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  Future<void> _doFollow({required bool loggedIn}) async {
    if (_followBusy) return;
    if (!loggedIn) {
      _toast('请先登录哔哩哔哩账号');
      return;
    }
    final anchorUid = _info?.uid ?? 0;
    if (anchorUid <= 0) {
      _toast('拿不到主播信息，暂时无法关注');
      return;
    }

    setState(() => _followBusy = true);
    try {
      final target = !_following;
      final r = await _interaction.follow(
        uid: anchorUid,
        follow: target,
        session: _session!,
      );
      if (!mounted) return;
      if (r.ok) {
        setState(() => _following = target);
      } else {
        _toast(r.message);
      }
    } on FusionException catch (e) {
      if (mounted) _toast(e.userMessage);
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _sendDanmaku() async {
    if (_danmakuBusy) return;
    final text = _danmakuCtrl.text.trim();
    if (text.isEmpty) return;

    if (_session == null) {
      _toast('请先登录哔哩哔哩账号');
      return;
    }

    setState(() => _danmakuBusy = true);
    try {
      final r = await _interaction.sendDanmaku(
        roomId: _numericRoomId,
        message: text,
        session: _session!,
      );
      if (!mounted) return;
      if (r.ok) {
        _danmakuCtrl.clear();
        _toast('已发送');
      } else {
        _toast(r.message);
      }
    } on FusionException catch (e) {
      if (mounted) _toast(e.userMessage);
    } finally {
      if (mounted) setState(() => _danmakuBusy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 数字房间号。B站房间号是数字；抖音不是数字时返回 0，
  /// 调用方据此避免发起无效写请求。
  int get _numericRoomId => int.tryParse(widget.roomKey) ?? 0;

  static String _fmt(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

/// 直播互动按钮（图标 + 文字/计数）。
class _InteractionButton extends StatelessWidget {
  const _InteractionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = active ? (activeColor ?? Colors.white) : Colors.white70;
    return GestureDetector(
      onTap: busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Colors.white54,
                  ),
                )
              : Icon(icon, size: 20, color: color),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: color, height: 1.2),
          ),
        ],
      ),
    );
  }
}

/// 弹幕连接状态指示点。
class _DanmakuStatusDot extends StatelessWidget {
  const _DanmakuStatusDot({required this.state});

  final DanmakuConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      DanmakuConnectionState.connected => (const Color(0xFF34C759), '弹幕已连接'),
      DanmakuConnectionState.connecting => (const Color(0xFFFF9F0A), '连接中'),
      DanmakuConnectionState.reconnecting => (const Color(0xFFFF9F0A), '重连中'),
      DanmakuConnectionState.failed => (const Color(0xFFFF3B30), '弹幕断开'),
      _ => (Colors.white24, '弹幕未连接'),
    };

    return Tooltip(
      message: label,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 一条聊天消息。
class _ChatLine extends StatelessWidget {
  const _ChatLine({super.key, required this.message});

  final LiveMessage message;

  @override
  Widget build(BuildContext context) {
    final m = message;

    // 系统消息：居中灰字
    if (m.type == LiveMessageType.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          m.text,
          style: AppleType.caption2.copyWith(color: const Color(0xFFFF9F0A)),
        ),
      );
    }

    // 礼物：高亮
    if (m.type == LiveMessageType.gift) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          m.text,
          style: AppleType.caption1.copyWith(
            color: const Color(0xFFFFD60A),
            height: 1.35,
          ),
        ),
      );
    }

    // 进场：淡
    if (m.type == LiveMessageType.memberEnter) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          m.text,
          style: AppleType.caption2.copyWith(color: Colors.white38),
        ),
      );
    }

    // 普通弹幕：昵称 + 内容
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(
        TextSpan(
          children: [
            if (m.isAdmin)
              TextSpan(
                text: '[房管] ',
                style: AppleType.caption1.copyWith(
                  color: const Color(0xFFFF3B30),
                  fontWeight: FontWeight.w600,
                ),
              ),
            TextSpan(
              text: '${m.uname ?? '匿名'}：',
              style: AppleType.caption1.copyWith(
                color: const Color(0xFF64D2FF),
              ),
            ),
            TextSpan(
              text: m.text,
              style: AppleType.caption1.copyWith(
                color: Colors.white,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹幕覆盖层。
///
/// 简化实现：把最近若干条普通弹幕以半透明文字叠在画面上方，
/// 不做逐条飞行轨迹（那需要独立的动画调度，且在高消息量下
/// 会与视频解码争抢 UI 线程）。
class _DanmakuOverlay extends StatelessWidget {
  const _DanmakuOverlay({required this.messages});

  final List<LiveMessage> messages;

  @override
  Widget build(BuildContext context) {
    // 只取最近 6 条普通弹幕
    final recent = <LiveMessage>[];
    for (var i = messages.length - 1; i >= 0 && recent.length < 6; i--) {
      if (messages[i].type == LiveMessageType.chat) {
        recent.insert(0, messages[i]);
      }
    }
    if (recent.isEmpty) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(
          left: AppleSpace.md,
          top: AppleSpace.sm,
          right: 80,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    child: Text(
                      m.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        height: 1.3,
                        shadows: [
                          Shadow(blurRadius: 2, color: Colors.black54),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 全屏时的退出按钮（悬浮在画面左上角）。
class _LiveExitFullscreenButton extends StatelessWidget {
  const _LiveExitFullscreenButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.fullscreen_exit_rounded,
        size: 18,
        color: Colors.white,
      ),
    );
  }
}
