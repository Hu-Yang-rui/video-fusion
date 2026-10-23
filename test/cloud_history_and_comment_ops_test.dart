/// 云端历史 + 评论点赞/发表的离线回归。
///
/// # 这组测试守护什么
///
/// 本轮把抖音/B站的**云端历史、评论点赞、评论发表**接进 UI 链路。
/// 每条能力的接口可达性都已实测（见各适配器文档注释里的实测依据），
/// 这里固化的是**解析与编排**这两层，全部离线：
///
///  1. B站云端历史 `history/cursor` 的**字段分层**（实测 2026-10-22）：
///     标题/封面/作者/进度在**顶层**，只有 `bvid/oid` 在 `history` 内层。
///     旧实现从 `history` 里取 title/cover，恒为 null → 整页解析成空列表。
///     这条用例把这个坑钉死。
///  2. B站评论点赞回显：`up_action.like` → [VideoComment.isLikedByMe]。
///  3. VideoService.setCommentLike / replyComment 的**统一前置校验**：
///     未登录抛 loginRequired；平台不支持抛 unsupportedPlatform。
///  4. capabilitiesFor 把 commentLike/commentReply/cloudHistory 如实透传。
///  5. InteractionController 写评论的**不乐观更新**：
///     平台确认前不点亮，成功后刷新列表而不是本地插一条假的。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/cache.dart';
import 'package:video_fusion/src/core/cloud_progress_reporter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/secure_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/interaction.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';
import 'package:video_fusion/src/ui/interaction/interaction_controller.dart';

import 'support/no_im_support.dart';

// ── 夹具 ──────────────────────────────────────────────────────

class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
  @override
  Future<Set<String>> keys() async => data.keys.toSet();
}

VideoService buildService(PlatformAdapter adapter) => VideoService(
      registry: PlatformRegistry(adapters: [adapter]),
      store: VideoStore(storage: MemoryStore()),
      cache: VideoCache(),
    );

CredentialVault vaultWithSession({bool login = true}) {
  final vault = CredentialVault(storage: InMemorySecureStore());
  if (login) vault.save(_session());
  return vault;
}

PlatformSession _session() => const PlatformSession(
      platformId: 'fake',
      displayName: '测试用户',
      userId: '11066452',
      cookies: {'SESSDATA': 'x', 'bili_jct': 'y'},
      loggedInAt: '2026-10-22T00:00:00Z',
    );

UnifiedVideo _video() => UnifiedVideo(
      id: 'fake:v1',
      platformId: 'fake',
      platformVideoId: 'v1',
      originalUrl: 'https://fake.test/v1',
      canonicalUrl: 'https://fake.test/v1',
      title: '测试视频',
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      diagnostics: const VideoDiagnostics(
        adapterId: 'fake',
        upstreamEndpoint: '/test',
        fromCache: false,
        fetchDurationMs: 0,
      ),
    );

// ── B站真实接口形态（照抄 2026-10-22 实测响应，离线喂给适配器）─────

/// 按 URL 关键片段分派响应的 GET 替身（不触网）。
class _StubBiliHttp extends FusionHttpClient {
  _StubBiliHttp(this._bySubstring)
      : super(logger: FusionLogger(enabled: false));

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

/// `history/cursor` 实测条目：顶层有 title/cover/author_name，
/// history 内层只有 oid/bvid（**没有** title/cover）。
Map<String, Object?> _historyCursorResponse() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'list': [
          {
            'title': '发生在你身边的传闻！请辨别它是真是假！',
            'long_title': '',
            'cover': 'http://i1.hdslb.com/bfs/archive/abc.jpg',
            'uri': 'https://www.bilibili.com/video/BV1F6po6QEeF',
            'author_name': '某UP主',
            'author_face': 'http://face.jpg',
            'author_mid': 12345,
            'view_at': 1792334934,
            'progress': 120,
            'duration': 3511,
            'history': {
              'oid': 117429640370113,
              'bvid': 'BV1F6po6QEeF',
              'cid': 999,
              'business': 'archive',
            },
          },
        ],
        'cursor': {'max': 116814856131590, 'view_at': 1790918559},
      },
    };

