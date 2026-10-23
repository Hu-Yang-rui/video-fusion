/// 红果搜索 + 抖音联想词的离线回归（2026-10-23）。
///
/// # 这组测试守护什么
///
/// 红果搜索以前是 `unsupportedPlatform`（"官网未找到搜索接口"）。
/// 本轮在页面 HTML 的 `_SdkGlueInit` 配置里找到了真实接口：
/// ```
/// bdms:{paths:{include:["^/api/search/result/?$",
///                       "^/api/search/suggestion/?$"]}}
/// ```
/// 实测 `query=总裁` → `totalCount=204, totalPages=21`，数据真实。
///
/// 测试重点不是"能不能请求"，而是**参数与字段的坑**：
///  1. 分页参数是 `page`，不是 `pageNum` / `offset`
///     （后两者会 HTTP 200 + 返回同一页数据，静默失败）
///  2. 剧集信息在 `video_data` 子对象里，不在条目顶层
///  3. 字段名是 `series_cover`，不是分类页的 `series_cover_pc`
///  4. 每页固定 10 条，`count` 参数不生效——不能声称 pageSize 生效
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo_adapter.dart';
import 'package:video_fusion/src/adapters/hongguo/parser.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

/// 实测（2026-10-23，`query=总裁`）的响应结构，字段值照抄真实响应。
Map<String, Object?> _realSearchResponse() => {
      'searchList': [
        {
          'doc_type': 23,
          'name': '总裁是我前女友',
          'keyword': '7688352674999176254',
          'video_data': {
            'series_id': '7688352674999176254',
            'series_title': '总裁是我前女友',
            'series_cover':
                'https://p3-novel.byteimg.com/novel-pic/091e1a4c74697bb342314423fd1b64dc~tplv-shrink:640:0.image',
            'series_intro': '年少相爱却无奈分手，多年后再度重逢。',
            'episode_cnt': 95,
            'create_time': '1790084101',
            'series_status': 1,
            'pay_type': 0,
          },
          'user_info': {},
          'video_list': [],
        },
        {
          'doc_type': 23,
          'name': '诱情染指之黎野入怀',
          'keyword': '7688352674999176255',
          'video_data': {
            'series_id': '7688352674999176255',
            'series_title': '诱情染指之黎野入怀',
            'series_cover': 'https://p3-novel.byteimg.com/cover2.jpg',
            'series_intro': '第二部的简介。',
            'episode_cnt': 80,
          },
        },
        {
          // 演员/话题命中：没有 video_data，必须跳过而不是崩
          'doc_type': 8,
          'name': '某演员',
          'keyword': 'actor_123',
        },
      ],
      'totalCount': 204,
      'accessibleEpisodeCnt': 30,
      'pageNum': 1,
      'totalPages': 21,
      'hasMore': true,
    };

