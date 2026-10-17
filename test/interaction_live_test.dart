/// 互动功能真实网络验证（Flutter 测试环境）。
///
/// 与 `smoke_interaction` 不同，这里用 `flutter test` 运行，
/// 因此可以使用依赖 Flutter 的模块（CredentialVault 等）。
///
/// 标记为 `network` 分组：默认 `flutter test` 会跳过真实网络用例，
/// 需要显式执行：
///   flutter test test/interaction_live_test.dart --tags network
///
/// 目的：在没有模拟器的环境下，仍能证明互动接口的解析与错误映射正确。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

/// 真实存在的公开视频（Rick Astley - Never Gonna Give You Up）。
const _bvid = 'BV1GJ411x7h7';

BilibiliAdapter _adapter() => BilibiliAdapter(
      http: FusionHttpClient(logger: FusionLogger(enabled: false)),
      logger: FusionLogger(enabled: false),
    );

/// 伪造的空会话，用于验证"登录态失效"路径。
PlatformSession _emptySession() => PlatformSession(
      platformId: 'bilibili',
      displayName: 'test',
      userId: '0',
      cookies: const {},
      loggedInAt: DateTime.now().toUtc().toIso8601String(),
    );

void main() {
  group('互动能力声明（离线）', () {
    test('B站支持全部互动能力', () {
      final a = _adapter();
      expect(a.supportsComments, isTrue);
      expect(a.supportsLike, isTrue);
      expect(a.supportsCoin, isTrue);
      expect(a.supportsFavorite, isTrue);
    });
  });

  group('评论列表（真实网络）', () {
    test('返回真实评论并正确解析字段', () async {
      final page = await _adapter().fetchComments(_bvid, page: 1, pageSize: 20);

      expect(page.items, isNotEmpty);
      expect(page.totalCount, greaterThan(0));

      final first = page.items.first;
      expect(first.id, isNotEmpty);
      expect(first.authorName, isNotEmpty);
      expect(first.message, isNotEmpty);
      // 平台用 <em> 高亮关键词，必须已剥离
      expect(first.message.contains('<em'), isFalse);
      expect(first.message.contains('</em>'), isFalse);
    }, tags: 'network');

    test('游标分页能连续取到不同评论且不重复', () async {
      final a = _adapter();

      // 第一页
      final p1 = await a.fetchComments(_bvid, page: 1, pageSize: 20);
      expect(p1.items, isNotEmpty);

      // 该视频评论很少时可能没有第二页——这本身是真实状态，不是缺陷。
      if (!p1.hasMore) {
        expect(p1.nextCursor, anyOf(0, greaterThan(0)));
        return;
      }

      // 用返回的游标取下一页
      final p2 = await a.fetchComments(
        _bvid,
        page: p1.nextCursor,
        pageSize: 20,
      );

      final ids1 = p1.items.map((c) => c.id).toSet();
      final ids2 = p2.items.map((c) => c.id).toSet();

      expect(ids1.intersection(ids2), isEmpty,
          reason: '游标分页不应返回重复条目');
    }, tags: 'network');

    test('未登录也能读到满页评论（不是只给 3 条）', () async {
      // 实测：旧接口 /x/v2/reply 未登录只返回 3 条；
      // 新接口 /x/v2/reply/main 返回满页。这条断言防止回退。
      final page = await _adapter().fetchComments(_bvid, page: 1, pageSize: 20);

      expect(
        page.items.length,
        greaterThan(3),
        reason: '应使用游标分页接口 /x/v2/reply/main，它返回满页',
      );
    }, tags: 'network');
  });

  group('未登录行为（真实网络）', () {
    test('互动状态为 unknown，不伪造"未点赞"', () async {
      final state = await _adapter().fetchInteractionState(_bvid);

      expect(state.known, isFalse);
      expect(state.liked, isFalse);
    }, tags: 'network');

    test('点赞被拒绝为 loginRequired', () async {
      expect(
        () => _adapter().setLike(
          _bvid,
          like: true,
          session: _emptySession(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.loginRequired,
          ),
        ),
      );
    }, tags: 'network');

    test('投币被拒绝为 loginRequired', () async {
      expect(
        () => _adapter().setCoin(
          _bvid,
          count: 1,
          session: _emptySession(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.loginRequired,
          ),
        ),
      );
    }, tags: 'network');

    test('收藏被拒绝（登录失效或无可用户收藏夹）', () async {
      expect(
        () => _adapter().setFavorite(
          _bvid,
          favorite: true,
          session: _emptySession(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            anyOf(
              FusionErrorCode.loginRequired,
              FusionErrorCode.permissionDenied,
            ),
          ),
        ),
      );
    }, tags: 'network');
  });

  group('视频统计（真实网络）', () {
    test('元数据含真实点赞与弹幕数', () async {
      final meta = await _adapter().fetchMetadata(
        const LinkMatch(
          platformId: 'bilibili',
          platformVideoId: _bvid,
          canonicalUrl: 'https://www.bilibili.com/video/$_bvid',
        ),
      );

      expect(meta.stats.likeCount, isNotNull);
      expect(meta.stats.likeCount, greaterThan(0));
      expect(meta.stats.danmakuCount, isNotNull);
    }, tags: 'network');
  });
}
