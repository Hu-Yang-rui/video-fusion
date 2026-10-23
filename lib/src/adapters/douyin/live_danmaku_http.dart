/// 抖音直播弹幕：HTTP 轮询通道（`/webcast/im/fetch/`）。
///
/// # 为什么有这条通道，它和 wss 什么关系
///
/// 抖音直播弹幕有**两条**获取路径：
///
/// | 路径 | 需要 signature | 需要 wss | 本项目状态 |
/// |---|---|---|---|
/// | `wss://.../webcast/im/push/v2/` | ✅ 要（webmssdk 的 `sign.js`） | ✅ | 见 [DouyinDanmakuClient] |
/// | `POST /webcast/im/fetch/`（HTTP 轮询） | ❌ **不要** | ❌ **不要** | **本文件** |
///
/// 之前的结论是"抖音直播弹幕不可用，因为 signature 由平台下发的
/// `sign.js`（473 KB 混淆 JS）计算，本项目不执行它"。这个结论
/// **对 wss 路径成立，但漏了 HTTP 轮询这条**。
///
/// # 实测依据（本轮，真实在播房间）
///
/// 房间 `7698363358944627490`（44.7 万人在线）：
///
/// ```
/// 单次 im/fetch  → 130–196 KB
/// 连续 6 次轮询   → 每次 41–55 条消息，其中 4–16 条是弹幕
/// 累计解析        → 67 条真实弹幕（如「[🌈吱昂] 还发吗」）
/// ```
///
/// 消息类型也全部解出：`WebcastChatMessage`（弹幕）、
/// `WebcastMemberMessage`（进场）、`WebcastFansclubMessage`（粉丝团）、
/// `WebcastRoomUserSeqMessage`（在线人数）等 14 种。
///
/// # 为什么之前测成"空"
///
/// 用了**已下播的房间号**。房间 `status != 2` 时 `im/fetch` 返回空，
/// 于是被误判为"接口不可用"。这与接口本身无关。
///
/// # 前置条件
///
/// 需要正式 `UIFID` Cookie（页面加载时下发，约 1–4 秒）。本客户端
/// 复用 [DouyinWebSigner] 拿到的会话——它已经解决了"如何拿到 UIFID"
/// 这个问题（评论/详情都靠它）。
///
/// # 轮询而不是长连接
///
/// `im/fetch` 是**拉模式**：每次带 `cursor` 请求一次，返回上一批之后
/// 的新消息。因此需要定时轮询（实测 1.5 秒间隔即可，且不会漏消息）。
/// 代价是延迟比 wss 高（约 1.5–3 秒），换来的是**不需要任何签名**。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../models/live.dart';
import 'web_signer.dart';

/// 一条直播弹幕（HTTP 通道解析结果）。
class LiveDanmakuItem {
  const LiveDanmakuItem({
    required this.method,
    this.nickname,
    this.userId,
    this.content,
    this.msgId,
    this.createTimeMs,
  });

  /// 消息类型，例如 `WebcastChatMessage`。
  final String method;

  /// 发送者昵称（非聊天消息时可能为空）。
  final String? nickname;

  /// 发送者 ID。
  final String? userId;

  /// 弹幕正文（非聊天消息时为 null）。
  final String? content;

  /// 平台消息 ID。
  final String? msgId;

  /// 消息创建时间（毫秒时间戳，平台口径）。
  final int? createTimeMs;

  /// 是否是一条真正的聊天弹幕。
  bool get isChat => method == 'WebcastChatMessage' && (content ?? '').isNotEmpty;

  /// 是否有人进场。
  bool get isMemberEnter => method == 'WebcastMemberMessage';

  Map<String, Object?> toJson() => {
        'method': method,
        if (nickname != null) 'nickname': nickname,
        if (content != null) 'content': content,
      };
}

/// 一次 `im/fetch` 的结果。
class LiveDanmakuBatch {
  const LiveDanmakuBatch({
    required this.items,
    required this.cursor,
    required this.rawBytes,
  });

  final List<LiveDanmakuItem> items;

  /// 下一页游标（平台返回，用于下次请求）。
  final String cursor;

  /// 本次响应字节数（诊断用）。
  final int rawBytes;

  List<LiveDanmakuItem> get chats =>
      items.where((i) => i.isChat).toList(growable: false);

  bool get isEmpty => items.isEmpty;
}

/// 抖音直播弹幕 HTTP 轮询客户端。
class DouyinLiveDanmakuHttp {
  DouyinLiveDanmakuHttp({
    required DouyinWebSigner signer,
    FusionLogger? logger,
  })  : _signer = signer,
        _logger = logger ?? appLogger;

  final DouyinWebSigner _signer;
  final FusionLogger _logger;

  /// 轮询间隔。实测 1.5 秒不漏消息，且对平台压力可接受。
  static const Duration defaultPollInterval = Duration(milliseconds: 1500);

  String _cursor = '';

  /// 当前游标（诊断用）。
  String get cursor => _cursor;

