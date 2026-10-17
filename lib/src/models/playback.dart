/// 统一播放层的数据契约（平台无关）。
///
/// 关键约束：
///  - 播放模式必须依据"实际可验证的能力"选择，不得默认所有视频都能应用内播放。
///  - 不得把普通网页 URL 当作视频流 URL。
///  - 不得为官方嵌入播放器虚构它不支持的控件能力。
///
/// 因此 [PlaybackSource] 使用密封类层次：每种模式只携带该模式真实存在的字段。
library;

import 'unified_video.dart';

/// 一个可选的清晰度档位。
class PlaybackQuality {
  const PlaybackQuality({
    required this.platformQualityId,
    required this.label,
    this.width,
    this.height,
    this.codec,
    this.bandwidth,
  });

  /// 平台清晰度码值（B 站 qn）。仅用于诊断。
  final int? platformQualityId;

  /// 展示标签，例如 '720P'。
  final String label;

  final int? width;
  final int? height;
  final String? codec;
  final int? bandwidth;

  Map<String, Object?> toJson() => {
        'platformQualityId': platformQualityId,
        'label': label,
        'width': width,
        'height': height,
        'codec': codec,
        'bandwidth': bandwidth,
      };
}

/// 官方嵌入播放器能力描述。默认全部保守，只有实测确认后才置 true。
class EmbedCapabilities {
  const EmbedCapabilities({
    this.hasBuiltInControls = true,
    this.supportsQualitySwitch = false,
    this.supportsPlaybackRate = false,
    this.refererSensitive = true,
    this.requiresLogin = false,
  });

  /// 平台嵌入播放器自带播放控制条。
  final bool hasBuiltInControls;

  /// 支持通过参数切换清晰度。
  final bool supportsQualitySwitch;

  /// 支持通过参数控制倍速。
  final bool supportsPlaybackRate;

  /// 可能因 referer / 登录状态导致嵌入不可用。
  final bool refererSensitive;

  /// 嵌入播放器是否要求登录才能播放。
  final bool requiresLogin;

  Map<String, Object?> toJson() => {
        'hasBuiltInControls': hasBuiltInControls,
        'supportsQualitySwitch': supportsQualitySwitch,
        'supportsPlaybackRate': supportsPlaybackRate,
        'refererSensitive': refererSensitive,
        'requiresLogin': requiresLogin,
      };
}

/// 播放源（密封类）。每种模式只携带该模式真实存在的字段。
sealed class PlaybackSource {
  const PlaybackSource({required this.videoId, required this.mode});

  final String videoId;
  final PlaybackMode mode;

  Map<String, Object?> toJson();
}

/// 应用内播放：使用平台公开可用的视频直链。
///
/// [videoStreamUrl] 必须是媒体文件地址（mp4/m4s 等），不是网页 URL。
/// [audioStreamUrl] 仅在 DASH 音视频分离时存在；此时播放器需要同时加载音轨。
class NativePlaybackSource extends PlaybackSource {
  const NativePlaybackSource({
    required super.videoId,
    required this.videoStreamUrl,
    this.audioStreamUrl,
    this.requiredHeaders = const {},
    this.quality,
    this.availableQualities = const [],
    this.expiresAt,
    this.isDash = false,
    this.videoFallbackUrls = const [],
    this.audioFallbackUrls = const [],
  }) : super(mode: PlaybackMode.native);

  final String videoStreamUrl;

  /// DASH 分离音轨地址；为 null 表示该直链自带音频。
  final String? audioStreamUrl;

  /// 播放该直链时必须携带的请求头（例如 B 站部分 CDN 要求 Referer 防盗链）。
  final Map<String, String> requiredHeaders;

  final PlaybackQuality? quality;
  final List<PlaybackQuality> availableQualities;

  /// 直链过期时间（ISO 8601）。
  final String? expiresAt;

  /// 是否为 DASH 分离流（音视频分开）。
  final bool isDash;

  /// 视频轨的备用地址（平台提供的 backupUrl）。
  ///
  /// 实测：B 站每条流附带多个指向不同 CDN 节点的备用地址，
  /// 主地址可能单独失效（404）。播放器应在主地址失败时依次尝试。
  final List<String> videoFallbackUrls;

  /// 音轨的备用地址。
  final List<String> audioFallbackUrls;

  /// 视频轨全部候选地址（主地址在前，已去重）。
  List<String> get allVideoUrls =>
      [videoStreamUrl, ...videoFallbackUrls].toSet().toList();

  /// 音轨全部候选地址（主地址在前，已去重）。
  List<String> get allAudioUrls => audioStreamUrl == null
      ? const []
      : [audioStreamUrl!, ...audioFallbackUrls].toSet().toList();

  @override
  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        'videoId': videoId,
        'videoStreamUrl': videoStreamUrl,
        'audioStreamUrl': audioStreamUrl,
        'requiredHeaders': requiredHeaders.keys.toList(),
        'quality': quality?.toJson(),
        'availableQualities': availableQualities.map((q) => q.toJson()).toList(),
        'expiresAt': expiresAt,
        'isDash': isDash,
        // 备用地址数量（不输出完整 URL，避免日志膨胀）
        'videoFallbackCount': videoFallbackUrls.length,
        'audioFallbackCount': audioFallbackUrls.length,
      };
}

/// 平台官方嵌入播放器。其内部控制能力由平台决定，本系统不得伪造。
class OfficialEmbedPlaybackSource extends PlaybackSource {
  const OfficialEmbedPlaybackSource({
    required super.videoId,
    required this.embedUrl,
    this.embedCapabilities = const EmbedCapabilities(),
    this.embedNotes = const [],
  }) : super(mode: PlaybackMode.officialEmbed);

  final String embedUrl;
  final EmbedCapabilities embedCapabilities;
  final List<String> embedNotes;

  @override
  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        'videoId': videoId,
        'embedUrl': embedUrl,
        'embedCapabilities': embedCapabilities.toJson(),
        'embedNotes': embedNotes,
      };
}

/// 只能在原平台播放，应用内提供跳转入口。
class ExternalPlaybackSource extends PlaybackSource {
  const ExternalPlaybackSource({
    required super.videoId,
    required this.externalUrl,
    required this.reason,
  }) : super(mode: PlaybackMode.external);

  final String externalUrl;

  /// 面向用户的跳转原因说明。
  final String reason;

  @override
  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        'videoId': videoId,
        'externalUrl': externalUrl,
        'reason': reason,
      };
}

/// 一次播放源解析的结果：成功时带 [source]，失败时带 [error]。
class PlaybackResolution {
  const PlaybackResolution({
    required this.videoId,
    this.source,
    this.error,
    this.attempts = const [],
    this.resolvedAt,
  });

  final String videoId;
  final PlaybackSource? source;
  final Object? error;

  /// 尝试过的播放模式及结果，用于 UI 如实展示"为什么降级"。
  final List<PlaybackAttempt> attempts;

  final String? resolvedAt;

  bool get ok => source != null;
}

/// 单次播放模式尝试记录。
class PlaybackAttempt {
  const PlaybackAttempt({
    required this.mode,
    required this.succeeded,
    this.detail,
  });

  final PlaybackMode mode;
  final bool succeeded;

  /// 失败原因或成功说明（面向用户，已脱敏）。
  final String? detail;

  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        'succeeded': succeeded,
        'detail': detail,
      };
}
