/// 红果短剧平台适配器。
///
/// # 数据来源（已实测）
///
/// 全部走**官网 Web 端** `hongguoduanju.com`，服务端渲染，
/// 零签名、零登录、零 Cookie。
///
/// | 能力 | 接口 | 状态 |
/// |---|---|---|
/// | 剧集列表 | `GET /` → `homeSections[].video_list[]` | ✅ 实测 36 部 |
/// | 剧集详情 + 分集 | `GET /player/{series_id}` → `vid_list` | ✅ 实测 76 集 |
/// | 播放直链 | `GET /video/public/{vid}/360p.mp4` | ✅ 实测 206 + ftyp |
/// | 搜索 | — | ❌ 未找到真实搜索接口 |
/// | 收藏 / 稍后看 / 互动 | — | ❌ 官网无公开接口 |
///
/// # 产品定位
///
/// **红果是短剧，不是社交平台。** 没有点赞、投币、三连、私信这些概念，
/// 硬塞进来只会让 UI 出现一堆点了没反应的按钮。
///
/// 因此本适配器只实现「浏览 → 选集 → 播放」这条主线，
/// 其余能力由 `PlatformAdapter` 的默认实现统一抛 `unsupportedPlatform`，
/// UI 依据 `supports*` 声明自动隐藏入口。
///
/// # 为什么不用 APP 端接口
///
/// APP 端有 `libmetasec_ml.so`（Argus 签名）+ 登录 + CDN 时效签名三层锁，
/// 且短剧播放路径在 dex 里**没有明文**。官网已经把 MP4 直链摊在 HTML 里。
library;

import '../core/errors.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../models/feed.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'hongguo/parser.dart';
import 'platform_adapter.dart';

/// 红果短剧适配器。
class HongguoAdapter extends PlatformAdapter {
  HongguoAdapter({
    required FusionHttpClient http,
    FusionLogger? logger,
    String siteOrigin = 'https://hongguoduanju.com',
  })  : _http = http,
        _logger = logger ?? appLogger,
        _origin = siteOrigin;

  final FusionHttpClient _http;
  final FusionLogger _logger;
  final String _origin;

  final HongguoParser _parser = const HongguoParser();

  /// 官网需要普通浏览器 UA。
  static const _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /// 首页剧集缓存（10 分钟）。官网首页 179 KB，不便宜。
  List<HongguoSeries>? _homeCache;
  DateTime? _homeCacheAt;
  static const _homeCacheTtl = Duration(minutes: 10);

  // ── 身份 ──────────────────────────────────────────────────

  @override
  String get id => 'hongguo';

  @override
  String get displayName => '红果短剧';

  @override
  String get shortLabel => '红果';

  // ── 能力声明：只声明实测可用的 ────────────────────────────
  //
  // 其余 supports* 走接口默认值 false，UI 自动隐藏入口。
  // 搜索未验证 → false；无评论/互动/直播/弹幕/私信 → 默认 false。

  @override
  bool get supportsSearch => false;

  @override
  bool get supportsComments => false;

  @override
  bool get supportsLike => false;

  @override
  bool get supportsCoin => false;

  @override
  bool get supportsFavorite => false;

  @override
  bool get supportsWatchLater => false;

  @override
  bool get supportsFollowAuthor => false;

  @override
  bool get supportsSavedContent => false;

  @override
  bool get supportsLive => false;

  @override
  bool get supportsVideoDanmaku => false;

  @override
  AdapterCapabilities get capabilities => const AdapterCapabilities(
        supportsMetadata: true,
        supportsNativePlayback: true,
        supportsOfficialEmbed: false,
        supportsExternalFallback: true,
        maxQualityWithoutAuth: '360p',
        notes: [
          '数据来自官网服务端渲染页面，不需要签名或登录',
          '播放直链仅验证过 360p',
          '红果是短剧平台，无点赞/投币/评论/私信等社交功能',
        ],
      );

  @override
  List<String> get supportedHosts => const ['hongguoduanju.com'];

  // ── 链接识别（必需）──────────────────────────────────────

  @override
  bool matches(Uri uri) {
    if (!supportedHosts.contains(uri.host)) return false;
    final segs = uri.pathSegments;
    if (segs.length < 2 || segs[0] != 'player') return false;
    return RegExp(r'^\d{10,25}$').hasMatch(segs[1]);
  }

