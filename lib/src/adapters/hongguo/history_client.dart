/// 红果观看历史客户端。
///
/// # 实测结论（2026-10-24）
///
/// `GET /reading/bookapi/read_history/list/v1/?page_count=20&<guest参数>`
///
/// | 请求形态 | 响应 |
/// |---|---|
/// | 带 guest 参数（iid/device_id） | `code:0` + `data_list:[]` + `total:0` |
/// | 不带 iid/device_id | `code:101108` `USER_NOT_LOGIN` |
///
/// **两种都不需要签名**。带 guest 参数时服务端把请求当成匿名访客，
/// 正常返回但列表必然为空——没有身份就没有历史。
///
/// 所以这个能力**必须有红果登录态**才可能拿到数据。当前项目没有红果
/// 登录链路（红果走 APP 端，登录需要抖音账号授权），因此这里只做到
/// 「接口可达 + 如实区分空列表与未登录」，不谎报能读到数据。
library;

import 'dart:convert';

import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';

/// 一条观看历史。
class HongguoHistoryItem {
  const HongguoHistoryItem({
    required this.bookId,
    required this.title,
    this.coverUrl,
    this.chapterIndex,
    this.readTimestamp,
  });

  /// 剧集/书籍 id。
  final String bookId;

  final String title;
  final String? coverUrl;

  /// 看到第几集（平台字段 `chapter_index`，0 基）。
  final int? chapterIndex;

  /// 最后观看时间（秒级时间戳）。
  final int? readTimestamp;

  @override
  String toString() => 'HongguoHistoryItem($bookId, $title)';
}

/// 观看历史拉取结果。
///
/// # 为什么不是一个裸列表
///
/// 必须区分三种状态，否则 UI 会把「未登录」渲染成「你还没看过剧」：
///  - [items] 非空 → 有数据
///  - [items] 为空 + [loginRequired] = true → 未登录，登录后才有
///  - [items] 为空 + [loginRequired] = false → 确实没有记录
class HongguoHistoryResult {
  const HongguoHistoryResult({
    required this.items,
    required this.total,
    required this.hasMore,
    required this.nextOffset,
    required this.loginRequired,
    this.notes = const [],
  });

  final List<HongguoHistoryItem> items;
  final int total;
  final bool hasMore;
  final int nextOffset;

  /// 服务端是否明确表示需要登录（`code=101108`）。
  final bool loginRequired;

  final List<String> notes;

  bool get isEmpty => items.isEmpty;
}

/// 红果观看历史客户端。
class HongguoHistoryClient {
  HongguoHistoryClient({required FusionHttpClient http, FusionLogger? logger})
    : _http = http,
      _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final FusionLogger _logger;

  static const String _host = 'https://api5-normal-sinfonlineb.fqnovel.com';
  static const String _path = '/reading/bookapi/read_history/list/v1/';

  /// 与播放链路一致的客户端参数。版本号必须与签名器/UA 同源。
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
    'compliance_status': '0',
  };

  static const String _userAgent =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
      'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
      'QuicVersion:c67e9834 2025-09-08)';

  /// 拉一页观看历史。
  ///
  /// [iid] / [deviceId] 为设备身份。每次请求应使用**新**身份：
  /// 复用同一对会被服务端静默封锁（返回空 body，见 media_client 的说明）。
  Future<HongguoHistoryResult> fetchHistory({
    required String iid,
    required String deviceId,
    int pageCount = 20,
    int offset = 0,
  }) async {
    final query = <String, String>{
      ..._guestParams,
      'iid': iid,
      'device_id': deviceId,
      'page_count': '$pageCount',
      if (offset > 0) 'next_offset': '$offset',
    };

    final uri = Uri.parse('$_host$_path').replace(queryParameters: query);

    final res = await _http.get(
      uri.toString(),
      headers: {'user-agent': _userAgent, 'accept': 'application/json'},
      platformId: 'hongguo',
      timeout: const Duration(seconds: 20),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw FusionException(
        code: FusionErrorCode.networkError,
        userMessage: '红果观看历史加载失败（HTTP ${res.statusCode}）。',
        technicalMessage: 'HTTP ${res.statusCode} for $_path',
        platformId: 'hongguo',
        retryable: res.statusCode >= 500,
      );
    }

    Map<String, Object?>? root;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map) root = Map<String, Object?>.from(decoded);
    } catch (_) {
      root = null;
    }
    if (root == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '红果观看历史解析失败。',
        technicalMessage: 'unparseable body (len=${res.body.length})',
        platformId: 'hongguo',
        retryable: true,
      );
    }

    final code = (root['code'] as num?)?.toInt() ?? -1;
    if (code == 101108) {
      // 明确未登录：不是错误，是状态。
      return const HongguoHistoryResult(
        items: [],
        total: 0,
        hasMore: false,
        nextOffset: 0,
        loginRequired: true,
        notes: ['红果账号未登录，历史记录需要登录后才能读取。'],
      );
    }
    if (code != 0) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '红果观看历史暂时不可用（${root['message'] ?? code}）。',
        technicalMessage: 'business error $code (${root['message']})',
        upstreamCode: code,
        platformId: 'hongguo',
        retryable: false,
      );
    }

    final data = root['data'];
    if (data is! Map) {
      return const HongguoHistoryResult(
        items: [],
        total: 0,
        hasMore: false,
        nextOffset: 0,
        loginRequired: false,
        notes: ['服务端未返回数据段。'],
      );
    }
    final d = Map<String, Object?>.from(data);
    final rawList = d['data_list'];
    final items = <HongguoHistoryItem>[];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final m = Map<String, Object?>.from(raw);
        final id = _str(m['book_id']) ?? _str(m['series_id']);
        if (id == null) continue;
        items.add(
          HongguoHistoryItem(
            bookId: id,
            title: _str(m['book_name']) ?? _str(m['title']) ?? '红果短剧',
            coverUrl: _str(m['thumb_url']) ?? _str(m['cover']),
            chapterIndex: (m['chapter_index'] as num?)?.toInt(),
            readTimestamp: (m['read_timestamp'] as num?)?.toInt(),
          ),
        );
      }
    }

    final total = (d['total'] as num?)?.toInt() ?? 0;
    final hasMore = d['has_more'] == true;
    final nextOffset = (d['next_offset'] as num?)?.toInt() ?? 0;

    _logger.debug('hongguo history', {
      'items': items.length,
      'total': total,
      'hasMore': hasMore,
    });

    return HongguoHistoryResult(
      items: items,
      total: total,
      hasMore: hasMore,
      nextOffset: nextOffset,
      loginRequired: false,
      notes: [
        // 如实交代：匿名访客必然拿到空列表。
        if (items.isEmpty) '当前为匿名访问，红果不返回任何历史记录。',
      ],
    );
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is String) return v.trim().isEmpty ? null : v.trim();
    return '$v';
  }
}