/// `reply/main`：一条 up_action.like=true（我赞过），一条 like=false。
Map<String, Object?> _replyMainResponse() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'cursor': {'all_count': 2, 'next': 0, 'is_end': true},
        'replies': [
          {
            'rpid_str': '3760801399',
            'like': 769119,
            'ctime': 1700000000,
            'member': {'uname': '用户A', 'avatar': 'http://a.jpg', 'mid': 1},
            'content': {'message': '已赞过的评论'},
            'up_action': {'like': true, 'reply': false},
          },
          {
            'rpid_str': '3463001426',
            'like': 180172,
            'ctime': 1700000001,
            'member': {'uname': '用户B', 'avatar': 'http://b.jpg', 'mid': 2},
            'content': {'message': '没赞过的评论'},
            'up_action': {'like': false, 'reply': false},
          },
        ],
      },
    };

/// `x/web-interface/view`（_resolveAid 用）返回固定 aid。
Map<String, Object?> _viewResponse() => {
      'code': 0,
      'data': {'aid': 80433022, 'cid': 1, 'bvid': 'BV1GJ411x7h7'},
    };

void main() {
  group('B站云端历史解析（实测字段分层）', () {
    test('标题/封面/作者取顶层，bvid 取 history 内层', () async {
      final http = _StubBiliHttp({
        'history/cursor': _historyCursorResponse(),
      });
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));

      final page = await adapter.fetchHistoryVideos(session: _session());

      expect(page.items, hasLength(1),
          reason: '旧实现从 history 取 title 会解析成空，这里必须有 1 条');
      final v = page.items.single;
      expect(v.platformVideoId, 'BV1F6po6QEeF');
      expect(v.title, '发生在你身边的传闻！请辨别它是真是假！');
      expect(v.coverUrl, 'http://i1.hdslb.com/bfs/archive/abc.jpg');
      expect(v.author.name, '某UP主');
      expect(v.durationSeconds, 3511);
    });

    test('进度与观看时间挂到诊断说明（列表显示用）', () async {
      final http = _StubBiliHttp({'history/cursor': _historyCursorResponse()});
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));

      final v = (await adapter.fetchHistoryVideos(session: _session())).items.single;
      final notes = v.diagnostics.notes;
      expect(notes.any((n) => n.startsWith('看到 ')), isTrue,
          reason: 'progress=120 duration=3511 → 应生成"看到 02:00 / 58:31"');
      expect(notes.any((n) => n.startsWith('观看于 ')), isTrue);
    });

    test('游标透传：nextCursor 用 cursor.max，满页才算 hasMore', () async {
      final http = _StubBiliHttp({'history/cursor': _historyCursorResponse()});
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));

      final page = await adapter.fetchHistoryVideos(
        session: _session(),
        pageSize: 20,
      );
      expect(page.nextCursor, 116814856131590);
      // 本页 1 条 < ps 20 → 平台到顶，hasMore 必须 false
      expect(page.hasMore, isFalse);
      // 该接口不下发总数
      expect(page.total, -1);
    });

    test('请求带登录 Cookie，第一页不带 max', () async {
      final http = _StubBiliHttp({'history/cursor': _historyCursorResponse()});
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));
      await adapter.fetchHistoryVideos(session: _session());
      expect(http.requestedUrls.single, contains('history/cursor'));
      expect(http.requestedUrls.single, isNot(contains('max=')),
          reason: 'cursor=0 是第一页，不应带 max 参数');
    });
  });

  group('B站评论点赞回显（up_action.like）', () {
    test('登录态解析：like=true 的评论 isLikedByMe 为 true', () async {
      final http = _StubBiliHttp({
        'web-interface/view': _viewResponse(),
        'reply/main': _replyMainResponse(),
      });
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));

      final page = await adapter.fetchComments('BV1GJ411x7h7', session: _session());
      expect(page.items, hasLength(2));
      expect(page.items[0].isLikedByMe, isTrue);
      expect(page.items[1].isLikedByMe, isFalse);
    });
  });

  group('VideoService 评论写操作统一前置校验', () {
    test('未登录 setCommentLike 抛 loginRequired（不发请求）', () {
      final service = buildService(_FakeCommentAdapter());
      expect(
        () => service.setCommentLike(
          _video(),
          commentId: 'c1',
          like: true,
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.loginRequired,
          ),
        ),
      );
    });

    test('未登录 replyComment 抛 loginRequired', () {
      final service = buildService(_FakeCommentAdapter());
      expect(
        () => service.replyComment(_video(), message: '测试'),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.loginRequired,
          ),
        ),
      );
    });

    test('平台不支持评论点赞时抛 unsupportedPlatform', () async {
      final service =
          buildService(_FakeCommentAdapter(commentLike: false));
      await expectLater(
        service.setCommentLike(
          _video(),
          commentId: 'c1',
          like: true,
          session: _session(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.unsupportedPlatform,
          ),
        ),
      );
    });
  });

  group('capabilitiesFor 透传本轮新增能力位', () {
    test('commentLike / commentReply / cloudHistory 如实反映适配器声明',
        () {
      final service = buildService(
        _FakeCommentAdapter(
          commentLike: true,
          commentReply: true,
          cloudHistory: true,
        ),
      );
      final caps = service.capabilitiesFor('fake');
      expect(caps.commentLike, isTrue);
      expect(caps.commentReply, isTrue);
      expect(caps.cloudHistory, isTrue);
    });

    test('只点亮 commentReply 时 commentLike 仍为 false', () {
      final service = buildService(
        _FakeCommentAdapter(commentLike: false, commentReply: true),
      );
      final caps = service.capabilitiesFor('fake');
      expect(caps.commentLike, isFalse);
      expect(caps.commentReply, isTrue);
    });

    test('新能力不计入 hasAny（评论依附 comments）', () {
      final service = buildService(
        _FakeCommentAdapter(
          comments: false,
          like: false,
          coin: false,
          favorite: false,
          commentLike: true,
          commentReply: true,
        ),
      );
      final caps = service.capabilitiesFor('fake');
      // 一个只支持评论点赞/回复、不支持视频互动的平台，
      // 不该被判成"有互动区"
      expect(caps.hasAny, isFalse);
    });
  });

  group('platformSupportsCloudHistory', () {
    test('适配器声明 true → service 返回 true', () {
      final service = buildService(_FakeCommentAdapter(cloudHistory: true));
      expect(service.platformSupportsCloudHistory('fake'), isTrue);
    });
    test('未接入平台 → false', () {
      final service = buildService(_FakeCommentAdapter());
      expect(service.platformSupportsCloudHistory('unknown'), isFalse);
    });
  });

  group('InteractionController 写评论：不乐观更新', () {
    test('未登录点评论：记 lastMessage，不发请求', () async {
      final adapter = _FakeCommentAdapter();
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(login: false),
      );
      await controller.init();

      await controller.postComment('你好');
      expect(adapter.replyCalls, 0, reason: '未登录绝不能发请求');
      expect(controller.lastMessage, contains('登录'));
    });

    test('平台接受后刷新列表，不在本地插入假评论', () async {
      final adapter = _FakeCommentAdapter(publishNewId: 'c-new');
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();

      await controller.postComment('测试内容');
      expect(adapter.replyCalls, 1);
      expect(adapter.lastMessage, '测试内容');
      // 评论列表来自适配器（两条真实条目），没有本地拼进去的"c-new"
      expect(controller.comments.map((c) => c.id), isNot(contains('c-new')));
    });

    test('评论点赞：平台确认后才点亮状态位', () async {
      final adapter = _FakeCommentAdapter(
        commentLike: true,
        commentLikeAccepted: true,
      );
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();
      await controller.loadComments();

      final c0 = controller.comments.first;
      expect(c0.isLikedByMe, isFalse);

      await controller.toggleCommentLike(c0.id);
      expect(adapter.commentLikeCalls, 1);
      // 写成功后控制器把这条标记为已赞
      expect(controller.comments.first.isLikedByMe, isTrue);
    });

    test('评论点赞被拒：不点亮', () async {
      final adapter = _FakeCommentAdapter(
        commentLike: true,
        commentLikeAccepted: false,
      );
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();
      await controller.loadComments();

      await controller.toggleCommentLike(controller.comments.first.id);
      expect(controller.comments.first.isLikedByMe, isFalse,
          reason: '平台没接受就不能显示已赞');
    });

    test('平台不支持评论点赞时 toggleCommentLike 是空操作', () async {
      final adapter = _FakeCommentAdapter(commentLike: false);
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();
      await controller.loadComments();

      await controller.toggleCommentLike(controller.comments.first.id);
      expect(adapter.commentLikeCalls, 0, reason: '不支持就不该发请求');
    });
  });

  // ── 楼中楼（二级评论）────────────────────────────────────────

  group('B站楼中楼解析（实测 2026-10-23 /x/v2/reply/reply）', () {
    test('子评论 root/parent/isSubComment/up_action 正确分层解析', () async {
      final http = _StubBiliHttp({
        'web-interface/view': _viewResponse(),
        'reply/reply': _replyReplyResponse(),
      });
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));

      final page = await adapter.fetchCommentReplies(
        'BV1GJ411x7h7',
        parentCommentId: '3760801399',
        session: _session(),
      );

      expect(page.items, hasLength(2));
      final s = page.items.first;
      expect(s.id, '4012538137');
      // 实测：二级评论带 root（所属一级）；回复一级时 parent==root
      expect(s.rootCommentId, '3760801399');
      expect(s.parentCommentId, '3760801399');
      expect(s.isSubComment, isTrue);
      // up_action.like=false → 未赞过
      expect(s.isLikedByMe, isFalse);
      // 第二条我赞过 → 点亮
      expect(page.items[1].isLikedByMe, isTrue);
      // 总数来自 data.page.count
      expect(page.totalCount, 2216);
    });

    test('一级评论不带 root/parent（isSubComment=false）', () async {
      final http = _StubBiliHttp({
        'web-interface/view': _viewResponse(),
        'reply/main': _replyMainResponse(),
      });
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));

      final page = await adapter.fetchComments('BV1GJ411x7h7');
      expect(page.items.first.isSubComment, isFalse);
      expect(page.items.first.rootCommentId, isNull);
    });

    test('请求用 pn（页码）不用 next（实测 next 在本接口不生效）', () async {
      final http = _StubBiliHttp({
        'web-interface/view': _viewResponse(),
        'reply/reply': _replyReplyResponse(),
      });
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));
      await adapter.fetchCommentReplies(
        'BV1GJ411x7h7',
        parentCommentId: '3760801399',
        page: 2,
        session: _session(),
      );
      final url = http.requestedUrls.last;
      expect(url, contains('pn=2'));
      expect(url, contains('root=3760801399'));
      expect(url, isNot(contains('next=')),
          reason: 'reply/reply 用 pn，next 在实测里恒返回第一页');
    });
  });

  group('控制器楼中楼：惰性加载 + 两层点赞/回显', () {
    test('平台不支持读回复时 supportsSubComments=false 且不发请求', () async {
      final adapter = _FakeCommentAdapter(commentReplies: false);
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();

      expect(controller.supportsSubComments, isFalse);
      await controller.loadSubComments('c1');
      expect(adapter.subReplyCalls, 0);
    });

    test('展开才拉，拉后缓存，点赞二级评论透传它的 level', () async {
      final adapter = _FakeCommentAdapter(commentReplies: true);
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();

      // 未展开：没有子评论
      expect(controller.subCommentsOf('c1'), isEmpty);

      await controller.loadSubComments('c1');
      expect(adapter.subReplyCalls, 1);
      expect(controller.subCommentsOf('c1'), isNotEmpty);
      final sub = controller.subCommentsOf('c1').first;
      expect(sub.isSubComment, isTrue);
      expect(sub.replyLevel, 2);

      // 点赞一条二级评论：level 必须透传（抖音 comment/digg 要它）
      await controller.toggleCommentLike(sub.id);
      expect(adapter.commentLikeCalls, 1);
      expect(adapter.lastReplyLevel, 2,
          reason: '二级评论的 level 要回传给平台，不能写死 0');
      // 就地回显到子列表（不能只更新顶层）
      expect(controller.subCommentsOf('c1').first.isLikedByMe, isTrue);
    });

    test('回复二级评论：自动带上它所属的 root', () async {
      final adapter = _FakeCommentAdapter(commentReplies: true);
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();
      await controller.loadSubComments('c1');
      final sub = controller.subCommentsOf('c1').first;

      await controller.postComment('回复内容', replyToCommentId: sub.id);
      expect(adapter.lastReplyTo, sub.id);
      expect(adapter.lastRootForReply, 'c1',
          reason: '回复二级评论要 root=所属一级评论（两平台都要 root≠parent）');
    });

    test('刷新顶层评论时楼中楼缓存一起失效', () async {
      final adapter = _FakeCommentAdapter(commentReplies: true);
      final controller = InteractionController(
        video: _video(),
        service: buildService(adapter),
        vault: vaultWithSession(),
      );
      await controller.init();
      await controller.loadSubComments('c1');
      expect(controller.subCommentsOf('c1'), isNotEmpty);

      await controller.loadComments(refresh: true);
      expect(controller.subCommentsOf('c1'), isEmpty,
          reason: '旧快照的展开态不能挂在新评论下');
    });
  });

  // ── 云端播放进度旁路 ───────────────────────────────────────────

  group('CloudProgressReporter：本地权威、云端尽力而为', () {
    test('平台不支持 → 一次都不发', () async {
      final adapter = _FakeCommentAdapter(cloudProgress: false);
      final reporter = CloudProgressReporter(
        service: buildService(adapter),
        vault: vaultWithSession(),
        logger: FusionLogger(enabled: false),
      );
      reporter.maybeReport(
        videoId: 'fake:v1',
        platformId: 'fake',
        platformVideoId: 'v1',
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 60),
      );
      await _flushMicrotasks();
      expect(adapter.progressCalls, 0);
    });

    test('未登录 → 不发请求', () async {
      final adapter = _FakeCommentAdapter(cloudProgress: true);
      final reporter = CloudProgressReporter(
        service: buildService(adapter),
        vault: vaultWithSession(login: false),
        logger: FusionLogger(enabled: false),
      );
      reporter.maybeReport(
        videoId: 'fake:v1',
        platformId: 'fake',
        platformVideoId: 'v1',
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 60),
      );
      await _flushMicrotasks();
      expect(adapter.progressCalls, 0, reason: '没有会话就不上报');
    });

    test('已登录 + 支持 → 上报一次，位置/时长原样到达', () async {
      final adapter = _FakeCommentAdapter(cloudProgress: true);
      final reporter = CloudProgressReporter(
        service: buildService(adapter),
        vault: vaultWithSession(),
        logger: FusionLogger(enabled: false),
      );
      reporter.maybeReport(
        videoId: 'fake:v1',
        platformId: 'fake',
        platformVideoId: 'v1',
        position: const Duration(seconds: 42),
        duration: const Duration(seconds: 300),
      );
      await _flushMicrotasks();
      expect(adapter.progressCalls, 1);
      expect(adapter.lastReportedPosition, const Duration(seconds: 42));
      expect(adapter.lastReportedDuration, const Duration(seconds: 300));
    });

    test('节流：minInterval 内同一视频只发一次', () async {
      final adapter = _FakeCommentAdapter(cloudProgress: true);
      final reporter = CloudProgressReporter(
        service: buildService(adapter),
        vault: vaultWithSession(),
        logger: FusionLogger(enabled: false),
        minInterval: const Duration(minutes: 5),
      );
      for (var i = 0; i < 10; i++) {
        reporter.maybeReport(
          videoId: 'fake:v1',
          platformId: 'fake',
          platformVideoId: 'v1',
          position: Duration(seconds: 5 * i),
          duration: const Duration(seconds: 300),
        );
      }
      await _flushMicrotasks();
      expect(adapter.progressCalls, 1,
          reason: 'B站连续第 6 个请求起 412，不节流必被打死');
    });

    test('上报失败被吞掉，不影响播放（本地进度才是权威）', () async {
      final adapter = _FakeCommentAdapter(
        cloudProgress: true,
        progressError: FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '平台拒绝',
          platformId: 'fake',
        ),
      );
      final reporter = CloudProgressReporter(
        service: buildService(adapter),
        vault: vaultWithSession(),
        logger: FusionLogger(enabled: false),
      );
      // maybeReport 不抛
      reporter.maybeReport(
        videoId: 'fake:v1',
        platformId: 'fake',
        platformVideoId: 'v1',
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 60),
      );
      await _flushMicrotasks();
      expect(adapter.progressCalls, 1);
      // 且失败不炸：没抛出即通过。
    });

    test('invalidateSessions 后立刻可再报（刚导入 Cookie）', () async {
      final adapter = _FakeCommentAdapter(cloudProgress: true);
      final reporter = CloudProgressReporter(
        service: buildService(adapter),
        vault: vaultWithSession(),
        logger: FusionLogger(enabled: false),
        minInterval: const Duration(minutes: 5),
      );
      reporter.maybeReport(
        videoId: 'fake:v1',
        platformId: 'fake',
        platformVideoId: 'v1',
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 60),
      );
      await _flushMicrotasks();
      expect(adapter.progressCalls, 1);

      reporter.invalidateSessions();
      reporter.maybeReport(
        videoId: 'fake:v1',
        platformId: 'fake',
        platformVideoId: 'v1',
        position: const Duration(seconds: 20),
        duration: const Duration(seconds: 60),
      );
      await _flushMicrotasks();
      expect(adapter.progressCalls, 2,
          reason: '登录态变化后节流窗口必须清掉，否则要等窗口到期');
    });
  });
}

