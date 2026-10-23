/// 红果短剧平台适配器。
///
/// 支持剧集列表、详情、分集、播放（360p~1080p）。
/// 搜索、评论、点赞、投币、收藏、私信、直播均不支持。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import '../core/errors.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../models/feed.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'hongguo/media_client.dart';
import 'hongguo/parser.dart';
import 'hongguo/playback_id.dart';
import 'platform_adapter.dart';

/// 红果短剧适配器。
class HongguoAdapter extends PlatformAdapter {
  HongguoAdapter({
    required FusionHttpClient http,
    FusionLogger? logger,
    String siteOrigin = 'https://hongguoduanju.com',
  }) : _http = http,
       _logger = logger ?? appLogger,
       _origin = siteOrigin;

  final FusionHttpClient _http;
  final FusionLogger _logger;
  final String _origin;

  final HongguoParser _parser = const HongguoParser();

  /// 播放信息客户端（延迟创建，复用同一个 HTTP 客户端）。
  HongguoMediaClient? _media;
  HongguoMediaClient get _mediaClient =>
      _media ??= HongguoMediaClient(http: _http, logger: _logger);

  /// 尝试取完整清晰度；失败返回 null。
  Future<HongguoEpisodeMedia?> _tryFetchMainSource(String vid) async {
    try {
      final media = await _mediaClient.fetchEpisodeMedia(vid);
      _logger.debug('hongguo: signed source ok', {
        'vid': vid,
        'qualities': media.qualities.length,
        'highest': media.highest?.label,
      });
      return media;
    } catch (e) {
      // 保留到 logcat：签名链路失败是最常见的播放故障，
      // 只在 logger 里记会导致 release 版完全看不到原因。
      debugPrint('[hongguo] signed source failed: $e');
      _logger.warn('hongguo: main source failed, falling back to 360p', {
        'vid': vid,
        'error': '$e'.split('\n').first,
      });
      return null;
    }
  }

  /// 首页内容来源标识。
  ///
  /// 带平台前缀：来源 id 全仓库共享一个命名空间，
  /// 裸 id 会与其它平台撞名。
  static const String feedSourceHome = 'hongguo:home';

  /// 分类来源 id 前缀。
  static const String _categorySourcePrefix = 'hongguo:category:';

  static const String feedSourceRealDrama =
      '${_categorySourcePrefix}real-drama';
  static const String feedSourceComicDrama =
      '${_categorySourcePrefix}comic-drama';
  static const String feedSourceAiDrama = '${_categorySourcePrefix}ai-drama';

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
  // 无评论/互动/直播/弹幕/私信 → 默认 false。
  // 搜索已实现（2026-10-23），见下方 searchVideos。

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
    // 实测：签名链路给 5 档（360p/480p/540p/720p/1080p），
    // 不是"仅 360p"。这里如实标最高档。
    maxQualityWithoutAuth: '1080p',
    notes: [
      // 这三条曾经全是错的，2026-10-23 逐项实测后修正：
      //  - 旧文案"不需要签名或登录" → 实际要六头签名
      //  - 旧文案"播放直链仅验证过 360p" → 实际 5 档全实测可播
      //  - 旧文案漏了搜索 → 已实现
      '数据来自官网服务端渲染页面 + 签名接口（六头签名：'
          'khronos/ladon/argus/gorgon/helios/medusa），无需登录',
      '播放直链实测 5 档可播（360p / 480p / 540p / 720p / 1080p）',
      '支持搜索（官网 /api/search/result/，实测 totalCount 200+）',
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
      notes: ['红果剧集 ID: $seriesId', if (vid != null) '指定分集 vid: $vid'],
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
        technicalMessage:
            'parseHomepage returned empty '
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

  /// 分类页的 slug。
  static const categoryRealDrama = 'real-drama';
  static const categoryComicDrama = 'comic-drama';
  static const categoryAiDrama = 'ai-drama';

  /// 分类的中文名。
  static const Map<String, String> categoryLabels = {
    categoryRealDrama: '真人剧',
    categoryComicDrama: '漫剧',
    categoryAiDrama: 'AI 剧',
  };

  final Map<String, ({List<HongguoSeries> data, DateTime at})> _categoryCache =
      {};

  static const Duration _categoryCacheTtl = Duration(minutes: 10);

  /// 拉取某个分类的剧集（每页 24 部）。
  ///
  /// [slug] 取 [categoryRealDrama] / [categoryComicDrama] / [categoryAiDrama]。
  Future<List<HongguoSeries>> fetchCategory(
    String slug, {
    bool forceRefresh = false,
  }) async {
    final cached = _categoryCache[slug];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < _categoryCacheTtl) {
      return cached.data;
    }

    final html = await _fetchHtml('$_origin/category/$slug');
    final list = _parser.parseCategoryPage(html);

    if (list.isEmpty) {
      _logger.warn('hongguo: category parsed empty', {
        'slug': slug,
        'htmlLength': html.length,
      });
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '红果${categoryLabels[slug] ?? '该分类'}暂时没有可显示的剧集。',
        technicalMessage:
            'parseCategoryPage($slug) returned empty '
            '(html=${html.length} bytes)',
        platformId: id,
        retryable: true,
      );
    }

