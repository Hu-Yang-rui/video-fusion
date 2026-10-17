/// 播放策略层：根据适配器声明的**实际能力**决定播放模式与降级链。
///
/// 核心约束：
///  - 播放模式必须依据实际可验证的能力选择，不得默认所有视频都能应用内播放。
///  - 不得把普通网页 URL 当作视频流 URL。
///  - 不得为官方嵌入播放器虚构它不支持的控件能力。
///  - 播放失败后不得静默跳转或伪造播放成功状态。
library;

import '../adapters/platform_adapter.dart';
import '../adapters/platform_registry.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../models/playback.dart';
import '../models/unified_video.dart';

/// 一次播放解析的完整结果。
class PlaybackOutcome {
  const PlaybackOutcome({
    required this.videoId,
    required this.attempts,
    this.source,
    this.error,
  });

  final String videoId;

  /// 按顺序尝试过的模式与结果。UI 据此如实展示"为什么降级"。
  final List<PlaybackAttempt> attempts;

  final PlaybackSource? source;
  final FusionException? error;

  bool get ok => source != null;
}

/// 播放策略。
///
/// 降级链固定为：NATIVE → OFFICIAL_EMBED → EXTERNAL。
/// 每一级只在适配器声明支持时才尝试；任一级成功即停止，不静默继续。
class PlaybackPolicy {
  PlaybackPolicy({
    required PlatformRegistry registry,
    FusionLogger? logger,
    this.nativeFirst = true,
  })  : _registry = registry,
        _logger = logger ?? appLogger;

  final PlatformRegistry _registry;
  final FusionLogger _logger;

  /// 是否优先尝试应用内播放。默认 true（本系统的主路径）。
  final bool nativeFirst;

  /// 解析播放源。
  ///
  /// 返回的 [PlaybackOutcome] 始终包含完整的尝试记录，
  /// 即使最终失败也会给出 EXTERNAL 兜底或明确错误。
  Future<PlaybackOutcome> resolve(UnifiedVideo video) async {
    final attempts = <PlaybackAttempt>[];

    final adapter = _registry.byId(video.platformId);
    if (adapter == null) {
      final error = FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台尚未接入，无法解析播放地址。',
        technicalMessage: 'No adapter for platformId=${video.platformId}',
        platformId: video.platformId,
      );
      attempts.add(PlaybackAttempt(
        mode: PlaybackMode.external,
        succeeded: false,
        detail: error.userMessage,
      ));
      return PlaybackOutcome(videoId: video.id, attempts: attempts, error: error);
    }

    final order = _modeOrder(adapter, video);

    for (final mode in order) {
      // EXTERNAL 不需要网络请求，直接构造
      if (mode == PlaybackMode.external) {
        attempts.add(PlaybackAttempt(
          mode: mode,
          succeeded: true,
          detail: '跳转到原平台播放页。',
        ));
        return PlaybackOutcome(
          videoId: video.id,
          attempts: attempts,
          source: ExternalPlaybackSource(
            videoId: video.id,
            externalUrl: video.canonicalUrl,
            reason: attempts.length > 1
                ? '当前环境无法在应用内播放该视频，已提供原平台入口。'
                : '该视频仅支持在原平台播放。',
          ),
        );
      }

      try {
        final source = await _tryMode(adapter, video, mode);
        if (source != null) {
          attempts.add(PlaybackAttempt(
            mode: mode,
            succeeded: true,
            detail: _successDetail(source),
          ));
          _logger.info(
            'playback resolved',
            {
              'video': video.id,
              'mode': mode.wireName,
              'attempts': attempts.length,
            },
          );
          return PlaybackOutcome(videoId: video.id, attempts: attempts, source: source);
        }
        attempts.add(PlaybackAttempt(
          mode: mode,
          succeeded: false,
          detail: '平台未返回该模式的可用播放地址。',
        ));
      } on FusionException catch (e) {
        attempts.add(PlaybackAttempt(
          mode: mode,
          succeeded: false,
          detail: e.userMessage,
        ));
        _logger.warn('playback mode failed', {
          'video': video.id,
          'mode': mode.wireName,
          'code': e.code.name,
          'detail': e.technicalMessage,
        });

        // 权限/登录类错误：不再继续尝试其它网络模式，直接给出 EXTERNAL 兜底
        if (e.code == FusionErrorCode.permissionDenied ||
            e.code == FusionErrorCode.loginRequired ||
            e.code == FusionErrorCode.regionRestricted) {
          if (!order.contains(PlaybackMode.external)) {
            return PlaybackOutcome(
              videoId: video.id,
              attempts: attempts,
              error: e,
            );
          }
        }
      } catch (e) {
        final normalized = normalizeError(e, platformId: video.platformId);
        attempts.add(PlaybackAttempt(
          mode: mode,
          succeeded: false,
          detail: normalized.userMessage,
        ));
      }
    }

