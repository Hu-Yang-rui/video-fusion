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
  });

  /// 直播间号（进入房间用）。
  final int roomId;

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
}

/// 直播间详情。
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
  });

  final int roomId;
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
