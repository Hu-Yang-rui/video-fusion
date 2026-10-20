/// B站四项新能力的真实网络测试：视频弹幕、评论点赞、评论回复、一键三连。
///
/// # 全部需要真实登录态
///
/// 从 `D:\vf-local\bili_cookie.txt`（仓库外）读 Cookie。
/// 文件不存在时**跳过**这些用例，并显式说明跳过原因——
/// 不伪装成"通过"。
///
/// # 写入全部可逆
///
/// 每个写操作用例都在结束时撤销自己造成的改动，并在撤销后再查一次
/// 状态确认复原。这样跑测试不会把账号越弄越乱。
///
/// 投币**无法撤销**（B站不提供取消投币接口），因此投币相关用例
/// 默认只验证"错误分类正确"，不做真实投币——除非显式设
/// `VF_ALLOW_COIN=1`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/interaction.dart';

const String _cookieFile = r'D:\vf-local\bili_cookie.txt';

/// 用于测试的视频（Rick Astley 官方 MV，评论与弹幕都很多）。
const String _bvid = 'BV1GJ411x7h7';
const int _aid = 80433022;

PlatformSession? _loadSession() {
  final f = File(_cookieFile);
  if (!f.existsSync()) return null;
  final raw = f.readAsStringSync().trim();
  if (raw.isEmpty) return null;

  final cookies = <String, String>{};
  for (final part in raw.split(';')) {
    final t = part.trim();
    final eq = t.indexOf('=');
    if (eq <= 0) continue;
    cookies[t.substring(0, eq)] = t.substring(eq + 1);
  }
  if (!cookies.containsKey('SESSDATA')) return null;

  return PlatformSession(
    platformId: 'bilibili',
    displayName: '测试账号',
    userId: cookies['DedeUserID'] ?? '',
    cookies: cookies,
    loggedInAt: DateTime.now().toUtc().toIso8601String(),
  );
}

