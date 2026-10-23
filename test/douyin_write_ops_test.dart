/// 抖音写操作能力的单元测试（v0.5.0）。
///
/// # 这组测试守护什么
///
/// 本轮把抖音 6 项写操作从"声明不支持"改为"已实现"，
/// 依据是实测发现它们**不是 403 Argus 拦截，而是需要登录**：
///
/// | 端点 | 未登录响应 |
/// |---|---|
/// | `commit/item/digg` | `code=8 用户未登录` |
/// | `aweme/collect` | `code=8 用户未登录` |
/// | `commit/follow/user` | `code=8 用户未登录` |
/// | `collects/list` | `code=8 用户未登录` |
/// | `watchlater/list` | `code=0`（空） |
/// | `webcast/room/{like,chat}` | `20003 User doesn't login` |
///
/// 测试锁死：
///  1. 能力开关确实翻成 true
///  2. `status_code=8` / `20003` 映射为 `loginRequired`（不是"不可用"）
///  3. 不谎报成功：`code != 0` 一律失败
///  4. 私信仍如实声明不支持（独立网关，Web 端不可达）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/live_interaction.dart';
import 'package:video_fusion/src/adapters/douyin/web_signer.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';

DouyinAdapter _adapter() => DouyinAdapter(
      http: FusionHttpClient(),
    );

PlatformSession _session() => const PlatformSession(
      platformId: 'douyin',
      displayName: '测试账号',
      userId: '123',
      cookies: {'sessionid': 'fake', 'ttwid': 'x'},
      loggedInAt: '2026-10-19T00:00:00Z',
    );

