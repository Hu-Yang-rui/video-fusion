/// 视频服务：链接接入、元数据获取、列表聚合、播放解析的统一编排层。
///
/// 职责边界：
///  - 这是 UI 唯一需要依赖的业务入口。
///  - UI 层不得直接调用任何平台接口，也不得做平台判断。
///  - 单个平台的失败不得阻塞其它平台的可用内容。
library;

import '../adapters/platform_adapter.dart';
import '../adapters/platform_registry.dart';
import '../core/cache.dart';
import '../core/credential_vault.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../core/playback_policy.dart';
import '../models/feed.dart';
import '../models/interaction.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';
import 'video_store.dart';

/// 推荐流拉取结果。
///
/// **失败与"没有内容"必须可区分**：失败时 [error] 非 null，
/// 且 [items] 为空。UI 据此分别展示错误态与空态。
class FeedFetchResult {
  const FeedFetchResult({
    required this.sourceId,
    this.page,
    this.error,
  });

  final String sourceId;
  final FeedPage? page;
  final FusionException? error;

  bool get ok => error == null;

  List<UnifiedVideo> get items => page?.items ?? const [];

  bool get hasMore => page?.hasMore ?? false;

  int get nextOffset => page?.nextOffset ?? 0;
}

/// 某平台支持的互动能力集合。UI 据此决定显示哪些按钮，
/// 不支持的按钮不渲染（而不是渲染后点了报错）。
class InteractionCapabilities {
  const InteractionCapabilities({
    required this.comments,
    required this.like,
    required this.coin,
    required this.favorite,
  });

  final bool comments;
  final bool like;
  final bool coin;
  final bool favorite;

  static const InteractionCapabilities none = InteractionCapabilities(
    comments: false,
    like: false,
    coin: false,
    favorite: false,
  );

  bool get hasAny => comments || like || coin || favorite;
}

/// 跨平台搜索结果。
///
/// 与 [FeedFetchResult] 相同的原则：**失败与"没有结果"必须可区分**。
/// 部分平台失败时 [items] 仍有内容，失败详情在 [failures] 中。
class SearchResult {  const SearchResult({
    required this.query,
    required this.items,
    required this.failures,
    this.error,
  });

  final String query;
  final List<UnifiedVideo> items;

  /// 平台 id → 该平台的失败原因。
  final Map<String, FusionException> failures;

  /// 全部平台失败时的统一错误；部分成功时为 null。
  final FusionException? error;

  bool get ok => error == null;

  bool get hasPartialFailure => failures.isNotEmpty && items.isNotEmpty;

  bool get isEmpty => items.isEmpty;
}

/// 链接接入结果。
class ResolveResult {
  const ResolveResult({
    this.video,
    this.error,
    this.match,
    this.fromCache = false,
  });

  final UnifiedVideo? video;
  final FusionException? error;
  final LinkMatch? match;
  final bool fromCache;

  /// 是否拿到了可用的视频实体。
  ///
  /// 注意：`refresh` 降级时会**保留旧实体并附带错误**，
  /// 此时 [ok] 为 true 但 [degraded] 也为 true。
  /// 需要判断"本次操作是否完全成功"时应使用 [succeeded]。
  bool get ok => video != null;

  /// 本次操作是否完全成功（无错误）。
  bool get succeeded => video != null && error == null;

  /// 是否处于降级状态：保留了旧元数据，但本次刷新失败。
  bool get degraded => video != null && error != null;
}

/// 视频服务。
class VideoService {
  VideoService({
    required PlatformRegistry registry,
    required VideoStore store,
    VideoCache? cache,
    FusionLogger? logger,
    PlaybackPolicy? policy,
  })  : _registry = registry,
        _store = store,
        _cache = cache ?? VideoCache(),
        _logger = logger ?? appLogger,
        _policy = policy ?? PlaybackPolicy(registry: registry, logger: logger);

  final PlatformRegistry _registry;
  final VideoStore _store;
  final VideoCache _cache;
  final FusionLogger _logger;
  final PlaybackPolicy _policy;

  VideoCache get cache => _cache;

  PlatformRegistry get registry => _registry;

