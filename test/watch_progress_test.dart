/// 观看历史记录测试。
///
/// 重点验证：历史页要显示剧名而不是一串 ID。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/video_progress_store.dart';

void main() {
  group('WatchProgress 展示字段', () {
    test('有标题时用标题', () {
      const p = WatchProgress(
        videoId: 'hongguo:7680951264905022488',
        positionMs: 30000,
        durationMs: 277000,
        updatedAt: '2026-10-21T00:00:00Z',
        title: '站在外科之巅，我在急诊科疯狂摸鱼',
      );
      expect(p.displayTitle, '站在外科之巅，我在急诊科疯狂摸鱼');
    });

    test('无标题时退化为「平台 · ID」', () {
      const p = WatchProgress(
        videoId: 'hongguo:7680951264905022488',
        positionMs: 30000,
        durationMs: 277000,
        updatedAt: '2026-10-21T00:00:00Z',
      );
      expect(p.displayTitle, 'hongguo · 7680951264905022488');
    });

    test('空白标题视为无标题', () {
      const p = WatchProgress(
        videoId: 'bilibili:BV1xx',
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: '2026-10-21T00:00:00Z',
        title: '   ',
      );
      expect(p.displayTitle, 'bilibili · BV1xx');
    });

    test('无冒号的 videoId 直接显示', () {
      const p = WatchProgress(
        videoId: 'plain-id',
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: '2026-10-21T00:00:00Z',
      );
      expect(p.displayTitle, 'plain-id');
    });

    test('resolvedPlatformId 优先用存储值', () {
      const p = WatchProgress(
        videoId: 'unknown:123',
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: '2026-10-21T00:00:00Z',
        platformId: 'hongguo',
      );
      expect(p.resolvedPlatformId, 'hongguo');
    });

    test('resolvedPlatformId 回退到前缀', () {
      const p = WatchProgress(
        videoId: 'douyin:456',
        positionMs: 1000,
        durationMs: 10000,
        updatedAt: '2026-10-21T00:00:00Z',
      );
      expect(p.resolvedPlatformId, 'douyin');
    });
  });

  group('序列化', () {
    test('新字段能往返', () {
      const p = WatchProgress(
        videoId: 'hongguo:1',
        positionMs: 5000,
        durationMs: 60000,
        updatedAt: '2026-10-21T00:00:00Z',
        title: '剧名',
        coverUrl: 'https://example.com/c.jpg',
        platformId: 'hongguo',
      );
      final back = WatchProgress.fromJson(p.toJson());
      expect(back.title, '剧名');
      expect(back.coverUrl, 'https://example.com/c.jpg');
      expect(back.platformId, 'hongguo');
      expect(back.displayTitle, '剧名');
    });

    test('旧记录（无新字段）能读', () {
      final json = {
        'videoId': 'hongguo:1',
        'positionMs': 5000,
        'durationMs': 60000,
        'updatedAt': '2026-10-21T00:00:00Z',
      };
      final p = WatchProgress.fromJson(json);
      expect(p.title, isNull);
      expect(p.coverUrl, isNull);
      expect(p.platformId, isNull);
      expect(p.displayTitle, 'hongguo · 1');
    });

    test('空字符串标题归一化为 null', () {
      final json = {
        'videoId': 'x:1',
        'positionMs': 0,
        'durationMs': 0,
        'updatedAt': '',
        'title': '  ',
      };
      expect(WatchProgress.fromJson(json).title, isNull);
    });

    test('toJson 不含空字段', () {
      const p = WatchProgress(
        videoId: 'x:1',
        positionMs: 1000,
        durationMs: 5000,
        updatedAt: '',
      );
      expect(p.toJson().containsKey('title'), isFalse);
      expect(p.toJson().containsKey('coverUrl'), isFalse);
      expect(p.toJson().containsKey('platformId'), isFalse);
    });
  });

  group('VideoProgressStore.save 带元数据', () {
    test('保存后能读回标题', () async {
      final store = VideoProgressStore(storage: InMemoryStore());
      await store.save(
        videoId: 'hongguo:1',
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 277),
        title: '剧名 A',
        coverUrl: 'https://example.com/a.jpg',
        platformId: 'hongguo',
      );
      final p = await store.get('hongguo:1');
      expect(p, isNotNull);
      expect(p!.title, '剧名 A');
      expect(p.coverUrl, 'https://example.com/a.jpg');
      expect(p.displayTitle, '剧名 A');
    });

    test('重复保存时新标题为空不会冲掉旧标题', () async {
      final store = VideoProgressStore(storage: InMemoryStore());
      await store.save(
        videoId: 'hongguo:1',
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 277),
        title: '剧名 A',
      );
      // 第二次不带标题
      await store.save(
        videoId: 'hongguo:1',
        position: const Duration(seconds: 60),
        duration: const Duration(seconds: 277),
      );
      final p = await store.get('hongguo:1');
      expect(p!.title, '剧名 A', reason: '旧标题应保留');
      expect(p.position.inSeconds, 60, reason: '位置应更新');
    });

    test('新标题能覆盖旧标题', () async {
      final store = VideoProgressStore(storage: InMemoryStore());
      await store.save(
        videoId: 'x:1',
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 100),
        title: '旧名',
      );
      await store.save(
        videoId: 'x:1',
        position: const Duration(seconds: 40),
        duration: const Duration(seconds: 100),
        title: '新名',
      );
      expect((await store.get('x:1'))!.title, '新名');
    });

    test('位置过短不记录', () async {
      final store = VideoProgressStore(storage: InMemoryStore());
      await store.save(
        videoId: 'x:1',
        position: const Duration(seconds: 2),
        duration: const Duration(seconds: 100),
        title: '不应记录',
      );
      expect(await store.get('x:1'), isNull);
    });

    test('旧记录能和新记录共存', () async {
      // 模拟旧版本写入的数据
      final storage = InMemoryStore({
        'video_fusion.progress.v1':
            '[{"videoId":"old:1","positionMs":30000,"durationMs":100000,'
                '"updatedAt":"2026-10-20T00:00:00Z"}]',
      });
      final store = VideoProgressStore(storage: storage);
      await store.save(
        videoId: 'new:1',
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 100),
        title: '新剧',
      );
      final all = await store.all();
      expect(all, hasLength(2));
      final old = all.firstWhere((p) => p.videoId == 'old:1');
      expect(old.title, isNull);
      expect(old.displayTitle, 'old · 1');
    });
  });
}
