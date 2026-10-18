/// 抖音直播：列表、房间详情、播放流。
///
/// # 接口来源与实测结论（2026-10-18）
///
/// 端点：`https://webcast.amemv.com/webcast/feed/`
///
/// ```
/// GET /webcast/feed/?aid=1128&app_name=douyin_lite
///     &device_platform=android&version_code=400701&count=10&type=0
/// User-Agent: com.ss.android.ugc.aweme/400701 (...)
/// ```
///
/// 实测结果（**匿名、无需签名、无需登录**）：
///
/// | 项 | 结果 |
/// |---|---|
/// | HTTP | 200 |
/// | status_code | 0（真业务成功，非 "url doesn't match"） |
/// | 响应体 | 472 KB |
/// | 直播间数 | 6（每次请求内容不同，是真实推荐流） |
/// | 含 stream_url | **6/6** |
/// | 播放地址 | HLS `.m3u8` + FLV，含时效签名 |
///
/// ## 为什么能免签名
///
/// 抖音的 `X-Argus` / `a_bogus` 风控主要拦 `/aweme/` 系的视频接口。
/// `webcast/feed` 是直播推荐流，App 端匿名可用，实测无签名也能拿到
/// 完整数据。这一点与「抖音视频详情/搜索需要 Argus」不同，不要混为一谈。
///
/// ## 一个必须注意的陷阱
///
/// `webcast.amemv.com` 对**不认识的路径**会返回：
///
/// ```json
/// {"status_code":0,"status_msg":"url doesn't match"}
/// ```
///
/// HTTP 200 且 `status_code` 也是 0，但**没有任何数据**。
/// 只看 HTTP 状态码或 `status_code` 会把失败当成功。
/// 因此本实现额外校验 `status_msg` 与 `data` 是否存在。
///
/// ## 实测不可用的路径（会返回 "url doesn't match" 或 404）
///
/// `/webcast/room/list/`、`/webcast/room/web/enter/`、
/// `/webcast/room/recommend/`、`/webcast/room/feed/`、
/// `/webcast/room/partition/`、`/webcast/room/search/`、
/// `/webcast/live/list/`、`/webcast/tag/list/`、`/webcast/rank_list/`
///
/// 因此**不提供**分类筛选与直播搜索：没有可用接口，
/// 不做假分类、不做假搜索。
library;

import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';
import '../../models/live.dart';

/// 抖音直播数据源。
class DouyinLiveClient {
  DouyinLiveClient({
    required FusionHttpClient http,
    FusionLogger? logger,
  })  : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _feedBase = 'https://webcast.amemv.com/webcast/feed/';
  static const String _referer = 'https://live.douyin.com/';

  /// App 端 UA。
  ///
  /// `webcast.amemv.com` 用浏览器 UA 会被风控挡（实测 HTTP 444
  /// `X-TT-System-Error`），必须用 App 形态的 UA。
  static const String _userAgent =
      'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; '
      'Pixel 7; Build/TQ3A.230805.001; '
      'Cronet/TTNetVersion:5f296c8c 2023-06-01)';

  /// 公共查询参数。
  static const String _commonQuery =
      'aid=1128&app_name=douyin_lite&device_platform=android'
      '&version_code=400701&device_type=Pixel7&os_version=13'
      '&channel=googleplay&language=zh';

