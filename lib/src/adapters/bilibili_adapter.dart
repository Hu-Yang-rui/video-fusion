/// 哔哩哔哩（B站）平台适配器。
///
/// ## 接口来源与合规说明
///
/// 本适配器使用的接口均为 B 站**公开 Web 端接口**，即普通浏览器访问
/// bilibili.com 时自身使用的接口，不需要任何账号凭证：
///
/// | 能力 | 接口 | 鉴权 |
/// |---|---|---|
/// | 视频元数据 | `/x/web-interface/view` | 无（公开） |
/// | 播放地址 | `/x/player/playurl` | 无（未登录降级到低清） |
/// | 短链展开 | `b23.tv` 302 | 无 |
///
/// **本适配器不携带任何 Cookie / SESSDATA / access_token，不调用需要登录的接口。**
///
/// ## 实测确认的能力边界（2026-02 实测，详见 docs/02-API可用性与权限调查报告.md）
///
///  - 未登录状态下 `playurl` 接口**声明**支持 [112,80,64,32,16]，但**实际下发**
///    的 DASH 流仅含 id=32(480P) 与 id=16(360P)。宣称值与实发值不一致，
///    因此本适配器**以实际下发的流为准**，不按 accept_quality 展示清晰度。
///  - DASH `.m4s` 直链**不需要 Referer**（实测无 Referer 返回 206，
///    `access-control-allow-origin: *`，ftyp 头正确）。
///  - MP4（fnval=1 的 durl）**需要 Referer**，无 Referer 返回 403。
///    因此本适配器优先使用 DASH。
library;

import '../core/errors.dart';
import '../core/credential_vault.dart';
import 'bilibili/im_client.dart';
import 'bilibili/im_emote_client.dart';
import 'bilibili/im_upload_client.dart';
import '../models/video_danmaku.dart';
import 'bilibili/wbi_signer.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../core/qr_login.dart';
import '../models/feed.dart';
import '../models/im.dart';
import '../models/interaction.dart';
import '../models/live.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'json_helpers.dart';
import 'platform_adapter.dart';

class BilibiliAdapter implements PlatformAdapter, QrLoginCapable, NumericVideoIdCapable {
  BilibiliAdapter({required FusionHttpClient http, FusionLogger? logger})
      : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _apiBase = 'https://api.bilibili.com';
  static const String _referer = 'https://www.bilibili.com/';

  /// 是否已经记录过 `reply_control` 的键名（只记一次，避免刷屏）。
  ///
  /// 用于验证"登录后平台是否开始下发 location"——见 [_replyToComment]。
  static bool _loggedReplyControlKeys = false;

  /// bvid → aid 的进程内缓存。
  ///
  /// # 为什么需要
  ///
  /// B 站的 `platformVideoId` 是 BV 号，但评论（`oid`）、收藏
  /// （`fav/resource/deal` 的 `rid`）等接口要的是数字 aid，必须多请求一次
  /// `/x/web-interface/view` 才能拿到。而**同一次打开视频页**里，
  /// 评论列表与收藏写入都会各自需要 aid；不缓存的话一个视频要重复打
  /// 2–3 次 view 接口，既慢又容易被限流。
  ///
  /// # 为什么可以缓存
  ///
  /// BV 号与 aid 是**一一对应且永不变更**的（B 站只是同一视频的两种
  /// ID 表示法，不会重指派），所以按 bvid 缓存到适配器生命周期内是安全的。
  /// 只缓存解析成功的结果：失败往往是网络或风控，缓存 null 会让
  /// 该视频在整个会话里再也拿不到 aid。
  final Map<String, int> _aidCache = {};

  /// `av123`/纯数字 → BV 号的缓存（BV↔aid 一成不变，可安全缓存）。
  ///
  /// 见 [_resolveBvid]：互动链路里"必须用 bvid"的接口都先过它，
  /// 否则从 av 号链接进来的视频会静默失去收藏/点赞能力。
  final Map<String, String> _bvidCache = {};

  /// wbi 签名器（懒加载，key 缓存 11h50m）。
  ///
  /// 直播弹幕的 `getDanmuInfo` 需要它；不带签名会返回 -352。
  late final WbiSigner _wbi = WbiSigner(http: _http, logger: _logger);

  /// 当前这次评论请求是否带了登录态。
  ///
  /// 只用于上面那条一次性诊断日志，让"登录前后"的差异在日志里
  /// 可区分——否则看到 keys 里没有 location 也无法判断是
  /// "没登录"还是"登录了但平台不给"。
  bool _currentRequestAuthenticated = false;

  /// 推荐流来源标识。
  static const String feedSourceRcmd = 'bilibili:rcmd';
  static const String feedSourcePopular = 'bilibili:popular';
  static const String feedSourceRanking = 'bilibili:ranking';

  @override
  List<FeedSource> get feedSources => const [
        FeedSource(
          id: feedSourceRcmd,
          adapterId: 'bilibili',
          label: '推荐',
          description: 'B 站首页推荐流（公开接口，无需登录）。',
        ),
        FeedSource(
          id: feedSourcePopular,
          adapterId: 'bilibili',
          label: '热门',
          description: 'B 站综合热门榜（公开接口，无需登录）。',
        ),
        FeedSource(
          id: feedSourceRanking,
          adapterId: 'bilibili',
          label: '排行榜',
          description: 'B 站全站排行榜（公开接口，无需登录）。',
        ),
      ];

  // ── 推荐流 ──────────────────────────────────────────────────

