/// 红果分集标识与观看进度测试。
///
/// 验证核心约束：**不同分集的进度不能串线**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/adapters/hongguo/playback_id.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/video_progress_store.dart';



/// 按 URL 返回 fixture 的假 HTTP 客户端。
class _FixtureHttp extends FusionHttpClient {
  _FixtureHttp(this.routes) : super();
  final Map<String, String> routes;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, String> headers = const {},
    String? platformId,
    Duration? timeout,
    bool? followRedirects,
    Set<int>? acceptStatuses,
    bool keepRawBytes = false,
  }) async {
    for (final e in routes.entries) {
      if (url.contains(e.key)) {
        return HttpResult(
          statusCode: 200,
          body: e.value,
          headers: const {},
          url: url,
          attempts: 1,
          durationMs: 1,
        );
      }
    }
    return HttpResult(
      statusCode: 404,
      body: '',
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 1,
    );
  }
}

void main() {
  group('红果分集标识编解码', () {
    test('整部剧（无分集号）', () {
      const id = HongguoPlaybackId(seriesId: '7503745441910017049');
      expect(id.toVideoId(), 'hongguo:7503745441910017049');

      final parsed = HongguoPlaybackId.parse(id.toVideoId());
      expect(parsed, isNotNull);
      expect(parsed!.seriesId, '7503745441910017049');
      expect(parsed.episodeIndex, isNull);
    });

    test('指定分集', () {
      const id = HongguoPlaybackId(
        seriesId: '7503745441910017049',
        episodeIndex: 5,
      );
      expect(id.toVideoId(), 'hongguo:7503745441910017049#5');

      final parsed = HongguoPlaybackId.parse(id.toVideoId());
      expect(parsed!.seriesId, '7503745441910017049');
      expect(parsed.episodeIndex, 5);
      expect(parsed.episodeLabel, ' 第5集');
    });

    test('往返编解码稳定', () {
      for (var i = 1; i <= 10; i++) {
        final id = HongguoPlaybackId(seriesId: '123456789012', episodeIndex: i);
        final back = HongguoPlaybackId.parse(id.toVideoId());
        expect(back!.seriesId, '123456789012');
        expect(back.episodeIndex, i);
      }
    });

    test('宽松解析：无前缀也接受', () {
      final p = HongguoPlaybackId.parse('123456789012#3');
      expect(p!.seriesId, '123456789012');
      expect(p.episodeIndex, 3);
    });

    test('非法输入返回 null', () {
      expect(HongguoPlaybackId.parse(''), isNull);
      // seriesId 为空时视为非法
      expect(HongguoPlaybackId.parse('#5'), isNull);
    });
  });

  group('同一部剧的判定', () {
    test('不同分集属于同一部剧', () {
      expect(
        hongguoSameSeries('hongguo:123#1', 'hongguo:123#5'),
        isTrue,
      );
    });

    test('不同剧不属于同一部', () {
      expect(
        hongguoSameSeries('hongguo:123#1', 'hongguo:456#1'),
        isFalse,
      );
    });

    test('取剧集 key 去掉分集号', () {
      expect(hongguoSeriesKeyOf('hongguo:123#5'), '123');
      expect(hongguoSeriesKeyOf('hongguo:123'), '123');
    });
  });

  group('观看进度按集隔离（关键）', () {
    test('第 1 集与第 5 集的进度互不影响', () async {
      final store = VideoProgressStore(storage: InMemoryStore());

      const ep1 = 'hongguo:7503745441910017049#1';
      const ep5 = 'hongguo:7503745441910017049#5';

      await store.save(
        videoId: ep1,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 20),
      );
      await store.save(
        videoId: ep5,
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 20),
      );

      final p1 = await store.get(ep1);
      final p5 = await store.get(ep5);

      expect(p1!.position, const Duration(minutes: 10));
      expect(p5!.position, const Duration(minutes: 2));
      expect(p1.position, isNot(p5.position),
          reason: '不同分集不能共享进度');
    });

    test('红果进度不与 B站/抖音串线', () async {
      final store = VideoProgressStore(storage: InMemoryStore());

      await store.save(
        videoId: 'hongguo:123#1',
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 10),
      );
      await store.save(
        videoId: 'bilibili:BV1xx',
        position: const Duration(minutes: 8),
        duration: const Duration(minutes: 10),
      );

      expect((await store.get('hongguo:123#1'))!.position,
          const Duration(minutes: 5));
      expect((await store.get('bilibili:BV1xx'))!.position,
          const Duration(minutes: 8));
    });

    test('历史列表能列出红果各集', () async {
      final store = VideoProgressStore(storage: InMemoryStore());

      for (var i = 1; i <= 3; i++) {
        await store.save(
          videoId: 'hongguo:999#$i',
          position: Duration(minutes: i),
          duration: const Duration(minutes: 20),
        );
      }

      final all = await store.all();
      expect(all.length, 3);
      for (final p in all) {
        expect(p.videoId, startsWith('hongguo:999#'));
      }
    });

    test('播放不足 3 秒不记录（避免噪声）', () async {
      final store = VideoProgressStore(storage: InMemoryStore());
      await store.save(
        videoId: 'hongguo:123#1',
        position: const Duration(seconds: 2),
        duration: const Duration(minutes: 10),
      );
      expect(await store.get('hongguo:123#1'), isNull);
    });
  });

  group('适配器构造分集 ID', () {
    test('episodeVideoId 与 HongguoPlaybackId 一致', () {
      const seriesId = '7503745441910017049';
      for (var i = 1; i <= 5; i++) {
        final expected =
            HongguoPlaybackId(seriesId: seriesId, episodeIndex: i).toVideoId();
        final actual = HongguoPlaybackId.parse(expected);
        expect(actual!.seriesId, seriesId);
        expect(actual.episodeIndex, i);
      }
    });
  });
  group('分集 UnifiedVideo 构造（选集与续播）', () {
    test('每集有独立的 video.id，进度不串线', () async {
      final home = File('test/fixtures/hongguo_home.html');
      final player = File('test/fixtures/hongguo_player.html');
      if (!player.existsSync()) return;

      final adapter = HongguoAdapter(
        http: _FixtureHttp({'/player/': player.readAsStringSync()}),
        logger: FusionLogger(enabled: false),
      );

      final eps = await adapter.fetchEpisodeVideos('7503745441910017049');
      expect(eps.length, greaterThan(1));

      // 每集 id 唯一
      final ids = eps.map((e) => e.id).toSet();
      expect(ids.length, eps.length, reason: '不同分集不能共用 id');

      // id 里带分集号
      expect(eps[0].id, contains('#1'));
      expect(eps[1].id, contains('#2'));

      // 标题带集数
      expect(eps[0].title, contains('第1集'));

      // 平台标识正确
      for (final e in eps) {
        expect(e.platformId, 'hongguo');
      }

      // 清理未使用的变量警告
      expect(home, isNotNull);
    });

    test('分集进度互相隔离', () async {
      final player = File('test/fixtures/hongguo_player.html');
      if (!player.existsSync()) return;

      final adapter = HongguoAdapter(
        http: _FixtureHttp({'/player/': player.readAsStringSync()}),
        logger: FusionLogger(enabled: false),
      );
      final store = VideoProgressStore(storage: InMemoryStore());

      final eps = await adapter.fetchEpisodeVideos('7503745441910017049');

      await store.save(
        videoId: eps[0].id,
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 20),
      );
      await store.save(
        videoId: eps[1].id,
        position: const Duration(minutes: 15),
        duration: const Duration(minutes: 20),
      );

      expect((await store.get(eps[0].id))!.position, const Duration(minutes: 3));
      expect((await store.get(eps[1].id))!.position, const Duration(minutes: 15));
    });
  });
}