    _categoryCache[slug] = (data: list, at: DateTime.now());
    return list;
  }

  /// 已拉取过的分类（供诊断）。
  Iterable<String> get cachedCategories => _categoryCache.keys;

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
      limitations: const ['播放清晰度仅 360p（官网只提供这一档）', '红果是短剧平台，无评论/弹幕/互动功能'],
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
          technicalMessage:
              'player page has no vid_list and no series_title '
              '(seriesId=$seriesId, html=${html.length} bytes)',
          platformId: id,
          retryable: false,
        );
      }
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '红果分集数据解析失败，可能是页面结构变化。',
        technicalMessage:
            'parsePlayerPage returned null but page is not '
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
    // 用统一的编解码器解析，避免各处重复拼字符串
    final parsed = HongguoPlaybackId.parse(videoId);
    final seriesId = parsed?.seriesId ?? videoId;
    final wantedIndex = parsed?.episodeIndex;

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

    // 先走签名链路拿完整清晰度（全量覆盖，含 1080P）。
    //
    // 顺序很重要：以前是先探测「官网 360p」，探测不到就直接抛错，
    // 导致签名链路根本没机会执行。官网 360p 只覆盖零星几集，
    // 而签名链路是全量覆盖，必须先试后者。
    final media = await _tryFetchMainSource(ep.vid);
    if (media != null && !media.isEmpty) {
      final wanted = request.preferQuality;
      final picked = wanted != null
          ? media.pickByHeight(wanted)
          : media.highest;

      if (picked != null) {
        return NativePlaybackSource(
          videoId: videoId,
          videoStreamUrl: picked.url,
          requiredHeaders: const {},
          quality: PlaybackQuality(
            platformQualityId: picked.qualityType,
            label: picked.label,
            width: picked.width,
            height: picked.height,
            bandwidth: picked.bitrate,
          ),
          availableQualities: media.qualities
              .map(
                (q) => PlaybackQuality(
                  platformQualityId: q.qualityType,
                  label: q.label,
                  width: q.width,
                  height: q.height,
                  bandwidth: q.bitrate,
                ),
              )
              .toList(),
          videoFallbackUrls: [if (picked.backupUrl != null) picked.backupUrl!],
          isDash: false,
          expiresAt: media.expireAt.toUtc().toIso8601String(),
        );
      }
    }

    // 降级：官网 360p。
    //
    // 官网公开源不是每集都有（实测第 8、9、13–18、21–29 集 404），
    // 所以这里先探测再用，避免把 404 当成播放源交给播放器。
    final playable = await isEpisodePlayable(ep.vid);
    if (!playable) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '第 ${ep.index} 集暂时取不到播放地址，请稍后重试。',
        technicalMessage:
            'both paths failed for vid=${ep.vid} '
            '(seriesId=$seriesId, episode=${ep.index}): '
            'signed video_model returned no source, '
            'and official 360p HEAD returned non-2xx',
        platformId: id,
        retryable: true,
        diagnostics: {
          'seriesId': seriesId,
          'episode': ep.index,
          'vid': ep.vid,
        },
      );
    }

    return NativePlaybackSource(
      videoId: videoId,
      videoStreamUrl: ep.playUrl,
      requiredHeaders: {'Referer': '$_origin/', 'User-Agent': _webUa},
      quality: const PlaybackQuality(
        platformQualityId: null,
        label: '360p',
        height: 360,
      ),
      availableQualities: const [
        PlaybackQuality(platformQualityId: null, label: '360p', height: 360),
      ],
      isDash: false,
    );
  }

  /// 构造某一集的播放标识（供 UI 切换分集、记录进度用）。
  ///
  /// 返回的字符串同时用于：
  ///  - `PlaybackRequest.platformVideoId`（适配器据此定位分集）
  ///  - `VideoProgressStore.videoId`（按集存进度）
  String episodeVideoId(String seriesId, int episodeIndex) => HongguoPlaybackId(
    seriesId: seriesId,
    episodeIndex: episodeIndex,
  ).toVideoId();

  /// 构造某一集的 [UnifiedVideo]（供「选集」与「续播」用）。
  ///
  /// # 为什么需要这个
  ///
  /// 红果一部剧几十集，但 `UnifiedVideo.id` 是 `{platformId}:{platformVideoId}`。
  /// 如果所有分集共用同一个 `videoId`：
  ///
  ///  - 进度会串线（第 1 集看到 10 分钟，第 5 集继承）；
  ///  - 历史记录只有一条，看不出看到第几集。
  ///
  /// 因此分集必须有自己的 `platformVideoId`（`{seriesId}#{index}`），
  /// 由 [HongguoPlaybackId] 统一编码。
  UnifiedVideo episodeVideo({
    required String seriesId,
    required String seriesTitle,
    required int episodeIndex,
    required int totalEpisodes,
    String? coverUrl,
    String? description,
    String? fetchedAt,
  }) {
    final videoId = HongguoPlaybackId(
      seriesId: seriesId,
      episodeIndex: episodeIndex,
    ).toVideoId();
    final now = fetchedAt ?? DateTime.now().toIso8601String();

    return UnifiedVideo(
      id: videoId,
      platformId: id,
      platformVideoId: videoId,
      originalUrl: '$_origin/player/$seriesId',
      canonicalUrl: '$_origin/player/$seriesId',
      title: '$seriesTitle 第$episodeIndex集',
      description: description,
      author: const VideoAuthor(name: '红果短剧'),
      coverUrl: coverUrl,
      fetchedAt: now,
      availability: VideoAvailability.available,
      playbackModes: const [PlaybackMode.native],
      diagnostics: VideoDiagnostics(
        adapterId: id,
        upstreamEndpoint: 'GET $_origin/player/{series_id}',
        fromCache: false,
        fetchDurationMs: 0,
        notes: ['第 $episodeIndex 集 / 共 $totalEpisodes 集', '清晰度：360p'],
      ),
    );
  }

  /// 拉取剧集的全部分集（转成 [UnifiedVideo]，供选集列表用）。
  Future<List<UnifiedVideo>> fetchEpisodeVideos(String seriesId) async {
    final detail = await fetchSeriesDetail(seriesId);
    final now = DateTime.now().toIso8601String();
    return detail.episodes
        .map(
          (e) => episodeVideo(
            seriesId: seriesId,
            seriesTitle: detail.title,
            episodeIndex: e.index,
            totalEpisodes: detail.episodes.length,
            coverUrl: detail.coverUrl,
            description: detail.description,
            fetchedAt: now,
          ),
        )
        .toList();
  }

  /// 探测某一集的 360p 是否真的可播。
  ///
  /// # 为什么需要
  ///
  /// 实测发现：**官网的 360p 不是每集都有**。
  ///
  /// 逐集探测 76 集的结果（2026-10-20）：
  ///
  /// ```
  /// 第 1–7 集   ✓
  /// 第 8–9 集   ✗ 404
  /// 第 10–12 集 ✓
  /// 第 13–18 集 ✗ 404
  /// 第 19–20 集 ✓
  /// 第 21–29 集 ✗ 404
  /// 第 30、48 集 ✓（零散可用）
  /// 第 40 集以后 ✗ 404
  /// ```
  ///
  /// 这与 TV 版 Release 说明一致：「公开备用页面只开放前三集」
  /// ——实际是**部分集有兜底缓存**，不是完整覆盖。
  ///
  /// 因此不能假设「拿到 vid 就能播」，必须探测。
  Future<bool> isEpisodePlayable(String vid) async {
    if (vid.isEmpty) return false;
    try {
      final res = await _http.send(
        HttpRequestSpec(
          url: '$_origin/video/public/$vid/360p.mp4',
          method: 'HEAD',
          headers: {'User-Agent': _webUa, 'Referer': '$_origin/'},
          platformId: id,
          timeout: const Duration(seconds: 12),
        ),
      );
      return res.statusCode == 200 || res.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  /// 探测整部剧哪些集可播（供 UI 标记不可用集）。
  ///
  /// 并发限制 4，避免对平台造成压力。
  Future<Map<int, bool>> probeEpisodes(String seriesId) async {
    final detail = await fetchSeriesDetail(seriesId);
    final result = <int, bool>{};

    const concurrency = 4;
    for (var i = 0; i < detail.episodes.length; i += concurrency) {
      final batch = detail.episodes.skip(i).take(concurrency).toList();
      final results = await Future.wait(
        batch.map((e) => isEpisodePlayable(e.vid)),
      );
      for (var j = 0; j < batch.length; j++) {
        result[batch[j].index] = results[j];
      }
    }
    return result;
  }

  // ── 首页推荐流（必需）────────────────────────────────────

  @override
  List<FeedSource> get feedSources => const [
    FeedSource(
      // 标签必须带平台名：发现页的来源是一排 chip，
      // 用户只能靠标签认出平台。「首页推荐」会与
      // B站/抖音的推荐来源混淆，等于没有入口。
      id: feedSourceHome,
      adapterId: 'hongguo',
      label: '红果短剧',
      description: '热播短剧、真人剧、漫剧',
    ),
    FeedSource(
      id: feedSourceRealDrama,
      adapterId: 'hongguo',
      label: '真人剧',
      description: '真人出演的短剧',
    ),
    FeedSource(
      id: feedSourceComicDrama,
      adapterId: 'hongguo',
      label: '漫剧',
      description: '漫画风格的短剧',
    ),
    FeedSource(
      id: feedSourceAiDrama,
      adapterId: 'hongguo',
      label: 'AI 剧',
      description: 'AI 生成的短剧',
    ),
  ];

  @override
  Future<FeedPage> fetchFeed(
    FeedRequest request, {
    required String sourceId,
  }) async {
    // 分类源：feedSourceCategory:<slug>
    final slug = _categorySlugOf(sourceId);
    if (slug != null) return _fetchCategoryFeed(slug);

    if (sourceId != feedSourceHome) {
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

  /// 分类源的 feed。
  Future<FeedPage> _fetchCategoryFeed(String slug) async {
    final started = DateTime.now();
    final list = await fetchCategory(slug);
    final now = DateTime.now().toIso8601String();
    final label = categoryLabels[slug] ?? slug;

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
          upstreamEndpoint: 'GET $_origin/category/$slug (recommendList)',
          fromCache: false,
          fetchDurationMs: DateTime.now().difference(started).inMilliseconds,
          notes: [
            '分类：$label',
            if (s.episodeCount != null) '共 ${s.episodeCount} 集',
          ],
        ),
      );
    }).toList();

    return FeedPage(
      items: items,
      hasMore: false,
      adapterId: id,
      upstreamEndpoint: 'GET $_origin/category/$slug (recommendList)',
      notes: ['来源：官网分类页 $label'],
    );
  }

  /// 从 sourceId 解析分类 slug；不是分类源时返回 null。
  String? _categorySlugOf(String sourceId) {
    const prefix = 'hongguo:category:';
    if (!sourceId.startsWith(prefix)) return null;
    final slug = sourceId.substring(prefix.length);
    return categoryLabels.containsKey(slug) ? slug : null;
  }

  // ── 搜索 ─────────────────────────────────────────────────

  /// 红果支持搜索。
  ///
  /// 实测（2026-10-23）：官网确实有公开搜索接口，之前"未找到"是因为
  /// 只翻了解包产物、没看页面 HTML 里的 `_SdkGlueInit` 配置。
  /// 那个配置里明写着允许路径：
  /// ```
  /// bdms:{paths:{include:["^/api/search/result/?$",
  ///                       "^/api/search/suggestion/?$"]}}
  /// ```
  @override
  bool get supportsSearch => true;

  /// 搜索剧集。
  ///
  /// 接口：`GET /api/search/result/?query={关键词}&page={页码}`
  ///
  /// # 实测参数语义（2026-10-23，`query=总裁`）
  ///
  /// | 参数 | 结果 |
  /// |---|---|
  /// | `query=` | ✅ 正确（返回 `totalCount=204, totalPages=21`） |
  /// | `keyword=` / `q=` | ❌ `400 invalid_query` |
  /// | `page=2` | ✅ 生效（pageNum=2，首条换成另一部剧） |
  /// | `pageNum=2` | ❌ **不生效**（仍回 pageNum=1、同一批数据） |
  /// | `offset=20` | ❌ 不生效（与 offset=0 完全一样） |
  /// | `count=20` | ❌ 不生效（每页固定 10 条） |
  ///
  /// `pageNum` / `offset` 这两个"看起来该能用"的参数都会**静默失败**
  /// （HTTP 200 + 同一页数据），是这次踩到的主要坑——照搬响应字段名
  /// 当请求参数就会这样。真正生效的是 `page`。
  ///
  /// 关键词上限 30 字符（超出返回 `400 invalid_query`），本地先拦。
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
    if (keyword.length > 30) {
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '搜索词过长（最多 30 个字）。',
        technicalMessage: 'query length ${keyword.length} > 30',
        platformId: id,
      );
    }

    final safePage = page < 1 ? 1 : page;
    // pageSize 只是契约参数：平台每页固定 10 条，count 不生效。
    // 不谎报——把实际条数写进 notes。
    final url = '$_origin/api/search/result/'
        '?query=${Uri.encodeQueryComponent(keyword)}&page=$safePage';

    final started = DateTime.now();
    final res = await _http.get(
      url,
      headers: {
        'User-Agent': _webUa,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': '$_origin/',
      },
      platformId: id,
      timeout: const Duration(seconds: 20),
    );

    if (res.statusCode == 400) {
      // 平台自己的 invalid_query 也是 400，但本地已经拦了空/超长，
      // 走到这里说明是别的形态问题，如实报。
      throw FusionException(
        code: FusionErrorCode.invalidUrl,
        userMessage: '搜索词被平台拒绝，请换一个试试。',
        technicalMessage: 'search returned HTTP 400: '
            '${res.body.substring(0, res.body.length.clamp(0, 160))}',
        httpStatus: 400,
        platformId: id,
      );
    }
    if (res.statusCode != 200) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '红果搜索暂时不可用（HTTP ${res.statusCode}）。',
        technicalMessage: 'search HTTP ${res.statusCode}',
        httpStatus: res.statusCode,
        platformId: id,
        retryable: res.statusCode >= 500,
      );
    }

    final parsed = _parser.parseSearchResult(res.body);
    if (parsed.isEmpty) {
      // 区分"没搜到"与"解析失败"：平台给了 totalCount>0 却解析不出条目，
      // 说明结构变了，不能伪装成"没有结果"。
      if (parsed.totalCount > 0) {
        throw FusionException(
          code: FusionErrorCode.parseError,
          userMessage: '搜索结果解析失败，接口结构可能已变化。',
          technicalMessage:
              'parseSearchResult returned 0 items but totalCount='
              '${parsed.totalCount} (body=${res.body.length} bytes)',
          platformId: id,
          retryable: false,
        );
      }
      return FeedPage(
        items: const [],
        hasMore: false,
        adapterId: id,
        upstreamEndpoint: 'GET $_origin/api/search/result/',
        notes: ['没有找到「$keyword」相关的短剧。'],
      );
    }

    final now = DateTime.now().toIso8601String();
    final items = parsed.items.map((s) {
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
          upstreamEndpoint: 'GET $_origin/api/search/result/',
          fromCache: false,
          fetchDurationMs: DateTime.now().difference(started).inMilliseconds,
          notes: [
            '搜索「$keyword」',
            if (s.episodeCount != null) '共 ${s.episodeCount} 集',
            '第 ${parsed.pageNum}/${parsed.totalPages} 页',
          ],
        ),
      );
    }).toList();

    return FeedPage(
      items: items,
      // 平台给了 hasMore，同时用页码兜底（两者都成立才算还有）
      hasMore: parsed.hasMore && parsed.pageNum < parsed.totalPages,
      adapterId: id,
      upstreamEndpoint: 'GET $_origin/api/search/result/',
      notes: [
        '共 ${parsed.totalCount} 部相关短剧',
        // 如实说明：平台每页固定 10 条，pageSize 参数不生效
        '每页 ${parsed.items.length} 条（平台固定 10 条/页）',
      ],
    );
  }

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
