/// 竖滑流控制器 —— 短视频平台的核心交互逻辑。
///
/// 职责：
///  - 管理推荐流分页（滑到接近底部时预加载下一页）
///  - 管理**单个**播放内核实例，在页面切换时换源
///    （不为一屏开一个解码器，避免内存与解码资源爆炸）
///  - 滑到哪一屏就解析并播放哪一屏
///  - 离开的屏立即释放播放资源
///
/// 关键约束：
///  - 只缓存当前屏与相邻屏的播放源，不预解析全部视频
///  - 播放失败**不静默跳过**，在当前屏如实展示错误
///  - 单个视频失败不影响继续上滑浏览
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/video_service.dart';
import '../../models/feed.dart';
import '../../models/playback.dart';
import '../../models/unified_video.dart';
import '../../player/player_controller.dart';

/// 单屏的加载状态。
enum FeedItemState {
  /// 尚未解析播放源。
  idle,

  /// 正在解析播放源。
  resolving,

  /// 正在加载到播放内核。
  loading,

  /// 可播放。
  ready,

  /// 该视频无法在应用内播放（降级为跳转原平台）。
  externalOnly,

  /// 加载或播放失败。
  failed,
}

/// 竖滑流控制器。
class FeedController extends ChangeNotifier {
  FeedController({
    required VideoService service,
    FusionLogger? logger,
  })  : _service = service,
        _logger = logger ?? appLogger;

  final VideoService _service;
  final FusionLogger _logger;

  // ── 流内容 ──────────────────────────────────────────────────

  final List<UnifiedVideo> _items = [];
  List<UnifiedVideo> get items => List.unmodifiable(_items);
  int get length => _items.length;

  /// 当前内容来源。
  FeedSource? _source;
  FeedSource? get source => _source;

  bool _loadingMore = false;
  bool get loadingMore => _loadingMore;

  bool _hasMore = true;
  bool get hasMore => _hasMore;

  int _nextOffset = 0;

  /// 首页加载状态。
  bool _initialLoading = false;
  bool get initialLoading => _initialLoading;

  /// 首页加载错误（**与"没有内容"严格区分**）。
  FusionException? _feedError;
  FusionException? get feedError => _feedError;

  /// 分页追加时的错误（不影响已加载内容的浏览）。
  FusionException? _appendError;
  FusionException? get appendError => _appendError;

  // ── 当前屏 ──────────────────────────────────────────────────

  int _currentIndex = 0;
  int get currentIndex => _currentIndex;

  UnifiedVideo? get currentVideo =>
      _currentIndex >= 0 && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;

  /// 每屏的状态。
  final Map<int, FeedItemState> _states = {};
  FeedItemState stateOf(int index) => _states[index] ?? FeedItemState.idle;

  /// 每屏的错误。
  final Map<int, FusionException> _errors = {};
  FusionException? errorOf(int index) => _errors[index];

  /// 每屏已解析出的播放源。
  final Map<int, NativePlaybackSource> _sources = {};

  /// 每屏的降级播放源（官方嵌入 / 外链）。
  final Map<int, PlaybackSource> _fallbackSources = {};

  PlaybackSource? playbackSourceOf(int index) =>
      _sources[index] ?? _fallbackSources[index];

  // ── 播放内核（全流复用单实例）──────────────────────────────

  FusionPlayerController? _player;
  FusionPlayerController? get player => _player;

  PlayerSnapshot _snapshot = PlayerSnapshot.initial;
  PlayerSnapshot get snapshot => _snapshot;

  StreamSubscription<PlayerSnapshot>? _snapshotSub;

  /// 当前正在播放的屏序号。
  int? _playingIndex;

  /// 播放快照的独立广播流。
  ///
  /// **性能关键**：播放器的 position 流约每 100ms 推送一次。
  /// 若把快照变化合并进 [ChangeNotifier.notifyListeners]，
  /// 整个 PageView 树（含所有子页面）会每秒重建约 10 次，
  /// 在低端设备上表现为明显卡顿与掉帧。
  ///
  /// 因此快照走独立流：只有真正关心播放进度的组件
  /// （如底部进度条）订阅它，页面结构不参与重建。
  final StreamController<PlayerSnapshot> _snapshotStream =
      StreamController<PlayerSnapshot>.broadcast();

  /// 订阅播放快照（仅进度条等高频组件使用）。
  Stream<PlayerSnapshot> get snapshotStream => _snapshotStream.stream;