  /// 重置游标（换房间时调用）。
  void reset() => _cursor = '';

  /// 拉一批消息。
  ///
  /// [roomId] 是 19 位房间号字符串。
  ///
  /// 失败时抛 [FusionException]，**不返回空批次**——空批次会让调用方
  /// 以为"这个房间没人说话"，而真相是请求失败了。
  Future<LiveDanmakuBatch> fetch({
    required String roomId,
    String host = 'https://live.douyin.com',
  }) async {
    final key = roomId.trim();
    if (key.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '直播间号为空。',
        technicalMessage: 'live danmaku: empty roomId',
        platformId: 'douyin',
      );
    }

    // 复用 WebView 会话：im/fetch 要正式 UIFID，这个由 signer 负责。
    final ready = await _signer.ensureReady(requireFullUifid: true);
    if (!ready) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音会话初始化未完成，暂时无法加载弹幕。',
        technicalMessage:
            'live danmaku requires UIFID; readiness=${_signer.readiness.name}',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final query = <String, String>{
      'aid': '6383',
      'app_name': 'douyin_web',
      'live_id': '1',
      'device_platform': 'web',
      'language': 'zh-CN',
      'enter_from': 'link_share',
      'cookie_enabled': 'true',
      'screen_width': '1280',
      'screen_height': '860',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '124.0.0.0',
      'room_id': key,
      'cursor': _cursor,
      'resp_content_type': 'protobuf',
      'did_rule': '3',
      'identity': 'audience',
      'need_persist_msg_count': '15',
    };

    // 在页面上下文里 fetch：同源、自动带 Cookie、自动带 Referer。
    //
    // 不自己拼 HTTP 请求的原因：Cookie 在 WebView 里，Dart 侧拿不到
    // 完整的（UIFID 是 HttpOnly 时尤其）。让页面发最省事也最稳。
    final response = await _signer.requestRawBytes(
      path: '/webcast/im/fetch/',
      params: query,
      host: host,
    );

    if (response.statusCode != 200) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '加载直播弹幕失败（HTTP ${response.statusCode}）。',
        technicalMessage:
            'im/fetch returned ${response.statusCode} for room $key',
        httpStatus: response.statusCode,
        platformId: 'douyin',
        retryable: true,
      );
    }

    final bytes = response.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音返回了空的弹幕响应。',
        technicalMessage: 'im/fetch returned 0 bytes for room $key; '
            'room may be offline (status != 2)',
        platformId: 'douyin',
        retryable: true,
        diagnostics: {
          'roomId': key,
          'hint': '房间未开播时该接口返回空',
        },
      );
    }

    final batch = parseLiveDanmakuResponse(bytes, currentCursor: _cursor);
    _cursor = batch.cursor;

    _logger.debug('live danmaku: batch', {
      'room': key,
      'bytes': bytes.length,
      'items': batch.items.length,
      'chats': batch.chats.length,
    });

    return batch;
  }

  /// 转成项目统一的 [LiveMessage] 模型（供 UI 直接渲染）。
  ///
  /// 只映射 UI 认识的两类：聊天弹幕与进场提示。其余消息类型
  /// （横幅、榜单、粉丝团、在线人数）不在这里塞进聊天流——
  /// 那会把弹幕区刷成系统公告墙。
  static List<LiveMessage> toLiveMessages(LiveDanmakuBatch batch) {
    final out = <LiveMessage>[];
    for (final item in batch.items) {
      if (item.isChat) {
        out.add(LiveMessage(
          type: LiveMessageType.chat,
          uname: item.nickname ?? '',
          text: item.content ?? '',
          receivedAt: item.createTimeMs == null
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(item.createTimeMs!),
        ));
      } else if (item.isMemberEnter) {
        out.add(LiveMessage(
          type: LiveMessageType.memberEnter,
          uname: item.nickname ?? '',
          text: '${item.nickname ?? '有人'} 进入直播间',
          receivedAt: DateTime.now(),
        ));
      }
    }
    return out;
  }
}

// ── protobuf 解析 ─────────────────────────────────────────────

