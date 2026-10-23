/// 红果短剧播放信息客户端。
///
/// 按 video_id 拉取单集的全部清晰度直链（360p / 480p / 540p / 720p / 1080p）。
///
/// # 链路
///
/// 分两步：
///
///  1. `POST /novel/player/video_model/v1/` → 拿 `data.video_model`
///     （一个 JSON 字符串，内含 `fallback_api` 与 `video_list`）
///  2. `GET {fallback_api}` → 拿 `video_info.data.video_list`
///     （真正的多档位直链）
///
/// 第 1 步需要六个签名头；第 2 步的 URL 自带鉴权，直接请求即可。
library;

import 'dart:convert';
import 'dart:math';

import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';
import 'hongguo_signer.dart';
import 'spade_decoder.dart';

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

  /// 平台档位码。
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

  /// 取目标清晰度的档位。
  ///
  /// 先按档位标签精确匹配（`1080` → `1080p`），匹配不到再按物理高度
  /// 找最接近的。不直接用高度差是因为平台的 `height` 是**实际编码高度**，
  /// 与档位标签不一致：实测 540p 档的 height 是 1024，
  /// 若按高度差算，请求 1080 会选中 540p（差 56）而不是 1080p（差 840）。
  HongguoQuality? pickByHeight(int targetHeight) {
    if (qualities.isEmpty) return null;

    // 1) 标签精确匹配
    final label = '${targetHeight}p';
    for (final q in qualities) {
      if (q.definition == label) return q;
    }

    // 2) 退化为高度差
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
  HongguoMediaClient({required FusionHttpClient http, FusionLogger? logger})
    : _http = http,
      _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _host = 'https://api5-normal-sinfonlineb.fqnovel.com';
  static const String _videoModelPath = '/novel/player/video_model/v1/';

  /// 请求所需的客户端参数。
  ///
  /// 版本号与 UA 必须与签名器内部使用的保持一致：
  /// 签名会把 `version_name` 写进 `x-medusa` 的 proto，
  /// 而 query 里也会带一份，两者不一致会被服务端丢弃。
  static const Map<String, String> _guestParams = {
    'ac': 'wifi',
    'channel': 'update_64',
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': '71332',
    'version_name': '7.1.3.32',
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'device_type': '25053RT47C',
    'device_brand': 'Redmi',
    'language': 'zh',
    'os_api': '36',
    'os_version': '16',
    'manifest_version_code': '71332',
    'resolution': '1280*2772',
    'dpi': '520',
    'update_version_code': '71332',
    'host_abi': 'arm64-v8a',
    'dragon_device_type': 'phone',
    'pv_player': '71332',
    'compliance_status': '0',
    'need_personal_recommend': '1',
    'player_so_load': '1',
    'is_android_pad_screen': '0',
  };

  static const String _videoUserAgent =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';

  final _random = Random.secure();

  /// 生成 16 位数字身份。
  ///
  /// 必须每次请求重新生成：同一对 `iid`/`device_id` 复用会被服务端
  /// 静默封锁（返回 HTTP 200 + 空 body），表现为「请求成功但没数据」。
  String _newIdentity() {
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(i == 0 ? 1 + _random.nextInt(9) : _random.nextInt(10));
    }
    return sb.toString();
  }

  /// 拉取一集的播放信息（含全部清晰度）。
  Future<HongguoEpisodeMedia> fetchEpisodeMedia(String videoId) async {
    final model = await _fetchVideoModel(videoId);
    return _fetchFromFallback(model, videoId);
  }

  /// 第一步：取 `video_model`。
  Future<Map<String, Object?>> _fetchVideoModel(String videoId) async {
    final body = jsonEncode({
      'biz_param': {
        'detail_page_version': 0,
        'device_level': 3,
        'disable_digg_stat': false,
        'need_all_video_definition': true,
        'need_mp4_align': false,
        'use_os_player': false,
        'use_server_dns': false,
        'video_platform': 1024,
      },
      'video_id': videoId,
    });
    final bodyBytes = utf8.encode(body);

    const maxAttempts = 4;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      // 每次全新设备身份
      final device = <String, String>{
        ..._guestParams,
        'iid': _newIdentity(),
        'device_id': _newIdentity(),
      };

      final signed = HongguoSigner(random: _random)
          .sign('$_host$_videoModelPath', device, body: bodyBytes);

      final res = await _http.post(
        signed.url,
        body: body,
        headers: signed.headers,
        platformId: 'hongguo',
        timeout: const Duration(seconds: 25),
      );

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

      if (res.body.trim().isEmpty) {
        // 空 body 有两种成因：身份被限流，或服务端偶发。
        // 换身份重试；仍为空再报错。
        _logger.debug('hongguo media: empty body, retry', {
          'attempt': attempt,
          'videoId': videoId,
        });
        lastError = 'empty body';
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
          continue;
        }
        break;
      }

      final code = _bizErrorCode(res.body);
      if (code != null) {
        throw FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '红果播放接口拒绝了本次请求。',
          technicalMessage:
              'business error $code (${_bizErrorMessage(res.body)}) '
              'for $_videoModelPath (videoId=$videoId)',
          platformId: 'hongguo',
          retryable: false,
        );
      }

      final parsed = _parseModel(res.body);
      if (parsed != null) return parsed;

      lastError = 'unparseable body (len=${res.body.length})';
      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }

    throw FusionException(
      code: FusionErrorCode.upstreamError,
      userMessage: '红果播放信息暂时取不到，请稍后重试。',
      technicalMessage:
          'video_model failed after $maxAttempts attempts '
          '(videoId=$videoId, last=$lastError)',
      platformId: 'hongguo',
      retryable: true,
    );
  }

  /// 第二步：请求 `fallback_api` 取真实多档位直链。
  Future<HongguoEpisodeMedia> _fetchFromFallback(
    Map<String, Object?> model,
    String videoId,
  ) async {
    final fallback = _extractFallback(model);
    if (fallback == null || !fallback.startsWith('http')) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '红果播放地址格式异常。',
        technicalMessage:
            'fallback_api missing or malformed (videoId=$videoId)',
        platformId: 'hongguo',
        retryable: false,
      );
    }

    final res = await _http.get(
      fallback,
      headers: {'user-agent': _videoUserAgent, 'accept': 'application/json'},
      platformId: 'hongguo',
      timeout: const Duration(seconds: 25),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '红果播放资源加载失败（HTTP ${res.statusCode}）。',
        technicalMessage: 'HTTP ${res.statusCode} for fallback_api',
        platformId: 'hongguo',
        retryable: res.statusCode >= 500,
      );
    }

    final media = _parseFallback(res.body, model, videoId);
    if (media == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '红果播放信息解析失败。',
        technicalMessage:
            'fallback_api unparseable (len=${res.body.length}, '
            'videoId=$videoId)',
        platformId: 'hongguo',
        retryable: true,
      );
    }
    return media;
  }

  /// 从 `video_model` 里取 `fallback_api`。
  ///
  /// 该字段可能是字符串、对象（含同名键）或数组，三种形态都见过。
  String? _extractFallback(Map<String, Object?> model) {
    final raw = model['fallback_api'];
    if (raw is String) return raw;
    if (raw is Map) {
      final inner =
          raw['fallback_api'] ?? (raw.isEmpty ? null : raw.values.first);
      return inner is String ? inner : null;
    }
    if (raw is List && raw.isNotEmpty) {
      final first = raw.first;
      return first is String ? first : null;
    }
    return null;
  }

  /// 解析第一步响应，返回 `video_model` 对象。
  Map<String, Object?>? _parseModel(String raw) {
    Map<String, Object?>? root;
    try {
      root = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return null;
    }

    final code = root['code'] ?? root['Code'];
    if (code is! int || code != 0) {
      _logger.debug('hongguo media: non-zero code', {
        'code': code,
        'message': root['message'] ?? root['Message'],
      });
      return null;
    }

    final data = root['data'];
    if (data is! Map) return null;

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

    return <String, Object?>{
      ...model.cast<String, Object?>(),
      // 把外层的高度/过期时间带进来，供解析兜底
      '_video_height': data['video_height'],
      '_expire_time': data['expire_time'],
    };
  }

  /// 解析第二步响应。
  HongguoEpisodeMedia? _parseFallback(
    String raw,
    Map<String, Object?> model,
    String videoId,
  ) {
    Map<String, Object?>? root;
    try {
      root = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return null;
    }

    final info = (root['video_info'] as Map?)?['data'] as Map?;
    if (info == null) return null;

    final list = info['video_list'];
    final items = list is Map
        ? list.values.toList()
        : (list is List ? list : null);
    if (items == null || items.isEmpty) return null;

    final qualities = <HongguoQuality>[];
    // 解密所需的种子。没有它就拿不到明文地址。
    final keySeed = (info['key_seed'] as String?) ?? '';
    const decoder = SpadeDecoder();

    for (final item in items) {
      if (item is! Map) continue;

      var url = (item['main_url'] as String?) ?? '';
      if (url.isEmpty) continue;

      // main_url 是加密串（`a8 ?? 01 00` 开头），必须解密才是可用地址。
      // 直接交给播放器会得到「时长 0 + 一直转圈」——它根本不是 URL。
      if (!url.startsWith('http')) {
        final plain = keySeed.isEmpty
            ? null
            : decoder.decryptSpadeUrl(mainUrl: url, keySeed: keySeed);
        if (plain == null || !plain.startsWith('http')) {
          _logger.debug('hongguo media: url decrypt failed', {
            'definition': item['definition'],
            'hasSeed': keySeed.isNotEmpty,
            'prefix': url.length > 8 ? url.substring(0, 8) : url,
          });
          continue;
        }
        url = plain;
      }

      // ByteVC2 声明自己为 bvc2 且不带 avcC/hvcC，播放器只识别到音轨；
      // 只有 ByteVC1（HEVC）能播。
      final codec = (item['codec_type'] as String?) ?? '';
      if (codec == 'bytevc2' || codec == 'bvc2') continue;

      // 档位标签可能落在 definition / quality_desc / height / vheight / quality
      final labelRaw =
          (item['definition'] as String?) ??
          (item['quality_desc'] as String?) ??
          (item['height']?.toString()) ??
          (item['vheight']?.toString()) ??
          (item['quality']?.toString()) ??
          '';
      final match = RegExp(r'\d{3,4}').firstMatch(labelRaw);
      final labelHeight = match == null ? 0 : int.parse(match.group(0)!);
      final definition = labelHeight > 0 ? '${labelHeight}p' : labelRaw;

      qualities.add(
        HongguoQuality(
          definition: definition,
          width:
              (item['vwidth'] as num?)?.toInt() ??
              (item['width'] as num?)?.toInt() ??
              0,
          height:
              (item['vheight'] as num?)?.toInt() ??
              (item['height'] as num?)?.toInt() ??
              labelHeight,
          bitrate: (item['bitrate'] as num?)?.toInt() ?? 0,
          url: url,
          backupUrl: item['backup_url'] as String?,
          codec: codec,
          fileSize: (item['size'] as num?)?.toInt() ?? 0,
          qualityType: (item['quality_type'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    if (qualities.isEmpty) return null;

    qualities.sort((a, b) => a.height.compareTo(b.height));

    final expireEpoch =
        (info['expire_time'] as num?)?.toInt() ??
        (model['_expire_time'] as num?)?.toInt() ??
        (model['url_expire'] as num?)?.toInt();
    final expireAt = expireEpoch != null
        ? DateTime.fromMillisecondsSinceEpoch(expireEpoch * 1000)
        : DateTime.now().add(const Duration(hours: 1));

    return HongguoEpisodeMedia(
      videoId: videoId,
      durationSeconds: ((model['video_duration'] as num?)?.toDouble()) ?? 0,
      qualities: qualities,
      expireAt: expireAt,
      videoHeight: (model['_video_height'] as num?)?.toInt() ?? 0,
    );
  }

  /// 取业务错误码；无错误或解析失败返回 null。
  int? _bizErrorCode(String raw) {
    Map<String, Object?>? root;
    try {
      root = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return null;
    }
    final code = root['Code'] ?? root['code'] ?? root['status_code'];
    if (code is int && code != 0) return code;
    return null;
  }

  String _bizErrorMessage(String raw) {
    try {
      final root = jsonDecode(raw) as Map<String, Object?>;
      return (root['Message'] ?? root['message'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }
}
