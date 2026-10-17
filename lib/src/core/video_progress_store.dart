/// 观看进度持久化存储。
///
/// 记录每个视频的播放位置与总时长，用于"继续观看"。
///
/// 约束：
///  - 只存本地，不上传任何服务器。
///  - 进度接近结束时视为"看完"，不再提供续播。
///  - 存储键与视频身份解耦：使用 `platformId:platformVideoId`。
library;

import 'dart:convert';

import 'key_value_store.dart';
import 'logger.dart';

/// 单条观看记录。
class WatchProgress {
  const WatchProgress({
    required this.videoId,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  final String videoId;
  final int positionMs;
  final int durationMs;
  final String updatedAt;

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);

  /// 播放进度 0..1。
  double get ratio =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  /// 是否已看完（超过 95%）。
  bool get isFinished => durationMs > 0 && ratio >= 0.95;

  /// 是否值得续播（看了一点但没看完）。
  bool get isResumable =>
      durationMs > 0 && positionMs > 5000 && ratio < 0.95;

  Map<String, Object?> toJson() => {
        'videoId': videoId,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt,
      };

  factory WatchProgress.fromJson(Map<String, Object?> json) => WatchProgress(
        videoId: json['videoId'] as String? ?? '',
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        updatedAt: json['updatedAt'] as String? ?? '',
      );
}

/// 观看进度存储。
class VideoProgressStore {
  VideoProgressStore({required KeyValueStore storage, FusionLogger? logger})
      : _storage = storage,
        _logger = logger ?? appLogger;

  static const String _key = 'video_fusion.progress.v1';

  final KeyValueStore _storage;
  final FusionLogger _logger;

  final Map<String, WatchProgress> _memory = {};
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final raw = await _storage.read(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              try {
                final p = WatchProgress.fromJson(
                  Map<String, Object?>.from(item),
                );
                if (p.videoId.isNotEmpty) _memory[p.videoId] = p;
              } catch (e) {
                _logger.warn('progress: skipping corrupted entry', {
                  'error': '$e',
                });
              }
            }
          }
        }
      }
    } catch (e) {
      _logger.error('progress: load failed', {'error': '$e'});
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    try {
      final list = _memory.values.map((p) => p.toJson()).toList();
      await _storage.write(_key, jsonEncode(list));
    } catch (e) {
      _logger.error('progress: persist failed', {'error': '$e'});
    }
  }

  /// 写入进度。播放时间过短（<3s）时不记录，避免产生噪声数据。
  Future<void> save({
    required String videoId,
    required Duration position,
    required Duration duration,
  }) async {
    if (duration.inSeconds <= 0) return;
    if (position.inSeconds < 3) return;

    await _ensureLoaded();
    _memory[videoId] = WatchProgress(
      videoId: videoId,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await _persist();
  }

  /// 读取单条进度。
  Future<WatchProgress?> get(String videoId) async {
    await _ensureLoaded();
    return _memory[videoId];
  }

  /// 全部记录，按更新时间倒序。
  Future<List<WatchProgress>> all() async {
    await _ensureLoaded();
    final list = _memory.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// 可续播的记录（看了一点但没看完）。
  Future<List<WatchProgress>> resumable() async {
    final all = await this.all();
    return all.where((p) => p.isResumable).toList();
  }

  Future<void> remove(String videoId) async {
    await _ensureLoaded();
    _memory.remove(videoId);
    await _persist();
  }

  Future<void> clear() async {
    await _ensureLoaded();
    _memory.clear();
    await _persist();
  }
}
