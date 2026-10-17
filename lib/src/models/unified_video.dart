/// 统一视频数据模型（平台无关）。
///
/// 核心约束：
///  - 视频身份由 (platformId, platformVideoId) 共同确定，跨平台 ID 相同不得冲突。
///  - 所有平台可选字段缺失即为 null，禁止凭空生成。
///  - 必须保留原始链接与平台原始 ID，供回源与报告追溯。
library;

import '../core/errors.dart';

/// 播放能力模式。
enum PlaybackMode {
  /// 应用内播放器使用平台公开可用的视频直链。
  native('NATIVE', '应用内播放'),

  /// 使用平台官方嵌入式播放器。
  officialEmbed('OFFICIAL_EMBED', '官方嵌入播放'),

  /// 跳转至原平台播放。
  external('EXTERNAL', '跳转原平台播放');

  const PlaybackMode(this.wireName, this.label);

  /// 序列化用的稳定标识（与跨语言契约一致）。
  final String wireName;

  /// 面向用户的展示名。
  final String label;

  static PlaybackMode fromWire(String value) => PlaybackMode.values.firstWhere(
        (m) => m.wireName == value,
        orElse: () => PlaybackMode.external,
      );
}

/// 视频整体可用状态。
enum VideoAvailability {
  /// 元数据与至少一种播放方式可用。
  available('AVAILABLE', '可播放'),

  /// 视频存在，但需要登录/授权。
  restricted('RESTRICTED', '受限'),

  /// 视频不存在或已删除。
  unavailable('UNAVAILABLE', '不可用'),

  /// 元数据未能获取，状态未知。
  unknown('UNKNOWN', '未知');

  const VideoAvailability(this.wireName, this.label);

  final String wireName;
  final String label;

  static VideoAvailability fromWire(String value) =>
      VideoAvailability.values.firstWhere(
        (a) => a.wireName == value,
        orElse: () => VideoAvailability.unknown,
      );
}

/// 作者信息。缺失字段为 null，不生成占位数据。
class VideoAuthor {
  const VideoAuthor({
    this.name,
    this.platformAuthorId,
    this.profileUrl,
    this.avatarUrl,
  });

  static const VideoAuthor empty = VideoAuthor();

  /// 展示名（B 站 UP 主名 / 抖音昵称）。
  final String? name;

  /// 平台内稳定作者标识（B 站 mid / 抖音 sec_uid）。
  final String? platformAuthorId;

  final String? profileUrl;
  final String? avatarUrl;

  bool get hasAny => name != null || platformAuthorId != null;

  Map<String, Object?> toJson() => {
        'name': name,
        'platformAuthorId': platformAuthorId,
        'profileUrl': profileUrl,
        'avatarUrl': avatarUrl,
      };

  factory VideoAuthor.fromJson(Map<String, Object?> json) => VideoAuthor(
        name: json['name'] as String?,
        platformAuthorId: json['platformAuthorId'] as String?,
        profileUrl: json['profileUrl'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
      );
}

/// 统计信息。仅作元数据展示，本系统不提供点赞/弹幕功能。
class VideoStats {
  const VideoStats({this.viewCount, this.likeCount, this.danmakuCount});

  static const VideoStats empty = VideoStats();

  final int? viewCount;
  final int? likeCount;
  final int? danmakuCount;

  bool get hasAny => viewCount != null || likeCount != null || danmakuCount != null;

  Map<String, Object?> toJson() => {
        'viewCount': viewCount,
        'likeCount': likeCount,
        'danmakuCount': danmakuCount,
      };

  factory VideoStats.fromJson(Map<String, Object?> json) => VideoStats(
        viewCount: (json['viewCount'] as num?)?.toInt(),
        likeCount: (json['likeCount'] as num?)?.toInt(),
        danmakuCount: (json['danmakuCount'] as num?)?.toInt(),
      );
}

/// 一次元数据获取的诊断记录，用于报告与 UI 的"受限能力"说明。
class VideoDiagnostics {
  const VideoDiagnostics({
    required this.adapterId,
    required this.upstreamEndpoint,
    required this.fromCache,
    required this.fetchDurationMs,
    this.limitations = const [],
    this.notes = const [],
  });

  /// 获取该元数据的适配器 id。
  final String adapterId;

  /// 实际使用的上游接口标识（不含凭证）。
  final String upstreamEndpoint;

  /// 是否来自缓存。
  final bool fromCache;

  /// 本次获取耗时（毫秒）；缓存命中为 0。
  final int fetchDurationMs;

  /// 降级/限制说明。
  final List<String> limitations;

  /// 上游返回的可诊断信息（已脱敏）。
  final List<String> notes;

  VideoDiagnostics copyWith({
    String? adapterId,
    String? upstreamEndpoint,
    bool? fromCache,
    int? fetchDurationMs,
    List<String>? limitations,
    List<String>? notes,
  }) =>
      VideoDiagnostics(
        adapterId: adapterId ?? this.adapterId,
        upstreamEndpoint: upstreamEndpoint ?? this.upstreamEndpoint,
        fromCache: fromCache ?? this.fromCache,
        fetchDurationMs: fetchDurationMs ?? this.fetchDurationMs,
        limitations: limitations ?? this.limitations,
        notes: notes ?? this.notes,
      );

