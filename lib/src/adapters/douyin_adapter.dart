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
import '../models/feed.dart';
import '../models/interaction.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'platform_adapter.dart';

class DouyinAdapter implements PlatformAdapter {
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
  bool get supportsComments => false;

  @override
  bool get supportsLike => false;

  @override
  bool get supportsCoin => false;

  @override
  bool get supportsFavorite => false;

  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    throw FusionException(
      code: FusionErrorCode.capabilityUnavailable,
      userMessage: '抖音评论当前不可用：该接口受平台风控保护。',
      technicalMessage:
          'douyin comments unavailable: reply endpoints are blocked by '
          'ArgusSecurityPlugin (403 before signature check).',
      platformId: id,
      retryable: false,
      diagnostics: const {'blockedBy': 'ArgusSecurityPlugin'},
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
        // 链接识别与短链展开可用
        supportsMetadata: false,
        // 无可用直链，不提供应用内播放
        supportsNativePlayback: false,
        // open.douyin.com/player/video 实测可嵌入
        supportsOfficialEmbed: true,
        supportsExternalFallback: true,
        requiresAuthForMetadata: true,
        requiresSignature: true,
        maxQualityWithoutAuth: null,
        notes: [
          '链接识别与短链展开已实现并通过真实网络验证。',
          '元数据获取被平台风控拦截：aweme/detail 返回 403 "Blocked by ArgusSecurityPlugin Uifid Not Found"，'
              '该拦截发生在签名校验之前，且需要服务端签发的 UIFID_TEMP Cookie。',
          '获取 UIFID_TEMP 需要驱动真实浏览器执行平台风控脚本，属于规避访问控制，本项目不实现。',
          '因此当前无法在应用内播放抖音视频，仅提供官方嵌入播放器与原平台跳转。',
          '本适配器不携带任何 Cookie、账号令牌或伪造设备指纹。',
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

  // ── 推荐流（当前不可用，如实声明）──────────────────────────

  /// 抖音推荐流在**未登录**环境下不可用。
  ///
  /// 实测证据（2026-10）：
  /// ```
  /// GET https://www.douyin.com/aweme/v1/web/tab/feed/?...
  /// → HTTP 200 但响应体长度为 0
  ///
  /// GET https://www.douyin.com/aweme/v1/web/module/feed/?...
  /// → HTTP 200 但响应体长度为 0
  /// ```
  /// 与 `aweme/detail` 相同，这些接口受 Argus 风控保护，
  /// 需要服务端签发的 `UIFID_TEMP` Cookie（只能由真实浏览器获取）。
  ///
  /// 因此这里**声明来源但标记为不可用**，让 UI 能够如实告知用户
  /// "抖音推荐流当前不可用"，而不是显示一个空列表让用户困惑。
  @override
  List<FeedSource> get feedSources => const [
        FeedSource(
          id: 'douyin:recommend',
          adapterId: 'douyin',
          label: '抖音推荐',
          description: '抖音 Web 推荐流。',
          requiresAuth: true,
          available: false,
          unavailableReason:
              '抖音推荐接口受平台风控保护（实测返回空响应），需要浏览器环境凭证，当前无法接入。',
        ),
      ];

  /// 抖音推荐流不可用：明确抛错，**不返回空列表**。
  ///
  /// 返回空列表会让"能力不可用"伪装成"当前没有内容"，
  /// 用户会误以为平台没视频，而不是接口被限制。必须抛错。
  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
  }) async {
    throw FusionException(
      code: FusionErrorCode.permissionDenied,
      userMessage: '抖音推荐流当前不可用：该接口受平台风控保护，需要浏览器环境凭证。',
      technicalMessage:
          'douyin feed unavailable (source=$sourceId): tab/feed and module/feed '
          'both return HTTP 200 with empty body, blocked by ArgusSecurityPlugin.',
      platformId: id,
      retryable: false,
      diagnostics: const {
        'blockedBy': 'ArgusSecurityPlugin',
        'requiredCookie': 'UIFID_TEMP',
        'testedEndpoints': [
          '/aweme/v1/web/tab/feed/',
          '/aweme/v1/web/module/feed/',
        ],
        'observedResponse': 'HTTP 200, body length 0',
      },
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

  // ── 播放源（仅官方嵌入）────────────────────────────────────

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async {
    // 应用内播放不可用：抖音未提供可用的公开直链接口。
    // 返回官方嵌入播放源，如实标注其能力边界。
    //
    // 实测：open.douyin.com/player/video 返回 200，
    // 无 X-Frame-Options / CSP frame-ancestors 限制。
    final embedUrl = 'https://open.douyin.com/player/video'
        '?vid=${Uri.encodeQueryComponent(request.platformVideoId)}'
        '&autoplay=0';

    return OfficialEmbedPlaybackSource(
      videoId: makeVideoId(id, request.platformVideoId),
      embedUrl: embedUrl,
      embedCapabilities: const EmbedCapabilities(
        hasBuiltInControls: true,
        supportsQualitySwitch: false,
        supportsPlaybackRate: false,
        refererSensitive: true,
        requiresLogin: false,
      ),
      embedNotes: const [
        '该播放器由抖音官方提供，播放控制能力由平台决定。',
        '本应用不为其添加倍速、清晰度等平台未声明支持的功能。',
        '若平台调整嵌入策略，此入口可能失效。',
      ],
    );
  }

  // ── 辅助 ───────────────────────────────────────────────────

  static String? _firstUrlFrom(Object? urlList) {
    if (urlList is List && urlList.isNotEmpty) {
      final first = urlList.first;
      if (first is String && first.isNotEmpty) return first;
    }
    return null;
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
}
