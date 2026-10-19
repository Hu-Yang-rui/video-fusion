/// B站私信**真实接口**验证。
///
/// 与 `im_test.dart` 的分工：
///  - `im_test.dart` 用 mock 守逻辑（去重/排序/状态机）
///  - 这个文件打**真实接口**，验证端点、参数、字段名与契约假设
///
/// # 运行方式
///
/// ```powershell
/// $env:BILI_COOKIE_FILE = 'D:\vf-local\bili_cookie.txt'
/// flutter test test/im_live_test.dart --tags network
/// ```
///
/// 不发任何消息、不改任何已读状态 —— **纯只读**。
/// 发送能力单独由 `VF_ALLOW_WRITE=1` + `VF_TEST_TALKER` 双开关保护，
/// 默认跳过（见最后一个 group）。
///
/// # 为什么只读
///
/// 私信是账号之间的真实通信。自动发测试消息会打扰真人，
/// 所以默认只验证"读"链路；写链路的验证交给人工在 App 内完成，
/// 报告里如实标注为"未自动验证"。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili/im_client.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/models/im.dart';

String? _cookie() {
  final inline = Platform.environment['BILI_COOKIE'];
  if (inline != null && inline.trim().isNotEmpty) return inline.trim();
  final file = Platform.environment['BILI_COOKIE_FILE'];
  if (file == null || file.isEmpty) return null;
  final f = File(file);
  if (!f.existsSync()) return null;
  final t = f.readAsStringSync().trim();
  return t.isEmpty ? null : t;
}

PlatformSession? _session() {
  final ck = _cookie();
  if (ck == null) return null;
  final map = <String, String>{};
  for (final part in ck.split(';')) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    map[part.substring(0, i).trim()] = part.substring(i + 1).trim();
  }
  final uid = map['DedeUserID'];
  if (uid == null) return null;
  return PlatformSession(
    platformId: 'bilibili',
    displayName: 'live-test',
    userId: uid,
    cookies: map,
    loggedInAt: '2026-10-19T00:00:00Z',
  );
}

