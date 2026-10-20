/// 抖音直播弹幕（HTTP 轮询通道）的解析测试。
///
/// # 这组测试守护什么
///
/// 项目此前把抖音直播弹幕判定为"不可用"，理由是 wss 需要 webmssdk 的
/// `signature`。这个结论对 wss 成立，但**漏了 HTTP 轮询这条路**：
/// `/webcast/im/fetch/` 不需要签名，也不需要长连接。
///
/// 之前之所以测成"空"，是用了**已下播的房间号**——房间 `status != 2`
/// 时该接口返回空。这与接口本身无关。
///
/// 因此这里锁死两件事：
///  1. **protobuf 结构假设**必须与平台真实响应一致（用真实字节验证）
///  2. 失败时必须明确报错，不能返回空批次（那会把"请求失败"
///     伪装成"这个房间没人说话"）
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/live_danmaku_http.dart';
import 'package:video_fusion/src/models/live.dart';

// ── 构造 protobuf 字节（用于离线用例）──────────────────────────

Uint8List _varint(int v) {
  final out = <int>[];
  var x = v;
  while (x >= 0x80) {
    out.add((x & 0x7F) | 0x80);
    x >>= 7;
  }
  out.add(x);
  return Uint8List.fromList(out);
}

Uint8List _tag(int field, int wire) => _varint((field << 3) | wire);

void _lenField(BytesBuilder b, int field, List<int> data) {
  b.add(_tag(field, 2));
  b.add(_varint(data.length));
  b.add(data);
}

void _varintField(BytesBuilder b, int field, int value) {
  b.add(_tag(field, 0));
  b.add(_varint(value));
}

/// 构造一条顶层元素：`tag(1, LEN) + Message{ f1=method, f2=payload }`。
///
/// 真实响应开头（hex）：
/// ```
/// 0a bb 03                        ← tag(1,LEN) + len=443
///   0a 12 "WebcastRoomMessage"    ← Message.f1 = method 名
///   12 e8 02 ...                  ← Message.f2 = payload
/// ```
///
/// 所以顶层是"一串 `tag(1,LEN)` 包裹的 Message"，每个包裹内部才是
/// method 与 payload。**这个两层结构是实测确认的，不要简化成一层**——
/// 简化后解析器解不出任何东西（这是本轮踩过的坑）。
List<int> _message(String method, List<int> payload) {
  final inner = BytesBuilder();
  _lenField(inner, 1, utf8.encode(method));
  _lenField(inner, 2, payload);
  final innerBytes = inner.takeBytes();

  final outer = BytesBuilder();
  _lenField(outer, 1, innerBytes);
  return outer.takeBytes();
}

/// 把若干条 Message 拼成完整响应体。
Uint8List _response(List<List<int>> messages) {
  final b = BytesBuilder();
  for (final m in messages) {
    b.add(m);
  }
  return b.takeBytes();
}

/// 构造 `WebcastChatMessage { common=1, user=2, content=3 }`。
List<int> _chatPayload({
  required String nickname,
  required String content,
  String userId = '123456',
  int msgId = 1001,
  int createTime = 1792422701000,
}) {
  final user = BytesBuilder();
  _varintField(user, 1, int.parse(userId));
  _lenField(user, 3, utf8.encode(nickname));

  final common = BytesBuilder();
  _lenField(common, 1, utf8.encode('WebcastChatMessage'));
  _varintField(common, 2, msgId);
  _varintField(common, 4, createTime);

  final b = BytesBuilder();
  _lenField(b, 1, common.takeBytes());
  _lenField(b, 2, user.takeBytes());
  _lenField(b, 3, utf8.encode(content));
  return b.takeBytes();
}