  Map<String, Object?> toJson() => {
        'adapterId': adapterId,
        'upstreamEndpoint': upstreamEndpoint,
        'fromCache': fromCache,
        'fetchDurationMs': fetchDurationMs,
        'limitations': limitations,
        'notes': notes,
      };

  factory VideoDiagnostics.fromJson(Map<String, Object?> json) => VideoDiagnostics(
        adapterId: json['adapterId'] as String? ?? 'unknown',
        upstreamEndpoint: json['upstreamEndpoint'] as String? ?? '',
        fromCache: json['fromCache'] as bool? ?? false,
        fetchDurationMs: (json['fetchDurationMs'] as num?)?.toInt() ?? 0,
        limitations:
            (json['limitations'] as List?)?.map((e) => '$e').toList() ?? const [],
        notes: (json['notes'] as List?)?.map((e) => '$e').toList() ?? const [],
      );
}

/// 视频错误状态（内嵌于 [UnifiedVideo]，便于列表项直接展示受限原因）。
class VideoErrorState {
  const VideoErrorState({
    required this.code,
    required this.userMessage,
    required this.technicalMessage,
    this.upstreamCode,
    required this.retryable,
  });

  final FusionErrorCode code;
  final String userMessage;
  final String technicalMessage;
  final Object? upstreamCode;
  final bool retryable;

  factory VideoErrorState.fromException(FusionException e) => VideoErrorState(
        code: e.code,
        userMessage: e.userMessage,
        technicalMessage: e.technicalMessage,
        upstreamCode: e.upstreamCode,
        retryable: e.retryable,
      );

  Map<String, Object?> toJson() => {
        'code': code.name,
        'userMessage': userMessage,
        'technicalMessage': technicalMessage,
        'upstreamCode': upstreamCode,
        'retryable': retryable,
      };

  factory VideoErrorState.fromJson(Map<String, Object?> json) => VideoErrorState(
        code: FusionErrorCode.values.firstWhere(
          (c) => c.name == json['code'],
          orElse: () => FusionErrorCode.internalError,
        ),
        userMessage: json['userMessage'] as String? ?? '未知错误',
        technicalMessage: json['technicalMessage'] as String? ?? '',
        upstreamCode: json['upstreamCode'],
        retryable: json['retryable'] as bool? ?? false,
      );
}

/// 统一视频实体。
class UnifiedVideo {
  const UnifiedVideo({
    required this.id,
    required this.platformId,
    required this.platformVideoId,
    required this.originalUrl,
    required this.canonicalUrl,
    required this.title,
    this.description,
    this.author = VideoAuthor.empty,
    this.coverUrl,
    this.durationSeconds,
    this.aspectRatio,
    this.width,
    this.height,
    this.publishedAt,
    required this.fetchedAt,
    this.stats = VideoStats.empty,
    this.availability = VideoAvailability.unknown,
    this.playbackModes = const [],
    this.requiresAuth = false,
    this.error,
    required this.diagnostics,
  });

  /// 内部唯一 ID：`{platformId}:{platformVideoId}`。
  final String id;

  /// 平台标识，例如 'bilibili' / 'douyin'。
  final String platformId;

  /// 平台原始视频 ID（B 站 BV 号 / av 号，抖音 aweme_id）。
  final String platformVideoId;

  /// 用户输入的原始链接（未经改写）。
  final String originalUrl;

  /// 规范化后的平台视频页链接。
  final String canonicalUrl;

  final String title;
  final String? description;
  final VideoAuthor author;
  final String? coverUrl;

  /// 时长（秒），缺失为 null。
  final double? durationSeconds;

  /// 宽高比 = width / height，缺失为 null。用于列表封面布局。
  final double? aspectRatio;

  final int? width;
  final int? height;

  /// 发布时间（ISO 8601），缺失为 null。
  final String? publishedAt;

  /// 元数据获取时间（ISO 8601）。
  final String fetchedAt;

  final VideoStats stats;
  final VideoAvailability availability;

  /// 可用/受限的播放模式，按优先级排序。空表示当前无法播放。
  final List<PlaybackMode> playbackModes;

  /// 是否需要登录/授权才能完整访问。
  final bool requiresAuth;

  final VideoErrorState? error;
  final VideoDiagnostics diagnostics;

  /// 首选播放模式；无可用模式时为 null。
  PlaybackMode? get preferredPlaybackMode =>
      playbackModes.isEmpty ? null : playbackModes.first;

  bool get playable => playbackModes.isNotEmpty;

  /// 时长展示（`mm:ss` / `h:mm:ss`），缺失返回 null。
  String? get durationLabel => formatDuration(durationSeconds);

  /// 封面布局用的安全宽高比：缺失时回退到 16:9，仅用于布局，不伪造数据。
  double get layoutAspectRatio {
    final r = aspectRatio;
    if (r == null || !r.isFinite || r <= 0) return 16 / 9;
    return r.clamp(0.3, 3.0);
  }