  /// 拉取推荐流。
  ///
  /// 实测确认（2026-10）：以下三个接口在**未登录**状态下均返回 `code=0`：
  ///  - `/x/web-interface/index/top/feed/rcmd` → 12 条，`goto=av`，含 bvid/cid
  ///  - `/x/web-interface/popular` → 12 条
  ///  - `/x/web-interface/ranking/v2` → 100 条
  ///
  /// 注意：推荐流**不返回** `dimension` 字段，因此宽高比未知，
  /// 由播放阶段从 playurl 的实际流获取。这里不凭空生成宽高。
  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
  }) async {
    return switch (sourceId) {
      feedSourceRcmd => _fetchRcmd(request),
      feedSourcePopular => _fetchPopular(request),
      feedSourceRanking => _fetchRanking(request),
      _ => throw FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage: '未知的推荐流来源。',
          technicalMessage: 'Unknown bilibili feed sourceId=$sourceId',
          platformId: id,
        ),
    };
  }

  Future<FeedPage> _fetchRcmd(FeedRequest request) async {
    // 实测（2026-10）：rcmd 的分页参数是 `fresh_idx`（刷新轮次），
    // 不是 offset。同一 fresh_idx 会返回同一批内容，
    // 因此必须用 offset 递增 fresh_idx 才能拿到新内容。
    final freshIdx = request.offset + request.freshIndex;

    final url = '$_apiBase/x/web-interface/index/top/feed/rcmd'
        '?ps=${request.safePageSize}'
        '&fresh_type=4'
        '&fresh_idx=$freshIdx'
        '&fresh_idx_1h=$freshIdx'
        '&feed_version=V8'
        '&homepage_ver=1'
        '&screen=1920-1080';

    final json = await _http.getJson(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );
    _assertApiOk(json, endpoint: '/x/web-interface/index/top/feed/rcmd');

    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '推荐流返回结构异常。',
        technicalMessage: 'rcmd data is ${data.runtimeType}',
        platformId: id,
      );
    }
    final d = Map<String, Object?>.from(data);
    final items = d['item'];
    if (items is! List) {
      return FeedPage(
        items: const [],
        hasMore: false,
        adapterId: id,
        upstreamEndpoint: '/x/web-interface/index/top/feed/rcmd',
        notes: const ['推荐流本次未返回条目。'],
      );
    }

    final videos = <UnifiedVideo>[];
    var skipped = 0;
    for (final raw in items) {
      if (raw is! Map) continue;
      final m = Map<String, Object?>.from(raw);
      final video = _feedItemToVideo(m,
          endpoint: '/x/web-interface/index/top/feed/rcmd');
      if (video != null) {
        videos.add(video);
      } else {
        // 非视频卡片（直播、广告、番剧等）如实跳过并计数，
        // 不伪造数据填充位置
        skipped++;
      }
    }

    return FeedPage(
      items: videos,
      hasMore: videos.isNotEmpty,
      adapterId: id,
      upstreamEndpoint: '/x/web-interface/index/top/feed/rcmd',
      nextOffset: request.offset + 1,
      notes: [
        if (skipped > 0) '本页跳过 $skipped 条非视频内容（直播/广告/番剧等）。',
      ],
    );
  }

  Future<FeedPage> _fetchPopular(FeedRequest request) async {
    final url = '$_apiBase/x/web-interface/popular'
        '?ps=${request.safePageSize}&pn=${request.offset + 1}';

    final json = await _http.getJson(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );
    _assertApiOk(json, endpoint: '/x/web-interface/popular');

    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '热门榜返回结构异常。',
        technicalMessage: 'popular data is ${data.runtimeType}',
        platformId: id,
      );
    }
    final d = Map<String, Object?>.from(data);
    final list = d['list'];
    if (list is! List) {
      return FeedPage(
        items: const [],
        hasMore: false,
        adapterId: id,
        upstreamEndpoint: '/x/web-interface/popular',
      );
    }

    final videos = <UnifiedVideo>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final video = _feedItemToVideo(Map<String, Object?>.from(raw),
          endpoint: '/x/web-interface/popular');
      if (video != null) videos.add(video);
    }

    final noMore = d['no_more'] == true;
    return FeedPage(
      items: videos,
      hasMore: !noMore && videos.isNotEmpty,
      adapterId: id,
      upstreamEndpoint: '/x/web-interface/popular',
      nextOffset: request.offset + 1,
    );
  }

  Future<FeedPage> _fetchRanking(FeedRequest request) async {    // 实测（2026-10）：`/x/web-interface/ranking/v2` 在当前网络环境下
    // 返回 `code=-352`（B 站风控拦截），且未登录时无法通过。
    // 这里改为使用 `/x/web-interface/ranking/region`（分区排行），
    // 该接口实测返回 code=0。若其亦被拦截，则如实抛错，不伪造空内容。
    const url = '$_apiBase/x/web-interface/ranking/region?rid=1&day=3';

    final json = await _http.getJson(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );

    // -352 是风控，不是普通业务错误，需要给出可区分的诊断
    if (json['code'] == -352) {
      throw FusionException(
        code: FusionErrorCode.rateLimited,
        userMessage: '排行榜接口被平台风控限制，暂时无法获取。',
        technicalMessage:
            'ranking/region returned code=-352 (risk control)',
        upstreamCode: -352,
        platformId: id,
        retryable: true,
        diagnostics: const {
          'blockedBy': 'bilibili risk control',
          'note': '该接口在部分网络环境下会被拦截，与登录状态无关。',
        },
      );
    }

    _assertApiOk(json, endpoint: '/x/web-interface/ranking/region');

    final data = json['data'];
    // 分区排行返回的是数组，不是 {list: []}
    final list = data is List ? data : (data is Map ? data['list'] : null);
    if (list is! List) {
      return FeedPage(
        items: const [],
        hasMore: false,
        adapterId: id,
        upstreamEndpoint: '/x/web-interface/ranking/region',
      );
    }

    final all = <UnifiedVideo>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      // 分区排行使用**扁平字段结构**，与 rcmd/popular 完全不同：
      //   author(字符串) / mid / play / video_review / favorites
      //   description / create(时间戳) / duration("49:20" 字符串)
      // 没有 owner / stat / pubdate / dimension。
      final video = _rankingItemToVideo(Map<String, Object?>.from(raw));
      if (video != null) all.add(video);
    }

    // 分页：该接口一次性返回全部条目，因此按请求的页大小做本地切片。
    // 注意 start/end 必须使用**同一个**页大小，否则会出现
    // "offset 递增但返回同一条"或跳过条目的错误。
    final size = request.safePageSize;
    final start = (request.offset * size).clamp(0, all.length);
    final end = (start + size).clamp(0, all.length);
    final slice = all.sublist(start, end);

    return FeedPage(
      items: slice,
      hasMore: end < all.length,
      adapterId: id,
      upstreamEndpoint: '/x/web-interface/ranking/region',
      nextOffset: request.offset + 1,
      notes: [
        if (all.isNotEmpty)
          '分区排行共 ${all.length} 条，本次返回第 ${start + 1}-$end 条。',
      ],
    );
  }

  // ── 搜索 ────────────────────────────────────────────────────

  @override
  bool get supportsSearch => true;

  /// 搜索视频。
  ///
  /// 实测确认（2026-10，未登录）：
  ///  - `/x/web-interface/search/type?search_type=video` → `code=0`，返回 result 数组
  ///  - 标题内含 `<em class="keyword">…</em>` 高亮标记，必须剥离
  ///  - 该接口**需要 WBI 签名**才能稳定返回；无签名时仍可返回，
  ///    但会被限流（HTTP 412）。因此这里对 412 做明确的限流提示。
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
        technicalMessage: 'Empty search query',
        platformId: id,
      );
    }

    final safePage = page.clamp(1, 50);
    final url = '$_apiBase/x/web-interface/search/type'
        '?search_type=video'
        '&keyword=${Uri.encodeQueryComponent(keyword)}'
        '&page=$safePage'
        '&page_size=${pageSize.clamp(1, 50)}';

    final result = await _http.get(
      url,
      headers: const {
        'Referer': _referer,
        'Accept': 'application/json, text/plain, */*',
      },
      platformId: id,
      acceptStatuses: const {200, 412},
    );

    // 412 = 平台风控限流，必须如实告知而不是返回空列表
    if (result.statusCode == 412) {
      throw FusionException(
        code: FusionErrorCode.rateLimited,
        userMessage: '搜索请求过于频繁，请稍后再试。',
        technicalMessage: 'bilibili search returned HTTP 412 (rate limited)',
        httpStatus: 412,
        platformId: id,
        retryable: true,
        diagnostics: const {
          'endpoint': '/x/web-interface/search/type',
          'hint': '该接口未签名时会被限流；需要 WBI 签名才能稳定访问。',
        },
      );
    }

    final json = result.jsonObject(platformId: id);
    _assertApiOk(json, endpoint: '/x/web-interface/search/type');

    final data = json['data'];
    if (data is! Map) {
      return FeedPage(
        items: const [],
        hasMore: false,
        adapterId: id,
        upstreamEndpoint: '/x/web-interface/search/type',
        nextOffset: safePage,
      );
    }

    final rawList = data['result'];
    final list = rawList is List ? rawList : const [];
    final numPages = (data['numPages'] as num?)?.toInt() ?? 0;
    final numResults = (data['numResults'] as num?)?.toInt() ?? 0;

    final items = <UnifiedVideo>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final video = _searchItemToVideo(Map<String, Object?>.from(raw));
      if (video != null) items.add(video);
    }

    return FeedPage(
      items: items,
      hasMore: numPages > 0 && safePage < numPages,
      adapterId: id,
      upstreamEndpoint: '/x/web-interface/search/type',
      nextOffset: safePage + 1,
      notes: [
        if (numResults > 0) '共找到约 $numResults 个结果，当前第 $safePage 页。',
      ],
    );
  }

  /// 解析搜索结果条目。
  ///
  /// 搜索结果的字段结构与推荐流不同：
  ///  - 标题含 `<em class="keyword">` 高亮标记，需要剥离
  ///  - 封面 URL 可能以 `//` 开头，需要补全协议
  ///  - 时长是 "MM:SS" 字符串
  UnifiedVideo? _searchItemToVideo(Map<String, Object?> item) {
    final bvid = _nullableString(item['bvid']);
    if (bvid == null) return null;
    if (!RegExp(r'^BV[0-9A-Za-z]{10}$').hasMatch(bvid)) return null;

    final mid = (item['mid'] as num?)?.toInt();
    final rawTitle = _stringOr(item['title'], '未命名视频');

    return UnifiedVideo(
      id: makeVideoId(id, bvid),
      platformId: id,
      platformVideoId: bvid,
      originalUrl: 'https://www.bilibili.com/video/$bvid',
      canonicalUrl: 'https://www.bilibili.com/video/$bvid',
      title: _stripSearchHighlight(rawTitle),
      description: _nullableString(item['description']),
      author: VideoAuthor(
        name: _nullableString(item['author']),
        platformAuthorId: mid?.toString(),
        profileUrl: mid != null ? 'https://space.bilibili.com/$mid' : null,
      ),
      coverUrl: _normalizeCoverUrl(_nullableString(item['pic'])),
      durationSeconds: _parseDurationString(item['duration']),
      aspectRatio: null,
      width: null,
      height: null,
      publishedAt: _epochToIso(item['pubdate']),
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: VideoStats(
        viewCount: _parseCountText(item['play']),
        likeCount: _parseCountText(item['like']),
        danmakuCount: _parseCountText(item['video_review']),
      ),
      availability: VideoAvailability.available,
      playbackModes: const [PlaybackMode.native, PlaybackMode.external],
      requiresAuth: false,
      diagnostics: VideoDiagnostics(
        adapterId: id,
        upstreamEndpoint: '/x/web-interface/search/type',
        fromCache: false,
        fetchDurationMs: 0,
        limitations: const ['搜索结果不返回视频宽高，画面比例在播放时确定。'],
        notes: const ['来自平台公开搜索接口。'],
      ),
    );
  }

  /// 剥离搜索结果标题中的 `<em class="keyword">…</em>` 高亮标记。
  static String _stripSearchHighlight(String raw) {
    // 平台用 <em> 包裹命中关键词，需要还原为纯文本
    final stripped = raw.replaceAll(RegExp(r'</?em[^>]*>'), '');
    // 还原 HTML 实体
    return stripped
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  /// 补全封面协议。搜索接口返回 `//i0.hdslb.com/...`。
  static String? _normalizeCoverUrl(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('//')) return 'https:$raw';
    if (raw.startsWith('http')) return raw;
    return raw;
  }

  /// 解析 "1.2万" / "1234" 形式的计数文本。
  static int? _parseCountText(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    final text = '$value'.trim();
    if (text.isEmpty || text == '-') return null;
    final match = RegExp(r'^([\d.]+)\s*([万亿]?)$').firstMatch(text);
    if (match == null) return null;
    final amount = double.tryParse(match.group(1)!);
    if (amount == null) return null;
    final unit = match.group(2);
    final multiplier = switch (unit) {
      '万' => 10000,
      '亿' => 100000000,
      _ => 1,
    };
    return (amount * multiplier).round();
  }

  /// 解析分区排行条目（扁平结构）。
  UnifiedVideo? _rankingItemToVideo(Map<String, Object?> item) {    final bvid = _nullableString(item['bvid']);
    if (bvid == null) return null;
    if (!RegExp(r'^BV[0-9A-Za-z]{10}$').hasMatch(bvid)) return null;

    final mid = (item['mid'] as num?)?.toInt();

    return UnifiedVideo(
      id: makeVideoId(id, bvid),
      platformId: id,
      platformVideoId: bvid,
      originalUrl: 'https://www.bilibili.com/video/$bvid',
      canonicalUrl: 'https://www.bilibili.com/video/$bvid',
      title: _stringOr(item['title'], '未命名视频'),
      description: _nullableString(item['description']),
      author: VideoAuthor(
        // 分区排行把作者名放在扁平的 author 字段
        name: _nullableString(item['author']),
        platformAuthorId: mid?.toString(),
        profileUrl: mid != null ? 'https://space.bilibili.com/$mid' : null,
      ),
      coverUrl: _nullableString(item['pic']),
      // duration 是 "49:20" 形式的字符串，需要解析
      durationSeconds: _parseDurationString(item['duration']),
      // 分区排行不返回 dimension
      aspectRatio: null,
      width: null,
      height: null,
      // ⚠️ 实测：分区排行的 `create` 是**日期字符串** `"2025-03-31 18:47"`，
      // 不是 epoch 秒。早期误用 _epochToIso（只接受 num）导致该来源的
      // publishedAt 恒为 null。这里改用专门的解析函数。
      publishedAt: _parseDateString(item['create']),
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: VideoStats(
        viewCount: (item['play'] as num?)?.toInt(),
        likeCount: null, // 该接口不返回点赞数
        danmakuCount: (item['video_review'] as num?)?.toInt(),
      ),
      availability: VideoAvailability.available,
      playbackModes: const [PlaybackMode.native, PlaybackMode.external],
      requiresAuth: false,
      diagnostics: const VideoDiagnostics(
        adapterId: 'bilibili',
        upstreamEndpoint: '/x/web-interface/ranking/region',
        fromCache: false,
        fetchDurationMs: 0,
        limitations: ['排行榜不返回视频宽高与点赞数。'],
        notes: ['来自平台公开分区排行榜。'],
      ),
    );
  }

  /// 解析 `"mm:ss"` / `"h:mm:ss"` 形式的时长字符串。
  static double? _parseDurationString(Object? value) {
    if (value is num) return normalizeDuration(value, isMilliseconds: false);
    final text = _nullableString(value);
    if (text == null) return null;
    final parts = text.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    var seconds = 0.0;
    for (final p in parts) {
      final n = int.tryParse(p.trim());
      if (n == null || n < 0) return null;
      seconds = seconds * 60 + n;
    }
    return seconds > 0 ? seconds : null;
  }

  /// 解析 `"2025-03-31 18:47"` 形式的日期字符串为 ISO 8601。
  ///
  /// 实测：B 站部分接口（如分区排行）用 `yyyy-MM-dd HH:mm` 字符串
  /// 而非 epoch 秒表示时间。缺失或格式不符时返回 null，不猜测。
  static String? _parseDateString(Object? value) {
    // 兼容数值型（部分接口确实返回 epoch）
    if (value is num) return _epochToIso(value);
    final text = _nullableString(value);
    if (text == null) return null;

    // `2025-03-31 18:47` 或 `2025-03-31 18:47:05`
    final normalized = text.contains(' ')
        ? text.replaceFirst(' ', 'T')
        : text;
    final parsed = DateTime.tryParse(normalized);
    if (parsed == null) return null;
    // 平台给出的是北京时间（UTC+8），转换为 UTC 存储
    final utc = parsed.isUtc
        ? parsed
        : DateTime.utc(
            parsed.year,
            parsed.month,
            parsed.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
          ).subtract(const Duration(hours: 8));
    return utc.toIso8601String();
  }

  /// 把推荐流条目标准化为 [UnifiedVideo]。
  ///
  /// 返回 null 表示该条目不是可播放的普通视频（直播、番剧、广告等），
  /// 由调用方如实跳过，**不得**用占位数据填充。
  ///
  /// 注意：不同来源的字段结构不一致，实测（2026-10）：
  ///  - `rcmd`     有 `goto='av'`，有 `bvid`
  ///  - `popular`  **没有 `goto` 字段**，但有 `bvid`、`dimension`、`desc`
  ///  - `ranking`  有 `goto`，但接口可能被风控拦截
  /// 因此这里**不依赖 `goto`**，改为以 `bvid` 是否存在作为唯一判据，
  /// 这样新增来源时无需再改解析逻辑。
  ///
  /// [endpoint] 由调用方传入，确保条目级诊断标注的是**真实来源接口**，
  /// 而不是固定写死为 rcmd。
  UnifiedVideo? _feedItemToVideo(
    Map<String, Object?> item, {
    required String endpoint,
  }) {
    final bvid = _nullableString(item['bvid']);
    if (bvid == null) return null;
    if (!RegExp(r'^BV[0-9A-Za-z]{10}$').hasMatch(bvid)) return null;

    // 若存在 goto 字段，只接受视频类型（排除直播等）
    final goto = _nullableString(item['goto']);
    if (goto != null && goto != 'av') return null;

    final owner = item['owner'] is Map
        ? Map<String, Object?>.from(item['owner'] as Map)
        : const <String, Object?>{};
    final stat = item['stat'] is Map
        ? Map<String, Object?>.from(item['stat'] as Map)
        : const <String, Object?>{};
    final mid = (owner['mid'] as num?)?.toInt();

    // rcmd 不返回 dimension；popular 返回。有则采用，无则保持 null。
    final dim = item['dimension'] is Map
        ? Map<String, Object?>.from(item['dimension'] as Map)
        : null;
    final width = (dim?['width'] as num?)?.toInt();
    final height = (dim?['height'] as num?)?.toInt();

    return UnifiedVideo(
      id: makeVideoId(id, bvid),
      platformId: id,
      platformVideoId: bvid,
      originalUrl: 'https://www.bilibili.com/video/$bvid',
      canonicalUrl: 'https://www.bilibili.com/video/$bvid',
      title: _stringOr(item['title'], '未命名视频'),
      description: _nullableString(item['desc']),
      author: VideoAuthor(
        name: _nullableString(owner['name']),
        platformAuthorId: mid?.toString(),
        profileUrl: mid != null ? 'https://space.bilibili.com/$mid' : null,
        avatarUrl: _nullableString(owner['face']),
      ),
      coverUrl: _nullableString(item['pic']),
      durationSeconds:
          normalizeDuration(item['duration'] as num?, isMilliseconds: false),
      aspectRatio: normalizeAspectRatio(width, height),
      width: width,
      height: height,
      publishedAt: _epochToIso(item['pubdate']),
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: VideoStats(
        viewCount: (stat['view'] as num?)?.toInt(),
        likeCount: (stat['like'] as num?)?.toInt(),
        danmakuCount: (stat['danmaku'] as num?)?.toInt(),
      ),
      availability: VideoAvailability.available,
      playbackModes: const [PlaybackMode.native, PlaybackMode.external],
      requiresAuth: false,
      diagnostics: VideoDiagnostics(
        adapterId: id,
        upstreamEndpoint: endpoint,
        fromCache: false,
        fetchDurationMs: 0,
        limitations: const [
          '推荐流不返回视频宽高，画面比例在播放时由实际流确定。',
        ],
        notes: const ['来自平台公开推荐流，非本系统算法生成。'],
      ),
    );
  }

  @override
  String get id => 'bilibili';

  @override
  String get displayName => '哔哩哔哩';

  @override
  String get shortLabel => 'B站';

  @override
  List<String> get supportedHosts => const [
        'bilibili.com',
        'www.bilibili.com',
        'm.bilibili.com',
        'b23.tv',
        'player.bilibili.com',
      ];

  @override
  AdapterCapabilities get capabilities => const AdapterCapabilities(
        supportsMetadata: true,
        supportsNativePlayback: true,
        supportsOfficialEmbed: true,
        supportsExternalFallback: true,
        requiresAuthForMetadata: false,
        requiresSignature: false,
        maxQualityWithoutAuth: '480P（未登录实测上限）',
        notes: [
          '元数据接口无需登录，公开可访问。',
          '应用内播放使用 DASH 分离流，播放时需携带 Referer（平台防盗链要求）。',
          '未登录时实测最高仅下发 480P；1080P+ 需登录账号，本系统不接入账号。',
          'playurl 返回的 accept_quality 高于实发流，本适配器以实发流为准。',
        ],
      );

  // ── 链接识别 ────────────────────────────────────────────────

  @override
  bool matches(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'b23.tv') return true;
    return host == 'bilibili.com' ||
        host.endsWith('.bilibili.com');
  }

  @override
  Future<LinkMatch?> extract(Uri uri) async {
    final host = uri.host.toLowerCase();
    final notes = <String>[];

    // 短链：需要展开
    if (host == 'b23.tv') {
      notes.add('识别为 b23.tv 短链，已展开重定向。');
      final target = await _http.resolveRedirect(uri.toString(), platformId: id);
      if (target == null) {
        throw FusionException(
          code: FusionErrorCode.videoIdNotFound,
          userMessage: '短链无法展开，请改用完整的视频链接。',
          technicalMessage: 'b23.tv redirect unresolved: ${Redactor.safeUrl(uri.toString())}',
          platformId: id,
        );
      }
      return extract(Uri.parse(target));
    }

    // 标准路径：/video/BVxxxx 或 /video/av123
    final segments = uri.pathSegments;
    final videoIndex = segments.indexOf('video');
    if (videoIndex >= 0 && videoIndex + 1 < segments.length) {
      final raw = segments[videoIndex + 1];
      final parsed = _parseVideoId(raw);
      if (parsed != null) {
        return LinkMatch(
          platformId: id,
          platformVideoId: parsed,
          canonicalUrl: 'https://www.bilibili.com/video/$parsed',
          notes: notes,
        );
      }
    }

    // 播放器嵌入链接：?bvid=BVxxx 或 ?aid=123
    final bvid = uri.queryParameters['bvid'];
    if (bvid != null && bvid.isNotEmpty) {
      final parsed = _parseVideoId(bvid);
      if (parsed != null) {
        return LinkMatch(
          platformId: id,
          platformVideoId: parsed,
          canonicalUrl: 'https://www.bilibili.com/video/$parsed',
          notes: [...notes, '从 bvid 查询参数识别。'],
        );
      }
    }
    final aid = uri.queryParameters['aid'];
    if (aid != null && int.tryParse(aid) != null) {
      final parsed = 'av$aid';
      return LinkMatch(
        platformId: id,
        platformVideoId: parsed,
        canonicalUrl: 'https://www.bilibili.com/video/$parsed',
        notes: [...notes, '从 aid 查询参数识别。'],
      );
    }

    // 动态/番剧等路径本阶段不接入，明确返回 null 而不是猜测
    return null;
  }

  /// 解析 BV 号 / av 号 / ep 号。只接受可验证的格式。
  static String? _parseVideoId(String raw) {
    final trimmed = raw.trim();
    // BV 号固定 12 位，以 BV1 开头
    final bvMatch = RegExp(r'^(BV[0-9A-Za-z]{10})$').firstMatch(trimmed);
    if (bvMatch != null) return bvMatch.group(1);
    // av 号
    final avMatch = RegExp(r'^av(\d+)$', caseSensitive: false).firstMatch(trimmed);
    if (avMatch != null) return 'av${avMatch.group(1)}';
    // 纯数字视为 aid
    final numMatch = RegExp(r'^(\d+)$').firstMatch(trimmed);
    if (numMatch != null) return 'av${numMatch.group(1)}';
    return null;
  }

  // ── 扫码登录 ────────────────────────────────────────────────

  /// 申请扫码登录二维码。
  ///
  /// 实测（2026-10）：
  /// ```
  /// GET passport.bilibili.com/x/passport-login/web/qrcode/generate
  /// → code=0, data.url = https://account.bilibili.com/h5/...&qrcode_key=...
  ///   data.qrcode_key = 32 字符
  /// ```
  /// `data.url` 就是要编码进二维码的字符串，由 APP 用纯 Dart 渲染，
  /// **不需要任何 web 组件**。
  @override
  Future<QrLoginChallenge> requestQrChallenge() async {
    const url =
        'https://passport.bilibili.com/x/passport-login/web/qrcode/generate';
    final json = await _http.getJson(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );

    final code = json['code'];
    if (code != 0) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '无法获取登录二维码，请稍后重试。',
        technicalMessage: 'qrcode/generate returned code=$code',
        upstreamCode: code,
        platformId: id,
      );
    }

    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '二维码接口返回结构异常。',
        technicalMessage: 'qrcode/generate data is ${data.runtimeType}',
        platformId: id,
      );
    }
    final d = Map<String, Object?>.from(data);
    final qrUrl = _nullableString(d['url']);
    final qrKey = _nullableString(d['qrcode_key']);

    if (qrUrl == null || qrKey == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '二维码接口未返回必要字段。',
        technicalMessage: 'qrcode/generate missing url or qrcode_key',
        platformId: id,
      );
    }

    return QrLoginChallenge(
      platformId: id,
      qrContent: qrUrl,
      challengeKey: qrKey,
      createdAt: DateTime.now(),
      expiresIn: const Duration(minutes: 3),
    );
  }

  /// 轮询扫码状态。
  ///
  /// 实测状态码：
  ///  - `86101` 未扫码
  ///  - `86090` 已扫码待确认
  ///  - `86038` 二维码已过期
  ///  - `0`     登录成功，响应头 `Set-Cookie` 携带会话凭证
  @override
  Future<QrLoginPollResult> pollQrChallenge(QrLoginChallenge challenge) async {
    final url = 'https://passport.bilibili.com/x/passport-login/web/qrcode/poll'
        '?qrcode_key=${Uri.encodeQueryComponent(challenge.challengeKey)}';

    // 用底层 get 以便读取 Set-Cookie 响应头
    final result = await _http.get(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    final data = json['data'];
    if (data is! Map) {
      return const QrLoginPollResult(
        phase: QrLoginPhase.failed,
        message: '登录状态接口返回结构异常。',
      );
    }
    final d = Map<String, Object?>.from(data);
    final stateCode = (d['code'] as num?)?.toInt();

    switch (stateCode) {
      case 86101:
        return const QrLoginPollResult(
          phase: QrLoginPhase.waitingForScan,
          message: '请使用哔哩哔哩手机客户端扫描二维码。',
        );
      case 86090:
        return const QrLoginPollResult(
          phase: QrLoginPhase.waitingForConfirm,
          message: '已扫码，请在手机上确认登录。',
        );
      case 86038:
        return const QrLoginPollResult(
          phase: QrLoginPhase.expired,
          message: '二维码已过期，请刷新后重试。',
        );
      case 0:
        final cookies = _extractCookies(result.headers);
        if (cookies.isEmpty) {
          return const QrLoginPollResult(
            phase: QrLoginPhase.failed,
            message: '登录成功但未收到会话凭证，请重试。',
          );
        }
        final profile = await _fetchLoginProfile(cookies);
        return QrLoginPollResult(
          phase: QrLoginPhase.succeeded,
          userId: profile.$1,
          displayName: profile.$2,
          username: profile.$3,
          avatarUrl: profile.$4,
          cookies: cookies,
          message: '登录成功。',
        );
      default:
        return QrLoginPollResult(
          phase: QrLoginPhase.failed,
          message: d['message'] != null
              ? '${d['message']}'
              : '登录失败（状态码 $stateCode）。',
        );
    }
  }

  /// 从 Set-Cookie 响应头提取会话 Cookie。
  ///
  /// 只提取平台会话必需的键，且**绝不记录取值**。
  Map<String, String> _extractCookies(Map<String, String> headers) {
    final raw = headers['set-cookie'];
    if (raw == null || raw.isEmpty) return const {};

    final out = <String, String>{};
    // 多个 Set-Cookie 可能被合并为一个字符串。按逗号切分需谨慎：
    // 只在 "键=值" 结构处切分，避免破坏 Expires 中的逗号。
    final parts = raw.split(RegExp(r',(?=\s*[A-Za-z_][A-Za-z0-9_]*=)'));
    for (final part in parts) {
      final first = part.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final key = first.substring(0, eq).trim();
      final value = first.substring(eq + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  /// 登录成功后查询账号信息。
  ///
  /// 返回 (userId, displayName, username, avatarUrl)。
  /// 查询失败不影响登录本身。
  Future<(String, String, String?, String?)> _fetchLoginProfile(
    Map<String, String> cookies,
  ) async {
    try {
      final cookieHeader =
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
      final json = await _http.getJson(
        '$_apiBase/x/web-interface/nav',
        headers: {
          'Referer': _referer,
          'Cookie': cookieHeader,
        },
        platformId: id,
      );
      final data = json['data'];
      if (data is Map) {
        final d = Map<String, Object?>.from(data);
        final mid = (d['mid'] as num?)?.toInt();
        return (
          mid?.toString() ?? '',
          _nullableString(d['uname']) ?? 'B站用户',
          _nullableString(d['uname']),
          _nullableString(d['face']),
        );
      }
    } catch (e) {
      // 账号信息查询失败不阻断登录流程；日志已脱敏
      _logger.warn('nav query failed after login', {
        'error': Redactor.scrubText('$e'),
      });
    }
    return ('', 'B站用户', null, null);
  }

  // ── 元数据 ──────────────────────────────────────────────────

  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async {
    final query = _videoIdQuery(match.platformVideoId);
    final url = '$_apiBase/x/web-interface/view?$query';
    final json = await _http.getJson(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );

    _assertApiOk(json, endpoint: '/x/web-interface/view');

    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '平台返回的元数据结构异常。',
        technicalMessage: 'view.data is not a Map',
        platformId: id,
      );
    }
    final d = Map<String, Object?>.from(data);

    final owner = d['owner'] is Map
        ? Map<String, Object?>.from(d['owner'] as Map)
        : const <String, Object?>{};
    final stat = d['stat'] is Map
        ? Map<String, Object?>.from(d['stat'] as Map)
        : const <String, Object?>{};
    final dimension = d['dimension'] is Map
        ? Map<String, Object?>.from(d['dimension'] as Map)
        : const <String, Object?>{};

    final width = (dimension['width'] as num?)?.toInt();
    final height = (dimension['height'] as num?)?.toInt();
    final mid = (owner['mid'] as num?)?.toInt();

    // 顺手把 aid 存进缓存：view 是公开接口且元数据阶段必然调用一次，
    // 之后评论（oid）与收藏写入（rid）就能直接复用，省掉重复的
    // bvid→aid 解析。见 [_aidCache]。
    _rememberAid(match.platformVideoId, d['aid']);

    // 分P：仅取第一 P 作为主视频（本阶段不实现分P切换）
    final pages = d['pages'];
    var cid = d['cid'];
    final notes = <String>[];
    if (pages is List && pages.isNotEmpty) {
      final first = pages.first;
      if (first is Map) {
        cid ??= first['cid'];
        if (pages.length > 1) {
          notes.add('该视频包含 ${pages.length} 个分P，当前仅接入第 1 P。');
        }
      }
    }

    final limitations = <String>[
      '应用内播放使用 DASH 分离流，未登录实测最高 480P。',
      '未接入登录，1080P 及以上清晰度不可用。',
    ];
    if (pages is List && pages.length > 1) {
      limitations.add('多分P视频当前仅播放第 1 P。');
    }

    return VideoMetadata(
      title: _stringOr(d['title'], '未命名视频'),
      description: _nullableString(d['desc']),
      author: VideoAuthor(
        name: _nullableString(owner['name']),
        platformAuthorId: mid?.toString(),
        profileUrl: mid != null ? 'https://space.bilibili.com/$mid' : null,
        avatarUrl: _nullableString(owner['face']),
      ),
      coverUrl: _nullableString(d['pic']),
      durationSeconds: normalizeDuration(d['duration'] as num?, isMilliseconds: false),
      width: width,
      height: height,
      publishedAt: _epochToIso(d['pubdate']),
      stats: VideoStats(
        viewCount: (stat['view'] as num?)?.toInt(),
        likeCount: (stat['like'] as num?)?.toInt(),
        danmakuCount: (stat['danmaku'] as num?)?.toInt(),
      ),
      availability: VideoAvailability.available,
      requiresAuth: false,
      limitations: limitations,
      notes: notes,
      upstreamEndpoint: '/x/web-interface/view',
    );
  }

  // ── 播放源解析 ──────────────────────────────────────────────

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async {
    // 先拿 cid：DASH 播放地址必须带 cid
    final cid = await _fetchCid(request.platformVideoId);
    if (cid == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '无法获取视频分P信息，暂时无法解析播放地址。',
        technicalMessage: 'cid missing for ${request.platformVideoId}',
        platformId: id,
      );
    }

    // fnval=16 请求 DASH（音视频分离）。
    // 注意：调用 playurl 接口本身需要 Referer（否则可能被拒），
    // 且返回的直链在播放时同样需要 Referer —— 见下方 requiredHeaders。
    final url = '$_apiBase/x/player/playurl'
        '?${_videoIdQuery(request.platformVideoId)}'
        '&cid=$cid&fnval=16&fnver=0&fourk=1&qn=120';

    final json = await _http.getJson(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );

    // 需要登录 / 权限不足的明确信号
    if (json['code'] == -403) {
      throw FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: '该视频需要登录或权限不足，无法获取播放地址。',
        technicalMessage: 'playurl code=-403',
        upstreamCode: -403,
        platformId: id,
      );
    }
    if (json['code'] == 87007 || json['code'] == 87008) {
      throw FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: '该视频为付费内容，当前无法获取播放地址。',
        technicalMessage: 'playurl code=${json['code']} (paid content)',
        upstreamCode: json['code'],
        platformId: id,
      );
    }

    _assertApiOk(json, endpoint: '/x/player/playurl');

    final data = json['data'];
    if (data is! Map) return null;
    final d = Map<String, Object?>.from(data);

    final dash = d['dash'];
    if (dash is Map) {
      final source = _buildDashSource(
        Map<String, Object?>.from(dash),
        request,
      );
      if (source != null) return source;
    }

    // DASH 不可用时退回 MP4（durl）。注意：durl 需要 Referer，播放器必须带上。
    final durl = d['durl'];
    if (durl is List && durl.isNotEmpty) {
      final first = durl.first;
      if (first is Map) {
        final m = Map<String, Object?>.from(first);
        final streamUrl = _nullableString(m['url']);
        if (streamUrl != null) {
          _logger.info('bilibili: falling back to MP4 durl (requires Referer)');
          return NativePlaybackSource(
            videoId: makeVideoId(id, request.platformVideoId),
            videoStreamUrl: streamUrl,
            requiredHeaders: const {
              'Referer': _referer,
              'User-Agent': kDefaultUserAgent,
            },
            quality: PlaybackQuality(
              platformQualityId: (d['quality'] as num?)?.toInt(),
              label: _qualityLabel((d['quality'] as num?)?.toInt()),
            ),
            isDash: false,
          );
        }
      }
    }

    return null;
  }

  /// 从 DASH 数据构建播放源。
  ///
  /// 关键决策（基于实测）：**只使用接口实际下发的流**，
  /// 不使用 accept_quality 宣称但未下发的清晰度。
  NativePlaybackSource? _buildDashSource(
    Map<String, Object?> dash,
    PlaybackRequest request,
  ) {
    final videos = dash['video'];
    final audios = dash['audio'];
    if (videos is! List || videos.isEmpty) return null;

    final videoStreams = videos
        .whereType<Map>()
        .map((e) => Map<String, Object?>.from(e))
        .toList();
    if (videoStreams.isEmpty) return null;

    // 优先 AVC（H.264）：兼容性最好，libmpv 与硬件解码均支持。
    // HEVC 虽然码率更低，但部分环境解码不可靠。
    final avc = videoStreams.where((s) {
      final codec = _nullableString(s['codecs']) ?? '';
      return codec.startsWith('avc');
    }).toList();

    final candidates = avc.isNotEmpty ? avc : videoStreams;

    // 在候选内按清晰度 id 降序（数字越大越清晰）
    candidates.sort((a, b) {
      final ai = (a['id'] as num?)?.toInt() ?? 0;
      final bi = (b['id'] as num?)?.toInt() ?? 0;
      return bi.compareTo(ai);
    });

    final chosen = candidates.first;
    // 实测：每条流都附带 2 个 backupUrl，且均可访问。
    // baseUrl 指向的 CDN 节点可能单独失效（实测出现过 404），
    // 因此这里收集完整候选链，而不是只用 baseUrl。
    final videoUrls = _collectStreamUrls(chosen);
    if (videoUrls.isEmpty) return null;
    final streamUrl = videoUrls.first;

    // 音轨：选择最低码率以节省带宽（人声/音乐在低码率下已足够）
    String? audioUrl;
    var audioFallbacks = const <String>[];
    if (audios is List && audios.isNotEmpty) {
      final audioStreams = audios
          .whereType<Map>()
          .map((e) => Map<String, Object?>.from(e))
          .toList()
        ..sort((a, b) {
          final ab = (a['bandwidth'] as num?)?.toInt() ?? 0;
          final bb = (b['bandwidth'] as num?)?.toInt() ?? 0;
          return ab.compareTo(bb);
        });
      if (audioStreams.isNotEmpty) {
        final audioUrls = _collectStreamUrls(audioStreams.first);
        if (audioUrls.isNotEmpty) {
          audioUrl = audioUrls.first;
          audioFallbacks = audioUrls.skip(1).toList();
        }
      }
    }

    final availableQualities = candidates
        .map((s) => PlaybackQuality(
              platformQualityId: (s['id'] as num?)?.toInt(),
              label: _qualityLabel((s['id'] as num?)?.toInt()),
              width: (s['width'] as num?)?.toInt(),
              height: (s['height'] as num?)?.toInt(),
              codec: _nullableString(s['codecs']),
              bandwidth: (s['bandwidth'] as num?)?.toInt(),
            ))
        .toList();

    final chosenId = (chosen['id'] as num?)?.toInt();

    return NativePlaybackSource(
      videoId: makeVideoId(id, request.platformVideoId),
      videoStreamUrl: streamUrl,
      audioStreamUrl: audioUrl,
      videoFallbackUrls: videoUrls.skip(1).toList(),
      audioFallbackUrls: audioFallbacks,
      // ⚠️ 实测（2026-10 复测）：B 站 CDN 已对 DASH 流启用防盗链。
      // 无 Referer 请求全部返回 403，带 Referer 返回 206 且 ftyp 头正确。
      // 因此必须把 Referer 传给播放内核（libmpv 支持自定义请求头）。
      requiredHeaders: const {
        'Referer': _referer,
        'User-Agent': kDefaultUserAgent,
      },
      quality: PlaybackQuality(
        platformQualityId: chosenId,
        label: _qualityLabel(chosenId),
        width: (chosen['width'] as num?)?.toInt(),
        height: (chosen['height'] as num?)?.toInt(),
        codec: _nullableString(chosen['codecs']),
        bandwidth: (chosen['bandwidth'] as num?)?.toInt(),
      ),
      availableQualities: availableQualities,
      isDash: audioUrl != null,
    );
  }

  Future<int?> _fetchCid(String videoId) async {
    final url = '$_apiBase/x/web-interface/view?${_videoIdQuery(videoId)}';
    final json = await _http.getJson(
      url,
      headers: const {'Referer': _referer},
      platformId: id,
    );
    _assertApiOk(json, endpoint: '/x/web-interface/view');
    final data = json['data'];
    if (data is! Map) return null;
    final d = Map<String, Object?>.from(data);
    // 同样回填 aid 缓存：播放解析也会打一次 view。
    _rememberAid(videoId, d['aid']);
    final cid = d['cid'];
    if (cid is num) return cid.toInt();
    final pages = d['pages'];
    if (pages is List && pages.isNotEmpty) {
      final first = pages.first;
      if (first is Map) {
        final c = first['cid'];
        if (c is num) return c.toInt();
      }
    }
    return null;
  }


  // ── 直播 ────────────────────────────────────────────────────
  //
  // 端点实测（2026-10，未登录）：
  //  - 列表 room/v3/area/getRoomList          → code=0，16754 个房间
  //  - 详情 room/v1/Room/get_info             → code=0，含 live_status
  //  - 播放 xlive/web-room/v2/.../getRoomPlayInfo → FLV + HLS，5 档清晰度
  //  - 弹幕 xlive/web-room/v1/index/getDanmuInfo → token + wss 地址
  //
  // 注意：xlive/web-interface/v1/second/getList 返回 -352（风控），
  // 不可用，因此列表走 room/v3/area/getRoomList。

  static const String _liveApiBase = 'https://api.live.bilibili.com';
  static const String _liveReferer = 'https://live.bilibili.com/';

  @override
  bool get supportsLive => true;

  @override
  Future<LiveRoomPage> fetchLiveRooms({
    int page = 1,
    int pageSize = 20,
    int? parentAreaId,
    int? areaId,
  }) async {
    final safePage = page < 1 ? 1 : page;
    final safeSize = pageSize.clamp(1, 30);

    final url = '$_liveApiBase/room/v3/area/getRoomList'
        '?platform=web'
        '&parent_area_id=${parentAreaId ?? 0}'
        '&area_id=${areaId ?? 0}'
        '&sort_type=online'
        '&page=$safePage'
        '&page_size=$safeSize';

    final result = await _http.get(
      url,
      headers: const {
        'Referer': _liveReferer,
        'Accept': 'application/json',
      },
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    _assertApiOk(json, endpoint: '/room/v3/area/getRoomList');

    final data = json['data'];
    if (data is! Map) {
      return LiveRoomPage(items: const [], page: safePage, hasMore: false);
    }
    final d = Map<String, Object?>.from(data);
    final rawList = d['list'];
    final total = (d['count'] as num?)?.toInt() ?? 0;

    final items = <LiveRoomSummary>[];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final m = Map<String, Object?>.from(raw);
        final roomId = (m['roomid'] as num?)?.toInt();
        if (roomId == null) continue;
        items.add(
          LiveRoomSummary(
            roomId: roomId,
            title: _nullableString(m['title']) ?? '直播间 $roomId',
            uname: _nullableString(m['uname']) ?? '未知主播',
            coverUrl: _nullableString(m['cover']) ??
                _nullableString(m['user_cover']),
            faceUrl: _nullableString(m['face']),
            online: (m['online'] as num?)?.toInt(),
            areaName: _nullableString(m['area_v2_name']) ??
                _nullableString(m['area_name']),
            parentAreaName: _nullableString(m['area_v2_parent_name']) ??
                _nullableString(m['parent_name']),
            uid: (m['uid'] as num?)?.toInt(),
          ),
        );
      }
    }

    return LiveRoomPage(
      items: items,
      page: safePage,
      hasMore: items.isNotEmpty && safePage * safeSize < total,
      totalCount: total,
      notes: [
        if (total > 0) '共 $total 个直播间。',
      ],
    );
  }

  @override
  Future<List<LiveArea>> fetchLiveAreas() async {
    final result = await _http.get(
      '$_liveApiBase/room/v1/Area/getList?show_pinyin=1',
      headers: const {
        'Referer': _liveReferer,
        'Accept': 'application/json',
      },
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    _assertApiOk(json, endpoint: '/room/v1/Area/getList');

    final data = json['data'];
    if (data is! List) return const [];

    final areas = <LiveArea>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final m = Map<String, Object?>.from(raw);
      final areaId = (m['id'] as num?)?.toInt();
      final name = _nullableString(m['name']);
      if (areaId == null || name == null) continue;

      final children = <LiveArea>[];
      final subs = m['list'];
      if (subs is List) {
        for (final sub in subs) {
          if (sub is! Map) continue;
          final sm = Map<String, Object?>.from(sub);
          // 注意：一级分区的 id 是数字，但二级分区的 id 是**字符串**。
          // 实测 2026-10：{"id":"86","parent_id":"2","name":"英雄联盟"}
          final sid = _toInt(sm['id']);
          final sname = _nullableString(sm['name']);
          if (sid == null || sname == null) continue;
          children.add(LiveArea(id: sid, name: sname));
        }
      }

      areas.add(LiveArea(id: areaId, name: name, children: children));
    }
    return areas;
  }

  @override
  Future<LiveRoomInfo> fetchLiveRoomInfo(int roomId) async {
    final result = await _http.get(
      '$_liveApiBase/room/v1/Room/get_info?room_id=$roomId',
      headers: const {
        'Referer': _liveReferer,
        'Accept': 'application/json',
      },
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    _assertApiOk(json, endpoint: '/room/v1/Room/get_info');
    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.videoNotFound,
        userMessage: '直播间不存在。',
        technicalMessage: 'get_info returned no data for room $roomId',
        platformId: id,
      );
    }
    final d = Map<String, Object?>.from(data);

    final startTime = _toInt(d['live_time']);

    // 注意：get_info 的字段类型不统一。
    // 实测 2026-10：`live_status` 返回的是**字符串** "1"，
    // 而 `room_id` / `uid` 是数字。直接 `as num?` 会抛
    // "type 'String' is not a subtype of type 'num?'"，
    // 导致所有直播间都查不出状态。统一走 _toInt 兼容两种类型。
    return LiveRoomInfo(
      roomId: _toInt(d['room_id']) ?? roomId,
      shortId: _toInt(d['short_id']) ?? 0,
      uid: _toInt(d['uid']) ?? 0,
      title: _nullableString(d['title']) ?? '直播间 $roomId',
      liveStatus: _toInt(d['live_status']) ?? 0,
      online: _toInt(d['online']),
      description: _nullableString(d['description']),
      coverUrl: _nullableString(d['user_cover']) ??
          _nullableString(d['keyframe']),
      keyframeUrl: _nullableString(d['keyframe']),
      areaName: _nullableString(d['area_name']),
      parentAreaName: _nullableString(d['parent_area_name']),
      tags: _nullableString(d['tags']),
      liveStartTime: startTime != null && startTime > 0
          ? _epochToIso(startTime)
          : null,
    );
  }

  @override
  Future<LiveStream> resolveLiveStream(int roomId, {int? quality}) async {
    final qn = quality ?? 10000;
    final url = '$_liveApiBase/xlive/web-room/v2/index/getRoomPlayInfo'
        '?room_id=$roomId'
        '&protocol=0,1'
        '&format=0,1,2'
        '&codec=0,1'
        '&qn=$qn'
        '&platform=web'
        '&ptype=8';

    final result = await _http.get(
      url,
      headers: const {
        'Referer': _liveReferer,
        'Accept': 'application/json',
      },
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    _assertApiOk(json, endpoint: '/xlive/web-room/v2/index/getRoomPlayInfo');

    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '该直播间暂无可播放的流。',
        technicalMessage: 'playurl_info missing for room $roomId',
        platformId: id,
      );
    }
    final d = Map<String, Object?>.from(data);

    // 未开播：平台不会给流地址
    final liveStatus = (d['live_status'] as num?)?.toInt() ?? 0;
    final playurlInfo = d['playurl_info'];
    if (playurlInfo is! Map) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: liveStatus == 0
            ? '主播尚未开播，暂时无法观看。'
            : '该直播间当前无法获取播放地址。',
        technicalMessage:
            'playurl_info is null (live_status=$liveStatus, room=$roomId)',
        platformId: id,
        retryable: liveStatus == 0,
      );
    }

    final streams = Map<String, Object?>.from(playurlInfo)['playurl'];
    if (streams is! Map) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '该直播间暂无可播放的流。',
        technicalMessage: 'playurl missing',
        platformId: id,
      );
    }

    final rawStreams = Map<String, Object?>.from(streams)['stream'];
    if (rawStreams is! List || rawStreams.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '该直播间暂无可播放的流。',
        technicalMessage: 'stream list empty',
        platformId: id,
      );
    }

    // 优先 HLS（断线重连更稳），否则回退 FLV
    LiveStream? best;
    for (final rawStream in rawStreams) {
      if (rawStream is! Map) continue;
      final sm = Map<String, Object?>.from(rawStream);
      final protocolName = _nullableString(sm['protocol_name']) ?? '';
      final formats = sm['format'];
      if (formats is! List) continue;

      for (final rawFormat in formats) {
        if (rawFormat is! Map) continue;
        final fm = Map<String, Object?>.from(rawFormat);
        final formatName = _nullableString(fm['format_name']) ?? '';
        final codecs = fm['codec'];
        if (codecs is! List) continue;

        for (final rawCodec in codecs) {
          if (rawCodec is! Map) continue;
          final cm = Map<String, Object?>.from(rawCodec);
          final codecName = _nullableString(cm['codec_name']) ?? '';
          // 优先 avc：兼容性最好，模拟器与老设备都能解
          if (codecName != 'avc') continue;

          final candidate = _buildLiveStream(
            cm,
            protocolName: protocolName,
            formatName: formatName,
            codecName: codecName,
          );
          if (candidate == null) continue;

          // HLS 优先
          if (best == null ||
              (candidate.isHls && !best.isHls)) {
            best = candidate;
          }
        }
      }
    }

    if (best == null) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '该直播间的流格式不受支持。',
        technicalMessage: 'no avc stream found among $rawStreams.length streams',
        platformId: id,
      );
    }

    return best;
  }

  /// 由 codec 节点拼出完整播放地址。
  ///
  /// B 站把地址拆成三段：host + base_url + extra，
  /// 直接拼接即可，**不能**再补问号（base_url 已自带）。
  LiveStream? _buildLiveStream(
    Map<String, Object?> codec, {
    required String protocolName,
    required String formatName,
    required String codecName,
  }) {
    final urlInfo = codec['url_info'];
    if (urlInfo is! List || urlInfo.isEmpty) return null;

    final host = _nullableString(
      urlInfo.first is Map
          ? Map<String, Object?>.from(urlInfo.first as Map)['host']
          : null,
    );
    final extra = _nullableString(
      urlInfo.first is Map
          ? Map<String, Object?>.from(urlInfo.first as Map)['extra']
          : null,
    );
    final baseUrl = _nullableString(codec['base_url']);
    if (host == null || baseUrl == null) return null;

    final fullUrl = '$host$baseUrl${extra ?? ''}';

    // 清晰度档位
    final acceptQn = codec['accept_qn'];
    final currentQn = (codec['current_qn'] as num?)?.toInt() ?? 0;
    final qualities = <LiveStream>[];
    if (acceptQn is List) {
      for (final raw in acceptQn) {
        final q = (raw as num?)?.toInt();
        if (q == null) continue;
        qualities.add(
          LiveStream(
            url: fullUrl,
            protocolName: protocolName,
            formatName: formatName,
            codecName: codecName,
            qualityLabel: _liveQualityLabel(q),
            qualityValue: q,
          ),
        );
      }
    }

    return LiveStream(
      url: fullUrl,
      protocolName: protocolName,
      formatName: formatName,
      codecName: codecName,
      qualityLabel: _liveQualityLabel(currentQn),
      qualityValue: currentQn,
      availableQualities: qualities,
    );
  }

  static String _liveQualityLabel(int qn) => switch (qn) {
        30000 => '杜比',
        20000 => '4K',
        10000 => '原画',
        400 => '蓝光',
        250 => '超清',
        150 => '高清',
        _ => '流畅',
      };

  /// 按字符串房间号取详情。
  ///
  /// B站的房间号是数字，这里直接转成 int 后走原有实现。
  /// 显式覆盖是为了让编译器确认"该平台已实现直播"，而不是靠
  /// 抽象类的默认抛错。
  @override
  Future<LiveRoomInfo> fetchLiveRoomInfoByKey(String roomKey) {
    final numeric = int.tryParse(roomKey);
    if (numeric == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '直播间号无效。',
        technicalMessage: 'bilibili roomKey "$roomKey" is not numeric',
        platformId: id,
      );
    }
    return fetchLiveRoomInfo(numeric);
  }

  /// 按字符串房间号解析播放流。B站房间号是数字，直接转发。
  @override
  Future<LiveStream> resolveLiveStreamByKey(
    String roomKey, {
    int? quality,
  }) {
    final numeric = int.tryParse(roomKey);
    if (numeric == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '直播间号无效。',
        technicalMessage: 'bilibili roomKey "$roomKey" is not numeric',
        platformId: id,
      );
    }
    return resolveLiveStream(numeric, quality: quality);
  }

  /// 获取弹幕服务器连接参数。
  ///
  /// # 必须带 wbi 签名（v1.11.0 修正）
  ///
  /// 这个接口**需要 wbi 签名**，不带会返回 `code = -352`。
  ///
  /// 本项目此前把 -352 误判为"需要登录"，实测证明不是：
  /// 加上 wbi 签名后 `code = 0`，**匿名即可拿到 token 与 host_list**。
  ///
  /// 参考实现：xfgryujk/blivedm 的 `clients/web.py`
  /// （`add_wbi_sign({'id': room_id, 'type': 0})`），
  /// 其代码注释也明确写着 `code == -352` 是 "wbi签名错误"。
  ///
  /// 拿到 token 后用它做弹幕协议认证包（op=7）的 `key` 字段，
  /// 服务端返回 `{"code":0}` 即认证成功，随后推 op=5 业务包。
  @override
  Future<LiveDanmakuEndpoint> fetchLiveDanmakuEndpoint(int roomId) async {
    // 先签一次；若服务端仍返回 -352，说明 key 过期，刷新后重试一次。
    var signedQuery = await _wbi.sign({'id': roomId, 'type': 0});
    var result = await _http.get(
      '$_liveApiBase/xlive/web-room/v1/index/getDanmuInfo?$signedQuery',
      headers: const {
        'Referer': _liveReferer,
        'Accept': 'application/json',
      },
      platformId: id,
      acceptStatuses: const {200},
    );
    var json = result.jsonObject(platformId: id);

    if ((json['code'] as num?)?.toInt() == -352) {
      _logger.info('danmaku: -352, refreshing wbi key and retrying');
      _wbi.invalidate();
      signedQuery = await _wbi.sign({'id': roomId, 'type': 0});
      result = await _http.get(
        '$_liveApiBase/xlive/web-room/v1/index/getDanmuInfo?$signedQuery',
        headers: const {
          'Referer': _liveReferer,
          'Accept': 'application/json',
        },
        platformId: id,
        acceptStatuses: const {200},
      );
      json = result.jsonObject(platformId: id);
    }

    _assertApiOk(json, endpoint: '/xlive/web-room/v1/index/getDanmuInfo');

    final data = json['data'];
    if (data is! Map) {
      throw FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: '无法连接该直播间的弹幕服务器。',
        technicalMessage: 'getDanmuInfo returned no data',
        platformId: id,
      );
    }
    final d = Map<String, Object?>.from(data);
    final token = _nullableString(d['token']) ?? '';

    final hosts = <String>[];
    final rawHosts = d['host_list'];
    if (rawHosts is List) {
      for (final raw in rawHosts) {
        if (raw is! Map) continue;
        final hm = Map<String, Object?>.from(raw);
        final host = _nullableString(hm['host']);
        final port = (hm['wss_port'] as num?)?.toInt() ?? 443;
        if (host == null) continue;
        hosts.add('wss://$host:$port/sub');
      }
    }

    if (hosts.isEmpty) {
      // 官方公布的兜底地址
      hosts.add('wss://broadcastlv.chat.bilibili.com:443/sub');
    }

    return LiveDanmakuEndpoint(
      token: token,
      hostList: hosts,
      roomId: roomId,
      uid: 0,
    );
  }

  // ── 视频内弹幕 ──────────────────────────────────────────────
  //
  // # 与直播弹幕的区别
  //
  // `fetchLiveDanmakuEndpoint` 拿的是**直播间实时弹幕流**的连接参数
  // （wss + token），要自己维护长连接。
  //
  // 这里拿的是**点播视频时间轴上的弹幕**，一次 HTTP 拿一段，
  // 用于在播放器上叠加显示。两者接口、协议、生命周期都不同。
  //
  // # 接口选择（实测本轮，真实视频 BV1GJ411x7h7 / cid=137649199）
  //
  // | 接口 | 结果 |
  // |---|---|
  // | `/x/v2/dm/web/seg.so?type=1&oid={cid}&pid={aid}&segment_index=N` | 200 / 163,551 字节 |
  // | `/x/v1/dm/list.so?oid={cid}`（旧版 XML） | 200 / 108,364 字节 |
  //
  // 两者内容一致。本实现**只用 protobuf**：
  //  - XML 的 `<d p="...">` 是位置耦合的（第 1 个字段是时间、第 2 个是模式…），
  //    平台改一下顺序就全错位
  //  - protobuf 是字段号耦合，加字段不影响已有字段
  //
  // # 分段语义
  //
  // 按视频时长切段，**每段 6 分钟（360 秒）**，`segment_index` 从 1 开始。
  // 实测 `segment_index` 是必需参数，缺了返回空。
  // 因此必须知道时长才能拉全——调用方从 `VideoMetadata.durationSeconds` 传。

  @override
  bool get supportsVideoDanmaku => true;

  @override
  Future<List<VideoDanmaku>> fetchVideoDanmaku(
    String platformVideoId, {
    double? durationSeconds,
    double? fromSeconds,
    double? toSeconds,
  }) async {
    // 弹幕接口的 `oid` 是 **cid**（不是 aid，也不是 bvid）。
    // view 接口的响应里 cid 是**第一 P** 的 cid；多 P 视频要按分 P 取，
    // 本方法只覆盖第一 P——多 P 的 cid 需要调用方另传，这里如实说明。
    final cid = await _resolveCid(platformVideoId);
    if (cid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '无法解析该视频的分区 ID，暂时无法加载弹幕。',
        technicalMessage: 'Cannot resolve cid for $platformVideoId',
        platformId: id,
      );
    }

    final aid = await _resolveAid(platformVideoId);
    final segments = danmakuSegmentCount(durationSeconds);

    final collected = <VideoDanmaku>[];
    final seen = <String>{};

    for (var index = 1; index <= segments; index++) {
      final url = '$_apiBase/x/v2/dm/web/seg.so'
          '?type=1&oid=$cid'
          '${aid != null ? '&pid=$aid' : ''}'
          '&segment_index=$index';

      final result = await _http.get(
        url,
        headers: {
          'Referer': '$_referer/video/$platformVideoId',
          'Accept': '*/*',
        },
        platformId: id,
        acceptStatuses: const {200, 304},
        keepRawBytes: true,
      );

      // 304 = 该段没有弹幕（平台用这个表示空段，而不是返回空体）。
      if (result.statusCode == 304) continue;

      final bytes = result.rawBytes;
      if (bytes == null || bytes.isEmpty) continue;

      DanmakuSegment parsed;
      try {
        parsed = parseDanmakuSegment(bytes, segmentIndex: index);
      } on FormatException catch (e) {
        // 单段解析失败不该让整次调用失败：记录后继续拉下一段。
        // 但如果**所有**段都失败，下面会因为结果为空而报错。
        _logger.warn('video danmaku: segment parse failed', {
          'cid': cid,
          'segment': index,
          'bytes': bytes.length,
          'error': e.message,
        });
        continue;
      }

      for (final item in parsed.items) {
        if (seen.add(item.id)) collected.add(item);
      }
    }

    if (collected.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音返回了无法解析的弹幕数据。',
        technicalMessage: 'video danmaku: all $segments segment(s) empty or '
            'unparsable for cid=$cid (duration=$durationSeconds)',
        platformId: id,
        retryable: true,
        diagnostics: {
          'cid': cid,
          'aid': aid,
          'segments': segments,
        },
      );
    }

    // 按时间排序：播放器要顺序消费。
    collected.sort((a, b) => a.progressMs.compareTo(b.progressMs));

    // 时间区间过滤（可选）。
    if (fromSeconds == null && toSeconds == null) return collected;
    final fromMs = ((fromSeconds ?? 0) * 1000).round();
    final toMs = toSeconds == null ? null : (toSeconds * 1000).round();
    return collected
        .where((d) =>
            d.progressMs >= fromMs && (toMs == null || d.progressMs <= toMs))
        .toList(growable: false);
  }

  /// cid 缓存（弹幕接口按 cid 取，同一视频会反复用到）。
  final Map<String, int> _cidCache = {};

  /// 解析视频的 cid（第一 P）。
  ///
  /// 与 [_resolveAid] 共用同一次 view 请求的结果，但分开缓存：
  /// aid 与 cid 是两个不同用途的标识，混在一个 map 里会误导。
  Future<int?> _resolveCid(String platformVideoId) async {
    final cached = _cidCache[platformVideoId];
    if (cached != null) return cached;

    final json = await _http.getJson(
      '$_apiBase/x/web-interface/view?${_videoIdQuery(platformVideoId)}',
      headers: const {'Referer': _referer, 'Accept': 'application/json'},
      platformId: id,
    );
    if ((json['code'] as num?)?.toInt() != 0) return null;
    final data = json['data'];
    if (data is! Map) return null;
    final cid = (Map<String, Object?>.from(data)['cid'] as num?)?.toInt();
    if (cid == null) return null;
    _cidCache[platformVideoId] = cid;
    return cid;
  }

  // ── 辅助 ────────────────────────────────────────────────────

  String _videoIdQuery(String videoId) {
    if (videoId.startsWith('BV')) return 'bvid=$videoId';
    if (videoId.startsWith('av')) return 'aid=${videoId.substring(2)}';
    return 'bvid=$videoId';
  }

  /// B 站业务错误码 → 统一错误码。
  void _assertApiOk(
    Map<String, Object?> json, {
    required String endpoint,
    FusionErrorCode? badRequestCode,
    String? badRequestMessage,
  }) {
    final code = json['code'];
    if (code == 0) return;
    final message = _nullableString(json['message']) ?? '';

    final FusionErrorCode mapped;
    final String userMessage;
    switch (code) {
      case -404:
        mapped = FusionErrorCode.videoNotFound;
        userMessage = '视频不存在或已被删除。';
      case -403:
        mapped = FusionErrorCode.permissionDenied;
        userMessage = '该视频需要登录或权限不足。';
      case -400:
        // -400 的语义取决于接口：
        //  - 视频接口：bvid 参数不合法 → invalidUrl
        //  - 收藏/账号接口：缺少有效登录态 → loginRequired
        // 因此允许调用方覆盖，避免把"未登录"误报成"链接无效"。
        mapped = badRequestCode ?? FusionErrorCode.invalidUrl;
        userMessage = badRequestMessage ?? '请求参数无效，视频 ID 可能不正确。';
      case -412:
        mapped = FusionErrorCode.rateLimited;
        userMessage = '请求被平台限流，请稍后再试。';
      case -509:
        mapped = FusionErrorCode.rateLimited;
        userMessage = '请求过于频繁，请稍后再试。';
      case 62002:
        mapped = FusionErrorCode.permissionDenied;
        userMessage = '该视频为私有或已被 UP 主设为不可见。';
      case 62004:
        mapped = FusionErrorCode.permissionDenied;
        userMessage = '该视频为付费内容，当前无法访问。';
      default:
        mapped = FusionErrorCode.upstreamError;
        userMessage = '平台返回了错误：${message.isEmpty ? '未知原因' : message}';
    }

    throw FusionException(
      code: mapped,
      userMessage: userMessage,
      technicalMessage: 'bilibili $endpoint returned code=$code message=$message',
      upstreamCode: code,
      platformId: id,
    );
  }

  /// 收集一条 DASH 流的全部候选 URL（baseUrl + backupUrl[]）。
  ///
  /// 实测背景（2026-10）：B 站返回的每条流都带 1 个 baseUrl 与 2 个
  /// backupUrl，指向不同的 CDN 节点。实测中曾出现 baseUrl 返回 404
  /// 而 backupUrl 正常的情况，因此**不能只用 baseUrl**。
  ///
  /// 这里按 [baseUrl, ...backupUrl] 的顺序返回去重后的候选链，
  /// 由播放内核在首个地址失败时自行回退。
  static List<String> _collectStreamUrls(Map<String, Object?> stream) {
    final out = <String>[];
    void add(Object? value) {
      if (value is String && value.isNotEmpty && !out.contains(value)) {
        out.add(value);
      }
    }

    add(stream['baseUrl']);
    final backups = stream['backupUrl'];
    if (backups is List) {
      for (final b in backups) {
        add(b);
      }
    }
    return out;
  }

  /// 宽松取整：兼容 num 与数字字符串。
  ///
  /// B 站同一个接口里 id 的类型并不统一（一级分区是数字、
  /// 二级分区是字符串），因此不能直接 `as num?`。
  static int? _toInt(Object? value) => jsonToInt(value);

  static String? _nullableString(Object? value) => jsonToNullableString(value);

  /// 宽松取浮点：兼容 num、数字字符串与 "MM:SS"/"H:MM:SS" 时长文本。
  ///
  /// B 站不同接口对 duration 给的类型不一样：`view` 给秒数（num）、
  /// 搜索/收藏列表给 "12:34" 字符串。直接 `as num?` 会在字符串上抛
  /// TypeError（互动状态解析曾因此整块降级），所以统一走这里。
  /// 无法识别时返回 null，**不返回 0**——0 会被 UI 渲染成"0 秒"。
  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final s = value.trim();
      if (s.isEmpty) return null;
      if (s.contains(':')) return _parseDurationString(s);
      return double.tryParse(s);
    }
    return null;
  }

  /// `archive/relation` 的 `like` → 当前用户是否已赞。
  ///
  /// 兼容两种实测形态（都出现过，见 [fetchInteractionState] 的说明）：
  ///  - **bool**：`like: true/false` 就是已赞/未赞；
  ///  - **数字**：B 站前端把"已赞"收敛成 1，未赞时该位等于总赞数，
  ///    所以 `== 1` 判已赞。
  ///
  /// 数字形态有一个**平台自身**的歧义无法在客户端消除：
  /// 某视频总赞数恰好是 1 且当前用户未赞时，会被读成"已赞"。
  /// 这不是解析写法的问题，是平台把两种语义塞进同一个字段，
  /// 因此不试图"修正"它，只保证**不抛异常**。
  static bool _relationLikeFlag(Object? value) {
    if (value is bool) return value;
    if (value is num) return value.toInt() == 1;
    if (value is String) {
      final n = int.tryParse(value.trim());
      if (n != null) return n == 1;
    }
    return false;
  }

  /// `archive/relation` 的 `like` → 可当作总赞数的值，拿不到就 null。
  ///
  /// 只在**数字形态且未赞**时才可能有意义（该位等于总赞数）。
  /// 布尔形态、或已赞（收敛为 1）时一律返回 null，
  /// 让调用方回退到 `UnifiedVideo.stats.likeCount`（来自 `view.stat`）。
  ///
  /// 已赞时若把 1 当总数返回，UI 会显示"1 人点赞"这种荒谬数字，
  /// 所以**必须**返回 null 而不是 1。
  static int? _relationLikeCount(Object? value) {
    if (value is! num) return null;
    final n = value.toInt();
    if (n == 1) return null; // 已赞：这个 1 是标志位，不是总数
    return n > 0 ? n : null;
  }

  /// 宽松取布尔：兼容 bool、0/1 数字与 'true'/'1' 字符串。
  ///
  /// B 站不同接口对同一语义用了不同表示：`archive/relation` 的
  /// `like`/`favorite`/`attention` 是 **bool**，而评论的 `up_action.like`、
  /// 分区的 `is_top` 等是 0/1 数字。直接 `as bool` 或 `as num` 都会在
  /// 平台改口径时抛 TypeError，进而被上层 catch 吞掉——互动状态查询
  /// 曾因此"永远返回 unknown"（收藏成功但按钮不高亮）。
  ///
  /// 因此所有布尔判定统一走这里，**永不抛异常**：无法识别的值按 false，
  /// 且仅在"确实需要区分未知"的地方另用 `_toInt`/null 判断。
  static bool _toBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final s = value.trim().toLowerCase();
      return s == 'true' || s == '1';
    }
    return false;
  }

  // ── 互动：评论 / 点赞 / 投币 / 收藏 ─────────────────────────
  //
  // 接口来源（均为 B 站 Web 端公开接口）：
  //  - 评论列表  GET  /x/v2/reply?type=1&oid={aid}&pn={page}&ps={size}
  //  - 互动状态  GET  /x/web-interface/archive/relation?bvid={bvid}
  //  - 点赞      POST /x/web-interface/archive/like   bvid, like=1|2
  //  - 投币      POST /x/web-interface/coin/add       bvid, multiply=1|2
  //  - 收藏      POST /x/v3/fav/resource/deal         rid={aid}, add_media_ids
  //
  // 认证：全部依赖 SESSDATA 等 Cookie。未登录时平台返回 code=-101，
  // 这里统一映射为 loginRequired，由 UI 引导登录，不静默失败。

  @override
  bool get supportsComments => true;

  @override
  bool get supportsLike => true;

  @override
  bool get supportsCoin => true;

  @override
  bool get supportsFavorite => true;

  /// 拉取评论列表。
  ///
  /// 实测（2026-10）：未登录可读，返回 `code=0`；
  /// 该视频评论数达 23.7 万，分页正常。
  @override
  Future<CommentPage> fetchComments(
    String platformVideoId, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    final aid = await _resolveAid(platformVideoId);
    if (aid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '无法解析该视频的 aid，暂时无法加载评论。',
        technicalMessage: 'Cannot resolve aid for $platformVideoId',
        platformId: id,
      );
    }

    final safePage = page < 1 ? 1 : page;
    final safeSize = pageSize.clamp(1, 49);

    // 使用游标分页接口 `/x/v2/reply/main`。
    //
    // 实测（2026-10）：
    //  - 旧接口 `/x/v2/reply?pn=N` 在未登录时**每个视频只返回 3 条**，
    //    且 pn=2 起返回空数组，无法翻页。
    //  - 新接口 `/x/v2/reply/main?next=N` 返回满页（实测 ps=20 给 20 条），
    //    游标连续翻 3 页共 59 条且无重复。
    //
    // 游标语义：next=0 为第一页，响应里 cursor.next 为下一页游标。
    // 这里把"页码"映射为游标链上的第 N 跳——因为适配器契约是按页取，
    // 而游标无法随机访问，所以第 1 页用 next=0，后续页由调用方
    // 用上一页返回的 CommentPage.nextCursor 传入。
    final cursor = page <= 1 ? 0 : page;
    final url = '$_apiBase/x/v2/reply/main'
        '?type=1&oid=$aid&mode=3&next=$cursor&ps=$safeSize';

    // 记录本次是否带登录态，供 [reply_control] 诊断日志区分场景。
    _currentRequestAuthenticated = session != null;

    final result = await _http.get(
      url,
      headers: {
        'Referer': _referer,
        'Accept': 'application/json, text/plain, */*',
        if (session != null) 'Cookie': session.cookieHeader,
      },
      platformId: id,
      acceptStatuses: const {200, 412},
    );

    if (result.statusCode == 412) {
      throw FusionException(
        code: FusionErrorCode.rateLimited,
        userMessage: '评论加载过于频繁，请稍后再试。',
        technicalMessage: 'bilibili reply/main returned HTTP 412',
        httpStatus: 412,
        platformId: id,
        retryable: true,
      );
    }

    final json = result.jsonObject(platformId: id);
    _assertApiOk(json, endpoint: '/x/v2/reply');

    final data = json['data'];
    if (data is! Map) {
      return CommentPage(
        items: const [],
        page: safePage,
        totalCount: 0,
        hasMore: false,
      );
    }

    final d = Map<String, Object?>.from(data);
    final cursorInfo = d['cursor'] is Map
        ? Map<String, Object?>.from(d['cursor'] as Map)
        : const <String, Object?>{};

    // 总数：cursor.all_count 是新接口的口径
    final total = (cursorInfo['all_count'] as num?)?.toInt() ??
        (cursorInfo['count'] as num?)?.toInt() ??
        0;

    final nextCursor = (cursorInfo['next'] as num?)?.toInt() ?? 0;
    final isEnd = cursorInfo['is_end'] == true;

    final rawReplies = d['replies'];
    final items = <VideoComment>[];
    if (rawReplies is List) {
      for (final raw in rawReplies) {
        if (raw is! Map) continue;
        final c = _replyToComment(Map<String, Object?>.from(raw));
        if (c != null) items.add(c);
      }
    }

    // 置顶评论（UP 主置顶）单独返回
    VideoComment? upTop;
    final top = d['upper'] is Map
        ? (d['upper'] as Map)['top']
        : null;
    if (top is Map) {
      upTop = _replyToComment(Map<String, Object?>.from(top));
    }

    return CommentPage(
      items: items,
      page: safePage,
      totalCount: total,
      // 有内容且平台未标记结束，才算还有更多
      hasMore: items.isNotEmpty && !isEnd && nextCursor > 0,
      nextCursor: nextCursor,
      upTopComment: upTop,
      notes: [
        if (total > 0) '共 $total 条评论。',
      ],
    );
  }

  /// 解析评论条目。
  VideoComment? _replyToComment(Map<String, Object?> raw) {
    final rpid = _nullableString(raw['rpid_str']) ??
        (raw['rpid'] as num?)?.toInt().toString();
    if (rpid == null) return null;

    final member = raw['member'] is Map
        ? Map<String, Object?>.from(raw['member'] as Map)
        : const <String, Object?>{};
    final content = raw['content'] is Map
        ? Map<String, Object?>.from(raw['content'] as Map)
        : const <String, Object?>{};

    final message = _nullableString(content['message']) ?? '';

    // IP 属地。
    //
    // B 站把属地放在 `reply_control.location`，原始值是
    // 「IP属地：广东」这种带前缀的字符串。
    //
    // 实测（2026-10-18，7 种请求面 × 20 个视频 × 60 条评论）：
    // **匿名请求的响应里完全没有该字段**，整个响应体里连字符串
    // "location" 都不出现，`reply_control` 只有
    // max_line / sub_reply_entry_text / time_desc /
    // translation_switch / support_share 这些。
    //
    // 测过的请求面（全部为 0）：
    //   - /x/v2/reply/main（mode=0/2/3，带与不带完整设备指纹）
    //   - /x/v2/reply/wbi/main（**正确 wbi 签名**，code=0，19 条）
    //   - /x/v2/reply（旧接口，sort=0/1/2）
    //   - /x/v2/reply/reply（二级评论）
    //   - APP 端 api.bilibili.com + appkey 签名（mobi_app=android）
    //   - APP 端 app.bilibili.com
    //   - 带 bili_ticket 风控 token
    //
    // 因此匿名时恒为 null，UI 不显示地区——不猜测、不伪造。
    final replyControl = raw['reply_control'] is Map
        ? Map<String, Object?>.from(raw['reply_control'] as Map)
        : const <String, Object?>{};

    // 一次性诊断：把实际收到的 reply_control 键名记下来。
    //
    // 目的：等用户用真实账号登录后，看一眼日志就知道平台是否**开始**
    // 下发 location —— 这是"登录后到底能不能拿到属地"唯一可靠的判定依据，
    // 比任何推断都准。只在 debug 级别输出一次，不含任何用户数据。
    if (!_loggedReplyControlKeys) {
      _loggedReplyControlKeys = true;
      _logger.debug('bilibili reply_control keys', {
        'keys': replyControl.keys.toList(),
        'hasLocation': replyControl.containsKey('location'),
        'authenticated': _currentRequestAuthenticated,
      });
    }

    final ipLocation = _parseIpLocation(replyControl['location']);

    return VideoComment(
      id: rpid,
      authorName: _nullableString(member['uname']) ?? '匿名用户',
      authorAvatarUrl: _nullableString(member['avatar']),
      authorId: _nullableString(member['mid']),
      message: _stripSearchHighlight(message),
      createdAt: _epochToIso(raw['ctime']) ??
          DateTime.now().toUtc().toIso8601String(),
      likeCount: (raw['like'] as num?)?.toInt(),
      replyCount: (raw['rcount'] as num?)?.toInt(),
      isUpAuthor: raw['up_action'] is Map &&
          ((raw['up_action'] as Map)['reply'] == true ||
              (raw['up_action'] as Map)['like'] == true),
      isPinned: raw['is_top'] == 1 || raw['is_top'] == true,
      floor: (raw['floor'] as num?)?.toInt(),
      ipLocation: ipLocation,
    );
  }

  /// 解析 B 站评论的 IP 属地。
  ///
  /// 原始值形如 `IP属地：广东` / `IP属地：日本`，
  /// 部分返回也可能已经是纯地区名。这里统一剥离前缀，
  /// 只保留地区本身供 UI 以低视觉权重展示。
  ///
  /// 返回 null 表示平台未提供——调用方不得补默认值。
  ///
  /// **只接受字符串**。这里刻意不用 `_nullableString`：那个辅助函数会
  /// 把任意类型 `toString()`，于是 `location: 12345` 会变成字符串
  /// `"12345"`、`location: {"name":"广东"}` 会变成 `"{name: 广东}"`，
  /// 两者都会被当成真实地区显示给用户——这正是"把空值填成虚构地区"。
  static String? _parseIpLocation(Object? raw) {
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;

    // 剥离「IP属地：」「IP属地:」前缀（中英文冒号都可能有）
    var value = text;
    for (final prefix in const ['IP属地：', 'IP属地:', 'IP 属地：', 'IP 属地:']) {
      if (value.startsWith(prefix)) {
        value = value.substring(prefix.length).trim();
        break;
      }
    }
    return value.isEmpty ? null : value;
  }

  /// 查询当前用户对该视频的互动状态。
  ///
  /// 未登录时返回 unknown —— 让 UI 显示"登录后可操作"，
  /// 而不是显示"未点赞"（那会让用户误以为操作被重置）。
  ///
  /// # 请求构成
  ///
  ///  1. `GET /x/web-interface/archive/relation?bvid=` —— 关系布尔值（1 个请求）
  ///  2. 仅当 `favorite == true` 时，才用 [scanFoldersContainingVideo]
  ///     查"在哪些夹里"（未收藏就不必扫描，省掉一整轮翻页请求）
  ///
  /// 这里**不需要 aid**：`archive/relation` 只认 bvid。
  /// （收藏**写入**才需要 aid，见 [setFavorite]。）
  ///
  /// # 字段类型（实测 2026-10-19，务必按此解析）
  ///
  /// `archive/relation` 的 data 实测形如：
  /// ```json
  /// {"attention":false,"favorite":true,"season_fav":false,
  ///  "like":false,"dislike":false,"coin":0}
  /// ```
  ///  - `attention` / `favorite` / `season_fav` / `like` / `dislike` 是 **bool**；
  ///  - `coin` 是 **数字**（0/1/2，当前用户在本视频投了几币）；
  ///  - **不返回任何计数字段**。旧实现写 `(d['favorite'] as num?)?.toInt()`
  ///    把 bool 强转 num，抛 TypeError，被外层 catch 吞成 unknown，
  ///    于是"服务端明明收藏成功（code=0）但按钮永不高亮"，只有 SnackBar
  ///    提示生效——这正是那次故障的根因。
  ///    计数一律留 null，由调用方回退到 `UnifiedVideo.stats`
  ///    （UI 侧是 `state.likeCount ?? video.stats.likeCount`，别破坏它）。
  ///    计数的唯一权威来源是 `/x/web-interface/view` 的 `data.stat`。
  ///  - **没有** `fav_time` 键（那是 `/x/v3/fav/resource/list` 里才有的字段），
  ///    旧代码 `d['fav_time'] != null` 恒为 false、不参与判断，已删。
  ///  - `season_fav` 表示该视频所属**合集**是否被收藏，与 `favorite`
  ///    （本单集是否被收藏）是两回事。我们只处理单集收藏，刻意不用它——
  ///    并入 `favorited` 会让"收藏了合集"错误点亮单集的收藏按钮。
  @override
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async {
    if (session == null) return InteractionState.unknown;

    const endpoint = '/x/web-interface/archive/relation';
    try {
      // 用 `_videoIdQuery`：该接口同时接受 `bvid=` 与 `aid=`（实测
      // 两者返回完全一致），因此 av 号形式的 id 不必额外解析，
      // 少一次请求。
      final url = '$_apiBase$endpoint?${_videoIdQuery(platformVideoId)}';
      final result = await _http.get(
        url,
        headers: {
          'Referer': _referer,
          'Cookie': session.cookieHeader,
        },
        platformId: id,
      );
      final json = result.jsonObject(platformId: id);

      // -101 表示登录态失效：如实上报，不当作"未点赞"
      if (json['code'] == -101) {
        throw FusionException(
          code: FusionErrorCode.loginRequired,
          userMessage: '登录状态已失效，请重新登录。',
          technicalMessage: 'archive/relation returned -101',
          upstreamCode: json['code'],
          platformId: id,
        );
      }

      final data = json['data'];
      if (data is! Map) return InteractionState.unknown;
      final d = Map<String, Object?>.from(data);

      // 收藏与否**只**依据 favorite（bool）。不混用 season_fav（合集收藏）。
      final favorited = d['favorite'] == true;

      // 点赞：`like` 有两种实测形态，两种都要扛住。
      //
      //  - 本地实测（2026-10-19，两个视频各 5 次调用）一律是 **bool**：
      //    `{"favorite":true,"like":false,...}`，
      //    其中一个视频在 view 里总赞数 2,957,453，relation 仍给 `like:false`。
      //  - 另一份实测样本给的是**数字**：
      //    `{"attention":0,"like":1,"dislike":18335,"coin":0}`，
      //    并按 B 站前端口径解释为"已赞时收敛为 1，未赞时等于总赞数"。
      //
      // 两种形态无法由本地账号复现出同一次响应，因此这里**同时兼容**：
      // 是 bool 就按布尔用（拿不到总数，likeCount 留 null 让 UI 回退到
      // video.stats）；是数字就按数字口径解析。
      //
      // 关键是**绝不做 `as num` / `as bool` 强转**：旧代码写
      // `(d['like'] as num?)?.toInt()`，在布尔形态上抛 TypeError，
      // 被外层 catch 吞成 unknown，于是"收藏成功但按钮永不高亮"。
      // 数字口径本身还有个无法消除的歧义：总赞数恰好为 1 且未赞时，
      // 会被读成"已赞"。这是平台设计缺陷，不是解析缺陷。
      final liked = _relationLikeFlag(d['like']);
      final likeCount = _relationLikeCount(d['like']);

      // 查该视频具体在哪些收藏夹里 —— **这里故意不查**。
      //
      // 归属只能靠逐夹翻页比对 bvid（平台无反查端点、fav_state 也与归属
      // 无关），一个 6 夹账号全量核对要 14 个请求，而 B 站在连续第 6 个
      // 请求起就返回 412。把它放在"每次打开详情页都要跑的互动状态查询"
      // 里，等于让每个视频都用光风控额度，收藏按钮反而更容易整体失败。
      //
      // 而按钮高亮**只需要** favorite 这个布尔值，1 个请求就够。
      // 所以本方法固定返回空的 favoritedFolderIds，
      // 需要归属的调用方（收藏夹选择面板）自己按预算调
      // [scanFoldersContainingVideo]，并如实处理"没核对完"。
      return InteractionState(
        known: true,
        liked: liked,
        // coin 是数字（0/1/2）：表示"当前用户在本视频投了几币"，
        // 不是平台总投币数，故不填 coinCount。
        coined: _toInt(d['coin']) ?? 0,
        favorited: favorited,
        // 计数：relation 不返计数的布尔形态下为 null，
        // UI 按 `state.likeCount ?? video.stats.likeCount` 回退。
        likeCount: likeCount,
        coinCount: null,
        favoriteCount: null,
        favoritedFolderIds: const [],
        // attention = 是否已关注 UP 主（同批返回，无需额外请求）
        following: _toBool(d['attention']),
      );
    } on FusionException {
      rethrow;
    } catch (e) {
      // 状态查询失败不影响播放与评论，降级为 unknown。
      //
      // 但**必须留下痕迹**：这个 catch 一旦静默，字段语义变化
      // （比如平台把某键从 bool 改成数字）就会表现为"按钮永不高亮"
      // 这种极难定位的症状。只记端点与异常类型，绝不记 Cookie。
      _logger.warn('bilibili: $endpoint parse failed, state degraded', {
        'endpoint': endpoint,
        'errorType': e.runtimeType.toString(),
      });
      return InteractionState.unknown;
    }
  }

  @override
  bool get supportsFolderOwnershipScan => true;

  // ── 限流与请求预算 ──────────────────────────────────────────
  //
  // 实测（2026-10-19）：B 站在**连续第 6 个请求**起返回
  // HTTP 412 + `status_msg="triggered captcha"`（业务码 `-70103112`，
  // 不在标准码表里），等约 6 秒后单发一次即恢复 code=0。
  //
  // 归属扫描天生是"一个视频 → N 个夹 × 翻页"的多请求路径，
  // 不限流就必然打死，用户看到的是"收藏面板转圈后失败"。
  // 因此下面这三条硬约束只在**多请求路径**上生效；
  // 单请求路径（收藏、点赞、投币、稍后再看写入）一律不加延时，
  // 否则把 400ms 的礼貌间隔压到用户每一次点击上，正常操作会被拖慢。

  /// 扫描时两次请求之间的最小间隔。
  static const Duration _scanGap = Duration(milliseconds: 400);

  /// 命中限流后的退避时长（实测约 6 秒恢复）。
  static const Duration _rateLimitBackoff = Duration(seconds: 6);

  /// B 站限流业务码（配 HTTP 412 出现，非标准码表）。
  static const int _captchaTriggeredCode = -70103112;

  /// 扫描时每个夹的翻页上限。
  ///
  /// ps 固定 20 且**不能调大**：实测 ps=100/200 返回的是**空数组**，
  /// 不是"截断到 20 条"（同一夹 ps=20 正常给 20 条）。
  /// 也就是说超限的 ps 会让每个夹看起来都是空的，归属全部判成
  /// "不包含"，而且不报错——见 [_scanOneFolder] 的说明。
  ///
  /// 5 页 = 一个夹最多核对 100 条。封顶的理由：实测有个夹要 10 页
  /// 都还没命中，不设上限的话单个大夹就能吃光整个预算，
  /// 其它夹一个都核对不了。
  static const int _scanMaxPagesPerFolder = 5;

  /// media_count 未知时用于排序的哨兵值（排在最后：不知道多大按贵的算）。
  static const int _unknownSizeSortKey = 1 << 30;

  /// 一次扫描的请求预算计数器。
  ///
  /// 做成**随扫描传递的对象**而不是实例字段：归属扫描可能同时进行
  /// 两次（用户在列表里连开两个视频详情页），共享实例字段会让
  /// 两次扫描互相扣预算，各自都只核对到一半。
  ///
  /// 预算是"整个扫描"共享的，不是每个夹各自一份——
  /// 否则 6 个夹各翻 5 页就是 30 个请求，直接撞 412。
  _ScanBudget _newScanBudget(int maxRequests) =>
      _ScanBudget(maxRequests < 1 ? 1 : maxRequests);

  /// 判断异常是不是平台限流。
  ///
  /// 两个入口都要认：HTTP 412（http_client 已归类为
  /// [FusionErrorCode.rateLimited]）与业务码 `-70103112`。
  static bool _isRateLimited(Object e) {
    if (e is! FusionException) return false;
    if (e.code == FusionErrorCode.rateLimited) return true;
    return e.upstreamCode == _captchaTriggeredCode;
  }

  /// 扫描专用的 GET：间隔节流 + 真实请求数计数 + 限流退避重试一次。
  ///
  /// # 为什么用 acceptStatuses 而不是让 http_client 抛 412
  ///
  /// 412 在 http_client 的 [_retryableStatuses] 里，它会**自己**退避重试
  /// 最多 maxRetries(2) 次——也就是说"一次调用"实际可能是 1~3 个请求。
  /// 若预算按调用次数计，一次扫描的真实请求数会是预算的 3 倍，
  /// 恰好把节流变成限流的帮凶。
  ///
  /// 这里显式 accept 412，把 412 当成**普通响应**读，预算改按
  /// `HttpResult.attempts`（真实发出的请求数）计，节流才名副其实。
  ///
  /// 返回结果带**明确状态**而不是 `null`：null 会混淆
  /// "预算用尽"与"被限流"，UI 于是把"该歇会儿再核对"提示成
  /// "稍后再试"，或反过来。其它异常原样抛出，由调用方按"跳过该夹"处理。
  Future<_ScanGetResult> _scanGet(
    String pathWithQuery,
    PlatformSession session,
    _ScanBudget budget,
  ) async {
    if (!budget.hasRoom) return _ScanGetResult.budgetExhausted();

    await Future<void>.delayed(_scanGap);

    try {
      final result = await _http.get(
        '$_apiBase$pathWithQuery',
        headers: {'Referer': _referer, 'Cookie': session.cookieHeader},
        platformId: id,
        acceptStatuses: const {200, 412, 429},
      );
      // 按**真实**请求数计，含 http_client 内部的自动重试
      budget.consume(result.attempts);

      if (result.statusCode == 412 || result.statusCode == 429) {
        return _scanBackoffAndRetry(pathWithQuery, session, budget);
      }

      final json = result.jsonObject(platformId: id);
      // 绕过 _getAuthed 就要自己接住登录失效：不能让它被当成"没找到"，
      // 那会把"你没登录"显示成"你没收藏"。
      if (json['code'] == -101) {
        throw FusionException(
          code: FusionErrorCode.loginRequired,
          userMessage: '登录状态已失效，请重新登录后再试。',
          technicalMessage: '$pathWithQuery returned -101',
          upstreamCode: json['code'],
          platformId: id,
        );
      }
      // 业务码形式的限流（HTTP 200 + code=-70103112）也要接住：
      // 两种形态都有实测样本。
      if (json['code'] == _captchaTriggeredCode) {
        return _scanBackoffAndRetry(pathWithQuery, session, budget);
      }
      return _ScanGetResult.ok(json);
    } on FusionException catch (e) {
      if (e.code == FusionErrorCode.loginRequired) rethrow;
      if (!_isRateLimited(e)) rethrow;
      budget.rateLimited = true;
      return _ScanGetResult.rateLimited();
    }
  }

  /// 限流后退避 [_rateLimitBackoff] 再试**一次**；仍限流则如实报告。
  Future<_ScanGetResult> _scanBackoffAndRetry(
    String pathWithQuery,
    PlatformSession session,
    _ScanBudget budget,
  ) async {
    budget.rateLimited = true;
    if (!budget.hasRoom) return _ScanGetResult.budgetExhausted();

    await Future<void>.delayed(_rateLimitBackoff);
    try {
      final result = await _http.get(
        '$_apiBase$pathWithQuery',
        headers: {'Referer': _referer, 'Cookie': session.cookieHeader},
        platformId: id,
        acceptStatuses: const {200, 412, 429},
      );
      budget.consume(result.attempts);

      if (result.statusCode == 412 || result.statusCode == 429) {
        return _ScanGetResult.rateLimited();
      }
      final json = result.jsonObject(platformId: id);
      if (json['code'] == _captchaTriggeredCode) {
        return _ScanGetResult.rateLimited();
      }
      return _ScanGetResult.ok(json);
    } on FusionException catch (e) {
      // 退避后仍限流 → 由调用方停止整个扫描
      if (_isRateLimited(e)) return _ScanGetResult.rateLimited();
      rethrow;
    }
  }

  /// 复查"刚收藏/刚移出的项是否真的在目标夹里"。
  ///
  /// # 为什么不复用 [scanFoldersContainingVideo]
  ///
  /// 全量归属扫描要 144 个请求级别（实测），把它放在"写完一次收藏之后"
  /// 等于让每次收藏都撞 412。而复查根本不需要知道"还在别的哪些夹里"，
  /// 只需要知道"我刚操作的那几个夹收下了没有"。
  ///
  /// 依据实测（2026-10-19）：`resource/list` 默认按 `mtime` 倒序，
  /// **新加入的项就在第 1 页**，所以每个目标夹 1 个请求就够，
  /// 保守翻到 [maxPages]（默认 2）页。收藏一次总计 2~3 个请求，
  /// 在实测第 6 个请求才触发风控的阈值之内。
  ///
  /// 返回**已确认包含**该视频的目标夹子集。
  ///
  /// # 返回值不能反着解释
  ///
  /// 不在返回列表里 = "没确认到"，**不等于** "一定没进去"：
  /// 页序不稳定（实测同一夹两次调用首条会变）、请求可能被限流、
  /// 也可能刚写入还没同步。调用方据此只能说"未确认，请刷新查看"，
  /// 不得说"收藏失败"；同理，用它做移除复查时，
  /// "还在列表里"可能只是缓存滞后。
  ///
  /// 判据只用 `bvid`（含 `bv_id` 写法兼容）：aid 在不同接口有短/长两种
  /// 数值形态，跨接口比对不可靠。
  ///
  /// 单夹失败只跳过该夹（返回里少一个），不整体抛错；
  /// 登录失效必须上抛——"你没登录"不能被说成"收藏没生效"。
  @override
  Future<List<int>> verifyRecentFavorite({
    required String platformVideoId,
    required List<int> folderIds,
    required PlatformSession session,
    int maxPages = 2,
  }) async {
    if (folderIds.isEmpty) return const [];
    // 归属/内容比对一律用 BV 号：平台列表给的是 bvid，
    // av 形式（`av123`）永远比不中 → 会误判"未生效"。
    final bvid = await _resolveBvid(platformVideoId);

    final pages = maxPages < 1 ? 1 : maxPages;
    // 复查的目标夹数量就是请求数下界，预算按"每夹 pages 页"给，
    // 但仍受同一套节流与退避约束。
    final budget = _newScanBudget(folderIds.length * pages);
    final confirmed = <int>[];

    for (final folderId in folderIds) {
      if (!budget.hasRoom) break;
      try {
        final found = await _folderContainsNearTop(
          folderId,
          bvid,
          session,
          budget,
          pages,
        );
        if (found) confirmed.add(folderId);
      } on FusionException catch (e) {
        if (e.code == FusionErrorCode.loginRequired) rethrow;
        // 其它错误：这个夹没确认到，继续下一个
      }
      if (budget.rateLimited) break;
    }
    return confirmed;
  }

  /// 在目标夹的**前几页**里找该视频（复查专用，不翻完整个夹）。
  Future<bool> _folderContainsNearTop(
    int folderId,
    String platformVideoId,
    PlatformSession session,
    _ScanBudget budget,
    int maxPages,
  ) async {
    for (var pn = 1; pn <= maxPages; pn++) {
      if (!budget.hasRoom) return false;

      final result = await _scanGet(
        '/x/v3/fav/resource/list'
        '?media_id=$folderId&pn=$pn&ps=20&platform=web',
        session,
        budget,
      );
      if (result.status != _ScanGetStatus.ok) return false;

      final data = result.json!['data'];
      if (data is! Map) return false;
      final d = Map<String, Object?>.from(data);

      final medias = d['medias'];
      if (medias is! List) return false;
      // 空页不能当"确认没有"：实测 ps 超限也返回空数组，
      // 且刚写入时平台可能短暂返回不完整列表。这里只当"没确认到"。
      if (medias.isEmpty) return false;

      for (final raw in medias) {
        if (raw is! Map) continue;
        final m = Map<String, Object?>.from(raw);
        final bv = _nullableString(m['bvid']) ?? _nullableString(m['bv_id']);
        if (bv == platformVideoId) return true;
      }

      if (d['has_more'] != true) return false;
    }
    return false;
  }

  /// 该视频当前所在的收藏夹（逐夹扫描，带请求预算）。
  ///
  /// 设计理由与成本核算见接口文档
  /// [PlatformAdapter.scanFoldersContainingVideo]。要点：
  ///  - 判据**只用 bvid**。不能用 `item.id`/aid 比对：实测 B 站的 aid
  ///    有**短版**（`resource/list` 里给 72996211 这种）与**长版**
  ///    （`view` 里给 117427778098783 这种）两种数值形态，跨接口不相等，
  ///    用 aid 比对会永远不命中 → 必然漏判。
  ///  - 命中即停止该夹翻页；每夹最多翻 [_scanMaxPagesPerFolder] 页。
  ///  - 顺序：默认夹优先（实测收藏大多进默认夹），再按 media_count
  ///    **升序**（小夹便宜，先跑完能更快拿到确定的"已核对"集合）。
  ///  - 单夹异常只跳过该夹，**不计入** checkedFolderIds（因为它没核对完）。
  ///  - 预算用尽或被限流打断时返回**部分结果**并把状态如实标在
  ///    [FolderOwnershipScan.exhaustive] / [FolderOwnershipScan.rateLimited]
  ///    上，不抛错——归属是辅助信息。
  ///
  /// 调用方**必须**先看 [FolderOwnershipScan.exhaustive] 再下结论：
  /// 未核对的夹是"不知道"，不是"不包含"。
  @override
  Future<FolderOwnershipScan> scanFoldersContainingVideo({
    required String platformVideoId,
    required PlatformSession session,
    int maxRequests = 6,
  }) async {
    final budget = _newScanBudget(maxRequests);
    // 同 verifyRecentFavorite：逐夹比对用的是 bvid，
    // av 形式必须先归一，否则每个夹都判"不含"（假的否定）。
    final bvid = await _resolveBvid(platformVideoId);

    final List<FavoriteFolder> folders;
    try {
      folders = await fetchFavoriteFolders(session: session);
    } on FusionException catch (e) {
      if (_isRateLimited(e)) {
        return const FolderOwnershipScan(
          containedFolderIds: [],
          checkedFolderIds: [],
          exhaustive: false,
          rateLimited: true,
          notes: ['收藏夹列表请求即被限流，未做任何核对。'],
        );
      }
      // 登录失效必须如实上抛：静默返回空会被 UI 显示成"未收藏到任何夹"，
      // 那是假的否定。
      if (e.code == FusionErrorCode.loginRequired) rethrow;
      return const FolderOwnershipScan(
        containedFolderIds: [],
        checkedFolderIds: [],
        exhaustive: false,
        notes: ['收藏夹列表获取失败，未做任何核对。'],
      );
    }

    if (folders.isEmpty) {
      return const FolderOwnershipScan(
        containedFolderIds: [],
        checkedFolderIds: [],
        exhaustive: true,
        notes: ['该账号没有自己创建的收藏夹。'],
      );
    }

    // 夹列表本身也是 1 个请求，计入用量：requestsUsed 要能对上
    // 真实打到平台的请求数，否则成本观测会低估。
    budget.consume(1);

    // 顺序：**默认夹优先**，其余按 media_count 升序。
    //
    // 默认夹排最前不是审美选择，是实测结论：绝大多数收藏进默认夹，
    // 所以第一个夹命中的概率最高 → 命中就立刻返回，只用 1~2 个请求
    // 就能给出"已确认在默认夹"这个对用户有用的结论。
    // 其余按体积升序：小夹便宜，先跑完能更快攒出确定的 checked 集合。
    // media_count 为 null 的排最后（不知道多大，按贵的处理）。
    final order = [...folders]..sort((a, b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return (a.mediaCount ?? _unknownSizeSortKey)
          .compareTo(b.mediaCount ?? _unknownSizeSortKey);
    });

    // 核对范围 = 自己创建的夹（见上面 fetchFavoriteFolders 的说明：
    // created/list-all 不含他人/协作夹）。
    final contained = <int>[];
    final checked = <int>[];
    var stoppedAtDefaultFolder = false;

    for (final folder in order) {
      if (!budget.hasRoom) break;

      final outcome = await _scanOneFolder(
        folder,
        bvid,
        session,
        budget,
      );

      switch (outcome) {
        case _FolderScanOutcome.hit:
          contained.add(folder.id);
          checked.add(folder.id);
        case _FolderScanOutcome.notFound:
          checked.add(folder.id);
        case _FolderScanOutcome.skipped:
        case _FolderScanOutcome.rateLimitedStop:
          // 不计入 checked：这个夹的归属是"不知道"，不是"不包含"
          break;
      }

      // 默认夹命中即返回：继续扫其余夹只为了回答"还在别的哪些夹里"，
      // 而那件事的成本是 144 个请求级别，不值得为一次回显去付。
      if (outcome == _FolderScanOutcome.hit && folder.isDefault) {
        stoppedAtDefaultFolder = true;
        break;
      }

      // 限流了就整体停：继续打只会加深风控（实测要等 6 秒才恢复）
      if (outcome == _FolderScanOutcome.rateLimitedStop) break;
      if (budget.rateLimited) break;
    }

    // 差额即"没核对完的夹数"：每个夹在 order 里只访问一次、
    // checked 只可能来自 order，所以不需要额外的"提前停止"标志。
    final unverified = order.length - checked.length;
    return FolderOwnershipScan(
      containedFolderIds: contained,
      checkedFolderIds: checked,
      // 只由"是否还有夹没核对完"决定——预算/限流/默认夹提前返回
      // 都表现为差额，一律 false。
      exhaustive: unverified == 0,
      rateLimited: budget.rateLimited,
      requestsUsed: budget.used,
      notes: [
        if (stoppedAtDefaultFolder)
          '已确认在默认收藏夹；其它收藏夹未核对（可能有其它夹，也可能没有）。',
        if (budget.rateLimited)
          '被平台限流（HTTP 412 / 业务码 -70103112），扫描提前停止。',
        if (!budget.rateLimited && unverified > 0 && !stoppedAtDefaultFolder)
          '请求预算（${budget.limit}）内未能核对全部收藏夹。',
        if (unverified > 0)
          '有 $unverified 个收藏夹未完成核对，它们的归属未知（不等于未收藏）。',
        '仅核对本人创建的收藏夹；收藏在他人/协作夹里的视频不在此结果中。',
      ],
    );
  }

  /// 核对单个收藏夹（翻页直到命中或到底）。
  ///
  /// # ps 必须保持 20，不能为了少翻页调大
  ///
  /// 实测（2026-10-19）`fav/resource/list`：**ps=100 / ps=200 返回空数组**
  /// （同一夹、同一登录态，ps=20 正常给 20 条）。也就是说这个接口
  /// 不是"把 ps 夹到上限"，而是**给了超限值就什么都不返回**。
  /// 若有人为了省翻页把 ps 改成 100，这里第一个空页就会被当成
  /// "该夹是空的 → 确认不包含"，于是**每个夹都判成不包含**，
  /// 归属面板全部显示未勾选，且不报任何错。
  /// 因此 ps=20 是**正确性约束**，不是性能取舍，改动前必须重新实测。
  Future<_FolderScanOutcome> _scanOneFolder(
    FavoriteFolder folder,
    String platformVideoId,
    PlatformSession session,
    _ScanBudget budget,
  ) async {
    for (var pn = 1; pn <= _scanMaxPagesPerFolder; pn++) {
      if (!budget.hasRoom) return _FolderScanOutcome.skipped;

      final result = await _scanGet(
        '/x/v3/fav/resource/list'
        '?media_id=${folder.id}&pn=$pn&ps=20&platform=web',
        session,
        budget,
      );

      switch (result.status) {
        case _ScanGetStatus.budgetExhausted:
          return _FolderScanOutcome.skipped;
        case _ScanGetStatus.rateLimited:
          return _FolderScanOutcome.rateLimitedStop;
        case _ScanGetStatus.ok:
          break;
      }

      final data = result.json!['data'];
      if (data is! Map) return _FolderScanOutcome.skipped;
      final d = Map<String, Object?>.from(data);

      final medias = d['medias'];
      if (medias is! List) return _FolderScanOutcome.skipped;
      if (medias.isEmpty) {
        // 空页**通常**意味着到底（实测 pn 越界返回 200 + 空数组而不报错）。
        // 但只有 has_more 也说"没有更多"时才敢断言"这个夹里没有"：
        // 实测把 ps 写成 100 会让有 32 条的夹直接返回空数组，
        // 若不看 has_more 就判 notFound，等于把"平台没给数据"
        // 谎报成"确认不包含"——那是会误导用户去重复收藏的假结论。
        return d['has_more'] == true
            ? _FolderScanOutcome.skipped
            : _FolderScanOutcome.notFound;
      }

      for (final raw in medias) {
        if (raw is! Map) continue;
        final m = Map<String, Object?>.from(raw);
        // 判据**只用 bvid**：aid 有短/长两种形态，跨接口不相等（见上）。
        final bv = _nullableString(m['bvid']) ?? _nullableString(m['bv_id']);
        if (bv == platformVideoId) return _FolderScanOutcome.hit;
      }

      if (d['has_more'] != true) return _FolderScanOutcome.notFound;
    }

    // 翻到页上限仍未命中：**不能**断言"不在这个夹里"
    // （实测有夹要 10 页才到底，这里只翻 5 页），如实算"没核对完"。
    return _FolderScanOutcome.skipped;
  }

  /// 点赞 / 取消点赞。
  ///
  /// 实测（2026-10）：未登录返回 `code=-101 账号未登录`。
  @override
  Future<InteractionResult> setLike(
    String platformVideoId, {
    required bool like,
    required PlatformSession session,
    int? aid,
  }) async {
    // 该接口的 `bvid` 参数必须是 BV 号：从 av 号链接进来时
    // platformVideoId 是 `av123`，直接传会被判参数错误。
    final bvid = await _resolveBvid(platformVideoId);
    final json = await _postAuthed(
      '/x/web-interface/archive/like',
      body: {
        'bvid': bvid,
        // B 站语义：1 = 点赞，2 = 取消点赞
        'like': like ? '1' : '2',
        'csrf': _csrfFrom(session),
      },
      session: session,
      endpoint: '/x/web-interface/archive/like',
    );

    return InteractionResult(
      accepted: json['code'] == 0,
      message: _nullableString(json['message']),
      upstreamCode: json['code'],
    );
  }

  /// 投币。[count] 为 1 或 2。
  ///
  /// # 平台有**两道**独立校验（实测 2026-10-19）
  ///
  ///  /x/web-interface/coin/add 会分别拒绝：
  ///  - `code=116 消耗的硬币大于剩余数` —— 当
  ///    `exp/reward` 的 `tags.enable_payment_qrcode == 0` 时触发；
  ///  - `code=-104 操作余额不足` —— 即使上面那个标志是 1，
  ///    余额为 0 时仍然触发。
  ///
  /// 也就是说"标志开着"不等于"能投币"，两个条件必须**都**满足。
  /// 本方法因此做两件事：
  ///  1. 若此前查过余额、且平台明确说过标志为 0，直接给出针对性文案
  ///     （省一次注定失败的请求）。这个缓存只在已查余额时存在，
  ///     **不会**为了投币去额外请求余额接口——正常投币仍是一个请求。
  ///  2. 把 116 / -104 映射成可操作的用户文案，而不是把平台原样
  ///     （"消耗的硬币大于剩余数"）丢给用户。
  ///
  /// 注意：这里**不实际消耗硬币**，只是把错误说清楚。
  @override
  Future<InteractionResult> setCoin(
    String platformVideoId, {
    required int count,
    required PlatformSession session,
    bool alsoLike = false,
    int? aid,
  }) async {
    // 前置检查（纯本地，不发请求）：已知的"平台关闭了用币能力"
    if (_lastCoinsUsable == false) {
      return const InteractionResult(
        accepted: false,
        message: '当前账号不可用币（平台已关闭该能力），投币未发起。',
        upstreamCode: 116,
      );
    }

    final multiply = count.clamp(1, 2);
    final json = await _postAuthed(
      '/x/web-interface/coin/add',
      body: {
        // 同 like：这里必须是 BV 号，av 形式先归一
        'bvid': await _resolveBvid(platformVideoId),
        'multiply': '$multiply',
        'select_like': alsoLike ? '1' : '0',
        'csrf': _csrfFrom(session),
      },
      session: session,
      endpoint: '/x/web-interface/coin/add',
    );

    final code = json['code'];
    // 风控拦截（-401）时把平台给的判据带出来：
    // 用户据此知道"去网页端验证一次就能过"，而不是反复点重试。
    final risk = _parseRiskControl(json);

    return InteractionResult(
      accepted: code == 0,
      // 各失败的语义不同，不能都揉成"投币失败"：
      // 能力问题（等也没用）/ 余额问题（攒够才行）/ 风控（去验证）。
      message: switch (code) {
        0 => _nullableString(json['message']),
        116 => '当前账号不可用币（平台已关闭该能力）。',
        -104 => '硬币余额不足，无法投币。',
        -401 => risk?.userHint ?? '投币被风控拦截，请到网页端操作一次再回来。',
        -403 => '账号被风控标记，投币失败。',
        _ => _nullableString(json['message']),
      },
      upstreamCode: code,
      riskControl: risk,
    );
  }

  // ── 评论点赞 / 评论回复 / 一键三连 ──────────────────────────
  //
  // 本轮实测（2026-10-19，真实登录账号）：
  //
  // | 接口 | 结果 |
  // |---|---|
  // | `POST /x/v2/reply/action` | `code=0 OK`（点赞成功） |
  // | `POST /x/v2/reply/add` | `code=0`，返回 `data.rpid_str` |
  // | `POST /x/v2/reply/del` | `code=0 OK`（撤回成功） |
  // | `POST /x/web-interface/archive/like` | `code=0 OK` |
  // | `POST /x/web-interface/coin/add` | **`-401 非法访问`**（风控，见下） |
  // | `POST /x/v3/fav/resource/deal` | `code=0`（**必须带 `add_media_ids`**） |
  //
  // # 投币的两个真实拦截（必须区分，文案不同）
  //
  //  - `-401 非法访问` + `data.ga_data.decisions = ["verify_captcha_level3"]`
  //    → **风控要求人机验证**，不是余额问题，重试无用
  //  - `-403 账号异常,操作失败` → 账号被风控标记
  //  - `-104 操作余额不足` / `116 消耗的硬币大于剩余数` → 余额或能力问题
  //
  // 注意 `-401` 的响应体里 `data.ga_data` 明确写了要哪一级验证码，
  // 这是唯一能区分"风控"与"参数错"的证据，必须读出来告诉用户。
  //
  // # 收藏的坑
  //
  // `add_media_ids` **不能为空**。传空串返回 `2001000 参数错误`。
  // 必须先从 `folder/created/list-all` 拿真实夹 id（默认收藏夹也在里面）。
  // 且响应里 `data.success_num` **恒为 0**，即使写入生效——不能用它判成败，
  // 要复查归属。

  @override
  bool get supportsCommentLike => true;

  @override
  Future<InteractionResult> setCommentLike(
    String platformVideoId, {
    required String commentId,
    required bool like,
    required PlatformSession session,
  }) async {
    final aid = await _resolveAid(platformVideoId);
    if (aid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '无法解析该视频的 ID，暂时无法给评论点赞。',
        technicalMessage: 'Cannot resolve aid for $platformVideoId',
        platformId: id,
      );
    }

    final rpid = int.tryParse(commentId);
    if (rpid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '评论 ID 格式不正确。',
        technicalMessage: 'commentId "$commentId" is not numeric',
        platformId: id,
      );
    }

    final json = await _postAuthed(
      '/x/v2/reply/action',
      body: {
        'oid': '$aid',
        'type': '1',
        'rpid': '$rpid',
        // B站语义：1 = 点赞，0 = 取消点赞
        'action': like ? '1' : '0',
        'csrf': _csrfFrom(session),
      },
      session: session,
      endpoint: '/x/v2/reply/action',
    );

    final code = json['code'];
    return InteractionResult(
      accepted: code == 0,
      message: _nullableString(json['message']),
      upstreamCode: code,
    );
  }

  @override
  bool get supportsCommentReply => true;

  @override
  Future<String?> replyComment(
    String platformVideoId, {
    required String message,
    required PlatformSession session,
    String? replyToCommentId,
  }) async {
    final text = message.trim();
    if (text.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '回复内容不能为空。',
        technicalMessage: 'empty reply message',
        platformId: id,
      );
    }

    final aid = await _resolveAid(platformVideoId);
    if (aid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '无法解析该视频的 ID，暂时无法回复。',
        technicalMessage: 'Cannot resolve aid for $platformVideoId',
        platformId: id,
      );
    }

    final body = <String, String>{
      'oid': '$aid',
      'type': '1',
      'message': text,
      'csrf': _csrfFrom(session),
      // 平台要求显式声明是 web 端发的；缺了会被判 -400。
      'plat': '1',
    };

    // 二级评论：带上父评论 id 与所属根评论 id。
    //
    // 实测：只带 root 不带 parent（或反之）都返回 -400 参数错误。
    // 对一级评论的回复，root 与 parent 是同一个值。
    if (replyToCommentId != null && replyToCommentId.isNotEmpty) {
      body['root'] = replyToCommentId;
      body['parent'] = replyToCommentId;
    }

    final json = await _postAuthed(
      '/x/v2/reply/add',
      body: body,
      session: session,
      endpoint: '/x/v2/reply/add',
    );

    final code = json['code'];
    if (code != 0) {
      // 实测（2026-10-19）该接口的失败码：
      //
      // | code | 含义 | 能否重试 |
      // |---|---|---|
      // | `12051` | **评论频率限制**（同一账号短时间内连发） | 等一会儿可以 |
      // | `12002` | 评论内容被屏蔽（含敏感词） | 改内容 |
      // | `-101` | 未登录（由 _postAuthed 已拦） | 登录 |
      // | `-111` | csrf 失效（由 _postAuthed 已拦） | 重登 |
      //
      // `12051` 最容易被误判成"未知错误"——它是**频控**，不是内容问题，
      // 也不代表接口挂了。必须给用户"稍后再试"而不是"失败"。
      if (code == 12051) {
        throw FusionException(
          code: FusionErrorCode.rateLimited,
          userMessage: '评论发得太快了，请稍等一会儿再发。',
          technicalMessage: 'reply/add returned 12051 (comment rate limited)',
          upstreamCode: code,
          platformId: id,
          retryable: true,
          diagnostics: const {
            'blockedBy': 'comment_rate_limit',
            'note': '同一账号短时间内连发评论会被频控，等几十秒即可',
          },
        );
      }
      if (code == 12002) {
        throw FusionException(
          code: FusionErrorCode.permissionDenied,
          userMessage: '这条评论包含平台不允许的内容，请修改后再发。',
          technicalMessage: 'reply/add returned 12002 (content rejected)',
          upstreamCode: code,
          platformId: id,
          retryable: false,
        );
      }
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '回复失败：${_nullableString(json['message']) ?? '未知原因'}',
        technicalMessage: 'reply/add returned $code',
        upstreamCode: code,
        platformId: id,
      );
    }

    final data = json['data'];
    if (data is Map) {
      final d = Map<String, Object?>.from(data);
      final rpidStr = _nullableString(d['rpid_str']);
      if (rpidStr != null) return rpidStr;
      final rpid = (d['rpid'] as num?)?.toInt();
      if (rpid != null) return '$rpid';
    }
    // 平台接受了但没给 id：如实返回 null，不编造。
    return null;
  }

  @override
  bool get supportsTripleAction => true;

  @override
  Future<TripleActionResult> tripleAction(
    String platformVideoId, {
    required PlatformSession session,
    int coinCount = 1,
  }) async {
    final steps = <TripleActionStep>[];

    // ── 1) 点赞 ──
    //
    // 先查当前状态：已点赞时**不发**点赞请求（重复点赞会被判 -400），
    // 直接记为已完成。这不是偷懒——重复请求会消耗风控配额。
    var alreadyLiked = false;
    try {
      final state = await fetchInteractionState(
        platformVideoId,
        session: session,
      );
      alreadyLiked = state.known && state.liked;
    } catch (_) {
      // 查不到就按"未点赞"处理，多一次幂等请求比漏点赞好。
    }

    if (alreadyLiked) {
      steps.add(const TripleActionStep(
        name: 'like',
        ok: true,
        message: '此前已点赞',
      ));
    } else {
      try {
        final r = await setLike(
          platformVideoId,
          like: true,
          session: session,
        );
        steps.add(TripleActionStep(
          name: 'like',
          ok: r.accepted,
          message: r.message,
          upstreamCode: r.upstreamCode,
        ));
      } on FusionException catch (e) {
        steps.add(TripleActionStep(
          name: 'like',
          ok: false,
          message: e.userMessage,
          upstreamCode: e.upstreamCode,
        ));
      }
    }

    // ── 2) 投币 ──
    //
    // 投币走 `select_like=1` 而不是先点赞再投币：平台在同一次请求里
    // 完成"投币时顺带点赞"，比两次请求省一半风控配额。
    // 但如果上面已经点赞成功，这里 `select_like` 传 0 避免重复。
    try {
      final r = await setCoin(
        platformVideoId,
        count: coinCount.clamp(1, 2),
        session: session,
        alsoLike: false,
      );
      steps.add(TripleActionStep(
        name: 'coin',
        ok: r.accepted,
        message: r.accepted ? null : _coinFailureHint(r.upstreamCode),
        upstreamCode: r.upstreamCode,
      ));
    } on FusionException catch (e) {
      steps.add(TripleActionStep(
        name: 'coin',
        ok: false,
        message: e.userMessage,
        upstreamCode: e.upstreamCode,
      ));
    }

    // ── 3) 收藏 ──
    //
    // 必须带真实收藏夹 id：传空 `add_media_ids` 返回 2001000 参数错误。
    try {
      final folders = await fetchFavoriteFolders(session: session);
      final target = _pickDefaultFolder(folders);
      if (target == null) {
        steps.add(const TripleActionStep(
          name: 'favorite',
          ok: false,
          message: '该账号没有可用的收藏夹，无法收藏。',
        ));
      } else {
        final r = await setFavorite(
          platformVideoId,
          favorite: true,
          session: session,
          folderIds: [target.id],
        );
        steps.add(TripleActionStep(
          name: 'favorite',
          ok: r.accepted,
          message: r.accepted ? null : r.message,
          upstreamCode: r.upstreamCode,
        ));
      }
    } on FusionException catch (e) {
      steps.add(TripleActionStep(
        name: 'favorite',
        ok: false,
        message: e.userMessage,
        upstreamCode: e.upstreamCode,
      ));
    }

    return TripleActionResult(steps: steps);
  }

  /// 从收藏夹列表里挑一个用于收藏的目标。
  ///
  /// 优先"默认收藏夹"（`title` 含"默认"），否则取第一个。
  /// **不硬编码任何 id**：不同账号的默认夹 id 完全不同。
  FavoriteFolder? _pickDefaultFolder(List<FavoriteFolder> folders) {
    if (folders.isEmpty) return null;
    for (final f in folders) {
      if (f.title.contains('默认')) return f;
    }
    return folders.first;
  }

  /// 投币失败的可操作提示。
  ///
  /// `-401` 是**风控**（响应体里 `ga_data.decisions` 会写明要哪级验证码），
  /// 与余额不足完全是两回事——重试无意义，要引导用户去网页端验证。
  String _coinFailureHint(Object? code) => switch (code) {
        -401 => '投币被风控拦截（需要人机验证），请到网页端手动投币。',
        -403 => '账号被风控标记，投币失败。',
        -104 => '硬币余额不足。',
        116 => '当前账号不可用币。',
        _ => '投币失败。',
      };
  /// 从 `-401` 的响应体里解析风控细节。
  ///
  /// 实测响应结构（2026-10-19，真实账号）：
  /// ```json
  /// {
  ///   "code": -401, "message": "非法访问",
  ///   "data": {
  ///     "ga_data": {
  ///       "decisions": ["verify_captcha_level3"],
  ///       "risk_level": 1,
  ///       "decision_ctx": {
  ///         "scene": "video_coin",
  ///         "verify_exempt_by_decision": "1",
  ///         "v_voucher": "voucher_..."
  ///       }
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// 这些字段决定了用户该怎么处理：
  ///  - `decisions` 里的 `verify_captcha_levelN` 说要哪一级验证码
  ///  - `scene` 说明是哪个动作触发的风控（`video_coin` / `video_like` …）
  ///  - `verify_exempt_by_decision == "1"` 说明该账号本身是白名单，
  ///    只是本次被临时拦（换个时间可能就过）
  ///
  /// **不返回 `v_voucher` 与 `grisk_id`**：前者是一次性验证凭据，
  /// 后者是风控会话标识，都不该出现在用户可见文案或日志里。
  PlatformRiskControl? _parseRiskControl(Map<String, Object?> json) {
    if ((json['code'] as num?)?.toInt() != -401) return null;
    final data = json['data'];
    if (data is! Map) return null;
    final gaData = Map<String, Object?>.from(data)['ga_data'];
    if (gaData is! Map) return null;
    final ga = Map<String, Object?>.from(gaData);

    final rawDecisions = ga['decisions'];
    final decisions = <String>[];
    if (rawDecisions is List) {
      for (final d in rawDecisions) {
        if (d is String) decisions.add(d);
      }
    }

    final ctx = ga['decision_ctx'] is Map
        ? Map<String, Object?>.from(ga['decision_ctx'] as Map)
        : const <String, Object?>{};

    return PlatformRiskControl(
      decisions: decisions,
      riskLevel: (ga['risk_level'] as num?)?.toInt(),
      scene: _nullableString(ctx['scene']),
      exemptByDecision: '${ctx['verify_exempt_by_decision'] ?? ''}' == '1',
    );
  }

  /// 是否支持"选择收藏夹"。
  ///
  /// B站有 `/x/v3/fav/folder/created/list-all` 可拿真实收藏夹列表，
  /// 实测（2026-10-18）返回 6 个收藏夹（含默认收藏夹与自建夹）。
  @override
  bool get supportsFavoriteFolders => true;

  /// 拉取当前账号的真实收藏夹列表。
  ///
  /// # 只包含**本人创建**的收藏夹
  ///
  /// `created/list-all` 顾名思义只列自己建的夹。账号还可能把视频收藏进
  /// **他人分享/协作**的夹，那些不在本结果里。
  /// 实测：`folder/visited/list` 在本账号对 3 种 uid 参数变体都返回
  /// `count=0`，说明这个账号确实没有协作夹——但**不能据此假定所有账号
  /// 都没有**。
  ///
  /// 直接后果：**收藏夹面板只能管理本人创建的夹**。UI 文案不得写成
  /// "管理全部收藏夹/所有收藏"；归属扫描也只对本人创建的夹成立
  /// （见 [scanFoldersContainingVideo] 的 notes）。
  ///
  /// # media_count 不可作权威
  ///
  /// 实测同一个夹：`created/list-all` 给 145，`folder/info` 给 248。
  /// 它只适合排序/展示，**不能**用来判断"翻完没有"——
  /// 翻页边界一律靠空页与 `has_more`。
  ///
  /// 实测响应（2026-10-19）：
  ///
  /// ```json
  /// {"code":0,"data":{"count":6,"list":[
  ///   {"id":62851852,"title":"默认收藏夹","media_count":32,"attr":0,"fav_state":0},
  ///   {"id":4020481152,"title":"gay","media_count":1,"attr":22,"fav_state":0},
  ///   {"id":3683371952,"title":"神人视频","media_count":145,"attr":22},
  ///   ...
  /// ],"season":null}}
  /// ```
  ///
  /// **注意**：`title` 为「默认收藏夹」的那个才是账号默认夹。
  /// 不要按 ID 硬编码，也不要用数组下标 0 假定——下标 0 恰好是默认夹
  /// 只是这个账号的巧合，别的账号不保证。
  ///
  /// # 这里给不出"某视频在哪些夹里"
  ///
  /// 每个夹带的 `fav_state` **与归属无关**（它是"我是否收藏了这个夹子"，
  /// 对自建夹恒为 0；判别实验见 [FavoriteFolder] 的 dartdoc）。
  /// 归属必须走 [scanFoldersContainingVideo]。因此本方法**不接受**
  /// 视频 ID 参数——曾加过一个 `platformVideoId` 命名参数想走捷径，
  /// 实测证明传与不传结果一样，留着只会误导后来的人。
  ///
  /// # 这里给不出"某视频在哪些夹里"
  ///
  /// 每个夹带的 `fav_state` **与归属无关**（它是"我是否收藏了这个夹子"，
  /// 对自建夹恒为 0；判别实验见 [FavoriteFolder] 的 dartdoc）。
  /// 归属必须走 [scanFoldersContainingVideo]。因此本方法**不接受**
  /// 视频 ID 参数——曾加过一个 `platformVideoId` 命名参数想走捷径，
  /// 实测证明传与不传结果一样，留着只会误导后来的人。
  @override
  Future<List<FavoriteFolder>> fetchFavoriteFolders({
    required PlatformSession session,
  }) async {
    final uid = session.userId;
    if (uid.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '登录信息不完整，请重新登录。',
        technicalMessage: 'session.userId is empty',
        platformId: id,
      );
    }

    final result = await _http.get(
      '$_apiBase/x/v3/fav/folder/created/list-all?up_mid=$uid&platform=web',
      headers: {'Referer': _referer, 'Cookie': session.cookieHeader},
      platformId: id,
    );
    final json = result.jsonObject(platformId: id);
    _assertApiOk(
      json,
      endpoint: '/x/v3/fav/folder/created/list-all',
      badRequestCode: FusionErrorCode.loginRequired,
      badRequestMessage: '登录状态无效，请重新登录后再试。',
    );

    final data = json['data'];
    final rawList = data is Map ? data['list'] : null;
    if (rawList is! List) {
      // 账号确实可能一个收藏夹都没有（新账号），如实返回空
      return const [];
    }

    final folders = <FavoriteFolder>[];
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final m = Map<String, Object?>.from(raw);
      final folderId = _toInt(m['id']);
      final title = _nullableString(m['title']);
      if (folderId == null || title == null) continue;

      folders.add(
        FavoriteFolder(
          id: folderId,
          title: title,
          mediaCount: _toInt(m['media_count']),
          // 平台不返回 is_default 布尔值，按名称判断。
          // 这是 B站 Web 端的既有约定（默认夹固定叫「默认收藏夹」）。
          isDefault: title == '默认收藏夹',
          // attr 的 bit0 按 B 站前端惯例表示"私密"。
          // 注意：本地实测**没有阳性样本**——本账号 5 个非默认夹
          // attr=22，而 22 & 1 = 0，全部判为公开；folder/info 也没给
          // priv_reason。所以这条规则的"私密"分支尚未被任何真实数据触发过，
          // UI 不要把它当强约束去隐藏收藏夹（见 FavoriteFolder.isPublic）。
          isPublic: (_toInt(m['attr']) ?? 0) & 1 == 0,
        ),
      );
    }
    return folders;
  }

  /// 收藏 / 取消收藏。
  ///
  /// 需要先拿到目标收藏夹 ID。这里采用：
  ///  - 收藏：[folderIds] 指定则用指定夹；未指定时读取
  ///    「创建的收藏夹列表」里**按名称识别**的默认收藏夹
  ///  - 取消：同样按 [folderIds] 移除（未指定则从默认夹移除）
  ///
  /// 若用户没有任何收藏夹，如实报错而不是静默失败。
  ///
  /// # 关键约束（实测 2026-10-18 / 10-19）
  ///
  /// - 接口：`POST /x/v3/fav/resource/deal`
  /// - `type=2`（视频）
  /// - `add_media_ids` / `del_media_ids` 互斥
  /// - 必须带 `csrf`（= `bili_jct`），否则返回 `-111 CSRF 校验失败`
  /// - `rid` 要的是**数字 aid**，所以收藏写入是少数确实需要
  ///   [_resolveAid] 的互动路径（BV 号本身不认）
  /// - 不存在的 media_id：不同时点返回过 `code=0 message=OK`（假成功）与
  ///   `code=11010 您访问的内容不存在`，**两者都要当失败处理**
  /// - 成功后 `archive/relation` 的 `favorite` 立即变 `true`
  ///
  /// # 判成败：不能只看 code，也不能看 success_num
  ///
  /// 实测（2026-10-19）：`code=0 message=OK data={"prompt":true,"success_num":0}`
  /// 里 **`success_num` 恒为 0**，即使写入真的生效（media_count 已 +1、
  /// relation.favorite 已变 true），所以它**不能**用来判断是否生效。
  /// 因此：
  ///  - `accepted` 仍按 `code == 0` 给（平台是否接受请求）；
  ///  - 把 `data.success_num` / `data.prompt` 解析进 [InteractionResult.message]，
  ///    `code == 0` 但 `success_num == 0` 时给"平台未确认生效"，
  ///    让 UI 能说清具体原因而不是空泛的"失败"；
  ///  - **真正的是否生效由调用方复查**：写入后调
  ///    [scanFoldersContainingVideo] 看归属有没有变。适配器不做这次复查
  ///    （一次复查是 N 个夹 × 翻页的开销，时机应由 UI 决定）。
  ///
  /// [folderIds] / [removeFolderIds] 同时为 null 时走旧语义：
  /// `favorite=true` → 加入默认收藏夹；`favorite=false` → 从当前归属的所有夹移出。
  /// 多收藏夹同时操作由平台支持（`add_media_ids` 是逗号分隔的列表）。
  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
    List<int>? folderIds,
    List<int>? removeFolderIds,
  }) async {
    final resolvedAid = aid ?? await _resolveAid(platformVideoId);
    if (resolvedAid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '无法解析该视频的 aid。',
        technicalMessage: 'Cannot resolve aid for $platformVideoId',
        platformId: id,
      );
    }

    List<int>? addIds;
    List<int>? delIds;

    if (folderIds == null && removeFolderIds == null) {
      // 旧语义（向后兼容）：只靠 favorite 布尔决定加还是减。
      //
      // 取消收藏时**只移出默认夹**，不为了"找出所有包含它的夹"而做一次
      // 逐夹扫描：那是 14 个请求的量级（见 [scanFoldersContainingVideo]），
      // 藏在一次写操作里等于让每次取消收藏都撞 412，
      // 而且把成本从"调用方可控"变成"用户点一下就爆"。
      //
      // 需要"从所有夹移出"的调用方（UI 已经这么做）应显式传
      // [removeFolderIds]——归属信息由调用方按自己的预算扫描后决定。
      // 只收藏进默认夹是绝大多数情况，因此这个兜底语义是安全的。
      final defaultId = _defaultFolderId(await _requireFolders(session));
      if (favorite) {
        addIds = [defaultId];
      } else {
        delIds = [defaultId];
      }
    } else {
      addIds = (folderIds == null || folderIds.isEmpty) ? null : folderIds;
      delIds = (removeFolderIds == null || removeFolderIds.isEmpty)
          ? null
          : removeFolderIds;
    }

    if (addIds == null && delIds == null) {
      // 两侧都没给夹：一次请求都不该发（发了等于误操作默认夹）。
      return const InteractionResult(
        accepted: true,
        message: '没有需要变更的收藏夹。',
      );
    }

    // 实测 add_media_ids 与 del_media_ids **互斥**，同一次请求只能生效一侧。
    // 因此"同时加 A 夹、移出 B 夹"必须拆成两次 POST，先加后删：
    // 先删后加会在加失败时把视频彻底移出收藏，反过来最坏只是没移出。
    final steps = <List<String>>[
      if (addIds != null) ['add', addIds.join(',')],
      if (delIds != null) ['del', delIds.join(',')],
    ];

    var allAccepted = true;
    String? message;
    Object? upstreamCode;
    for (final step in steps) {
      final isAdd = step[0] == 'add';
      final json = await _postAuthed(
        '/x/v3/fav/resource/deal',
        body: {
          'rid': '$resolvedAid',
          'type': '2',
          'add_media_ids': isAdd ? step[1] : '',
          'del_media_ids': isAdd ? '' : step[1],
          'csrf': _csrfFrom(session),
        },
        session: session,
        endpoint: '/x/v3/fav/resource/deal',
      );
      final code = json['code'];
      final ok = code == 0;
      if (!ok) allAccepted = false;
      // 失败的那一步优先保留其平台消息与码，便于排查
      message = _favDealMessage(json, accepted: ok) ?? message;
      upstreamCode = code;
    }

    return InteractionResult(
      accepted: allAccepted,
      message: message,
      upstreamCode: upstreamCode,
    );
  }

  /// 把 `fav/resource/deal` 的响应翻成一句可展示的原因。
  ///
  /// `code == 0` 但 `success_num == 0` 时明确说"平台未确认生效"：
  /// 实测 `success_num` **恒为 0**，所以这句话本身也不能当成"失败"的结论，
  /// 它的作用是把"平台只回了个 OK、没给任何生效证据"这件事如实说出来，
  /// 让 UI 有依据去提示用户复查（而不是假装成功或假装失败）。
  String? _favDealMessage(Map<String, Object?> json, {required bool accepted}) {
    final raw = _nullableString(json['message']);
    if (!accepted) return raw;

    final data = json['data'];
    if (data is! Map) return raw;
    final successNum = _toInt(data['success_num']);
    final prompt = data['prompt'];

    final parts = <String>[
      ?raw,
      if (successNum == 0) '平台未确认生效（success_num=0），请复查收藏夹',
      if (prompt == true) '平台返回了提示位',
    ];
    return parts.isEmpty ? null : parts.join('；');
  }

  /// 拉收藏夹列表，并在账号确实一个夹都没有时如实报错。
  ///
  /// 不静默返回空——那会让"收藏失败"伪装成"收藏成功"。
  Future<List<FavoriteFolder>> _requireFolders(
    PlatformSession session,
  ) async {
    final folders = await fetchFavoriteFolders(session: session);
    if (folders.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: '你还没有收藏夹，请先在 B 站创建一个。',
        technicalMessage: 'no fav folder for mid=${session.userId}',
        platformId: id,
      );
    }
    return folders;
  }

  /// 取账号的默认收藏夹 ID。
  ///
  /// **按名称识别**（B 站默认夹固定叫「默认收藏夹」），
  /// 不按数组下标 0、也不按 ID 硬编码——不同账号的默认夹 ID 不同。
  /// 名称没匹配上时退回第一个夹（至少是用户自己的夹，收藏不会失败）。
  int _defaultFolderId(List<FavoriteFolder> folders) {
    final defaultFolder =
        folders.firstWhere((f) => f.isDefault, orElse: () => folders.first);
    return defaultFolder.id;
  }

  // ── 硬币余额 / 稍后再看 / 关注 ──────────────────────────────

  @override
  bool get supportsCoinBalance => true;

  @override
  bool get supportsWatchLater => true;

  @override
  bool get supportsFollowAuthor => true;

  @override
  bool get supportsSavedContent => true;

  /// 拉取某个收藏夹里的内容。
  ///
  /// 实测：`GET /x/v3/fav/resource/list?media_id=&pn=&ps=&platform=web`
  /// → `data.medias[]`（字段 `id/type/title/cover/page/duration/
  /// upper{mid,name,face}/link/bvid/ctime/pubtime/fav_time/cnt_info`），
  /// 总数在 `data.info.totals`。
  ///
  /// # 只收视频
  ///
  /// `type` 是 B 站的资源类型码（**2 = 视频**；其余是合集/音频/专栏等）。
  /// 非视频条目**直接跳过**并在 [SavedVideoPage.notes] 里计数——
  /// 把它们伪装成 UnifiedVideo 会让点进去必然播放失败，
  /// 属于"把不知道的东西填成有"，违反全局的"不凭空生成"约束。
  @override
  Future<SavedVideoPage> fetchFavoriteFolderVideos(
    int mediaId, {
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async {
    final pn = page < 1 ? 1 : page;
    // 上限 20：实测 ps>20 时平台返回**空数组**而不是截断到 20，
    // 一旦放到 100 就会"每页都空"，列表看起来像收藏夹是空的。
    final ps = pageSize.clamp(1, 20);
    final json = await _getAuthed(
      '/x/v3/fav/resource/list'
      '?media_id=$mediaId&pn=$pn&ps=$ps&platform=web',
      session: session,
    );
    _assertApiOk(
      json,
      endpoint: '/x/v3/fav/resource/list',
      badRequestCode: FusionErrorCode.loginRequired,
      badRequestMessage: '登录状态无效，请重新登录后再试。',
    );

    final data = json['data'];
    if (data is! Map) {
      return const SavedVideoPage(items: [], hasMore: false, total: 0);
    }
    final d = Map<String, Object?>.from(data);
    final medias = d['medias'];
    final apiHasMore = d['has_more'] is bool ? d['has_more'] as bool : null;
    final info = d['info'] is Map
        ? Map<String, Object?>.from(d['info'] as Map)
        : const <String, Object?>{};
    final total = _toInt(info['totals']) ?? 0;

    return _buildSavedPage(
      rawItems: medias is List ? medias : const [],
      total: total,
      page: pn,
      pageSize: ps,
      endpoint: '/x/v3/fav/resource/list',
      mapper: _favMediaToVideo,
      hasMoreFromApi: apiHasMore,
    );
  }

  /// 拉取"稍后再看"列表。
  ///
  /// 实测（2026-10-19）：`GET /x/v2/history/toview/web?platform=web&pn=&ps=`
  /// → `data.count`（总数）/ `data.list[]`，条目字段是
  /// `aid/bvid/title/pic/duration/owner{mid,name,face}/pubdate/stat`
  /// ——与收藏夹的 `medias` **不同构**（封面叫 `pic`、作者叫 `owner`、
  /// 且没有 `type` 字段，因为这里只有视频），所以单独一个映射函数。
  @override
  Future<SavedVideoPage> fetchWatchLaterVideos({
    required PlatformSession session,
    int page = 1,
    int pageSize = 20,
  }) async {
    final pn = page < 1 ? 1 : page;
    // 上限 20：实测 ps>20 时平台返回**空数组**而不是截断到 20，
    // 一旦放到 100 就会"每页都空"，列表看起来像收藏夹是空的。
    final ps = pageSize.clamp(1, 20);
    final json = await _getAuthed(
      '/x/v2/history/toview/web?platform=web&pn=$pn&ps=$ps',
      session: session,
    );

    final data = json['data'];
    if (data is! Map) {
      return const SavedVideoPage(
        items: [],
        hasMore: false,
        total: 0,
        upstreamEndpoint: '/x/v2/history/toview/web',
      );
    }
    final d = Map<String, Object?>.from(data);
    final list = d['list'];

    return _buildSavedPage(
      rawItems: list is List ? list : const [],
      total: _toInt(d['count']) ?? 0,
      page: pn,
      pageSize: ps,
      endpoint: '/x/v2/history/toview/web',
      mapper: _toviewItemToVideo,
    );
  }

  /// 已保存内容分页的统一装配（把两类条目源归一到 [SavedVideoPage]）。
  ///
  /// # hasMore 以平台的 `has_more` 为准，不用总数算
  ///
  /// B 站的 `info.totals` / `media_count` 在夹内存在**已失效条目**时与
  /// 实际可翻页条数不一致（被删的视频仍计入总数但列表不返回），
  /// 靠"总数 − 已加载"估算边界会漏页或多翻一页空页。所以优先采信
  /// [hasMoreFromApi]；仅当平台没给该字段（null）时才退回估算，
  /// 并在 notes 里写明这是估算值。
  ///
  /// 终止条件用「**原始页为空**」而不是「过滤后的 items 为空」：
  /// 一页全是非视频条目（type != 2）时 items 会是空数组，
  /// 若据此判定到底，用户往下翻就永远看不到后面的视频了。
  SavedVideoPage _buildSavedPage({
    required List<Object?> rawItems,
    required int total,
    required int page,
    required int pageSize,
    required String endpoint,
    required UnifiedVideo? Function(Map<String, Object?> raw) mapper,
    bool? hasMoreFromApi,
  }) {
    final items = <UnifiedVideo>[];
    var skipped = 0;
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final video = mapper(Map<String, Object?>.from(raw));
      if (video == null) {
        skipped++;
        continue;
      }
      items.add(video);
    }

    final notes = <String>[
      if (skipped > 0) '本页跳过 $skipped 条非视频或无 BV 号的条目。',
    ];

    // 平台明确说没有下一页 → 就是没有；平台没说 → 用总数估算并标注。
    var hasMore = hasMoreFromApi ?? (total > 0 && page * pageSize < total);
    if (rawItems.isEmpty) hasMore = false;
    if (hasMoreFromApi == null && total > 0) {
      notes.add('平台未返回 has_more，是否还有下一页按总数估算，可能有偏差。');
    }

    return SavedVideoPage(
      items: items,
      hasMore: hasMore,
      total: total,
      adapterId: id,
      upstreamEndpoint: endpoint,
      notes: notes,
    );
  }

  /// 收藏夹条目（`/x/v3/fav/resource/list` 的 medias[i]）→ 统一视频。
  UnifiedVideo? _favMediaToVideo(Map<String, Object?> m) {
    // type=2 才是视频；其它类型一律不伪装成视频（见调用处注释）。
    final type = _toInt(m['type']);
    if (type != null && type != 2) return null;

    final bvid = _nullableString(m['bvid']);
    if (bvid == null) return null;

    final upper = m['upper'] is Map
        ? Map<String, Object?>.from(m['upper'] as Map)
        : const <String, Object?>{};
    final cnt = m['cnt_info'] is Map
        ? Map<String, Object?>.from(m['cnt_info'] as Map)
        : const <String, Object?>{};
    final mid = _nullableString(upper['mid']);
    final link = _nullableString(m['link']);

    // 不对失效条目做任何推断：平台在视频被删/UP 主拉黑时仍会把条目
    // 列出来（title 变占位串、type 可能非 2）。这里只搬接口明确给的字段，
    // 能否播放由点进去时的播放策略决定，列表阶段不下结论。
    return UnifiedVideo(
      id: makeVideoId(id, bvid),
      platformId: id,
      platformVideoId: bvid,
      // 原始链接用接口给的 link；没有就退回规范链接，不编造第三方域名
      originalUrl: link ?? 'https://www.bilibili.com/video/$bvid',
      canonicalUrl: 'https://www.bilibili.com/video/$bvid',
      title: _stringOr(m['title'], '未命名视频'),
      author: VideoAuthor(
        name: _nullableString(upper['name']),
        platformAuthorId: mid,
        profileUrl: mid != null ? 'https://space.bilibili.com/$mid' : null,
        avatarUrl: _nullableString(upper['face']),
      ),
      coverUrl: _normalizeCoverUrl(_nullableString(m['cover'])),
      durationSeconds: _toDouble(m['duration']),
      publishedAt: _epochToIso(m['pubtime']),
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: VideoStats(
        // cnt_info 里 play/like 可能是数字也可能是 "1.2万" 这类文本，
        // 两者都兼容；拿不到就留 null。
        viewCount: _parseCountText(cnt['play']),
        likeCount: _parseCountText(cnt['like']),
        danmakuCount: _parseCountText(cnt['danmaku']),
      ),
      // 收藏夹列表本身不声明可播性；交给现有播放策略在点开时解析，
      // 这里给 unknown，避免"列表看着能播、点开失败"。
      availability: VideoAvailability.unknown,
      playbackModes: const [PlaybackMode.native, PlaybackMode.external],
      requiresAuth: false,
      diagnostics: VideoDiagnostics(
        adapterId: id,
        upstreamEndpoint: '/x/v3/fav/resource/list',
        fromCache: false,
        fetchDurationMs: 0,
        limitations: const ['收藏夹列表不含宽高信息，播放时由播放策略解析。'],
      ),
    );
  }

  /// 稍后再看条目（`/x/v2/history/toview/web` 的 data.list[i]）→ 统一视频。
  UnifiedVideo? _toviewItemToVideo(Map<String, Object?> m) {
    final bvid = _nullableString(m['bvid']);
    if (bvid == null) return null;

    final owner = m['owner'] is Map
        ? Map<String, Object?>.from(m['owner'] as Map)
        : const <String, Object?>{};
    final stat = m['stat'] is Map
        ? Map<String, Object?>.from(m['stat'] as Map)
        : const <String, Object?>{};
    final mid = _nullableString(owner['mid']);

    // 稍后再看条目天然带 aid，回填缓存后收藏/评论路径省掉一次 view 请求。
    _rememberAid(bvid, m['aid']);

    return UnifiedVideo(
      id: makeVideoId(id, bvid),
      platformId: id,
      platformVideoId: bvid,
      originalUrl: 'https://www.bilibili.com/video/$bvid',
      canonicalUrl: 'https://www.bilibili.com/video/$bvid',
      title: _stringOr(m['title'], '未命名视频'),
      author: VideoAuthor(
        name: _nullableString(owner['name']),
        platformAuthorId: mid,
        profileUrl: mid != null ? 'https://space.bilibili.com/$mid' : null,
        avatarUrl: _nullableString(owner['face']),
      ),
      coverUrl: _normalizeCoverUrl(_nullableString(m['pic'])),
      durationSeconds: _toDouble(m['duration']),
      publishedAt: _epochToIso(m['pubdate']),
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: VideoStats(
        viewCount: _toInt(stat['views']),
        likeCount: _toInt(stat['likes']),
        danmakuCount: _toInt(stat['danmaku']),
      ),
      availability: VideoAvailability.unknown,
      playbackModes: const [PlaybackMode.native, PlaybackMode.external],
      requiresAuth: false,
      diagnostics: VideoDiagnostics(
        adapterId: id,
        upstreamEndpoint: '/x/v2/history/toview/web',
        fromCache: false,
        fetchDurationMs: 0,
        limitations: const ['稍后再看列表不含宽高信息，播放时由播放策略解析。'],
      ),
    );
  }

  /// 读取当前账号的可用硬币余额。
  ///
  /// 实测（2026-10-19）：`GET /x/member/web/exp/reward` →
  /// `data.coins`。**类型不固定**：同一字段在不同账号/时点出现过
  /// JSON 整数 `0` 与浮点 `0.0` 两种写法，所以不能 `(v as int)`，
  /// 一律走 [_toInt]（它把任意 num 折成 int），并保留 null 语义。
  ///
  /// 同一响应里还有 `tags.enable_payment_qrcode`：它和余额**共同**决定
  /// 能否投币（见 [setCoin] 的双重前置校验），所以这里把它缓存到
  /// [_lastCoinsUsable]，供投币路径使用——余额接口本身不返回"能不能投"，
  /// 只看余额会把"标志关闭"误判成"有钱就能投"。
  ///
  /// 未登录：平台返回 `-101`，映射为 loginRequired（见 [_getAuthed]）。
  /// 返回 null 只在平台**没有** coins 键时发生——不当 0 用，
  /// "不知道"和"没有币"必须可区分。
  @override
  Future<int?> fetchCoinBalance({required PlatformSession session}) async {
    final json = await _getAuthed(
      '/x/member/web/exp/reward',
      session: session,
    );
    final data = json['data'];
    if (data is! Map) return null;
    final d = Map<String, Object?>.from(data);

    // "平台是否允许用币"标志。
    //
    // 必须**显式判类型**：`tags` 存在但 `enable_payment_qrcode` 键缺失时，
    // 宽松取整会拿到 null，而 `null != 0` 为 true → 错误判定"可以投币"，
    // 于是放行一次注定被 116 拒绝的请求。
    // 规则：tags 存在时按键的实际数值判定，**拿不到该键就按 false**
    // （不鼓励投币）；连 tags 都没有时保持 null（不知道），
    // 不做任何猜测，也**不沿用上一次的值**——陈旧缓存会把上个账号/
    // 上个时点的结论带到这次投币上。
    final tags = d['tags'];
    if (tags is Map) {
      final enable = tags['enable_payment_qrcode'];
      _lastCoinsUsable = enable is num && enable.toInt() != 0;
    } else {
      _lastCoinsUsable = null;
    }

    return _toInt(d['coins']);
  }

  /// 最近一次余额查询里平台声明的"允许用币"标志。
  ///
  /// 三态：
  ///  - `true`  —— 平台明确说允许（`enable_payment_qrcode != 0`）；
  ///  - `false` —— 平台明确说不允许，**或** tags 存在但那个键缺失
  ///    （实测平台确有"tags 在、键不在"的响应，此时按不允许处理，
  ///    宁可少发一次请求，也不要给用户一个必然失败的按钮）；
  ///  - `null`  —— 还没查过余额（连 tags 都没有的响应也算未知）。
  ///
  /// 投币前置检查用它 + 余额**两个**条件，因为实测两者会不一致
  /// （标志为 1 但余额 0 → `-104`）。
  bool? _lastCoinsUsable;

  /// 该视频是否已在"稍后再看"里。
  ///
  /// 实测（2026-10-19）：
  ///  - `GET /x/v2/history/toview/web?platform=web` → `code=0`，
  ///    `data.count` / `data.list[]`（本测试号 count=0）。
  ///  - **候选的 aid 直查端点不存在**：
  ///    `GET /x/v2/history/toview/aid?aid=<aid>` 带不带 `platform=web`
  ///    都返回 **HTTP 404**（两次独立实测均如此，响应体是 HTML 错误页）。
  ///    因此无法"一个请求查清"，只能读列表比对——这里不假装存在该端点。
  ///
  /// # 为什么 ps 用 20 而不是 100（这是个真坑）
  ///
  /// 同一族的 `fav/resource/list` 实测：**ps>20 时返回空数组**
  /// （ps=100/200 各请求一次，`medias` 长度都是 0；ps=20 正常给 20 条）。
  /// 如果这里为了"一次取满 100 条"写 `ps=100`，很可能拿到空列表，
  /// 于是 `fetchWatchLater` **永远返回 false** —— 表现是
  /// "明明在稍后再看里，按钮却不亮"，而且不报任何错。
  ///
  /// 所以按 ps=20 有限翻页：既不踩空，也不无限翻。
  /// 上限 [_watchLaterMaxPages] 页；翻到 count 或空页即停。
  /// 若平台上调上限导致超出此范围，结果是"未在已核对范围内找到"，
  /// 按 false 返回——漏判的后果是按钮不亮，用户重点一次即恢复
  /// （add 幂等），不会破坏数据。
  @override
  Future<bool> fetchWatchLater({
    required String platformVideoId,
    required PlatformSession session,
  }) async {
    // 列表项同时给 aid 与 bvid，这里用 bvid 比对：
    // 不需要 aid，也就省掉一次 view 解析（BV↔aid 有短/长两种形态的
    // 历史问题，比对一律优先用 bvid 更稳）。
    var seen = 0;
    for (var pn = 1; pn <= _watchLaterMaxPages; pn++) {
      final json = await _getAuthed(
        '/x/v2/history/toview/web?platform=web&pn=$pn&ps=$_watchLaterPageSize',
        session: session,
      );
      final data = json['data'];
      if (data is! Map) return false;
      final d = Map<String, Object?>.from(data);

      final list = d['list'];
      if (list is! List || list.isEmpty) return false;

      for (final raw in list) {
        if (raw is! Map) continue;
        final m = Map<String, Object?>.from(raw);
        final bv = _nullableString(m['bvid']) ?? _nullableString(m['bv_id']);
        if (bv == platformVideoId) return true;
        // 顺手回填 aid 缓存：条目带 aid，之后收藏/评论路径省一次 view
        _rememberAid(platformVideoId, m['aid']);
      }
      seen += list.length;

      final total = _toInt(d['count']);
      if (total != null && seen >= total) return false;
    }
    return false;
  }

  /// 稍后再看读取的页大小与翻页上限。
  ///
  /// ps 固定 20：实测 ps>20 会让同族接口返回空数组（见
  /// [fetchWatchLater]）。上限 5 页 = 最多核对 100 条，
  /// 与平台"稍后再看最多 100 条"的口径一致。
  static const int _watchLaterPageSize = 20;
  static const int _watchLaterMaxPages = 5;

  /// 加入 / 移出"稍后再看"。
  ///
  /// 实测（2026-10-19，可逆写回环）：
  ///  - `POST /x/v2/history/toview/add`  参数 `aid` + `csrf` → `code=0 OK`
  ///  - `POST /x/v2/history/toview/del`  参数 **`aid`（单数）** + `csrf` → `code=0 OK`
  ///  - 同端点用 `aids=<JSON 数组>` 会返回 **`code=-400 请求错误`**（实测），
  ///    Web 端界面上看到的"批量删除"是另一个形态；这里按实测可用的
  ///    单数 `aid` 实现，**不要改回 aids=JSON**。
  ///
  /// # 写入后的读一致性
  ///
  /// 实测 add 成功（code=0）后立刻读 `toview/web`，`count` 会在约 1–2 秒内
  /// 反映变化，但**不保证即时**（同一轮里出现过 add 返回 0 而列表仍为空）。
  /// 因此本方法只声明"平台已接受"（`accepted`），
  /// 调用方若需如实回显，应重查 [fetchWatchLater]，不要在同一次点击里
  /// add 完马上读并据此判定失败。
  @override
  Future<InteractionResult> setWatchLater({
    required String platformVideoId,
    required bool add,
    required PlatformSession session,
  }) async {
    final aid = await _resolveAid(platformVideoId);
    if (aid == null) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '无法解析该视频的 aid，暂时无法操作稍后再看。',
        technicalMessage: 'Cannot resolve aid for $platformVideoId',
        platformId: id,
      );
    }

    final endpoint = add ? '/x/v2/history/toview/add' : '/x/v2/history/toview/del';
    final json = await _postAuthed(
      endpoint,
      body: {'aid': '$aid', 'platform': 'web', 'csrf': _csrfFrom(session)},
      session: session,
      endpoint: endpoint,
    );

    return InteractionResult(
      accepted: json['code'] == 0,
      message: _nullableString(json['message']),
      upstreamCode: json['code'],
    );
  }

  /// 关注 / 取关 UP 主。
  ///
  /// 实测（2026-10-19）：`POST /x/relation/modify`
  ///  - `fid` = UP 主 mid
  ///  - `act` = **1 关注 / 2 取关**（B 站这套码还有 3=拉黑、4=取消拉黑、5=屏蔽，
  ///    本方法只用 1/2，其余语义不对 UI 暴露）
  ///  - `re_sub` = 0（特别关注开关，固定 0）
  ///  - `csrf` 必带，否则 -111
  ///
  /// # 成败判定：code==0 还不够
  ///
  /// 这类写接口在风控/参数异常时会返回**空 body 或 data=null**，
  /// 而 code 仍可能是 0。只看 code 就会产生"假成功"：UI 提示已关注，
  /// 重新拉状态又变回未关注，用户看到的是"点了没反应"。
  /// 因此这里要求 `code == 0` **且** `data` 非 null 才算 accepted。
  /// （[_postAuthed] 只在 2xx 时返回，所以 HTTP 状态这一层已经由它把关；
  ///  非 2xx 会抛 [FusionException]，不会走到这里被当成成功。）
  ///
  /// 关注**状态**不在这里读：`archive/relation` 的 `data.attention`
  /// 已随互动状态一并返回（见 [fetchInteractionState]）。
  /// 另有权威读法 `GET /x/relation?fid=&ptype=1` 的 `attribute`
  /// （实测存在，0 = 未关注；平台另有 2 = 已关注等取值），
  /// 但那是多一个请求，按钮态不需要它。
  @override
  Future<InteractionResult> setFollowAuthor({
    required String targetMid,
    required bool follow,
    required PlatformSession session,
  }) async {
    final mid = _toInt(targetMid);
    if (mid == null || mid <= 0) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '无法识别该作者，暂时无法关注。',
        technicalMessage: 'invalid targetMid="$targetMid"',
        platformId: id,
      );
    }

    final json = await _postAuthed(
      '/x/relation/modify',
      body: {
        'fid': '$mid',
        'act': follow ? '1' : '2',
        're_sub': '0',
        'csrf': _csrfFrom(session),
      },
      session: session,
      endpoint: '/x/relation/modify',
    );

    final code = json['code'];
    final data = json['data'];
    final accepted = code == 0 && data != null;

    return InteractionResult(
      accepted: accepted,
      message: accepted
          ? _nullableString(json['message'])
          : (code == 0
              ? '平台返回成功但未给出结果（data 为空），关注状态未确认。'
              : _nullableString(json['message'])),
      upstreamCode: code,
    );
  }

  /// 带登录态的 GET，把平台的登录错误统一映射为 loginRequired。
  ///
  /// 与 [_postAuthed] 同一套码映射：只读接口不会遇到 -111（csrf），
  /// 但 -101 / -400 的处理必须一致，否则"登录失效"在不同入口表现不同。
  Future<Map<String, Object?>> _getAuthed(
    String path, {
    required PlatformSession session,
  }) async {
    final result = await _http.get(
      '$_apiBase$path',
      headers: {'Referer': _referer, 'Cookie': session.cookieHeader},
      platformId: id,
    );
    final json = result.jsonObject(platformId: id);
    final code = json['code'];
    if (code == -101) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '登录状态已失效，请重新登录后再操作。',
        technicalMessage: '$path returned -101 (not logged in)',
        upstreamCode: code,
        platformId: id,
      );
    }
    return json;
  }

  /// 带登录态的 POST，并把平台的登录错误统一映射为 loginRequired。
  Future<Map<String, Object?>> _postAuthed(
    String path, {
    required Map<String, String> body,
    required PlatformSession session,
    required String endpoint,
  }) async {
    final result = await _http.post(
      '$_apiBase$path',
      headers: {
        'Referer': _referer,
        'Origin': 'https://www.bilibili.com',
        'Cookie': session.cookieHeader,
        'Accept': 'application/json, text/plain, */*',
      },
      body: body.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'),
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
    final code = json['code'];

    // 登录态相关错误码：-101 未登录 / -111 csrf 校验失败
    if (code == -101) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '登录状态已失效，请重新登录后再操作。',
        technicalMessage: '$endpoint returned -101 (not logged in)',
        upstreamCode: code,
        platformId: id,
      );
    }
    if (code == -111) {
      throw FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: '操作凭证（csrf）无效，请重新登录。',
        technicalMessage: '$endpoint returned -111 (csrf failed)',
        upstreamCode: code,
        platformId: id,
      );
    }
    if (code == -400) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: _nullableString(json['message']) ?? '请求参数有误。',
        technicalMessage: '$endpoint returned -400',
        upstreamCode: code,
        platformId: id,
      );
    }

    return json;
  }

  /// 从会话 Cookie 中取 csrf（B 站用 bili_jct）。
  ///
  /// csrf 是 SESSDATA 的配套令牌，**不写入日志**。
  String _csrfFrom(PlatformSession session) =>
      session.cookies['bili_jct'] ?? '';

  /// 解析视频的 aid（评论与收藏写入接口需要数字 aid）。
  ///
  /// 结果按 bvid 缓存，见 [_aidCache]：BV↔aid 一成不变，
  /// 而评论分页与收藏写入会在同一次浏览里反复用到同一个 aid。
  ///
  /// 返回 null 表示解析失败（网络或风控）；**不缓存失败**，
  /// 否则一次抖动会让该视频在整个会话内再也拿不到 aid。
  Future<int?> _resolveAid(String platformVideoId) async {
    final cached = _aidCache[platformVideoId];
    if (cached != null) return cached;

    // BV 号 → aid 需要请求 view 接口。
    // 用 `_videoIdQuery` 而不是硬拼 `bvid=`：从 av 号链接进来的
    // platformVideoId 是 `av123` 形式，硬拼 bvid 会 404 → 收藏/评论
    // 全部失败。
    try {
      final result = await _http.get(
        '$_apiBase/x/web-interface/view?${_videoIdQuery(platformVideoId)}',
        headers: const {'Referer': _referer},
        platformId: id,
      );
      final json = result.jsonObject(platformId: id);
      if (json['code'] != 0) return null;
      final data = json['data'];
      if (data is! Map) return null;
      final aid = _toInt(data['aid']);
      if (aid != null) _aidCache[platformVideoId] = aid;
      return aid;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> resolveNumericVideoId(String platformVideoId) =>
      _resolveAid(platformVideoId);

  /// 用 view 接口返回的 aid 回填缓存（供已自行请求过 view 的路径复用）。
  void _rememberAid(String platformVideoId, Object? aid) {
    final parsed = _toInt(aid);
    if (parsed != null) _aidCache[platformVideoId] = parsed;
  }

  /// 把 `platformVideoId` 归一成 BV 号。
  ///
  /// # 为什么需要它
  ///
  /// `extract()` 对 `/video/av123`、`?aid=123`、纯数字这几种输入会返回
  /// **`av123` 形式**的 id（见 `_parseVideoId`）。而互动链路上有两类
  /// 接口对 id 形式很敏感：
  ///  - 收藏夹归属比对、稍后再看比对：平台列表里给的是 **bvid**，
  ///    拿 `av123` 去比永远不命中 → 面板回显"未收藏"、复查判"未生效"；
  ///  - `archive/like` / `coin/add` 的 `bvid` 参数：传 `av123` 直接报错。
  ///
  /// 所以凡是**必须用 bvid** 的地方，先过这个方法。BV↔aid 一一对应
  /// 且永不变更，可安全缓存。
  ///
  /// 解析失败时**原样返回**（保持旧行为），由调用方按接口报错如实上报，
  /// 不在这里静默改成别的 id。
  Future<String> _resolveBvid(String platformVideoId) async {
    if (platformVideoId.startsWith('BV')) return platformVideoId;
    final cached = _bvidCache[platformVideoId];
    if (cached != null) return cached;
    try {
      final result = await _http.get(
        '$_apiBase/x/web-interface/view?${_videoIdQuery(platformVideoId)}',
        headers: const {'Referer': _referer},
        platformId: id,
      );
      final json = result.jsonObject(platformId: id);
      if (json['code'] != 0) return platformVideoId;
      final data = json['data'];
      if (data is! Map) return platformVideoId;
      final bv = _nullableString(data['bvid']);
      if (bv == null || bv.isEmpty) return platformVideoId;
      _bvidCache[platformVideoId] = bv;
      // 同一次响应里顺带回填 aid，省掉后续一次 view
      _rememberAid(bv, data['aid']);
      _rememberAid(platformVideoId, data['aid']);
      return bv;
    } catch (_) {
      return platformVideoId;
    }
  }

  static String _stringOr(Object? value, String fallback) =>
      jsonToStringOr(value, fallback);

  static String? _epochToIso(Object? value) => jsonEpochToIso(value);

  /// 清晰度码值 → 展示标签。只标注实际已知的档位。
  static String _qualityLabel(int? id) => switch (id) {
        6 => '240P 极速',
        16 => '360P 流畅',
        32 => '480P 标清',
        64 => '720P 准高清',
        74 => '720P60 高清',
        80 => '1080P 高清',
        112 => '1080P+ 高码率',
        116 => '1080P60 高帧率',
        120 => '4K 超清',
        125 => 'HDR 真彩',
        126 => '杜比视界',
        127 => '8K 超高清',
        _ => '未知清晰度',
      };

  // ── 私信（IM）──────────────────────────────────────────────
  //
  // 私信在另一个 host（api.vc.bilibili.com）且要带 message.bilibili.com
  // 的 Referer/Origin，所以交给独立的 [BilibiliImClient] 处理，
  // 不把两套 host/头的规则混在这个文件里。

  late final BilibiliImClient _im = BilibiliImClient(
    http: _http,
    platformId: id,
    logger: _logger,
  );

  late final BilibiliImUploadClient _imUpload = BilibiliImUploadClient(
    http: _http,
    platformId: id,
    logger: _logger,
  );

  late final BilibiliEmoteClient _imEmote = BilibiliEmoteClient(
    http: _http,
    platformId: id,
    logger: _logger,
  );

  @override
  bool get supportsIm => true;

  /// 支持发送图片（上传接口 + 消息体形态均来自官方前端代码）。
  ///
  /// **注意**：能力"已实现"与"已验证跑通"是两件事。上传接口在本项目里
  /// 只验证到"匿名请求返回 -101"，带真实登录态的上传未验证。
  @override
  bool get supportsImImageSend => true;

  /// 支持读取表情面板。
  ///
  /// 同样是"已实现、未用真实登录态验证拿到列表"。
  @override
  bool get supportsImEmote => true;

  /// 支持发送自定义表情消息（协议层）。
  ///
  /// 但平台对"发送未收藏的表情"可能拒绝，本项目**未验证**，
  /// 因此 UI 不暴露该入口，只做接收侧渲染。
  @override
  bool get supportsImCustomEmojiSend => false;

  @override
  Future<ImSessionPage> fetchImSessions({
    required PlatformSession session,
    int count = 20,
    int endTs = 0,
  }) =>
      _im.fetchSessions(session: session, count: count, endTs: endTs);

  @override
  Future<ImMessagePage> fetchImMessages({
    required PlatformSession session,
    required int talkerId,
    int size = 20,
    int endSeqno = 0,
  }) =>
      _im.fetchMessages(
        session: session,
        talkerId: talkerId,
        size: size,
        endSeqno: endSeqno,
      );

  @override
  Future<ImSendResult> sendImMessage({
    required PlatformSession session,
    required int talkerId,
    required String content,
  }) =>
      _im.sendMessage(
        session: session,
        talkerId: talkerId,
        content: content,
      );

  @override
  Future<ImUnread> fetchImUnread({required PlatformSession session}) =>
      _im.fetchUnread(session: session);

  @override
  Future<Map<int, ImUserInfo>> fetchImUserInfos({
    required PlatformSession session,
    required List<int> uids,
  }) =>
      _im.fetchUserInfos(session: session, uids: uids);

  @override
  Future<bool> markImSessionRead({
    required PlatformSession session,
    required int talkerId,
    required int ackSeqno,
  }) =>
      _im.markRead(
        session: session,
        talkerId: talkerId,
        ackSeqno: ackSeqno,
      );

  @override
  Future<ImMedia> uploadImImage({
    required PlatformSession session,
    required List<int> bytes,
    required String filename,
  }) =>
      _imUpload.uploadImage(
        session: session,
        bytes: bytes,
        filename: filename,
      );

  @override
  Future<ImSendResult> sendImImage({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      _im.sendImageMessage(
        session: session,
        talkerId: talkerId,
        media: media,
      );

  @override
  Future<ImSendResult> sendImCustomEmoji({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      _im.sendCustomEmojiMessage(
        session: session,
        talkerId: talkerId,
        media: media,
      );

  @override
  Future<ImEmotePanel> fetchImEmotePanel({
    required PlatformSession session,
  }) =>
      _imEmote.fetchPanel(session: session);
}

/// 单个收藏夹的核对结果。
///
/// 这四态必须分开：**"没找到"与"没核对完"是两件不同的事**。
/// 把它们混成一个布尔，UI 就会把"还没翻到"显示成"用户没收藏进这个夹"。
enum _FolderScanOutcome {
  /// 命中：该夹包含该视频。
  hit,

  /// 翻到列表末尾仍未命中 → **确认不包含**。
  notFound,

  /// 请求失败、或页翻到上限仍未命中 → **不知道**（不计入已核对）。
  skipped,

  /// 被平台限流打断 → 停止整个扫描。
  rateLimitedStop,
}

/// 一次扫描的请求预算。
///
/// 随扫描传递的独立对象，**不是**适配器字段：扫描可能同时进行两次
/// （用户在列表里连开两个详情页），共享字段会让两次扫描互扣预算，
/// 结果各自只核对到一半。
///
/// 计数按**真实发出的请求数**（含 http_client 内部自动重试），
/// 不是按调用次数——否则一次"带 2 次内部重试"的调用会偷偷打 3 个请求，
/// 节流反而放大限流。
class _ScanBudget {
  _ScanBudget(this.limit);

  /// 允许的真实请求总数上限。
  final int limit;

  /// 已用量。
  int used = 0;

  /// 本次扫描是否撞到过限流。
  bool rateLimited = false;

  /// 是否还有余量发起下一个请求。
  bool get hasRoom => used < limit;

  /// 记账 n 个请求（可以超过上限：一次调用内部的重试也必须算进来，
  /// 低估用量等于把成本藏起来）。
  void consume([int n = 1]) => used += n;
}

/// 扫描内部一次 GET 的结果状态。
enum _ScanGetStatus { ok, rateLimited, budgetExhausted }

/// 扫描内部一次 GET 的返回值。
///
/// 用带状态的结构而不是 `Map?`：null 同时可能表示"预算用尽"和
/// "被限流"，调用方无法区分，就会把一种情况提示成另一种
/// （"该歇会儿再核对" vs "今天核对不完"）。
class _ScanGetResult {
  const _ScanGetResult.ok(this.json) : status = _ScanGetStatus.ok;
  const _ScanGetResult.rateLimited()
      : json = null,
        status = _ScanGetStatus.rateLimited;
  const _ScanGetResult.budgetExhausted()
      : json = null,
        status = _ScanGetStatus.budgetExhausted;

  final Map<String, Object?>? json;
  final _ScanGetStatus status;
}
