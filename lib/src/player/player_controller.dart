/// 播放控制器：把统一播放源接入 media_kit（libmpv）内核。
///
/// 职责边界（严格遵守需求 5.5）：
///  - 本文件只负责**播放内核的技术接入**与状态暴露。
///  - 播放器**外围 UI**（控制条、状态提示、错误、重试）由
///    `lib/src/ui/player/player_view.dart` 自行绘制，不使用任何现成播放器皮肤。
///  - 只为当前播放模式**实际支持**的能力暴露控制项，不虚构倍速/清晰度等能力。
///
/// 关于"APP 内播放"的实现方式：
///  - 使用 media_kit（libmpv）原生内核在应用窗口内直接解码播放。
///  - **不嵌入任何平台网页，不使用 WebView，不调用平台播放器 SDK。**
///  - B 站 DASH 分离流：视频轨与音频轨分别以直链加载，由本内核自行合成。
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/logger.dart';
import '../models/playback.dart';

/// 播放器运行状态（供外围 UI 渲染）。
enum PlayerPhase {
  /// 尚未加载任何媒体。
  idle,

  /// 正在解析/加载播放地址。
  loading,

  /// 已就绪，等待播放指令。
  ready,

  /// 正在缓冲。
  buffering,

  /// 正在播放。
  playing,

  /// 已暂停。
  paused,

  /// 播放结束。
  completed,

  /// 加载或播放失败。
  failed,
}

/// 播放器对外暴露的状态快照。
class PlayerSnapshot {
  const PlayerSnapshot({
    required this.phase,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.isBuffering,
    required this.errorMessage,
    required this.errorDetail,
    required this.videoWidth,
    required this.videoHeight,
    required this.volume,
  });

  final PlayerPhase phase;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool isBuffering;
  final String? errorMessage;
  final String? errorDetail;
  final int? videoWidth;
  final int? videoHeight;
  final double volume;

  static const PlayerSnapshot initial = PlayerSnapshot(
    phase: PlayerPhase.idle,
    position: Duration.zero,
    duration: Duration.zero,
    buffered: Duration.zero,
    isBuffering: false,
    errorMessage: null,
    errorDetail: null,
    videoWidth: null,
    videoHeight: null,
    volume: 100,
  );

  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  bool get hasError => phase == PlayerPhase.failed;

  PlayerSnapshot copyWith({
    PlayerPhase? phase,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? isBuffering,
    String? errorMessage,
    String? errorDetail,
    bool clearError = false,
    int? videoWidth,
    int? videoHeight,
    double? volume,
  }) =>
      PlayerSnapshot(
        phase: phase ?? this.phase,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        buffered: buffered ?? this.buffered,
        isBuffering: isBuffering ?? this.isBuffering,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        errorDetail: clearError ? null : (errorDetail ?? this.errorDetail),
        videoWidth: videoWidth ?? this.videoWidth,
        videoHeight: videoHeight ?? this.videoHeight,
        volume: volume ?? this.volume,
      );
}

/// 播放控制器。
///
/// 使用方式：
/// ```dart
/// final controller = FusionPlayerController();
/// await controller.load(source);
/// // UI 侧监听 controller.stream
/// ```
class FusionPlayerController {
  FusionPlayerController({FusionLogger? logger})
      : _logger = logger ?? appLogger {
    _player = Player();
    _attach();
  }

  final FusionLogger _logger;
  late final Player _player;

  final StreamController<PlayerSnapshot> _snapshots =
      StreamController<PlayerSnapshot>.broadcast();

  PlayerSnapshot _snapshot = PlayerSnapshot.initial;

  /// 当前加载的播放源；null 表示尚未加载。
  PlaybackSource? _source;

  final List<StreamSubscription<Object?>> _subs = [];

  /// 状态流。外围 UI 监听此流进行渲染。
  Stream<PlayerSnapshot> get stream => _snapshots.stream;

  PlayerSnapshot get snapshot => _snapshot;

  PlaybackSource? get source => _source;

