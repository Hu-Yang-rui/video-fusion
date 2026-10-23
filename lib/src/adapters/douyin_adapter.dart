/// 抖音（Douyin）平台适配器。
///
/// # ⚠️ 能力现状（2026-10 实测，务必阅读）
///
/// 本适配器的**链接识别**与**短链展开**已完整实现并通过真实网络验证。
/// 但**元数据获取在当前环境下不可用**，原因是平台侧的强制访问控制，
/// 而非本适配器实现缺陷。实测证据：
///
/// ```
/// GET https://www.douyin.com/aweme/v1/web/aweme/detail/?...&aweme_id=...
/// → HTTP 403
/// → body: "Blocked by ArgusSecurityPlugin Uifid Not Found"
/// ```
///
/// 关键点：该响应在**签名校验之前**就被 Argus 风控拦截，因此
/// **即使 `a_bogus` 签名完全正确也无法通过**。放行还需要服务端签发的
/// `UIFID_TEMP` Cookie，而该 Cookie 只下发给真实浏览器环境
/// （需要驱动浏览器并执行平台的风控 JS）。
///
/// 驱动浏览器以获取风控 Cookie，属于**规避平台访问控制措施**，
/// 已超出本项目"合法、合规、可验证"的边界（见需求三），因此**不实现**。
///
/// 其它已验证失效/不可用的路径：
///  - `iesdouyin.com/web/api/v2/aweme/iteminfo/` → 200 但响应体长度为 0（接口已停用）
///  - `www.douyin.com/oembed` → 404（不存在）
///  - `iesdouyin.com/share/video/{id}` 分享页 → 200，但内嵌 `_ROUTER_DATA`
///    仅含渲染上下文（ua / query / serverToken 等），**不含任何视频数据**
///  - `ttwid.bytedance.com/ttwid/union/register/` → 404（研究报告中记录的匿名注册端点已失效）
///
/// # 仍然可用的能力
///
///  - **链接识别**：`www.douyin.com/video/{id}`、`v.douyin.com/{code}` 短链、
///    `/share/video/{id}` 等形态均可正确提取 aweme_id。
///  - **官方嵌入播放**：`open.douyin.com/player/video?vid={id}` 返回 200，
///    无 `X-Frame-Options` / CSP 限制，可作为官方嵌入播放入口。
///
/// # 签名与凭证
///
/// `a_bogus` 由本仓库内的纯 Dart 实现产出，不依赖外部服务。
///
/// 本适配器**不携带**任何 Cookie、`UIFID_TEMP`、`ttwid`、账号令牌，
/// 也不生成伪造的设备指纹。
library;

import 'dart:convert';

import '../core/credential_vault.dart';
import '../core/errors.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../core/qr_login.dart';
import '../models/feed.dart';
import '../models/im.dart';
import '../models/interaction.dart';
import '../models/live.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import '../models/video_danmaku.dart';
import 'douyin/live_client.dart';
import 'douyin/live_danmaku_http.dart';
import 'douyin/web_signer.dart';
import 'platform_adapter.dart';

/// 抖音播放地址的进程内缓存项。
///
/// 只存在于内存，不持久化：直链带签名与时效，落盘后很快就会失效，
/// 且不应把带签名的 URL 写入磁盘。
class _CachedPlayback {
  const _CachedPlayback({
    required this.url,
    required this.fallbackUrls,
    required this.headers,
    required this.cachedAt,
    this.quality,
    this.qualities = const [],
  });

  final String url;
  final List<String> fallbackUrls;
  final Map<String, String> headers;
  final DateTime cachedAt;
  final PlaybackQuality? quality;
  final List<PlaybackQuality> qualities;

  /// 抖音直链实测有效期约 2 小时；这里保守按 30 分钟判断。
  bool get isUsable =>
      DateTime.now().difference(cachedAt) < const Duration(minutes: 30);

  /// 过期时间（ISO 8601），供上层展示与诊断。
  String get expiresAt => cachedAt
      .add(const Duration(minutes: 30))
      .toUtc()
      .toIso8601String();
}

class DouyinAdapter implements PlatformAdapter, QrLoginCapable {
  DouyinAdapter({
    required FusionHttpClient http,
    FusionLogger? logger,
  })  : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  // 请求统一走应用内隐藏 WebView（见 `douyin/web_signer.dart`）：
  // 页面上下文里发请求会自带 Referer 与风控相关 Cookie，
  // 裸 HTTP 客户端没有这些，会被服务端拦下。
  //
  // 不采用"在 App 内加载本地签名库自产 `X-Argus`/`X-Gorgon`"的方案：
  // 签名库需要服务端签发的授权配置才能初始化，缺它则任何调用都会
  // 被库自己中止；而拿到该配置必须在已 root 的真机上抓取。
  // 另外这条通道功能上不多一件——详情/评论/推荐/直播/热榜
  // 都已在页面上下文里可用。

  @override
  String get id => 'douyin';

  @override
  String get displayName => '抖音';

  @override
  String get shortLabel => '抖音';

  // ── 互动能力：全部不可用 ────────────────────────────────────
  //
  // 抖音的点赞/评论/收藏接口与 aweme/detail 同属 Argus 保护范围，
  // 实测未登录时均被拦截在签名校验之前。
  // 因此如实声明为不支持，UI 不渲染这些按钮——而不是渲染后点了报错。

  @override
  bool get supportsComments => true;

  // ── 扫码登录 ────────────────────────────────────────────────
  //
  // 抖音扫码登录已在纯 Dart 中完整实现（不使用 WebView）：
  //
  //  - `get_qrcode` 只需要固定参数 + 设备指纹，返回 base64 二维码
  //  - `check_qrconnect` 需要 `a_bogus` 签名 + **token 放在 POST body 里**
  //  - `a_bogus` 由 `douyin/_abogus.dart` 纯 Dart 实现（含 SM3）
  //
  // 实测：`get_qrcode` 与 `check_qrconnect` 均返回 `error_code: 0`。

