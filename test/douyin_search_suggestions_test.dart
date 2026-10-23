/// 抖音搜索联想词的离线回归（2026-10-23）。
///
/// # 为什么单独一个能力
///
/// 实测（probe_dy_search_state.mjs）发现抖音搜索的两半**登录要求不同**：
///
/// | 端点 | 匿名结果 |
/// |---|---|
/// | `general/search/single` | `2483 请先登录` |
/// | `general/search/stream` | `2483 请先登录` |
/// | `search/item` | `2483 请先登录` |
/// | `discover/search` | `2483 请先登录` |
/// | **`search/sug`** | **`code=0`，22148 字节真实候选词** |
///
/// 所以未登录时搜索框不该是死的——至少能给候选词。
/// 这组测试守两件事：
///  1. 联想词能力声明为支持，且与搜索结果能力分开
///  2. 联想词**失败时静默**（返回空），不打断用户输入
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/adapters/mock_adapter.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  group('能力声明：联想词与搜索结果分开', () {
    test('抖音：两者都支持', () {
      final a = DouyinAdapter(http: FusionHttpClient());
      expect(a.supportsSearch, isTrue);
      expect(a.supportsSearchSuggestions, isTrue,
          reason: 'search/sug 匿名实测 code=0，未登录也能给候选词');
    });

    test('B站：搜索结果支持，联想词如实声明未实现', () {
      final a = BilibiliAdapter(
        http: FusionHttpClient(),
        logger: FusionLogger(enabled: false),
      );
      expect(a.supportsSearch, isTrue);
      expect(a.supportsSearchSuggestions, isFalse,
          reason: '未实测的端点不声明为可用');
      expect(
        () => a.fetchSearchSuggestions('猫'),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.unsupportedPlatform,
        )),
      );
    });

    test('Mock：两者都不支持', () {
      final a = MockAdapter(http: FusionHttpClient());
      expect(a.supportsSearchSuggestions, isFalse);
    });
  });

  group('抖音联想词：空输入与失败都不打断输入', () {
    test('空关键词直接返回空列表，不发请求', () async {
      final a = DouyinAdapter(http: FusionHttpClient());
      expect(await a.fetchSearchSuggestions(''), isEmpty);
      expect(await a.fetchSearchSuggestions('   '), isEmpty);
    });

    test('会话未就绪时抛 capabilityUnavailable（可重试），不是静默空',
        () async {
      // 测试环境没有 WebView → signer 未就绪。
      // 这里要确认的是"如实报错"而不是"假装没有候选词"。
      final a = DouyinAdapter(http: FusionHttpClient());
      await expectLater(
        a.fetchSearchSuggestions('猫'),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.capabilityUnavailable,
        )),
      );
    });
  });

  group('实现约束（源码级）', () {
    late String src;
    setUpAll(() {
      src = File('lib/src/adapters/douyin_adapter.dart').readAsStringSync();
    });

    test('用 search/sug 端点', () {
      expect(src.contains("'/aweme/v1/web/search/sug/'"), isTrue);
    });

    test('取 sug_list[].content，并兼容 word_record.words_content', () {
      expect(src.contains("m['content']"), isTrue);
      expect(src.contains('words_content'), isTrue);
    });

    test('联想词失败返回空而不是抛（不打断输入）', () {
      // 解析失败 / 非 0 码都 return const []
      final idx = src.indexOf("'/aweme/v1/web/search/sug/'");
      expect(idx, greaterThan(0));
      final block = src.substring(idx, (idx + 2200).clamp(0, src.length));
      expect(
        block.contains('return const [];'),
        isTrue,
        reason: '联想词是锦上添花，失败不该弹错',
      );
    });
  });
}