  /// 初始化播放内核（在页面 initState 调用）。
  void initPlayer() {
    if (_player != null) return;
    final p = FusionPlayerController(logger: _logger);
    _player = p;
    _snapshotSub = p.stream.listen((snap) {
      final prev = _snapshot;
      _snapshot = snap;
      _snapshotStream.add(snap);

      // 只有"会影响页面结构"的状态变化才触发整体重建：
      // 相位切换（加载→播放→失败）与错误信息变化。
      // 位置/缓冲等高频字段不触发。
      final structuralChange = prev.phase != snap.phase ||
          prev.errorMessage != snap.errorMessage ||
          prev.errorDetail != snap.errorDetail;
      if (structuralChange) notifyListeners();
    });
  }

  // ── 内容加载 ────────────────────────────────────────────────

  /// 切换内容来源并重新加载。
  Future<void> loadSource(FeedSource source) async {
    _source = source;
    _items.clear();
    _states.clear();
    _errors.clear();
    _sources.clear();
    _fallbackSources.clear();
    _currentIndex = 0;
    _nextOffset = 0;
    _hasMore = true;
    _feedError = null;
    _appendError = null;

    // 关键：必须重置播放索引与上一来源的播放快照。
    //
    // 否则切换来源后 playIndex(0) 会因 `_playingIndex == 0` 早退，
    // 新来源的视频永远不会开始播放——表现为"内容加载了但画面不动"。
    // 同时清掉快照里的 duration，避免沿用上一个来源的时长
    // 让 `alreadyPlaying` 判断误判为"已起播"。
    _playingIndex = null;
    _snapshot = PlayerSnapshot.initial;

    notifyListeners();

    await loadMore(initial: true);
  }

  /// 加载下一页。
  Future<void> loadMore({bool initial = false}) async {
    final source = _source;
    if (source == null) return;
    if (_loadingMore) return;
    if (!initial && !_hasMore) return;

    _loadingMore = true;
    if (initial) {
      _initialLoading = true;
      _feedError = null;
    } else {
      _appendError = null;
    }
    notifyListeners();

    final result = await _service.fetchFeed(
      source.id,
      request: FeedRequest(offset: _nextOffset),
    );

    _loadingMore = false;
    _initialLoading = false;

    if (result.ok) {
      final page = result.page!;
      _items.addAll(page.items);
      _hasMore = page.hasMore;
      _nextOffset = page.nextOffset;
      _logger.info('feed page loaded', {
        'source': source.id,
        'received': page.items.length,
        'total': _items.length,
        'hasMore': _hasMore,
      });
    } else {
      if (initial) {
        _feedError = result.error;
      } else {
        _appendError = result.error;
      }
      _logger.warn('feed load failed', {
        'source': source.id,
        'code': result.error?.code.name,
      });
    }

    notifyListeners();

    // 首屏加载完成后立即开始播放
    if (_items.isNotEmpty && _playingIndex == null) {
      await playIndex(0);
    }
  }

  /// 重试首屏加载。
  Future<void> retryInitial() async {
    final source = _source;
    if (source == null) return;
    _hasMore = true;
    _nextOffset = 0;
    await loadMore(initial: true);
  }

  // ── 播放控制 ────────────────────────────────────────────────

  /// 切到第 [index] 屏并开始播放。
  ///
  /// 这是"滑到哪一屏就播哪一屏"的唯一入口。
  Future<void> playIndex(int index) async {
    if (index < 0 || index >= _items.length) return;

    // 同一屏且已真正起播：不重复加载，避免浪费解码资源。
    // 但若该屏当前**没有成功起播**（例如上次加载失败、或被音轨
    // 挂载打断），仍需重新尝试——否则用户会卡在一个永远黑屏的页面。
    final alreadyPlaying = _playingIndex == index &&
        _states[index] == FeedItemState.ready &&
        _snapshot.duration.inMilliseconds > 0;
    if (alreadyPlaying) return;

    _playingIndex = index;
    _currentIndex = index;
    notifyListeners();

    await _ensurePlayable(index);
  }

  /// 更新当前屏序号（滑动过程中调用，不触发播放）。
  void setCurrentIndex(int index) {
    if (_currentIndex == index) return;
    _currentIndex = index;
    notifyListeners();

    // 接近末尾时预加载下一页
    if (index >= _items.length - 3 && _hasMore && !_loadingMore) {
      unawaited(loadMore());
    }
  }

  /// 确保第 [index] 屏已解析播放源并加载到内核。
  Future<void> _ensurePlayable(int index) async {
    final video = _items[index];

    // 已有播放源：直接换源
    final existing = _sources[index];
    if (existing != null) {
      _states[index] = FeedItemState.loading;
      notifyListeners();
      await _player?.load(existing);
      await _player?.play();
      // 以快照为准判断是否真的起播，而不是假定成功
      final ok = _snapshot.duration.inMilliseconds > 0 &&
          _snapshot.phase != PlayerPhase.failed;
      _states[index] = ok ? FeedItemState.ready : FeedItemState.failed;
      if (!ok) {
        _errors[index] = FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '视频加载后未能开始播放。',
          technicalMessage:
              'duration=${_snapshot.duration.inMilliseconds} '
              'phase=${_snapshot.phase.name}',
          platformId: video.platformId,
        );
        // 直链可能已过期：清掉缓存，下次重试重新解析
        _sources.remove(index);
        _service.cache.playback.invalidate(video.id);
      }
      notifyListeners();
      return;
    }

