/// 关注 UP 主的离线回归（2026-10-23）。
///
/// # 这组测试守护什么
///
/// 本轮修了抖音关注的两个真 bug，都是"看起来能用、实际点了没反应"那类：
///
///  1. **作者 id 填错**：信息流映射填 `uid`，但 `commit/follow/user`
///     认的是 `sec_user_id` → 从推荐流/搜索点关注必然失败；而详情页
///     另一条映射填的是 `sec_uid`，所以详情页能用、信息流不能用，
///     表现成"有时候关注得上，有时候点了没反应"。
///  2. **关注态读不到**：`fetchInteractionState` 直接返回 unknown
///     → 按钮永远显示"关注"，关注成功后刷新仍是 unknown，按钮不变化。
///
/// 第 2 个修复引出一个**语义陷阱**：抖音的 aweme/detail 里能确认
/// `author.follow_status`，但没有"我是否点赞/收藏"的字段。若为此把
/// `known` 设成 true，UI 会把 `liked=false` 当成"未点赞"渲染
/// （详情页用 `active: state.liked` 控制高亮），已点赞的视频会显示成没点过。
/// 所以新增独立的 `followKnown`，只声明关注态可信。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/interaction.dart';

/// 实测（2026-10-23，aweme/detail 真实响应）的 author 关键字段。
/// uid 是纯数字，sec_uid 是 MS4wLjABAAAA 开头——两者都在，但关注接口只认后者。
const String _realUid = '3890515065704004';
const String _realSecUid =
    'MS4wLjABAAAAw6TYfM7-7NTiOcVflQUIJS8rBxd-hIRm1knmiOeOSW72VG11qS7HlqNPEj0YKazO';

PlatformSession _session() => const PlatformSession(
      platformId: 'douyin',
      displayName: '测试',
      userId: '1',
      cookies: {'sessionid': 'x'},
      loggedInAt: '2026-10-23T00:00:00Z',
    );

