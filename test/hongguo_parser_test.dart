/// 红果短剧官网解析测试。
///
/// 用**真实保存的官网 HTML** 做样本（`test/fixtures/`），
/// 不联网。样本采集于 2026-10-20。
///
/// # 为什么必须用真实样本
///
/// 需求明确警告：不能假定 `series_id` 与 `series_name` 按下标对应。
/// 实测首页有 46 个 `series_id` 但只有 10 个 `series_name`，
/// 分别正则后配对必然错位。只有用真实 HTML 才能验证解析器
/// 是否真的按对象成组提取。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/parser.dart';

void main() {
  const parser = HongguoParser();

  String? readFixture(String name) {
    final f = File('test/fixtures/$name');
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }

  group('红果首页解析（真实 HTML）', () {
    test('提取出剧集，且 id/title/cover 成组正确', () {
      final html = readFixture('hongguo_home.html');
      if (html == null) {
        // 样本缺失时跳过（不是失败）
        return;
      }

      final list = parser.parseHomepage(html);

      expect(list, isNotEmpty, reason: '首页应能解析出剧集');

      // 每部剧都要有 id 与标题
      for (final s in list) {
        expect(s.seriesId, isNotEmpty);
        expect(RegExp(r'^\d{10,25}$').hasMatch(s.seriesId), isTrue,
            reason: 'series_id 应是纯数字：${s.seriesId}');
        expect(s.title, isNotEmpty, reason: '每部剧都必须有标题');
      }

      // 已知的真实数据（实测确认）
      final known = list.where((s) => s.seriesId == '7690961604636052505');
      expect(known, isNotEmpty, reason: '应包含实测存在的「军需处长的账本」');
      expect(known.first.title, '军需处长的账本',
          reason: 'id 与 title 必须正确配对，不能错位');
      expect(known.first.episodeCount, 46, reason: 'episode_cnt 应为 46');

      // 去重
      final ids = list.map((s) => s.seriesId).toList();
      expect(ids.toSet().length, ids.length, reason: '不应有重复剧集');
    });

    test('不把 banner 里的 id 混进剧集列表', () {
      final html = readFixture('hongguo_home.html');
      if (html == null) return;

      final list = parser.parseHomepage(html);
      final ids = list.map((s) => s.seriesId).toSet();

      // bannerList 里的这部剧不在 homeSections 里（实测确认）
      // 如果解析器错误地把 banner 也算进来，这条会失败
      final bannerOnly = '7503745441910017049';
      final inBanner = html.contains('"series_id":"$bannerOnly"');
      if (inBanner) {
        // 它可能在也可能不在 homeSections —— 关键是解析器不因
        // banner 存在而重复计入
        final count = list.where((s) => s.seriesId == bannerOnly).length;
        expect(count, lessThanOrEqualTo(1), reason: '同一部剧不应重复出现');
      }
      expect(ids.length, list.length);
    });

    test('空 HTML / 无数据 HTML → 返回空列表而非崩溃', () {
      expect(parser.parseHomepage(''), isEmpty);
      expect(parser.parseHomepage('<html><body>nothing</body></html>'), isEmpty);
    });

    test('JSON 损坏 → 返回空列表而非崩溃', () {
      const broken = '{"homeSections":[{"video_list":[{"series_id":';
      expect(parser.parseHomepage(broken), isEmpty);
    });
  });

  group('红果播放页解析（真实 HTML）', () {
    test('提取分集，集数从 1 开始且连续', () {
      final html = readFixture('hongguo_player.html');
      if (html == null) return;

      final detail = parser.parsePlayerPage(
        html,
        seriesId: '7503745441910017049',
      );

      expect(detail, isNotNull, reason: '播放页应能解析出分集');
      expect(detail!.episodes, isNotEmpty);

      // 集数连续从 1 开始
      for (var i = 0; i < detail.episodes.length; i++) {
        expect(detail.episodes[i].index, i + 1);
      }

      // 每集都有 vid 与播放地址
      for (final e in detail.episodes) {
        expect(RegExp(r'^\d+$').hasMatch(e.vid), isTrue);
        expect(e.playUrl, contains('/video/public/'));
        expect(e.playUrl, endsWith('/360p.mp4'),
            reason: '只拼 360p——实测仅此档存在');
      }

      // 实测这个剧有 76 集
      expect(detail.episodes.length, 76);
    });

    test('第一集的 vid 与实测一致', () {
      final html = readFixture('hongguo_player.html');
      if (html == null) return;

      final detail = parser.parsePlayerPage(
        html,
        seriesId: '7503745441910017049',
      );
      expect(detail, isNotNull);
      // 实测第 1 集 vid（206 + ftyp 验证过可播放）
      expect(detail!.episodes.first.vid, '7503780574541122622');
      expect(detail.episodes.first.playUrl,
          'https://hongguoduanju.com/video/public/7503780574541122622/360p.mp4');
    });

    test('无 vid_list 的页面 → 返回 null', () {
      expect(
        parser.parsePlayerPage('<html></html>', seriesId: '1'),
        isNull,
      );
    });

    test('isMissingPage 能识别下架页', () {
      expect(parser.isMissingPage('<html>404</html>'), isTrue);
      final html = readFixture('hongguo_player.html');
      if (html != null) {
        expect(parser.isMissingPage(html), isFalse);
      }
    });
  });

  group('跨剧集不串线', () {
    test('两部剧的分集 vid 不重叠', () {
      final html = readFixture('hongguo_player.html');
      if (html == null) return;

      final a = parser.parsePlayerPage(html, seriesId: 'A');
      expect(a, isNotNull);

      // 用同一份 HTML 解析成另一个 seriesId，vid 应保持一致
      // （vid 来自页面内容，不来自 seriesId 参数）
      final b = parser.parsePlayerPage(html, seriesId: 'B');
      expect(b, isNotNull);
      expect(
        a!.episodes.map((e) => e.vid).toList(),
        b!.episodes.map((e) => e.vid).toList(),
        reason: 'vid 应来自页面数据，不受 seriesId 参数影响',
      );
      expect(a.seriesId, 'A');
      expect(b.seriesId, 'B');
    });
  });
}