    // 已知只能外部播放
    if (_states[index] == FeedItemState.externalOnly) {
      notifyListeners();
      return;
    }

    _states[index] = FeedItemState.resolving;
    _errors.remove(index);
    notifyListeners();

    try {
      final outcome = await _service.resolvePlayback(video);

      if (!outcome.ok) {
        _states[index] = FeedItemState.failed;
        _errors[index] = outcome.error ??
            FusionException(
              code: FusionErrorCode.capabilityUnavailable,
              userMessage: '无法解析该视频的播放地址。',
              platformId: video.platformId,
            );
        notifyListeners();
        return;
      }

      final source = outcome.source!;

      if (source is NativePlaybackSource) {
        _sources[index] = source;
        _states[index] = FeedItemState.loading;
        notifyListeners();

        await _player?.load(source);
        await _player?.play();

        // 以快照为准：duration 解析成功且非 failed 才算 ready。
        // 仅看 phase 不够——phase 可能是 ready 但 duration 为 0
        // （媒体未真正加载），此时应判为失败而不是假装可播。
        final started = _snapshot.duration.inMilliseconds > 0 &&
            _snapshot.phase != PlayerPhase.failed;
        _states[index] =
            started ? FeedItemState.ready : FeedItemState.failed;
        if (!started) {
          _errors[index] = FusionException(
            code: FusionErrorCode.capabilityUnavailable,
            userMessage: _snapshot.errorMessage ?? '视频未能开始播放。',
            technicalMessage: 'duration=${_snapshot.duration.inMilliseconds} '
                'phase=${_snapshot.phase.name} '
                'detail=${_snapshot.errorDetail ?? '-'}',
            platformId: video.platformId,
          );
          // 清缓存，让重试能拿到新的直链
          _sources.remove(index);
          _service.cache.playback.invalidate(video.id);
        }
        notifyListeners();
      } else {
        // 官方嵌入 / 外链：不在竖滑流内自动播放，如实标记
        _fallbackSources[index] = source;
        _states[index] = FeedItemState.externalOnly;
        notifyListeners();
      }
    } on FusionException catch (e) {
      _states[index] = FeedItemState.failed;
      _errors[index] = e;
      notifyListeners();
    } catch (e) {
      _states[index] = FeedItemState.failed;
      _errors[index] = normalizeError(e, platformId: video.platformId);
      notifyListeners();
    }
  }

  /// 重试当前屏。
  Future<void> retryCurrent() async {
    final index = _currentIndex;
    if (index < 0 || index >= _items.length) return;

    // 直链可能已过期：先清缓存再重新解析
    final video = _items[index];
    _service.cache.playback.invalidate(video.id);
    _sources.remove(index);
    _fallbackSources.remove(index);
    _errors.remove(index);
    _states[index] = FeedItemState.idle;
    _playingIndex = null;

    notifyListeners();
    await playIndex(index);
  }

  /// 当前是否允许切换播放/暂停。
  ///
  /// 判断依据是**播放器的实时状态**，不是快照 phase。
  /// 快照由 media_kit 事件流驱动，暂停/恢复与事件到达之间有延迟；
  /// 用快照判断会让连续两次点击读到同一个旧值，
  /// 表现为"暂停后点不回来"。
  ///
  /// 只要已加载出时长（即媒体真的打开了），就允许切换。
  /// 加载中（duration 为 0）与失败态不响应。
  bool get canTogglePlay {
    final p = _player;
    if (p == null) return false;
    if (_snapshot.phase == PlayerPhase.failed) return false;
    if (_snapshot.duration.inMilliseconds <= 0) return false;
    return true;
  }

  /// 切换播放/暂停。
  ///
  /// 直接委托给播放内核，不在这里维护第二份播放状态——
  /// 两套状态必然发散，是"点了没反应"类缺陷的常见来源。
  Future<void> togglePlay() async {
    final p = _player;
    if (p == null) return;
    await p.playOrPause();
  }

  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  Future<void> setVolume(double v) async {
    await _player?.setVolume(v);
  }

  Future<void> setRate(double r) async {
    await _player?.rawPlayer.setRate(r);
  }

  /// 离开页面时释放内核。
  @override
  void dispose() {
    _snapshotSub?.cancel();
    _snapshotStream.close();
    _player?.dispose();
    _player = null;
    super.dispose();
  }
}
