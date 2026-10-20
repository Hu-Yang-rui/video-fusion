/// 视频总结的数据契约（平台无关）。
///
/// # 为什么独立于评论翻译
///
/// 翻译是**逐条评论**的短文本转换，总结是**整个视频**的长文本概括。
/// 两者的缓存键、生命周期、UI 位置都不同，混在一个模型里会让
/// 缓存失效逻辑变得难以推理。
///
/// # 三种必须区分的状态
///
/// 需求明确要求区分「视频暂无总结」与「请求失败」。这两种情况在
/// 接口层面都可能表现为"没有内容"，但对用户含义完全不同：
///
///  - [VideoSummaryStatus.noSummary] —— 平台明确表示这个视频没有总结
///    （B 站返回 `code=0` 但 `summary` 为空）。不是错误，不该显示重试按钮。
///  - [VideoSummaryStatus.failed] —— 请求真的失败了（网络、登录、风控）。
///    应该显示原因和重试入口。
///  - [VideoSummaryStatus.unavailable] —— 该平台没有总结能力（抖音官方）。
///
/// 把三者压成一个"空"会让用户无法判断该不该重试。
library;

/// 总结的来源。
enum VideoSummarySource {
  /// 平台官方 AI 总结（B 站 `conclusion/get`）。
  ///
  /// 这类结果**不得**标注为本项目生成。
  platform('平台 AI 总结'),

  /// 本项目通过用户配置的模型生成。
  ///
  /// 必须在 UI 上标注为"由 AI 生成"，不能冒充平台官方总结。
  generated('AI 生成（本项目）');

  const VideoSummarySource(this.label);
  final String label;
}

/// 总结的加载状态。
enum VideoSummaryStatus {
  /// 还没请求过。
  idle,

  /// 请求进行中。
  loading,

  /// 成功拿到总结（[VideoSummary.summary] 非空）。
  success,

  /// 平台明确表示没有总结（不是错误）。
  noSummary,

  /// 该平台没有总结能力。
  unavailable,

  /// 请求失败（网络/登录/风控），可重试。
  failed,
}

/// 总结里的一个章节。
class SummaryChapter {
  const SummaryChapter({
    required this.title,
    this.timestampSeconds,
    this.points = const [],
  });

  /// 章节标题。
  final String title;

  /// 章节起始时间（秒）。null 表示平台没给时间戳。
  ///
  /// **只有非 null 时才允许在 UI 上渲染可跳转的章节**——
  /// 凭空编造时间戳会让用户跳到错误位置。
  final int? timestampSeconds;

  /// 章节内的要点。
  final List<SummaryPoint> points;

  bool get canSeek => timestampSeconds != null && timestampSeconds! >= 0;

  Map<String, Object?> toJson() => {
        'title': title,
        if (timestampSeconds != null) 'timestamp': timestampSeconds,
        if (points.isNotEmpty) 'points': points.map((p) => p.toJson()).toList(),
      };

  static SummaryChapter fromJson(Map<String, Object?> json) => SummaryChapter(
        title: (json['title'] as String?)?.trim() ?? '',
        timestampSeconds: _toInt(json['timestamp']),
        points: (json['points'] as List?)
                ?.whereType<Map>()
                .map((e) => SummaryPoint.fromJson(Map<String, Object?>.from(e)))
                .toList() ??
            const [],
      );

  static int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// 章节里的一个要点。
class SummaryPoint {
  const SummaryPoint({required this.content, this.timestampSeconds});

  final String content;
  final int? timestampSeconds;

  Map<String, Object?> toJson() => {
        'content': content,
        if (timestampSeconds != null) 'timestamp': timestampSeconds,
      };

  static SummaryPoint fromJson(Map<String, Object?> json) => SummaryPoint(
        content: (json['content'] as String?)?.trim() ?? '',
        timestampSeconds: SummaryChapter._toInt(json['timestamp']),
      );
}

/// 一次视频总结的完整结果。
class VideoSummary {
  const VideoSummary({
    required this.status,
    required this.source,
    this.summary,
    this.chapters = const [],
    this.errorMessage,
    this.retryable = false,
    this.upstreamCode,
    this.providerId,
  });