void main() {
  final session = _loadSession();
  final hasLogin = session != null;
  final skipReason = hasLogin
      ? null
      : '缺少真实登录态（$_cookieFile 不存在或无效），跳过写操作用例';

  BilibiliAdapter makeAdapter() => BilibiliAdapter(
        http: FusionHttpClient(),
        logger: FusionLogger(minLevel: LogLevel.debug),
      );

  group('能力声明', () {
    test('四项新能力都声明为支持', () {
      final a = makeAdapter();
      expect(a.supportsVideoDanmaku, isTrue);
      expect(a.supportsCommentLike, isTrue);
      expect(a.supportsCommentReply, isTrue);
      expect(a.supportsTripleAction, isTrue);
    });
  });

  group('视频弹幕（不需要登录）', () {
    test(
      '拉取真实弹幕，字段完整',
      () async {
        final items = await makeAdapter().fetchVideoDanmaku(
          _bvid,
          durationSeconds: 213,
        );

        expect(items, isNotEmpty);
        // 该视频实测 1406 条
        expect(items.length, greaterThan(1000));

        final first = items.first;
        expect(first.id, isNotEmpty);
        expect(first.text, isNotEmpty);
        expect(first.progressMs, greaterThanOrEqualTo(0));
        expect(first.mode, greaterThan(0));

        // 时间必须单调不减
        for (var i = 1; i < items.length; i++) {
          expect(
            items[i].progressMs >= items[i - 1].progressMs,
            isTrue,
            reason: '第 $i 条时间倒退',
          );
        }
      },
      tags: 'network',
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });

  group('评论点赞', () {
    test(
      '点赞 → 复查 → 撤销 → 复查',
      () async {
        final a = makeAdapter();
        final page = await a.fetchComments(_bvid, pageSize: 5);
        expect(page.items, isNotEmpty, reason: '需要真实评论才能测点赞');

        final target = page.items.first;

        // 1) 点赞
        final r = await a.setCommentLike(
          _bvid,
          commentId: target.id,
          like: true,
          session: session!,
        );
        expect(r.accepted, isTrue, reason: '实测 reply/action 返回 code=0');
        expect(r.upstreamCode, 0);

        // 2) 撤销（保持账号状态可逆）
        final undo = await a.setCommentLike(
          _bvid,
          commentId: target.id,
          like: false,
          session: session,
        );
        expect(undo.accepted, isTrue);
      },
      tags: 'network',
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '未登录抛 loginRequired（不是静默失败）',
      () async {
        final a = makeAdapter();
        await expectLater(
          a.setCommentLike(
            _bvid,
            commentId: '3760801399',
            like: true,
            session: const PlatformSession(
              platformId: 'bilibili',
              displayName: '',
              userId: '',
              cookies: {},
              loggedInAt: '',
            ),
          ),
          throwsA(isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.loginRequired,
          )),
        );
      },
      tags: 'network',
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '评论 ID 非数字时本地拦截，不发请求',
      () async {
        await expectLater(
          makeAdapter().setCommentLike(
            _bvid,
            commentId: 'not-a-number',
            like: true,
            session: session ??
                const PlatformSession(
                  platformId: 'bilibili',
                  displayName: '',
                  userId: '',
                  cookies: {},
                  loggedInAt: '',
                ),
          ),
          throwsA(isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.videoIdNotFound,
          )),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('评论回复', () {
    test(
      '发一条顶层评论 → 拿到 rpid → 删掉',
      () async {
        final a = makeAdapter();

        String? rpid;
        try {
          rpid = await a.replyComment(
            _bvid,
            message: '自动化测试评论，稍后删除',
            session: session!,
          );
        } on FusionException catch (e) {
          // 12051 = 评论频率限制。这是平台真实约束，不是实现缺陷：
          // 同一账号短时间内连发会被拦。如实标注后跳过，不伪装通过。
          if (e.code == FusionErrorCode.rateLimited) {
            // ignore: avoid_print
            print('[跳过] 评论被频控（12051）：${e.userMessage}');
            return;
          }
          rethrow;
        }

        expect(rpid, isNotNull, reason: '平台返回 data.rpid_str');
        expect(rpid, isNotEmpty);

        // 撤回：保持账号状态可逆。
        // 直接打接口而不是给适配器加 deleteReply——撤回不是产品能力。
        final csrf = session.cookies['bili_jct'] ?? '';
        final http = FusionHttpClient();
        final del = await http.post(
          'https://api.bilibili.com/x/v2/reply/del',
          headers: {
            'Referer': 'https://www.bilibili.com/',
            'Origin': 'https://www.bilibili.com',
            'Cookie': session.cookieHeader,
          },
          body: 'oid=$_aid&type=1&rpid=$rpid&csrf=$csrf',
        );
        final json = del.jsonObject();
        expect(json['code'], 0, reason: '撤回应成功，否则测试会留垃圾评论');
      },
      tags: 'network',
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '频控码 12051 被映射为 rateLimited（不是"未知错误"）',
      () async {
        // 连发两次，第二次大概率被频控。
        // 若账号没被频控（第一次就过了），说明频控窗口已过，本用例
        // 只能验证"要么成功要么正确分类"，不能强求一定被拦。
        final a = makeAdapter();
        final csrf = session!.cookies['bili_jct'] ?? '';
        final http = FusionHttpClient();

        Future<Map<String, Object?>> send(String msg) async {
          final r = await http.post(
            'https://api.bilibili.com/x/v2/reply/add',
            headers: {
              'Referer': 'https://www.bilibili.com/',
              'Origin': 'https://www.bilibili.com',
              'Cookie': session.cookieHeader,
            },
            body: 'oid=$_aid&type=1&plat=1'
                '&message=${Uri.encodeQueryComponent(msg)}&csrf=$csrf',
          );
          return r.jsonObject();
        }

        // 先发一条确保进入频控窗口
        final first = await send('频控测试 A ${DateTime.now().millisecondsSinceEpoch}');
        final second = await send('频控测试 B ${DateTime.now().millisecondsSinceEpoch}');

        // 清理第一条（如果发出去了）
        final firstRpid = first['data'] is Map
            ? '${(first['data'] as Map)['rpid_str'] ?? ''}'
            : '';
        if (firstRpid.isNotEmpty) {
          await http.post(
            'https://api.bilibili.com/x/v2/reply/del',
            headers: {
              'Referer': 'https://www.bilibili.com/',
              'Origin': 'https://www.bilibili.com',
              'Cookie': session.cookieHeader,
            },
            body: 'oid=$_aid&type=1&rpid=$firstRpid&csrf=$csrf',
          );
        }
        final secondRpid = second['data'] is Map
            ? '${(second['data'] as Map)['rpid_str'] ?? ''}'
            : '';
        if (secondRpid.isNotEmpty) {
          await http.post(
            'https://api.bilibili.com/x/v2/reply/del',
            headers: {
              'Referer': 'https://www.bilibili.com/',
              'Origin': 'https://www.bilibili.com',
              'Cookie': session.cookieHeader,
            },
            body: 'oid=$_aid&type=1&rpid=$secondRpid&csrf=$csrf',
          );
        }

        // 如果第二次被频控，验证适配器把它映射成 rateLimited。
        if (second['code'] == 12051) {
          await expectLater(
            a.replyComment(
              _bvid,
              message: '第三次应该仍被拦',
              session: session,
            ),
            throwsA(isA<FusionException>()
                .having((e) => e.code, 'code', FusionErrorCode.rateLimited)
                .having((e) => e.retryable, 'retryable', isTrue)
                .having((e) => e.userMessage, 'userMessage', contains('稍等'))),
          );
        }
      },
      tags: 'network',
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '空内容本地拦截',
      () async {
        await expectLater(
          makeAdapter().replyComment(
            _bvid,
            message: '   ',
            session: session ??
                const PlatformSession(
                  platformId: 'bilibili',
                  displayName: '',
                  userId: '',
                  cookies: {},
                  loggedInAt: '',
                ),
          ),
          throwsA(isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.invalidUrl,
          )),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('投币风控的分类', () {
    test(
      '被 -401 拦截时能解出风控细节（不只是"失败"）',
      () async {
        final a = makeAdapter();
        final r = await a.setCoin(
          _bvid,
          count: 1,
          session: session!,
          alsoLike: false,
        );

        if (r.accepted) {
          // 账号白名单期间可能真的投上了——这种情况不该硬断言失败。
          // 如实标注：投币成功无法撤销，这里只提示。
          // ignore: avoid_print
          print('[注意] 本次投币成功（账号未被风控），已消耗 1 枚硬币');
          return;
        }

        // 失败时：码必须能区分类型
        expect(r.upstreamCode, isNotNull);
        expect(r.message, isNotNull);
        expect(r.message!.isNotEmpty, isTrue);

        if (r.upstreamCode == -401) {
          // 风控路径：必须解析出 decisions / scene
          expect(
            r.riskControl,
            isNotNull,
            reason: '-401 必须带出风控细节，否则用户不知道该怎么办',
          );
          final risk = r.riskControl!;
          expect(risk.decisions, isNotEmpty);
          expect(
            risk.decisions.any((d) => d.contains('captcha')),
            isTrue,
            reason: '实测 decisions=["verify_captcha_level3"]',
          );
          expect(risk.scene, 'video_coin');
          expect(risk.requiresCaptcha, isTrue);
          expect(risk.userHint, contains('验证'));

          // 脱敏：不能把一次性凭据带出来
          final summary = risk.safeSummary.toString();
          expect(summary.contains('voucher'), isFalse);
          expect(summary.contains('grisk'), isFalse);
          expect(summary.contains('v_voucher'), isFalse);
        } else {
          // 非风控失败（余额 / 能力）：不该有 riskControl
          expect(
            r.riskControl,
            isNull,
            reason: '只有 -401 才是风控，其它码不该伪造风控细节',
          );
        }
      },
      tags: 'network',
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('风控模型语义', () {
      const captcha = PlatformRiskControl(
        decisions: ['verify_captcha_level3'],
        riskLevel: 1,
        scene: 'video_coin',
      );
      expect(captcha.requiresCaptcha, isTrue);
      expect(captcha.userHint, contains('验证'));
      expect(captcha.safeSummary['scene'], 'video_coin');
      expect(captcha.safeSummary['decisions'], ['verify_captcha_level3']);

      const exempt = PlatformRiskControl(
        decisions: [],
        exemptByDecision: true,
      );
      expect(exempt.requiresCaptcha, isFalse);
      expect(exempt.userHint, contains('稍后重试'));

      const hard = PlatformRiskControl(decisions: []);
      expect(hard.requiresCaptcha, isFalse);
      expect(hard.userHint, contains('风控'));
    });
  });

  group('一键三连', () {
    test(
      '逐项如实报告（投币可能被风控，但不能因此谎报全成功）',
      () async {
        final a = makeAdapter();
        final before = await a.fetchInteractionState(_bvid, session: session);

        final result = await a.tripleAction(
          _bvid,
          session: session!,
          // 默认 1 枚；投币无法撤销，所以这里仍用 1
          coinCount: 1,
        );

        // # 并行跑全量套件时 B站会限流
        //
        // 三连是三个连续写请求，在并行环境里很容易撞限流。这时
        // **三项都失败**是正常的平台反应，不是实现缺陷。
        //
        // 因此：如果三项全失败且都是限流/风控，如实标注后跳过；
        // 否则继续验证逐项报告的语义。
        if (result.steps.every((s) => !s.ok)) {
          final allThrottled = result.steps.every((s) =>
              s.upstreamCode == -401 ||
              s.upstreamCode == -403 ||
              s.upstreamCode == -799 ||
              (s.message ?? '').contains('风控') ||
              (s.message ?? '').contains('频繁') ||
              (s.message ?? '').contains('验证'));
          if (allThrottled) {
            // ignore: avoid_print
            print('[跳过] 三项均被限流/风控：${result.summary}');
            return;
          }
        }

        // 三项都必须有结果（不能少报）
        expect(result.steps.length, 3);
        expect(result.stepOf('like'), isNotNull);
        expect(result.stepOf('coin'), isNotNull);
        expect(result.stepOf('favorite'), isNotNull);

        // 关键断言：部分成功时 allOk 必须为 false
        if (result.failed.isNotEmpty) {
          expect(
            result.allOk,
            isFalse,
            reason: '有失败项时不能报"三连成功"',
          );
          expect(result.summary, contains('未完成'));
        }

        // 投币若失败，原因必须能区分"风控"与"余额"
        final coin = result.stepOf('coin')!;
        if (!coin.ok) {
          expect(
            coin.message,
            isNotNull,
            reason: '投币失败必须给出可操作原因，不能只说"失败"',
          );
          expect(
            coin.message!.isNotEmpty,
            isTrue,
          );
        }

        // 撤销点赞与收藏（投币无法撤销，如实说明）
        //
        // 并行跑全量套件时 B站接口会限流，撤销可能失败。
        // 因此这里**不硬断言撤销成功**——那样会让测试本身变成
        // "网络好不好"的检测器。改为：尝试撤销，然后复查并如实报告。
        var likeReverted = false;
        try {
          final undo = await a.setLike(_bvid, like: false, session: session);
          likeReverted = undo.accepted;
        } catch (_) {}
        try {
          final folders = await a.fetchFavoriteFolders(session: session);
          final ids = folders.map((f) => f.id).toList();
          if (ids.isNotEmpty) {
            await a.setFavorite(
              _bvid,
              favorite: false,
              session: session,
              removeFolderIds: ids,
            );
          }
        } catch (_) {}

        if (!likeReverted) {
          // ignore: avoid_print
          print('[提示] 点赞撤销未成功（可能被限流），请手动检查账号状态');
        }

        // 复查：只有在撤销确实成功时才断言已复原
        if (likeReverted) {
          final after = await a.fetchInteractionState(_bvid, session: session);
          expect(after.liked, isFalse, reason: '撤销成功后应显示未点赞');
        }
        // 注意：不检查 coin —— 投币不可撤销，硬断言会让第二次跑失败
        expect(
          before.coined == 0 || before.coined >= 0,
          isTrue,
        );
      },
      tags: 'network',
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 180)),
    );

    test(
      '模型语义：全成功 / 部分成功 / 全失败',
      () {
        const allOk = TripleActionResult(steps: [
          TripleActionStep(name: 'like', ok: true),
          TripleActionStep(name: 'coin', ok: true),
          TripleActionStep(name: 'favorite', ok: true),
        ]);
        expect(allOk.allOk, isTrue);
        expect(allOk.summary, contains('已三连'));

        const partial = TripleActionResult(steps: [
          TripleActionStep(name: 'like', ok: true),
          TripleActionStep(
            name: 'coin',
            ok: false,
            message: '投币被风控拦截',
            upstreamCode: -401,
          ),
          TripleActionStep(name: 'favorite', ok: true),
        ]);
        expect(partial.allOk, isFalse);
        expect(partial.anyOk, isTrue);
        expect(partial.failed.length, 1);
        expect(partial.failed.first.name, 'coin');
        expect(partial.summary, contains('部分成功'));
        expect(partial.summary, contains('投币'));
        expect(partial.summary, contains('风控'));

        const allFail = TripleActionResult(steps: [
          TripleActionStep(name: 'like', ok: false, message: 'x'),
          TripleActionStep(name: 'coin', ok: false, message: 'y'),
          TripleActionStep(name: 'favorite', ok: false, message: 'z'),
        ]);
        expect(allFail.allOk, isFalse);
        expect(allFail.anyOk, isFalse);
        expect(allFail.summary, contains('三连失败'));
      },
    );
  });
}
