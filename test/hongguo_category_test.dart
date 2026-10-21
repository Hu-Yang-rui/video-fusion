/// 红果分类页解析测试。
///
/// 用真实 HTML 的片段结构做桩（不联网）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/parser.dart';

/// 构造一个带 `recommendList` 的页面片段。
String _page(List<Map<String, Object?>> items) {
  final list = items
      .map(
        (m) =>
            '{${m.entries.map((e) {
              final v = e.value;
              final encoded = v is String
                  ? '"${v.replaceAll('"', '\\"')}"'
                  : '$v';
              return '"${e.key}":$encoded';
            }).join(',')}}',
      )
      .join(',');
  return '<html><body><script>window.__DATA__={"recommendList":[$list]};'
      '</script></body></html>';
}

void main() {
  const parser = HongguoParser();

  group('parseCategoryPage', () {
    test('解析出剧集基本信息', () {
      final html = _page([
        {
          'series_id': '7694653385668037657',
          'series_name': '王妈在顾家当保姆后全家只会搞笑了',
          'series_cover': 'https://p6-novel.byteimg.com/cover1.image',
          'series_intro': '王妈应聘成为顾家住家保姆。',
          'episode_cnt': 86,
          'episode_right_text': '全86集',
        },
        {
          'series_id': '7694896136963755032',
          'series_name': '雾锁情迷',
          'series_cover': 'https://p6-novel.byteimg.com/cover2.image',
          'series_intro': '一场迷雾中的相遇。',
          'episode_cnt': 60,
        },
      ]);

      final list = parser.parseCategoryPage(html);
      expect(list, hasLength(2));
      expect(list[0].seriesId, '7694653385668037657');
      expect(list[0].title, '王妈在顾家当保姆后全家只会搞笑了');
      expect(list[0].episodeCount, 86);
      expect(list[1].title, '雾锁情迷');
    });

    test('去重相同 series_id', () {
      final html = _page([
        {'series_id': '111', 'series_name': 'A'},
        {'series_id': '111', 'series_name': 'A 重复'},
        {'series_id': '222', 'series_name': 'B'},
      ]);
      final list = parser.parseCategoryPage(html);
      expect(list, hasLength(2));
      expect(list.map((s) => s.seriesId), ['111', '222']);
    });

    test('跳过缺 id 或标题的条目', () {
      final html = _page([
        {'series_id': '', 'series_name': '无 id'},
        {'series_id': '333'},
        {'series_id': '444', 'series_name': '正常'},
      ]);
      final list = parser.parseCategoryPage(html);
      expect(list, hasLength(1));
      expect(list.first.seriesId, '444');
    });

    test('兼容 series_title 字段名', () {
      final html = _page([
        {'series_id': '555', 'series_title': '用 title 字段'},
      ]);
      final list = parser.parseCategoryPage(html);
      expect(list, hasLength(1));
      expect(list.first.title, '用 title 字段');
    });

    test('无 recommendList 时返回空列表（不抛错）', () {
      expect(parser.parseCategoryPage('<html></html>'), isEmpty);
      expect(parser.parseCategoryPage(''), isEmpty);
    });

    test('recommendList 不是数组时返回空列表', () {
      final html = '<html>{"recommendList":"not-an-array"}</html>';
      expect(parser.parseCategoryPage(html), isEmpty);
    });

    test('24 条全部解析（真实页面上限）', () {
      final items = List.generate(
        24,
        (i) => {
          'series_id': '${7000000000000000000 + i}',
          'series_name': '剧集 $i',
          'episode_cnt': 40 + i,
        },
      );
      final list = parser.parseCategoryPage(_page(items));
      expect(list, hasLength(24));
      expect(list.first.title, '剧集 0');
      expect(list.last.title, '剧集 23');
    });

    test('空数组返回空列表', () {
      expect(parser.parseCategoryPage('<html>{"recommendList":[]}</html>'), isEmpty);
    });
  });
}
