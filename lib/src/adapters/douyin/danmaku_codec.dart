/// 抖音直播弹幕：protobuf 帧解析。
///
/// # 协议（实测 2026-10-18）
///
/// WebSocket 帧是 `PushFrame` protobuf，字段号来自 `douyin.proto`：
///
/// ```proto
/// message PushFrame {
///   uint64 seqId = 1;
///   uint64 logId = 2;
///   uint64 service = 3;
///   uint64 method = 4;
///   repeated HeadersList headersList = 5;
///   string payloadEncoding = 6;   // "gzip"
///   string payloadType = 7;       // "msg"
///   bytes payload = 8;            // gzip 压缩的 Response
/// }
///
/// message Response {
///   repeated Message messagesList = 1;
///   string cursor = 2;
///   uint64 fetchInterval = 3;
///   uint64 now = 4;
///   string internalExt = 5;
///   ...
///   bool needAck = 9;
/// }
///
/// message Message {
///   string method = 1;   // "WebcastChatMessage" 等
///   bytes payload = 2;   // gzip 压缩的具体消息
/// }
///
/// message ChatMessage {
///   Common common = 1;
///   User user = 2;
///   string content = 3;   // 弹幕正文
/// }
///
/// message User {
///   uint64 id = 1;
///   uint64 shortId = 2;
///   string nickName = 3;
/// }
/// ```
///
/// # 为什么不用 protoc 生成代码
///
/// 项目只用到 5 个字段（method / payload / user.nickName / content），
/// 引入 protobuf 运行时 + 生成代码不划算。这里用最小的 wire 解析器，
/// 只读需要的字段，遇到未知字段按 wire type 跳过。
///
/// 实测能正确解出：`TinyXin: 出隐刀带球啊`、`灾星: bkb` 等真实弹幕。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/live.dart';

/// 抖音消息里我们关心的类型。
enum DouyinMessageKind {
  /// 弹幕。
  chat,

  /// 进场。
  member,

  /// 点赞。
  like,

  /// 礼物。
  gift,

  /// 在线人数/统计。
  roomStats,

  /// 其它（不展示）。
  other,
}

/// 解析结果：一批消息 + 是否需要回 ack。
class DouyinPushResult {
  const DouyinPushResult({
    required this.messages,
    required this.needAck,
    this.cursor,
    this.internalExt,
  });

  final List<LiveMessage> messages;
  final bool needAck;
  final String? cursor;
  final String? internalExt;
}

/// 抖音弹幕 protobuf 解析器。
class DouyinDanmakuCodec {
  const DouyinDanmakuCodec();

  /// 解析一帧 WebSocket 二进制消息。
  ///
  /// 返回 null 表示这帧没有可展示内容（例如只有心跳/横幅）。
  DouyinPushResult? parseFrame(List<int> bytes) {
    final buf = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final frame = _parseFields(buf);

    // PushFrame.payload = field 8
    final payload = _firstBytes(frame[8]);
    if (payload is! Uint8List) return null;

    final respBytes = _maybeGunzip(payload);
    final resp = _parseFields(respBytes);

    // Response.needAck = field 9 (varint)
    final needAckRaw = _firstInt(resp[9]);
    final needAck = needAckRaw is int && needAckRaw != 0;

    // Response.cursor = 2, internalExt = 5
    final cursor = _firstString(resp[2]);
    final internalExt = _firstString(resp[5]);

    final messages = <LiveMessage>[];
    final rawMessages = resp[1];
    if (rawMessages != null) {
      for (final m in rawMessages) {
        if (m is! Uint8List) continue;
        final msg = _parseMessage(m);
        if (msg != null) messages.add(msg);
      }
    }

    return DouyinPushResult(
      messages: messages,
      needAck: needAck,
      cursor: cursor,
      internalExt: internalExt,
    );
  }

  /// 解析 `Message`（method + 压缩 payload）。
  LiveMessage? _parseMessage(Uint8List bytes) {
    final fields = _parseFields(bytes);
    final method = _firstString(fields[1]);
    if (method == null) return null;

    final payloadRaw = _firstBytes(fields[2]);
    if (payloadRaw is! Uint8List) return null;
    final inner = _maybeGunzip(payloadRaw);

    switch (method) {
      case 'WebcastChatMessage':
        return _parseChat(inner);
      case 'WebcastMemberMessage':
        return _parseMember(inner);
      case 'WebcastLikeMessage':
        return _parseLike(inner);
      case 'WebcastGiftMessage':
        return _parseGift(inner);
      case 'WebcastRoomUserSeqMessage':
        return _parseRoomStats(inner);
      default:
        // 其它类型（横幅/榜单/引导）不展示，返回 null
        return null;
    }
  }

  /// ChatMessage：user = 2, content = 3。
  LiveMessage? _parseChat(Uint8List bytes) {
    final f = _parseFields(bytes);
    final content = _firstString(f[3]);
    if (content == null || content.isEmpty) return null;
    final (nick, uid) = _parseUser(f[2]);
    return LiveMessage(
      type: LiveMessageType.chat,
      text: content,
      receivedAt: DateTime.now(),
      uname: nick,
      uid: uid,
    );
  }

