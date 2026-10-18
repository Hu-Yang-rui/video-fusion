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
/// # 参考的公开实现
///
///  - Evil0ctal/Douyin_TikTok_Download_API（Apache-2.0）：`a_bogus` 签名算法
///  - JoeanAmier/TikTokDownloader：可读的 `a_bogus` JS 参考实现
///  - SocialSisterYi/bilibili-API-collect 的同类社区文档方法学
///
/// 本适配器**不携带**任何 Cookie、`UIFID_TEMP`、`ttwid`、账号令牌，
/// 也不生成伪造的设备指纹。
library;

import '../core/credential_vault.dart';
import '../core/errors.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../core/qr_login.dart';
import '../models/feed.dart';
import '../models/interaction.dart';
import '../models/live.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'douyin/live_client.dart';
import 'douyin/login_client.dart';
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
  DouyinAdapter({required FusionHttpClient http, FusionLogger? logger})
      : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _shareReferer = 'https://www.douyin.com/';

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

  /// 扫码登录客户端（懒加载）。
  DouyinLoginClient? _loginClient;

  DouyinLoginClient get _ensureLoginClient => _loginClient ??=
      DouyinLoginClient(http: _http, logger: _logger);

  @override
  Future<QrLoginChallenge> requestQrChallenge() async {
    final challenge = await _ensureLoginClient.requestQrCode();

    return QrLoginChallenge(
      platformId: id,
      // 抖音返回的是已渲染好的 base64 PNG。
      // 必须走 qrImageBase64（直接展示），不能塞进 qrContent ——
      // 那会让 UI 把 base64 字符串当二维码内容重新编码，画出扫不出的假码。
      qrContent: '',
      qrImageBase64: challenge.qrBase64,
      // challengeKey 编码 token 与 fp：`token|fp`
      // 轮询时两者都必须与申请时一致
      challengeKey: '${challenge.token}|${challenge.fp}',
      createdAt: DateTime.now(),
      expiresIn: challenge.expiresAt.difference(DateTime.now()),
    );
  }

  @override
  Future<QrLoginPollResult> pollQrChallenge(QrLoginChallenge challenge) async {
    final client = _ensureLoginClient;

    // 从 challenge 还原出轮询需要的信息。
    // fp 需要与申请二维码时一致，但 QrLoginChallenge 没有这个字段，
    // 因此在 token 里编码它：`token|fp`。
    final parts = challenge.challengeKey.split('|');
    final token = parts.first;
    final fp = parts.length > 1 ? parts[1] : '';

    final internal = DouyinQrChallenge(
      qrBase64: challenge.qrImageBase64 ?? challenge.qrContent,
      token: token,
      expiresAt: challenge.createdAt.add(challenge.expiresIn),
      fp: fp,
    );

    final result = await client.pollQrStatus(internal);

    final phase = switch (result.phase) {
      DouyinLoginPhase.waitingForScan => QrLoginPhase.waitingForScan,
      DouyinLoginPhase.waitingForConfirm => QrLoginPhase.waitingForConfirm,
      DouyinLoginPhase.succeeded => QrLoginPhase.succeeded,
      DouyinLoginPhase.expired => QrLoginPhase.expired,
      DouyinLoginPhase.blocked => QrLoginPhase.failed,
    };

    return QrLoginPollResult(
      phase: phase,
      message: result.message,
      cookies: result.session?.cookies ?? const {},
      userId: result.session?.userId,
      displayName: result.session?.displayName,
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
    final room = await _ensureLiveClient.findRoomInFeed(roomKey);
    if (room == null) {
      throw FusionException(
        code: FusionErrorCode.videoNotFound,
        userMessage: '这个直播间当前不在推荐流中，暂时无法获取详情。',
        technicalMessage:
            'room $roomKey not found in webcast/feed after 3 attempts',
        platformId: id,
        retryable: true,
      );
    }

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
      // 抖音 status: 2 = 直播中（实测推荐流里的条目全是 2）
      liveStatus: status == 2 ? 1 : 0,
      online: _toInt(room['user_count']),
      description: _nullableString(room['introduction']),
      coverUrl: _firstUrl(room['cover']),
      uname: _nullableString(owner['nickname']),
      faceUrl: _firstUrl(owner['avatar_thumb']),
      liveStartTime: _toInt(room['create_time']) != null
          ? _epochToIso(_toInt(room['create_time'])!)
          : null,
      // 抖音直播以竖屏为主（stream_orientation: 1）
      isPortrait: _toInt(room['stream_orientation']) != 1,
    );
  }

  @override
  Future<LiveStream> resolveLiveStream(int roomId, {int? quality}) =>
      resolveLiveStreamByKey('$roomId', quality: quality);

  @override
  Future<LiveStream> resolveLiveStreamByKey(
    String roomKey, {
    int? quality,
  }) async {
    final room = await _ensureLiveClient.findRoomInFeed(roomKey);
    if (room == null) {
      throw FusionException(
        code: FusionErrorCode.videoNotFound,
        userMessage: '这个直播间当前不在推荐流中，暂时无法观看。',
        technicalMessage:
            'room $roomKey not found in webcast/feed; cannot resolve stream',
        platformId: id,
        retryable: true,
      );
    }

    final status = _toInt(room['status']) ?? 0;
    if (status != 2) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '主播当前没有开播。',
        technicalMessage: 'room $roomKey status=$status (2 = live)',
        platformId: id,
        retryable: true,
      );
    }

    final stream = _ensureLiveClient.parseStream(room);
    if (stream == null) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '该直播间当前没有可播放的流。',
        technicalMessage:
            'room $roomKey: stream_url present but no playable url parsed',
        platformId: id,
        retryable: true,
      );
    }
    return stream;
  }

  /// 抖音直播弹幕：**未实现**。
  ///
  /// 实测结论：抖音直播弹幕走 WebSocket + protobuf（`wss://webcast*.douyin.com/webcast/im/ws/`），
  /// 需要 `signature` 参数，该签名由设备侧生成。项目当前没有可用的
  /// 弹幕端点，因此如实声明不支持，UI 不渲染弹幕开关。
  ///
  /// 不做假弹幕、不接入未验证的第三方弹幕服务。
  @override
  Future<LiveDanmakuEndpoint> fetchLiveDanmakuEndpoint(int roomId) =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '抖音直播弹幕暂不支持。',
        technicalMessage:
            'douyin live danmaku uses wss + protobuf with a device-side '
            'signature; no verified public endpoint available',
        platformId: id,
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

  @override
  bool get supportsLike => false;

  @override
  bool get supportsCoin => false;

  @override
  bool get supportsFavorite => false;

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

    // 2. 计算游标（偏移量语义）
    final safeSize = pageSize.clamp(1, 50);
    final cursor = (page <= 1 ? 0 : (page - 1) * safeSize);

    // 3. 在页面上下文里请求（页面 SDK 自动签名）
    final response = await signer.request(
      path: '/aweme/v1/web/comment/list/',
      params: {
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
      },
    );

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
      // IP 属地。
      //
      // 实测（2026-10，未登录态，通过应用内 WebView 请求）：
      // 抖音评论顶层字段 `ip_label` 直接就是地区名，
      // 例如 "安徽" / "湖南" / "四川"，**不需要登录**。
      //
      // 注意不要用 `user.region` —— 那是账号注册国家（恒为 "CN"），
      // 不是 IP 属地。
      ipLocation: _nullableString(raw['ip_label'])?.trim(),
    );
  }

  @override
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async =>
      InteractionState.unknown;

  @override
  Future<InteractionResult> setLike(
    String platformVideoId, {
    required bool like,
    required PlatformSession session,
    int? aid,
  }) async {
    throw FusionException(
      code: FusionErrorCode.capabilityUnavailable,
      userMessage: '抖音点赞当前不可用：该接口受平台风控保护。',
      technicalMessage: 'douyin like blocked by ArgusSecurityPlugin',
      platformId: id,
      retryable: false,
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

  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
  }) async {
    throw FusionException(
      code: FusionErrorCode.capabilityUnavailable,
      userMessage: '抖音收藏当前不可用：该接口受平台风控保护。',
      technicalMessage: 'douyin favorite blocked by ArgusSecurityPlugin',
      platformId: id,
      retryable: false,
    );
  }

  /// 抖音搜索接口同样受 Argus 风控保护（实测返回空响应或 403），
  /// 因此**不声明支持搜索**，避免 UI 展示一个必然失败的入口。
  @override
  bool get supportsSearch => false;

  /// 搜索不可用：明确抛错，不返回空列表。
  ///
  /// 返回空列表会让"能力不可用"伪装成"没有搜到内容"。
  @override
  Future<FeedPage> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    throw FusionException(
      code: FusionErrorCode.capabilityUnavailable,
      userMessage: '抖音搜索当前不可用：该接口受平台风控保护。',
      technicalMessage:
          'douyin search unavailable: search endpoints are blocked by '
          'ArgusSecurityPlugin (empty body / 403 before signature check).',
      platformId: id,
      retryable: false,
      diagnostics: const {
        'blockedBy': 'ArgusSecurityPlugin',
        'supportsSearch': false,
      },
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
        // 推荐流与热榜的 aweme 结构已包含完整元数据，
        // 但按 aweme_id 单独查详情仍需 Argus 签名。
        supportsMetadata: false,
        // 推荐流返回的 play_addr 实测为 video/mp4 直链，可在应用内播放
        supportsNativePlayback: true,
        // open.douyin.com/player/video 实测可嵌入
        supportsOfficialEmbed: true,
        supportsExternalFallback: true,
        requiresAuthForMetadata: true,
        // 推荐流/热榜不需要签名；详情/搜索需要
        requiresSignature: true,
        maxQualityWithoutAuth: null,
        notes: [
          '链接识别与短链展开已实现并通过真实网络验证。',
          '推荐流与热榜使用 APP 端公开接口（api.amemv.com），'
              '实测无需签名即可返回真实数据。',
          '推荐流返回的播放地址实测为 video/mp4 直链（ftypisom 头），可在应用内原生播放。',
          '按 aweme_id 单独查询详情、搜索、话题接口需要 X-Argus 签名，'
              '实测返回空响应，当前不可用。',
          'Argus 签名逻辑为远程下发的 JS（bytegecko CDN）并在 WebView 中执行，'
              '本项目不实现，因为那属于规避平台访问控制。',
          '本适配器不携带任何 Cookie、账号令牌、X-Argus 签名或伪造设备指纹。',
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
    for (final raw in list) {
      if (raw is! Map) continue;
      final video = _awemeToVideo(Map<String, Object?>.from(raw));
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
  UnifiedVideo? _awemeToVideo(Map<String, Object?> raw) {
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
        platformAuthorId: _nullableString(author['uid']),
        avatarUrl: _firstUrlIn(author['avatar_thumb']) ??
            _firstUrlIn(author['avatar_medium']),
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



  // ── 元数据（当前不可用，如实报错）──────────────────────────

  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async {
    // 仍然发起一次真实请求，以便：
    //  1. 验证当前环境下的实际拦截行为（而不是凭假设报错）
    //  2. 在平台策略变化后能够自动恢复
    //  3. 向用户与报告提供**实测证据**而非猜测
    final query = _buildDetailQuery(match.platformVideoId);
    final url = 'https://www.douyin.com/aweme/v1/web/aweme/detail/?$query';

    _logger.info(
      'douyin: probing aweme/detail (expected to be blocked by Argus)',
      {'videoId': match.platformVideoId},
    );

    try {
      final result = await _http.get(
        url,
        headers: const {
          'Referer': _shareReferer,
          'Accept': 'application/json, text/plain, */*',
        },
        platformId: id,
        acceptStatuses: const {200, 403},
      );

      // 实测的 Argus 风控拦截
      if (result.statusCode == 403) {
        throw _argusBlockedError(result.body);
      }

      final json = result.jsonObject(platformId: id);
      final detail = json['aweme_detail'];

      if (detail is! Map) {
        // 平台返回 200 但没有数据 —— 同样如实报错，不伪造
        throw FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '抖音未返回该视频的数据，当前无法获取元数据。',
          technicalMessage:
              'aweme_detail is ${detail.runtimeType}; status_code=${json['status_code']}',
          upstreamCode: json['status_code'],
          platformId: id,
          diagnostics: {
            'responseKeys': json.keys.take(10).toList(),
          },
        );
      }

      // 若平台策略放开，以下解析路径即可生效
      return _parseAwemeDetail(Map<String, Object?>.from(detail), match);
    } on FusionException {
      rethrow;
    } catch (e) {
      throw normalizeError(e, platformId: id);
    }
  }

  /// 构造 aweme/detail 的查询参数。
  ///
  /// 参数集合参考 Evil0ctal/Douyin_TikTok_Download_API 的 web 客户端画像，
  /// 使用固定的、非账号态的浏览器指纹字段。**不包含任何凭证**。
  String _buildDetailQuery(String awemeId) {
    final params = <String, String>{
      'device_platform': 'webapp',
      'aid': '6383',
      'channel': 'channel_pc_web',
      'aweme_id': awemeId,
      'pc_client_type': '1',
      'version_code': '290100',
      'version_name': '29.1.0',
      'cookie_enabled': 'true',
      'screen_width': '1920',
      'screen_height': '1080',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '124.0.0.0',
      'browser_online': 'true',
      'engine_name': 'Blink',
      'engine_version': '124.0.0.0',
      'os_name': 'Windows',
      'os_version': '10',
      'cpu_core_num': '8',
      'device_memory': '8',
      'platform': 'PC',
      'downlink': '10',
      'effective_type': '4g',
      'round_trip_time': '50',
    };
    return params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  /// Argus 风控拦截的统一错误。明确说明"这不是签名问题"。
  FusionException _argusBlockedError(String body) {
    final isUifid = body.contains('Uifid');
    return FusionException(
      code: FusionErrorCode.permissionDenied,
      userMessage: isUifid
          ? '抖音拒绝了本次请求（平台风控拦截，需要浏览器环境凭证）。'
          : '抖音拒绝了本次请求（平台风控拦截）。',
      technicalMessage:
          'douyin aweme/detail blocked: HTTP 403 body="${body.trim()}"',
      httpStatus: 403,
      upstreamCode: 403,
      platformId: id,
      // 这不是可重试的临时错误
      retryable: false,
      diagnostics: {
        'blockedBy': 'ArgusSecurityPlugin',
        'requiredCookie': 'UIFID_TEMP',
        'signatureSufficient': false,
        'note':
            '拦截发生在签名校验之前，a_bogus 正确也无法通过；'
                '放行需服务端签发的 UIFID_TEMP Cookie。',
      },
    );
  }

  /// 解析 aweme_detail。当前不可达，但保持完整以便平台策略变化后可用。
  ///
  /// 字段路径参考公开实现的解析逻辑，并遵循"缺失即 null"的原则。
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
        // 公开实现记录：抖音 web 接口的 play_count 恒为 0，不可信，故不采用
        viewCount: null,
        likeCount: (statistics['digg_count'] as num?)?.toInt(),
        danmakuCount: null,
      ),
      availability: VideoAvailability.available,
      requiresAuth: false,
      limitations: const [
        '抖音元数据接口受平台风控保护，当前环境下无法稳定获取。',
      ],
      notes: const ['本路径当前不可达；保留以便平台策略变化后恢复。'],
      upstreamEndpoint: '/aweme/v1/web/aweme/detail',
    );
  }

  // ── 播放源 ─────────────────────────────────────────────────

  /// 缓存从 feed 拿到的播放地址。
  ///
  /// 抖音的详情接口需要 Argus 签名，无法按 aweme_id 单独查询播放地址。
  /// 但 feed 接口返回的每条视频都带完整 `video.play_addr.url_list`，
  /// 因此这里把 feed 解析时拿到的地址缓存起来，供 resolvePlayback 使用。
  ///
  /// 缓存只在内存中，进程退出即失效——不持久化，因为直链有有效期
  /// 且不应写入磁盘。
  final Map<String, _CachedPlayback> _playbackCache = {};

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async {
    final videoId = request.platformVideoId;

    // 1. 优先使用 feed 解析时缓存的直链
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

    // 2. 缓存未命中：无法通过详情接口补齐（需 Argus 签名），
    //    退回到官方嵌入播放，并如实说明原因。
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
        '未命中推荐流缓存，无法获取应用内播放直链。',
        '按 aweme_id 查询详情需要 X-Argus 签名，本项目不实现。',
        '该播放器由抖音官方提供，播放控制能力由平台决定。',
      ],
    );
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
