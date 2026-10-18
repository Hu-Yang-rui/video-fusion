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
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../adapters/platform_adapter.dart';
import '../../core/errors.dart';
import '../../core/live_danmaku.dart';
import '../../design/apple_tokens.dart';
import '../../models/live.dart';

class LiveRoomScreen extends StatefulWidget {
  const LiveRoomScreen({
    super.key,
    required this.adapter,
    required this.roomKey,
    this.initialTitle,
    this.initialUname,
    this.onOpenOriginal,
  });

  final PlatformAdapter adapter;

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

  bool _showDanmakuOverlay = true;
  bool _showChat = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _danmaku?.dispose();
    _player?.dispose();
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
    final player = Player();
    final controller = VideoController(player);
    _player = player;
    _videoController = controller;

    try {
      // 直播流需要 Referer，否则 CDN 可能 403
      await player.open(
        Media(
          stream.url,
          httpHeaders: const {'Referer': 'https://live.bilibili.com/'},
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
          platformId: 'bilibili',
          retryable: true,
        );
      });
    }
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
    await _player?.dispose();
    _player = null;
    _videoController = null;
    await _danmaku?.dispose();
    _danmaku = null;
    _messages.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            // 播放区
            AspectRatio(
              aspectRatio: 16 / 9,
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
          fit: BoxFit.contain,
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
          const SizedBox(width: AppleSpace.sm),
          // 弹幕连接状态
          _DanmakuStatusDot(state: _danmakuState),
        ],
      ),
    );
  }

  Widget _buildChat() {
    if (!_showChat) return const SizedBox.shrink();

    return Container(
      color: const Color(0xFF121212),
      child: ListView.builder(
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
            key: ValueKey('${m.receivedAt.microsecondsSinceEpoch}_$index'),
            message: m,
          );
        },
      ),
    );
  }

  static String _fmt(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
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
