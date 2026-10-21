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
    this.title,
    this.coverUrl,
    this.platformId,
  });

  final String videoId;
  final int positionMs;
  final int durationMs;
  final String updatedAt;

  /// 视频标题。旧记录没有这个字段，为 null。
  ///
  /// 没有它时历史页只能显示 `红果 · 7680951264905022488` 这样的 ID，
  /// 用户认不出是哪一集。
  final String? title;

  /// 封面地址。旧记录为 null。
  final String? coverUrl;

  /// 平台标识（`hongguo` / `bilibili` / `douyin`）。
  ///
  /// 旧记录从 `videoId` 的前缀推断。
  final String? platformId;

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

  /// 平台标识：优先用存储的，否则从 `videoId` 前缀推断。
  String get resolvedPlatformId {
    final stored = platformId;
    if (stored != null && stored.isNotEmpty) return stored;
    final i = videoId.indexOf(':');
    return i < 0 ? '' : videoId.substring(0, i);
  }

  /// 用于列表展示的标题：有标题用标题，否则退化为 `平台 · ID`。
  String get displayTitle {
    final t = title;
    if (t != null && t.trim().isNotEmpty) return t.trim();
    final p = resolvedPlatformId;
    final i = videoId.indexOf(':');
    final raw = i < 0 ? videoId : videoId.substring(i + 1);
    return p.isEmpty ? raw : '$p · $raw';
  }

  Map<String, Object?> toJson() => {
        'videoId': videoId,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt,
        if (title != null) 'title': title,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (platformId != null) 'platformId': platformId,
      };

  factory WatchProgress.fromJson(Map<String, Object?> json) => WatchProgress(
        videoId: json['videoId'] as String? ?? '',
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        updatedAt: json['updatedAt'] as String? ?? '',
        title: (json['title'] as String?)?.trim().isEmpty ?? true
            ? null
            : json['title'] as String?,
        coverUrl: (json['coverUrl'] as String?)?.trim().isEmpty ?? true
            ? null
            : json['coverUrl'] as String?,
        platformId: (json['platformId'] as String?)?.trim().isEmpty ?? true
            ? null
            : json['platformId'] as String?,
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
  ///
  /// [title] / [coverUrl] / [platformId] 是可选的展示信息。带上它们，
  /// 历史页才能显示剧名而不是一串 ID。旧调用点不传也能工作，
  /// 只是列表里会退化成 `平台 · ID`。
  Future<void> save({
    required String videoId,
    required Duration position,
    required Duration duration,
    String? title,
    String? coverUrl,
    String? platformId,
  }) async {
    if (duration.inSeconds <= 0) return;
    if (position.inSeconds < 3) return;

    await _ensureLoaded();
    final existing = _memory[videoId];
    _memory[videoId] = WatchProgress(
      videoId: videoId,
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      // 新值为空时保留旧值：同一集反复保存不应把标题冲掉
      title: _pick(title, existing?.title),
      coverUrl: _pick(coverUrl, existing?.coverUrl),
      platformId: _pick(platformId, existing?.platformId),
    );
    await _persist();
  }

  /// 取非空的那个。
  static String? _pick(String? incoming, String? fallback) {
    final t = incoming?.trim();
    if (t != null && t.isNotEmpty) return t;
    return fallback;
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
