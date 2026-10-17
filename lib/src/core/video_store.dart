/// 视频持久化存储。
///
/// 使用 [KeyValueStore] 抽象（Flutter 侧注入 SharedPreferences 实现），
/// 不引入数据库依赖——第一版数据量小，无需大规模数据仓库。
///
/// 约束：
///  - 仅存储标准化视频信息，不存储任何凭证。
///  - 单个视频的解析失败不影响其它条目的读写。
///  - 核心层保持纯 Dart，不依赖 Flutter，以便命令行验证。
library;

import 'dart:convert';

import 'errors.dart';
import 'key_value_store.dart';
import 'logger.dart';
import '../models/unified_video.dart';

class VideoStore {
  VideoStore({required KeyValueStore storage, FusionLogger? logger})
      : _storage = storage,
        _logger = logger ?? appLogger;

  static const String _key = 'video_fusion.library.v1';

  final KeyValueStore _storage;
  final FusionLogger _logger;

  final Map<String, UnifiedVideo> _memory = {};
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
                final video =
                    UnifiedVideo.fromJson(Map<String, Object?>.from(item));
                _memory[video.id] = video;
              } catch (e) {
                // 单条损坏不影响其它条目
                _logger.warn('store: skipping corrupted entry', {'error': '$e'});
              }
            }
          }
        }
      }
    } catch (e) {
      _logger.error('store: load failed', {'error': '$e'});
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    try {
      final list = _memory.values.map((v) => v.toJson()).toList();
      await _storage.write(_key, jsonEncode(list));
    } catch (e) {
      _logger.error('store: persist failed', {'error': '$e'});
    }
  }

  /// 插入或更新。同一视频重复导入时更新而非重复添加。
  Future<void> upsert(UnifiedVideo video) async {
    await _ensureLoaded();
    _memory[video.id] = video;
    await _persist();
  }

  Future<UnifiedVideo?> get(String videoId) async {
    await _ensureLoaded();
    return _memory[videoId];
  }

  /// 全部视频，按导入时间倒序（最新在前）。
  Future<List<UnifiedVideo>> all() async {
    await _ensureLoaded();
    final list = _memory.values.toList()
      ..sort((a, b) => (b.fetchedAt).compareTo(a.fetchedAt));
    return list;
  }

  Future<void> remove(String videoId) async {
    await _ensureLoaded();
    _memory.remove(videoId);
    await _persist();
  }

  Future<int> count() async {
    await _ensureLoaded();
    return _memory.length;
  }

  Future<void> clear() async {
    await _ensureLoaded();
    _memory.clear();
    await _persist();
  }

  /// 按平台分组统计（用于首页来源区域展示真实数据量）。
  Future<Map<String, int>> countByPlatform() async {
    await _ensureLoaded();
    final out = <String, int>{};
    for (final v in _memory.values) {
      out[v.platformId] = (out[v.platformId] ?? 0) + 1;
    }
    return out;
  }

  /// 导出库为 JSON（供测试与报告验证使用）。
  Future<String> exportJson() async {
    await _ensureLoaded();
    return jsonEncode(_memory.values.map((v) => v.toJson()).toList());
  }

  /// 从 JSON 导入（供测试使用）。
  Future<void> importJson(String raw) async {
    await _ensureLoaded();
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '导入数据格式不正确。',
        technicalMessage: 'Expected JSON array, got ${decoded.runtimeType}',
      );
    }
    _memory.clear();
    for (final item in decoded) {
      if (item is Map) {
        final video = UnifiedVideo.fromJson(Map<String, Object?>.from(item));
        _memory[video.id] = video;
      }
    }
    await _persist();
  }
}
