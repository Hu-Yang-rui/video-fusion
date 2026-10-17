/// 元数据缓存。区分原始视频信息、标准化视频信息与播放状态。
///
/// 约束：
///  - 缓存有效期可配置。
///  - 仅缓存符合平台规则与隐私要求的数据（本系统不缓存任何凭证）。
///  - 播放直链单独缓存且 TTL 更短（直链本身带时效签名）。
library;

import 'dart:async';

import '../models/unified_video.dart';
import '../models/playback.dart';

/// 缓存条目统计，用于 UI 展示与报告。
class CacheStats {
  const CacheStats({
    required this.hits,
    required this.misses,
    required this.staleHits,
    required this.entries,
    required this.evictions,
  });

  final int hits;
  final int misses;
  final int staleHits;
  final int entries;
  final int evictions;

  Map<String, Object?> toJson() => {
        'hits': hits,
        'misses': misses,
        'staleHits': staleHits,
        'entries': entries,
        'evictions': evictions,
      };
}

class _CacheEntry<T> {
  _CacheEntry(this.value, this.storedAt, this.ttl);

  final T value;
  final DateTime storedAt;
  final Duration ttl;

  bool get isExpired => DateTime.now().difference(storedAt) > ttl;

  Duration get age => DateTime.now().difference(storedAt);
}

/// 带 TTL 的内存缓存。线程安全（单 isolate 内使用 Completer 去重并发请求）。
class TtlCache<T> {
  TtlCache({required this.ttl, this.maxEntries = 500});

  Duration ttl;
  final int maxEntries;

  final Map<String, _CacheEntry<T>> _entries = {};
  final Map<String, Completer<T>> _inflight = {};

  int _hits = 0;
  int _misses = 0;
  int _staleHits = 0;
  int _evictions = 0;

  CacheStats get stats => CacheStats(
        hits: _hits,
        misses: _misses,
        staleHits: _staleHits,
        entries: _entries.length,
        evictions: _evictions,
      );

  /// 读取缓存；[allowStale] 为 true 时过期条目仍返回（用于"先展示旧数据再刷新"）。
  ({T value, bool stale})? peek(String key, {bool allowStale = false}) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      if (!allowStale) return null;
      _staleHits++;
      return (value: entry.value, stale: true);
    }
    _hits++;
    return (value: entry.value, stale: false);
  }

  void put(String key, T value) {
    if (_entries.length >= maxEntries && !_entries.containsKey(key)) {
      _evictOldest();
    }
    _entries[key] = _CacheEntry<T>(value, DateTime.now(), ttl);
  }

  /// 获取或加载。并发相同 key 的请求会合并为一次上游调用。
  Future<T> getOrLoad(String key, Future<T> Function() loader) async {
    final cached = peek(key);
    if (cached != null) return cached.value;

    final inflight = _inflight[key];
    if (inflight != null) return inflight.future;

    _misses++;
    final completer = Completer<T>();
    _inflight[key] = completer;
    try {
      final value = await loader();
      put(key, value);
      completer.complete(value);
      return value;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _inflight.remove(key);
    }
  }

  void invalidate(String key) => _entries.remove(key);

  void clear() {
    _entries.clear();
    _evictions += 0;
  }

  /// 主动清理过期条目。
  int pruneExpired() {
    final before = _entries.length;
    _entries.removeWhere((_, e) => e.isExpired);
    return before - _entries.length;
  }

  void _evictOldest() {
    if (_entries.isEmpty) return;
    String? oldestKey;
    DateTime? oldestAt;
    _entries.forEach((k, e) {
      if (oldestAt == null || e.storedAt.isBefore(oldestAt!)) {
        oldestAt = e.storedAt;
        oldestKey = k;
      }
    });
    if (oldestKey != null) {
      _entries.remove(oldestKey);
      _evictions++;
    }
  }
}

/// 缓存配置。TTL 可配置。
class CacheConfig {
  const CacheConfig({
    this.metadataTtl = const Duration(minutes: 30),
    this.playbackTtl = const Duration(minutes: 8),
    this.maxMetadataEntries = 500,
    this.maxPlaybackEntries = 100,
  });

  /// 视频元数据缓存有效期。
  final Duration metadataTtl;

  /// 播放直链缓存有效期。直链通常带时效签名，必须短。
  final Duration playbackTtl;

  final int maxMetadataEntries;
  final int maxPlaybackEntries;
}

/// 全局缓存集合。
class VideoCache {
  VideoCache({CacheConfig? config})
      : config = config ?? const CacheConfig(),
        _metadata = TtlCache<UnifiedVideo>(
          ttl: (config ?? const CacheConfig()).metadataTtl,
          maxEntries: (config ?? const CacheConfig()).maxMetadataEntries,
        ),
        _playback = TtlCache<PlaybackSource>(
          ttl: (config ?? const CacheConfig()).playbackTtl,
          maxEntries: (config ?? const CacheConfig()).maxPlaybackEntries,
        );

  final CacheConfig config;
  final TtlCache<UnifiedVideo> _metadata;
  final TtlCache<PlaybackSource> _playback;

  TtlCache<UnifiedVideo> get metadata => _metadata;
  TtlCache<PlaybackSource> get playback => _playback;

  /// 缓存命中时把 fromCache 标记写入 diagnostics。
  UnifiedVideo markFromCache(UnifiedVideo video) => video.copyWith(
        diagnostics: video.diagnostics.copyWith(
          fromCache: true,
          fetchDurationMs: 0,
        ),
      );

  Map<String, Object?> statsJson() => {
        'metadata': _metadata.stats.toJson(),
        'playback': _playback.stats.toJson(),
        'config': {
          'metadataTtlSeconds': config.metadataTtl.inSeconds,
          'playbackTtlSeconds': config.playbackTtl.inSeconds,
        },
      };

  void clear() {
    _metadata.clear();
    _playback.clear();
  }
}
