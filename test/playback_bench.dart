/// 播放链路耗时基准（真实网络）。
///
/// 默认**跳过**，用 tag 显式运行：
/// ```
/// flutter test test/playback_bench_test.dart --tags bench
/// ```
///
/// 只测网络与解析：推荐流一页、播放地址解析（冷/热）。
/// 播放器初始化与首帧渲染属于设备侧，必须真机测，不在本文件范围。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/adapters/mock_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';

class _MemStore implements KeyValueStore {
  final Map<String, String> _d = {};
  @override
  Future<String?> read(String key) async => _d[key];
  @override
  Future<void> write(String key, String value) async => _d[key] = value;
  @override
  Future<void> delete(String key) async => _d.remove(key);
  @override
  Future<Set<String>> keys() async => _d.keys.toSet();
}

VideoService _service() {
  final logger = FusionLogger(minLevel: LogLevel.warn);
  final http = FusionHttpClient(logger: logger);
  final registry = PlatformRegistry(adapters: [
    BilibiliAdapter(http: http, logger: logger),
    DouyinAdapter(http: http, logger: logger),
    MockAdapter(http: http, logger: logger),
  ]);
  return VideoService(
    registry: registry,
    store: VideoStore(storage: _MemStore(), logger: logger),
    logger: logger,
  );
}

int _median(List<int> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

String _clip(String s) => s.length <= 26 ? s : '${s.substring(0, 26)}…';

void main() {
  test(
    '基准：推荐流 + 播放解析（冷/热）',
    () async {
      final service = _service();

      // ── 1. 推荐流一页 ──
      final feedStart = DateTime.now();
      final feed = await service.fetchFeed(
        BilibiliAdapter.feedSourceRcmd,
        request: const FeedRequest(offset: 0),
      );
      final feedMs = DateTime.now().difference(feedStart).inMilliseconds;

      // ignore: avoid_print
      print('[BENCH] 推荐流一页: ${feed.items.length} 条, ${feedMs}ms');
      expect(feed.items, isNotEmpty, reason: '需要真实内容才能测解析');

      final samples = feed.items.take(5).toList();

      // ── 2. 冷缓存解析 ──
      final cold = <int>[];
      for (var i = 0; i < samples.length; i++) {
        final v = samples[i];
        service.cache.playback.invalidate(v.id);
        final t0 = DateTime.now();
        final outcome = await service.resolvePlayback(v);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        cold.add(ms);
        // ignore: avoid_print
        print('[BENCH] 冷[$i] ${ms}ms ${outcome.source.runtimeType} '
            '${_clip(v.title)}');
      }

      // ── 3. 热缓存解析 ──
      final hot = <int>[];
      for (var i = 0; i < samples.length; i++) {
        final v = samples[i];
        final t0 = DateTime.now();
        final outcome = await service.resolvePlayback(v);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        hot.add(ms);
        // ignore: avoid_print
        print('[BENCH] 热[$i] ${ms}ms ${outcome.source.runtimeType} '
            '${_clip(v.title)}');
      }

      // ignore: avoid_print
      print('[BENCH] 汇总: feed=${feedMs}ms '
          'cold中位=${_median(cold)}ms 明细=$cold '
          'hot中位=${_median(hot)}ms 明细=$hot '
          '缓存节省=${_median(cold) - _median(hot)}ms');

      // 热缓存必须显著快于冷缓存，否则说明缓存没命中
      expect(
        _median(hot),
        lessThan(_median(cold)),
        reason: '热缓存应命中，耗时应明显低于冷缓存',
      );

      // ── 4. 抖音推荐流 ──
      try {
        final dyStart = DateTime.now();
        final dy = await service.fetchFeed(
          'douyin:recommend',
          request: const FeedRequest(offset: 0),
        );
        final dyMs = DateTime.now().difference(dyStart).inMilliseconds;
        // ignore: avoid_print
        print('[BENCH] 抖音推荐流: ${dy.items.length} 条, ${dyMs}ms');

        if (dy.items.isNotEmpty) {
          service.cache.playback.invalidate(dy.items.first.id);
          final t0 = DateTime.now();
          final o = await service.resolvePlayback(dy.items.first);
          // ignore: avoid_print
          print('[BENCH] 抖音首个解析: '
              '${DateTime.now().difference(t0).inMilliseconds}ms '
              '${o.source.runtimeType}');
        }
      } catch (e) {
        // ignore: avoid_print
        print('[BENCH] 抖音推荐流失败: $e');
      }
    },
    tags: ['bench'],
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