/// 让 `maybeReport` 里 unawaited 的 Future 跑完。
Future<void> _flushMicrotasks() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

/// 实测形态的 `/x/v2/reply/reply` 响应（真实账号 2026-10-23）。
Map<String, Object?> _replyReplyResponse() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'page': {'num': 1, 'size': 10, 'count': 2216},
        'replies': [
          {
            'rpid_str': '4012538137',
            'root': 3760801399,
            'parent': 3760801399,
            'like': 1527,
            'ctime': 1700000000,
            'member': {'uname': 'WtfWasThat', 'avatar': 'http://x.jpg', 'mid': 5},
            'content': {'message': '二级评论内容'},
            'up_action': {'like': false, 'reply': false},
          },
          {
            'rpid_str': '4057142592',
            'root_str': '3760801399',
            'parent_str': '4012538137',
            'like': 3,
            'ctime': 1700000100,
            'member': {'uname': '用户C', 'avatar': 'http://c.jpg', 'mid': 6},
            'content': {'message': '回复楼中楼'},
            'up_action': {'like': true, 'reply': false},
          },
        ],
      },
    };

/// 支持评论点赞/发表/云端历史的可编程替身。
///
/// 用 `extends PlatformAdapter with NoImSupport`：只继承需要断言的成员，
/// 其余走接口默认实现（抛 unsupportedPlatform）。
class _FakeCommentAdapter extends PlatformAdapter with NoImSupport {
  _FakeCommentAdapter({
    this.comments = true,
    this.like = true,
    this.coin = false,
    this.favorite = false,
    this.commentLike = true,
    this.commentReply = true,
    this.cloudHistory = false,
    this.commentReplies = false,
    this.cloudProgress = false,
    this.publishNewId,
    this.commentLikeAccepted = true,
    this.progressError,
  });