void main() {
  group('红果搜索解析（实测结构）', () {
    test('从 video_data 取剧集，跳过无 video_data 的命中', () {
      final r = HongguoParser()
          .parseSearchResult(jsonEncode(_realSearchResponse()));

      expect(r.items, hasLength(2), reason: '第三条是演员命中，没有 video_data');
      expect(r.items.first.seriesId, '7688352674999176254');
      expect(r.items.first.title, '总裁是我前女友');
      expect(r.items.first.coverUrl, contains('p3-novel.byteimg.com'));
      expect(r.items.first.episodeCount, 95);
    });

    test('分页信息来自 totalCount / pageNum / totalPages / hasMore', () {
      final r = HongguoParser()
          .parseSearchResult(jsonEncode(_realSearchResponse()));
      expect(r.totalCount, 204);
      expect(r.pageNum, 1);
      expect(r.totalPages, 21);
      expect(r.hasMore, isTrue);
    });

    test('空/坏 JSON 返回 empty，不抛', () {
      final p = HongguoParser();
      expect(p.parseSearchResult('').isEmpty, isTrue);
      expect(p.parseSearchResult('<html>').isEmpty, isTrue);
      expect(p.parseSearchResult('{"searchList":null}').isEmpty, isTrue);
    });

    test('series_cover 优先，兼容 series_cover_pc', () {
      final body = jsonEncode({
        'searchList': [
          {
            'name': 'x',
            'video_data': {
              'series_id': '1',
              'series_title': 't',
              'series_cover_pc': 'https://pc-only.jpg',
            },
          },
        ],
        'totalCount': 1,
        'pageNum': 1,
        'totalPages': 1,
        'hasMore': false,
      });
      final r = HongguoParser().parseSearchResult(body);
      expect(r.items.single.coverUrl, 'https://pc-only.jpg');
    });
  });

  group('红果搜索适配器：参数与语义', () {
    test('supportsSearch 已翻为 true', () {
      final a = HongguoAdapter(http: _StubHttp({}));
      expect(a.supportsSearch, isTrue);
    });

    test('请求用 page=，且不发送 pageNum/offset/count', () async {
      final http = _StubHttp({'api/search/result': _realSearchResponse()});
      final a = HongguoAdapter(http: http);

      await a.searchVideos('总裁', page: 2);
      final url = http.requestedUrls.last;

      expect(url, contains('query='));
      expect(url, contains('page=2'), reason: 'page 才是生效的分页参数');
      expect(url, isNot(contains('pageNum=')),
          reason: 'pageNum 实测不生效，会静默返回第一页');
      expect(url, isNot(contains('offset=')), reason: 'offset 实测不生效');
      expect(url, isNot(contains('count=')), reason: '每页固定 10 条，count 不生效');
    });

    test('关键词 URL 编码（中文不能裸拼）', () async {
      final http = _StubHttp({'api/search/result': _realSearchResponse()});
      final a = HongguoAdapter(http: http);
      await a.searchVideos('总裁');
      expect(http.requestedUrls.last, contains('%E6%80%BB%E8%A3%81'));
    });

    test('空关键词本地拦截，不发请求', () async {
      final http = _StubHttp({});
      final a = HongguoAdapter(http: http);
      await expectLater(
        a.searchVideos('   '),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.invalidUrl,
        )),
      );
      expect(http.requestedUrls, isEmpty);
    });

    test('超 30 字本地拦截（平台会 400 invalid_query）', () async {
      final http = _StubHttp({});
      final a = HongguoAdapter(http: http);
      await expectLater(
        a.searchVideos('字' * 31),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.invalidUrl,
        )),
      );
      expect(http.requestedUrls, isEmpty, reason: '本地拦了就别浪费请求');
    });

    test('没有结果时返回空列表 + 明确说明，不抛错', () async {
      final http = _StubHttp({
        'api/search/result': {
          'searchList': <Object?>[],
          'totalCount': 0,
          'pageNum': 1,
          'totalPages': 1,
          'hasMore': false,
        },
      });
      final a = HongguoAdapter(http: http);
      final page = await a.searchVideos('不存在的剧名xyz');
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.notes.any((n) => n.contains('没有找到')), isTrue);
    });

    test('totalCount>0 却解析不出条目 → parseError（不伪装成"没搜到"）',
        () async {
      final http = _StubHttp({
        'api/search/result': {
          // 结构变了：有总数但没有可解析条目
          'searchList': [
            {'name': '无 video_data 的条目'}
          ],
          'totalCount': 99,
          'pageNum': 1,
          'totalPages': 10,
          'hasMore': true,
        },
      });
      final a = HongguoAdapter(http: http);
      await expectLater(
        a.searchVideos('总裁'),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.parseError,
        )),
      );
    });

    test('hasMore 同时看平台标志与页码（不越界翻页）', () async {
      // hasMore=true 但已在最后一页 → 应为 false
      final http = _StubHttp({
        'api/search/result': {
          ..._realSearchResponse(),
          'pageNum': 21,
          'totalPages': 21,
          'hasMore': true,
        },
      });
      final a = HongguoAdapter(http: http);
      final page = await a.searchVideos('总裁', page: 21);
      expect(page.hasMore, isFalse, reason: '已到最后一页，不能再声称还有');
    });

    test('如实说明每页条数（不谎报 pageSize 生效）', () async {
      final http = _StubHttp({'api/search/result': _realSearchResponse()});
      final a = HongguoAdapter(http: http);
      final page = await a.searchVideos('总裁', pageSize: 50);
      expect(page.items, hasLength(2), reason: '平台给几条就是几条');
      expect(page.notes.any((n) => n.contains('固定 10 条')), isTrue,
          reason: '必须如实告知每页固定 10 条');
    });
  });
}

/// 按 URL 片段分派的 HTTP 替身（不触网）。
class _StubHttp extends FusionHttpClient {
  _StubHttp(this._bySubstring) : super(logger: FusionLogger(enabled: false));

  final Map<String, Map<String, Object?>> _bySubstring;
  final List<String> requestedUrls = [];

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
    requestedUrls.add(url);
    final body = _bySubstring.entries
        .firstWhere(
          (e) => url.contains(e.key),
          orElse: () => const MapEntry('', <String, Object?>{}),
        )
        .value;
    return HttpResult(
      statusCode: 200,
      body: jsonEncode(body),
      headers: const {},
      url: url,
      attempts: 1,
      durationMs: 0,
    );
  }
}
