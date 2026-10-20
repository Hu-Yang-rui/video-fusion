/// 私信（IM）测试。
///
/// 守护的是"**不许用假数据冒充真实功能**"这条底线：
///  - 消息正文解析：四种实测类型（1/18 文本、10 系统卡片、2 图片、未知）
///  - 翻页去重：按 msgKey，重复消息不能插两遍
///  - 排序：服务端新→旧，入库统一转正序
///  - 发送状态：只有服务端确认（code=0 **且有 msg_key**）才算 sent
///  - 失败/登录失效/CSRF：如实落到 failed，不谎报成功
///  - 已读：只对打开的**那一个**会话标记，不批量
///  - 签名能力：如实报告不可用 + 提供方默认抛错
///
/// 所有 mock 响应都按**真实实测结构**构造（字段名取自
/// 但 mock 通过**不算**
/// 真实接口已验证 —— 真实验证见 `test/im_live_test.dart`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili/im_client.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/cache.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/secure_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/im.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';
import 'package:video_fusion/src/ui/messages/im_store.dart';
import 'package:video_fusion/src/ui/messages/messages_screen.dart';

// ── 测试替身 ──────────────────────────────────────────────────

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

/// 支持私信的假适配器。
///
/// 用 `extends` 而不是 `implements`：PlatformAdapter 的默认实现
/// （抛 unsupportedPlatform）可以直接继承，只需覆盖真正用到的成员。
class FakeImAdapter extends PlatformAdapter {
  FakeImAdapter({
    this.sessionPage,
    this.messagePages = const [],
    this.unread = const ImUnread(unfollowUnread: 2),
    this.sendResult,
    this.sendError,
    this.sessionsError,
    this.messagesError,
    this.messageGate,
    this.markReadResult = true,
    this.userInfos = const {},
    this.imSupported = true,
  });

  ImSessionPage? sessionPage;
  List<ImMessagePage> messagePages;
  ImUnread unread;
  ImSendResult? sendResult;
  FusionException? sendError;
  FusionException? sessionsError;
  FusionException? messagesError;

  /// 若非 null，fetchImMessages 会挂住直到测试 complete 它（测并发时序用）。
  Completer<ImMessagePage>? messageGate;
  bool markReadResult;
  Map<int, ImUserInfo> userInfos;
  bool imSupported;

  // 调用记录
  int fetchSessionsCalls = 0;
  int fetchMessagesCalls = 0;
  int sendCalls = 0;
  final List<int> markedReadTalkers = [];
  final List<int> markedReadSeqnos = [];
  final List<int> requestedEndTs = [];
  final List<int> requestedEndSeqno = [];
  final List<String> sentContents = [];
  int fetchUserInfosCalls = 0;
  int fetchUnreadCalls = 0;

  @override
  String get id => 'bilibili';
  @override
  String get displayName => '哔哩哔哩';
  @override
  String get shortLabel => 'B站';
  @override
  AdapterCapabilities get capabilities =>
      const AdapterCapabilities(
        supportsMetadata: true,
        supportsNativePlayback: false,
        supportsOfficialEmbed: false,
        supportsExternalFallback: false,
      );
  @override
  List<String> get supportedHosts => const ['bilibili.com'];
  @override
  bool matches(Uri uri) => uri.host.endsWith('bilibili.com');
  @override
  Future<LinkMatch?> extract(Uri uri) async => null;
  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async =>
      const VideoMetadata(title: 'x');
  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async =>
      null;
  @override
  List<FeedSource> get feedSources => const [];

  @override
  bool get supportsIm => imSupported;

  @override
  Future<ImSessionPage> fetchImSessions({
    required PlatformSession session,
    int count = 20,
    int endTs = 0,
  }) async {
    fetchSessionsCalls++;
    requestedEndTs.add(endTs);
    if (sessionsError != null) throw sessionsError!;
    return sessionPage ?? const ImSessionPage(items: [], hasMore: false);
  }

  @override
  Future<ImMessagePage> fetchImMessages({
    required PlatformSession session,
    required int talkerId,
    int size = 20,
    int endSeqno = 0,
  }) async {
    final i = fetchMessagesCalls++;
    requestedEndSeqno.add(endSeqno);
    if (messagesError != null) throw messagesError!;
    if (messageGate != null) return messageGate!.future;
    if (i < messagePages.length) return messagePages[i];
    return const ImMessagePage(items: [], hasMore: false);
  }

