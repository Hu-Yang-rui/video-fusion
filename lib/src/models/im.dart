/// 私信（IM）的数据模型（平台无关）。
///
/// # 字段来源（全部实测，2026-10-19，B站 8.91.1）
///
/// 会话来自 `session_svr/v1/session_svr/get_sessions`，
/// 消息来自 `svr_sync/v1/svr_sync/fetch_session_msgs`。
/// 实测的响应结构见 `video-fusion-prompts/APK-API-REPORT.md` 与 HANDOVER §十六。
///
/// # 设计约束
///
///  - **不编造字段**。平台没给的（例如服务端不下发"已读回执"）就是 null，
///    不用本地推断填上。
///  - **未知消息类型安全降级**。实测 `msg_type` 至少有 1/2/10/18 四种，
///    平台以后加新类型时不能让整个会话崩掉 —— 见 [ImMessageType]。
///  - **正文与元数据分离**。`content` 是原始 JSON 串，解析后的可读文本在
///    [ImMessage.text]；解析失败时 [text] 为 null 而不是抛异常。
library;

/// 一条私信消息的类型。
///
/// 实测 `msg_type` 取值（B站）：
///  - `1`  → 文本（`content` = `{"content":"..."}`）
///  - `2`  → 图片（`content` = `{"url":..,"height":..,"width":..,"size":..}`）
///  - `10` → 系统卡片/通知（`content` = `{"title":..,"text":..,"jump_text":..,"jump_uri":..,...}`）
///  - `18` → 文本（`content` = `{"content":"..."}`，与 1 同构）
///
/// **`unknown` 不是"错误"**：平台随时可能新增类型，UI 必须能安全显示
/// 一条占位（"该消息类型暂不支持显示"），而不是让整页报错。
enum ImMessageType {
  /// 文本消息（msg_type 1 / 18）。
  text,

  /// 图片消息（msg_type 2）。**当前只展示占位**：没有做图片下载/缓存，
  /// 也没有验证图片域名是否需要 Referer。
  image,

  /// 系统卡片/通知（msg_type 10），例如"对方已关注你""会话已创建"。
  systemCard,

  /// 平台新增的、本项目尚未识别的类型。
  unknown;

  /// 从平台原始 `msg_type` 映射。
  static ImMessageType fromRaw(int? raw) => switch (raw) {
        1 || 18 => ImMessageType.text,
        2 => ImMessageType.image,
        10 => ImMessageType.systemCard,
        _ => ImMessageType.unknown,
      };

  /// 能否渲染出可读正文。false 时 UI 显示占位说明。
  bool get hasReadableText => this == ImMessageType.text || this == ImMessageType.systemCard;
}

/// 一个私信会话（会话列表里的一行）。
///
/// 对应 `get_sessions` 的 `session_list[i]`。实测字段（节选）：
/// ```
/// talker_id, session_type, session_ts, unread_count, is_follow, is_dnd,
/// ack_seqno, ack_ts, max_seqno, top_ts, group_name, group_cover,
/// last_msg{msg_type,timestamp,...}, live_status, user_label, ...
/// ```
class ImSession {
  const ImSession({
    required this.talkerId,
    required this.sessionType,
    required this.unreadCount,
    this.sessionTs = 0,
    this.ackSeqno = 0,
    this.maxSeqno = 0,
    this.isTop = false,
    this.isFollow = false,
    this.isDnd = false,
    this.groupName,
    this.groupCoverUrl,
    this.lastMsgType,
    this.lastMsgTimestamp = 0,
    this.lastMsgText,
    this.liveStatus = 0,
    this.userLabel,
  });

  /// 对方用户 ID（`talker_id`）。群聊时是群 ID。
  final int talkerId;

  /// 会话类型：1 = 单聊，2 = 群聊（实测单聊为 1）。
  final int sessionType;

  /// 服务端下发的未读数。**以它为准**，不用本地"打开就算已读"推算。
  final int unreadCount;

  /// 会话最后活跃时间（秒级时间戳）。
  final int sessionTs;

  /// 已读到的 seqno（用于 `update_ack`）。
  final int ackSeqno;

  /// 会话最大 seqno（标记已读时要带上）。
  final int maxSeqno;

  /// 是否置顶（`top_ts > 0`）。
  final bool isTop;

  final bool isFollow;
  final bool isDnd;

  /// 群名（单聊为 null）。
  final String? groupName;
  final String? groupCoverUrl;

  /// 最后一条消息的类型与时间（正文需要另外拉，实测列表只给元数据）。
  final int? lastMsgType;
  final int lastMsgTimestamp;