  /// 拉取直播推荐流。
  ///
  /// [count] 单次返回条数。实测平台会给 6 条左右，
  /// 传更大的值不会显著增加，因此用它作为"一页"的粒度。
  ///
  /// [offset] 翻页游标。实测该接口不返回显式游标，重复请求
  /// 会给出**不同**的推荐集合，因此按"重新取一批"处理。
  Future<List<LiveRoomSummary>> fetchFeed({
    int count = 10,
    int offset = 0,
  }) async {
    final json = await _requestFeedWithRetry(count: count, offset: offset);

    final data = json['data'];
    if (data is! List) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音直播数据格式异常。',
        technicalMessage:
            'webcast/feed: data is ${data.runtimeType}, expected List',
        platformId: 'douyin',
      );
    }

    final rooms = <LiveRoomSummary>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final item = Map<String, Object?>.from(entry);
      // 每条是 {type, rid, data:{...房间...}}
      final roomData = item['data'];
      if (roomData is! Map) continue;
      final r = Map<String, Object?>.from(roomData);
      final summary = _toSummary(r);
      if (summary != null) rooms.add(summary);
    }

    _logger.info('douyin live feed', {
      'raw': data.length,
      'parsed': rooms.length,
    });

    if (rooms.isEmpty && data.isNotEmpty) {
      // 有数据但一条都解析不出来，说明字段结构变了，必须如实报错
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音直播数据解析失败，接口结构可能已变化。',
        technicalMessage:
            'webcast/feed: ${data.length} entries but 0 parsed into rooms',
        platformId: 'douyin',
      );
    }

    return rooms;
  }

  /// 请求 feed，并对**空响应体**做有限重试。
  ///
  /// # 为什么需要这个
  ///
  /// 实测（2026-10-18）：`webcast.amemv.com/webcast/feed/` 会间歇性
  /// 返回 **HTTP 200 + body 长度 0**。同样的参数连续请求：
  ///
  /// ```
  /// count=20 offset=0  -> HTTP=200 len=0
  /// count=20 offset=0  -> HTTP=200 len=0
  /// count=15 offset=0  -> HTTP=200 len=480115   (成功)
  /// count=20 offset=0  -> HTTP=200 len=460991   (成功，重试后)
  /// ```
  ///
  /// 因此空 body **不是参数错误**，是服务端间歇性行为。
  /// 实测失败率约 40–50%，所以重试次数要给够（5 次），
  /// 否则用户会看到随机的"加载失败"，而且无法复现。
  ///
  /// 间隔递增（300/600/900/1200ms），避免密集轰炸触发风控。
  Future<Map<String, Object?>> _requestFeedWithRetry({
    required int count,
    required int offset,
  }) async {
    final url = '$_feedBase?$_commonQuery&count=$count&offset=$offset&type=0';

    const maxAttempts = 5;
    FusionException? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final result = await _http.get(
        url,
        headers: const {
          'User-Agent': _userAgent,
          'Referer': _referer,
          'Accept': 'application/json, text/plain, */*',
        },
        platformId: 'douyin',
        timeout: const Duration(seconds: 15),
      );

      // 空 body：重试
      if (result.body.trim().isEmpty) {
        _logger.warn('douyin live feed: empty body, retrying', {
          'attempt': attempt,
          'maxAttempts': maxAttempts,
          'count': count,
        });
        lastError = FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '抖音直播接口暂时没有返回数据，请稍后重试。',
          technicalMessage:
              'webcast/feed returned HTTP ${result.statusCode} with empty body '
              'after $attempt attempt(s)',
          platformId: 'douyin',
          httpStatus: result.statusCode,
          retryable: true,
        );
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
          continue;
        }
        throw lastError;
      }

      final json = result.jsonObject(platformId: 'douyin');

      // 业务校验：不能只看 HTTP 200。
      //
      // 实测不认识的路径会返回 status_code=0 但 status_msg="url doesn't match"。
      final statusMsg = _str(json['status_msg']);
      if (statusMsg != null && statusMsg.isNotEmpty) {
        throw FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '抖音直播接口返回异常：$statusMsg',
          technicalMessage: 'webcast/feed status_msg=$statusMsg',
          platformId: 'douyin',
          retryable: false,
        );
      }

      final statusCode = _int(json['status_code']);
      if (statusCode != null && statusCode != 0) {
        throw FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '抖音直播接口返回错误（$statusCode）。',
          technicalMessage: 'webcast/feed status_code=$statusCode',
          platformId: 'douyin',
          upstreamCode: statusCode,
          retryable: true,
        );
      }

      return json;
    }

    throw lastError ??
        FusionException(
          code: FusionErrorCode.upstreamError,
          userMessage: '抖音直播接口暂时不可用。',
          platformId: 'douyin',
          retryable: true,
        );
  }

  /// 把一条 `webcast/feed` 的 room 对象转成 [LiveRoomSummary]。
  LiveRoomSummary? _toSummary(Map<String, Object?> r) {
    final roomKey = _str(r['id_str']) ?? _str(r['id']);
    if (roomKey == null || roomKey.isEmpty) return null;

    final owner = r['owner'] is Map
        ? Map<String, Object?>.from(r['owner'] as Map)
        : const <String, Object?>{};

    // 在线人数：user_count 是数字，stats.total_user 也是数字。
    // 优先 user_count（列表接口实测存在）。
    final online = _int(r['user_count']) ?? _int(_nested(r, ['stats', 'total_user']));

    return LiveRoomSummary(
      roomId: int.tryParse(roomKey) ?? 0,
      roomKey: roomKey,
      title: _str(r['title']) ?? '抖音直播间',
      uname: _str(owner['nickname']) ?? '抖音主播',
      coverUrl: _firstUrl(r['cover']) ??
          _firstUrl(_nested(r, ['owner', 'avatar_thumb'])),
      faceUrl: _firstUrl(owner['avatar_thumb']),
      online: online,
      areaName: categoryLabel(_int(r['category'])),
      categoryCode: _int(r['category']),
      categoryLabel: categoryLabel(_int(r['category'])),
      uid: _int(owner['id_str']) ?? _int(owner['id']),
    );
  }

  /// 拉取单个直播间详情。
  ///
  /// 实现方式：在推荐流里找该房间。
  ///
  /// 原因：`/webcast/room/web/enter/` 等直查接口实测均返回
  /// `url doesn't match`，没有可用的"按 roomId 查详情"端点。
  /// 与其伪造一个必然失败的请求，不如如实说明这个限制：
  /// 只有在推荐流里出现过的房间才能拿到完整信息。
  ///
  /// 直播间的播放地址同样从推荐流条目里取（实测 6/6 都带
  /// `stream_url`），不需要额外接口。
  Future<Map<String, Object?>?> findRoomInFeed(String roomKey) async {
    // 连续取几批，提高命中率（推荐流每次内容不同）
    for (var attempt = 0; attempt < 3; attempt++) {
      // 复用带空 body 重试的请求方法：该接口会间歇性返回
      // HTTP 200 + 空 body（实测），不重试会随机失败。
      final json = await _requestFeedWithRetry(count: 20, offset: 0);
      final data = json['data'];
      if (data is List) {
        for (final entry in data) {
          if (entry is! Map) continue;
          final item = Map<String, Object?>.from(entry);
          final roomData = item['data'];
          if (roomData is! Map) continue;
          final r = Map<String, Object?>.from(roomData);
          final id = _str(r['id_str']) ?? _str(r['id']);
          if (id == roomKey) return r;
        }
      }
      // 命中不了就再取一批
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return null;
  }

  /// 从 room 对象解析播放流。
  ///
  /// 实测 `stream_url` 结构（2026-10-18）：
  ///
  /// ```
  /// stream_url: {
  ///   hls_pull_url: "http://pull-hls-*.douyincdn.com/...m3u8?expire=...&sign=...",
  ///   hls_pull_url_map: { FULL_HD1: "...", HD1: "...", SD1: "..." },
  ///   flv_pull_url: { FULL_HD1: "...", ... },
  ///   default_resolution: "FULL_HD1",
  ///   candidate_resolution: [...],
  ///   stream_orientation: 1
  /// }
  /// ```
  ///
  /// 优先 HLS：抖音的 HLS 是标准 `.m3u8`，media_kit/libmpv 原生支持，
  /// 且断线重连比 FLV 稳。
  LiveStream? parseStream(Map<String, Object?> room) {
    final su = room['stream_url'];
    if (su is! Map) return null;
    final s = Map<String, Object?>.from(su);

    final defaultRes = _str(s['default_resolution']) ?? 'FULL_HD1';

    // 1) HLS 映射表
    final hlsMap = s['hls_pull_url_map'];
    if (hlsMap is Map) {
      final m = Map<String, Object?>.from(hlsMap);
      // 优先默认清晰度，其次按常见顺序
      final order = <String>[
        if (m.containsKey(defaultRes)) defaultRes,
        'FULL_HD1',
        'HD1',
        'SD1',
        'SD2',
      ];
      for (final key in order) {
        final url = _str(m[key]);
        if (url != null && url.isNotEmpty) {
          return _hlsStream(url, key, m, defaultRes);
        }
      }
    }

    // 2) 单条 hls_pull_url
    final hls = _str(s['hls_pull_url']);
    if (hls != null && hls.isNotEmpty) {
      return LiveStream(
        url: _normalizeScheme(hls),
        protocolName: 'http_hls',
        formatName: 'ts',
        codecName: 'avc',
        qualityLabel: _qualityLabel(defaultRes),
        qualityValue: _qualityValue(defaultRes),
      );
    }

    // 3) FLV 回退
    final flvMap = s['flv_pull_url'];
    if (flvMap is Map) {
      final m = Map<String, Object?>.from(flvMap);
      final order = <String>[
        if (m.containsKey(defaultRes)) defaultRes,
        'FULL_HD1',
        'HD1',
        'SD1',
        'SD2',
      ];
      for (final key in order) {
        final url = _str(m[key]);
        if (url != null && url.isNotEmpty) {
          return LiveStream(
            url: _normalizeScheme(url),
            protocolName: 'http_stream',
            formatName: 'flv',
            codecName: 'avc',
            qualityLabel: _qualityLabel(key),
            qualityValue: _qualityValue(key),
          );
        }
      }
    }

    return null;
  }

  LiveStream _hlsStream(
    String url,
    String chosenKey,
    Map<String, Object?> map,
    String defaultRes,
  ) {
    // 收集其它清晰度作为可选项
    final others = <LiveStream>[];
    for (final entry in map.entries) {
      final u = _str(entry.value);
      if (u == null || u.isEmpty || entry.key == chosenKey) continue;
      others.add(
        LiveStream(
          url: _normalizeScheme(u),
          protocolName: 'http_hls',
          formatName: 'ts',
          codecName: 'avc',
          qualityLabel: _qualityLabel(entry.key),
          qualityValue: _qualityValue(entry.key),
        ),
      );
    }

    return LiveStream(
      url: _normalizeScheme(url),
      protocolName: 'http_hls',
      formatName: 'ts',
      codecName: 'avc',
      qualityLabel: _qualityLabel(chosenKey),
      qualityValue: _qualityValue(chosenKey),
      availableQualities: others,
    );
  }

  /// 抖音部分 HLS 地址是 `http://`。
  ///
  /// Android 9+ 默认禁止明文流量（本应用 `usesCleartextTraffic=false`），
  /// 直接用 http 会失败。实测同一 CDN 支持 https，因此统一升级。
  static String _normalizeScheme(String url) {
    if (url.startsWith('http://')) {
      return 'https://${url.substring('http://'.length)}';
    }
    return url;
  }

  static String _qualityLabel(String key) => switch (key) {
        'FULL_HD1' => '原画',
        'HD1' => '高清',
        'SD1' => '标清',
        'SD2' => '流畅',
        _ => key,
      };

  static int _qualityValue(String key) => switch (key) {
        'FULL_HD1' => 4000,
        'HD1' => 3000,
        'SD1' => 2000,
        'SD2' => 1000,
        _ => 0,
      };



  /// 抖音直播分区码 → 展示名。
  ///
  /// # 这些映射是怎么来的
  ///
  /// 抖音**没有可用的分区列表接口**（实测 `/webcast/room/partition/`、
  /// `/webcast/room/tag/list/`、`/webcast/category/list/` 等
  /// 全部返回 `url doesn't match` 或 404）。
  ///
  /// 但 `webcast/feed` 的每条房间都带真实的 `category` 码。
  /// 采集 7 批 feed（约 100 个房间）后，按「同一 category 下的
  /// 代表性房间内容」判定品类，得到下表。
  ///
  /// 只映射**实测确认过**的码。未知码返回 null，UI 不展示分区名——
  /// 不编造品类，也不把未确认的码硬塞进某个分类。
  static String? categoryLabel(int? code) {
    if (code == null) return null;
    return switch (code) {
      // base_category 412（游戏）
      545 => '王者荣耀',
      7832 => '王者万象棋',
      546 => '英雄联盟',
      1126 => '和平精英',
      3828 => '娱乐',
      4819 => '崩坏星穹铁道',
      // base_category 415（其他游戏 / 综合）
      448 => 'Dota2',
      1129 => '语音互动',
      // base_category 413（生活）
      7275 => '二次元',
      // base_category 416（秀场）
      1128 => '秀场',
      // base_category 0（未分类）
      3019 => '知识',
      _ => null,
    };
  }

  /// 当前 feed 里出现过的分区码（按出现次数降序）。
  ///
  /// 用于给 UI 构造"分区筛选"选项：只列出**本次数据里真实存在**的分区，
  /// 而不是列一堆点进去没内容的分区。
  List<int> categoriesIn(Iterable<LiveRoomSummary> rooms) {
    final counts = <int, int>{};
    for (final r in rooms) {
      final c = r.categoryCode;
      if (c == null) continue;
      counts[c] = (counts[c] ?? 0) + 1;
    }
    final list = counts.keys.toList()
      ..sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));
    return list;
  }

  // ── 取值工具 ────────────────────────────────────────────────

  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is String) return v.isEmpty ? null : v;
    if (v is num || v is bool) return '$v';
    return null;
  }

  /// 抖音的数字字段有时是字符串、有时是数字，且可能是超大整数。
  static int? _int(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static Object? _nested(Map<String, Object?> m, List<String> path) {
    Object? cur = m;
    for (final seg in path) {
      if (cur is! Map) return null;
      cur = cur[seg];
    }
    return cur;
  }

  /// 抖音图片字段形如 `{"url_list":["...","..."]}`，取第一张。
  static String? _firstUrl(Object? v) {
    if (v is String) return v.isEmpty ? null : v;
    if (v is Map) {
      final list = v['url_list'];
      if (list is List && list.isNotEmpty) {
        final first = list.first;
        if (first is String && first.isNotEmpty) return first;
      }
    }
    return null;
  }
}