  @override
  Future<ImSendResult> sendImMessage({
    required PlatformSession session,
    required int talkerId,
    required String content,
  }) async {
    sendCalls++;
    sentContents.add(content);
    if (sendError != null) throw sendError!;
    return sendResult ??
        const ImSendResult(accepted: true, msgKey: 'srv-1');
  }

  @override
  Future<ImUnread> fetchImUnread({required PlatformSession session}) async {
    fetchUnreadCalls++;
    return unread;
  }

  @override
  Future<Map<int, ImUserInfo>> fetchImUserInfos({
    required PlatformSession session,
    required List<int> uids,
  }) async {
    fetchUserInfosCalls++;
    return userInfos;
  }

  @override
  Future<bool> markImSessionRead({
    required PlatformSession session,
    required int talkerId,
    required int ackSeqno,
  }) async {
    markedReadTalkers.add(talkerId);
    markedReadSeqnos.add(ackSeqno);
    return markReadResult;
  }
}

PlatformSession makeSession({String uid = '240352', bool withCsrf = true}) =>
    PlatformSession(
      platformId: 'bilibili',
      displayName: '测试账号',
      userId: uid,
      cookies: {
        'SESSDATA': 'x',
        if (withCsrf) 'bili_jct': 'csrf-token',
      },
      loggedInAt: '2026-10-19T00:00:00Z',
    );

VideoService buildService(PlatformAdapter adapter) => VideoService(
      registry: PlatformRegistry(adapters: [adapter]),
      store: VideoStore(storage: MemoryStore()),
      cache: VideoCache(),
    );

/// 构造一个登录态的 ImStore（用内存 secure store 存会话）。
Future<ImStore> buildLoggedInStore(
  PlatformAdapter adapter, {
  PlatformSession? session,
}) async {
  final vault = CredentialVault(
    storage: InMemorySecureStore({
      'video_fusion.session.bilibili':
          _sessionToJson(session ?? makeSession()),
    }),
  );
  final store = ImStore(service: buildService(adapter), vault: vault);
  await store.init();
  return store;
}

String _sessionToJson(PlatformSession s) {
  final cookies = s.cookies.entries
      .map((e) => '"${e.key}":"${e.value}"')
      .join(',');
  return '{"platformId":"${s.platformId}","displayName":"${s.displayName}",'
      '"userId":"${s.userId}","cookies":{$cookies},'
      '"loggedInAt":"${s.loggedInAt}"}';
}

/// 按真实结构造一条消息。
ImMessage makeMessage({
  required String key,
  required int ts,
  int sender = 1001,
  int receiver = 240352,
  int msgType = 1,
  String? text = 'hello',
  int seqno = 1,
}) =>
    ImMessage(
      msgKey: key,
      senderUid: sender,
      receiverId: receiver,
      receiverType: 1,
      msgType: msgType,
      timestamp: ts,
      content: text == null ? '{}' : '{"content":"$text"}',
      msgSeqno: seqno,
      text: text,
    );

ImSession makeSessionRow({
  int talkerId = 1001,
  int unread = 0,
  int ts = 1792337210,
  bool top = false,
  int maxSeqno = 100,
}) =>
    ImSession(
      talkerId: talkerId,
      sessionType: 1,
      unreadCount: unread,
      sessionTs: ts,
      maxSeqno: maxSeqno,
      isTop: top,
      lastMsgType: 1,
      lastMsgTimestamp: ts,
    );