  /// 成功。
  factory VideoSummary.success({
    required String summary,
    required VideoSummarySource source,
    List<SummaryChapter> chapters = const [],
    String? providerId,
  }) =>
      VideoSummary(
        status: VideoSummaryStatus.success,
        source: source,
        summary: summary,
        chapters: chapters,
        providerId: providerId,
      );

  /// 平台明确表示没有总结（不是错误）。
  factory VideoSummary.noSummary({
    required VideoSummarySource source,
    String? providerId,
    String? reason,
  }) =>
      VideoSummary(
        status: VideoSummaryStatus.noSummary,
        source: source,
        errorMessage: reason ?? '该视频暂无 AI 总结。',
        providerId: providerId,
      );

  /// 该平台没有总结能力。
  factory VideoSummary.unavailable({
    required String reason,
    String? providerId,
  }) =>
      VideoSummary(
        status: VideoSummaryStatus.unavailable,
        source: VideoSummarySource.platform,
        errorMessage: reason,
        providerId: providerId,
      );

  /// 失败，可重试。
  factory VideoSummary.failure({
    required String errorMessage,
    required VideoSummarySource source,
    bool retryable = true,
    Object? upstreamCode,
    String? providerId,
  }) =>
      VideoSummary(
        status: VideoSummaryStatus.failed,
        source: source,
        errorMessage: errorMessage,
        retryable: retryable,
        upstreamCode: upstreamCode,
        providerId: providerId,
      );

  final VideoSummaryStatus status;
  final VideoSummarySource source;

  /// 总结正文。仅 [VideoSummaryStatus.success] 时非空。
  final String? summary;

  /// 章节列表（可能为空——不是所有视频都有）。
  final List<SummaryChapter> chapters;

  /// 失败或"无总结"时的可读原因。
  final String? errorMessage;

  /// 是否值得重试。`noSummary` / `unavailable` 为 false。
  final bool retryable;

  /// 平台返回的业务码（诊断用）。
  final Object? upstreamCode;

  /// 提供方标识（`bilibili` / `douyin-ai` / ...）。
  final String? providerId;

  bool get isSuccess => status == VideoSummaryStatus.success;

  /// 缓存键：平台 + 视频 ID + 目标语言 + 来源。
  ///
  /// 不含模型配置——模型变了应该由调用方清理缓存，
  /// 而不是让键空间无限膨胀。
  String cacheKey({
    required String platformId,
    required String videoId,
  }) =>
      '$platformId::$videoId::${source.name}';

  Map<String, Object?> toJson() => {
        'status': status.name,
        'source': source.name,
        if (summary != null) 'summary': summary,
        if (chapters.isNotEmpty)
          'chapters': chapters.map((c) => c.toJson()).toList(),
        if (errorMessage != null) 'errorMessage': errorMessage,
        'retryable': retryable,
        if (upstreamCode != null) 'upstreamCode': upstreamCode,
        if (providerId != null) 'providerId': providerId,
      };

  static VideoSummary fromJson(Map<String, Object?> json) => VideoSummary(
        status: VideoSummaryStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => VideoSummaryStatus.idle,
        ),
        source: VideoSummarySource.values.firstWhere(
          (e) => e.name == json['source'],
          orElse: () => VideoSummarySource.platform,
        ),
        summary: json['summary'] as String?,
        chapters: (json['chapters'] as List?)
                ?.whereType<Map>()
                .map((e) =>
                    SummaryChapter.fromJson(Map<String, Object?>.from(e)))
                .toList() ??
            const [],
        errorMessage: json['errorMessage'] as String?,
        retryable: json['retryable'] as bool? ?? false,
        upstreamCode: json['upstreamCode'],
        providerId: json['providerId'] as String?,
      );
}