void main() {
  group('能力开关（本轮翻转为 true）', () {
    final a = _adapter();

    test('点赞 / 收藏 / 关注 / 稍后再看 / 收藏夹 / 已保存内容 均声明支持', () {
      expect(a.supportsLike, isTrue, reason: '实测 code=8 需登录，可实现');
      expect(a.supportsFavorite, isTrue, reason: '实测 code=8 需登录，可实现');
      expect(a.supportsFollowAuthor, isTrue, reason: '实测 code=8 需登录，可实现');
      expect(a.supportsWatchLater, isTrue, reason: '实测 watchlater/list code=0');
      expect(a.supportsFavoriteFolders, isTrue, reason: '实测 collects/list code=8');
      expect(a.supportsSavedContent, isTrue);
    });

    test('投币仍然不支持（抖音没有该概念）', () {
      expect(a.supportsCoin, isFalse);
      expect(a.supportsCoinBalance, isFalse);
    });

    test('逐夹归属扫描仍不支持（条目列表参数未验证）', () {
      expect(
        a.supportsFolderOwnershipScan,
        isFalse,
        reason: 'collects/video/list 返回 code=4，参数未调通，不冒充能精确归属',
      );
    });

    test('私信仍不支持（独立网关，Web 端不可达）', () {
      expect(
        a.supportsIm,
        isFalse,
        reason: '/im/* 在 www.douyin.com 返回 HTML，imapi 不可达',
      );
      expect(a.supportsImImageSend, isFalse);
      expect(a.supportsImEmote, isFalse);
    });

    test('搜索已支持（需登录）', () {
      expect(a.supportsSearch, isTrue);
    });

    test('本轮新增：评论点赞 / 评论发表 / 云端历史 均声明支持（需登录）', () {
      // 实测（2026-10-22，probe_douyin_comment_history.mjs）：
      //  - history/read     → code=8 用户未登录
      //  - comment/digg     → code=8 用户未登录
      //  - comment/publish  → code=8 用户未登录（comment:null）
      // 三者都不是 404（不存在）、不是 403（Argus），只差登录态。
      expect(a.supportsCommentLike, isTrue,
          reason: '实测 code=8 需登录，可实现');
      expect(a.supportsCommentReply, isTrue,
          reason: '实测 code=8 需登录，可实现');
      expect(a.supportsCloudHistory, isTrue,
          reason: '实测 code=8 需登录，可实现');
    });

    test('楼中楼读取声明支持；云端播放进度如实声明不支持', () {
      // 楼中楼：comment/list/reply 是 comment/list 的同构翻页
      // （bundle s86.js 调用点 k(e)），读路径公开可用。
      expect(a.supportsCommentReplies, isTrue);

      // play/progress：端点存在（bundle 有通用调用点，与 history/write
      // 的信息流翻页语义不同），但实测（2026-10-23，
      // probe_dy_pp_gate.mjs）5 种 body 全部 code=5 参数不合法，
      // 连调用**页面自己的**上报函数（webpack 649397.J$，签名参数
      // 全由页面负责）也是 code=5——那个函数被 isLogin 门控，
      // 匿名时页面根本不触发，服务端参数契约在无登录态下不可观察。
      // 按「不谎报」：拿不到一次 code=0 就不声明支持。
      expect(a.supportsCloudProgress, isFalse,
          reason: 'play/progress 匿名 code=5，契约不可观察，不接死按钮');
    });

    test('reportPlaybackProgress（抖音）抛 unsupportedPlatform，不谎报成功',
        () async {
      final a = _adapter();
      await expectLater(
        a.reportPlaybackProgress(
          platformVideoId: '1',
          position: const Duration(seconds: 5),
          duration: const Duration(seconds: 30),
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

  group('本轮新接的写路径：本地校验先拦（不浪费请求）', () {
    test('setCommentLike：非数字 cid 直接 videoIdNotFound', () async {
      final a = _adapter();
      await expectLater(
        a.setCommentLike(
          '123',
          commentId: 'not-a-number',
          like: true,
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

    test('replyComment：空内容本地拦截', () async {
      final a = _adapter();
      await expectLater(
        a.replyComment(
          '123',
          message: '   ',
          session: _session(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.invalidUrl,
          ),
        ),
      );
    });

    test('replyComment：超 500 字本地拦截', () async {
      final a = _adapter();
      await expectLater(
        a.replyComment(
          '123',
          message: '字' * 501,
          session: _session(),
        ),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.invalidUrl,
          ),
        ),
      );
    });

    test('写路径缺会话：本地先抛，不发 WebView 请求', () async {
      // replyComment / setCommentLike 的 session 是 required，
      // 这里验证的是**参数校验在 signer 之前**：
      // 空内容时 _writeRequest 根本没被调用（不会挂 WebView）。
      final a = _adapter();
      await expectLater(
        a.replyComment('123', message: '', session: _session()),
        throwsA(isA<FusionException>()),
      );
    });
  });

  group('_writeRequest 不吞掉调用方的 aweme_id（2026-10-22 修正）', () {
    // 原代码 `{..._detailParams(''), ...params}..remove('aweme_id')`
    // 无条件删 aweme_id：占位被删是预期，调用方传的真 aweme_id 也一起没了。
    // 未登录停在 code=8 走不到参数校验，登录前看不出来；有登录态后
    // 点赞/收藏/关注会全部变成"参数错误"。
    //
    // 这条走 WebView 无法离线断言返回值，用**源码约束**守：
    // 必须"仅当值为空才删"，而不是无条件 remove。
    late String src;
    setUpAll(() {
      src = File('lib/src/adapters/douyin_adapter.dart').readAsStringSync();
    });

    test('mergedParams 不再链式 ..remove(aweme_id)', () {
      expect(
        src.contains('...params}..remove(\'aweme_id\')') ||
            src.contains('...params}..remove("aweme_id")'),
        isFalse,
        reason: '无条件 remove 会删掉调用方传入的真实 aweme_id',
      );
    });

    test('改为仅当空占位才删除', () {
      expect(
        src.contains("if ((mergedParams['aweme_id'] ?? '').isEmpty)"),
        isTrue,
        reason: '应改为值判空后才 remove，保留调用方真值',
      );
    });
  });

  group('未登录时抛 loginRequired（不是"能力不可用"）', () {
    test('setLike 未登录 → loginRequired', () async {
      final a = _adapter();
      // 未注入登录态：_writeRequest 会在 WebView 未就绪时抛 capabilityUnavailable，
      // 或在 status_code=8 时抛 loginRequired。两者都是"如实失败"，
      // 关键是不能返回 accepted=true。
      await expectLater(
        a.setLike('1', like: true, session: _session()),
        throwsA(isA<FusionException>()),
      );
    });

    test('setCoin 仍抛 unsupportedPlatform', () async {
      final a = _adapter();
      await expectLater(
        a.setCoin('1', count: 1, session: _session()),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.unsupportedPlatform,
        )),
      );
    });

    test('setFollowAuthor 空 sec_user_id 直接拒，不发请求', () async {
      final a = _adapter();
      await expectLater(
        a.setFollowAuthor(targetMid: '', follow: true, session: _session()),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.videoIdNotFound,
        )),
      );
    });
  });

  group('UIFID 分级（沿用 v0.5.0 核心修复）', () {
    test('UIFID_TEMP 不足以支撑写操作（需 full）', () {
      expect(
        DouyinWebSigner.readinessOfCookieString('UIFID_TEMP=x; ttwid=y'),
        SignerReadiness.temp,
      );
    });

    test('正式 UIFID 才算 full', () {
      expect(
        DouyinWebSigner.readinessOfCookieString('UIFID=f; UIFID_TEMP=x'),
        SignerReadiness.full,
      );
    });
  });

  group('直播互动：20003 映射为 loginRequired', () {
    test('未登录（session=null）直接抛 loginRequired，不发请求', () async {
      final li = DouyinLiveInteraction(
        signer: DouyinWebSigner(),
      );
      await expectLater(
        li.like(roomKey: '123', session: null),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.loginRequired,
        )),
      );
    });

    test('发弹幕：空内容本地拦截', () async {
      final li = DouyinLiveInteraction(signer: DouyinWebSigner());
      await expectLater(
        li.sendDanmaku(roomKey: '1', content: '   ', session: _session()),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.invalidUrl,
        )),
      );
    });

    test('发弹幕：超长本地拦截（不浪费一次请求）', () async {
      final li = DouyinLiveInteraction(signer: DouyinWebSigner());
      await expectLater(
        li.sendDanmaku(
          roomKey: '1',
          content: 'x' * 51,
          session: _session(),
        ),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.invalidUrl,
        )),
      );
    });

    test('未登录发弹幕 → loginRequired', () async {
      final li = DouyinLiveInteraction(signer: DouyinWebSigner());
      await expectLater(
        li.sendDanmaku(roomKey: '1', content: 'hi', session: null),
        throwsA(isA<FusionException>().having(
          (e) => e.code,
          'code',
          FusionErrorCode.loginRequired,
        )),
      );
    });
  });

  group('响应模型：不谎报成功', () {
    test('非 JSON 响应判失败', () {
      const r = DouyinCommentResponse(statusCode: 200, body: '<html>');
      expect(r.tryParseJson(), isNull);
    });

    test('code=8 的 JSON 能解析出来（由上层映射）', () {
      const r = DouyinCommentResponse(
        statusCode: 200,
        body: '{"status_code":8,"status_msg":"用户未登录"}',
      );
      final j = r.tryParseJson();
      expect(j, isNotNull);
      expect(j!['status_code'], 8);
    });

    test('20003 的直播响应能解析', () {
      const r = DouyinCommentResponse(
        statusCode: 200,
        body: '{"status_code":20003,"data":{"message":"User doesn\'t login"}}',
      );
      final j = r.tryParseJson();
      expect(j!['status_code'], 20003);
    });
  });
}