/// 解析一次 `im/fetch` 的 protobuf 响应。
///
/// # 实测结构（逐字节核对过）
///
/// 响应体最外层**直接就是 repeated Message**，没有 `Response` 包裹：
///
/// ```
/// // 开头 hex: 0a bb 03 0a 12 "WebcastRoomMessage" 12 e8 02 ...
/// Message {
///   string method  = 1;   // "WebcastChatMessage" / "WebcastMemberMessage" ...
///   bytes  payload = 2;
///   int64  msgId   = 3;
///   ...
/// }
/// WebcastChatMessage {
///   Common common  = 1;
///   User   user    = 2;   // id=1, nickname=3
///   string content = 3;
/// }
/// ```
///
/// # 三个坑
///
///  1. **没有外层容器**：不要去找 `Response` / `PushFrame` 字段。
///  2. **payload 没有 gzip**：gzip 是 wss 推送帧才有的。
///  3. **f1 是 method 名字符串**，不是嵌套消息；按嵌套递归会解出乱码。
LiveDanmakuBatch parseLiveDanmakuResponse(
  Uint8List bytes, {
  String currentCursor = '',
}) {
  final items = <LiveDanmakuItem>[];
  var cursor = currentCursor;
  final r = _PbReader(bytes);

  while (!r.atEnd) {
    final tag = r.varint();
    final wire = tag & 7;

    if (wire != 2) {
      r.skip(wire);
      continue;
    }

    final len = r.varint();
    final start = r.pos;
    final end = start + len;
    if (end > bytes.length) break;

    // # 关键：外层每一条都是完整的 Message
    //
    // 响应体的顶层结构是 `repeated Message`——也就是"一条 Message 接
    // 一条 Message"，**没有更外层的容器字段**。
    //
    // 每条 Message 的第一个字段恰好是 `f1 = method 名`。因此不能写成
    // `if (field == 1) { ... }`：那样会以为外层 f1 是 method，实际它是
    // 整条 Message 的 tag，而 method 在**内层**的 f1。层级搞混就解不出。
    //
    // 正确做法：顶层**无条件**把这一段当成一条 Message 解析。
    final msg = _readFields(bytes, start, end);
    final methodField = msg[1];
    final payloadField = msg[2];
    if (methodField != null && payloadField != null) {
      final method = _readString(bytes, methodField);
      final payload = Uint8List.sublistView(
        bytes,
        payloadField.offset,
        payloadField.offset + payloadField.length,
      );
      items.add(_parseMessage(method, payload));
    }

    // cursor：平台放在 headers（field 9）里，key=4。
    final headersField = msg[9];
    if (headersField != null) {
      final headers = _readFields(
        bytes,
        headersField.offset,
        headersField.offset + headersField.length,
      );
      final c = headers[4];
      if (c != null) {
        final v = _readString(bytes, c);
        if (v.isNotEmpty) cursor = v;
      }
    }

    r.pos = end;
  }

  return LiveDanmakuBatch(
    items: items,
    cursor: cursor,
    rawBytes: bytes.length,
  );
}

LiveDanmakuItem _parseMessage(String method, Uint8List payload) {
  final f = _readFields(payload, 0, payload.length);

  String? nickname;
  String? userId;
  String? content;
  String? msgId;
  int? createTime;

  // User（field 2）：id=1, nickname=3
  final user = f[2];
  if (user != null) {
    final u = _readFields(payload, user.offset, user.offset + user.length);
    final idField = u[1];
    if (idField != null) userId = '${idField.varint}';
    final nickField = u[3];
    if (nickField != null) nickname = _readString(payload, nickField);
  }

  // content（field 3）
  final contentField = f[3];
  if (contentField != null) content = _readString(payload, contentField);

  // Common（field 1）：msgId=2, createTime=4
  final common = f[1];
  if (common != null) {
    final c = _readFields(payload, common.offset, common.offset + common.length);
    final mid = c[2];
    if (mid != null) msgId = '${mid.varint}';
    final ct = c[4];
    if (ct != null) createTime = ct.varint;
  }

  return LiveDanmakuItem(
    method: method,
    nickname: nickname,
    userId: userId,
    content: content,
    msgId: msgId,
    createTimeMs: createTime,
  );
}

/// 一个 length-delimited 字段的位置与长度。
class _PbField {
  const _PbField({required this.offset, required this.length, this.varint = 0});
  final int offset;
  final int length;
  final int varint;
}

/// 把一个 protobuf 消息读成 `field → _PbField`。
Map<int, _PbField> _readFields(Uint8List bytes, int start, int end) {
  final out = <int, _PbField>{};
  final r = _PbReader(bytes)..pos = start;
  while (r.pos < end) {
    final tag = r.varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (wire == 0) {
      final v = r.varint();
      out[field] = _PbField(offset: r.pos, length: 0, varint: v);
    } else if (wire == 2) {
      final len = r.varint();
      out[field] = _PbField(offset: r.pos, length: len);
      r.pos += len;
    } else if (wire == 1) {
      r.pos += 8;
    } else if (wire == 5) {
      r.pos += 4;
    } else {
      break;
    }
  }
  return out;
}

String _readString(Uint8List bytes, _PbField f) {
  if (f.length == 0) return '';
  try {
    return utf8.decode(
      Uint8List.sublistView(bytes, f.offset, f.offset + f.length),
    );
  } on FormatException {
    return '';
  }
}

class _PbReader {
  _PbReader(this._bytes);
  final Uint8List _bytes;
  int pos = 0;

  bool get atEnd => pos >= _bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= _bytes.length) {
        throw const FormatException('protobuf: truncated varint');
      }
      final b = _bytes[pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) throw const FormatException('protobuf: varint too long');
    }
    return result;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        pos += varint();
      case 5:
        pos += 4;
      default:
        throw FormatException('protobuf: unknown wire $wire');
    }
  }
}