  /// 最后一条消息的可读摘要。
  ///
  /// 实测 `last_msg` 里**没有**可直接展示的正文（只有 msg_type/timestamp 等），
  /// 所以这里通常为 null；会话列表会退化为显示"有新消息"。
  /// **不要**为了列表好看而伪造摘要。
  final String? lastMsgText;

  /// 直播间状态（若该会话来自直播）。
  final int liveStatus;

  /// 平台给的用户标签（例如粉丝勋章），原样保留。
  final Object? userLabel;

  /// 用于列表展示的标题：群聊用群名，单聊留给上层用 user_infos 补昵称。
  String get displayTitle => groupName ?? '用户 $talkerId';

  /// 时间戳 → DateTime（秒级）。
  DateTime? get sessionTime => sessionTs > 0
      ? DateTime.fromMillisecondsSinceEpoch(sessionTs * 1000)
      : null;

  ImSession copyWith({
    int? unreadCount,
    int? sessionTs,
    int? ackSeqno,
    int? maxSeqno,
    bool? isTop,
    String? lastMsgText,
    int? lastMsgType,
    int? lastMsgTimestamp,
  }) =>
      ImSession(
        talkerId: talkerId,
        sessionType: sessionType,
        unreadCount: unreadCount ?? this.unreadCount,
        sessionTs: sessionTs ?? this.sessionTs,
        ackSeqno: ackSeqno ?? this.ackSeqno,
        maxSeqno: maxSeqno ?? this.maxSeqno,
        isTop: isTop ?? this.isTop,
        isFollow: isFollow,
        isDnd: isDnd,
        groupName: groupName,
        groupCoverUrl: groupCoverUrl,
        lastMsgType: lastMsgType ?? this.lastMsgType,
        lastMsgTimestamp: lastMsgTimestamp ?? this.lastMsgTimestamp,
        lastMsgText: lastMsgText ?? this.lastMsgText,
        liveStatus: liveStatus,
        userLabel: userLabel,
      );
}

/// 一页会话。
class ImSessionPage {
  const ImSessionPage({
    required this.items,
    required this.hasMore,
    this.nextEndTs = 0,
  });

  final List<ImSession> items;

  /// 服务端 `has_more`。**必须用它判断是否还有下一页**，
  /// 不能靠"返回条数 < count"推断（实测 size 与返回条数不完全对应）。
  final bool hasMore;

  /// 下一页的 `end_ts`（本页最后一条的 session_ts）。
  final int nextEndTs;

  bool get isEmpty => items.isEmpty;
}

/// 一条私信消息。
///
/// 对应 `fetch_session_msgs` 的 `messages[i]`。实测字段：
/// ```
/// sender_uid, receiver_type, receiver_id, msg_type, content, msg_seqno,
/// timestamp, at_uids, msg_key, msg_status, notify_code, msg_source
/// ```
class ImMessage {
  const ImMessage({
    required this.msgKey,
    required this.senderUid,
    required this.receiverId,
    required this.receiverType,
    required this.msgType,
    required this.timestamp,
    required this.content,
    this.msgSeqno = 0,
    this.msgStatus = 0,
    this.atUids,
    this.notifyCode,
    this.msgSource,
    this.text,
    this.rawType,
    this.sendState = ImSendState.sent,
    this.localError,
  });

  /// 平台消息唯一 ID。
  ///
  /// **去重就靠它**：翻页时服务端可能返回与上一页重叠的消息（实测某次
  /// 0 重叠，但契约上不保证），按 [msgKey] 去重是唯一可靠做法。
  final String msgKey;

  final int senderUid;
  final int receiverId;

  /// 接收方类型：1 = 用户，2 = 群（实测单聊为 1）。
  final int receiverType;

  /// 平台原始 `msg_type`。见 [ImMessageType.fromRaw]。
  final int msgType;

  /// 秒级时间戳。
  final int timestamp;

  /// 原始 content 串（JSON）。保留原文便于排查，不丢信息。
  final String content;

  /// 消息序号，用于分页（`end_seqno`）与已读确认（`ack_seqno`）。
  final int msgSeqno;

  /// 平台消息状态。
  final int msgStatus;

  final String? atUids;
  final int? notifyCode;
  final int? msgSource;

  /// 解析后的可读文本。null 表示"该类型没有文本"或"解析失败"。
  ///
  /// **解析失败不抛异常**：一条脏数据不能毁掉整页会话。
  final String? text;

  /// 原始类型（`msgType` 的别名，便于 UI 层不依赖 int 字面量）。
  final int? rawType;

  /// 发送状态（本地状态，非服务端字段）。
  final ImSendState sendState;

