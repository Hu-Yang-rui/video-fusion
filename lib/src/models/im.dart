/// 私信（IM）的数据模型（平台无关）。
///
/// # 字段来源（全部实测，2026-10-19，B站 8.91.1）
///
/// 会话来自 `session_svr/v1/session_svr/get_sessions`，
/// 消息来自 `svr_sync/v1/svr_sync/fetch_session_msgs`。

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
/// # 实测 `msg_type` 取值（B站 8.91.1，2026-10-19）
///
/// 来源：`message.bilibili.com` 前端 bundle 的 `iR` 枚举 +
/// `fetch_session_msgs` 真实响应交叉验证。
///
/// | 值 | 枚举名 | content 结构 |
/// |---|---|---|
/// | 0 | `INVALID` | 无效，不显示 |
/// | 1 | `TEXT` | `{"content":"..."}` |
/// | 2 | `IMG` | `{"url","width","height","size","imageType","original"}` |
/// | 5 | `WITHDRAW` | 撤回提示 |
/// | 6 | **`FAV_EMOJI`** | **自定义表情（大表情/收藏表情）**，结构与 IMG 同族 |
/// | 7 | `SHARE` | 分享卡片 |
/// | 10 | （系统卡片） | `{"title","text","jump_text","jump_uri",...}` |
/// | 17 | `VIDEO` | `{"duration","img","img_width","img_height","key","video_url"}` |
/// | 18 | （文本，与 1 同构） | `{"content":"..."}` |
/// | 10001+ | `ORDER`/`GOODS`/... | 电商卡片 |
///
/// # 关键区分（需求明确要求「不要把不同媒体混为一种类型」）
///
///  - [image]：普通图片消息（`2`），content 里是图片 URL + 尺寸
///  - [customEmoji]：**自定义表情**（`6`），也是图片形态，但语义是表情，
///    在聊天里应显示为小尺寸、不占满宽、可点击查看大图
///  - [sticker]：**文本中的表情短代码**（`[doge]`），不是独立消息，
///    由 [ImMessage.emojiShortcodes] 解析，属于文本消息的一部分
///  - [video]：视频消息（`17`），有封面 + 播放地址
///
/// 这四类在数据来源、渲染尺寸、交互上完全不同，**不能合并成一个
/// "媒体"枚举**——那正是需求里点名要避免的事。
///
/// **`unknown` 不是"错误"**：平台随时可能新增类型，UI 必须能安全显示
/// 一条占位（"该消息类型暂不支持显示"），而不是让整页报错。
enum ImMessageType {
  /// 文本消息（msg_type 1 / 18）。
  text,

  /// 图片消息（msg_type 2）。
  image,

  /// 自定义表情 / 收藏表情（msg_type 6 `FAV_EMOJI`）。
  ///
  /// 与 [image] 的区别：表情是**小尺寸内联资产**，通常带
  /// `gif_url`/`webp_url`（动图）或静态 `url`；图片是用户拍摄/选择的
  /// 内容图片，展示为大图。
  customEmoji,

  /// 视频消息（msg_type 17）。
  video,

  /// 撤回提示（msg_type 5）。
  withdraw,

  /// 分享卡片（msg_type 7）。
  shareCard,

  /// 系统卡片/通知（msg_type 10 等），例如"对方已关注你""会话已创建"。
  systemCard,

  /// 平台新增的、本项目尚未识别的类型。
  unknown;

  /// 从平台原始 `msg_type` 映射。
  ///
  /// 映射依据见枚举文档的实测表。**未知值一律落到 [unknown]**，
  /// 不猜测、不就近归类。
  static ImMessageType fromRaw(int? raw) => switch (raw) {
        1 || 18 => ImMessageType.text,
        2 => ImMessageType.image,
        6 => ImMessageType.customEmoji,
        17 => ImMessageType.video,
        5 => ImMessageType.withdraw,
        7 => ImMessageType.shareCard,
        10 => ImMessageType.systemCard,
        _ => ImMessageType.unknown,
      };

  /// 能否渲染出可读正文。false 时 UI 显示占位说明。
  bool get hasReadableText =>
      this == ImMessageType.text ||
      this == ImMessageType.systemCard ||
      this == ImMessageType.withdraw;

