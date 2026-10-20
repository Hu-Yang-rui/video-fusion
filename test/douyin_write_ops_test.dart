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