  /// 已接入平台的来源描述（首页"来源区域"使用）。
  List<PlatformDescriptor> describePlatforms() => _registry.describeAll();

  // ── 互动能力编排 ────────────────────────────────────────────
  //
  // 统一入口：UI 只调这里，不直接接触适配器。
  // 所有方法把失败归一化为 FusionException 并抛出，
  // 由 UI 决定如何呈现（登录引导 / 重试 / 明确报错）。

  /// 该视频所属平台支持哪些互动能力。
  InteractionCapabilities capabilitiesFor(String platformId) {
    final adapter = _registry.byId(platformId);
    if (adapter == null) return InteractionCapabilities.none;
    return InteractionCapabilities(
      comments: adapter.supportsComments,
      like: adapter.supportsLike,
      coin: adapter.supportsCoin,
      favorite: adapter.supportsFavorite,
    );
  }

  /// 拉取评论列表。
  Future<CommentPage> fetchComments(
    UnifiedVideo video, {
    int page = 1,
    int pageSize = 20,
    PlatformSession? session,
  }) async {
    final adapter = _registry.byId(video.platformId);
    if (adapter == null || !adapter.supportsComments) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持评论。',
        technicalMessage: 'No comment support for ${video.platformId}',
        platformId: video.platformId,
      );
    }
    return adapter.fetchComments(
      video.platformVideoId,
      page: page,
      pageSize: pageSize,
      session: session,
    );
  }

  /// 查询互动状态。
  Future<InteractionState> fetchInteractionState(
    UnifiedVideo video, {
    PlatformSession? session,
  }) async {
    final adapter = _registry.byId(video.platformId);
    if (adapter == null) return InteractionState.unknown;
    return adapter.fetchInteractionState(
      video.platformVideoId,
      session: session,
    );
  }

  /// 点赞 / 取消点赞。
  ///
  /// 未登录时抛 [FusionErrorCode.loginRequired]。
  Future<InteractionResult> setLike(
    UnifiedVideo video, {
    required bool like,
    PlatformSession? session,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '点赞');
    return adapter.setLike(
      video.platformVideoId,
      like: like,
      session: session!,
    );
  }

  /// 投币。
  Future<InteractionResult> setCoin(
    UnifiedVideo video, {
    required int count,
    PlatformSession? session,
    bool alsoLike = false,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '投币');
    return adapter.setCoin(
      video.platformVideoId,
      count: count,
      session: session!,
      alsoLike: alsoLike,
    );
  }

  /// 收藏 / 取消收藏。
  Future<InteractionResult> setFavorite(
    UnifiedVideo video, {
    required bool favorite,
    PlatformSession? session,
  }) async {
    final adapter = _requireInteractionAdapter(video, session, '收藏');
    return adapter.setFavorite(
      video.platformVideoId,
      favorite: favorite,
      session: session!,
    );
  }

  /// 互动写操作的统一前置校验：适配器存在 + 已登录。
  PlatformAdapter _requireInteractionAdapter(
    UnifiedVideo video,
    PlatformSession? session,
    String action,
  ) {
    final adapter = _registry.byId(video.platformId);
    if (adapter == null) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台尚未接入。',
        technicalMessage: 'No adapter for ${video.platformId}',
        platformId: video.platformId,
      );
    }
    if (session == null) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '请先登录 $action 所属的平台账号。',
        technicalMessage: 'No session for ${video.platformId} ($action)',
        platformId: video.platformId,
        retryable: false,
      );
    }
    return adapter;
  }

  /// 全部推荐流来源，按适配器注册顺序汇总。
  ///
  /// 这是唯一的"内容来源"清单入口。UI 层不得硬编码任何平台判断。
  List<FeedSource> describeFeedSources() {
    final out = <FeedSource>[];
    for (final adapter in _registry.adapters) {
      out.addAll(adapter.feedSources);
    }
    return out;
  }

  /// 拉取一页推荐流。
  ///
  /// 失败时返回带明确错误的 [FeedFetchResult]，不抛异常给 UI。
  /// **不把失败伪装成空列表**——两者在 UI 上是不同的状态。
  Future<FeedFetchResult> fetchFeed(
    String sourceId, {
    FeedRequest request = const FeedRequest(),
  }) async {
    PlatformAdapter? owner;
    for (final adapter in _registry.adapters) {
      if (adapter.feedSources.any((s) => s.id == sourceId)) {
        owner = adapter;
        break;
      }
    }

    if (owner == null) {
      return FeedFetchResult(
        sourceId: sourceId,
        error: FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage: '该内容来源不存在。',
          technicalMessage: 'No adapter declares feed sourceId=$sourceId',
        ),
      );
    }

    try {
      final page = await owner.fetchFeed(request, sourceId: sourceId);
      return FeedFetchResult(sourceId: sourceId, page: page);
    } on FusionException catch (e) {
      _logger.warn('feed fetch failed', {
        'source': sourceId,
        'platform': owner.id,
        'code': e.code.name,
      });
      return FeedFetchResult(sourceId: sourceId, error: e);
    } catch (e) {
      return FeedFetchResult(
        sourceId: sourceId,
        error: normalizeError(e, platformId: owner.id),
      );
    }
  }

  /// 链接接入：识别平台 → 提取 ID → 获取元数据 → 入库。
  ///
  /// 失败时返回带明确错误的 [ResolveResult]，不抛异常给 UI。
  Future<ResolveResult> resolveLink(String rawInput) async {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '请输入视频链接。',
          technicalMessage: 'Empty input',
        ),
      );
    }

    // 从分享文案中提取 URL（抖音/B站分享常带描述文字）
    final extracted = _extractUrl(input);
    final uri = Uri.tryParse(extracted);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '这不是一个有效的链接，请检查后重试。',
          technicalMessage: 'Unparsable URL: ${Redactor.safeUrl(extracted)}',
        ),
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '仅支持 http/https 链接。',
          technicalMessage: 'Unsupported scheme: ${uri.scheme}',
        ),
      );
    }

    // 唯一平台判定入口
    final adapter = _registry.match(uri);
    if (adapter == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage:
              '暂不支持该链接所属的平台。当前已接入：${_registry.adapters.map((a) => a.displayName).join('、')}。',
          technicalMessage: 'No adapter matched host=${uri.host}',
        ),
      );
    }

    LinkMatch? match;
    try {
      match = await adapter.extract(uri);
    } on FusionException catch (e) {
      return ResolveResult(error: e, match: null);
    } catch (e) {
      return ResolveResult(
        error: normalizeError(e, platformId: adapter.id),
      );
    }

    if (match == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.videoIdNotFound,
          userMessage: '无法从该链接中识别出视频 ID，请确认链接指向的是单个视频。',
          technicalMessage:
              'Adapter ${adapter.id} matched but returned no video id for ${Redactor.safeUrl(extracted)}',
          platformId: adapter.id,
        ),
      );
    }

    final videoId = makeVideoId(match.platformId, match.platformVideoId);

    // 同一视频重复导入：命中缓存直接返回
    final cached = _cache.metadata.peek(videoId);
    if (cached != null && !cached.stale) {
      final existing = _cache.markFromCache(cached.value);
      await _store.upsert(existing);
      return ResolveResult(video: existing, match: match, fromCache: true);
    }

    // 已在库中且未过期
    final stored = await _store.get(videoId);
    if (stored != null && _isFresh(stored)) {
      return ResolveResult(
        video: stored.copyWith(
          diagnostics: stored.diagnostics.copyWith(fromCache: true),
        ),
        match: match,
        fromCache: true,
      );
    }

    // 获取元数据
    try {
      final video = await _fetchAndBuild(adapter, match, extracted);
      await _store.upsert(video);
      return ResolveResult(video: video, match: match);
    } on FusionException catch (e) {
      _logger.warn('metadata fetch failed', {
        'platform': adapter.id,
        'videoId': match.platformVideoId,
        'code': e.code.name,
        'detail': e.technicalMessage,
      });
      return ResolveResult(error: e, match: match);
    } catch (e) {
      return ResolveResult(
        error: normalizeError(e, platformId: adapter.id),
        match: match,
      );
    }
  }

  /// 获取元数据并构造 [UnifiedVideo]。ID / 时间戳 / 诊断由核心层统一负责。
  Future<UnifiedVideo> _fetchAndBuild(
    PlatformAdapter adapter,
    LinkMatch match,
    String originalUrl,
  ) async {
    final startedAt = DateTime.now();
    final metadata = await adapter.fetchMetadata(match);
    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;

    final video = UnifiedVideo(
      id: makeVideoId(match.platformId, match.platformVideoId),
      platformId: match.platformId,
      platformVideoId: match.platformVideoId,
      originalUrl: originalUrl,
      canonicalUrl: match.canonicalUrl,
      title: metadata.title,
      description: metadata.description,
      author: metadata.author,
      coverUrl: metadata.coverUrl,
      durationSeconds: metadata.durationSeconds,
      aspectRatio: normalizeAspectRatio(metadata.width, metadata.height),
      width: metadata.width,
      height: metadata.height,
      publishedAt: metadata.publishedAt,
      fetchedAt: DateTime.now().toUtc().toIso8601String(),
      stats: metadata.stats,
      availability: metadata.availability,
      playbackModes: _playbackModesFor(adapter),
      requiresAuth: metadata.requiresAuth,
      diagnostics: VideoDiagnostics(
        adapterId: adapter.id,
        upstreamEndpoint: metadata.upstreamEndpoint,
        fromCache: false,
        fetchDurationMs: durationMs,
        limitations: metadata.limitations,
        notes: [...match.notes, ...metadata.notes],
      ),
    );

    _cache.metadata.put(video.id, video);
    return video;
  }

  /// 适配器能力 → 该视频理论上可用的播放模式列表（按优先级）。
  ///
  /// 注意：这是"声明可用"，真实可用性由 [PlaybackPolicy] 在实际解析时验证。
  List<PlaybackMode> _playbackModesFor(PlatformAdapter adapter) {
    final caps = adapter.capabilities;
    return [
      if (caps.supportsNativePlayback) PlaybackMode.native,
      if (caps.supportsOfficialEmbed) PlaybackMode.officialEmbed,
      if (caps.supportsExternalFallback) PlaybackMode.external,
    ];
  }

  /// 支持搜索的平台适配器列表。
  List<PlatformAdapter> get searchableAdapters =>
      _registry.adapters.where((a) => a.supportsSearch).toList();

  /// 跨平台搜索。
  ///
  /// 并行请求所有支持搜索的平台，合并结果。
  /// **单个平台失败不影响其它平台**：失败记录在 [SearchResult.failures] 中，
  /// 成功的结果照常返回。
  Future<SearchResult> searchVideos(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SearchResult(
        query: query,
        items: const [],
        failures: const <String, FusionException>{},
        error: FusionException(
          code: FusionErrorCode.invalidUrl,
          userMessage: '请输入搜索关键词。',
          technicalMessage: 'Empty search query',
        ),
      );
    }

    final adapters = searchableAdapters;
    if (adapters.isEmpty) {
      return SearchResult(
        query: trimmed,
        items: const [],
        failures: const <String, FusionException>{},
        error: FusionException(
          code: FusionErrorCode.capabilityUnavailable,
          userMessage: '当前没有支持搜索的平台。',
          technicalMessage: 'No adapter declares supportsSearch',
        ),
      );
    }

    final items = <UnifiedVideo>[];
    final failures = <String, FusionException>{};

    final results = await Future.wait<MapEntry<String, Object>>(
      adapters.map((a) async {
        try {
          final page0 = await a.searchVideos(
            trimmed,
            page: page,
            pageSize: pageSize,
          );
          return MapEntry<String, Object>(a.id, page0);
        } on FusionException catch (e) {
          return MapEntry<String, Object>(a.id, e);
        } catch (e) {
          return MapEntry<String, Object>(
            a.id,
            normalizeError(e, platformId: a.id),
          );
        }
      }),
    );

    for (final entry in results) {
      final value = entry.value;
      if (value is FeedPage) {
        items.addAll(value.items);
      } else if (value is FusionException) {
        failures[entry.key] = value;
      }
    }

    // 全部失败才算失败
    final allFailed = items.isEmpty && failures.length == adapters.length;
    return SearchResult(
      query: trimmed,
      items: items,
      failures: failures,
      error: allFailed
          ? (failures.values.firstOrNull ??
              FusionException(
                code: FusionErrorCode.capabilityUnavailable,
                userMessage: '搜索失败。',
                technicalMessage: 'All search adapters failed',
              ))
          : null,
    );
  }

  /// 解析播放源。
  Future<PlaybackOutcome> resolvePlayback(UnifiedVideo video) async {
    // 播放直链缓存（短 TTL）
    final cached = _cache.playback.peek(video.id);
    if (cached != null && !cached.stale) {
      return PlaybackOutcome(
        videoId: video.id,
        attempts: [
          PlaybackAttempt(
            mode: cached.value.mode,
            succeeded: true,
            detail: '使用缓存的播放地址。',
          ),
        ],
        source: cached.value,
      );
    }

    final outcome = await _policy.resolve(video);
    final source = outcome.source;
    if (source != null && source is NativePlaybackSource) {
      _cache.playback.put(video.id, source);
    }
    return outcome;
  }

  /// 列表聚合：返回库中全部视频，按导入时间倒序。
  ///
  /// 平台间互不阻塞：单个视频的错误状态内嵌在实体中，不影响其它条目。
  Future<List<UnifiedVideo>> listVideos() => _store.all();

  /// 重新获取单个视频的元数据（忽略缓存）。
  Future<ResolveResult> refresh(String videoId) async {
    final existing = await _store.get(videoId);
    if (existing == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.videoNotFound,
          userMessage: '该视频不在库中。',
          technicalMessage: 'No stored video with id=$videoId',
        ),
      );
    }

    _cache.metadata.invalidate(videoId);
    _cache.playback.invalidate(videoId);

    final adapter = _registry.byId(existing.platformId);
    if (adapter == null) {
      return ResolveResult(
        error: FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage: '该平台适配器已不可用。',
          technicalMessage: 'Missing adapter ${existing.platformId}',
          platformId: existing.platformId,
        ),
      );
    }

    final match = LinkMatch(
      platformId: existing.platformId,
      platformVideoId: existing.platformVideoId,
      canonicalUrl: existing.canonicalUrl,
    );

    try {
      final video = await _fetchAndBuild(adapter, match, existing.originalUrl);
      await _store.upsert(video);
      return ResolveResult(video: video, match: match);
    } on FusionException catch (e) {
      // 刷新失败时保留旧元数据，只更新错误状态（不删除、不隐藏）
      final degraded = existing.copyWith(
        error: VideoErrorState.fromException(e),
        availability: _availabilityForError(e.code),
        playbackModes: const [],
        diagnostics: existing.diagnostics.copyWith(fromCache: true),
      );
      await _store.upsert(degraded);
      return ResolveResult(error: e, match: match, video: degraded);
    }
  }

  Future<void> remove(String videoId) async {
    _cache.metadata.invalidate(videoId);
    _cache.playback.invalidate(videoId);
    await _store.remove(videoId);
  }

  bool _isFresh(UnifiedVideo video) {
    final fetched = DateTime.tryParse(video.fetchedAt);
    if (fetched == null) return false;
    return DateTime.now().toUtc().difference(fetched.toUtc()) <
        _cache.config.metadataTtl;
  }

  static VideoAvailability _availabilityForError(FusionErrorCode code) =>
      switch (code) {
        FusionErrorCode.videoNotFound => VideoAvailability.unavailable,
        FusionErrorCode.permissionDenied ||
        FusionErrorCode.loginRequired ||
        FusionErrorCode.regionRestricted =>
          VideoAvailability.restricted,
        _ => VideoAvailability.unknown,
      };

  /// 从分享文案中提取第一个 URL。
  ///
  /// 抖音/B站分享文本形如：
  ///   `7.43 复制打开抖音，看看【xxx】https://v.douyin.com/xxxx/ ...`
  /// 这里只做保守提取，不猜测平台。
  static String _extractUrl(String input) {
    final match =
        RegExp(r'''https?://[^\s，,。、；;"'<>）)】\]]+''').firstMatch(input);
    if (match != null) return match.group(0)!;
    return input;
  }
}