  /// 底层 media_kit Player，仅供 video 渲染组件绑定使用。
  /// **不得**在 UI 层调用它来绕过本控制器的状态管理。
  Player get rawPlayer => _player;

  /// 视频输出配置。
  ///
  /// 保持 media_kit 的默认 `gpu` 渲染路径。
  ///
  /// 实测结论（2026-10，Android 模拟器 Pixel 7 / API 35）：
  ///  - `gpu`（默认）：元数据解析正常、Surface 创建成功、
  ///    position 能前进，但模拟器软件渲染下画面无法合成上屏。
  ///  - `gpu-next`：渲染管线初始化失败，播放立即进入 completed。
  ///  - `mediacodec_embed`：position 前进但画面黑屏，
  ///    因为它要求 Flutter 端直接桥接 Android Surface，
  ///    与 `Video` widget 的纹理路径不兼容。
  ///
  /// 因此保留默认 `gpu`。模拟器黑屏是环境限制，真机正常。
  VideoControllerConfiguration get videoConfiguration =>
      const VideoControllerConfiguration();

  /// 当前播放模式实际支持的能力。外围 UI 据此决定显示哪些控件。
  PlayerCapabilities get capabilities => _capabilities;

  PlayerCapabilities _capabilities = PlayerCapabilities.none;

  void _attach() {
    _subs.add(_player.stream.playing.listen((playing) {
      if (_snapshot.phase == PlayerPhase.failed) return;
      _emit(_snapshot.copyWith(
        phase: playing ? PlayerPhase.playing : PlayerPhase.paused,
      ));
    }));

    _subs.add(_player.stream.position.listen((pos) {
      _emit(_snapshot.copyWith(position: pos));
    }));

    _subs.add(_player.stream.duration.listen((dur) {
      _emit(_snapshot.copyWith(duration: dur));
    }));

    _subs.add(_player.stream.buffer.listen((buf) {
      _emit(_snapshot.copyWith(buffered: buf));
    }));

    _subs.add(_player.stream.buffering.listen((buffering) {
      if (_snapshot.phase == PlayerPhase.failed) return;
      _emit(_snapshot.copyWith(isBuffering: buffering));
    }));

    _subs.add(_player.stream.completed.listen((done) {
      if (done && _snapshot.phase != PlayerPhase.failed) {
        _emit(_snapshot.copyWith(phase: PlayerPhase.completed));
      }
    }));

    _subs.add(_player.stream.width.listen((w) {
      _emit(_snapshot.copyWith(videoWidth: w));
    }));

    _subs.add(_player.stream.height.listen((h) {
      _emit(_snapshot.copyWith(videoHeight: h));
    }));

    _subs.add(_player.stream.volume.listen((v) {
      _emit(_snapshot.copyWith(volume: v));
    }));

    // 内核错误：如实上报，不静默吞掉
    _subs.add(_player.stream.error.listen((err) {
      _logger.warn('player kernel error', {'detail': err});
      _emit(_snapshot.copyWith(
        phase: PlayerPhase.failed,
        errorMessage: '播放失败',
        errorDetail: _humanizeKernelError(err),
      ));
    }));
  }