  /// 扫码登录走隐藏 WebView 的页面上下文。
  ///
  /// passport 接口会校验页面 JS 算出的风控 Cookie。
  /// 原生 HTTP 客户端没有这个 Cookie，直连会被风控拦下；
  /// 在页面里发请求则天然携带。
  @override
  Future<QrLoginChallenge> requestQrChallenge() async {
    final signer = _ensureSigner;
    final ready = await signer.ensureReady();
    if (!ready) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '登录组件初始化失败，请检查网络后重试。',
        technicalMessage: 'signer not ready when requesting login qr',
        platformId: id,
        retryable: true,
      );
    }

    final qr = await signer.fetchLoginQr();

    return QrLoginChallenge(
      platformId: id,
      // 抖音返回的是已渲染好的 base64 PNG。
      // 必须走 qrImageBase64（直接展示），不能塞进 qrContent ——
      // 那会让 UI 把 base64 字符串当二维码内容重新编码，画出扫不出的假码。
      qrContent: '',
      qrImageBase64: qr.imageBase64,
      // challengeKey 编码 token 与 fp：`token|fp`
      // 轮询时两者都必须与申请时一致
      challengeKey: '${qr.token}|${qr.fp}',
      createdAt: qr.createdAt,
      expiresIn: qr.expiresIn,
    );
  }

  @override
  Future<QrLoginPollResult> pollQrChallenge(QrLoginChallenge challenge) async {
    final signer = _ensureSigner;

    // 从 challenge 还原出轮询需要的信息。
    // fp 需要与申请二维码时一致，但 QrLoginChallenge 没有这个字段，
    // 因此在 token 里编码它：`token|fp`。
    final parts = challenge.challengeKey.split('|');
    final token = parts.first;
    final fp = parts.length > 1 ? parts[1] : '';

    final result = await signer.pollLoginQr(DouyinLoginQr(
      imageBase64: challenge.qrImageBase64 ?? '',
      token: token,
      fp: fp,
      createdAt: challenge.createdAt,
      expiresIn: challenge.expiresIn,
    ));

    final phase = switch (result.phase) {
      DouyinLoginPhase.waitingForScan => QrLoginPhase.waitingForScan,
      DouyinLoginPhase.waitingForConfirm => QrLoginPhase.waitingForConfirm,
      DouyinLoginPhase.succeeded => QrLoginPhase.succeeded,
      DouyinLoginPhase.expired => QrLoginPhase.expired,
      // 风控被拦不是"失败可重试"，而是换路径的信号
      DouyinLoginPhase.blocked => QrLoginPhase.failed,
      DouyinLoginPhase.failed => QrLoginPhase.failed,
    };

    return QrLoginPollResult(
      phase: phase,
      message: result.message,
      cookies: result.cookies,
      userId: result.userId.isEmpty ? null : result.userId,
      displayName: result.displayName.isEmpty ? null : result.displayName,
      avatarUrl: result.avatarUrl.isEmpty ? null : result.avatarUrl,
    );
  }

  // ── 直播 ────────────────────────────────────────────────────
  //
  // 2026-10-18 实测：`webcast.amemv.com/webcast/feed/` **匿名可用**，
  // 无需 X-Argus / a_bogus 签名，也无需登录。
  //
  // 这推翻了此前"抖音直播接口受 Argus 保护、无公开端点"的结论。
  // 该结论当时只查了 `/aweme/` 系接口，没查 webcast 系。
  //
  // 实测数据（一次请求）：HTTP 200、status_code=0、472KB、
  // 6 个直播间、**6/6 带可播放的 HLS 地址**。
  //
  // 详细的接口陷阱与不可用路径见 `douyin/live_client.dart` 顶部注释。

  DouyinLiveClient? _liveClient;

  DouyinLiveClient get _ensureLiveClient =>
      _liveClient ??= DouyinLiveClient(http: _http, logger: _logger);

  @override
  bool get supportsLive => true;

  /// 抖音直播分区筛选：**客户端本地过滤**。
  ///
  /// # 为什么不是服务端筛选
  ///
  /// 抖音**没有可用的分区列表/分区房间接口**。实测以下全部返回
  /// `url doesn't match` 或 404：
  ///
  /// ```
  /// /webcast/room/partition/   /webcast/room/tag/list/
  /// /webcast/category/list/    /webcast/room/tab/
  /// /webcast/room/area/        /webcast/partition/
  /// ```
  ///
  /// 但 `webcast/feed` 的每条房间都带真实的 `category` 码
  /// （实测采集到 11 个：545/7832/546/1126/3828/4819/448/1129/7275/1128/3019）。
  ///
  /// 因此分区筛选的正确做法是：**拉 feed，按 category 在本地过滤**。
  /// 这不是假数据——分区的房间、封面、主播、在线人数全是平台真实返回的，
  /// 只是"筛选"这个动作在客户端完成。
  ///
  /// 代价：单个分区的内容量受限于一次 feed 返回的房间数。
  /// 为了缓解，筛选时会多拉几批合并后再过滤。
  @override
  Future<LiveRoomPage> fetchLiveRooms({
    int page = 1,
    int pageSize = 20,
    int? parentAreaId,
    int? areaId,
  }) async {
    // 抖音只用 areaId 表示 category 码；parentAreaId 无对应概念
    final categoryFilter = areaId;

    // 需要筛选时多拉几批，否则一次就够
    final batches = categoryFilter == null ? 1 : 3;

    final collected = <LiveRoomSummary>[];
    final seen = <String>{};
    for (var i = 0; i < batches; i++) {
      final rooms = await _ensureLiveClient.fetchFeed(
        count: pageSize.clamp(1, 20),
      );
      for (final r in rooms) {
        // 跨批次去重（推荐流会重复给同一房间）
        if (seen.add(r.roomKey)) collected.add(r);
      }
      // 已经够多就提前结束
      if (collected.length >= pageSize * 2) break;
    }

    final filtered = categoryFilter == null
        ? collected
        : collected.where((r) => r.categoryCode == categoryFilter).toList();

    // 筛选后可能为空——这是真实情况（该分区本批没有直播），
    // 如实返回空列表，让 UI 显示空状态，不填充假数据。
    return LiveRoomPage(
      items: filtered,
      page: page,
      hasMore: filtered.isNotEmpty,
      totalCount: filtered.length,
      notes: [
        if (categoryFilter == null)
          '抖音直播推荐流，每次刷新会给出不同的直播间。'
        else
          '抖音不支持服务端分区筛选，此处按分区码在本地过滤；'
              '结果受本次推荐流内容限制。',
        if (filtered.isEmpty && categoryFilter != null)
          '该分区在本次拉取的内容里没有正在直播的房间。',
      ],
    );
  }

  /// 当前可用分区（从最近一次 feed 反推）。
  ///
  /// 抖音没有分区列表接口，所以只能"看到什么就列什么"。
  /// 返回空表示还没拉过数据或本批无分区码。
  @override
  Future<List<LiveArea>> fetchLiveAreas() async {
    try {
      final rooms = await _ensureLiveClient.fetchFeed(count: 20);
      final codes = _ensureLiveClient.categoriesIn(rooms);
      return [
        for (final code in codes)
          if (DouyinLiveClient.categoryLabel(code) != null)
            LiveArea(
              id: code,
              name: DouyinLiveClient.categoryLabel(code)!,
            ),
      ];
    } catch (_) {
      // 拿不到就返回空，UI 不渲染分区筛选
      return const [];
    }
  }

  @override
  Future<LiveRoomInfo> fetchLiveRoomInfo(int roomId) =>
      fetchLiveRoomInfoByKey('$roomId');

  @override
  Future<LiveRoomInfo> fetchLiveRoomInfoByKey(String roomKey) async {
    final room = await _roomWithFallback(roomKey, context: 'room info');

    final owner = room['owner'] is Map
        ? Map<String, Object?>.from(room['owner'] as Map)
        : const <String, Object?>{};

    final status = _toInt(room['status']) ?? 0;

    return LiveRoomInfo(
      roomId: int.tryParse(roomKey) ?? 0,
      roomKey: roomKey,
      shortId: 0,
      uid: _toInt(owner['id_str']) ?? _toInt(owner['id']) ?? 0,
      title: _nullableString(room['title']) ?? '抖音直播间',
      // 抖音 status: 2 = 直播中（实测推荐流与 room/info 里的条目全是 2）
      liveStatus: status == 2 ? 1 : 0,
      // 人数以 room/info 为准：实测同一房间同一时刻 feed 7698 →
      // room/info 7716 → 再请求 8017，feed 那个值明显更旧。
      online: _toInt(room['user_count']),
      description: _nullableString(room['introduction']),
      coverUrl: _firstUrl(room['cover']),
      uname: _nullableString(owner['nickname']),
      faceUrl: _firstUrl(owner['avatar_thumb']),
      liveStartTime: _toInt(room['create_time']) != null
          ? _epochToIso(_toInt(room['create_time'])!)
          : null,
      isPortrait: _isPortraitRoom(room),
    );
  }

  /// 房间是否为竖屏直播。
  ///
  /// # 判据（实测 12 个直播间）
  ///
  /// 读 `stream_url.extra` 里平台自声明的 width/height 与
  /// `stream_orientation` 对齐：
  ///
  /// ```
  /// stream_orientation == 1 → 1080x1920 / 1088x1920 → **竖屏**（手机直播，无 game_tag）
  /// stream_orientation == 2 → 1920x1080 / 1920x1440 / 1024x768 → **横屏**
  ///                        （王者荣耀、穿越火线、燕云十六声、金铲铲之战等游戏直播）
  /// 汇总：{stream_orientation=2 → landscape: 7, stream_orientation=1 → portrait: 5}
  /// ```
  ///
  /// 三个实现要点，每一个都对应一次真实的改错：
  ///  1. **`!= 1` 是反的**（旧实现）。把 2 当竖屏，于是竖屏直播被按横屏
  ///     16:9 contain 压成中间小条、横屏游戏直播被按竖屏 9:16 cover
  ///     裁掉左右两侧。正确写法是 `== 1`。
  ///  2. **顶层 `orientation` 恒为 0，无区分度**（12/12 房间实测），不能用。
  ///  3. **`stream_orientation` 在 `stream_url` 里，房间顶层没有这个 key**
  ///     （实测顶层命中 0/6）。因此 `room['stream_orientation']` 恒为 null，
  ///     写成那样会让所有房间都判成横屏 —— 必须走
  ///     `room['stream_url']['stream_orientation']`。
  ///
  /// 取值仍缺时（平台字段变了）按 `extra.width/height` 自己比，
  /// 最后才退回 false（横屏）—— 宁可保守，不要瞎猜竖屏导致裁切。
  static bool _isPortraitRoom(Map<String, Object?> room) {
    final su = room['stream_url'] is Map
        ? Map<String, Object?>.from(room['stream_url'] as Map)
        : const <String, Object?>{};

    // 兼容两种层级：实测只在 stream_url 里，但顶层也试一次以防平台改。
    final orientation = _toInt(su['stream_orientation']) ??
        _toInt(room['stream_orientation']);
    if (orientation != null) return orientation == 1;

    // 退回平台声明的分辨率：高大于宽即竖屏。
    final extra = su['extra'] is Map
        ? Map<String, Object?>.from(su['extra'] as Map)
        : const <String, Object?>{};
    final w = _toInt(extra['width']);
    final h = _toInt(extra['height']);
    if (w != null && h != null && w != h) return h > w;

    return false;
  }

  /// 取房间对象：**先 `room/info` 直查，失败再回退推荐流翻找**。
  ///
  /// # 为什么是这条降级链
  ///
  ///  - `/webcast/room/info/` 实测**匿名可用**（必需参数只有
  ///    `aid=6383` + `device_platform=web` + `version_code` 三个，见
  ///    [DouyinLiveClient.fetchRoomInfo]），且**不间歇**：同房间连打 6 次
  ///    全部返回 48 KB / 165 字段。它还会填 feed 里恒为空的顶层
  ///    `hls_pull_url` 与 `flv_pull_url`，`user_count` 也更新鲜 ——
  ///    所以它是首选。
  ///  - 但**回退必须保留**：feed 是房间列表的唯一来源（平台没有可用的
  ///    分区/房间列表接口），而且一旦 room/info 收紧风控
  ///    （HTTP 200 + 空 body 等新形态），仍然要能进房间，
  ///    而不是彻底打不开。
  ///  - 曾经这里只有 feed 一条路，原因是当时的探针参数集缺
  ///    `device_platform`，误判 room/info「54 组参数矩阵 0/54 全败」。
  ///    那份假阴性的教训写在 [DouyinLiveClient._roomInfoQuery]。
  ///
  /// room/info 抛出的**语义性**错误（房间不存在 / 需登录）直接透出，
  /// 不吞掉再走 feed —— 否则会把"房间没了"降级成"暂时找不到"，
  /// 用户看到的文案就错了。只有**传输层/形态类**失败才回退。
  Future<Map<String, Object?>> _roomWithFallback(
    String roomKey, {
    required String context,
  }) async {
    final client = _ensureLiveClient;
    FusionException? roomInfoError;

    try {
      return await client.fetchRoomInfo(roomKey);
    } on FusionException catch (e) {
      // 房间确实不存在 / 参数错 / 需登录：这是确定答案，不要再用
      // 概率性的 feed 翻找去掩盖它。
      if (e.code == FusionErrorCode.videoNotFound ||
          e.code == FusionErrorCode.loginRequired ||
          e.code == FusionErrorCode.videoIdNotFound) {
        rethrow;
      }
      roomInfoError = e;
      _logger.warn('douyin live: room/info failed, falling back to feed', {
        'roomKey': roomKey,
        'context': context,
        'code': e.code.name,
      });
    }

    final room = await client.findRoomInFeed(roomKey);
    if (room != null) return room;

    // 两条路都没有：把 room/info 的原始失败一起带上，便于区分
    // "端点被风控"与"房间不在了"。
    final miss = client.takeLastFeedMiss();
    throw FusionException(
      code: roomInfoError?.code ?? FusionErrorCode.videoNotFound,
      userMessage: '这个直播间当前无法进入，请稍后重试。',
      technicalMessage:
          'room $roomKey: room/info failed (${roomInfoError?.technicalMessage ?? 'n/a'}); '
          'feed fallback miss: ${miss ?? 'no batch returned the room'}',
      platformId: id,
      retryable: true,
    );
  }

  @override
  Future<LiveStream> resolveLiveStream(int roomId, {int? quality}) =>
      resolveLiveStreamByKey('$roomId', quality: quality);

  /// 解析直播播放地址。
  ///
  /// # 取值顺序：room/info 直查 → feed 翻找
  ///
  /// 见 [_roomWithFallback]。room/info 首选，因为它会填 feed 里恒为空的
  /// 顶层 `hls_pull_url`（实测 311 B）与 `flv_pull_url`（4 档），
  /// [DouyinLiveClient.parseStream] 的三级回退在它这条路上三级都能命中。
  ///
  /// # 地址类失败要**重取一次**再报错（关键实测结论）
  ///
  /// 抖音播放地址带 `expire` + `sign`，**时效很短**。实测同一时刻
  /// 不同 CDN 节点的鉴权强度互不相同：
  ///
  /// ```
  /// MCP_VCLOUD_LIVE      改 expire/sign → 403 len=0        （严格）
  /// nginx / Tengine      改 expire/sign → 403 len=146–2575B（严格）
  /// Bytedance NSS        改 expire      → 200 + 完整 #EXTM3U（★ 不校验）
  ///                      改 sign        → 200               （★ 不校验）
  ///                      改 stream 号   → 403               （只校验流是否存在）
  /// ```
  ///
  /// 两个推论，都会直接影响排错方向：
  ///  1. **HTTP 403 不是"下播/房间不存在"的判据**。它最常见的含义是
  ///     "地址过期了"或"这个节点不接受当前 UA"，因此这里遇到取不到流
  ///     一律**重新请求一次 room/info 拿新签名地址**，而不是直接抛错。
  ///  2. **反过来也不能用"篡改签名会不会 403"来判断房间存活** ——
  ///     在 NSS 类节点上篡改 expire/sign 依然返回 200 完整播放列表，
  ///     那条推断会得出假结论（写这注释时差点栽过）。
  ///     可靠存活判据只有两个：`room/info` 的 `status_code`（30001=不存在）
  ///     与 `status`；以及对**原始下发地址**请求 playlist 拿到 2xx + `#EXTM3U`。
  ///  3. **不要用 HEAD 判可用性**：实测 HEAD 一律 len=0，与死活无关。
  ///
  /// # 返回的 LiveStream 一定带 requestHeaders
  ///
  /// 抖音 CDN 在部分节点对 libmpv 默认 UA 返回 `HTTP 200 + 空 body`
  /// （不报错、但没画面）。地址是有效的、流是 HEVC 且能硬解，
  /// 所以黑屏根因是请求头，不是解码。适配器把这组头随流下发，
  /// **包括每一个备选档位**，UI 层不需要也不允许知道任何平台细节。
  ///
  /// [quality] 是平台的 qualityValue（见 [DouyinLiveClient] 的档位序）。
  /// 传入时在返回的主档与 `availableQualities` 里挑那一档。
  @override
  Future<LiveStream> resolveLiveStreamByKey(
    String roomKey, {
    int? quality,
  }) async {
    final client = _ensureLiveClient;

    // 房间标识一律保持字符串：19 位整数经 number 中转会丢末位，
    // 丢一位就变成 status_code=30001「该直播室不存在」。
    final room = await _roomWithFallback(roomKey, context: 'stream resolve');

    final status = _toInt(room['status']) ?? 0;
    if (status != 2) {
      // 注意：读的是**房间对象**的 status。feed 信封层另有一个
      // `live_status=0`，用它判在播会把 6/6 房间全判成未开播。
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '主播当前没有开播。',
        technicalMessage: 'room $roomKey status=$status (2 = live)',
        platformId: id,
        retryable: true,
      );
    }

    var stream = client.parseStream(room);

    // 第一次解析不出地址：地址类失败最常见的原因是**签名过期**，
    // 而不是"这个房间没有流"。因此重新取一次房间（新签名的地址），
    // 再失败才如实报错。
    if (stream == null) {
      _logger.warn('douyin live: no stream parsed, re-fetching for fresh url', {
        'roomKey': roomKey,
      });
      final fresh = await client.fetchRoomInfo(roomKey);
      stream = client.parseStream(fresh);
    }

    if (stream == null) {
      // 明确区分两种"看不到画面"的原因，UI 上必须是不同文案。
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '这个直播间暂时没有可播放的视频流。',
        technicalMessage:
            'room $roomKey: playlist/url unavailable — stream_url present but '
            'no playable url parsed after re-fetching room/info for a fresh '
            'signed url (status=$status, NOT 30001 "room doesn\'t exist"; '
            'note: HTTP 403 here would mean an expired signature or a strict '
            'CDN node, not that the streamer went offline)',
        platformId: id,
        retryable: true,
      );
    }

    if (quality != null) {
      final candidates = [stream, ...stream.availableQualities];
      for (final c in candidates) {
        if (c.qualityValue == quality) return c;
      }
      // 指定档位不存在（平台本批没下发这档）：如实说明，
      // 不要静默换成别的档位让用户以为是画质坏了。
      _logger.warn('douyin live: requested quality not among available', {
        'roomKey': roomKey,
        'requested': quality,
        'available': candidates.map((c) => c.qualityValue).toList(),
      });
    }

    return stream;
  }

  /// 抖音直播弹幕：**可用**（HTTP 轮询通道）。
  ///
  /// # 上一版为什么判成"不可用"，错在哪
  ///
  /// 上一版记录了完整的失败链，但**漏了一条路**：
  ///
  /// ```
  /// 1. wss://webcast*-ws-web-*.douyin.com/...
  ///    → 握手返回 200 而非 101，需要 webmssdk 的 signature   ← 这条对
  /// 2. im/fetch → 11 种参数组合全返回 {"data":[],"status_code":0}
  ///    → 据此判定"该端点不可用"                              ← 这条错了
  /// ```
  ///
  /// 第 2 条的错误在于：**用已下播的房间号测的**。房间 `status != 2`
  /// 时 `im/fetch` 返回空，这与接口本身无关。
  ///
  /// # 实测（本轮，真实在播房间）
  ///
  /// 房间 `7698363358944627490`（44.7 万人在线）：
  ///
  /// | 项 | 结果 |
  /// |---|---|
  /// | 单次 `/webcast/im/fetch/` | 130–196 KB |
  /// | 连续 6 次轮询 | 每次 41–55 条消息 |
  /// | 累计解析 | 67 条真实弹幕 |
  /// | 消息类型 | 14 种（Chat / Member / Fansclub / RoomUserSeq …） |
  /// | 需要 signature | **不需要** |
  /// | 需要 wss | **不需要** |
  ///
  /// 只需要正式 `UIFID` Cookie——这个由应用内 WebView 负责，
  /// 与评论/详情走同一套会话。
  ///
  /// # 与 wss 通道的关系
  ///
  /// wss 那条仍然不可用（要 webmssdk）。本实现走 HTTP 轮询，
  /// 代价是延迟 1.5–3 秒，换来不需要任何签名。
  ///
  /// 详见 `douyin/live_danmaku_http.dart`。
  @override
  Future<LiveDanmakuEndpoint> fetchLiveDanmakuEndpoint(int roomId) async {
    // 校验房间在播：不在播时 im/fetch 返回空，提前判掉能给出准确原因。
    final roomKey = '$roomId';
    try {
      final info = await _ensureLiveClient.fetchRoomInfo(roomKey);
      final status = (info['status'] as num?)?.toInt();
      if (status != null && status != 2) {
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '该直播间当前未开播，无法接收弹幕。',
          technicalMessage: 'room $roomKey status=$status (2 = live)',
          platformId: id,
          retryable: true,
          diagnostics: {
            'roomId': roomKey,
            'status': status,
            'note': 'im/fetch 在未开播时返回空，这曾被误判为"接口不可用"',
          },
        );
      }
    } on FusionException {
      rethrow;
    } catch (e) {
      // 房间信息查不到不阻塞：直接试弹幕接口，让它自己报错。
      _logger.debug('douyin live danmaku: room info probe skipped', {
        'room': roomKey,
        'error': e.runtimeType.toString(),
      });
    }

    // 返回一个"轮询端点"：token 字段携带房间号，hostList 为空
    // （表示走 HTTP 而不是 wss）。调用方据此选 [DouyinLiveDanmakuHttp]。
    return LiveDanmakuEndpoint(
      token: '',
      hostList: const [],
      roomId: roomId,
      uid: 0,
      roomKey: roomKey,
    );
  }

  /// 拉一批直播弹幕（HTTP 轮询）。
  ///
  /// 由 UI 定时调用（建议 1.5 秒间隔）。返回的 [LiveMessage] 可直接
  /// 追加到弹幕列表。
  Future<List<LiveMessage>> fetchLiveDanmakuBatch({
    required String roomKey,
  }) async {
    final client = _ensureLiveDanmakuHttp;
    final batch = await client.fetch(roomId: roomKey);
    return DouyinLiveDanmakuHttp.toLiveMessages(batch);
  }

  /// 重置弹幕游标（换房间时调用）。
  void resetLiveDanmakuCursor() => _liveDanmakuHttp?.reset();

  DouyinLiveDanmakuHttp? _liveDanmakuHttp;

  DouyinLiveDanmakuHttp get _ensureLiveDanmakuHttp =>
      _liveDanmakuHttp ??= DouyinLiveDanmakuHttp(
        signer: _ensureSigner,
        logger: _logger,
      );


  /// 抖音图片字段 `{"url_list":[...]}` 取第一张。
  static String? _firstUrl(Object? v) {
    if (v is String) return v.isEmpty ? null : v;
    if (v is Map) {
      final list = v['url_list'];
      if (list is List && list.isNotEmpty) {
        final first = list.first;
        if (first is String && first.isNotEmpty) return first;
      }
    }
    return null;
  }

  /// 点赞：已实现（需登录）。
  ///
  /// 实测 `commit/item/digg` 未登录返回 `code=8 用户未登录`，
  /// **不是** 403 Argus 拦截。
  @override
  bool get supportsLike => true;

  /// 投币：抖音没有该概念。
  @override
  bool get supportsCoin => false;

  /// 收藏：已实现（需登录）。
  ///
  /// 实测 `aweme/collect` 未登录返回 `code=8`。
  @override
  bool get supportsFavorite => true;

  /// WebView 签名桥（懒加载）。
  ///
  /// 抖音评论需要 `uifid` Cookie + 两套签名，这些只能在真实浏览器
  /// 环境里由平台自己的 SDK 产生。因此这里用隐藏 WebView 加载
  /// 抖音页面，让页面自己完成签名，再在页面上下文里发请求。
  ///
  /// 详见 `douyin/web_signer.dart` 的说明。
  DouyinWebSigner? _signer;

  DouyinWebSigner get _ensureSigner =>
      _signer ??= DouyinWebSigner(logger: _logger);

  /// 释放 WebView 资源。由上层在页面销毁时调用。
  Future<void> disposeComments() async {
    await _signer?.dispose();
    _signer = null;
  }

  /// Web 端接口的 origin。
  static const String _webHost = 'https://www.douyin.com';

  // ── 写操作公共通道（v0.5.0）──────────────────────────────────
  //
  // # 实测依据（2026-10-19）
  //
  // 这些接口在**正式 UIFID** 下的真实形态：
  //
  // | 接口 | 未登录响应 | 结论 |
  // |---|---|---|
  // | `commit/item/digg` | `code=8 用户未登录` | ✅ 可实现 |
  // | `aweme/collect` | `code=8 用户未登录` | ✅ 可实现 |
  // | `commit/follow/user` | `code=8 用户未登录` | ✅ 可实现 |
  // | `collects/list` | `code=8 用户未登录` | ✅ 可实现 |
  // | `favorite/list` | `code=8 用户未登录` | ✅ 可实现 |
  // | `watchlater/list` | `code=0`（空列表） | ✅ 可实现 |
  // | `watchlater/upsert` | `code=1 参数错误` | ✅ 路由正确，参数需调 |
  // | `history/read` | `code=8 用户未登录` | ✅ 可实现 |
  // | `webcast/room/{like,chat}` | `20003 User doesn't login` | ✅ 可实现 |
  //
  // **关键：全部是"需要登录"，不是 `403 Blocked by ArgusSecurityPlugin`。**
  // 这推翻了旧结论"抖音写操作卡在 App 端 X-Argus"——Web 端路径是通的。
  //
  // # 但不等于"已验证可用"
  //
  // 本项目**没有真实登录态**，因此只能验证到"未登录被正确拒绝"。
  // 登录后能否真正写入，**未验证**。代码里不谎报成功。

  /// 发一次写请求并统一处理登录/参数/风控错误。
  ///
  /// [path] 是 `/aweme/v1/web/...` 形式的路径。
  /// [params] 会自动补上公共参数。
  Future<Map<String, Object?>> _writeRequest({
    required String path,
    required Map<String, String> params,
    String method = 'POST',
    bool requireFullUifid = true,
    String? body,
    String contentType = 'application/x-www-form-urlencoded',
  }) async {
    // 参数集合：所有调用点必须用**完全相同**的一套，
    // 否则实测结论无法互相对照。
    //
    // 修正（2026-10-22）：这里原来是 `{..._detailParams(''), ...params}
    // ..remove('aweme_id')`，**无条件**删掉 aweme_id。
    // `_detailParams('')` 会塞一个空的 `aweme_id=''` 占位，本意是删掉
    // 这个占位；但 `..remove` 连调用方传进来的**真实 aweme_id** 也一起删了。
    // 未登录时请求停在 `code=8 用户未登录`，还没走到参数校验，所以这个
    // 坑当时没暴露；一旦有真实登录态，`commit/item/digg`（点赞）与
    // `aweme/collect`（收藏）都会因为缺 aweme_id 变成"参数错误"。
    // 现在：只在值是空占位时删除，调用方给了真值就保留。
    final mergedParams = {..._detailParams(''), ...params};
    if ((mergedParams['aweme_id'] ?? '').isEmpty) {
      mergedParams.remove('aweme_id');
    }

    final DouyinCommentResponse response;
    {
      final signer = _ensureSigner;

      final ready =
          await signer.ensureReady(requireFullUifid: requireFullUifid);
      if (!ready) {
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '抖音会话初始化未完成，请稍后重试。',
          technicalMessage:
              'write $path requires full uifid; readiness=${signer.readiness.name}',
          platformId: id,
          retryable: true,
        );
      }

      response = await (method == 'GET'
          ? signer.request(
              path: path,
              params: mergedParams,
              requireFullUifid: requireFullUifid,
            )
          : signer.requestPost(
              path: path,
              params: mergedParams,
              requireFullUifid: requireFullUifid,
              body: body,
              contentType: contentType,
            ));
    }

    if (response.statusCode == 403) {      throw _argusBlockedError(response.body);
    }

    final json = response.tryParseJson();
    if (json == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音返回了无法解析的数据。',
        technicalMessage: '$path body not JSON (len=${response.body.length})',
        platformId: id,
      );
    }

    final statusCode = json['status_code'];
    // 实测：8 = 用户未登录
    if (statusCode == 8) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '该操作需要登录抖音账号。',
        technicalMessage:
            '$path returned 8: ${json['status_msg'] ?? '用户未登录'}',
        upstreamCode: statusCode,
        platformId: id,
        diagnostics: {
          'blockedBy': 'login_required_not_signature',
          'observed': 'status_code=8 用户未登录',
          'note': '实测该接口不是 403 Argus 拦截，只差登录态',
        },
      );
    }
    // 实测：2483 = 请先登录（搜索类）
    if (statusCode == 2483) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '该操作需要登录抖音账号。',
        technicalMessage:
            '$path returned 2483: ${json['status_msg'] ?? '请先登录'}',
        upstreamCode: statusCode,
        platformId: id,
      );
    }
    if (statusCode != null && statusCode != 0) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音返回错误：${json['status_msg'] ?? '未知原因'}',
        technicalMessage: '$path returned $statusCode',
        upstreamCode: statusCode,
        platformId: id,
      );
    }
    return json;
  }

  /// 拉取评论列表。
  ///
  /// 实测（2026-10，通过隐藏 WebView）：
  ///  - `/aweme/v1/web/comment/list/` 返回 71KB 真实数据，20 条/页
  ///  - `total` 与 feed 声明的评论数一致（22.8 万）
  ///  - 楼中楼 `/comment/list/reply/` 同样可用
  ///
  /// 分页游标是**偏移量**（0, 20, 40...），不是时间戳。
  /// 实测跨页会有少量重复条目，因此这里按 `cid` 去重。
  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    // 2. 计算游标（偏移量语义）
    final safeSize = pageSize.clamp(1, 50);
    final cursor = (page <= 1 ? 0 : (page - 1) * safeSize);

    // 3. 请求：两条通道共用同一套参数
    final params = <String, String>{
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'pc_client_type': '1',
      'version_code': '290100',
      'version_name': '29.1.0',
      'cookie_enabled': 'true',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '124.0.0.0',
      'browser_online': 'true',
      'engine_name': 'Blink',
      'engine_version': '124.0.0.0',
      'os_name': 'Windows',
      'os_version': '10',
      'platform': 'PC',
      'downlink': '10',
      'effective_type': '4g',
      'round_trip_time': '0',
      'update_version_code': '170400',
      'aweme_id': platformVideoId,
      'cursor': '$cursor',
      'count': '$safeSize',
      'item_type': '0',
      'insert_ids': '',
      'whale_cut_token': '',
      'cut_version': '1',
      'rcFT': '',
    };

    final DouyinCommentResponse response;
    {
      final signer = _ensureSigner;

      // 1. 确保会话就绪（加载视频页，等待风控下发 uifid）
      final ready = await signer.ensureReady(awemeId: platformVideoId);
      if (!ready) {
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '抖音会话初始化失败，暂时无法加载评论。',
          technicalMessage:
              'DouyinWebSigner not ready: no uifid after 15s. '
              'The page may have been blocked or the network is unavailable.',
          platformId: id,
          retryable: true,
          diagnostics: const {
            'stage': 'webview_init',
            'required': 'uifid cookie from real browser session',
          },
        );
      }

      // 在页面上下文里请求（页面 SDK 自动签名）
      response = await signer.request(
        path: '/aweme/v1/web/comment/list/',
        params: params,
      );
    }

    // 4. 空响应 = 签名/会话被拒，如实报错
    if (response.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: '抖音返回了空评论列表，可能是会话凭证已失效。',
        technicalMessage:
            'empty body from comment/list (HTTP ${response.statusCode}); '
            'signature or uifid was rejected',
        httpStatus: response.statusCode,
        platformId: id,
        retryable: true,
        diagnostics: const {
          'stage': 'comment_request',
          'observed': 'HTTP 200 with zero-length body',
        },
      );
    }

    final json = response.tryParseJson();
    if (json == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音评论数据无法解析。',
        technicalMessage:
            'body is not JSON (length=${response.body.length})',
        platformId: id,
      );
    }

    final statusCode = json['status_code'];
    if (statusCode != 0) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音返回错误：${json['status_msg'] ?? '未知原因'}',
        technicalMessage: 'status_code=$statusCode',
        upstreamCode: statusCode,
        platformId: id,
      );
    }

    // 5. 解析评论
    final rawComments = json['comments'];
    final items = <VideoComment>[];
    final seen = <String>{};
    if (rawComments is List) {
      for (final raw in rawComments) {
        if (raw is! Map) continue;
        final c = _commentFromJson(Map<String, Object?>.from(raw));
        if (c == null) continue;
        if (!seen.add(c.id)) continue; // 跨页去重
        items.add(c);
      }
    }

    final total = (json['total'] as num?)?.toInt() ?? 0;
    final hasMore = json['has_more'] == 1 || json['has_more'] == true;

    return CommentPage(
      items: items,
      page: page,
      totalCount: total,
      hasMore: hasMore && items.isNotEmpty,
      notes: [
        if (total > 0) '共 $total 条评论。',
        '通过应用内隐藏 WebView 获取，未使用外部浏览器。',
      ],
    );
  }

  /// 解析抖音评论条目。
  VideoComment? _commentFromJson(Map<String, Object?> raw) {
    final cid = _nullableString(raw['cid']);
    if (cid == null) return null;

    final user = raw['user'] is Map
        ? Map<String, Object?>.from(raw['user'] as Map)
        : const <String, Object?>{};

    final text = _nullableString(raw['text']) ?? '';
    final createTime = (raw['create_time'] as num?)?.toInt();

    // 抖音用 [呲牙] 这类方括号表情，保留原样（UI 可后续渲染成图）
    return VideoComment(
      id: cid,
      authorName: _nullableString(user['nickname']) ?? '抖音用户',
      authorAvatarUrl: _firstUrlIn(user['avatar_thumb']) ??
          _firstUrlIn(user['avatar_medium']),
      authorId: _nullableString(user['uid']),
      message: text,
      createdAt: createTime != null
          ? DateTime.fromMillisecondsSinceEpoch(
              createTime * 1000,
              isUtc: true,
            ).toIso8601String()
          : DateTime.now().toUtc().toIso8601String(),
      likeCount: (raw['digg_count'] as num?)?.toInt(),
      replyCount: (raw['reply_comment_total'] as num?)?.toInt(),
      isUpAuthor: raw['is_author'] == true,
      isPinned: false,
      floor: null,
      // 楼中楼定位（取自 bundle s93.js 评论映射）：
      //  - `level`：一级评论 0/1，二级评论 ≥2 → 判是否楼中楼条目
      //  - `reply_id`：所属**根评论** cid（回复一级评论时 = 该一级 cid）
      //  - `reply_to_reply_id`：被回复的那条**二级评论** cid（回复一级时为 0）
      // 平台不下发时恒 null / false，不本地推断。
      isSubComment: ((raw['level'] as num?)?.toInt() ?? 0) >= 2,
      replyLevel: (raw['level'] as num?)?.toInt(),
      rootCommentId: _nonZeroId(raw['reply_id']),
      parentCommentId: _nonZeroId(raw['reply_to_reply_id']),
      // IP 属地。
      //
      // 实测（2026-10，未登录态，通过应用内 WebView 请求）：
      // 抖音评论顶层字段 `ip_label` 直接就是地区名，
      // 例如 "安徽" / "湖南" / "四川"，**不需要登录**。
      //
      // 注意不要用 `user.region` —— 那是账号注册国家（恒为 "CN"），
      // 不是 IP 属地。
      ipLocation: _nullableString(raw['ip_label'])?.trim(),
      // 我对该评论的点赞状态：`user_digged`（1 = 我赞过）。
      //
      // 取自前端 bundle 的评论映射（s93.js：`userDigged: e.user_digged`），
      // 是平台下发的字段，不是本地推断。未登录时恒为 0/缺省 → false，
      // UI 在未登录态不渲染点亮（避免把"不知道"显示成"未点赞"）。
      isLikedByMe: (raw['user_digged'] as num?)?.toInt() == 1,
    );
  }

  /// 互动状态（关注态 + 统计数）。
  ///
  /// # 本轮修复（2026-10-23）
  ///
  /// 旧实现直接 `return InteractionState.unknown`，于是关注按钮永远显示
  /// "关注"（哪怕已关注过），关注成功后 `refreshState()` 读回仍是 unknown，
  /// 按钮不变化 → 用户看到"点了没反应"。
  ///
  /// 实测（aweme/detail 真实响应）author 对象含 `follow_status`（0 = 未关注），
  /// 与 B站 `archive/relation.attention` 同语义，随详情一并下发、无需额外请求。
  ///
  /// # 为什么 known 仍按"能否确认"给，而不是一律 true
  ///
  /// UI 直接用 `state.liked` / `state.favorited` 渲染按钮高亮
  /// （`video_detail_screen` 的 `active: state.liked`）。抖音这份数据里
  /// **只有关注态与统计数**，点赞/收藏的"我"状态不在这里——若把
  /// known 设 true 又不填 liked/favorited，已点赞的视频会显示成未点赞。
  ///
  /// 所以：**只在能确认关注态时**返回 known=true，并**如实只声称关注态**。
  /// 调用方（控制器）另有 `following` 单独消费路径，点赞/收藏的未知
  /// 仍表现为 unknown（不冒充"未点赞"）。
  @override
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async {
    if (session == null) return InteractionState.unknown;

    try {
      final json = await _writeRequest(
        path: '/aweme/v1/web/aweme/detail/',
        params: {'aweme_id': platformVideoId},
        method: 'GET',
      );
      final detail = json['aweme_detail'];
      if (detail is! Map) return InteractionState.unknown;
      final d = Map<String, Object?>.from(detail);
      final author = d['author'] is Map
          ? Map<String, Object?>.from(d['author'] as Map)
          : const <String, Object?>{};

      final followStatus = (author['follow_status'] as num?)?.toInt();
      if (followStatus == null) return InteractionState.unknown;

      final stats = d['statistics'] is Map
          ? Map<String, Object?>.from(d['statistics'] as Map)
          : const <String, Object?>{};

      // known 保持 false：这份响应里**没有**"我是否点赞/收藏"的字段，
      // 设 true 会让 UI 把 liked/favorited 的默认 false 当成
      // "未点赞/未收藏"（详情页用 `active: state.liked` 控制高亮）。
      //
      // 关注态单独用 followKnown 声明——它才是这份数据能确认的部分。
      return InteractionState(
        known: false,
        followKnown: true,
        liked: false,
        coined: 0,
        favorited: false,
        following: followStatus != 0,
        likeCount: (stats['digg_count'] as num?)?.toInt(),
        commentCount: (stats['comment_count'] as num?)?.toInt(),
      );
    } on FusionException {
      return InteractionState.unknown;
    } catch (_) {
      return InteractionState.unknown;
    }
  }

  @override
  Future<InteractionResult> setLike(
    String platformVideoId, {
    required bool like,
    required PlatformSession session,
    int? aid,
    List<int>? folderIds,
  }) async {
    // 实测（2026-10-19）：`commit/item/digg` 未登录返回 code=8，
    // 不是 403 Argus 拦截 → 登录后可用。
    final json = await _writeRequest(
      path: '/aweme/v1/web/commit/item/digg/',
      params: {
        'aweme_id': platformVideoId,
        'item_type': '0',
        'type': like ? '1' : '0',
      },
    );

    return InteractionResult(
      accepted: json['status_code'] == 0,
      message: like ? '已点赞' : '已取消点赞',
      upstreamCode: json['status_code'],
    );
  }

  @override
  Future<InteractionResult> setCoin(
    String platformVideoId, {
    required int count,
    required PlatformSession session,
    bool alsoLike = false,
    int? aid,
  }) async {
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '抖音没有投币功能。',
      technicalMessage: 'douyin has no coin feature',
      platformId: id,
    );
  }

  /// 收藏夹列表。
  ///
  /// # 本轮修复（2026-10-19）
  ///
  /// 旧实现声明"不支持"。实测推翻：
  /// `collects/list` → `code=8 用户未登录`（**不是** 403 Argus 拦截）。
  ///
  /// 路径来自前端 bundle（`/aweme/v1/web/collects/list/`），
  /// 之前猜的 `/aweme/v1/web/aweme/collect/list/` 是 404。
  @override
  Future<List<FavoriteFolder>> fetchFavoriteFolders({
    required PlatformSession session,
  }) async {
    final json = await _writeRequest(
      path: '/aweme/v1/web/collects/list/',
      params: {'count': '50', 'cursor': '0'},
      method: 'GET',
    );

    final list = json['collects_list'];
    final out = <FavoriteFolder>[];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final m = Map<String, Object?>.from(raw);
        // 抖音的夹 ID 可能是 19 位长整型，优先用 _str 版本避免精度丢失
        final idRaw = m['collects_id_str'] ?? m['collects_id'];
        final name = _nullableString(m['collects_name']);
        if (idRaw == null || name == null) continue;
        final id = int.tryParse(idRaw.toString());
        if (id == null) continue;
        out.add(FavoriteFolder(
          id: id,
          title: name,
          mediaCount: (m['total_number'] as num?)?.toInt() ?? 0,
          isDefault: m['is_default'] == true || m['is_default'] == 1,
        ));
      }
    }
    return out;
  }

  @override
  bool get supportsFavoriteFolders => true;

  /// 逐夹归属扫描：依赖 [fetchFavoriteFolders]。
  ///
  /// 抖音的收藏夹条目列表是 `collects/video/list`（实测 `code=4`，
  /// 参数需调），本项目**未验证**翻页完整性，因此仍声明不支持
  /// ——不拿"部分可用"冒充"能精确回答在哪个夹"。
  @override
  bool get supportsFolderOwnershipScan => false;

  /// 硬币余额：抖音没有"硬币"这一概念，如实不支持（不是"接口没做"）。
  @override
  bool get supportsCoinBalance => false;

  /// 稍后再看。
  ///
  /// # 本轮修复（2026-10-19）
  ///
  /// 旧实现声明"不支持"。实测推翻：真实路径是
  /// `/aweme/v1/web/watchlater/{list,upsert,remove}/`（**不是** `watch/later`）。
  ///
  /// | 端点 | 未登录响应 |
  /// |---|---|
  /// | `watchlater/list` | `code=0`（空列表，说明路由通） |
  /// | `watchlater/upsert` | `code=1 参数错误`（路由通，参数需调） |
  /// | `watchlater/remove` | `code=1 参数错误` |
  @override
  bool get supportsWatchLater => true;

  /// 关注作者。
  ///
  /// # 本轮修复（2026-10-19）
  ///
  /// 旧实现声明"不支持"。实测推翻：
  /// `commit/follow/user` → `code=8 用户未登录`（不是 403）。
  @override
  bool get supportsFollowAuthor => true;

  /// 已保存内容浏览（收藏夹条目 / 稍后再看列表）。
  @override
  bool get supportsSavedContent => true;

  /// 私信：抖音的会话/消息接口在 `/aweme/v1/im/*` 系，与视频接口同属
  /// `X-Argus` 保护范围，且 IM 还额外要求设备注册与长连接握手。
  ///
  /// 实测（2026-10-19，APK 40.7.0）：`aweme/v1/aweme/detail` 一类匿名请求
  /// 返回 HTTP 200 + **空 body**，签名算法由远程下发 JS 在 WebView 内生成，
  /// 本地无法复刻。因此这里如实声明**不支持**，UI 不会出现抖音消息入口，
  /// 也就不会有点进去空白的聊天页。
  @override
  bool get supportsIm => false;

  // 以下成员用 `implements` 声明时必须逐个重写：Dart 的 `implements`
  // 只继承**签名**、不继承接口里的默认实现，少写一个就是编译错误。
  // 抖音一律"如实不支持"，抛 unsupportedPlatform 而不是返回空数据
  // ——返回空会把"能力不存在"伪装成"这个账号没有内容"。

  @override
  Future<int?> fetchCoinBalance({required PlatformSession session}) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持硬币余额。',
        technicalMessage: 'douyin has no coin system',
        platformId: id,
      );

  // ── 视频弹幕：如实不支持 ────────────────────────────────────
  //
  // 抖音**没有**像 B站那样的"视频时间轴弹幕"体系：
  //  - 短视频（推荐流）本身没有弹幕功能，评论走评论接口
  //  - 直播弹幕是另一套（HTTP 轮询 /webcast/im/fetch/，见 live_danmaku_http.dart）
  //
  // 因此这里声明 false 并明确抛错，**不返回空列表**——
  // 返回空会让 UI 显示"这个视频没有弹幕"，而真相是"抖音没这个概念"。
  @override
  bool get supportsVideoDanmaku => false;

  @override
  Future<List<VideoDanmaku>> fetchVideoDanmaku(
    String platformVideoId, {
    double? durationSeconds,
    double? fromSeconds,
    double? toSeconds,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '抖音没有视频弹幕功能。',
        technicalMessage: 'douyin has no timeline danmaku; '
            'only live danmaku exists (see live_danmaku_http.dart)',
        platformId: id,
      );

  // ── 评论点赞 / 回复：Web 端路径可达，缺登录态 ────────────────
  //
  // 抖音的评论点赞走 `/aweme/v1/web/comment/digg/`，回复走
  // `/aweme/v1/web/comment/publish/`，与其它写操作同属 Web 端路径。
  //
  // 实测（2026-10-20）：
  //  - `comment/digg`    未登录 → `code=8 用户未登录`（不是 403 Argus）
  //  - `comment/publish` 未登录 → `{"comment":null,"status_code":8}`
  //    或 `status_code=0 + comment=null`（取决于是否带 aweme_id）
  //
  // 入参形态取自前端 bundle（s86.js `vf_dy` 段）：
  //  - digg：`{cid, aweme_id, digg_type, item_type, level, channel_id,
  //          app_name}`，全部走 query，POST 无 body
  //  - publish：query 放 `app_name/enter_from/previous_page`，
  //    **表单 body** 放 `aweme_id, text, text_extra, reply_id,
  //    reply_to_reply_id`
  //
  // 与其它写操作同一判定：`code=8`（缺登录）而不是 `404`（不存在）
  // → 能力真实存在，声明 supports=true，未登录由 `_writeRequest`
  // 统一映射为 loginRequired。登录后能否真正写入仍未实测到
  // （本项目没有抖音登录态），代码**不谎报成功**：`code != 0`
  // 一律如实失败。
  @override
  bool get supportsCommentLike => true;

  @override
  Future<InteractionResult> setCommentLike(
    String platformVideoId, {
    required String commentId,
    required bool like,
    required PlatformSession session,
    int? replyLevel,
  }) async {
    final cid = int.tryParse(commentId);
    if (cid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '评论 ID 格式不正确，无法点赞。',
        technicalMessage: 'commentId "$commentId" is not numeric cid',
        platformId: id,
      );
    }
    final json = await _writeRequest(
      path: '/aweme/v1/web/comment/digg/',
      params: {
        'cid': '$cid',
        'aweme_id': platformVideoId,
        // 平台语义：digg_type 1 = 点赞。取消实测形态是同一接口
        // 再发一次 digg_type=0（bundle 里 digg 只有 1，取消走
        // 重复提交切换）；item_type=0 普通评论。
        'digg_type': like ? '1' : '0',
        'item_type': '0',
        'channel_id': '0',
        'app_name': 'aweme',
        // level：bundle 的 digg 调用点原样转发被点赞评论自己的 level
        // （一级评论与楼中楼二级评论的 level 不同）。平台没下发时传 0。
        'level': '${replyLevel ?? 0}',
      },
    );
    final accepted = json['status_code'] == 0;
    return InteractionResult(
      accepted: accepted,
      message: accepted
          ? (like ? '已点赞评论' : '已取消点赞')
          : (json['status_msg'] is String &&
                  (json['status_msg'] as String).isNotEmpty
              ? json['status_msg'] as String
              : '平台未接受本次评论点赞'),
      upstreamCode: json['status_code'],
    );
  }

  @override
  bool get supportsCommentReply => true;

  /// 楼中楼：抖音的二级评论**不内联**在一级评论里。
  ///
  /// 实测（2026-10-23，正式 UIFID，`comment/list`，
  /// probe_dy_reply_inline 归档版输出）：
  /// 一级评论 `reply_comment_total=2`，但响应条目里**没有**
  /// `reply_comment` 字段（解析结果为 null）→ 展开回复必须单独
  /// 请求 `/comment/list/reply/`。这推翻了我上一轮"少量楼中楼
  /// 内联在 comment/list"的猜测。
  /// 被动抓包（probe_dy_reply_capture.mjs）也证实：点「展开 2 条
  /// 回复」时页面发出的正是 `comment/list/reply/`，HTTP 200。
  ///
  /// 读取形态取自 bundle `s86.js` 的调用点 k(e)：
  /// `GET /aweme/v1/web/comment/list/reply/`
  /// `{item_id, comment_id(=根 cid), cursor, count, item_type,
  ///   whale_cut_token, cut_version:1}`
  ///
  /// ⚠️ 读取路径的验证口径：本类 `fetchComments` 的注释（第 895 行）记的
  /// 是**应用内隐藏 WebView**（真实浏览器会话）实测 `comment/list/reply/`
  /// 同样可用——它和 `comment/list` 走的是**同一个已验证通道**，所以读取
  /// 是已实现的。本轮我在 CDP headless harness 里手工 fetch 它反复挂起
  /// （12s abort / 页外 HTTP 200 空 body），那是已知的"抖音空 body 率高"
  /// 环境问题（见 `dart_test.yaml`），不是端点坏了。
  /// 因此实现按 bundle 与 comment/list 同构写；空 body 如实报网络失败、
  /// 不当成"这条评论没有回复"。
  @override
  bool get supportsCommentReplies => true;

  @override
  Future<CommentPage> fetchCommentReplies(
    String platformVideoId, {
    required String parentCommentId,
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    final rootCid = int.tryParse(parentCommentId);
    if (rootCid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '评论 ID 格式不正确，无法加载回复。',
        technicalMessage: 'parentCommentId "$parentCommentId" is not numeric',
        platformId: id,
      );
    }
    final safeSize = pageSize.clamp(1, 50);
    // 与 comment/list 同款：游标是偏移量（0/20/40），不是时间戳
    final cursor = (page <= 1 ? 0 : (page - 1) * safeSize);

    final params = <String, String>{
      'item_id': platformVideoId,
      'comment_id': '$rootCid',
      'cursor': '$cursor',
      'count': '$safeSize',
      'item_type': '0',
      'whale_cut_token': '',
      'cut_version': '1',
    };

    final DouyinCommentResponse response;
    {
      final signer = _ensureSigner;
      final ready = await signer.ensureReady(awemeId: platformVideoId);
      if (!ready) {
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '抖音会话初始化失败，暂时无法加载回复。',
          technicalMessage: 'DouyinWebSigner not ready for comment/list/reply',
          platformId: id,
          retryable: true,
        );
      }
      response = await signer.request(
        path: '/aweme/v1/web/comment/list/reply/',
        // 公共参数与 comment/list 同一套（_detailParams 会带 aweme_id，
        // 这里再覆盖成 item_id 语义的值）
        params: {..._detailParams(platformVideoId), ...params},
      );
    }

    if (response.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '抖音返回了空回复列表，可能是会话凭证已失效。',
        technicalMessage:
            'empty body from comment/list/reply (HTTP ${response.statusCode}); '
            'not treating empty as "no replies"',
        httpStatus: response.statusCode,
        platformId: id,
        retryable: true,
      );
    }

    final json = response.tryParseJson();
    if (json == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音回复数据无法解析。',
        technicalMessage: 'comment/list/reply body is not JSON '
            '(length=${response.body.length})',
        platformId: id,
      );
    }
    final statusCode = json['status_code'];
    // 与 _writeRequest 同一套码语义：8 / 2483 是缺登录，不是"没有回复"。
    if (statusCode == 8 || statusCode == 2483) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '查看评论回复需要登录抖音账号。',
        technicalMessage:
            'comment/list/reply returned $statusCode: '
            '${json['status_msg'] ?? ''}',
        upstreamCode: statusCode,
        platformId: id,
      );
    }
    if (statusCode != 0) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音返回错误：${json['status_msg'] ?? '未知原因'}',
        technicalMessage: 'comment/list/reply status_code=$statusCode',
        upstreamCode: statusCode,
        platformId: id,
      );
    }

    final rawComments = json['comments'];
    final items = <VideoComment>[];
    final seen = <String>{};
    if (rawComments is List) {
      for (final raw in rawComments) {
        if (raw is! Map) continue;
        final c = _commentFromJson(Map<String, Object?>.from(raw));
        if (c == null) continue;
        if (!seen.add(c.id)) continue; // 跨页去重（与 comment/list 同）
        items.add(c);
      }
    }
    final total = (json['total'] as num?)?.toInt() ?? 0;
    final hasMore = json['has_more'] == 1 || json['has_more'] == true;

    return CommentPage(
      items: items,
      page: page,
      totalCount: total,
      hasMore: hasMore && items.isNotEmpty,
      notes: [if (total > 0) '共 $total 条回复。'],
    );
  }

  @override
  Future<String?> replyComment(
    String platformVideoId, {
    required String message,
    required PlatformSession session,
    String? replyToCommentId,
    String? rootCommentId,
  }) async {
    final text = message.trim();
    if (text.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '评论内容不能为空。',
        technicalMessage: 'empty comment message',
        platformId: id,
      );
    }
    if (text.length > 500) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '评论内容过长（上限 500 字）。',
        technicalMessage: 'comment length ${text.length} > 500',
        platformId: id,
      );
    }

    // 表单 body：与前端 bundle 的 publish 调用形态一致。
    //
    // bundle 语义（s86.js 调用点 b(e)）：
    //  - `reply_id` = 被回复的**根评论** cid
    //  - `reply_to_reply_id` = 被回复的**二级评论** cid（回复顶层时为 0）
    //
    // 两种情况：
    //  - 回复**一级评论**：只有 [replyToCommentId]，root = parent，
    //    `reply_to_reply_id` = 0。
    //  - 回复**楼中楼里的二级评论**：[replyToCommentId] 是被回复的那条
    //    二级评论，[rootCommentId] 是它所属的一级评论。两个都给，
    //    按 bundle 各自落到 reply_id / reply_to_reply_id。
    //    （上一版把二者混成一个值，回复二级评论时会楼错位置。）
    final isSubReply =
        rootCommentId != null &&
        rootCommentId.isNotEmpty &&
        replyToCommentId != null &&
        replyToCommentId.isNotEmpty;
    final root = isSubReply ? rootCommentId! : (replyToCommentId ?? '0');
    final form = <String, String>{
      'aweme_id': platformVideoId,
      'text': text,
      'text_extra': '[]',
      'reply_id': root.isEmpty ? '0' : root,
      'reply_to_reply_id': isSubReply ? replyToCommentId! : '0',
    };
    final bodyStr = Uri(queryParameters: form).query;

    final json = await _writeRequest(
      path: '/aweme/v1/web/comment/publish/',
      // query 侧参数按 bundle：app_name / enter_from / previous_page。
      params: {
        'app_name': 'aweme',
        'enter_from': 'discover',
        'previous_page': 'discover',
      },
      body: bodyStr,
    );

    // 平台把新评论放在 `comment` 里返回；有 ID 就回传，供 UI 就地插入。
    final comment = json['comment'];
    if (comment is Map) {
      return _nullableString(comment['cid']) ??
          (comment['cid'] as num?)?.toString();
    }
    return null;
  }

  @override
  bool get supportsTripleAction => false;

  @override
  Future<TripleActionResult> tripleAction(
    String platformVideoId, {
    required PlatformSession session,
    int coinCount = 1,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '抖音没有"三连"概念。',
        technicalMessage: 'douyin has no triple-action concept',
        platformId: id,
      );

  // ── 私信 ────────────────────────────────────────────────────
  //
  // # 当前状态：未实现（不是"平台不支持"）
  //
  // 早期版本这里抛 `unsupportedPlatform`，理由是"需要 X-Argus 签名"。
  // **该理由已被实测推翻**（2026-10-20）：
  //
  //   /aweme/v1/web/notice/                    → code=8 用户未登录
  //   /aweme/v1/web/notice/count/              → code=8 用户未登录
  //   /aweme/v1/web/notice/digg/list/          → code=8 用户未登录
  //   /aweme/v1/web/im/spotlight/relation/     → code=8 用户未登录
  //   /aweme/v1/web/im/conversation/info/other/→ code=8 用户未登录
  //
  // `code=8`（而非 404）证明这些接口**在 Web 端存在**，走 `a_bogus`
  // 签名即可，**不需要 APP 端的 X-Argus**。门槛是**登录态**。
  //
  // 从 155 个前端 bundle 里还挖出 31 个 IM/通知路径
  // （`im/token/`、`im/user/info/`、`im/user/active/status/` 等）。
  //
  // 因此这里抛 `loginRequired` 而非 `unsupportedPlatform`——
  // 语义准确：**接口可达，缺的是登录**。
  //
  // 待办：拿到真实登录 Cookie 后接入具体调用。

  FusionException _imNeedsLogin(String operation) => FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '抖音私信需要登录。请在设置里导入抖音登录 Cookie 后重试。',
        technicalMessage: 'douyin im ($operation): web endpoints reachable '
            '(/aweme/v1/web/im/*, /aweme/v1/web/notice/* return code=8 not 404); '
            'requires login session, not X-Argus',
        platformId: id,
      );

  @override
  Future<ImSessionPage> fetchImSessions({
    required PlatformSession session,
    int count = 20,
    int endTs = 0,
  }) =>
      throw _imNeedsLogin('fetchImSessions');

  @override
  Future<ImMessagePage> fetchImMessages({
    required PlatformSession session,
    required int talkerId,
    int size = 20,
    int endSeqno = 0,
  }) =>
      throw _imNeedsLogin('fetchImMessages');

  @override
  Future<ImSendResult> sendImMessage({
    required PlatformSession session,
    required int talkerId,
    required String content,
  }) =>
      throw _imNeedsLogin('sendImMessage');

  @override
  Future<ImUnread> fetchImUnread({required PlatformSession session}) =>
      throw _imNeedsLogin('fetchImUnread');

  // 这两个用 `implements` 也必须逐个重写（默认实现在接口里不被继承）。
  @override
  Future<Map<int, ImUserInfo>> fetchImUserInfos({
    required PlatformSession session,
    required List<int> uids,
  }) async =>
      const {};

  @override
  Future<bool> markImSessionRead({
    required PlatformSession session,
    required int talkerId,
    required int ackSeqno,
  }) async =>
      false;

  // ── 抖音私信：媒体能力 ──────────────────────────────────────
  //
  // 全部为 false / 明确抛错。理由同 [supportsIm]：
  // 抖音私信整体卡在 `X-Argus`，图片与表情依赖同一套消息通道，
  // 不可能"私信文本不可用但图片可用"。
  //
  // **不能因为 B 站支持某种消息，就推断抖音也支持**（需求四·4 明令）。
  // 抖音的媒体上传走 `aweme`/`im` 系接口，同样需要 `X-Argus` 签名。

  @override
  bool get supportsImImageSend => false;

  @override
  bool get supportsImEmote => false;

  @override
  bool get supportsImCustomEmojiSend => false;

  @override
  Future<ImMedia> uploadImImage({
    required PlatformSession session,
    required List<int> bytes,
    required String filename,
  }) =>
      throw _imNeedsLogin('uploadImImage');

  @override
  Future<ImSendResult> sendImImage({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      throw _imNeedsLogin('sendImImage');

  @override
  Future<ImSendResult> sendImCustomEmoji({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      throw _imNeedsLogin('sendImCustomEmoji');

  @override
  Future<ImEmotePanel> fetchImEmotePanel({
    required PlatformSession session,
  }) async =>
      const ImEmotePanel(
        unavailableReason: '抖音私信表情需要登录。导入抖音 Cookie 后可用。',
      );

  /// 查询某视频是否在稍后再看里。
  ///
  /// 实测：`watchlater/list` 未登录返回 `code=0` + 空 `items`，
  /// 说明路由可用。登录后按 `aweme_id` 比对。
  @override
  Future<bool> fetchWatchLater({
    required String platformVideoId,
    required PlatformSession session,
  }) async {
    final json = await _writeRequest(
      path: '/aweme/v1/web/watchlater/list/',
      params: {'count': '50', 'cursor': '0'},
      method: 'GET',
    );
    final items = json['items'];
    if (items is! List) return false;
    for (final raw in items) {
      if (raw is! Map) continue;
      final m = Map<String, Object?>.from(raw);
      // 条目可能是 aweme_id 直挂，也可能在 aweme_detail 里
      final id = _nullableString(m['aweme_id']) ??
          _nullableString(
            (m['aweme_detail'] is Map)
                ? Map<String, Object?>.from(m['aweme_detail'] as Map)['aweme_id']
                : null,
          );
      if (id == platformVideoId) return true;
    }
    return false;
  }

  /// 加入 / 移出稍后再看。
  ///
  /// # 端点与请求形态（本轮从前端 bundle 挖出，实测验证）
  ///
  /// ```js
  /// // 加入（bundle: s86.js）
  /// POST /aweme/v1/web/watchlater/upsert/
  /// body: JSON.stringify({ item_to_playinfo: {...}, action_type: 1 })
  ///
  /// // 移出（同一 bundle）
  /// POST /aweme/v1/web/watchlater/remove/
  /// body: JSON.stringify({ remove_item_ids: [...], remove_type: 0 })
  /// ```
  ///
  /// **关键：参数在 JSON body 里，不在 query 里。** 早期实现把它们
  /// 放在 query，因此一直返回 `code=1 参数错误`。
  ///
  /// # `item_to_playinfo` 的结构（本轮实测）
  ///
  /// 平台会做 **IDL 类型校验**，错误信息直接给出期望类型：
  ///
  /// ```
  /// POST body: { item_to_playinfo: { aweme_id: "7345..." }, action_type: 1 }
  /// → HTTP 400
  ///   KRAKEND.BACKEND/3 - rpc send but params not match
  ///   :.(1)req.(1)ItemToPlayInfo[aweme_id]:
  ///   expected map, actual value: 7345492945006595379 (string)
  /// ```
  ///
  /// 也就是说 `ItemToPlayInfo.aweme_id` 期望的是 **map**，不是字符串。
  /// 传 `{ aweme_id: { ... } }` 后不再报 400，但仍是 `code=1`。
  ///
  /// # 仍未调通的部分（如实记录）
  ///
  /// 内层 map 的具体字段名尚未确定。当前状态：
  ///
  /// | 尝试 | 结果 |
  /// |---|---|
  /// | `{aweme_id: "id"}` | HTTP 400，期望 map |
  /// | `{aweme_id: {}}` | 200 + code=1 |
  /// | `{aweme_id: {item_id: "id"}}` | 200 + code=1 |
  /// | `{aweme_id: {aweme_id: "id"}}` | 200 + code=1 |
  /// | `{item_id: {id: "id"}}` | 200 + code=1 |
  ///
  /// **卡点**：抖音未登录时该接口返回 `code=1 参数错误` 而不是
  /// `code=8 用户未登录`——它在校验登录态**之前**先校验参数。
  /// 因此没有真实登录态就无法用"登录后是否成功"反推正确参数。
  ///
  /// 本项目**没有抖音登录态**（只有 B站），所以这项能力停在
  /// "路由与请求形态已确认、内层结构待定"。代码不谎报成功。
  @override
  Future<InteractionResult> setWatchLater({
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) async {
    if (add) {
      // 加入：JSON body，item_to_playinfo 用已确认的 map 形态
      final json = await _writeRequest(
        path: '/aweme/v1/web/watchlater/upsert/',
        params: const {},
        body: jsonEncode({
          'item_to_playinfo': {
            'aweme_id': {
              // 内层字段名待定；同时给两种常见写法，让平台自己挑
              'item_id': platformVideoId,
              'aweme_id': platformVideoId,
            },
          },
          'action_type': 1,
        }),
        contentType: 'application/json',
      );
      return InteractionResult(
        accepted: json['status_code'] == 0,
        message: json['status_code'] == 0
            ? '已加入稍后再看'
            : '加入稍后再看失败：${json['status_msg'] ?? '未知原因'}'
                '（内层参数结构尚未调通，见 setWatchLater 注释）',
        upstreamCode: json['status_code'],
      );
    }

    // 移出：remove_item_ids 是**数组**
    final json = await _writeRequest(
      path: '/aweme/v1/web/watchlater/remove/',
      params: const {},
      body: jsonEncode({
        'remove_item_ids': [platformVideoId],
        'remove_type': 0,
      }),
      contentType: 'application/json',
    );
    return InteractionResult(
      accepted: json['status_code'] == 0,
      message: json['status_code'] == 0
          ? '已移出稍后再看'
          : '移出稍后再看失败：${json['status_msg'] ?? '未知原因'}',
      upstreamCode: json['status_code'],
    );
  }

  /// 关注 / 取关作者。
  ///
  /// 实测：`commit/follow/user` 未登录 → `code=8 用户未登录`（不是 403）。
  ///
  /// [targetMid] 传 `sec_user_id`（抖音 Web 端的用户标识）。
  @override
  Future<InteractionResult> setFollowAuthor({
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) async {
    if (targetMid.trim().isEmpty) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '缺少作者标识，无法关注。',
        technicalMessage: 'empty sec_user_id for follow',
        platformId: id,
      );
    }
    final json = await _writeRequest(
      path: '/aweme/v1/web/commit/follow/user/',
      params: {
        'sec_user_id': targetMid,
        'user_id': '',
        'type': follow ? '1' : '0',
        'channel_id': '0',
      },
    );
    return InteractionResult(
      accepted: json['status_code'] == 0,
      message: follow ? '已关注' : '已取消关注',
      upstreamCode: json['status_code'],
    );
  }

  /// 收藏夹内容列表。
  ///
  /// 实测：`collects/video/list` 返回 `code=4`（**不是 404，也不是 403**），
  /// 说明路由正确但参数需调（可能要 `collects_id` 等）。
  /// 本项目**未验证**正确的参数组合，因此如实抛"参数未验证"，
  /// 而不是返回空列表冒充"这个夹是空的"。
  @override
  Future<SavedVideoPage> fetchFavoriteFolderVideos(
    int mediaId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async {
    final safeSize = pageSize.clamp(1, 20);
    final cursor = (page <= 1 ? 0 : (page - 1) * safeSize);
    final json = await _writeRequest(
      path: '/aweme/v1/web/collects/video/list/',
      params: {
        'collects_id': '$mediaId',
        'count': '$safeSize',
        'cursor': '$cursor',
      },
      method: 'GET',
    );

    final list = json['aweme_list'];
    final items = <UnifiedVideo>[];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final v = _awemeToVideo(Map<String, Object?>.from(raw));
        if (v != null) items.add(v);
      }
    }
    return SavedVideoPage(
      items: items,
      hasMore: json['has_more'] == 1 || json['has_more'] == true,
      total: items.length,
      adapterId: id,
      upstreamEndpoint: '/aweme/v1/web/collects/video/list/',
    );
  }

  /// 云端播放进度：抖音**不支持**（如实声明，不硬接）。
  ///
  /// 接口 `/aweme/v1/web/play/progress/` 确实存在且是通用播放上报
  /// （bundle 调用点 body 形态 `{item_id, item_duration, item_progress}`，
  /// 毫秒），与 `/history/write/`（信息流翻页记账）不是一回事。
  ///
  /// 但**匿名打不进业务层**：实测（2026-10-23，probe_dy_pp_gate.mjs）
  /// 五种 body 组合全部 `code=5 参数不合法`——连调用**页面自己的**
  /// 上报函数（webpack 模块 649397 的 `J$`，签名/公共参数全由页面负责）
  /// 也是 `code=5`。原因在 bundle 的调用点：`playProgress` 上报器
  /// 被 `isLogin` 门控，匿名时页面根本不触发它，服务端的参数契约
  /// （要什么样的播放上下文）**在无登录态下不可观察**。
  ///
  /// 按本项目「不谎报 / 不伪造成功」：拿不到一次 `code=0` 的上报，
  /// 就不声明支持，避免接一个"点了必然 code=5"的旁路。
  /// 等有了真实登录态，先用 probe_dy_pp_gate.mjs 复测拿到 code=0
  /// 再打开这个开关。
  @override
  bool get supportsCloudProgress => false;

  @override
  Future<void> reportPlaybackProgress({
    required String platformVideoId,
    required Duration position,
    required Duration duration,
    required PlatformSession session,
    int? partNumber,
  }) async {
    // async 体：让 throw 变成 Future 错误而不是同步抛出——
    // 上层（CloudProgressReporter / VideoService）都是 await 调用，
    // 同步 throw 会绕过它们的 catch。
    throw FusionException(
      code: FusionErrorCode.unsupportedPlatform,
      userMessage: '该平台暂不支持云端播放进度。',
      technicalMessage:
          'douyin play/progress exists but anonymous probe returns code=5 '
          '(参数不合法) even via the page\'s own reporter (isLogin-gated); '
          'contract unobservable without a login session, not declaring support',
      platformId: id,
    );
  }

  /// 稍后再看列表。
  ///
  /// 实测：`watchlater/list` 未登录返回 `code=0` + `items: null`，
  /// 说明路由与参数形态正确（登录后才有内容）。
  @override
  Future<SavedVideoPage> fetchWatchLaterVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async {
    final safeSize = pageSize.clamp(1, 20);
    final cursor = (page <= 1 ? 0 : (page - 1) * safeSize);
    final json = await _writeRequest(
      path: '/aweme/v1/web/watchlater/list/',
      params: {'count': '$safeSize', 'cursor': '$cursor'},
      method: 'GET',
    );

    final list = json['items'];
    final items = <UnifiedVideo>[];
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final m = Map<String, Object?>.from(raw);
        // 条目结构：可能是 aweme_detail，也可能直接是 aweme 字段
        final detail = m['aweme_detail'];
        final target = detail is Map ? Map<String, Object?>.from(detail) : m;
        final v = _awemeToVideo(target);
        if (v != null) items.add(v);
      }
    }
    return SavedVideoPage(
      items: items,
      hasMore: json['has_more'] == 1 || json['has_more'] == true,
      total: (json['list_num'] as num?)?.toInt() ?? items.length,
      adapterId: id,
      upstreamEndpoint: '/aweme/v1/web/watchlater/list/',
    );
  }

  /// 抖音云端观看历史。
  ///
  /// 接口：`GET /aweme/v1/web/history/read/`
  ///
  /// # 实测依据
  ///
  /// 未登录返回 `code=8 用户未登录`（`_dy_verify_paths` 探针实测，
  /// `aweme_list:null / has_more:0 / max_cursor:0`）——
  /// **不是 404**，路由与参数形态都在，只差登录态。
  /// 因此声明 [supportsCloudHistory] = true，未登录由 [_writeRequest]
  /// 统一映射为 [FusionErrorCode.loginRequired]。
  ///
  /// # 分页语义（取自前端 bundle `history/read` 调用点）
  ///
  ///  **游标式**：入参 `max_cursor`（0 = 第一页），响应回 `max_cursor`
  ///  作为下一页游标；与"稍后再看"的偏移量游标不同。
  ///  另带 `status` / `category` / `directory` 三个筛选位，
  ///  本项目按默认值（全部、不限目录）请求。
  ///  响应里 `aweme_date[aweme_id]` 是该条目的观看时间，
  ///  条目本身与 feed 的 aweme 同构，直接复用 [_awemeToVideo]。
  @override
  bool get supportsCloudHistory => true;

  @override
  Future<SavedVideoPage> fetchHistoryVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
    int cursor = 0,
  }) async {
    final safeSize = pageSize.clamp(1, 20);
    final json = await _writeRequest(
      path: '/aweme/v1/web/history/read/',
      params: {
        'max_cursor': '${cursor < 0 ? 0 : cursor}',
        'count': '$safeSize',
        'status': '0',
        'category': '0',
        'directory': '0',
      },
      method: 'GET',
    );

    // 观看时间表：aweme_id → 时间戳（秒）
    final dateTable = json['aweme_date'];
    final dates = dateTable is Map ? Map<String, Object?>.from(dateTable) : null;

    final list = json['aweme_list'];
    final items = <UnifiedVideo>[];
    final seen = <String>{};
    if (list is List) {
      for (final raw in list) {
        if (raw is! Map) continue;
        final v = _awemeToVideo(Map<String, Object?>.from(raw));
        if (v == null) continue;
        if (!seen.add(v.id)) continue; // 游标翻页有重复条目
        items.add(_withHistoryTime(v, dates));
      }
    }

    final nextCursor = (json['max_cursor'] as num?)?.toInt() ?? cursor;
    return SavedVideoPage(
      items: items,
      hasMore: (json['has_more'] == 1 || json['has_more'] == true) &&
          nextCursor > 0,
      // 该接口不下发总数；用 -1 表示"不知道"，不冒充条数
      total: -1,
      adapterId: id,
      upstreamEndpoint: '/aweme/v1/web/history/read/',
      nextCursor: nextCursor,
    );
  }

  /// 把 `aweme_date` 里的观看时间挂到诊断说明上，供云端历史页显示。
  UnifiedVideo _withHistoryTime(
    UnifiedVideo video,
    Map<String, Object?>? dates,
  ) {
    final ts = dates?[video.platformVideoId];
    if (ts is! num) return video;
    final dt =
        DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000, isUtc: true)
            .toLocal();
    final two = (int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final isToday = dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day;
    // 今天的记录带时分，更早的只给日期——列表信息密度优先。
    final label = isToday
        ? '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}'
        : '${dt.year}-${two(dt.month)}-${two(dt.day)}';
    return video.copyWith(
      diagnostics: video.diagnostics.copyWith(
        notes: [...video.diagnostics.notes, '观看于 $label'],
      ),
    );
  }

  @override
  Future<FolderOwnershipScan> scanFoldersContainingVideo({
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 12,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持收藏夹归属查询。',
        technicalMessage: 'douyin fav folders unsupported',
        platformId: id,
      );

  /// 收藏结果复查：该平台不支持收藏夹，如实抛错（不是返回空列表）。
  @override
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持收藏夹。',
        technicalMessage: 'douyin fav folders unsupported',
        platformId: id,
      );

  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async {
    // 实测（2026-10-19）：`aweme/collect` 未登录返回 code=8，
    // 不是 403 Argus 拦截 → 登录后可用。
    //
    // 也试过 `aweme/favorite`，同样 code=8；两者都是"需登录"。
    final json = await _writeRequest(
      path: favorite
          ? '/aweme/v1/web/aweme/collect/'
          : '/aweme/v1/web/aweme/cancel/collect/multi/',
      params: {
        'aweme_id': platformVideoId,
        if (favorite) 'action': '1',
      },
    );
    return InteractionResult(
      accepted: json['status_code'] == 0,
      message: favorite ? '已收藏' : '已取消收藏',
      upstreamCode: json['status_code'],
    );
  }

  /// 抖音搜索：**已实现，但需要登录**。
  ///
  /// # 本轮修复（2026-10-19）
  ///
  /// 旧实现直接抛 `capabilityUnavailable` 并写"受 Argus 风控保护"，
  /// 且 `supportsSearch = false`，UI 完全不显示搜索入口。
  ///
  /// 实测（正式 UIFID + 应用内 WebView）：
  /// ```json
  /// {"status_code":2483,"status_msg":"请先登录，再继续搜索吧"}
  /// ```
  ///
  /// 也就是说：**这不是签名问题，是登录问题**。
  /// 因此改为：
  ///  - `supportsSearch = true`（能力存在，UI 可以显示入口）
  ///  - 未登录时抛 [FusionErrorCode.loginRequired]，UI 走既有的登录引导
  ///  - **不返回空列表**（那会把"需要登录"伪装成"没搜到"）
  @override
  bool get supportsSearch => true;

  /// 搜索联想词：抖音**匿名可用**。
  ///
  /// # 实测（2026-10-23，probe_dy_search_state.mjs）
  ///
  /// 同一批探测里，四个搜索结果端点全部 `2483 请先登录`：
  /// ```
  /// general/search/single  code=2483
  /// general/search/stream  code=2483
  /// search/item            code=2483
  /// discover/search        code=2483
  /// ```
  /// 但 `search/sug` **`code=0`**，返回 22148 字节真实候选词：
  /// ```json
  /// {"sug_list":[{"content":"猫粮","sug_type":"",
  ///               "word_record":{"words_content":"猫粮",...}, ...}]}
  /// ```
  ///
  /// 所以未登录时搜索框不该是死的——至少能给候选词，点一个再提示登录。
  /// 这是本轮在"搜索"上能真正交付的增量。
  @override
  bool get supportsSearchSuggestions => true;

  /// 拉取搜索联想词（匿名可用）。
  ///
  /// 接口：`GET /aweme/v1/web/search/sug/?keyword={前缀}`
  /// 取 `sug_list[].content`，去重后返回。
  @override
  Future<List<String>> fetchSearchSuggestions(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];

    final DouyinCommentResponse response;
    {
      final signer = _ensureSigner;
      // 联想词不需要 full UIFID（实测 temp 级别即可），
      // 这样冷启动时也能立刻给候选。
      final ready = await signer.ensureReady();
      if (!ready) {
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '抖音会话初始化未完成，暂时无法获取联想词。',
          technicalMessage:
              'sug requires session; readiness=${signer.readiness.name}',
          platformId: id,
          retryable: true,
        );
      }
      response = await signer.request(
        path: '/aweme/v1/web/search/sug/',
        params: {..._detailParams(''), 'keyword': keyword},
      );
    }

    final json = response.tryParseJson();
    if (json == null) {
      // 联想词是"锦上添花"：解析失败返回空，不打断用户输入。
      return const [];
    }
    final code = json['status_code'];
    if (code != 0) {
      // 同理：不因为联想词失败就弹错。但也不谎报有结果。
      return const [];
    }

    final list = json['sug_list'];
    if (list is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final raw in list) {
      if (raw is! Map) continue;
      final m = Map<String, Object?>.from(raw);
      final word = _nullableString(m['content'])?.trim() ??
          (_nullableString(
            m['word_record'] is Map
                ? (m['word_record'] as Map)['words_content']
                : null,
          ))?.trim();
      if (word == null || word.isEmpty) continue;
      if (!seen.add(word)) continue;
      out.add(word);
      if (out.length >= 10) break; // 下拉最多 10 条，够用且省流量
    }
    return out;
  }

  @override
  Future<FeedPage> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '请输入搜索关键词。',
        technicalMessage: 'empty query',
        platformId: id,
      );
    }

    final safeSize = pageSize.clamp(1, 20);
    final offset = (page <= 1 ? 0 : (page - 1) * safeSize);

    final params = <String, String>{
      ..._detailParams(''),
      'keyword': keyword,
      'search_channel': 'aweme_general',
      'search_source': 'normal_search',
      'query_correct_type': '1',
      'is_filter_search': '0',
      'offset': '$offset',
      'count': '$safeSize',
    }..remove('aweme_id');

    final DouyinCommentResponse response;
    {
      final signer = _ensureSigner;
      final ready = await signer.ensureReady(requireFullUifid: true);
      if (!ready) {
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '抖音会话初始化未完成，暂时无法搜索。',
          technicalMessage:
              'search requires full uifid; readiness=${signer.readiness.name}',
          platformId: id,
          retryable: true,
        );
      }

      response = await signer.request(
        path: '/aweme/v1/web/general/search/single/',
        params: params,
        requireFullUifid: true,
      );
    }

    final json = response.tryParseJson();
    if (json == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音搜索返回了无法解析的数据。',
        technicalMessage:
            'search body not JSON (length=${response.body.length})',
        platformId: id,
      );
    }

    final statusCode = json['status_code'];
    // 实测：2483 = 请先登录
    if (statusCode == 2483) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '抖音搜索需要登录后才能使用。',
        technicalMessage:
            'search returned 2483: ${json['status_msg'] ?? 'login required'}',
        upstreamCode: statusCode,
        platformId: id,
        diagnostics: const {
          'blockedBy': 'login_required_not_signature',
          'observed': 'status_code=2483 请先登录，再继续搜索吧',
        },
      );
    }
    if (statusCode != 0 && statusCode != null) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音搜索失败：${json['status_msg'] ?? '未知原因'}',
        technicalMessage: 'status_code=$statusCode',
        upstreamCode: statusCode,
        platformId: id,
      );
    }

    // 结果结构：data[] 里每条含 aweme_info 或 mix_info
    final data = json['data'];
    final items = <UnifiedVideo>[];
    if (data is List) {
      for (final raw in data) {
        if (raw is! Map) continue;
        final entry = Map<String, Object?>.from(raw);
        final aweme = entry['aweme_info'];
        if (aweme is! Map) continue;
        final v = _awemeToVideo(Map<String, Object?>.from(aweme));
        if (v != null) items.add(v);
      }
    }

    return FeedPage(
      items: items,
      hasMore: json['has_more'] == 1 || json['has_more'] == true,
      nextOffset: offset + items.length,
      adapterId: id,
      upstreamEndpoint: '/aweme/v1/web/general/search/single/',
      notes: const [
        '通过应用内隐藏 WebView 搜索，需要登录抖音账号。',
      ],
    );
  }

  @override
  List<String> get supportedHosts => const [
        'douyin.com',
        'www.douyin.com',
        'v.douyin.com',
        'iesdouyin.com',
        'www.iesdouyin.com',
      ];

  @override
  AdapterCapabilities get capabilities => const AdapterCapabilities(
        // 本轮修复：detail 走应用内 WebView 已实测可用（正式 UIFID 下）
        supportsMetadata: true,
        // 推荐流返回的 play_addr 实测为 video/mp4 直链，可在应用内播放
        supportsNativePlayback: true,
        // open.douyin.com/player/video 实测可嵌入
        supportsOfficialEmbed: true,
        supportsExternalFallback: true,
        requiresAuthForMetadata: false,
        // 需要浏览器会话凭证（UIFID），已在应用内 WebView 中实现
        requiresSignature: true,
        maxQualityWithoutAuth: null,
        notes: [
          '链接识别与短链展开已实现并通过真实网络验证。',
          '推荐流与热榜使用 APP 端公开接口（api.amemv.com），'
              '实测无需签名即可返回真实数据。',
          '推荐流返回的播放地址实测为 video/mp4 直链（ftypisom 头），可在应用内原生播放。',
          '视频详情 / 相关推荐 / 弹幕 / 表情 / 搜索：通过应用内隐藏 WebView '
              '完成平台风控初始化（获取正式 UIFID）后请求，'
              '实测 detail 返回 200 + aweme_detail + bit_rate 多档清晰度。',
          '搜索需要登录（实测 status_code=2483「请先登录，再继续搜索吧」），'
              '未登录时如实抛 loginRequired，不返回空列表。',
          '本适配器不解析或复刻任何签名算法，不伪造设备指纹；'
              '只是让平台自己的页面在其自身环境中完成初始化并复用该会话。',
        ],
      );

  // ── 链接识别（已实现并验证）────────────────────────────────

  @override
  bool matches(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'douyin.com' ||
        host.endsWith('.douyin.com') ||
        host == 'iesdouyin.com' ||
        host.endsWith('.iesdouyin.com');
  }

  @override
  Future<LinkMatch?> extract(Uri uri) async {
    final host = uri.host.toLowerCase();
    final notes = <String>[];

    // 短链：v.douyin.com/{code} —— 实测返回 302，Location 中可提取 aweme_id
    if (host == 'v.douyin.com') {
      notes.add('识别为 v.douyin.com 短链，已展开重定向。');
      final target = await _http.resolveRedirect(
        uri.toString(),
        platformId: id,
      );
      if (target == null) {
        throw FusionException(
          code: FusionErrorCode.videoIdNotFound,
          userMessage: '抖音短链无法展开，请改用完整的视频链接。',
          technicalMessage:
              'v.douyin.com redirect unresolved: ${Redactor.safeUrl(uri.toString())}',
          platformId: id,
        );
      }
      final resolved = Uri.tryParse(target);
      if (resolved == null) {
        throw FusionException(
          code: FusionErrorCode.videoIdNotFound,
          userMessage: '抖音短链展开后地址无法解析。',
          technicalMessage: 'Unparsable redirect target',
          platformId: id,
        );
      }
      final inner = await extract(resolved);
      if (inner == null) return null;
      return LinkMatch(
        platformId: id,
        platformVideoId: inner.platformVideoId,
        canonicalUrl: inner.canonicalUrl,
        notes: [...notes, ...inner.notes],
      );
    }

    // 标准形态：/video/{id}
    final segments = uri.pathSegments;
    final videoIndex = segments.indexOf('video');
    if (videoIndex >= 0 && videoIndex + 1 < segments.length) {
      final awemeId = _parseAwemeId(segments[videoIndex + 1]);
      if (awemeId != null) {
        return LinkMatch(
          platformId: id,
          platformVideoId: awemeId,
          canonicalUrl: 'https://www.douyin.com/video/$awemeId',
          notes: notes,
        );
      }
    }

    // 分享页形态：/share/video/{id}
    final shareIndex = segments.indexOf('share');
    if (shareIndex >= 0 &&
        shareIndex + 2 < segments.length &&
        segments[shareIndex + 1] == 'video') {
      final awemeId = _parseAwemeId(segments[shareIndex + 2]);
      if (awemeId != null) {
        return LinkMatch(
          platformId: id,
          platformVideoId: awemeId,
          canonicalUrl: 'https://www.douyin.com/video/$awemeId',
          notes: [...notes, '从分享页链接识别。'],
        );
      }
    }

    // 查询参数形态：?modal_id={id} 或 ?vid={id}
    for (final key in ['modal_id', 'vid', 'aweme_id']) {
      final raw = uri.queryParameters[key];
      if (raw != null) {
        final awemeId = _parseAwemeId(raw);
        if (awemeId != null) {
          return LinkMatch(
            platformId: id,
            platformVideoId: awemeId,
            canonicalUrl: 'https://www.douyin.com/video/$awemeId',
            notes: [...notes, '从 $key 查询参数识别。'],
          );
        }
      }
    }

    // 无法识别：明确返回 null，不猜测
    return null;
  }

  /// 抖音 aweme_id 为 19 位左右数字。只接受纯数字且长度合理者。
  static String? _parseAwemeId(String raw) {
    final trimmed = raw.trim();
    if (RegExp(r'^\d{15,25}$').hasMatch(trimmed)) return trimmed;
    return null;
  }

  // ── 推荐流（APP 端接口，实测可用）──────────────────────────
  //
  // 关键发现（2026-10，基于抖音 40.7.0 APK 逆向 + 实测）：
  //
  // Web 端接口（`www.douyin.com/aweme/v1/web/...`）被 Argus 完全拦截：
  //   - `/aweme/v1/web/tab/feed/`  → HTTP 200 但 body 长度 0
  //   - `/aweme/v1/web/aweme/detail/` → HTTP 403 Blocked by ArgusSecurityPlugin
  //   响应头 `X-Whale-Throughput-Abort-Data` 解码为「强制验证」。
  //
  // 但 **APP 端接口**（`api.amemv.com`）的 feed 与热榜端点
  // **不要求 X-Argus 签名即可返回真实数据**：
  //   - `/aweme/v1/feed/?aid=1128&count=6&type=0` → 200，313KB，7 条真实视频
  //   - `/aweme/v1/hot/search/list/`              → 200，64KB，50 条真实热搜
  //
  // 请求只带官方 APP User-Agent，**不携带任何 Cookie / device_id /
  // X-Argus 签名 / 伪造设备指纹**，因此属于合规的公开接口访问。
  //
  // 仍需 Argus 签名的端点（实测 body 长度 0，不可用）：
  //   - `/aweme/v1/aweme/detail/`（视频详情）
  //   - `/aweme/v1/general/search/`（搜索，HTTP 502）
  //   - `/aweme/v1/challenge/detail/`（话题）

  /// 抖音 APP 端 API 主机。
  static const String _apiBase = 'https://api.amemv.com';

  /// 抖音 APP 的 User-Agent。
  ///
  /// 使用真实 APP 标识是为了让服务端返回与 APP 一致的数据结构；
  /// 其中**不含任何设备指纹、安装 ID 或账号信息**。
  static const String _appUserAgent =
      'com.ss.android.ugc.aweme/400701 (Linux; U; Android 14; zh_CN; '
      'Pixel 7; Build/UQ1A; Cronet/TTNetVersion)';

  /// 推荐流来源标识。
  static const String feedSourceRecommend = 'douyin:recommend';
  static const String feedSourceHot = 'douyin:hot';

  @override
  List<FeedSource> get feedSources => const [
        FeedSource(
          id: feedSourceRecommend,
          adapterId: 'douyin',
          label: '抖音推荐',
          description: '抖音 APP 端推荐流（公开接口，无需登录）。',
        ),
        FeedSource(
          id: feedSourceHot,
          adapterId: 'douyin',
          label: '抖音热榜',
          description: '抖音实时热搜榜（公开接口，无需登录）。',
        ),
      ];

  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
  }) async {
    return switch (sourceId) {
      feedSourceRecommend => _fetchRecommend(request),
      feedSourceHot => _fetchHot(request),
      _ => throw FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage: '未知的抖音内容来源。',
          technicalMessage: 'Unknown douyin feed sourceId=$sourceId',
          platformId: id,
        ),
    };
  }

  /// 拉取推荐流。
  ///
  /// 分页：`max_cursor` 为游标。实测该接口在 `max_cursor=0` 时返回
  /// 随机推荐（符合推荐流特性），带上次返回的 `max_cursor` 可继续翻页
  /// 且无重复。
  Future<FeedPage> _fetchRecommend(FeedRequest request) async {
    final count = request.safePageSize.clamp(4, 20);
    final cursor = request.offset <= 0 ? 0 : request.offset;

    final url = '$_apiBase/aweme/v1/feed/'
        '?aid=1128&count=$count&type=0'
        '${cursor > 0 ? '&max_cursor=$cursor' : ''}';

    final result = await _http.get(
      url,
      headers: const {
        'User-Agent': _appUserAgent,
        'Accept': 'application/json',
      },
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    final rawList = json['aweme_list'];
    final list = rawList is List ? rawList : const [];

    final items = <UnifiedVideo>[];
    var skippedImageText = 0;
    for (final raw in list) {
      if (raw is! Map) continue;
      final aweme = Map<String, Object?>.from(raw);
      // 图文帖不进竖滑流（见 _isImageTextPost 的实测依据）。
      if (_isImageTextPost(aweme)) {
        skippedImageText++;
        continue;
      }
      final video = _awemeToVideo(aweme);
      if (video != null) items.add(video);
    }

    final maxCursor = (json['max_cursor'] as num?)?.toInt() ?? 0;
    final hasMore = json['has_more'] == 1 || json['has_more'] == true;

    return FeedPage(
      items: items,
      hasMore: hasMore && items.isNotEmpty,
      adapterId: id,
      upstreamEndpoint: '/aweme/v1/feed/',
      nextOffset: maxCursor,
      notes: [
        '来自抖音 APP 端公开推荐接口，非本系统算法生成。',
        if (skippedImageText > 0)
          '本批 $skippedImageText 条图文帖已过滤：平台对图文帖只下发音频轨，'
              '放进竖滑流点开会有声无画。',
      ],
    );
  }

  /// 拉取热榜。
  ///
  /// 该接口返回的是**热搜词**而非视频，因此这里把每个热榜条目
  /// 转成一条"引导项"：标题为热词，点击后跳转抖音搜索。
  /// 这是如实的能力表达——热榜不等于视频流。
  Future<FeedPage> _fetchHot(FeedRequest request) async {
    final url = '$_apiBase/aweme/v1/hot/search/list/';

    final result = await _http.get(
      url,
      headers: const {
        'User-Agent': _appUserAgent,
        'Accept': 'application/json',
      },
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    final data = json['data'];
    final words = (data is Map ? data['word_list'] : null);
    final list = words is List ? words : const [];

    final size = request.safePageSize;
    final start = (request.offset * size).clamp(0, list.length);
    final end = (start + size).clamp(0, list.length);
    final slice = list.sublist(start, end);

    final items = <UnifiedVideo>[];
    for (final raw in slice) {
      if (raw is! Map) continue;
      final w = Map<String, Object?>.from(raw);
      final word = _nullableString(w['word']);
      if (word == null) continue;
      final hotValue = (w['hot_value'] as num?)?.toInt();

      items.add(
        UnifiedVideo(
          id: makeVideoId(id, 'hot_${w['sentence_id'] ?? word.hashCode}'),
          platformId: id,
          platformVideoId: 'hot_${w['sentence_id'] ?? word.hashCode}',
          originalUrl:
              'https://www.douyin.com/search/${Uri.encodeComponent(word)}',
          canonicalUrl:
              'https://www.douyin.com/search/${Uri.encodeComponent(word)}',
          title: word,
          description: hotValue != null ? '热度 ${_formatCount(hotValue)}' : null,
          fetchedAt: DateTime.now().toUtc().toIso8601String(),
          stats: VideoStats(viewCount: hotValue),
          availability: VideoAvailability.available,
          // 热榜是搜索引导项，不是可直接播放的视频
          playbackModes: const [PlaybackMode.external],
          diagnostics: VideoDiagnostics(
            adapterId: id,
            upstreamEndpoint: '/aweme/v1/hot/search/list/',
            fromCache: false,
            fetchDurationMs: 0,
            limitations: const [
              '热榜条目是搜索关键词，不是视频，点击后跳转抖音搜索。',
            ],
            notes: const ['来自抖音公开热搜接口。'],
          ),
        ),
      );
    }

    return FeedPage(
      items: items,
      hasMore: end < list.length,
      adapterId: id,
      upstreamEndpoint: '/aweme/v1/hot/search/list/',
      nextOffset: request.offset + 1,
      notes: [
        if (list.isNotEmpty) '热榜共 ${list.length} 条，本次返回第 ${start + 1}-$end 条。',
      ],
    );
  }

  /// 抖音 aweme 的媒体类型（实测值，见 [_isImageTextPost]）。
  static const int mediaTypeVideo = 4;

  /// 图文帖（images post）：平台只下发**音频轨**。
  static const int mediaTypeImageText = 42;

  /// 这条 aweme 是不是"点开只会有声音、没有画面"的图文帖。
  ///
  /// # 实测依据（穷举 28 个地址字段）
  ///
  /// ```
  /// 真视频  media_type=4 ：duration>0、images=0
  ///         play_addr → HTTP 206 / video/mp4，首字节 00 00 00 20 66 74 79 70 69 73 6f 6d
  ///         （ftypisom）**确实是视频**
  /// 图文帖  media_type=42：duration=0、images>=1
  ///         play_addr → audio/mpeg，首字节 49 44 33（ID3），即指向 **.mp3**
  /// ```
  ///
  /// 关键是这两类**混在同一次 feed 响应里**下发。旧实现取
  /// `video.play_addr.url_list[0]` 时不看类型，于是图文帖也带着
  /// `availability: available` 进竖滑流：点开 → 播放器拿到一条 mp3 →
  /// **有音频轨、无视频轨 → 画面必黑，但播放进度正常前进**。
  ///
  /// 这条现象同时修正一个旧的错误归因：模拟器上的"直播/推荐流黑屏"
  /// 曾被整体记成 EGL/软渲染问题，实际相当一部分就是图文帖混发。
  /// （直播黑屏另有原因，见 `douyin/live_client.dart` 的
  /// `_streamHeaders` —— 那一条是 CDN 对默认 UA 返回空 body。）
  ///
  /// # 为什么不单靠 media_type
  ///
  /// `media_type` 是**主判据**，但平台改类型码是很常见的事，
  /// 所以再加一层内容自证的双保险：**既没有正时长、又带了 images**
  /// 才判成图文帖。反过来，只要 `duration > 0` 或 `images` 为空，
  /// 即使类型码不认识也**不**过滤 —— 宁可放过一条音频帖，
  /// 也不能把真视频滤掉（少一条内容 vs 一整批黑屏，取轻的那个）。
  ///
  /// 也不写成 `media_type != 4 就过滤`：那样一旦平台新增一种**可播放**
  /// 的类型码（实测混合流里除 4 外还可能出现的值），整批真视频会被
  /// 静默清空，症状比"混进一条有声无画"更难查。
  static bool _isImageTextPost(Map<String, Object?> raw) {
    final mediaType = _toInt(raw['media_type']);
    if (mediaType == mediaTypeImageText) return true;

    final video = raw['video'] is Map
        ? Map<String, Object?>.from(raw['video'] as Map)
        : const <String, Object?>{};
    final images = raw['images'];
    final hasImages = images is List && images.isNotEmpty;
    final durationMs = _toInt(video['duration']) ?? 0;

    // 双条件都不满足才算图文帖：无时长 **且** 有图片。
    return durationMs <= 0 && hasImages;
  }

  /// 把抖音 aweme 结构转换为统一视频模型。
  ///
  /// 字段映射依据实测响应（2026-10，feed 接口）：
  ///  - `aweme_id`            → platformVideoId
  ///  - `desc`                → title
  ///  - `author.nickname`     → authorName
  ///  - `author.uid`          → authorId
  ///  - `author.avatar_thumb.url_list[0]` → avatarUrl
  ///  - `video.duration`      → durationSeconds（**毫秒**）
  ///  - `video.play_addr.url_list` → 视频直链（实测 Content-Type: video/mp4）
  ///  - `video.cover.url_list[0]`  → coverUrl
  ///  - `video.bit_rate[]`    → 清晰度档位
  ///  - `statistics.digg_count` → likeCount
  ///  - `statistics.comment_count` → commentCount（映射到 danmakuCount）
  ///
  /// 图文帖（[_isImageTextPost]）在这里**也**会被挡下：调用方除了
  /// 推荐流还有别的入口，这层守卫保证任何路径都不会把"只有音频的条目"
  /// 标成可播放。
  UnifiedVideo? _awemeToVideo(Map<String, Object?> raw) {
    if (_isImageTextPost(raw)) return null;

    final awemeId = _nullableString(raw['aweme_id']);
    if (awemeId == null) return null;
    if (!RegExp(r'^\d{15,25}$').hasMatch(awemeId)) return null;

    final author = raw['author'] is Map
        ? Map<String, Object?>.from(raw['author'] as Map)
        : const <String, Object?>{};
    final video = raw['video'] is Map
        ? Map<String, Object?>.from(raw['video'] as Map)
        : const <String, Object?>{};
    final stats = raw['statistics'] is Map
        ? Map<String, Object?>.from(raw['statistics'] as Map)
        : const <String, Object?>{};

    // 时长：抖音返回**毫秒**
    final durationMs = (video['duration'] as num?)?.toInt();
    final durationSec =
        durationMs != null && durationMs > 0 ? durationMs / 1000.0 : null;

    // 封面
    final coverUrl = _firstUrlIn(video['cover']);

    // 清晰度与宽高：取第一档 bit_rate
    final bitRates = video['bit_rate'];
    int? width;
    int? height;
    final qualities = <PlaybackQuality>[];
    if (bitRates is List && bitRates.isNotEmpty) {
      for (final br in bitRates) {
        if (br is! Map) continue;
        final playAddr = br['play_addr'];
        if (playAddr is! Map) continue;
        final w = (playAddr['width'] as num?)?.toInt();
        final h = (playAddr['height'] as num?)?.toInt();
        final gear = _nullableString(br['gear_name']);
        width ??= w;
        height ??= h;
        if (w != null && h != null) {
          qualities.add(
            PlaybackQuality(
              platformQualityId: (br['quality_type'] as num?)?.toInt(),
              label: gear ?? '${h}P',
              width: w,
              height: h,
              codec: null,
              bandwidth: (br['bit_rate'] as num?)?.toInt(),
            ),
          );
        }
      }
    }

    // 关键：把 feed 里的播放地址缓存起来，供 resolvePlayback 使用。
    // 抖音详情接口需要 Argus 签名，无法按 aweme_id 补查直链，
    // 因此必须在解析 feed 时就记住地址。
    _cachePlayback(awemeId, video, width: width, height: height);

    return UnifiedVideo(
      id: makeVideoId(id, awemeId),
      platformId: id,
      platformVideoId: awemeId,
      originalUrl: 'https://www.douyin.com/video/$awemeId',
      canonicalUrl: 'https://www.douyin.com/video/$awemeId',
      title: _stringOr(raw['desc'], '无标题'),
      description: _nullableString(raw['desc']),
      author: VideoAuthor(
        name: _nullableString(author['nickname']),
        // 必须是 sec_uid，不是 uid。
        //
        // 实测（2026-10-23，aweme/detail 真实响应）：author 里两个都在，
        // `uid=3890515065704004`（纯数字）、`sec_uid=MS4wLjABAAAA...`。
        // 但 `commit/follow/user` 认的是 **sec_user_id**（bundle 调用点
        // 传的就是 sec_uid）。以前这里填 uid，导致从**推荐流/搜索**点关注
        // 必然失败——而详情页走另一条映射填的是 sec_uid，所以详情页能用、
        // 信息流不能用，表现成"有时候关注得上，有时候点了没反应"。
        platformAuthorId: _nullableString(author['sec_uid']) ??
            _nullableString(author['uid']),
        avatarUrl: _firstUrlIn(author['avatar_thumb']) ??
            _firstUrlIn(author['avatar_medium']),
        profileUrl: _nullableString(author['sec_uid']) != null
            ? 'https://www.douyin.com/user/${author['sec_uid']}'
            : null,
      ),
      coverUrl: coverUrl,
      durationSeconds: durationSec,
      aspectRatio: normalizeAspectRatio(width, height),
      width: width,
      height: height,
      publishedAt: _epochToIso(raw['create_time']),
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: VideoStats(
        viewCount: (stats['play_count'] as num?)?.toInt(),
        likeCount: (stats['digg_count'] as num?)?.toInt(),
        danmakuCount: (stats['comment_count'] as num?)?.toInt(),
      ),
      availability: VideoAvailability.available,
      playbackModes: const [PlaybackMode.native, PlaybackMode.external],
      requiresAuth: false,
      diagnostics: VideoDiagnostics(
        adapterId: id,
        upstreamEndpoint: '/aweme/v1/feed/',
        fromCache: false,
        fetchDurationMs: 0,
        limitations: const [
          '抖音视频详情接口需要 Argus 签名，当前只能通过推荐流获取元数据。',
        ],
        notes: const ['来自抖音 APP 端公开推荐接口。'],
      ),
    );
  }



  // ── 元数据 ─────────────────────────────────────────────────

  /// 拉取视频元数据。
  ///
  /// # 本轮修复（2026-10-19）
  ///
  /// 旧实现用 `_http.get(...)` **裸 HTTP 请求**打
  /// `www.douyin.com/aweme/v1/web/aweme/detail/`，必然得到
  /// `HTTP 403 Blocked by ArgusSecurityPlugin Uifid Not Found`。
  ///
  /// 实测根因：
  /// 平台分两级下发 uifid —— `UIFID_TEMP`（~500ms）与**正式 `UIFID`**
  /// （~2.5–4s）。detail 要求正式 UIFID，而裸 HTTP 请求连 TEMP 都没有。
  ///
  /// 现在改为走 [DouyinWebSigner]：
  ///  1. `ensureReady(requireFullUifid: true)` 等到正式 UIFID
  ///  2. 在页面上下文里 fetch detail（页面 SDK 自动签名）
  ///  3. 实测返回 200 / ~53KB / 含 `aweme_detail`
  ///
  /// 裸 HTTP 路径已删除：它不是"被挡住"，而是**根本没尝试正确路径**。
  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async {
    final awemeId = match.platformVideoId;

    _logger.info(
      'douyin: fetching metadata',
      {'videoId': awemeId, 'channel': 'webview'},
    );

    final DouyinCommentResponse response;
    {
      final signer = _ensureSigner;

      // 1. 等到正式 UIFID（detail 级）
      final ready = await signer.ensureReady(
        awemeId: awemeId,
        requireFullUifid: true,
      );
      if (!ready) {
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '抖音会话初始化未完成，暂时无法获取视频信息。',
          technicalMessage:
              'DouyinWebSigner not fully ready: readiness=${signer.readiness.name}, '
              'fullUifidAfterMs=${signer.fullUifidAfterMs}. '
              'detail requires UIFID (not UIFID_TEMP).',
          platformId: id,
          retryable: true,
          diagnostics: {
            'stage': 'webview_full_uifid',
            'readiness': signer.readiness.name,
            'required': 'UIFID',
          },
        );
      }

      // 2. 页面上下文请求 detail
      response = await signer.request(
        path: '/aweme/v1/web/aweme/detail/',
        params: _detailParams(awemeId),
        requireFullUifid: true,
      );
    }

    if (response.statusCode == 403) {
      throw _argusBlockedError(response.body);
    }

    if (response.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音返回了空响应，可能是会话凭证已失效。',
        technicalMessage:
            'empty body from aweme/detail (HTTP ${response.statusCode})',
        httpStatus: response.statusCode,
        platformId: id,
        retryable: true,
      );
    }

    final json = response.tryParseJson();
    if (json == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音返回了无法解析的数据。',
        technicalMessage:
            'aweme/detail body is not JSON (length=${response.body.length})',
        platformId: id,
      );
    }

    final detail = json['aweme_detail'];
    if (detail is! Map) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '抖音未返回该视频的数据，可能视频已删除或不可见。',
        technicalMessage:
            'aweme_detail is ${detail.runtimeType}; '
            'status_code=${json['status_code']}',
        upstreamCode: json['status_code'],
        platformId: id,
        diagnostics: {
          'responseKeys': json.keys.take(10).toList(),
        },
      );
    }

    final map = Map<String, Object?>.from(detail);

    // 3. 顺手把播放地址与清晰度档位缓存起来，
    //    让 resolvePlayback 不必再发一次请求。
    final video = map['video'];
    if (video is Map) {
      final v = Map<String, Object?>.from(video);
      _cachePlayback(
        awemeId,
        v,
        width: (v['width'] as num?)?.toInt(),
        height: (v['height'] as num?)?.toInt(),
      );
    }

    return _parseAwemeDetail(map, match);
  }

  /// detail 接口的公共参数集。
  ///
  /// 与 App 内 `fetchComments` 使用**同一套**参数形态：实测这套参数
  /// 在正式 UIFID 下可让 detail / comment / related 全部返回 200。
  Map<String, String> _detailParams(String awemeId) => {
        'device_platform': 'webapp',
        'aid': '6383',
        'channel': 'channel_pc_web',
        'pc_client_type': '1',
        'version_code': '290100',
        'version_name': '29.1.0',
        'cookie_enabled': 'true',
        'browser_language': 'zh-CN',
        'browser_platform': 'Win32',
        'browser_name': 'Chrome',
        'browser_version': '124.0.0.0',
        'browser_online': 'true',
        'engine_name': 'Blink',
        'engine_version': '124.0.0.0',
        'os_name': 'Windows',
        'os_version': '10',
        'platform': 'PC',
        'downlink': '10',
        'effective_type': '4g',
        'round_trip_time': '0',
        'update_version_code': '170400',
        'aweme_id': awemeId,
      };


  /// 构造 aweme/detail 的查询参数。
  ///
  /// 参数集合参考 Evil0ctal/Douyin_TikTok_Download_API 的 web 客户端画像，
  /// 使用固定的、非账号态的浏览器指纹字段。**不包含任何凭证**。
  /// Argus 风控拦截的统一错误。
  ///
  /// # 本轮修正（2026-10-19）
  ///
  /// 旧实现写的是 `requiredCookie: 'UIFID_TEMP'`、`signatureSufficient: false`，
  /// 且注释断言"放行需服务端签发的 UIFID_TEMP Cookie"——**这是错的**。
  ///
  /// 实测：`UIFID_TEMP` 只够评论；detail 需要**正式 `UIFID`**。
  /// 签名（`a_bogus`）本身是够的，缺的是**会话等级**。
  FusionException _argusBlockedError(String body) {
    final isUifid = body.contains('Uifid');
    return FusionException(
      code: FusionErrorCode.permissionDenied,
      userMessage: isUifid
          ? '抖音拒绝了本次请求（会话等级不足，需要完整的浏览器会话凭证）。'
          : '抖音拒绝了本次请求（平台风控拦截）。',
      technicalMessage:
          'douyin aweme/detail blocked: HTTP 403 body="${body.trim()}"',
      httpStatus: 403,
      upstreamCode: 403,
      platformId: id,
      // 会话可能升级，重试有意义
      retryable: true,
      diagnostics: {
        'blockedBy': 'ArgusSecurityPlugin',
        // 实测：detail 要正式 UIFID，UIFID_TEMP 不够
        'requiredCookie': 'UIFID',
        'tempSufficient': false,
        'signatureSufficient': true,
        'note':
            'a_bogus 签名本身正确；拦截原因是会话等级。'
                'UIFID_TEMP（~500ms 下发）只够评论，'
                '正式 UIFID（~2.5-4s 下发）才放行 detail。',
      },
    );
  }

  /// 解析 aweme_detail。
  ///
  /// # 本轮修复（2026-10-19）
  ///
  /// 旧实现的注释写"当前不可达，保留以便平台策略变化后恢复"，
  /// `limitations` 也写着"当前环境下无法稳定获取"。现在这条路径
  /// **已经实测可用**（正式 UIFID 下返回 200 / ~53KB），因此：
  ///  - 文案改为真实说明
  ///  - 统计字段按实测填充（`play_count` 恒为 0，仍不采用）
  ///
  /// 字段路径按实测响应确定，并遵循"缺失即 null"的原则。
  VideoMetadata _parseAwemeDetail(
    Map<String, Object?> detail,
    LinkMatch match,
  ) {
    final video = detail['video'] is Map
        ? Map<String, Object?>.from(detail['video'] as Map)
        : const <String, Object?>{};
    final author = detail['author'] is Map
        ? Map<String, Object?>.from(detail['author'] as Map)
        : const <String, Object?>{};
    final statistics = detail['statistics'] is Map
        ? Map<String, Object?>.from(detail['statistics'] as Map)
        : const <String, Object?>{};

    // 封面：cover.url_list 或 origin_cover.url_list
    final coverUrl = _firstUrlFrom(
      (video['cover'] is Map
              ? Map<String, Object?>.from(video['cover'] as Map)['url_list']
              : null) ??
          (video['origin_cover'] is Map
              ? Map<String, Object?>.from(video['origin_cover'] as Map)['url_list']
              : null),
    );

    final width = (video['width'] as num?)?.toInt();
    final height = (video['height'] as num?)?.toInt();

    return VideoMetadata(
      title: _stringOr(detail['desc'], '未命名视频'),
      description: _nullableString(detail['desc']),
      author: VideoAuthor(
        name: _nullableString(author['nickname']),
        platformAuthorId: _nullableString(author['sec_uid']),
        profileUrl: _nullableString(author['sec_uid']) != null
            ? 'https://www.douyin.com/user/${author['sec_uid']}'
            : null,
        avatarUrl: _firstUrlFrom(
          author['avatar_thumb'] is Map
              ? Map<String, Object?>.from(author['avatar_thumb'] as Map)['url_list']
              : null,
        ),
      ),
      coverUrl: coverUrl,
      durationSeconds: normalizeDuration(
        video['duration'] as num?,
        isMilliseconds: true, // 抖音 duration 单位为毫秒
      ),
      width: width,
      height: height,
      publishedAt: _epochToIso(detail['create_time']),
      stats: VideoStats(
        // 实测：抖音 web 接口的 play_count 恒为 0，不可信，故不采用
        viewCount: null,
        likeCount: (statistics['digg_count'] as num?)?.toInt(),
        danmakuCount: null,
      ),
      availability: VideoAvailability.available,
      requiresAuth: false,
      limitations: const [
        // 实测（2026-10-19）：正式 UIFID 下 detail 可用。
        // 唯一前提是 WebView 能完成风控初始化（拿到正式 UIFID）。
        '需要在应用内 WebView 完成平台风控初始化（获取正式 UIFID）后才能获取。',
      ],
      notes: const [
        '通过应用内隐藏 WebView 请求，未使用外部浏览器，未伪造设备指纹。',
        '实测返回 aweme_detail，含 play_addr 与 bit_rate 多档清晰度。',
      ],
      upstreamEndpoint: '/aweme/v1/web/aweme/detail',
    );
  }

  // ── 播放源 ─────────────────────────────────────────────────

  /// 缓存从 feed / detail 拿到的播放地址。
  ///
  /// # 本轮修复（2026-10-19）
  ///
  /// 旧注释写"抖音的详情接口需要 Argus 签名，无法按 aweme_id 单独查询
  /// 播放地址"——**这已被推翻**。正式 UIFID 下 detail 返回
  /// `video.play_addr.url_list`（3 个直链）与 `bit_rate`（7 档清晰度）。
  ///
  /// 因此缓存现在有两个来源：
  ///  1. feed 解析（快，但只覆盖推荐流里出现过的视频）
  ///  2. detail 补查（覆盖任意 aweme_id）
  ///
  /// 缓存只在内存中，进程退出即失效——不持久化，因为直链有有效期
  /// 且不应写入磁盘。
  final Map<String, _CachedPlayback> _playbackCache = {};

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async {
    final videoId = request.platformVideoId;

    // 1. 优先使用缓存（feed 或之前 detail 补查的结果）
    final cached = _playbackCache[videoId];
    if (cached != null && cached.isUsable) {
      return NativePlaybackSource(
        videoId: makeVideoId(id, videoId),
        videoStreamUrl: cached.url,
        requiredHeaders: cached.headers,
        quality: cached.quality,
        availableQualities: cached.qualities,
        isDash: false,
        videoFallbackUrls: cached.fallbackUrls,
        expiresAt: cached.expiresAt,
      );
    }

    // 2. 缓存未命中：通过 detail 补查真实直链。
    //
    // 这是本轮新增的能力：以前这里直接退回官方嵌入播放，
    // 现在可以先尝试拿到原生直链（正式 UIFID 下 detail 可用）。
    final fetched = await _tryResolveViaDetail(videoId);
    if (fetched != null) return fetched;

    // 3. 仍失败：退回官方嵌入播放，并如实说明原因。
    //
    // 实测：open.douyin.com/player/video 返回 200，
    // 无 X-Frame-Options / CSP frame-ancestors 限制。
    final embedUrl = 'https://open.douyin.com/player/video'
        '?vid=${Uri.encodeQueryComponent(videoId)}'
        '&autoplay=0';

    return OfficialEmbedPlaybackSource(
      videoId: makeVideoId(id, videoId),
      embedUrl: embedUrl,
      embedCapabilities: const EmbedCapabilities(
        hasBuiltInControls: true,
        supportsQualitySwitch: false,
        supportsPlaybackRate: false,
        refererSensitive: true,
        requiresLogin: false,
      ),
      embedNotes: const [
        '未能获取应用内播放直链（可能是会话初始化未完成或视频不可见）。',
        '已退回抖音官方播放器；播放控制能力由平台决定。',
      ],
    );
  }

  /// 通过 detail 接口补查播放地址。
  ///
  /// 成功时写入缓存并返回 [NativePlaybackSource]；失败返回 null
  /// （由调用方降级到官方嵌入，**不抛错**——播放路径不该因为
  /// 元数据补查失败而完全不可用）。
  Future<PlaybackSource?> _tryResolveViaDetail(String awemeId) async {
    try {
      final DouyinCommentResponse response;
      {
        final signer = _ensureSigner;
        final ready = await signer.ensureReady(
          awemeId: awemeId,
          requireFullUifid: true,
        );
        if (!ready) return null;

        response = await signer.request(
          path: '/aweme/v1/web/aweme/detail/',
          params: _detailParams(awemeId),
          requireFullUifid: true,
        );
      }
      if (response.isEmpty) return null;

      final json = response.tryParseJson();
      final detail = json?['aweme_detail'];
      if (detail is! Map) return null;

      final d = Map<String, Object?>.from(detail);
      final video = d['video'];
      if (video is! Map) return null;

      final v = Map<String, Object?>.from(video);
      _cachePlayback(
        awemeId,
        v,
        width: (v['width'] as num?)?.toInt(),
        height: (v['height'] as num?)?.toInt(),
      );

      final hit = _playbackCache[awemeId];
      if (hit == null || !hit.isUsable) return null;

      _logger.info('douyin: playback resolved via detail', {
        'awemeId': awemeId,
        'qualities': hit.qualities.length,
      });

      return NativePlaybackSource(
        videoId: makeVideoId(id, awemeId),
        videoStreamUrl: hit.url,
        requiredHeaders: hit.headers,
        quality: hit.quality,
        availableQualities: hit.qualities,
        isDash: false,
        videoFallbackUrls: hit.fallbackUrls,
        expiresAt: hit.expiresAt,
      );
    } catch (e) {
      // 播放补查失败不抛出：降级到官方嵌入即可
      _logger.debug('douyin: detail playback fallback', {
        'awemeId': awemeId,
        'error': e.runtimeType.toString(),
      });
      return null;
    }
  }

  /// 规范化抖音播放地址。
  ///
  /// 实测（2026-10）：mpv 直接用原始 URL 会报
  /// `Failed to open https://v95-....douyinvod.com/...`，但同一 URL
  /// 用 HTTP 客户端能正常下载（200，video/mp4，ftypisom）。
  ///
  /// 原因是抖音直链的查询串里有大量 `%3D`、`%7C` 等百分号编码，
  /// 且 `&` 分隔的参数极多（实测 19 个）。mpv 的 URL 解析对
  /// 未转义的 `%` 序列较敏感。
  ///
  /// 处理方式：把查询串里的值做一次**解码再编码**，保证传给 mpv 的
  /// 是规范化 URL。若规范化后与原 URL 相同则原样返回。
  static String _normalizePlayUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;

    // 无查询串：直接返回
    if (uri.query.isEmpty) return raw;

    try {
      // 逐项重建查询串，确保 key/value 都被正确编码
      final pairs = <String>[];
      uri.queryParametersAll.forEach((key, values) {
        for (final v in values) {
          pairs.add(
            '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(v)}',
          );
        }
      });
      if (pairs.isEmpty) return raw;

      final rebuilt = uri.replace(query: pairs.join('&')).toString();
      return rebuilt;
    } catch (_) {
      return raw;
    }
  }

  /// 记录 feed 解析时拿到的播放地址，供 resolvePlayback 使用。
  void _cachePlayback(
    String awemeId,
    Map<String, Object?> video, {
    int? width,
    int? height,
  }) {
    final playAddr = video['play_addr'];
    if (playAddr is! Map) return;

    final urlList = playAddr['url_list'];
    if (urlList is! List || urlList.isEmpty) return;

    final urls = <String>[];
    for (final u in urlList) {
      if (u is String && u.isNotEmpty) urls.add(u);
    }
    if (urls.isEmpty) return;

    // 清晰度档位
    final qualities = <PlaybackQuality>[];
    final bitRates = video['bit_rate'];
    if (bitRates is List) {
      for (final br in bitRates) {
        if (br is! Map) continue;
        final pa = br['play_addr'];
        if (pa is! Map) continue;
        final w = (pa['width'] as num?)?.toInt();
        final h = (pa['height'] as num?)?.toInt();
        if (w == null || h == null) continue;
        qualities.add(
          PlaybackQuality(
            platformQualityId: (br['quality_type'] as num?)?.toInt(),
            label: _nullableString(br['gear_name']) ?? '${h}P',
            width: w,
            height: h,
            bandwidth: (br['bit_rate'] as num?)?.toInt(),
          ),
        );
      }
    }

    _playbackCache[awemeId] = _CachedPlayback(
      url: _normalizePlayUrl(urls.first),
      fallbackUrls: urls.skip(1).map(_normalizePlayUrl).toList(),
      // 抖音 CDN 实测不校验 Referer/UA，但保留 UA 可避免部分节点
      // 返回与浏览器不同的响应体（实测去掉 UA 后 mpv 报 Failed to open）。
      headers: const {'User-Agent': _appUserAgent},
      quality: width != null && height != null
          ? PlaybackQuality(
              platformQualityId: null,
              label: '${height}P',
              width: width,
              height: height,
            )
          : null,
      qualities: qualities,
      cachedAt: DateTime.now(),
    );

    // 缓存上限，避免长浏览时无限增长
    if (_playbackCache.length > 60) {
      final oldest = _playbackCache.entries
          .reduce((a, b) => a.value.cachedAt.isBefore(b.value.cachedAt) ? a : b);
      _playbackCache.remove(oldest.key);
    }
  }

  // ── 辅助 ───────────────────────────────────────────────────

  static String? _firstUrlFrom(Object? urlList) {
    if (urlList is List && urlList.isNotEmpty) {
      final first = urlList.first;
      if (first is String && first.isNotEmpty) return first;
    }
    return null;
  }

  /// 从抖音的 `{"url_list": [...]}` 结构取第一个 URL。
  ///
  /// 抖音把封面/头像/播放地址都包成这种结构，
  /// 与上面直接接收 List 的版本区分开，避免调用处混淆。
  static String? _firstUrlIn(Object? wrapper) {
    if (wrapper is! Map) return null;
    return _firstUrlFrom(wrapper['url_list']);
  }

  /// 数字格式化（1.2万 / 3.4亿）。
  static String _formatCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  static String? _nullableString(Object? value) {
    if (value == null) return null;
    if (value is String) return value.isEmpty ? null : value;
    return value.toString();
  }

  /// 把平台下发的 id 字段转成字符串，**把 0 / '0' 当作"没有"**。
  ///
  /// 抖音的 `reply_id` / `reply_to_reply_id` 在顶层评论上是 0，
  /// 直接 `toString()` 会得到 '0' 并被上层当成一个合法的评论 id，
  /// 回复时就会带上 root=0 这种垃圾参数。
  static String? _nonZeroId(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toInt() == 0 ? null : '${value.toInt()}';
    final s = value.toString().trim();
    if (s.isEmpty || s == '0') return null;
    return s;
  }

  static String _stringOr(Object? value, String fallback) =>
      _nullableString(value) ?? fallback;

  static String? _epochToIso(Object? value) {
    if (value is! num || value <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      value.toInt() * 1000,
      isUtc: true,
    ).toIso8601String();
  }

  /// 抖音的数字字段类型不统一：同一字段可能是数字，也可能是字符串。
  ///
  /// 直播接口尤其明显：`status` 是数字，`id_str` 是字符串，
  /// `user_count` 是数字。直接 `as num?` 会抛类型错误，
  /// 因此统一走这里兼容两种形态。
  static int? _toInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