  /// 是否为图片形态（图片 / 自定义表情 / 视频封面都靠图片渲染，
  /// 但**渲染策略不同**，由 UI 分别处理）。
  bool get isImageBearing =>
      this == ImMessageType.image ||
      this == ImMessageType.customEmoji ||
      this == ImMessageType.video;
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

/// 一条消息里携带的图片 / 表情资产。
///
/// # 字段来源（实测 content JSON）
///
/// 图片（`msg_type=2`）：
/// ```json
/// {"url":"https://...","width":1200,"height":800,"size":123456,
///  "imageType":1,"original":1}
/// ```
///
/// 自定义表情（`msg_type=6`，`FAV_EMOJI`）：结构同族，
/// 额外可能有 `gif_url` / `webp_url`（动图变体）。
///
/// # 为什么宽高是必填的
///
/// 聊天列表里图片要在**加载完成前**就占好正确比例的坑位，
/// 否则会从 0 高度跳到真实高度，导致列表剧烈抖动。
/// 平台确实下发了宽高，所以这里要求它——拿不到就当作"未知尺寸"，
/// UI 退化到固定方形占位，**而不是猜一个比例**。
class ImMedia {
  const ImMedia({
    required this.url,
    this.width,
    this.height,
    this.sizeBytes,
    this.animatedUrl,
    this.mimeType,
  });

  /// 主资源地址（静态图，或动图的首帧）。
  final String url;

  /// 原始宽度（像素）。null 表示平台未下发。
  final int? width;

  /// 原始高度（像素）。null 表示平台未下发。
  final int? height;

  /// 文件大小（字节）。
  final int? sizeBytes;

  /// 动图地址（`gif_url` / `webp_url`）。
  ///
  /// **只有平台确实提供了才非 null**。没有就不播动画，
  /// 不自己把静态图当动图处理。
  final String? animatedUrl;

  final String? mimeType;

  /// 宽高比。两者都有且合法时返回，否则 null（UI 用固定占位）。
  double? get aspectRatio {
    final w = width, h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  /// 是否平台提供了动图资源。
  bool get hasAnimation => animatedUrl != null && animatedUrl!.isNotEmpty;

  /// 用于展示的地址：优先动图（若存在），否则静态图。
  String get displayUrl => hasAnimation ? animatedUrl! : url;
}

/// 从文本中提取表情短代码。
///
/// B 站的表情短代码形如 `[doge]`、`[笑哭]`、`[tv_doge]`。
/// 只识别 `[` + 1–20 个非方括号字符 + `]`，且按出现顺序去重。
///
/// # 为什么要排除嵌套
///
/// 朴素正则 `\[([^\[\]]{1,20})\]` 在 `[[doge]]` 上会从**第二个** `[`
/// 开始匹配到 `[doge]`，把嵌套结构误当成一个合法表情。
/// 这里用前后断言要求 `[` 前面不是 `[`、`]` 后面不是 `]`，
/// 保证匹配到的是**最外层的完整方括号**，嵌套一律不算。
///
/// 这是纯函数，便于单测；**不做 URL 映射**（映射表需要登录态才能拿到）。
List<String> extractEmojiShortcodes(String? text) {
  if (text == null || text.isEmpty) return const [];
  final matches = RegExp(r'(?<!\[)\[([^\[\]]{1,20})\](?!\])').allMatches(text);
  final out = <String>[];
  final seen = <String>{};
  for (final m in matches) {
    final name = m.group(1);
    if (name == null) continue;
    // 纯数字的方括号更像 [1] 这类引用，不是表情
    if (RegExp(r'^\d+$').hasMatch(name)) continue;
    if (seen.add(name)) out.add(name);
  }
  return out;
}

/// 一个表情资源。
class ImEmote {
  const ImEmote({
    required this.name,
    required this.shortcode,
    required this.url,
    this.id,
    this.animatedUrl,
    this.packageId,
    this.packageName,
  });

  /// 表情名（英文标识，如 `doge`）。
  final String name;