  @override
  Future<LinkMatch?> extract(Uri uri) async {
    if (!matches(uri)) return null;
    final segs = uri.pathSegments;
    final seriesId = segs[1];
    final vid = segs.length >= 3 ? segs[2] : null;

    return LinkMatch(
      platformId: id,
      platformVideoId: seriesId,
      canonicalUrl: '$_origin/player/$seriesId',
      notes: [
        '红果剧集 ID: $seriesId',
        if (vid != null) '指定分集 vid: $vid',
      ],
    );
  }

  // ── 首页剧集列表 ──────────────────────────────────────────

  /// 拉取首页剧集（带 10 分钟缓存）。
  Future<List<HongguoSeries>> fetchSeriesList({
    bool forceRefresh = false,
  }) async {
    final cached = _homeCache;
    final at = _homeCacheAt;
    if (!forceRefresh &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < _homeCacheTtl) {
      return cached;
    }

    final html = await _fetchHtml('$_origin/');
    final list = _parser.parseHomepage(html);

    if (list.isEmpty) {
      _logger.warn('hongguo: homepage parsed empty', {
        'htmlLength': html.length,
      });
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '红果首页暂时没有可显示的剧集。',
        technicalMessage: 'parseHomepage returned empty '
            '(html=${html.length} bytes); 页面结构可能已变化',
        platformId: id,
        retryable: true,
      );
    }