void main() {
  group('InteractionState.followKnown 语义', () {
    test('默认 false：unknown 态不得被当成"未关注"', () {
      expect(InteractionState.unknown.followKnown, isFalse);
      expect(InteractionState.unknown.following, isFalse);
    });

    test('copyWith 保留 followKnown（写后刷新不会把它冲掉）', () {
      const s = InteractionState(known: false, followKnown: true, following: true);
      expect(s.copyWith(liked: true).followKnown, isTrue);
      expect(s.copyWith(liked: true).following, isTrue);
    });

    test('B站 relation 一次给全：known 与 followKnown 同时为 true', () {
      // B站的 attention 与 like/favorite 同批返回，两者都可信。
      final http = _StubHttp({
        'archive/relation': {
          'code': 0,
          'data': {'attention': true, 'favorite': false, 'like': false, 'coin': 0},
        },
      });
      final adapter =
          BilibiliAdapter(http: http, logger: FusionLogger(enabled: false));
      final state = adapter.fetchInteractionState(
        'BV1GJ411x7h7',
        session: const PlatformSession(
          platformId: 'bilibili',
          displayName: 't',
          userId: '1',
          cookies: {'SESSDATA': 'x'},
          loggedInAt: '2026-10-23T00:00:00Z',
        ),
      );
      return state.then((s) {
        expect(s.known, isTrue);
        expect(s.followKnown, isTrue);
        expect(s.following, isTrue);
      });
    });
  });

  group('抖音关注：作者 id 必须是 sec_uid', () {
    // 抖音的请求走 WebView signer（`_writeRequest` → `DouyinWebSigner`），
    // 测试环境没有 WebView，所以**没法**用 HTTP stub 走通真实解析路径。
    // 这两条用源码约束守——它们要防的是"映射写错字段"这种回归，
    // 而字段名在源码里是确定的，比伪造一个 WebView 更可靠。
    late String src;
    setUpAll(() {
      src = File('lib/src/adapters/douyin_adapter.dart').readAsStringSync();
    });

    test('信息流映射取 sec_uid，不再用裸 uid', () {
      // 信息流（_awemeToVideo）必须优先 sec_uid
      expect(
        src.contains("platformAuthorId: _nullableString(author['sec_uid'])"),
        isTrue,
        reason: 'commit/follow/user 认 sec_user_id；填 uid 会让推荐流点关注必失败',
      );
      // 且不能再有"只取 uid"的映射
      expect(
        src.contains("platformAuthorId: _nullableString(author['uid']),"),
        isFalse,
        reason: '裸 uid 映射会让关注失败（详情页能用、信息流不能用的那种怪象）',
      );
    });

    test('关注态读 author.follow_status，不再恒 unknown', () {
      expect(src.contains("author['follow_status']"), isTrue);
      expect(
        src.contains('Future<InteractionState> fetchInteractionState') &&
            !src.contains('''  }) async =>
      InteractionState.unknown;'''),
        isTrue,
        reason: '旧实现直接返回 unknown，关注按钮永远显示"关注"',
      );
    });

    test('known 与 followKnown 分开：抖音不能声称点赞态已知', () {
      // 抖音的响应里没有"我是否点赞"，known 必须保持 false，
      // 否则详情页 `active: state.liked` 会把已点赞显示成未点赞。
      final idx = src.indexOf("author['follow_status']");
      expect(idx, greaterThan(0));
      final block = src.substring(idx, (idx + 700).clamp(0, src.length));
      expect(block.contains('known: false'), isTrue,
          reason: '抖音确认不了点赞/收藏态，known 必须 false');
      expect(block.contains('followKnown: true'), isTrue,
          reason: '关注态可信，单独用 followKnown 声明');
    });
  });

  group('抖音关注态读取（源码约束）', () {
    // 同上一组：抖音走 WebView，测试环境无法走通真实请求，
    // 这里守的是"解析逻辑有没有正确读字段 + 语义有没有搞错"。
    late String src;
    setUpAll(() {
      src = File('lib/src/adapters/douyin_adapter.dart').readAsStringSync();
    });

    test('follow_status 非 0 视为已关注', () {
      expect(src.contains('following: followStatus != 0'), isTrue,
          reason: '平台用 0 表示未关注，其余取值都算已关注');
    });

    test('未登录直接 unknown（不冒充"未关注"）', () {
      final idx = src.indexOf('Future<InteractionState> fetchInteractionState');
      final block = src.substring(idx, (idx + 400).clamp(0, src.length));
      expect(block.contains('if (session == null) return InteractionState.unknown;'),
          isTrue);
    });

    test('缺 follow_status 时返回 unknown，不猜', () {
      expect(src.contains('if (followStatus == null) return InteractionState.unknown;'),
          isTrue);
    });
  });

  group('关注写入前置校验', () {
    test('抖音：空 sec_user_id 直接 videoIdNotFound，不发请求', () async {
      final adapter = DouyinAdapter(
        http: _StubHttp({}),
        logger: FusionLogger(enabled: false),
      );
      await expectLater(
        adapter.setFollowAuthor(
          targetMid: '  ',
          follow: true,
          session: _session(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.videoIdNotFound,
          ),
        ),
      );
    });
  });
}

/// 实测形态的 aweme/detail 响应（author 两个 id 都在）。
Map<String, Object?> _detailResponse({required int followStatus}) => {
      'status_code': 0,
      'aweme_detail': {
        'aweme_id': '7345492945006595379',
        'desc': '测试视频',
        'author': {
          'uid': _realUid,
          'sec_uid': _realSecUid,
          'nickname': '复古百晓生',
          'follow_status': followStatus,
          'follower_count': 1000,
        },
        'video': {
          'width': 1080,
          'height': 1920,
          'duration': 60000,
          'play_addr': {
            'url_list': ['https://example.invalid/v.mp4'],
          },
        },
        'statistics': {'digg_count': 12345, 'comment_count': 678},
      },
    };

/// 按 URL 片段分派的 GET 替身（不触网）。
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
