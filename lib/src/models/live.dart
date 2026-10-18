/// B 站直播的数据契约。
///
/// 覆盖：直播间列表、房间信息、播放流、弹幕消息。
///
/// 设计约束：
///  - 播放地址带时效签名，**不持久化**，每次进房重新解析。
///  - `live_status` 以平台返回为准，不猜测"是否在播"。
///  - 弹幕消息与普通评论是两套数据，不共用模型。
library;

/// 直播列表中的一个房间（列表接口返回的轻量信息）。
///
/// # 关于 [roomId] 与 [roomKey]
///
/// 不同平台的房间标识类型不同：
///  - B站是数字 `room_id`（如 21452505）
///  - 抖音是 19 位长整型字符串（如 `7697959724830018331`）
///
/// 19 位整数超出 Dart `int` 在 Web 端的安全整数范围，且平台本身
/// 就是以字符串下发的。因此这里用 [roomKey]（字符串）作为**唯一**
/// 的跨平台房间标识，[roomId] 仅作为 B站等数字平台的兼容视图保留。
///
/// 新增代码一律用 [roomKey]；[roomId] 为 0 表示该平台房间号不是数字。
class LiveRoomSummary {
  const LiveRoomSummary({
    required this.roomId,
    required this.title,
    required this.uname,
    this.coverUrl,
    this.faceUrl,
    this.online,
    this.areaName,
    this.parentAreaName,
    this.uid,
    String? roomKey,
    this.categoryCode,
    this.categoryLabel,
  }) : _roomKey = roomKey;

  /// 直播间号（进入房间用）。
  ///
  /// 仅对数字房间号的平台（B站）有意义。抖音等平台为 0，
  /// 此时必须用 [roomKey]。
  final int roomId;

  /// 跨平台房间标识（字符串形式）。始终有效。
  ///
  /// 构造时未显式传入则回退为 `roomId.toString()`。
  final String? _roomKey;

  String get roomKey => _roomKey ?? '$roomId';

  final String title;

  /// 主播昵称。
  final String uname;

  final String? coverUrl;
  final String? faceUrl;

  /// 人气值（平台口径，非真实在线人数）。
  final int? online;

  /// 二级分区名（如「英雄联盟」）。
  final String? areaName;

  /// 一级分区名（如「网游」）。
  final String? parentAreaName;

  /// 主播 UID。
  final int? uid;

  /// 平台原始分区码（抖音 `category`，B站不用）。
  ///
  /// 抖音**没有可用的分区列表接口**（实测 `/webcast/room/partition/`、
  /// `/webcast/room/tag/list/` 等全部返回 `url doesn't match`）。
  /// 但 `webcast/feed` 的每条房间都带真实的 `category` 码，
  /// 因此分区筛选只能**在客户端按这个码做本地过滤**，
  /// 不能向平台请求"某个分区的房间"。
  final int? categoryCode;

  /// 分区展示名。
  ///
  /// 只对**实测确认过**的码做映射（见 `DouyinLiveClient.categoryLabel`），
  /// 未知码为 null，UI 不展示分区名——不编造品类。
  final String? categoryLabel;
}

/// 直播间详情。
///
/// 与 [LiveRoomSummary] 一样，房间标识同时提供数字视图 [roomId]
/// 与跨平台字符串视图 [roomKey]。
class LiveRoomInfo {
  const LiveRoomInfo({
    required this.roomId,
    required this.shortId,
    required this.uid,
    required this.title,
    required this.liveStatus,
    this.online,
    this.description,
    this.coverUrl,
    this.keyframeUrl,
    this.areaName,
    this.parentAreaName,
    this.tags,
    this.liveStartTime,
    String? roomKey,
    this.uname,
    this.faceUrl,
    this.isPortrait = false,
  }) : _roomKey = roomKey;

  /// 数字房间号。抖音等平台为 0，此时用 [roomKey]。
  final int roomId;

  /// 跨平台房间标识（字符串形式）。始终有效。
  final String? _roomKey;

  String get roomKey => _roomKey ?? '$roomId';

  final int shortId;
  final int uid;
  final String title;

  /// 直播状态：0 未开播，1 直播中，2 轮播。
  final int liveStatus;

  final int? online;
  final String? description;
  final String? coverUrl;
  final String? keyframeUrl;
  final String? areaName;
  final String? parentAreaName;
  final String? tags;

  /// 开播时间（ISO 8601），未开播时为 null。
  final String? liveStartTime;

  /// 主播昵称（列表页已带过来时可直接展示，避免详情页闪空）。
  final String? uname;

  /// 主播头像。
  final String? faceUrl;

  /// 直播间是否为竖屏（影响画面填充方式）。
  ///
  /// 抖音直播大量是竖屏；B站以横屏为主。播放器据此选择
  /// `BoxFit.cover` 还是 `contain`。
  final bool isPortrait;

  bool get isLive => liveStatus == 1;

  /// 面向用户的直播状态文案。
  String get statusLabel => switch (liveStatus) {
        1 => '直播中',
        2 => '轮播中',
        _ => '未开播',
      };
}

/// 一个可播放的直播流。
class LiveStream {
  const LiveStream({
    required this.url,
    required this.protocolName,
    required this.formatName,
    required this.codecName,
    required this.qualityLabel,
    required this.qualityValue,
    this.availableQualities = const [],
  });

  /// 完整播放地址（含时效签名）。
  final String url;

  /// `http_stream`（FLV）或 `http_hls`（HLS）。
  final String protocolName;

  /// `flv` / `ts` / `fmp4`。
  final String formatName;

  /// `avc` / `hevc`。
  final String codecName;

  /// 清晰度显示名，如「原画」。
  final String qualityLabel;

  /// 清晰度值（qn），越大越清晰。
  final int qualityValue;

  /// 其它可选清晰度（同协议同格式）。
  final List<LiveStream> availableQualities;

  bool get isHls => protocolName == 'http_hls';

  /// 给用户看的协议标签。
  String get protocolLabel => isHls ? 'HLS' : 'FLV';
}

/// 弹幕/直播消息类型。
enum LiveMessageType {
  /// 普通聊天弹幕。
  chat,

  /// 礼物。
  gift,

  /// 进场提示。
  memberEnter,

  /// 系统公告（房间公告、禁言提示等）。
  system,

  /// 点赞/关注等互动提示。
  interaction,
}

/// 一条直播消息。
class LiveMessage {
  const LiveMessage({
    required this.type,
    required this.text,
    required this.receivedAt,
    this.uname,
    this.uid,
    this.isAdmin = false,
    this.isVip = false,
    this.giftName,
    this.giftCount,
  });

  final LiveMessageType type;
  final String text;
  final DateTime receivedAt;

  /// 发送者昵称（系统消息为 null）。
  final String? uname;
  final int? uid;

  /// 是否为房管。
  final bool isAdmin;

  /// 是否为老爷/提督等高等级身份。
  final bool isVip;

  final String? giftName;
  final int? giftCount;

  /// 是否属于需要以特殊样式呈现的消息。
  bool get isHighlighted =>
      type == LiveMessageType.gift ||
      type == LiveMessageType.system ||
      type == LiveMessageType.memberEnter;
}

/// 弹幕服务器连接参数（由 HTTP 接口换取）。
class LiveDanmakuEndpoint {
  const LiveDanmakuEndpoint({
    required this.token,
    required this.hostList,
    required this.roomId,
    required this.uid,
  });

  /// 鉴权 token。
  final String token;

  /// 可连接的弹幕服务器地址（wss）。
  final List<String> hostList;

  final int roomId;

  /// 当前用户 UID（未登录为 0）。
  final int uid;
}
