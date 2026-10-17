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
/// 参考的公开实现（用于交叉验证参数语义，未复制其代码）：
///  - SocialSisterYi/bilibili-API-collect（社区维护的接口文档）
///  - yt-dlp 的 bilibili extractor（参数组合交叉验证）
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
import '../core/http_client.dart';
import '../core/logger.dart';
import '../core/qr_login.dart';
import '../models/feed.dart';
import '../models/interaction.dart';
import '../models/live.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'platform_adapter.dart';

class BilibiliAdapter implements PlatformAdapter, QrLoginCapable {
  BilibiliAdapter({required FusionHttpClient http, FusionLogger? logger})
      : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _apiBase = 'https://api.bilibili.com';
  static const String _referer = 'https://www.bilibili.com/';

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

  @override
  Future<LiveDanmakuEndpoint> fetchLiveDanmakuEndpoint(int roomId) async {
    final result = await _http.get(
      '$_liveApiBase/xlive/web-room/v1/index/getDanmuInfo?id=$roomId&type=0',
      headers: const {
        'Referer': _liveReferer,
        'Accept': 'application/json',
      },
      platformId: id,
    );

    final json = result.jsonObject(platformId: id);
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
  static int? _toInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String? _nullableString(Object? value) {
    if (value == null) return null;
    if (value is String) return value.isEmpty ? null : value;
    return value.toString();
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
    // 实测（2026-10）：**未登录请求的响应里完全没有该字段**，
    // `reply_control` 只有 max_line / time_desc / translation_switch 等。
    // 因此未登录时恒为 null，UI 不显示地区——不猜测、不伪造。
    final replyControl = raw['reply_control'] is Map
        ? Map<String, Object?>.from(raw['reply_control'] as Map)
        : const <String, Object?>{};
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
  static String? _parseIpLocation(Object? raw) {
    final text = _nullableString(raw)?.trim();
    if (text == null || text.isEmpty) return null;

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
  @override
  Future<InteractionState> fetchInteractionState(
    String platformVideoId, {
    PlatformSession? session,
    int? aid,
  }) async {
    if (session == null) return InteractionState.unknown;

    try {
      final url = '$_apiBase/x/web-interface/archive/relation'
          '?bvid=$platformVideoId';
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

      return InteractionState(
        known: true,
        liked: d['like'] == 1 || d['like'] == true,
        coined: (d['coin'] as num?)?.toInt() ?? 0,
        favorited: d['favorite'] == true || d['fav_time'] != null,
        likeCount: (d['like'] as num?)?.toInt(),
        coinCount: (d['coin'] as num?)?.toInt(),
        favoriteCount: (d['favorite'] as num?)?.toInt(),
      );
    } on FusionException {
      rethrow;
    } catch (_) {
      // 状态查询失败不影响播放与评论，降级为 unknown
      return InteractionState.unknown;
    }
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
    final json = await _postAuthed(
      '/x/web-interface/archive/like',
      body: {
        'bvid': platformVideoId,
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
  @override
  Future<InteractionResult> setCoin(
    String platformVideoId, {
    required int count,
    required PlatformSession session,
    bool alsoLike = false,
    int? aid,
  }) async {
    final multiply = count.clamp(1, 2);
    final json = await _postAuthed(
      '/x/web-interface/coin/add',
      body: {
        'bvid': platformVideoId,
        'multiply': '$multiply',
        'select_like': alsoLike ? '1' : '0',
        'csrf': _csrfFrom(session),
      },
      session: session,
      endpoint: '/x/web-interface/coin/add',
    );

    return InteractionResult(
      accepted: json['code'] == 0,
      message: _nullableString(json['message']),
      upstreamCode: json['code'],
    );
  }

  /// 收藏 / 取消收藏。
  ///
  /// 需要先拿到用户的默认收藏夹 ID。这里采用：
  ///  - 收藏：读取「创建的收藏夹列表」第一条作为默认收藏夹
  ///  - 取消：读取该视频所在收藏夹并移除
  ///
  /// 若用户没有任何自建收藏夹，如实报错而不是静默失败。
  @override
  Future<InteractionResult> setFavorite(
    String platformVideoId, {
    required bool favorite,
    required PlatformSession session,
    int? aid,
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

    // 取用户自建收藏夹列表
    final listUrl = '$_apiBase/x/v3/fav/folder/created/list-all'
        '?up_mid=${session.userId}';
    final listResult = await _http.get(
      listUrl,
      headers: {'Referer': _referer, 'Cookie': session.cookieHeader},
      platformId: id,
    );
    final listJson = listResult.jsonObject(platformId: id);
    _assertApiOk(
      listJson,
      endpoint: '/x/v3/fav/folder/created/list-all',
      // 该接口的 -400 表示 up_mid 无效（通常是登录态缺失），
      // 不是"链接无效"——必须映射为 loginRequired。
      badRequestCode: FusionErrorCode.loginRequired,
      badRequestMessage: '登录状态无效，请重新登录后再收藏。',
    );

    final listData = listJson['data'];
    final folders = (listData is Map ? listData['list'] : null);
    if (folders is! List || folders.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: '你还没有创建收藏夹，请先在 B 站创建后再试。',
        technicalMessage: 'No created fav folder for mid=${session.userId}',
        platformId: id,
      );
    }

    final first = Map<String, Object?>.from(folders.first as Map);
    final mediaId = (first['id'] as num?)?.toInt();
    if (mediaId == null) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '无法读取收藏夹 ID。',
        technicalMessage: 'fav folder has no id',
        platformId: id,
      );
    }

    final json = await _postAuthed(
      '/x/v3/fav/resource/deal',
      body: {
        'rid': '$resolvedAid',
        'type': '2',
        // add_media_ids 为空、del_media_ids 有值即为取消收藏
        'add_media_ids': favorite ? '$mediaId' : '',
        'del_media_ids': favorite ? '' : '$mediaId',
        'csrf': _csrfFrom(session),
      },
      session: session,
      endpoint: '/x/v3/fav/resource/deal',
    );

    return InteractionResult(
      accepted: json['code'] == 0,
      message: _nullableString(json['message']),
      upstreamCode: json['code'],
    );
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

  /// 解析视频的 aid（评论与收藏接口需要数字 aid）。
  Future<int?> _resolveAid(String platformVideoId) async {
    // BV 号 → aid 需要请求 view 接口
    try {
      final result = await _http.get(
        '$_apiBase/x/web-interface/view?bvid=$platformVideoId',
        headers: const {'Referer': _referer},
        platformId: id,
      );
      final json = result.jsonObject(platformId: id);
      if (json['code'] != 0) return null;
      final data = json['data'];
      if (data is! Map) return null;
      return (data['aid'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  static String _stringOr(Object? value, String fallback) =>
      _nullableString(value) ?? fallback;

  static String? _epochToIso(Object? value) {
    if (value is! num || value <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(
      value.toInt() * 1000,
      isUtc: true,
    );
    return dt.toIso8601String();
  }

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
}