void main() {
  final cookie = _cookie();
  final session = _session();
  final skip = cookie == null || session == null
      ? '需要 BILI_COOKIE_FILE 或 BILI_COOKIE（仓库外）'
      : null;

  final client = BilibiliImClient(
    http: FusionHttpClient(),
    platformId: 'bilibili',
  );

  /// 非空取会话。
  ///
  /// 所有用到会话的用例都带 `skip: skip`，走到这里时它必然非空；
  /// 收在一处，避免把 `!` 散落满地（那样既难读，也会触发
  /// "unnecessary_non_null_assertion" 的误报）。
  PlatformSession needSession() => session!;

  group('真实私信接口', () {
    test('会话列表：返回真实会话与分页游标', () async {
      final page = await client.fetchSessions(session: needSession());

      expect(page.items, isNotEmpty, reason: '测试账号应有真实会话');
      final first = page.items.first;
      expect(first.talkerId, greaterThan(0));
      expect(first.sessionType, 1, reason: '实测单聊 session_type=1');
      expect(first.unreadCount, greaterThanOrEqualTo(0));
      // sessionTs 可能为 0（系统会话），有值的必须像时间戳
      if (first.sessionTs > 0) {
        expect(first.sessionTs, greaterThan(1600000000),
            reason: '秒级时间戳应晚于 2020 年');
      }
    }, tags: 'network', skip: skip);

    test('会话列表分页：end_ts 往前翻，不重复', () async {
      final p1 = await client.fetchSessions(session: needSession(), count: 20);
      if (!p1.hasMore) {
        // 只有一页也是合法结果，如实记录
        expect(p1.hasMore, isFalse);
        return;
      }
      final p2 = await client.fetchSessions(
        session: needSession(),
        count: 20,
        endTs: p1.nextEndTs,
      );
      final ids1 = p1.items.map((e) => e.talkerId).toSet();
      final overlap = p2.items.where((e) => ids1.contains(e.talkerId)).length;
      expect(p2.items, isNotEmpty, reason: 'has_more=1 时下一页不该为空');
      expect(overlap, 0, reason: '按 end_ts 翻页不应重复同一会话');
    }, tags: 'network', skip: skip);

    test('历史消息：字段齐全、服务端按新→旧返回', () async {
      final sessions = await client.fetchSessions(session: needSession());
      // 找一个有消息的会话
      final target = sessions.items.firstWhere(
        (s) => s.sessionTs > 0,
        orElse: () => sessions.items.first,
      );
      final page = await client.fetchMessages(
        session: needSession(),
        talkerId: target.talkerId,
      );

      expect(page.items, isNotEmpty, reason: '真实会话应有历史消息');
      final m = page.items.first;
      expect(m.msgKey, isNotEmpty, reason: 'msg_key 是去重唯一依据');
      expect(m.senderUid, greaterThan(0));
      expect(m.timestamp, greaterThan(1600000000));
      expect(m.msgSeqno, greaterThan(0), reason: '翻页与已读都依赖 seqno');

      // 服务端顺序：新 → 旧（实测单调递减）
      if (page.items.length > 1) {
        final ts = page.items.map((e) => e.timestamp).toList();
        final desc = List<int>.from(ts)..sort((a, b) => b.compareTo(a));
        expect(ts, desc,
            reason: '实测服务端按时间倒序返回；适配器/UI 依赖这个契约做反转');
      }
    }, tags: 'network', skip: skip);

    test('历史消息分页：end_seqno 往前翻，无重复', () async {
      final sessions = await client.fetchSessions(session: needSession());
      // 找消息最多的会话
      int bestTalker = 0;
      ImMessagePage? best;
      for (final s in sessions.items.take(8)) {
        final p = await client.fetchMessages(
          session: needSession(),
          talkerId: s.talkerId,
        );
        if (best == null || p.items.length > best.items.length) {
          best = p;
          bestTalker = s.talkerId;
        }
      }
      if (best == null || !best.hasMore) {
        // 没有多页的会话：如实跳过，不伪造
        expect(best, isNotNull);
        return;
      }

      final p2 = await client.fetchMessages(
        session: needSession(),
        talkerId: bestTalker,
        endSeqno: best.minSeqno,
      );
      final keys1 = best.items.map((e) => e.msgKey).toSet();
      final overlap = p2.items.where((e) => keys1.contains(e.msgKey)).length;
      expect(p2.items, isNotEmpty, reason: 'has_more=1 时下一页不该为空');
      expect(overlap, 0,
          reason: '按 end_seqno 翻页不应重复（若重叠，store 的 msgKey 去重是必需的）');
    }, tags: 'network', skip: skip);

    test('未读汇总：8 个字段可解析', () async {
      final u = await client.fetchUnread(session: needSession());
      expect(u.total, greaterThanOrEqualTo(0));
      // 各分项都不能是负数
      expect(u.unfollowUnread, greaterThanOrEqualTo(0));
      expect(u.followUnread, greaterThanOrEqualTo(0));
      expect(u.bizMsgFollowUnread, greaterThanOrEqualTo(0));
    }, tags: 'network', skip: skip);

    test('用户信息：字段是 mid/name/face（不是 uid/nick）', () async {
      final sessions = await client.fetchSessions(session: needSession());
      final talker = sessions.items.first.talkerId;
      final infos = await client.fetchUserInfos(
        session: needSession(),
        uids: [talker],
      );

      expect(infos, isNotEmpty, reason: 'x/im/user_infos 应返回该用户');
      final info = infos[talker];
      expect(info, isNotNull,
          reason: '按 mid 索引；若这里失败说明字段名猜错了（实测是 mid 不是 uid）');
      expect(info!.mid, talker);
    }, tags: 'network', skip: skip);

    test('登录失效：无效 Cookie 抛 loginRequired，而不是返回空列表', () async {
      final bad = PlatformSession(
        platformId: 'bilibili',
        displayName: 'bad',
        userId: '1',
        cookies: const {'SESSDATA': 'invalid', 'bili_jct': 'invalid'},
        loggedInAt: '2026-10-19T00:00:00Z',
      );
      await expectLater(
        client.fetchSessions(session: bad),
        throwsA(predicate(
          (e) => e.toString().contains('loginRequired') ||
              e.toString().contains('-101'),
          '登录失效必须明确报错，不能伪装成"没有会话"',
        )),
      );
    }, tags: 'network', skip: skip);

    test('CSRF 缺失：发送被拒（-111），不产生任何消息', () async {
      final noCsrf = PlatformSession(
        platformId: 'bilibili',
        displayName: 'no-csrf',
        userId: needSession().userId,
        cookies: Map<String, String>.from(needSession().cookies)..remove('bili_jct'),
        loggedInAt: needSession().loggedInAt,
      );
      // 目标用自己：即使 csrf 校验意外通过，平台也会用 21026 拒绝自聊，
      // 双重保证不会给真人发消息。
      final selfUid = int.parse(needSession().userId);
      await expectLater(
        client.sendMessage(
          session: noCsrf,
          talkerId: selfUid,
          content: 'vf-csrf-probe',
        ),
        throwsA(anything),
        reason: '缺 csrf 必须失败（实测 -111）',
      );
    }, tags: 'network', skip: skip);

    test('空内容：本地拦截，不发请求', () async {
      final r = await client.sendMessage(
        session: needSession(),
        talkerId: int.parse(needSession().userId),
        content: '   ',
      );
      expect(r.accepted, isFalse);
      expect(r.message, contains('不能为空'));
    }, tags: 'network', skip: skip);
  });

  // 写链路：默认跳过，需要显式双开关。
  group('真实发送（需显式授权）', () {
    final allowWrite = Platform.environment['VF_ALLOW_WRITE'] == '1';
    final talkerEnv = Platform.environment['VF_TEST_TALKER'];
    final writeSkip = skip ??
        (!allowWrite
            ? '需要 VF_ALLOW_WRITE=1'
            : (talkerEnv == null
                ? '需要 VF_TEST_TALKER=<talker_id>（建议用你自己的另一个号）'
                : null));

    test('发送一条无敏感内容的测试消息，并读回确认', () async {
      final talkerId = int.parse(talkerEnv!);
      final text = 'vf-im-test-${DateTime.now().millisecondsSinceEpoch}';

      final r = await client.sendMessage(
        session: needSession(),
        talkerId: talkerId,
        content: text,
      );
      expect(r.accepted, isTrue, reason: '服务端必须返回 code=0 且有 msg_key');
      expect(r.msgKey, isNotNull);

      // 读回：必须能在历史里找到同一条 msg_key
      final page = await client.fetchMessages(
        session: needSession(),
        talkerId: talkerId,
      );
      final found = page.items.where((m) => m.msgKey == r.msgKey).toList();
      expect(found, isNotEmpty,
          reason: '发送成功但历史里查不到，说明"成功"是假的');
      expect(found.first.text, text);
    }, tags: 'network', skip: writeSkip);
  });
}
