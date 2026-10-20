/// 红果短剧播放信息客户端。
///
/// 按 video_id 拉取单集的全部清晰度直链（360p / 480p / 540p / 720p / 1080p）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';

/// 一个清晰度档位。
class HongguoQuality {
  const HongguoQuality({
    required this.definition,
    required this.width,
    required this.height,
    required this.bitrate,
    required this.url,
    required this.backupUrl,
    required this.codec,
    required this.fileSize,
    required this.qualityType,
  });

  /// 档位标识，例如 `1080p`。
  final String definition;

  final int width;
  final int height;

  /// 码率（bps）。
  final int bitrate;

  /// 主直链。
  final String url;

  /// 备用直链。
  final String? backupUrl;

  /// 编码，例如 `bytevc1`（H.265）。
  final String codec;

  /// 文件大小（字节）。
  final int fileSize;

  /// 平台档位码（1=1080p, 10=720p, 20=540p, 30=480p, 40=360p）。
  final int qualityType;

  /// UI 短标签。
  String get label => definition;

  bool get isPlayable => url.isNotEmpty;

  @override
  String toString() => 'HongguoQuality($definition, ${width}x$height)';
}

/// 一集的播放信息。
class HongguoEpisodeMedia {
  const HongguoEpisodeMedia({
    required this.videoId,
    required this.durationSeconds,
    required this.qualities,
    required this.expireAt,
    required this.videoHeight,
  });

  final String videoId;
  final double durationSeconds;

  /// 按高度升序（360p → 1080p）。
  final List<HongguoQuality> qualities;

  /// 直链过期时间。过期后需重新请求。
  final DateTime expireAt;

  /// 接口声明的视频高度。
  final int videoHeight;

  bool get isEmpty => qualities.isEmpty;

  /// 取最接近目标高度的档位。
  HongguoQuality? pickByHeight(int targetHeight) {
    if (qualities.isEmpty) return null;
    HongguoQuality best = qualities.first;
    var bestDiff = (best.height - targetHeight).abs();
    for (final q in qualities) {
      final diff = (q.height - targetHeight).abs();
      if (diff < bestDiff) {
        best = q;
        bestDiff = diff;
      }
    }
    return best;
  }

  HongguoQuality? get highest => qualities.isEmpty ? null : qualities.last;

  HongguoQuality? get lowest => qualities.isEmpty ? null : qualities.first;
}

/// 红果播放信息客户端。
class HongguoMediaClient {
  HongguoMediaClient({
    required FusionHttpClient http,
    FusionLogger? logger,
  })  : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _host = 'https://api5-normal-sinfonlineb.fqnovel.com';

  static const String _videoModelPath = '/novel/player/video_model/v1/';

  /// 请求所需的客户端参数。
  static const Map<String, String> _guestParams = {
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': '73532',
    'version_name': '7.3.5.32',
    'manifest_version_code': '73532',
    'update_version_code': '73532',
    'channel': 'update_64',
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'device_type': '25053RT47C',
    'device_brand': 'Redmi',
    'language': 'zh',
    'os_api': '36',
    'os_version': '16',
    'resolution': '1280*2772',
    'dpi': '520',
    'ac': 'wifi',
  };

  static const String _userAgent =
      'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';

  /// 客户端标识。首次使用时生成，之后固定。
  String? _deviceId;
  String? _installId;
  final _random = Random.secure();

  /// 生成 19 位数字 ID。
  String _newId() {
    final base = BigInt.from(10).pow(18);
    final span = BigInt.from(8) * BigInt.from(10).pow(18);
    final r =
        BigInt.from(_random.nextInt(1 << 32)) * BigInt.from(_random.nextInt(1 << 32)) % span;
    return (base + r).toString();
  }

  void _ensureIdentity() {
    _deviceId ??= _newId();
    _installId ??= _newId();
  }