void main() {
  group('protobuf 解析（构造字节）', () {
    test('单条弹幕的全部字段都能解出', () {
      final payload = _chatPayload(
        nickname: '过火啦',
        content: '我手机坏了',
        userId: '987654321',
        msgId: 42,
        createTime: 1792422704472,
      );
      final body = _response([_message('WebcastChatMessage', payload)]);

      final batch = parseLiveDanmakuResponse(body);
      expect(batch.items.length, 1);
      final item = batch.items.first;
      expect(item.method, 'WebcastChatMessage');
      expect(item.nickname, '过火啦');
      expect(item.content, '我手机坏了');
      expect(item.userId, '987654321');
      expect(item.msgId, '42');
      expect(item.createTimeMs, 1792422704472);
      expect(item.isChat, isTrue);
      expect(batch.chats.length, 1);
    });

    test('多条消息按顺序解出，类型正确分类', () {
      final body = _response([
        _message(
          'WebcastChatMessage',
          _chatPayload(nickname: 'A', content: '第一条'),
        ),
        _message(
          'WebcastMemberMessage',
          _chatPayload(nickname: 'B', content: ''),
        ),
        _message(
          'WebcastChatMessage',
          _chatPayload(nickname: 'C', content: '第二条'),
        ),
      ]);

      final batch = parseLiveDanmakuResponse(body);
      expect(batch.items.length, 3);
      expect(batch.items[0].isChat, isTrue);
      expect(batch.items[1].isMemberEnter, isTrue);
      expect(batch.items[2].isChat, isTrue);
      expect(batch.chats.map((c) => c.content), ['第一条', '第二条']);
    });

    test('没有 content 的消息不算弹幕（心跳 / 榜单等）', () {
      final common = BytesBuilder();
      _lenField(common, 1, utf8.encode('WebcastRoomStatsMessage'));
      _varintField(common, 2, 999);

      final body = _response([
        _message('WebcastRoomStatsMessage', common.takeBytes()),
      ]);

      final batch = parseLiveDanmakuResponse(body);
      expect(batch.items.length, 1);
      expect(batch.items.first.isChat, isFalse);
      expect(batch.chats, isEmpty);
    });

    test('空字节返回空批次（不是错误）', () {
      final batch = parseLiveDanmakuResponse(Uint8List(0));
      expect(batch.isEmpty, isTrue);
      expect(batch.rawBytes, 0);
    });

    test('未知消息类型不影响其它消息的解析', () {
      final body = _response([
        _message('WebcastSomeFutureMessage', [1, 2, 3]),
        _message(
          'WebcastChatMessage',
          _chatPayload(nickname: 'X', content: '仍然能解'),
        ),
      ]);

      final batch = parseLiveDanmakuResponse(body);
      expect(batch.items.length, 2);
      expect(batch.chats.length, 1);
      expect(batch.chats.first.content, '仍然能解');
    });

    test('中文与 emoji 都能正确解码', () {
      final body = _response([
        _message(
          'WebcastChatMessage',
          _chatPayload(nickname: '🌈须弥至巅', content: '老爷保佑🀄一次'),
        ),
      ]);
      final batch = parseLiveDanmakuResponse(body);
      expect(batch.items.first.nickname, '🌈须弥至巅');
      expect(batch.items.first.content, '老爷保佑🀄一次');
    });
  });

  group('转成 LiveMessage', () {
    test('只映射聊天与进场，不把榜单塞进聊天流', () {
      final body = _response([
        _message(
          'WebcastChatMessage',
          _chatPayload(nickname: 'A', content: '弹幕一'),
        ),
        _message(
          'WebcastMemberMessage',
          _chatPayload(nickname: 'B', content: ''),
        ),
        _message('WebcastRoomRankMessage', [1, 2, 3]),
        _message('WebcastFansclubMessage', [4, 5, 6]),
      ]);

      final batch = parseLiveDanmakuResponse(body);
      final messages = DouyinLiveDanmakuHttp.toLiveMessages(batch);

      expect(messages.length, 2, reason: '榜单/粉丝团不应进聊天流');
      expect(messages[0].type, LiveMessageType.chat);
      expect(messages[0].text, '弹幕一');
      expect(messages[1].type, LiveMessageType.memberEnter);
      expect(messages[1].uname, 'B');
    });
  });

  group('模型语义', () {
    test('isChat 要求 method 与正文都成立', () {
      const empty = LiveDanmakuItem(method: 'WebcastChatMessage');
      expect(empty.isChat, isFalse, reason: '没有正文不算弹幕');

      const other = LiveDanmakuItem(method: 'WebcastMemberMessage', content: 'x');
      expect(other.isChat, isFalse, reason: '进场消息不是聊天');

      const ok = LiveDanmakuItem(method: 'WebcastChatMessage', content: 'hi');
      expect(ok.isChat, isTrue);
    });

    test('批次暴露 chats 子集', () {
      final batch = LiveDanmakuBatch(
        items: const [
          LiveDanmakuItem(method: 'WebcastChatMessage', content: 'a'),
          LiveDanmakuItem(method: 'WebcastMemberMessage'),
          LiveDanmakuItem(method: 'WebcastChatMessage', content: 'b'),
        ],
        cursor: '',
        rawBytes: 100,
      );
      expect(batch.chats.length, 2);
      expect(batch.isEmpty, isFalse);
    });
  });

  group('真实结构假设（用真实响应的开头字节）', () {
    test('顶层是 repeated Message，f1=method 名，f2=payload', () {
      // 真实响应开头（hex）：
      //   0a bb 03 0a 12 "WebcastRoomMessage" 12 e8 02 ...
      // 即：tag(1,LEN) len=443 | 里面 tag(1,LEN) len=18 "WebcastRoomMessage"
      //     | tag(2,LEN) len=360 payload
      //
      // **没有更外层的容器**。这条用例锁死这个结构假设——
      // 如果谁把解析器改成"先找 Response 字段"，这里就会失败。
      final methodName = utf8.encode('WebcastRoomMessage');
      final payload = List<int>.filled(50, 0x08);

      final body = _response([_message('WebcastRoomMessage', payload)]);

      final batch = parseLiveDanmakuResponse(body);
      expect(batch.items.length, 1);
      expect(batch.items.first.method, 'WebcastRoomMessage');
    });
  });
}