  /// 短代码（如 `[doge]`），发送文本时用它。
  final String shortcode;

  /// 静态图地址。
  final String url;

  /// 动图地址（`gif_url` / `webp_url`）。
  final String? animatedUrl;

  final int? id;

  /// 所属表情包 ID / 名称（用于分类）。
  final int? packageId;
  final String? packageName;

  bool get isAnimated => animatedUrl != null && animatedUrl!.isNotEmpty;

  /// 展示用地址（有动图优先动图）。
  String get displayUrl => isAnimated ? animatedUrl! : url;

  /// 转成媒体负载（用于发送自定义表情消息）。
  ImMedia toMedia({int? width, int? height}) => ImMedia(
        url: url,
        width: width,
        height: height,
        animatedUrl: animatedUrl,
      );
}

/// 一个表情包（分类）。
class ImEmotePackage {
  const ImEmotePackage({
    required this.id,
    required this.name,
    this.coverUrl,
    this.emotes = const [],
  });

  final int id;
  final String name;
  final String? coverUrl;
  final List<ImEmote> emotes;

  bool get isEmpty => emotes.isEmpty;
}

/// 表情面板加载结果。
class ImEmotePanel {
  const ImEmotePanel({
    this.packages = const [],
    this.loaded = false,
    this.unavailableReason,
  });

  /// 表情包列表（已过滤空包）。
  final List<ImEmotePackage> packages;

  /// 是否成功拿到数据。
  ///
  /// **false 不等于"用户没有表情"**：可能是未登录、接口变更、
  /// 或平台静默返回 null。UI 必须区分这两种情况。
  final bool loaded;

  /// 拿不到时的原因（面向用户）。
  final String? unavailableReason;

  bool get isEmpty => packages.isEmpty;

  /// 摊平的所有表情（用于"最近使用"匹配）。
  List<ImEmote> get allEmotes =>
      packages.expand((p) => p.emotes).toList(growable: false);
}

/// 一条私信消息。
///
/// 对应 `fetch_session_msgs` 的 `messages[i]`。实测字段：
/// ```
/// sender_uid, receiver_type, receiver_id, msg_type, content, msg_seqno,
/// timestamp, at_uids, msg_key, msg_status, notify_code, msg_source
/// ```
class ImMessage {  const ImMessage({
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
    this.media,
    this.emojiShortcodes = const [],
    this.localPreviewPath,
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

  /// 图片 / 表情 / 视频封面资产。仅 [ImMessageType.isImageBearing] 的类型有值。
  ///
  /// **null 表示"这条消息没有可渲染的媒体"**，不等于"解析失败"——
  /// 解析失败会体现在 [text] 为 null 且 [media] 为 null，
  /// UI 显示"图片加载失败/不支持"占位。
  final ImMedia? media;

  /// 文本里出现的表情短代码，按出现顺序去重。
  ///
  /// 例如 `"哈哈[doge]太强了[笑哭]"` → `['doge', '笑哭']`。
  ///
  /// # 为什么要单独存
  ///
  /// 需求要求区分「普通文本中的表情短代码」与「独立的表情图片消息」。
  /// 短代码本身是文本的一部分（原文照常显示），但 UI 可以选择把它们
  /// 渲染成内联小图。**本项目目前只做识别与暴露，不做内联替换**——
  /// 因为内联替换需要表情名 → 图片 URL 的映射表，而 B 站的表情面板
  /// 接口 `/x/emote/user/panel/web` 在未登录时返回 `packages: null`
  /// （实测），拿不到映射表就不该假装能渲染。
  final List<String> emojiShortcodes;

  /// 本地待发送图片的路径（仅本地"sending"气泡用）。
  ///
  /// **绝不能把它当作远端 URL**：它只用于在发送过程中显示预览，
  /// 服务端确认后会被 [media] 里的真实远端地址替换。
  final String? localPreviewPath;

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
    ImMedia? media,
    List<String>? emojiShortcodes,
    String? localPreviewPath,
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
        media: media ?? this.media,
        emojiShortcodes: emojiShortcodes ?? this.emojiShortcodes,
        localPreviewPath: localPreviewPath ?? this.localPreviewPath,
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