  /// 加载统一播放源。
  ///
  /// 只接受 [NativePlaybackSource]：本系统的应用内播放路径。
  /// 其它模式由外围 UI 分别处理（官方嵌入 / 跳转原平台），
  /// 不会走到这里，也不会被伪装成应用内播放。
  Future<void> load(NativePlaybackSource source) async {
    _source = source;
    _capabilities = PlayerCapabilities.forNative(source);
    _emit(_snapshot.copyWith(
      phase: PlayerPhase.loading,
      clearError: true,
      position: Duration.zero,
      duration: Duration.zero,
    ));

    try {
      // 视频轨：DASH 分离流的视频部分；自带音频时为完整媒体。
      //
      // 主地址可能失效（实测 B 站 CDN 节点单独返回 404），
      // 因此按候选链依次尝试，直到某个地址被内核接受。
      final headers =
          source.requiredHeaders.isEmpty ? null : source.requiredHeaders;
      final videoCandidates = source.allVideoUrls;

      var opened = false;
      Object? lastError;
      for (final url in videoCandidates) {
        try {
          // play:true —— 关键修复。
          //
          // 历史实现用 play:false 再单独调用 play()，但在 DASH 分离流
          // 场景下不可靠：mpv 会停在"已加载未解复用"状态，
          // 表现为 duration 有值但 position 永远为 0、无 vd-/ao- 线程。
          // 直接以 play:true 打开，让 mpv 自行进入解码流程。
          await _player.open(Media(url, httpHeaders: headers), play: true);
          opened = true;
          _logger.info('player: media opened', {
            'host': Uri.tryParse(url)?.host ?? '?',
            'hasAudio': source.audioStreamUrl != null,
          });
          break;
        } catch (e) {
          lastError = e;
          _logger.warn('video url failed, trying fallback', {
            'host': Uri.tryParse(url)?.host ?? '?',
            'error': '$e',
          });
        }
      }

      if (!opened) {
        throw lastError ?? StateError('all video urls failed');
      }

      // ── DASH 分离音轨 ─────────────────────────────────────
      //
      // 实测结论（2026-10，模拟器 + 真机）：
      //  `setAudioTrack` 会触发 mpv 重载播放列表项，**破坏视频轨的
      //  解码状态**（duration 归零、position 不前进、无 vd- 线程）。
      //
      // 因此策略改为：**先让视频轨真正开始播放，再异步挂载音轨**。
      // 挂载后 mpv 会重新起播，此时视频轨已在解码，重载代价可接受；
      // 若挂载失败则保持纯视频播放，并如实提示"无音频"。
      final audioCandidates = source.allAudioUrls;
      if (audioCandidates.isNotEmpty) {
        unawaited(_attachAudioAfterPlayback(audioCandidates));
      }

      _emit(_snapshot.copyWith(phase: PlayerPhase.ready));
    } catch (e) {
      _logger.error('player load failed', {'error': '$e'});
      _emit(_snapshot.copyWith(
        phase: PlayerPhase.failed,
        errorMessage: '无法加载视频',
        errorDetail: _humanizeLoadError(e),
      ));
    }
  }

  /// 视频起播后再挂载音轨。
  ///
  /// 实测教训（2026-10，模拟器 + 真机复现）：
  ///
  /// `setAudioTrack` 内部走 `lock.synchronized(...)`，与 `open()` 争用
  /// 同一把锁。若在 open 尚未完全释放时挂载音轨，命令会被排队，
  /// 表现为 duration 有值但 position 恒为 0、进程内只有
  /// mpv core/worker 而没有 demux/vd-/ao- 线程。
  ///
  /// 当前 media_kit 公开 API 不暴露 `synchronized: false`，
  /// 因此改用**延后 + 重试**策略：等视频真正开始出帧（position 前进）
  /// 后再挂音轨，此时 open 的锁必然已释放。
  /// 若挂载后检测到视频被打断，则回滚为纯视频播放，保证画面优先。
  Future<void> _attachAudioAfterPlayback(List<String> candidates) async {
    // 等视频真正开始出帧：position 前进才算数（仅 duration 有值不够）
    var playing = false;
    var lastPos = Duration.zero;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (_snapshot.position > lastPos) {
        playing = true;
        break;
      }
      lastPos = _snapshot.position;
    }

    if (!playing) {
      _logger.warn('player: video never advanced, skipping audio attach');
      return;
    }

    final positionBefore = _snapshot.position;
    final durationBefore = _snapshot.duration;

