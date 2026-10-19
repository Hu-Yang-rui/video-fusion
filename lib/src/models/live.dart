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

  /// 直播状态（**平台无关的统一口径**）：0 未开播，1 直播中，2 轮播。
  ///
  /// # 这是归一化后的值，不是任何平台的原始值
  ///
  /// 各平台原始字段的取值完全不同，**由适配器负责归一化**，
  /// 模型这一层只保留 0/1/2 这一套语义：
  ///
  ///  - **B 站**：`room/v1/Room/get` 的 `live_status` 原生就是
  ///    0 未开播 / 1 直播中 / 2 轮播，适配器**原样透传**。
  ///  - **抖音**：`status` 实测**恒为 2 且含义是"直播中"**
  ///    （同批数据里 `video_feed_tag` = "直播中"）。
  ///    如果按 B 站的表直接读，2 会被当成"轮播"，直播中的房间
  ///    于是显示成"轮播中"。所以抖音适配器必须做映射：
  ///    `liveStatus: status == 2 ? 1 : 0`。
  ///
  /// # 改动这一层之前请先看这条
  ///
  /// 看到"抖音给 2、模型里 2 是轮播"很容易顺手去改适配器的映射，
  /// 那是错的方向：适配器现在是对的，模型的 0/1/2 才是需要保持稳定的
  /// 跨平台契约（[isLive]、[statusLabel] 以及所有消费方都按它写）。
  /// 若将来接入第三个平台，同样在它自己的适配器里归一化，
  /// **不要往模型里加平台分支**。
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
  ///
  /// 按 [liveStatus] 的**归一化口径**取值（0 未开播 / 1 直播中 / 2 轮播）。
  /// 抖音原始 `status` 恒为 2 但含义是"直播中"，其适配器已映射成 1，
  /// 所以这里不需要、也**不应该**加任何平台分支。
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
    this.requestHeaders = const {},
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

  /// 拉这条流时必须带的 HTTP 请求头。
  ///
  /// # 为什么这个字段归模型，而不是让 UI 自己拼
  ///
  /// 实测（2026-10-19）抖音直播的 HLS 分片：用 App UA 请求是
  /// `HTTP 206` + 完整 TS；用 `libmpv` 默认 UA 请求，部分
  /// douyincdn 节点返回 `HTTP 200 + 空 body`。地址是有效的、
  /// 播放器也初始化成功了，但取不到分片 —— 用户看到的是
  /// **画面全黑且没有任何报错**，极难归因。
  ///
  /// 所以"这条流要带什么头"是**平台知识**，必须由知道该平台的
  /// 适配器随流一起给出。UI 层的约束是零平台分支：如果让页面自己
  /// 按 `adapter.id` 拼 Referer/UA，就多了一处平台判断，且每接入
  /// 一个平台都要改一次页面。
  ///
  /// 为空时消费方（直播间页面）会退化成"只带 Referer"的最小集合，
  /// 不假装什么都对。
  final Map<String, String> requestHeaders;

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
    this.protocol = LiveDanmakuProtocol.bilibili,
    this.roomKey,
  });

  /// 鉴权 token。
  ///
  /// B站：`getDanmuInfo` 下发的 key，未登录拿不到（-352）。
  /// 抖音：**完整 wss URL**（已含 signature），见 [protocol]。
  final String token;

  /// 可连接的弹幕服务器地址（wss）。
  ///
  /// B站：`broadcastlv.chat.bilibili.com` 等，需自己拼 `/sub`。
  /// 抖音：为空，完整地址在 [token] 里。
  final List<String> hostList;

  final int roomId;

  /// 当前用户 UID（未登录为 0）。
  final int uid;

  /// 弹幕协议类型。两种平台的帧格式完全不同。
  final LiveDanmakuProtocol protocol;

  /// 跨平台房间标识（抖音是 19 位字符串）。
  final String? roomKey;
}

/// 弹幕协议类型。
enum LiveDanmakuProtocol {
  /// B站：自定义 16 字节头 + JSON/zlib body。
  bilibili,

  /// 抖音：`PushFrame` protobuf + gzip。
  douyin,
}