  /// 拉取一集的播放信息（含全部清晰度）。
  Future<HongguoEpisodeMedia> fetchEpisodeMedia(String videoId) async {
    _ensureIdentity();

    final query = <String, String>{
      ..._guestParams,
      'device_id': _deviceId!,
      'iid': _installId!,
    };
    final qs = query.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final url = '$_host$_videoModelPath?$qs';

    final body = jsonEncode({
      'video_id': videoId,
      'content_type': 1,
      'biz_param': {
        'need_all_video_definition': true,
        'video_platform': 3,
      },
    });

    // 请求体完整性校验：带上请求体的 MD5（大写）。
    final stub = md5.convert(utf8.encode(body)).toString().toUpperCase();

    // 服务端会随机返回空 body（实测约 25% 概率，与设备、vid 都无关），
    // 重试即可。实测平均 2.7 次成功，留 8 次余量。
    const maxAttempts = 8;
    String? lastRaw;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final res = await _http.post(
        url,
        body: body,
        headers: {
          'user-agent': _userAgent,
          'accept': 'application/json',
          'x-xs-from-web': '0',
          'sdk-version': '2',
          'content-type': 'application/json; charset=utf-8',
          'x-ss-stub': stub,
        },
        platformId: 'hongguo',
        timeout: const Duration(seconds: 25),
      );

      lastRaw = res.body;

      if (res.statusCode == 404) {
        throw FusionException(
          code: FusionErrorCode.unsupportedPlatform,
          userMessage: '红果播放接口不可用。',
          technicalMessage: 'HTTP 404 for $_videoModelPath',
          platformId: 'hongguo',
          retryable: false,
        );
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw FusionException(
          code: FusionErrorCode.networkError,
          userMessage: '红果播放信息加载失败（HTTP ${res.statusCode}）。',
          technicalMessage: 'HTTP ${res.statusCode} for $_videoModelPath',
          platformId: 'hongguo',
          retryable: res.statusCode >= 500,
        );
      }

      // 空 body 视为暂时失败，重试。
      if (res.body.trim().isEmpty) {
        _logger.debug('hongguo media: empty body, retry', {
          'attempt': attempt,
          'videoId': videoId,
        });
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
          continue;
        }
        throw FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '红果播放信息暂时取不到，请稍后重试。',
          technicalMessage:
              'empty body after $maxAttempts attempts (videoId=$videoId)',
          platformId: 'hongguo',
          retryable: true,
        );
      }

      final parsed = _parse(res.body, videoId);
      if (parsed != null) return parsed;

      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }

    throw FusionException(
      code: FusionErrorCode.parseError,
      userMessage: '红果播放信息解析失败。',
      technicalMessage: 'could not parse after $maxAttempts attempts '
          '(videoId=$videoId, lastLen=${lastRaw?.length ?? 0})',
      platformId: 'hongguo',
      retryable: true,
    );
  }

  HongguoEpisodeMedia? _parse(String raw, String videoId) {
    Map<String, Object?>? root;
    try {
      root = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return null;
    }

    final code = root['code'];
    if (code is! int || code != 0) {
      _logger.debug('hongguo media: non-zero code', {
        'code': code,
        'message': root['message'],
      });
      return null;
    }

    final data = root['data'];
    if (data is! Map) return null;

    // video_model 可能是 JSON 字符串，也可能是对象。
    Object? model = data['video_model'];
    if (model is String) {
      if (model.isEmpty) return null;
      try {
        model = jsonDecode(model);
      } catch (_) {
        return null;
      }
    }
    if (model is! Map) return null;

    final list = model['video_list'];
    final items =
        list is List ? list : (list is Map ? list.values.toList() : null);
    if (items == null || items.isEmpty) return null;

    final qualities = <HongguoQuality>[];
    for (final item in items) {
      if (item is! Map) continue;
      final meta = item['video_meta'];
      if (meta is! Map) continue;

      final url = (item['main_url'] as String?) ?? '';
      if (url.isEmpty) continue;

      qualities.add(HongguoQuality(
        definition: (meta['definition'] as String?) ?? '?',
        width: (meta['vwidth'] as num?)?.toInt() ?? 0,
        height: (meta['vheight'] as num?)?.toInt() ?? 0,
        bitrate: (meta['bitrate'] as num?)?.toInt() ?? 0,
        url: url,
        backupUrl: item['backup_url'] as String?,
        codec: (meta['codec_type'] as String?) ?? '',
        fileSize: (meta['size'] as num?)?.toInt() ?? 0,
        qualityType: (item['quality_type'] as num?)?.toInt() ?? 0,
      ));
    }

    if (qualities.isEmpty) return null;

    qualities.sort((a, b) => a.height.compareTo(b.height));

    final expireEpoch = (data['expire_time'] as num?)?.toInt() ??
        (model['url_expire'] as num?)?.toInt();
    final expireAt = expireEpoch != null
        ? DateTime.fromMillisecondsSinceEpoch(expireEpoch * 1000)
        : DateTime.now().add(const Duration(hours: 1));

    return HongguoEpisodeMedia(
      videoId: videoId,
      durationSeconds: ((model['video_duration'] as num?)?.toDouble()) ?? 0,
      qualities: qualities,
      expireAt: expireAt,
      videoHeight: (data['video_height'] as num?)?.toInt() ?? 0,
    );
  }

  /// 当前客户端标识（脱敏，供诊断）。
  Map<String, String> get identityForDiagnostics => {
        'deviceId': _deviceId == null
            ? '(未生成)'
            : '${_deviceId!.substring(0, 4)}…${_deviceId!.substring(15)}',
        'installId': _installId == null
            ? '(未生成)'
            : '${_installId!.substring(0, 4)}…${_installId!.substring(15)}',
      };
}