  /// MemberMessage：user = 2（进场用户）。
  LiveMessage? _parseMember(Uint8List bytes) {
    final f = _parseFields(bytes);
    final (nick, uid) = _parseUser(f[2]);
    if (nick == null) return null;
    return LiveMessage(
      type: LiveMessageType.memberEnter,
      text: '来了',
      receivedAt: DateTime.now(),
      uname: nick,
      uid: uid,
    );
  }

  /// LikeMessage：count = 2, total = 5, user = 6（实测）。
  LiveMessage? _parseLike(Uint8List bytes) {
    final f = _parseFields(bytes);
    final (nick, uid) = _parseUser(f[6]);
    final count = _firstInt(f[2]) ?? 1;
    return LiveMessage(
      type: LiveMessageType.interaction,
      text: '点了 $count 个赞',
      receivedAt: DateTime.now(),
      uname: nick,
      uid: uid,
    );
  }

  /// GiftMessage：gift = 15（GiftStruct，含 name），user = 7，repeatCount = 5。
  LiveMessage? _parseGift(Uint8List bytes) {
    final f = _parseFields(bytes);
    final (nick, uid) = _parseUser(f[7]);
    final repeat = _firstInt(f[5]) ?? 1;

    // GiftStruct.name 是 field 2（string）
    var giftName = '礼物';
    final giftRaw = _firstBytes(f[15]);
    if (giftRaw is Uint8List) {
      final gf = _parseFields(giftRaw);
      giftName = _firstString(gf[2]) ?? '礼物';
    }

    return LiveMessage(
      type: LiveMessageType.gift,
      text: '送出 $giftName x$repeat',
      receivedAt: DateTime.now(),
      uname: nick,
      uid: uid,
      giftName: giftName,
      giftCount: repeat,
    );
  }

  /// RoomUserSeqMessage：total = 3（在线人数）。
  ///
  /// 这条不产生消息气泡，只用来更新在线人数。
  /// 这里返回 system 消息以便上层能识别并单独处理。
  LiveMessage? _parseRoomStats(Uint8List bytes) {
    final f = _parseFields(bytes);
    final total = _firstInt(f[3]);
    if (total == null) return null;
    return LiveMessage(
      type: LiveMessageType.system,
      text: '$total',
      receivedAt: DateTime.now(),
    );
  }

  /// User：nickName = 3, id = 1。
  (String?, int?) _parseUser(List<Object>? raw) {
    if (raw == null) return (null, null);
    final userRaw = _firstBytes(raw);
    if (userRaw is! Uint8List) return (null, null);
    final u = _parseFields(userRaw);
    final nick = _firstString(u[3]);
    final id = _firstInt(u[1]);
    return (nick, id);
  }

  // ── protobuf wire 解析 ──────────────────────────────────────

  /// 解析 protobuf 为 `field -> [values]`。
  ///
  /// varint 存为 `int`，length-delimited 存为 `Uint8List`。
  Map<int, List<Object>> _parseFields(Uint8List buf) {
    final out = <int, List<Object>>{};
    var pos = 0;

    while (pos < buf.length) {
      final tag = _readVarint(buf, pos);
      if (tag == null) break;
      pos = tag.$2;
      final field = tag.$1 >> 3;
      final wire = tag.$1 & 7;
      if (field == 0) break;

      switch (wire) {
        case 0: // varint
          final v = _readVarint(buf, pos);
          if (v == null) return out;
          pos = v.$2;
          (out[field] ??= []).add(v.$1);
        case 2: // length-delimited
          final l = _readVarint(buf, pos);
          if (l == null) return out;
          pos = l.$2;
          final len = l.$1;
          if (len < 0 || pos + len > buf.length) return out;
          (out[field] ??= [])
              .add(Uint8List.sublistView(buf, pos, pos + len));
          pos += len;
        case 5: // fixed32
          if (pos + 4 > buf.length) return out;
          pos += 4;
        case 1: // fixed64
          if (pos + 8 > buf.length) return out;
          pos += 8;
        default:
          // 未知 wire type：停止解析，避免越界
          return out;
      }
    }
    return out;
  }

  /// 读 varint，返回 (值, 新位置)。
  (int, int)? _readVarint(Uint8List buf, int pos) {
    var result = 0;
    var shift = 0;
    var p = pos;
    while (p < buf.length) {
      final b = buf[p++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return (result, p);
      shift += 7;
      // protobuf varint 最多 10 字节；超出视为数据损坏
      if (shift > 63) return null;
    }
    return null;
  }

  static Uint8List? _firstBytes(List<Object>? values) {
    if (values == null) return null;
    for (final v in values) {
      if (v is Uint8List) return v;
    }
    return null;
  }

  static String? _firstString(List<Object>? values) {
    if (values == null) return null;
    for (final v in values) {
      if (v is Uint8List) {
        try {
          return utf8.decode(v);
        } catch (_) {
          // 不是合法 UTF-8，跳过（可能是嵌套消息）
        }
      }
    }
    return null;
  }

  static int? _firstInt(List<Object>? values) {
    if (values == null) return null;
    for (final v in values) {
      if (v is int) return v;
    }
    return null;
  }

  /// gzip 解压（抖音的 payload 与内层消息都是 gzip）。
  static Uint8List _maybeGunzip(Uint8List buf) {
    if (buf.length < 2 || buf[0] != 0x1f || buf[1] != 0x8b) return buf;
    try {
      return Uint8List.fromList(gzip.decode(buf));
    } catch (_) {
      return buf;
    }
  }
}