  /// 发送失败时的原因（脱敏后的用户可读文案）。
  final String? localError;

  /// 消息类型（安全映射，未知类型落到 [ImMessageType.unknown]）。
  ImMessageType get type => ImMessageType.fromRaw(msgType);

  DateTime get sentAt => DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);

  /// 是否为"我"发出的消息。
  bool isMine(int myUid) => senderUid == myUid;

  ImMessage copyWith({
    String? text,
    ImSendState? sendState,
    String? localError,
    String? msgKey,
  }) =>
      ImMessage(
        msgKey: msgKey ?? this.msgKey,
        senderUid: senderUid,
        receiverId: receiverId,
        receiverType: receiverType,
        msgType: msgType,
        timestamp: timestamp,
        content: content,
        msgSeqno: msgSeqno,
        msgStatus: msgStatus,
        atUids: atUids,
        notifyCode: notifyCode,
        msgSource: msgSource,
        text: text ?? this.text,
        rawType: rawType,
        sendState: sendState ?? this.sendState,
        localError: localError ?? this.localError,
      );
}

/// 消息的发送状态。
///
/// **只有服务端确认后才允许是 [sent]**。本地"已发出 HTTP 请求"
/// 不等于发送成功 —— 实测 `send_msg` 对空内容返回 `code=-400`，
/// 对缺 csrf 返回 `-111`，都必须如实落到 [failed]。
enum ImSendState {
  /// 正在发送（UI 显示菊花，不显示对勾）。
  sending,

  /// 服务端已确认（返回 code=0 且带回 msg_key）。
  sent,

  /// 发送失败（可重试）。
  failed,
}

/// 一页历史消息。
class ImMessagePage {
  const ImMessagePage({
    required this.items,
    required this.hasMore,
    this.minSeqno = 0,
    this.maxSeqno = 0,
  });

  /// **服务端顺序：新 → 旧（降序）**，实测 20 条时间戳单调递减。
  /// UI 若要按时间正序显示，需要自己反转。
  final List<ImMessage> items;

  final bool hasMore;

  /// 本页最小/最大 seqno，用于继续往前翻（`end_seqno`）与标记已读。
  final int minSeqno;
  final int maxSeqno;

  bool get isEmpty => items.isEmpty;
}

/// 未读汇总。
///
/// 实测 `single_unread` 返回 8 个字段：
/// `unfollow_unread, follow_unread, unfollow_push_msg, dustbin_push_msg,
///  dustbin_unread, biz_msg_unfollow_unread, biz_msg_follow_unread, custom_unread`
class ImUnread {
  const ImUnread({
    this.unfollowUnread = 0,
    this.followUnread = 0,
    this.bizMsgUnfollowUnread = 0,
    this.bizMsgFollowUnread = 0,
    this.dustbinUnread = 0,
    this.customUnread = 0,
  });

  final int unfollowUnread;
  final int followUnread;
  final int bizMsgUnfollowUnread;
  final int bizMsgFollowUnread;
  final int dustbinUnread;
  final int customUnread;

  /// 入口红点用的总数。
  ///
  /// 只累加"未关注的人"与"关注的人"两类私信未读；
  /// `dustbin_*` 是垃圾桶里的，`custom_unread` 语义未确认，
  /// 都不计入 —— 宁可少报，不虚报。
  int get total => unfollowUnread + followUnread + bizMsgUnfollowUnread + bizMsgFollowUnread;
}

/// 私信用户信息（头像/昵称）。
///
/// 实测 `x/im/user_infos` 返回的字段是 **`mid` / `name` / `face`**，
/// 不是 `uid` / `nick` —— 这点与直觉不同，照 `uid` 解析会全部拿到 null。
class ImUserInfo {
  const ImUserInfo({
    required this.mid,
    this.name,
    this.faceUrl,
    this.sign,
    this.level,
  });

  final int mid;
  final String? name;
  final String? faceUrl;
  final String? sign;
  final int? level;
}

/// 发送结果。
class ImSendResult {
  const ImSendResult({
    required this.accepted,
    this.msgKey,
    this.msgContent,
    this.upstreamCode,
    this.message,
  });

  /// 服务端是否确认接收。
  ///
  /// **这是唯一可信的成功判据**：`code == 0` 且拿到 msg_key。
  /// 光有 HTTP 200 不算（实测空内容也是 200）。
  final bool accepted;

  /// 服务端分配的消息 ID（回填本地消息用）。
  final String? msgKey;

  /// 服务端回显的 content（可能与本地不同，以它为准）。
  final String? msgContent;

  final Object? upstreamCode;
  final String? message;
}