    for (final url in candidates) {
      try {
        await _player.setAudioTrack(AudioTrack.uri(url));
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final broke = _snapshot.duration.inMilliseconds == 0 &&
            durationBefore.inMilliseconds > 0;

        if (broke) {
          // 视频被打断：回滚为纯视频，保证画面优先
          _logger.warn('player: audio attach broke video, rolling back');
          final src = _source;
          if (src is NativePlaybackSource) {
            final headers =
                src.requiredHeaders.isEmpty ? null : src.requiredHeaders;
            await _player.open(
              Media(src.videoStreamUrl, httpHeaders: headers),
              play: true,
            );
            await Future<void>.delayed(const Duration(milliseconds: 500));
            await _player.seek(positionBefore);
          }
          return;
        }

        _logger.info('player: audio track attached', {
          'host': Uri.tryParse(url)?.host ?? '?',
          'durationKept': _snapshot.duration.inMilliseconds,
          'position': _snapshot.position.inMilliseconds,
        });

        if (_snapshot.phase != PlayerPhase.playing) {
          await _player.play();
        }
        return;
      } catch (e) {
        _logger.warn('audio url failed, trying fallback', {
          'host': Uri.tryParse(url)?.host ?? '?',
          'error': '$e',
        });
      }
    }

    _logger.warn('player: all audio tracks failed');
    _emit(_snapshot.copyWith(
      errorMessage: '音频轨加载失败',
      errorDetail: '视频画面可正常播放，但音轨未能挂载。',
    ));
  }

  Future<void> play() async {
    await _player.play();
    var advanced = await _waitForAdvance();

    if (!advanced && _snapshot.phase != PlayerPhase.failed) {
      // 第一层修复：显式 seek(0) 强制 mpv 进入解码流程。
      // 实测中部分 DASH 流首次 open 只完成元数据解析，需要这一步拉起解复用。
      _logger.warn('player: not advancing, trying seek(0)');
      try {
        await _player.seek(Duration.zero);
        await _player.play();
        advanced = await _waitForAdvance();
      } catch (e) {
        _logger.warn('player: seek(0) failed', {'error': '$e'});
      }
    }

    if (!advanced && _snapshot.phase != PlayerPhase.failed) {
      // 第二层修复：重新 open 并直接 play:true，让 mpv 走完整起播路径。
      _logger.warn('player: still not advancing, re-opening media');
      final src = _source;
      if (src is NativePlaybackSource) {
        final headers =
            src.requiredHeaders.isEmpty ? null : src.requiredHeaders;
        try {
          await _player.open(
            Media(src.videoStreamUrl, httpHeaders: headers),
            play: true,
          );
          advanced = await _waitForAdvance();
        } catch (e) {
          _logger.warn('player: re-open failed', {'error': '$e'});
        }
      }
    }

    _logger.info('player: playing', {
      'position': _snapshot.position.inMilliseconds,
      'duration': _snapshot.duration.inMilliseconds,
      'width': _snapshot.videoWidth,
      'height': _snapshot.videoHeight,
      'advanced': advanced,
    });

    // 未起播时输出底层诊断，便于定位是解码器、渲染器还是网络问题。
    if (!advanced) {
      await _logDiagnostics();
    }
  }

  /// 输出 mpv 的底层状态，用于定位"能解析元数据但不出帧"的问题。
  Future<void> _logDiagnostics() async {
    try {
      final tracks = _player.state.tracks;
      _logger.warn('player: diagnostics', {
        'audioTracks': tracks.audio.length,
        'videoTracks': tracks.video.length,
        'subtitleTracks': tracks.subtitle.length,
        'audioSelected': _player.state.track.audio.id,
        'videoSelected': _player.state.track.video.id,
        'buffering': _snapshot.isBuffering,
        'phase': _snapshot.phase.name,
        'paused': !_player.state.playing,
      });

      // 逐个列出轨道，看 mpv 是否真的识别到了音视频流
      for (var i = 0; i < tracks.video.length; i++) {
        final t = tracks.video[i];
        _logger.warn('player: video track $i', {
          'id': t.id,
          'codec': t.codec,
          'w': t.w,
          'h': t.h,
          'fps': t.fps,
        });
      }
      for (var i = 0; i < tracks.audio.length; i++) {
        final t = tracks.audio[i];
        _logger.warn('player: audio track $i', {
          'id': t.id,
          'codec': t.codec,
          'channels': t.channels,
        });
      }
    } catch (e) {
      _logger.warn('player: diagnostics failed', {'error': '$e'});
    }
  }

  /// 等待播放位置前进。返回是否真的前进了。
  Future<bool> _waitForAdvance() async {
    var last = _snapshot.position;
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (_snapshot.position > last) return true;
      if (_snapshot.phase == PlayerPhase.failed) return false;
      last = _snapshot.position;
    }
    return false;
  }

  Future<void> pause() => _player.pause();

  Future<void> playOrPause() => _player.playOrPause();

  /// 跳转。仅在播放源支持 Range 请求时有意义——
  /// 本系统的 B 站 DASH 直链实测支持 Range，故开放此控件。
  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> setVolume(double volume) => _player.setVolume(volume);

  /// 重试：重新加载当前播放源。
  ///
  /// 注意：直链可能已过期，此时需要上层重新解析播放源，
  /// 而不是用旧地址反复重试。上层通过 `_reloadPlayback` 决定。
  Future<void> retry() async {
    final src = _source;
    if (src is! NativePlaybackSource) return;
    await load(src);
  }

  void _emit(PlayerSnapshot next) {
    _snapshot = next;
    if (!_snapshots.isClosed) _snapshots.add(next);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _player.dispose();
    await _snapshots.close();
  }

  static String _humanizeKernelError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('403') || lower.contains('forbidden')) {
      return '视频源拒绝了访问（HTTP 403）。直链可能已过期，请重新获取。';
    }
    if (lower.contains('404') || lower.contains('not found')) {
      return '视频源地址已失效（HTTP 404）。';
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return '连接视频源超时，请检查网络后重试。';
    }
    if (lower.contains('could not resolve') || lower.contains('resolve host')) {
      return '无法解析视频源域名，请检查网络连接。';
    }
    return '播放内核报告错误：$raw';
  }

  static String _humanizeLoadError(Object error) {
    final text = '$error';
    if (text.contains('403')) return '视频源拒绝访问（HTTP 403），直链可能已过期。';
    if (text.contains('404')) return '视频源地址已失效（HTTP 404）。';
    return '加载失败：$text';
  }
}