  final bool comments;
  final bool like;
  final bool coin;
  final bool favorite;
  final bool commentLike;
  final bool commentReply;
  final bool cloudHistory;
  final bool commentReplies;
  final bool cloudProgress;

  /// reportPlaybackProgress 抛出的错误（复现"平台没收下上报"，测旁路降级）。
  final FusionException? progressError;

  /// replyComment 返回的新评论 id（模拟平台回传）。
  final String? publishNewId;
  final bool commentLikeAccepted;

  int replyCalls = 0;
  int commentLikeCalls = 0;
  int historyCalls = 0;
  int subReplyCalls = 0;
  int progressCalls = 0;
  String? lastMessage;
  String? lastReplyTo;
  bool? lastLikeTarget;
  String? lastCommentId;

  /// 楼中楼 / 云端进度的入参记录（断言"level 与 root 有没有透传"）。
  int? lastReplyLevel;
  String? lastRootForReply;
  String? lastSubParentId;
  Duration? lastReportedPosition;
  Duration? lastReportedDuration;

  @override
  bool get supportsCommentReplies => commentReplies;
  @override
  bool get supportsCloudProgress => cloudProgress;

  @override
  Future<CommentPage> fetchCommentReplies(
    String platformVideoId, {
    required String parentCommentId,
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    subReplyCalls++;
    lastSubParentId = parentCommentId;
    return CommentPage(
      items: [
        VideoComment(
          id: 's$page',
          authorName: '子评论者',
          message: '第 $page 页的回复',
          createdAt: '2026-10-23T00:00:00Z',
          rootCommentId: parentCommentId,
          parentCommentId: parentCommentId,
          isSubComment: true,
          replyLevel: 2,
        ),
      ],
      page: page,
      totalCount: 5,
      hasMore: page < 3,
    );
  }

  @override
  Future<void> reportPlaybackProgress({
    required String platformVideoId,
    required Duration position,
    required Duration duration,
    required PlatformSession session,
    int? partNumber,
  }) async {
    progressCalls++;
    lastReportedPosition = position;
    lastReportedDuration = duration;
    if (progressError != null) throw progressError!;
  }

  @override
  String get id => 'fake';
  @override
  String get displayName => '测试平台';
  @override
  String get shortLabel => '测试';
  @override
  AdapterCapabilities get capabilities => const AdapterCapabilities(
        supportsMetadata: true,
        supportsNativePlayback: true,
        supportsOfficialEmbed: false,
        supportsExternalFallback: true,
      );
  @override
  List<String> get supportedHosts => const ['fake.test'];
  @override
  bool matches(Uri uri) => uri.host == 'fake.test';
  @override
  Future<LinkMatch?> extract(Uri uri) async => null;
  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async =>
      const VideoMetadata(title: 'fake');
  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async =>
      null;

  @override
  bool get supportsComments => comments;
  @override
  bool get supportsLike => like;
  @override
  bool get supportsCoin => coin;
  @override
  bool get supportsFavorite => favorite;

  @override
  bool get supportsCommentLike => commentLike;
  @override
  bool get supportsCommentReply => commentReply;
  @override
  bool get supportsCloudHistory => cloudHistory;

  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    if (!comments) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '不支持评论',
        platformId: id,
      );
    }
    return const CommentPage(
      items: [
        VideoComment(
          id: 'c1',
          authorName: '用户A',
          message: '第一条评论',
          createdAt: '2026-10-01T00:00:00Z',
          likeCount: 10,
        ),
      ],
      page: 1,
      totalCount: 1,
      hasMore: false,
    );
  }

  @override
  Future<InteractionResult> setCommentLike(
    String platformVideoId, {
    required String commentId,
    required bool like,
    required PlatformSession session,
    int? replyLevel,
  }) async {
    commentLikeCalls++;
    lastCommentId = commentId;
    lastLikeTarget = like;
    lastReplyLevel = replyLevel;
    return InteractionResult(accepted: commentLikeAccepted);
  }

  @override
  Future<String?> replyComment(
    String platformVideoId, {
    required String message,
    required PlatformSession session,
    String? replyToCommentId,
    String? rootCommentId,
  }) async {
    replyCalls++;
    lastMessage = message;
    lastReplyTo = replyToCommentId;
    lastRootForReply = rootCommentId;
    return publishNewId;
  }

  @override
  Future<SavedVideoPage> fetchHistoryVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
    int cursor = 0,
  }) async {
    historyCalls++;
    return const SavedVideoPage(
      items: [],
      hasMore: false,
      total: -1,
      upstreamEndpoint: '/fake/history',
    );
  }
}