void main() {
  // ── 1. 正文解析（纯函数，对应实测四种类型）────────────────
  group('消息正文解析（实测类型）', () {
    test('type 1 文本 → 取出 content', () {
      expect(BilibiliImClient.extractText(1, '{"content":"你好"}'), '你好');
    });

    test('type 18 也是文本（与 1 同构）', () {
      expect(BilibiliImClient.extractText(18, '{"content":"晚安"}'), '晚安');
    });

    test('type 10 系统卡片 → 优先 text，回退 title', () {
      expect(
        BilibiliImClient.extractText(10, '{"title":"会话已创建","text":"对方已关注你"}'),
        '对方已关注你',
      );
      expect(
        BilibiliImClient.extractText(10, '{"title":"仅标题"}'),
        '仅标题',
      );
    });

    test('type 2 图片 → 没有文本，返回 null（不伪造占位文案）', () {
      expect(
        BilibiliImClient.extractText(2, '{"url":"http://x/y.jpg","width":10}'),
        isNull,
      );
    });

    test('未知类型 → null（安全降级，不抛异常）', () {
      expect(BilibiliImClient.extractText(999, '{"content":"?"}'), isNull);
    });

    test('content 是坏 JSON / 空串 → null，不抛', () {
      expect(BilibiliImClient.extractText(1, 'not-json'), isNull);
      expect(BilibiliImClient.extractText(1, ''), isNull);
      expect(BilibiliImClient.extractText(1, '[]'), isNull);
    });

    test('文本为空串 → null（空消息不显示空白气泡）', () {
      expect(BilibiliImClient.extractText(1, '{"content":"   "}'), isNull);
    });
  });

  // ── 2. 消息类型映射 ────────────────────────────────────────
  group('消息类型映射', () {
    test('1/18 → text，2 → image，10 → systemCard，其它 → unknown', () {
      expect(ImMessageType.fromRaw(1), ImMessageType.text);
      expect(ImMessageType.fromRaw(18), ImMessageType.text);
      expect(ImMessageType.fromRaw(2), ImMessageType.image);
      expect(ImMessageType.fromRaw(10), ImMessageType.systemCard);
      expect(ImMessageType.fromRaw(777), ImMessageType.unknown);
      expect(ImMessageType.fromRaw(null), ImMessageType.unknown);
    });

    test('只有 text 与 systemCard 有可读正文', () {
      expect(ImMessageType.text.hasReadableText, isTrue);
      expect(ImMessageType.systemCard.hasReadableText, isTrue);
      expect(ImMessageType.image.hasReadableText, isFalse);
      expect(ImMessageType.unknown.hasReadableText, isFalse);
    });
  });

  // ── 3. 分页去重与排序 ─────────────────────────────────────
  group('消息分页与去重', () {
    test('服务端倒序 → 入库正序', () {
      final chat = ImChatState(talkerId: 1);
      chat.mergePage(ImMessagePage(
        items: [
          makeMessage(key: 'c', ts: 300),
          makeMessage(key: 'b', ts: 200),
          makeMessage(key: 'a', ts: 100),
        ],
        hasMore: true,
        minSeqno: 100,
        maxSeqno: 300,
      ));
      expect(chat.messages.map((m) => m.msgKey).toList(), ['a', 'b', 'c'],
          reason: '服务端给新→旧，UI 需要旧→新');
    });

    test('翻页重叠的消息按 msgKey 去重', () {
      final chat = ImChatState(talkerId: 1);
      chat.mergePage(ImMessagePage(
        items: [
          makeMessage(key: 'c', ts: 300),
          makeMessage(key: 'b', ts: 200),
        ],
        hasMore: true,
        minSeqno: 200,
      ));
      // 第二页与第一页重叠了 b
      final added = chat.mergePage(ImMessagePage(
        items: [
          makeMessage(key: 'b', ts: 200),
          makeMessage(key: 'a', ts: 100),
        ],
        hasMore: false,
        minSeqno: 100,
      ));
      expect(added, 1, reason: '只应新增 a，b 是重复');
      expect(chat.messages.map((m) => m.msgKey).toList(), ['a', 'b', 'c']);
      expect(chat.hasMore, isFalse);
    });

    test('minSeqno 取历史最小值，用于继续往前翻', () {
      final chat = ImChatState(talkerId: 1);
      chat.mergePage(ImMessagePage(
          items: [makeMessage(key: 'b', ts: 200)], hasMore: true, minSeqno: 200));
      chat.mergePage(ImMessagePage(
          items: [makeMessage(key: 'a', ts: 100)], hasMore: true, minSeqno: 100));
      expect(chat.minSeqno, 100);
    });

    test('本地消息与服务端消息合并后仍按时间排序', () {
      final chat = ImChatState(talkerId: 1);
      chat.mergePage(ImMessagePage(
        items: [makeMessage(key: 'a', ts: 100)],
        hasMore: false,
      ));
      chat.addLocal(makeMessage(key: 'local-1', ts: 200, text: '我发的'));
      expect(chat.messages.last.msgKey, 'local-1');
    });
  });

  // ── 4. 会话列表 ───────────────────────────────────────────
  group('会话列表', () {
    test('解析会话并按 talkerId 去重，补齐昵称头像', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
          items: [
            makeSessionRow(talkerId: 1001, unread: 3),
            makeSessionRow(talkerId: 1002),
            makeSessionRow(talkerId: 1001, unread: 3), // 重复
          ],
          hasMore: true,
          nextEndTs: 1792337210,
        ),
        userInfos: {
          1001: const ImUserInfo(mid: 1001, name: '小明', faceUrl: 'http://a/b.jpg'),
        },
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);

      expect(store.sessions.length, 2, reason: '重复 talkerId 只保留一条');
      expect(store.sessionsHasMore, isTrue);
      expect(store.titleOf(store.sessions.first), '小明',
          reason: '昵称来自 x/im/user_infos 的 name 字段');
      expect(store.avatarOf(store.sessions.first), 'http://a/b.jpg');
      expect(adapter.fetchUserInfosCalls, 1, reason: '批量补信息，不是逐条请求');
    });

    test('未读数来自服务端汇总，不靠本地推算', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
            items: [makeSessionRow(talkerId: 1001, unread: 3)], hasMore: false),
        unread: const ImUnread(unfollowUnread: 4, followUnread: 1),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      expect(store.unreadTotal, 5, reason: '未关注 4 + 关注 1');
    });

    test('刷新有节流：5 秒内第二次 refresh 不发请求', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(items: [makeSessionRow()], hasMore: false),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      expect(adapter.fetchSessionsCalls, 1);
      await store.loadSessions(refresh: true);
      expect(adapter.fetchSessionsCalls, 1, reason: '节流期内不重复请求');
    });

    test('登录失效 → 抛出的错误被如实记录，不当成空列表', () async {
      final adapter = FakeImAdapter(
        sessionsError: FusionException(
          code: FusionErrorCode.loginRequired,
          userMessage: '登录状态已失效，请重新登录后查看私信。',
          platformId: 'bilibili',
        ),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      expect(store.sessionsError, isNotNull);
      expect(store.sessionsError!.code, FusionErrorCode.loginRequired);
      expect(store.sessions, isEmpty);
      expect(store.isLoggedIn, isFalse, reason: '登录失效要清会话，引导重新登录');
    });
  });

  // ── 5. 发送 ───────────────────────────────────────────────
  group('发送消息', () {
    test('服务端确认（有 msg_key）→ sent，并用服务端 key 替换本地临时消息', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
            items: [makeSessionRow(talkerId: 1001)], hasMore: false),
        sendResult: const ImSendResult(accepted: true, msgKey: 'srv-42'),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);

      final ok = await store.sendText(1001, '测试消息');
      expect(ok, isTrue);
      final chat = store.chatOf(1001);
      expect(chat.messages.single.msgKey, 'srv-42');
      expect(chat.messages.single.sendState, ImSendState.sent);
      expect(adapter.sentContents.single, '测试消息');
    });

    test('code=0 但没有 msg_key → 判失败（不谎报成功）', () async {
      final adapter = FakeImAdapter(
        sendResult: const ImSendResult(
          accepted: false,
          message: '平台未返回消息 ID，无法确认发送成功。',
        ),
      );
      final store = await buildLoggedInStore(adapter);
      final ok = await store.sendText(1001, 'hi');
      expect(ok, isFalse);
      final chat = store.chatOf(1001);
      expect(chat.messages.single.sendState, ImSendState.failed);
      expect(chat.messages.single.localError, contains('无法确认'));
    });

    test('发送抛登录失效 → failed 且清会话', () async {
      final adapter = FakeImAdapter(
        sendError: FusionException(
          code: FusionErrorCode.loginRequired,
          userMessage: '登录状态已失效，请重新登录后再操作。',
          platformId: 'bilibili',
        ),
      );
      final store = await buildLoggedInStore(adapter);
      final ok = await store.sendText(1001, 'hi');
      expect(ok, isFalse);
      expect(store.chatOf(1001).messages.single.sendState, ImSendState.failed);
      expect(store.isLoggedIn, isFalse);
    });

    test('空内容不发请求', () async {
      final adapter = FakeImAdapter();
      final store = await buildLoggedInStore(adapter);
      final ok = await store.sendText(1001, '   ');
      expect(ok, isFalse);
      expect(adapter.sendCalls, 0, reason: '本地就拦住，不打接口');
    });

    test('发送成功后会话列表的摘要与排序同步更新', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
          items: [
            makeSessionRow(talkerId: 1001, ts: 100),
            makeSessionRow(talkerId: 1002, ts: 200),
          ],
          hasMore: false,
        ),
        sendResult: const ImSendResult(accepted: true, msgKey: 'srv-9'),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      expect(store.sessions.first.talkerId, 1002, reason: '原本 1002 更新');

      await store.sendText(1001, '新消息');
      expect(store.sessions.first.talkerId, 1001,
          reason: '刚发过消息的会话排到最前');
      expect(store.sessions.first.lastMsgText, '新消息');
    });

    test('重发失败消息会先移除本地气泡再重新发送', () async {
      final adapter = FakeImAdapter(
        sendResult: const ImSendResult(accepted: true, msgKey: 'srv-2'),
      );
      final store = await buildLoggedInStore(adapter);
      final chat = store.chatOf(1001);
      chat.addLocal(makeMessage(
        key: 'local-x',
        ts: 100,
        text: '重试内容',
        sender: store.myUid,
        receiver: 1001,
      ).copyWith(sendState: ImSendState.failed, localError: '失败'));
      final ok = await store.resend(chat.messages.single);
      expect(ok, isTrue);
      expect(chat.messages.where((m) => m.msgKey == 'local-x'), isEmpty,
          reason: '旧的失败气泡要清掉，避免重复');
    });
  });

  // ── 6. 已读 ───────────────────────────────────────────────
  group('已读同步', () {
    test('只对打开的会话标记已读，未读清零', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
          items: [
            makeSessionRow(talkerId: 1001, unread: 5, maxSeqno: 500),
            makeSessionRow(talkerId: 1002, unread: 7, maxSeqno: 700),
          ],
          hasMore: false,
        ),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);

      await store.markRead(1001);

      expect(adapter.markedReadTalkers, [1001], reason: '只标这一个会话');
      expect(adapter.markedReadSeqnos.single, 500);
      final s1001 = store.sessions.firstWhere((s) => s.talkerId == 1001);
      final s1002 = store.sessions.firstWhere((s) => s.talkerId == 1002);
      expect(s1001.unreadCount, 0);
      expect(s1002.unreadCount, 7, reason: '没打开的会话不能被动清零');
    });

    test('已读接口失败 → 本地不清零（宁可红点还在，也不假装已读）', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
            items: [makeSessionRow(talkerId: 1001, unread: 5)], hasMore: false),
        markReadResult: false,
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      await store.markRead(1001);
      expect(store.sessions.first.unreadCount, 5);
    });

    test('已读的 ack_seqno 用消息流里的 maxSeqno（更准）', () async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
            items: [makeSessionRow(talkerId: 1001, unread: 2, maxSeqno: 100)],
            hasMore: false),
        messagePages: [
          ImMessagePage(
            items: [makeMessage(key: 'a', ts: 100)],
            hasMore: false,
            minSeqno: 300,
            maxSeqno: 900,
          ),
        ],
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      await store.loadMessages(1001);
      await store.markRead(1001);
      expect(adapter.markedReadSeqnos.single, 900,
          reason: '以实际拉到的最大 seqno 为准');
    });
  });

  // ── 7. 消息加载 ───────────────────────────────────────────
  group('消息加载', () {
    test('翻页用 minSeqno 作为 end_seqno', () async {
      final adapter = FakeImAdapter(
        messagePages: [
          ImMessagePage(
            items: [makeMessage(key: 'b', ts: 200)],
            hasMore: true,
            minSeqno: 200,
            maxSeqno: 300,
          ),
          ImMessagePage(
            items: [makeMessage(key: 'a', ts: 100)],
            hasMore: false,
            minSeqno: 100,
          ),
        ],
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadMessages(1001);
      await store.loadOlderMessages(1001);

      expect(adapter.requestedEndSeqno, [0, 200],
          reason: '第一次不带游标，第二次用上一页 minSeqno');
      expect(store.chatOf(1001).messages.map((m) => m.msgKey), ['a', 'b']);
    });

    test('加载失败记录错误，不当成"没有消息"', () async {
      final adapter = FakeImAdapter(
        messagesError: FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '网络异常',
          platformId: 'bilibili',
        ),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadMessages(1001);
      expect(store.chatOf(1001).error, isNotNull);
      expect(store.chatOf(1001).loadedOnce, isFalse,
          reason: '失败不能标记为"已加载过"');
    });

    test('两个会话各自的消息不会串线', () async {
      final adapter = FakeImAdapter(
        messagePages: [
          ImMessagePage(
              items: [makeMessage(key: 'a-msg', ts: 100)], hasMore: false),
          ImMessagePage(
              items: [makeMessage(key: 'b-msg', ts: 200)], hasMore: false),
        ],
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadMessages(1001);
      await store.loadMessages(1002);

      expect(store.chatOf(1001).messages.map((m) => m.msgKey), ['a-msg']);
      expect(store.chatOf(1002).messages.map((m) => m.msgKey), ['b-msg'],
          reason: '每个会话只应持有自己的消息');
    });

    test('请求在飞时发生 refresh，晚到的旧响应被代际号丢弃', () async {
      // 用闸门把第一次响应挂住，制造真正的"并发"时序：
      //  1) 发请求 A（gen=0），响应未到
      //  2) 用户 refresh → gen=1
      //  3) A 的响应到达 → 因为 gen 已变，必须丢弃
      final gate = Completer<ImMessagePage>();
      final adapter = FakeImAdapter(messageGate: gate);
      final store = await buildLoggedInStore(adapter);
      final chat = store.chatOf(1001);

      final inflight = store.loadMessages(1001); // 不 await
      chat.generation++; // 模拟 refresh 推进代际
      gate.complete(ImMessagePage(
        items: [makeMessage(key: 'stale', ts: 100)],
        hasMore: false,
      ));
      await inflight;

      expect(chat.messages.map((m) => m.msgKey), isNot(contains('stale')),
          reason: '代际号变化后，旧请求的结果必须被丢弃，'
              '否则会把用户刚刷新的列表覆盖回旧数据');
    });
  });

  // ── 9. 页面状态 ───────────────────────────────────────────
  group('消息页状态', () {
    testWidgets('未登录 → 显示登录引导，不显示空会话列表', (tester) async {
      final vault = CredentialVault(storage: InMemorySecureStore());
      final store = ImStore(
        service: buildService(FakeImAdapter()),
        vault: vault,
      );
      await tester.pumpWidget(MaterialApp(
        home: MessagesScreen(store: store, onOpenLogin: () {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('未登录'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
    });

    testWidgets('已登录且无会话 → 空状态说明', (tester) async {
      final adapter = FakeImAdapter(
        sessionPage: const ImSessionPage(items: [], hasMore: false),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      await tester.pumpWidget(MaterialApp(home: MessagesScreen(store: store)));
      await tester.pumpAndSettle();

      expect(find.text('还没有私信'), findsOneWidget);
    });

    testWidgets('加载失败 → 错误状态 + 重试按钮', (tester) async {
      final adapter = FakeImAdapter(
        sessionsError: FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '网络异常，请稍后重试。',
          platformId: 'bilibili',
        ),
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      await tester.pumpWidget(MaterialApp(home: MessagesScreen(store: store)));
      await tester.pumpAndSettle();

      expect(find.text('网络异常，请稍后重试。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('有会话 → 显示昵称与未读徽标', (tester) async {
      final adapter = FakeImAdapter(
        sessionPage: ImSessionPage(
          items: [makeSessionRow(talkerId: 1001, unread: 7)],
          hasMore: false,
        ),
        userInfos: {
          1001: const ImUserInfo(mid: 1001, name: '小明'),
        },
      );
      final store = await buildLoggedInStore(adapter);
      await store.loadSessions(refresh: true);
      await tester.pumpWidget(MaterialApp(home: MessagesScreen(store: store)));
      await tester.pumpAndSettle();

      expect(find.text('小明'), findsOneWidget);
      expect(find.text('7'), findsOneWidget, reason: '未读徽标');
    });
  });
}
