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

import '../../core/app_settings.dart';
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

  /// 控制器是否已释放。
  ///
  /// 预解析等后台异步任务需要在完成后检查这个标志，
  /// 避免往已释放的控制器里写状态。
  bool _disposed = false;

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

  /// 内容来源代际。切换来源时递增，用于让上一个来源残留的
  /// 后台预解析任务作废——否则它会把旧列表第 i 项的播放源
  /// 写进新列表的第 i 项（列表下标相同但视频不同）。
  int _sourceGeneration = 0;

  /// 正在预解析中的屏序号，避免重复发请求。
  final Set<int> _prefetching = {};

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
    final p = FusionPlayerController(logger: _logger, settings: _settings);
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
          prev.errorDetail != snap.errorDetail ||
          // 长按加速的角标要随起随消，不能等下一次相位变化才更新。
          prev.boosting != snap.boosting;
      if (structuralChange) notifyListeners();
    });
    // 内核在换源后会被 mpv 重置回 1.0×，这里挂上设置里的倍速。
    final s = _settings;
    if (s != null) unawaited(p.setRate(s.playbackRate));
  }

  AppSettings? _settings;

  /// 接上应用设置：立即套用默认倍速，之后由 FusionPlayerController 跟随。
  void attachSettings(AppSettings? settings) {
    _settings = settings;
    final p = _player;
    final s = settings;
    if (p != null && s != null) unawaited(p.setRate(s.playbackRate));
  }

  // ── 内容加载 ────────────────────────────────────────────────

  /// 切换内容来源并重新加载。
  Future<void> loadSource(FeedSource source) async {
    _source = source;
    // 让上一个来源的预解析任务全部作废
    _sourceGeneration++;
    _prefetching.clear();
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

    // 预解析后续视频的播放地址。
    //
    // 实测：单个视频的 playurl 解析耗时约 1.9 秒（网络往返 + 签名），
    // 用户滑到下一屏时如果才开始解析，必然等 1–2 秒。
    //
    // 这里在首屏起播后，后台预解析接下来两屏的地址。
    // 不阻塞当前播放，失败也不影响任何状态——纯粹是预热缓存。
    _prefetchUpcoming(from: (_playingIndex ?? 0) + 1, count: 2);
  }

  /// 预解析后续视频的播放地址（预热缓存）。
  ///
  /// 只在缓存未命中时发请求；结果由 `VideoService` 的播放缓存持有，
  /// 用户真正滑到那一屏时 `resolvePlayback` 直接命中缓存。
  ///
  /// 失败静默忽略：这是优化路径，不是功能路径。
  void _prefetchUpcoming({required int from, int count = 2}) {
    if (from < 0 || from >= _items.length) return;

    final generation = _sourceGeneration;
    final end = (from + count).clamp(0, _items.length);
    for (var i = from; i < end; i++) {
      // 已经解析过、或正在解析中，跳过（快速连续滑动时避免重复请求）
      if (_sources.containsKey(i) || _prefetching.contains(i)) continue;

      final video = _items[i];
      _prefetching.add(i);

      unawaited(() async {
        try {
          final outcome = await _service.resolvePlayback(video);
          // 页面已销毁，或期间切换了内容来源：结果作废。
          // 否则会把旧列表第 i 项写进新列表第 i 项。
          if (_disposed || generation != _sourceGeneration) return;
          final src = outcome.source;
          // 只缓存 native 源；其它模式在真正切换时再处理
          if (src is NativePlaybackSource && _sources[i] == null) {
            _sources[i] = src;
            _logger.debug('feed: prefetched playback', {'index': i});
          }
        } catch (e) {
          // 预热失败不影响任何用户可见状态
          _logger.debug('feed: prefetch failed', {'index': i, 'error': '$e'});
        } finally {
          _prefetching.remove(i);
        }
      }());
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

    // 起播后立刻预解析后续两屏。
    //
    // 只在首屏加载时预解析是不够的：用户滑到第 3 屏后，
    // 第 4、5 屏仍是冷的，下一次滑动又要等一次 playurl 往返。
    // 这里每次成功起播都向前预热，滑动越多命中率越高。
    if (!_disposed && _states[index] == FeedItemState.ready) {
      _prefetchUpcoming(from: index + 1, count: 2);
    }
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

  /// 等待内核拿到时长。
  ///
  /// `load()` 内部的 `open()` 已经 await，多数源在返回时 duration 就绪；
  /// 少数源要等首个分片才有时长。这里给一个短窗口，
  /// 避免把"还没拿到时长"误判成"播放失败"而清掉缓存重来。
  Future<void> _awaitDuration({int timeoutMs = 900}) async {
    if (_snapshot.duration.inMilliseconds > 0) return;
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (_disposed) return;
      if (_snapshot.duration.inMilliseconds > 0) return;
      if (_snapshot.phase == PlayerPhase.failed) return;
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
      // play() 已改为不阻塞（起播修复走后台），这里补一个短窗口等时长，
      // 避免把"时长还没到"误判成失败。
      await _awaitDuration();
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
        await _awaitDuration();

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
  /// 判据是**媒体是否真的被打开过**，而不是 `duration > 0`。
  ///
  /// 历史实现要求 `duration > 0`，但存在两类合法场景会误判：
  ///  - 部分源的时长要等首个分片到达才知道，此前 duration 为 0；
  ///  - 直播/无时长媒体永远没有 duration。
  /// 这两种情况下用户点画面完全无响应，看起来像"暂停坏了"。
  ///
  /// 因此改为看快照 phase 是否处于"已加载"的任一态。
  /// 真正的播放/暂停判定交给内核实时状态（见 [FusionPlayerController.togglePlay]）。
  bool get canTogglePlay {
    final p = _player;
    if (p == null) return false;
    return switch (_snapshot.phase) {
      PlayerPhase.ready ||
      PlayerPhase.playing ||
      PlayerPhase.paused ||
      PlayerPhase.buffering ||
      PlayerPhase.completed =>
        true,
      PlayerPhase.idle || PlayerPhase.loading || PlayerPhase.failed => false,
    };
  }

  /// 切换播放/暂停。
  ///
  /// 直接委托给播放内核，不在这里维护第二份播放状态——
  /// 两套状态必然发散，是"点了没反应"类缺陷的常见来源。
  /// 内核内部会做串行化与"播完后回到开头"处理。
  Future<void> togglePlay() async {
    final p = _player;
    if (p == null) return;
    await p.togglePlay();
  }

  /// 短视频页是否处于前台。
  ///
  /// 切到「发现」「我的」时视频必须停下来——否则声音会在后台继续播。
  /// 切回时若用户没有主动暂停过，则自动恢复。
  ///
  /// 这个值同时被 [FeedScreen] 的生命周期回调读取：应用退到系统后台时
  /// 按"非前台"处理，回到前台时**只在该页确实可见**才恢复播放
  /// ——否则用户在「发现」页时回到前台，视频声音会从背后冒出来。
  bool _pageActive = true;
  bool get pageActive => _pageActive;

  Future<void> setPageActive(bool active) async {
    _pageActive = active;
    final p = _player;
    if (p == null) return;
    if (active) {
      await p.restoreFromSuspend();
    } else {
      await p.suspend();
    }
  }

  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  Future<void> setVolume(double v) async {
    await _player?.setVolume(v);
  }

  Future<void> setRate(double r) async {
    await _player?.setRate(r);
  }

  /// 长按临时加速（松手用 [endBoost] 结束）。
  Future<void> beginBoost([double rate = 3.0]) async {
    await _player?.beginBoost(rate);
  }

  Future<void> endBoost() async => _player?.endBoost();

  /// 进入画中画。返回 false = 设备不支持或被 ROM 拒绝。
  Future<bool> enterPictureInPicture() async =>
      await _player?.enterPictureInPicture() ?? false;

  /// 是否处于画中画（小窗期间不得因生命周期暂停播放）。
  bool get inPictureInPicture => _player?.pictureInPicture.isActive ?? false;

  /// 离开页面时释放内核。
  @override
  void dispose() {
    _disposed = true;
    _snapshotSub?.cancel();
    _snapshotStream.close();
    _player?.dispose();
    _player = null;
    super.dispose();
  }
}