/// 当前播放模式**实际支持**的能力集合。
///
/// 外围 UI 严格依据此对象决定显示哪些控件，
/// 不得为官方嵌入或跳转模式虚构倍速、清晰度等能力。
class PlayerCapabilities {
  const PlayerCapabilities({
    required this.canSeek,
    required this.canSetVolume,
    required this.canSetRate,
    required this.canSwitchQuality,
    required this.canFullscreen,
    required this.showNativeControls,
  });

  /// 可拖动进度（需要源支持 Range 请求）。
  final bool canSeek;

  /// 可调节音量。
  final bool canSetVolume;

  /// 可调节倍速。
  final bool canSetRate;

  /// 可切换清晰度（需要平台返回多档）。
  final bool canSwitchQuality;

  /// 可全屏。
  final bool canFullscreen;

  /// 是否由本应用自绘控制条。
  final bool showNativeControls;

  static const PlayerCapabilities none = PlayerCapabilities(
    canSeek: false,
    canSetVolume: false,
    canSetRate: false,
    canSwitchQuality: false,
    canFullscreen: false,
    showNativeControls: false,
  );

  /// 依据实际播放源推导能力。
  ///
  /// 倍速：libmpv 内核在本地解码，支持变速播放，故为 true。
  /// 清晰度切换：仅当平台确实返回多档时为 true。
  /// 进度：B 站 DASH 直链实测支持 Range，故为 true。
  static PlayerCapabilities forNative(NativePlaybackSource source) =>
      PlayerCapabilities(
        canSeek: true,
        canSetVolume: true,
        canSetRate: true,
        canSwitchQuality: source.availableQualities.length > 1,
        canFullscreen: true,
        showNativeControls: true,
      );
}