    // 全部失败：给出明确错误，不伪造成功
    final lastFailure = attempts.where((a) => !a.succeeded).toList();
    return PlaybackOutcome(
      videoId: video.id,
      attempts: attempts,
      error: FusionException(
        code: FusionErrorCode.capabilityUnavailable,
        userMessage: lastFailure.isNotEmpty && lastFailure.last.detail != null
            ? lastFailure.last.detail!
            : '当前无法解析该视频的播放地址。',
        technicalMessage:
            'All playback modes failed: ${attempts.map((a) => '${a.mode.wireName}=${a.succeeded}').join(', ')}',
        platformId: video.platformId,
      ),
    );
  }

  /// 计算该视频的尝试顺序。
  List<PlaybackMode> _modeOrder(PlatformAdapter adapter, UnifiedVideo video) {
    final caps = adapter.capabilities;
    final modes = <PlaybackMode>[];

    if (nativeFirst && caps.supportsNativePlayback) modes.add(PlaybackMode.native);
    if (caps.supportsOfficialEmbed) modes.add(PlaybackMode.officialEmbed);
    if (!nativeFirst && caps.supportsNativePlayback) modes.add(PlaybackMode.native);
    if (caps.supportsExternalFallback) modes.add(PlaybackMode.external);

    // 适配器未声明 EXTERNAL 时也要兜底，否则用户完全无路可走
    if (modes.isEmpty) modes.add(PlaybackMode.external);
    return modes;
  }

  Future<PlaybackSource?> _tryMode(
    PlatformAdapter adapter,
    UnifiedVideo video,
    PlaybackMode mode,
  ) async {
    switch (mode) {
      case PlaybackMode.native:
      case PlaybackMode.officialEmbed:
        return adapter.resolvePlayback(PlaybackRequest(
          platformVideoId: video.platformVideoId,
          canonicalUrl: video.canonicalUrl,
          preferredMode: mode,
        ));
      case PlaybackMode.external:
        return null; // 在上层直接构造
    }
  }

  String _successDetail(PlaybackSource source) => switch (source) {
        NativePlaybackSource(:final quality, :final isDash) =>
          '应用内播放${quality != null ? '（${quality.label}）' : ''}${isDash ? '，DASH 分离流' : ''}',
        OfficialEmbedPlaybackSource() => '使用平台官方嵌入播放器。',
        ExternalPlaybackSource(:final reason) => reason,
      };
}

/// 播放模式展示描述（UI 统一消费，不在 UI 层硬编码平台判断）。
class PlaybackModeInfo {
  const PlaybackModeInfo({
    required this.mode,
    required this.label,
    required this.description,
  });

  final PlaybackMode mode;
  final String label;
  final String description;

  static const Map<PlaybackMode, PlaybackModeInfo> all = {
    PlaybackMode.native: PlaybackModeInfo(
      mode: PlaybackMode.native,
      label: '应用内播放',
      description: '使用平台公开可用的视频直链在应用内播放，受直链有效期限制。',
    ),
    PlaybackMode.officialEmbed: PlaybackModeInfo(
      mode: PlaybackMode.officialEmbed,
      label: '官方嵌入播放',
      description: '使用平台官方嵌入式播放器，播放控制由平台自身提供。',
    ),
    PlaybackMode.external: PlaybackModeInfo(
      mode: PlaybackMode.external,
      label: '跳转原平台播放',
      description: '当前环境无法在应用内播放，将跳转到原平台播放页。',
    ),
  };

  static PlaybackModeInfo of(PlaybackMode mode) => all[mode]!;
}