  bool get isPortrait => layoutAspectRatio < 1.0;

  UnifiedVideo copyWith({
    String? title,
    String? description,
    VideoAuthor? author,
    String? coverUrl,
    double? durationSeconds,
    double? aspectRatio,
    int? width,
    int? height,
    String? publishedAt,
    String? fetchedAt,
    VideoStats? stats,
    VideoAvailability? availability,
    List<PlaybackMode>? playbackModes,
    bool? requiresAuth,
    VideoErrorState? error,
    bool clearError = false,
    VideoDiagnostics? diagnostics,
  }) =>
      UnifiedVideo(
        id: id,
        platformId: platformId,
        platformVideoId: platformVideoId,
        originalUrl: originalUrl,
        canonicalUrl: canonicalUrl,
        title: title ?? this.title,
        description: description ?? this.description,
        author: author ?? this.author,
        coverUrl: coverUrl ?? this.coverUrl,
        durationSeconds: durationSeconds ?? this.durationSeconds,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        width: width ?? this.width,
        height: height ?? this.height,
        publishedAt: publishedAt ?? this.publishedAt,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        stats: stats ?? this.stats,
        availability: availability ?? this.availability,
        playbackModes: playbackModes ?? this.playbackModes,
        requiresAuth: requiresAuth ?? this.requiresAuth,
        error: clearError ? null : (error ?? this.error),
        diagnostics: diagnostics ?? this.diagnostics,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'platformId': platformId,
        'platformVideoId': platformVideoId,
        'originalUrl': originalUrl,
        'canonicalUrl': canonicalUrl,
        'title': title,
        'description': description,
        'author': author.toJson(),
        'coverUrl': coverUrl,
        'durationSeconds': durationSeconds,
        'aspectRatio': aspectRatio,
        'width': width,
        'height': height,
        'publishedAt': publishedAt,
        'fetchedAt': fetchedAt,
        'stats': stats.toJson(),
        'availability': availability.wireName,
        'playbackModes': playbackModes.map((m) => m.wireName).toList(),
        'requiresAuth': requiresAuth,
        'error': error?.toJson(),
        'diagnostics': diagnostics.toJson(),
      };

  factory UnifiedVideo.fromJson(Map<String, Object?> json) => UnifiedVideo(
        id: json['id'] as String,
        platformId: json['platformId'] as String,
        platformVideoId: json['platformVideoId'] as String,
        originalUrl: json['originalUrl'] as String? ?? '',
        canonicalUrl: json['canonicalUrl'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String?,
        author: json['author'] is Map
            ? VideoAuthor.fromJson(Map<String, Object?>.from(json['author'] as Map))
            : VideoAuthor.empty,
        coverUrl: json['coverUrl'] as String?,
        durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
        aspectRatio: (json['aspectRatio'] as num?)?.toDouble(),
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
        publishedAt: json['publishedAt'] as String?,
        fetchedAt: json['fetchedAt'] as String? ?? '',
        stats: json['stats'] is Map
            ? VideoStats.fromJson(Map<String, Object?>.from(json['stats'] as Map))
            : VideoStats.empty,
        availability: VideoAvailability.fromWire(json['availability'] as String? ?? 'UNKNOWN'),
        playbackModes: (json['playbackModes'] as List?)
                ?.map((e) => PlaybackMode.fromWire('$e'))
                .toList() ??
            const [],
        requiresAuth: json['requiresAuth'] as bool? ?? false,
        error: json['error'] is Map
            ? VideoErrorState.fromJson(Map<String, Object?>.from(json['error'] as Map))
            : null,
        diagnostics: json['diagnostics'] is Map
            ? VideoDiagnostics.fromJson(
                Map<String, Object?>.from(json['diagnostics'] as Map))
            : const VideoDiagnostics(
                adapterId: 'unknown',
                upstreamEndpoint: '',
                fromCache: false,
                fetchDurationMs: 0,
              ),
      );
}

/// 生成内部唯一 ID。平台标识与平台视频 ID 共同决定身份。
String makeVideoId(String platformId, String platformVideoId) =>
    '$platformId:$platformVideoId';

/// 宽高比归一化：非法值返回 null，避免 UI 用 NaN 计算布局。
double? normalizeAspectRatio(int? width, int? height) {
  if (width == null || height == null) return null;
  if (width <= 0 || height <= 0) return null;
  return width / height;
}

/// 时长归一化：接受秒或毫秒，非法值返回 null。
double? normalizeDuration(num? value, {required bool isMilliseconds}) {
  if (value == null) return null;
  final v = value.toDouble();
  if (!v.isFinite || v <= 0) return null;
  final seconds = isMilliseconds ? v / 1000 : v;
  return (seconds * 1000).round() / 1000;
}

/// 把秒数格式化为 `mm:ss` / `h:mm:ss`，缺失返回 null。
String? formatDuration(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  final total = seconds.floor();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