    _homeCache = list;
    _homeCacheAt = DateTime.now();
    return list;
  }

  /// 按 tab 分组（热播短剧 / 热播真人剧 …）。
  Future<Map<String, List<HongguoSeries>>> fetchSeriesByTab({
    bool forceRefresh = false,
  }) async {
    final all = await fetchSeriesList(forceRefresh: forceRefresh);
    final grouped = <String, List<HongguoSeries>>{};
    for (final s in all) {
      grouped.putIfAbsent(s.tabName ?? '全部', () => []).add(s);
    }
    return grouped;
  }

  // ── 元数据（必需）────────────────────────────────────────

  @override
  Future<VideoMetadata> fetchMetadata(LinkMatch match) async {
    final detail = await fetchSeriesDetail(match.platformVideoId);
    final started = DateTime.now();

    return VideoMetadata(
      title: detail.title.isEmpty ? '红果短剧' : detail.title,
      description: detail.description,
      author: const VideoAuthor(name: '红果短剧'),
      coverUrl: detail.coverUrl,
      availability: VideoAvailability.available,
      limitations: const [
        '播放清晰度仅 360p（官网只提供这一档）',
        '红果是短剧平台，无评论/弹幕/互动功能',
      ],
      notes: [
        '共 ${detail.episodes.length} 集',
        '来源：官网服务端渲染页面',
        '耗时 ${DateTime.now().difference(started).inMilliseconds}ms',
      ],
      upstreamEndpoint: 'GET $_origin/player/{series_id}',
    );
  }

  /// 拉取剧集详情（含分集）。
  Future<HongguoSeriesDetail> fetchSeriesDetail(String seriesId) async {
    final html = await _fetchHtml('$_origin/player/$seriesId');
    final detail = _parser.parsePlayerPage(html, seriesId: seriesId);

    if (detail == null) {
      // 区分「剧集下架」与「页面结构变化」
      if (_parser.isMissingPage(html)) {
        throw FusionException(
          code: FusionErrorCode.videoNotFound,
          userMessage: '这部剧不存在或已下架。',
          technicalMessage: 'player page has no vid_list and no series_title '
              '(seriesId=$seriesId, html=${html.length} bytes)',
          platformId: id,
          retryable: false,
        );
      }
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '红果分集数据解析失败，可能是页面结构变化。',
        technicalMessage: 'parsePlayerPage returned null but page is not '
            'missing (seriesId=$seriesId, html=${html.length} bytes)',
        platformId: id,
        retryable: true,
      );
    }
    return detail;
  }

  // ── 播放（必需）──────────────────────────────────────────

  @override
  Future<PlaybackSource?> resolvePlayback(PlaybackRequest request) async {
    final videoId = request.platformVideoId;

    // videoId 可能是 seriesId，也可能带分集（`{seriesId}#{index}`）
    final parts = videoId.split('#');
    final seriesId = parts[0];
    final wantedIndex = parts.length > 1 ? int.tryParse(parts[1]) : null;

    final detail = await fetchSeriesDetail(seriesId);
    if (detail.episodes.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '这部剧暂时没有可播放的分集。',
        technicalMessage: 'episodes empty (seriesId=$seriesId)',
        platformId: id,
        retryable: false,
      );
    }

    final ep = wantedIndex != null
        ? detail.episodes.firstWhere(
            (e) => e.index == wantedIndex,
            orElse: () => detail.episodes.first,
          )
        : detail.episodes.first;

    return NativePlaybackSource(
      videoId: videoId,
      videoStreamUrl: ep.playUrl,
      // 官网 MP4 直链需要 Referer，否则可能 403
      requiredHeaders: {
        'Referer': '$_origin/',
        'User-Agent': _webUa,
      },
      quality: const PlaybackQuality(
        platformQualityId: null,
        label: '360p',
        height: 360,
      ),
      // 只列实测存在的档位
      availableQualities: const [
        PlaybackQuality(platformQualityId: null, label: '360p', height: 360),
      ],
      isDash: false,
    );
  }

  // ── 首页推荐流（必需）────────────────────────────────────

  @override
  List<FeedSource> get feedSources => const [
        FeedSource(
          id: 'home',
          adapterId: 'hongguo',
          label: '首页推荐',
          description: '官网首页热播短剧',
        ),
      ];

  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
  }) async {
    if (sourceId != 'home') {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '红果短剧暂不支持该内容来源。',
        technicalMessage: 'unknown hongguo feed sourceId=$sourceId',
        platformId: id,
        retryable: false,
      );
    }

    final started = DateTime.now();
    final list = await fetchSeriesList();
    final now = DateTime.now().toIso8601String();

    final items = list.map((s) {
      return UnifiedVideo(
        id: '$id:${s.seriesId}',
        platformId: id,
        platformVideoId: s.seriesId,
        originalUrl: '$_origin/player/${s.seriesId}',
        canonicalUrl: '$_origin/player/${s.seriesId}',
        title: s.title,
        description: s.description,
        author: const VideoAuthor(name: '红果短剧'),
        coverUrl: s.coverUrl,
        fetchedAt: now,
        availability: VideoAvailability.available,
        playbackModes: const [PlaybackMode.native],
        diagnostics: VideoDiagnostics(
          adapterId: id,
          upstreamEndpoint: 'GET $_origin/ (homeSections)',
          fromCache: false,
          fetchDurationMs: DateTime.now().difference(started).inMilliseconds,
          notes: [
            if (s.episodeCount != null) '共 ${s.episodeCount} 集',
            if (s.rank != null) '榜单第 ${s.rank} 名',
            if (s.tabName != null) '分区：${s.tabName}',
          ],
        ),
      );
    }).toList();

    return FeedPage(
      items: items,
      hasMore: false,
      adapterId: id,
      upstreamEndpoint: 'GET $_origin/ (homeSections)',
      notes: const ['来源：官网首页 homeSections'],
    );
  }

  // ── 搜索：如实不支持 ─────────────────────────────────────

  @override
  Future<FeedPage> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '红果短剧暂不支持搜索。',
        technicalMessage: 'hongguo: no verified public search endpoint '
            '(官网未找到搜索接口)',
        platformId: id,
        retryable: false,
      );

  // ── 内部 ──────────────────────────────────────────────────

  Future<String> _fetchHtml(String url) async {
    final res = await _http.get(
      url,
      headers: {
        'User-Agent': _webUa,
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': '$_origin/',
      },
      platformId: id,
      timeout: const Duration(seconds: 20),
    );

    if (res.statusCode == 404) {
      throw FusionException(
        code: FusionErrorCode.videoNotFound,
        userMessage: '这部剧不存在或已下架。',
        technicalMessage: 'HTTP 404 for $url',
        platformId: id,
        retryable: false,
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '红果页面加载失败（HTTP ${res.statusCode}）。',
        technicalMessage: 'HTTP ${res.statusCode} for $url',
        platformId: id,
        retryable: res.statusCode >= 500,
      );
    }
    if (res.body.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '红果返回了空页面，请稍后重试。',
        technicalMessage: 'empty body for $url',
        platformId: id,
        retryable: true,
      );
    }
    return res.body;
  }

  /// 清空首页缓存（下拉刷新用）。
  void clearCache() {
    _homeCache = null;
    _homeCacheAt = null;
  }
}
