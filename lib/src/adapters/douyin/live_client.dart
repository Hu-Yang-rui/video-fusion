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

import 'dart:convert';

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

  /// 按房间号直查详情的端点（**匿名可用**，实测 2026-10-19）。
  static const String _roomInfoBase =
      'https://webcast.amemv.com/webcast/room/info/';

  /// `room/info` 的**最小必需参数集**：恰好三个，缺一不可。
  ///
  /// 逐变量消融实测（每组打 3 次，同房间）：
  ///
  /// ```
  /// aid=6383&device_platform=web&version_code=180800   → 3/3 成功，len≈48 KB，165 字段
  /// 删 device_platform                                  → 0/3，HTTP 200 / len=0
  /// 删 aid                                              → 0/3，len=0
  /// 删 version_code                                     → 0/3，len=0
  /// device_platform=webapp                              → 3/3 成功
  /// device_platform=android / pc                        → 0/3
  /// ```
  ///
  /// 曾经有过一次**假阴性**：另一份探针的参数集缺 `device_platform`，
  /// 于是得出"54 组参数矩阵 0/54 全败、该端点不可用"的结论并写进了注释。
  /// 根因就是缺这一个参数，不是端点失效。**改动这行前先复现上面的消融表。**
  ///
  /// `channel` / `version_name` / `browser_*` / `screen_*` / `timezone_name`
  /// / `cookie_enabled` / `pc_client_type` 实测**全部可选**；
  /// 不需要 cookie、不需要预热 live.douyin.com 拿 ttwid、
  /// UA 不敏感（Chrome UA / App UA / 空 UA / 完全裸请求都 3/3 成功）。
  ///
  /// 注意 `room/info_by_user` 对 `device_platform` **不敏感**，
  /// 两个端点不要共用一套参数串。
  static const String _roomInfoQuery =
      'aid=6383&device_platform=web&version_code=180800';

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
  ///
  /// # 注意解析层级（实测，两个坑）
  ///
  /// `webcast/feed` 的 `data[i]` **不是**房间对象，而是 **27 个 key 的信封**：
  /// `type / rid / live_reason / live_status / is_pseudo_living /
  /// is_recommend_card / is_ad / web_rid / user_id / content_category /
  /// tabs / tags / data = {房间对象}`。
  ///
  ///  - **信封层的 `rid` 是本次请求的 impr 串，不是房间号**；房间号只在
  ///    `data[i].data.id_str`。拿信封 `rid` 当房间标识会全库错配。
  ///  - **信封层的 `live_status=0` 与房间对象的 `status=2` 是不同层的字段**。
  ///    若用信封的 `live_status` 判在播，实测会把 6/6 房间全判成"未开播"。
  ///    在播与否一律读 `data[i].data.status`。
  ///  - 信封层与 `owner` 里的 `web_rid` **都是空串** → 匿名拿不到任何可用
  ///    web_rid，`/webcast/room/web/enter/` 这条路封死，不要再凑参数。
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

  /// 按房间号直查直播间详情（**匿名可用**，实测 2026-10-19 复核）。
  ///
  /// ```
  /// GET https://webcast.amemv.com/webcast/room/info/
  ///     ?aid=6383&device_platform=web&version_code=180800&room_id=<id_str>
  /// ```
  ///
  /// # 实测（本地独立复跑，非转述）
  ///
  /// | 维度 | 结果 |
  /// |---|---|
  /// | 必需参数 | **恰好 3 个**：`aid=6383` + `device_platform=web`(或 `webapp`) + `version_code`；删任一个 → HTTP 200 / len=0 |
  /// | cookie / 预热 | 不需要（预热拿 ttwid 后结果一样） |
  /// | UA | 不敏感：Chrome / App / 空 UA / 裸请求 全部成功 |
  /// | 间歇性 | **不间歇**：同房间连打 6 次全部 len≈48 KB（feed 才有 5/7 空 body，别把 feed 的重试套到这里） |
  /// | 参数名 | 必须 `room_id`；写 `room_id_str`/`id_str`/`roomId` → `status_code=10011 "Request params error"` |
  /// | 域名 | 只有 `webcast.amemv.com` 通；`live.douyin.com/webcast/room/info/` → 404 len=18；`webcast.bytedance.com` → 404 |
  /// | 响应 | `data` 165 字段、`stream_url` 28 字段 |
  ///
  /// [roomKey] **必须是平台下发的字符串房间号（`id_str`）**：19 位整数经
  /// number 中转会丢末位精度（实测 `7697991152271723273` →
  /// `7697991152271724000`），丢一位就变成 `status_code=30001`
  /// 「该直播室不存在」。这里全程按字符串拼 URL，绝不 `int.parse` 再转回。
  ///
  /// # 错误语义（映射成可区分的异常，不一律"加载失败"）
  ///
  ///  - `30001` → 房间不存在/已关闭（实测 `data.message="room doesn’t exist"`、
  ///    `data.prompts="该直播室不存在"`）
  ///  - `10011` → 请求参数错误。这是**实现 bug**，不是用户的问题，
  ///    technicalMessage 里带上 roomKey 与其长度。
  ///  - `20003` → 需要登录。
  ///  - HTTP 200 + 空 body → **参数集不对**（缺 `device_platform` /
  ///    `version_code` / `aid`），technicalMessage 明确写
  ///    `empty body (check device_platform/version_code)`，
  ///    绝不能被误读成"房间不在了"。
  ///
  /// 上层约定：本方法**只**在拿到房间对象时返回；任何失败都抛
  /// [FusionException]。调用方（适配器）负责"room/info 失败 → 回退
  /// [findRoomInFeed]"这条降级链。
  Future<Map<String, Object?>> fetchRoomInfo(String roomKey) async {
    final key = roomKey.trim();
    if (key.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '直播间号为空，无法进入。',
        technicalMessage: 'room/info: empty roomKey',
        platformId: 'douyin',
        retryable: false,
      );
    }
    // 房间号只应是数字串。带别的东西说明上游传错了标识。
    if (!RegExp(r'^\d{6,25}$').hasMatch(key)) {
      throw FusionException(
        code: FusionErrorCode.videoIdNotFound,
        userMessage: '直播间号格式不正确。',
        technicalMessage:
            'room/info: roomKey is not a numeric id_str (len=${key.length})',
        platformId: 'douyin',
        retryable: false,
      );
    }

    final url = '$_roomInfoBase?$_roomInfoQuery&room_id=$key';

    // 与 feed 不同：该端点实测稳定，**不做空 body 重试**。
    // 空 body 意味着参数集被平台拒了，重试没有意义，直接如实报错。
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

    if (result.body.trim().isEmpty) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '抖音未能读取该直播间的信息。',
        technicalMessage:
            'room/info HTTP ${result.statusCode} empty body '
            '(check device_platform/version_code — this means the query '
            'parameter set was rejected, NOT that the room is gone); '
            'room_id_len=${key.length}',
        platformId: 'douyin',
        httpStatus: result.statusCode,
        retryable: true,
      );
    }

    final json = result.jsonObject(platformId: 'douyin');
    final statusCode = _int(json['status_code']);

    if (statusCode != null && statusCode != 0) {
      // data 里可能带更具体的人类可读提示（如 prompts="该直播室不存在"）。
      final data = json['data'] is Map
          ? Map<String, Object?>.from(json['data'] as Map)
          : const <String, Object?>{};
      final prompt = _str(data['prompts']) ?? _str(data['message']);

      throw switch (statusCode) {
        // 房间不存在 / 已关闭。
        30001 => FusionException(
            code: FusionErrorCode.videoNotFound,
            userMessage: '该直播间不存在或已被关闭。',
            technicalMessage:
                'room/info status_code=30001 room doesn\'t exist; '
                'room_id_len=${key.length} prompts=$prompt',
            platformId: 'douyin',
            upstreamCode: statusCode,
            retryable: false,
          ),
        // 参数错误：属于我方实现 bug（参数名必须是 room_id，值必须是
        // 未丢精度的字符串 id_str）。
        10011 => FusionException(
            code: FusionErrorCode.upstreamError,
            userMessage: '无法读取该直播间的信息。',
            technicalMessage:
                'room/info status_code=10011 Request params error; '
                'roomKey=$key len=${key.length} '
                '(param name must be room_id, value must be the string '
                'id_str — number round-trip loses the last digits)',
            platformId: 'douyin',
            upstreamCode: statusCode,
            retryable: false,
          ),
        // 需要登录。
        20003 => FusionException(
            code: FusionErrorCode.loginRequired,
            userMessage: '该直播间需要登录后才能观看。',
            technicalMessage: 'room/info status_code=20003 User doesn\'t login',
            platformId: 'douyin',
            upstreamCode: statusCode,
            retryable: false,
          ),
        _ => FusionException(
            code: FusionErrorCode.upstreamError,
            userMessage: '抖音直播接口返回错误（$statusCode）。',
            technicalMessage:
                'room/info status_code=$statusCode status_msg=${_str(json['status_msg'])}',
            platformId: 'douyin',
            upstreamCode: statusCode,
            retryable: true,
          ),
      };
    }

    // "url doesn't match" 陷阱：HTTP 200 + status_code=0 + 无数据。
    final data = json['data'];
    if (data is! Map || data.isEmpty) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音未返回该直播间的数据。',
        technicalMessage:
            'room/info: status_code=0 but data is ${data.runtimeType}'
            ' (url doesn\'t match 形态：HTTP 200 无负载)',
        platformId: 'douyin',
        retryable: true,
      );
    }

    final room = Map<String, Object?>.from(data);
    if (_str(room['id_str']) == null && _str(room['id']) == null) {
      throw FusionException(
        code: FusionErrorCode.parseError,
        userMessage: '抖音返回的直播间数据不完整。',
        technicalMessage:
            'room/info: data has ${room.length} keys but no id_str/id',
        platformId: 'douyin',
        retryable: true,
      );
    }
    return room;
  }

  /// 在推荐流里翻找某个房间（[fetchRoomInfo] 的**兜底路径**）。
  ///
  /// 为什么这条链必须保留，而不是只用 room/info：
  ///  - feed 是**列表**的唯一来源（没有可用的分区/房间列表接口）；
  ///  - room/info 虽实测稳定，但一旦平台收紧风控（`len=0` / 新业务码），
  ///    仍然要能进房间 —— 兜底比"完全打不开"诚实；
  ///  - 房间对象结构与 feed 一致，[parseStream] / [_toSummary] 两条路径共用。
  ///
  /// # feed 的两个实测事实（决定了下面这套重试）
  ///
  ///  1. **`count` 参数不生效，每批恒 6 条**。实测 count=10/12/20 都只给
  ///     6 条，所以"多拉几批"是唯一增大命中面的办法。
  ///  2. **间歇性 HTTP 200 + 空 body**，本地实测 9/12 批次为空
  ///     （`[6,0,0,0,0,0,6,0,0,0,6]`）。空 body 不是参数错误，是服务端
  ///     间歇行为，因此 [_requestFeedWithRetry] 的重试**是必要的**，
  ///     不要当作冗余删掉。
  ///
  /// 代价：一次 `findRoomInFeed` 最多翻 3 批 × 每批内 5 次空 body 重试。
  /// 未命中时返回 null，并由调用方决定报错文案；本方法把**已尝试批次数与
  /// 累计扫过的条目数**写进日志与异常，方便区分"没翻到"和"feed 全空"。
  Future<Map<String, Object?>?> findRoomInFeed(String roomKey) async {
    const maxBatches = 3;
    var scanned = 0;
    var emptyBatches = 0;

    // 连续取几批，提高命中率（推荐流每次内容不同）
    for (var attempt = 0; attempt < maxBatches; attempt++) {
      // 复用带空 body 重试的请求方法：该接口会间歇性返回
      // HTTP 200 + 空 body（实测），不重试会随机失败。
      final json = await _requestFeedWithRetry(count: 20, offset: 0);
      final data = json['data'];
      if (data is List) {
        if (data.isEmpty) emptyBatches++;
        scanned += data.length;
        for (final entry in data) {
          if (entry is! Map) continue;
          final item = Map<String, Object?>.from(entry);
          // 信封层是 {type, rid, ..., data:{房间对象}}；**rid 是请求级
          // impr 串，不是房间号**，房间只在 data 这一层。
          final roomData = item['data'];
          if (roomData is! Map) continue;
          final r = Map<String, Object?>.from(roomData);
          final id = _str(r['id_str']) ?? _str(r['id']);
          if (id == roomKey) {
            _logger.info('douyin live: room found in feed', {
              'roomKey': roomKey,
              'batch': attempt + 1,
              'scanned': scanned,
            });
            return r;
          }
        }
      }
      // 命中不了就再取一批
      if (attempt < maxBatches - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    _logger.warn('douyin live: room not found in feed', {
      'roomKey': roomKey,
      'batches': maxBatches,
      'scanned': scanned,
      'emptyBatches': emptyBatches,
    });
    // 未命中：把"翻了几批、扫了几条"带进异常，方便排查是命中率问题
    // 还是 feed 一直在给空 body。
    _lastFeedMiss =
        'scanned $scanned entries across $maxBatches batch(es) '
        '($emptyBatches of them returned an empty data list); '
        'feed gives a fixed 6 rooms per batch regardless of count';
    return null;
  }

  /// 最近一次 [findRoomInFeed] 未命中的统计描述，供调用方拼进
  /// technicalMessage。命中时置 null。
  String? _lastFeedMiss;

  /// 读取并清空 [_lastFeedMiss]。
  String? takeLastFeedMiss() {
    final v = _lastFeedMiss;
    _lastFeedMiss = null;
    return v;
  }

  /// 从 room 对象解析播放流。
  ///
  /// # 实测 `stream_url` 结构（2026-10-19，本地探针复核，非推测）
  ///
  /// 同一个 `stream_url` 在 **feed** 与 **room/info** 两个端点里
  /// **字段可得性不同**，这张表就是取值优先级的依据：
  ///
  /// | 字段 | feed（实测 12 房间） | room/info（实测） |
  /// |---|---|---|
  /// | `hls_pull_url_map`（4 档） | ✅ FULL_HD1/HD1/SD1/SD2 | ✅ 同样 4 档 |
  /// | 顶层 `hls_pull_url` | ❌ **0/12 是空串** | ✅ 非空（实测 311 B） |
  /// | 顶层 `flv_pull_url` | ❌ **0/12 是 `{}`** | ✅ 4 档 |
  /// | `live_core_sdk_data.pull_data.stream_data` | ✅ **被字符串化的 JSON**（12/12 type=string，需二次 decode） | ✅ 同样是 string（实测 8650 B） |
  /// | 真实 FLV 地址 | 只在上面的 `stream_data` 里 | 顶层 + `stream_data` 都有 |
  /// | `stream_orientation` | 在 **`stream_url` 里**，房间顶层**没有**这个 key（0/6） | 同样在 `stream_url` 里 |
  /// | `user_count` | 较旧 | **更新鲜**，进房后以 room/info 为准 |
  ///
  /// 因此三级回退（map → 顶层 hls → 顶层 flv）在 feed 路径上只有第 1 级
  /// 能命中，在 room/info 路径上三级都能命中。
  ///
  /// # 编码：默认 HEVC，逐档如实标注
  ///
  /// 实测 `options.qualities` 的 `v_codec` **100% 是 `bytevc1`**
  /// （字节的 HEVC 变体），拉流解 PMT 也印证：`stream_type=0x24`=H.265 +
  /// `0x0F`=AAC。旧实现把每一档硬写成 `codecName: 'avc'` 与事实相反。
  ///
  /// 一个**反直觉的坑**：`stream_url.extra.h265_enable` 实测是 `false`，
  /// `extra.bytevc1_enable` 也是 `false`、`extra.video_profile` 是 `0`，
  /// 而流本身确实是 HEVC —— 这几个字段描述的是**推流侧**能力协商，
  /// 不是当前这路流的编码，**不能**拿来当 codecName 判据（用它会把
  /// 真实的 HEVC 标成 AVC）。所以 [ _codecNameFor] 以
  /// `options.qualities[].v_codec` 为主判据。
  ///
  /// # 排序不能靠档位名
  ///
  /// 平台档位命名与实际质量**不单调对应**：实测真实序是
  /// `FULL_HD1(蓝光) > HD1(超清) ≈ SD2(高清) > SD1(标清)`，
  /// 即 **SD2 高于 SD1**，名字里的数字顺序是反的。
  /// 所以档位名只当展示（见 [_qualityLabel]），排序一律用平台给的
  /// `options.qualities[].level` / `v_bit_rate`（见 [_qualityValue]）。
  ///
  /// # 优先 HLS
  ///
  /// 抖音 HLS 是标准 `.m3u8` + **MPEG-TS** 分片（实测分片首字节
  /// `47 40 00 10 00 00 b0 0d` = TS sync 0x47、188 字节包对齐，**不是** fMP4），
  /// media_kit/libmpv 原生支持，断线重连比 FLV 稳。FLV 实测也能拉
  /// （`content-type: video/x-flv`，魔数 `FLV ver=1 hdrLen=9`），只作兜底。
  ///
  /// # 每个档位都带 requestHeaders
  ///
  /// 见 [_streamHeaders]。**包括 [LiveStream.availableQualities] 里的每一条**，
  /// 因为切清晰度时会用那个对象的 url 重新 open。
  LiveStream? parseStream(Map<String, Object?> room) {
    final su = room['stream_url'];
    if (su is! Map) return null;
    final s = Map<String, Object?>.from(su);

    // 平台下发的档位名与档位序先取到：_qualityLabel / _qualityValue 会用。
    // **每次解析都重取**，不跨请求缓存（平台改了命名立刻生效）。
    _resolutionNames = _stringMap(s['resolution_name']);
    _qualityRanks = _readQualityRanks(s);
    final codec = _codecNameFor(s);
    final headers = _streamHeaders(s);

    final defaultRes = _str(s['default_resolution']) ?? 'FULL_HD1';

    // 1) HLS 映射表：feed 与 room/info 都可靠，因此排第一。
    final hlsMap = s['hls_pull_url_map'];
    if (hlsMap is Map) {
      final m = Map<String, Object?>.from(hlsMap);
      // 默认档优先，其余按**实测真实质量序**（SD2 高于 SD1）。
      final order = _sortedByRank(<String>[
        if (m.containsKey(defaultRes)) defaultRes,
        'FULL_HD1',
        'HD1',
        'SD2',
        'SD1',
      ]);
      for (final key in order) {
        final url = _str(m[key]);
        if (url != null && url.isNotEmpty) {
          return _hlsStream(url, key, m, defaultRes, codec, headers);
        }
      }
    }

    // 2) 单条 hls_pull_url：feed 里实测恒为空串，room/info 里非空。
    final hls = _str(s['hls_pull_url']);
    if (hls != null && hls.isNotEmpty) {
      return LiveStream(
        url: _normalizeScheme(hls),
        protocolName: 'http_hls',
        formatName: 'ts',
        codecName: _codecNameFor(s, tierKey: defaultRes),
        qualityLabel: _qualityLabel(defaultRes),
        qualityValue: _qualityValue(defaultRes),
        requestHeaders: headers,
      );
    }

    // 3) 顶层 flv_pull_url：feed 里实测恒为 {}，room/info 有 4 档。
    final flvMap = s['flv_pull_url'];
    if (flvMap is Map && flvMap.isNotEmpty) {
      final m = Map<String, Object?>.from(flvMap);
      final order = _sortedByRank(<String>[
        if (m.containsKey(defaultRes)) defaultRes,
        'FULL_HD1',
        'HD1',
        'SD2',
        'SD1',
      ]);
      for (final key in order) {
        final url = _str(m[key]);
        if (url != null && url.isNotEmpty) {
          return LiveStream(
            url: _normalizeScheme(url),
            protocolName: 'http_stream',
            formatName: 'flv',
            codecName: _codecNameFor(s, tierKey: key),
            qualityLabel: _qualityLabel(key),
            qualityValue: _qualityValue(key),
            requestHeaders: headers,
          );
        }
      }
    }

    // 4) live_core_sdk_data 里的真实 FLV（feed 唯一有 FLV 的地方）。
    //    这个 stream_data 是**被字符串化的 JSON**，必须二次 decode。
    final sdkFlv = _sdkFlvStreams(s);
    if (sdkFlv.isNotEmpty) {
      final order = _sortedByRank(sdkFlv.keys.toList());
      final chosenKey = order.first;
      final chosen = LiveStream(
        url: _normalizeScheme(sdkFlv[chosenKey]!),
        protocolName: 'http_stream',
        formatName: 'flv',
        codecName: _codecNameFor(s, tierKey: chosenKey),
        qualityLabel: _qualityLabel(chosenKey),
        qualityValue: _qualityValue(chosenKey),
        requestHeaders: headers,
      );
      return LiveStream(
        url: chosen.url,
        protocolName: chosen.protocolName,
        formatName: chosen.formatName,
        codecName: chosen.codecName,
        qualityLabel: chosen.qualityLabel,
        qualityValue: chosen.qualityValue,
        requestHeaders: chosen.requestHeaders,
        availableQualities: [
          for (final k in order.skip(1))
            if (k.isNotEmpty)
              LiveStream(
                url: _normalizeScheme(sdkFlv[k]!),
                protocolName: 'http_stream',
                formatName: 'flv',
                codecName: _codecNameFor(s, tierKey: k),
                qualityLabel: _qualityLabel(k),
                qualityValue: _qualityValue(k),
                requestHeaders: headers,
              ),
        ],
      );
    }

    return null;
  }

  /// HLS：主档 + 其余全部档位列进 `availableQualities`。
  ///
  /// [codecName] 与 [headers] 由 [parseStream] 显式传入 —— helper 内部
  /// **不重新推导**编码：它拿不到调用方的局部变量，自己推导只会和主档
  /// 不一致（这里踩过一次作用域编译错误）。
  ///
  /// **保留全部档位、不做自动降级**：抖音直播主档实测是 HEVC，部分
  /// Android 设备（尤其 x86 模拟器与低端机）可能缺 HEVC 硬解。本项目
  /// 没有设备解码能力探测接口，因此不擅自替用户选档 —— 把全部档位连同
  /// 各自的 `codecName` 一起交给上层，由用户在清晰度菜单里自己挑
  /// （实测唯一 H.264 档是 `live_core_sdk_data` 的 `md` 档）。
  LiveStream _hlsStream(
    String url,
    String chosenKey,
    Map<String, Object?> map,
    String defaultRes,
    String codecName,
    Map<String, String> headers,
  ) {
    // 收集其它清晰度作为可选项（**同一 codecName**：实测 HLS 的
    // FULL_HD1/HD1/SD1/SD2 四档 v_codec 100% 是 bytevc1，没有混合编码；
    // 唯一 H.264 档在 live_core_sdk_data 的 md，走的是 FLV 分支）。
    // 每一条都带同一组请求头，否则用户一切档就变成"原画能播、标清黑屏"。
    final others = <LiveStream>[];
    for (final entry in _sortedByRank(map.keys.toList())) {
      final u = _str(map[entry]);
      if (u == null || u.isEmpty || entry == chosenKey) continue;
      others.add(
        LiveStream(
          url: _normalizeScheme(u),
          protocolName: 'http_hls',
          formatName: 'ts',
          codecName: codecName,
          qualityLabel: _qualityLabel(entry),
          qualityValue: _qualityValue(entry),
          requestHeaders: headers,
        ),
      );
    }

    return LiveStream(
      url: _normalizeScheme(url),
      protocolName: 'http_hls',
      formatName: 'ts',
      codecName: codecName,
      qualityLabel: _qualityLabel(chosenKey),
      qualityValue: _qualityValue(chosenKey),
      availableQualities: others,
      requestHeaders: headers,
    );
  }

  /// 拉这条流必须带的请求头（**平台知识，由适配器随流下发**）。
  ///
  /// # 为什么这是必修项
  ///
  /// 实测：同一条分片地址，带 App 形态 UA 打是 `HTTP 206` + 完整 TS；
  /// libmpv 的默认 UA 在**部分** douyincdn 节点会拿到
  /// `HTTP 200 + 空 body` —— 地址有效、播放器初始化成功、
  /// 不报错，但**没有画面**。也就是说"黑屏"并不一定是解码问题
  /// （模拟器 Android 15 有 `c2.goldfish.hevc.decoder` +
  /// `OMX.google.hevc.decoder`，ffmpeg 对真实 HEVC 分片能完整解码出
  /// 非黑帧），而是**请求头**。
  ///
  /// 这组头是平台知识，必须由适配器随流一起给出。本项目的关键约束是
  /// **UI 层零平台分支**：若让直播间页面按 `adapter.id` 自己拼 UA/Referer，
  /// 就多一处平台判断，且每接一个平台都要改一次页面。
  ///
  /// [LiveStream.requestHeaders] 为空时消费方会退化成"只带 Referer"，
  /// 对抖音来说那就是继续黑屏。
  Map<String, String> _streamHeaders(Map<String, Object?> streamUrl) {
    // 抖音 CDN 校验 Referer 是否为直播域名；UA 用 App 形态（与取 feed
    // 同一身份，实测可用）。不携带任何 Cookie / 令牌。
    return const {
      'User-Agent': _userAgent,
      'Referer': _referer,
    };
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

  /// 档位展示名。
  ///
  /// 不是 static：要先读实例字段 [_resolutionNames]（平台本次下发的名字）。
  ///
  /// **只用于展示，绝不用于排序** —— 实测平台命名与实际质量不单调对应
  /// （SD2「高清」比 SD1「标清」更高），排序一律走 [_qualityValue]。
  String _qualityLabel(String key) {
    // 档位展示名**直接采用平台自己下发的 `stream_url.resolution_name`**
    // （实测 12/12 房间下发：
    //   FULL_HD1=蓝光  HD1=超清  ORIGION=原画  SD1=标清  SD2=高清）。
    //
    // 旧实现是手写表（FULL_HD1→原画、HD1→高清、SD2→流畅），
    // 与平台命名不一致，其中 3 档标错 —— 用户在切换菜单上看到的
    // 名字和 B 站/抖音官方客户端不同，会误判画质档位。
    // 因此：优先用接口下发的名字（见 [_resolutionNames]），
    // 下面的表只是**兜底**，且按平台实测命名校正。
    return _resolutionNames[key] ?? switch (key) {
        'FULL_HD1' => '蓝光',
        'HD1' => '超清',
        'ORIGION' || 'ORIGIN' => '原画',
        'SD1' => '标清',
        'SD2' => '高清',
        _ => key,
      };
  }

  /// 把平台响应里的字符串映射（如 `resolution_name`）安全转成
  /// `Map<String, String>`。
  ///
  /// 不用 `as Map<String, String>` 直接 cast：JSON 解码出来的是
  /// `Map<String, dynamic>`，cast 会抛 TypeError；而且值可能混入数字。
  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    for (final e in raw.entries) {
      final k = e.key;
      final v = e.value;
      if (k is! String || v == null) continue;
      out[k] = '$v';
    }
    return out;
  }

  /// 从 `stream_url` 推断某一档的**实际编码**（`'hevc'` / `'avc'`）。
  ///
  /// [tierKey] 可以是档位名（`FULL_HD1`/`HD1`/`SD1`/`SD2`/`ORIGION`）
  /// 或 sdk_key（`uhd`/`hd`/`sd`/`ld`/`origin`/`md`/`xuhd`）；
  /// 传 null 时按"该房间的主档"判定。
  ///
  /// # 实测依据（2026-10-19，本地探针真实拉流）
  ///
  ///  - `stream_url.live_core_sdk_data.pull_data.options.qualities[]`
  ///    每档都带 `sdk_key` + `v_codec`，实测 6/6 房间全部是
  ///    `v_codec=bytevc1`（字节的 HEVC 变体）→ **这是主判据**。
  ///  - 拉 TS 分片解 PMT 印证：`stream_type=0x24` = H.265/HEVC，
  ///    音频 `0x0F` = AAC。
  ///  - 唯一 H.264 档是 `stream_data` 里的 **`md`**（360x640 / h264 High）；
  ///    **没有 `ulls_h264` 这个 key**（6 房间全部档位都没找到，别去找它）。
  ///
  /// # 一个会把 HEVC 误标成 AVC 的坑
  ///
  /// 实测 `stream_url.extra.h265_enable = false`、`extra.bytevc1_enable = false`、
  /// `extra.video_profile = 0`，**而流确实是 HEVC**。这几个字段描述的是
  /// 推流侧的能力协商结果，不是当前这路流的编码，因此**不能**当判据。
  /// 早期实现按它们判断会把真实的 HEVC 标成 `avc`，反而误导解码能力。
  /// 只有当 `options.qualities` 完全拿不到时，才退化到读 `extra.*`，
  /// 且兜底一律给实测主档 `hevc`。
  String _codecNameFor(
    Map<String, Object?> streamUrl, {
    String? tierKey,
  }) {
    final sdkKey = tierKey == null ? null : _sdkKeyFor(tierKey);

    // 1) 主判据：options.qualities[*].v_codec（平台逐档声明）。
    for (final q in _qualities(streamUrl)) {
      final key = _str(q['sdk_key']);
      if (sdkKey != null && key != null && key != sdkKey) continue;
      final vc = '${q['v_codec']}'.toLowerCase();
      if (vc.isEmpty || vc == 'null') continue;
      if (vc.contains('bytevc') || vc.contains('hevc') || vc.contains('h265')) {
        return 'hevc';
      }
      if (vc.contains('avc') || vc.contains('h264')) return 'avc';
    }

    // 2) 次判据：stream_data.data[tier].main.sdk_params
    //    （形如 "v_codec=hevc,..." 的字符串，比 options 更贴近这条地址）。
    final params = _sdkParam(streamUrl, sdkKey);
    if (params != null) {
      final p = params.toLowerCase();
      if (p.contains('bytevc') || p.contains('hevc') || p.contains('h265')) {
        return 'hevc';
      }
      if (p.contains('avc') || p.contains('h264')) return 'avc';
    }

    // 3) md 档实测是唯一 H.264（低码率兼容档）。
    if (sdkKey == 'md') return 'avc';

    // 4) 退化路径：只有在 1)/2) 都拿不到时才看 extra（注意上面写的坑）。
    final extra = streamUrl['extra'] is Map
        ? Map<String, Object?>.from(streamUrl['extra'] as Map)
        : null;
    if (extra != null) {
      final profile = extra['video_profile'];
      if (profile is String) {
        final p = profile.toLowerCase();
        if (p.contains('hevc') || p.contains('h265') || p.contains('bytevc')) {
          return 'hevc';
        }
        if (p.contains('avc') || p.contains('h264')) return 'avc';
      }
    }

    // 5) 实测主档：抽样 6/6 房间的全部 HLS 档位都是 HEVC。
    return 'hevc';
  }

  /// `options.qualities` 数组，取不到返回空表。
  ///
  /// 注意路径是 `live_core_sdk_data.pull_data.options.qualities`，
  /// **不是** `stream_url.options`（实测 `stream_url` 顶层没有 `options` 键）。
  List<Map<String, Object?>> _qualities(Map<String, Object?> streamUrl) {
    final raw = _nested(streamUrl, [
      'live_core_sdk_data',
      'pull_data',
      'options',
      'qualities',
    ]);
    if (raw is! List) return const [];
    return [
      for (final q in raw)
        if (q is Map) Map<String, Object?>.from(q),
    ];
  }

  /// 某档在 `stream_data` 里的 `sdk_params` 字符串。
  String? _sdkParam(Map<String, Object?> streamUrl, String? sdkKey) {
    if (sdkKey == null) return null;
    final data = _sdkStreamData(streamUrl);
    final tier = data?[sdkKey];
    if (tier is! Map) return null;
    final main = tier['main'];
    if (main is! Map) return null;
    return _str(main['sdk_params']);
  }

  /// `live_core_sdk_data.pull_data.stream_data` —— **被字符串化的 JSON**。
  ///
  /// 实测 feed 12/12、room/info 同样是 string（len≈8.6 KB），
  /// 不解码就取不到里面的 `data.{origin,uhd,hd,sd,ld,md,xuhd}.main.{flv,hls,lls}`。
  /// 结构：`{common:{...}, data:{<sdk_key>:{main:{flv,hls,lls,...}, backup:{...}}}}`。
  Map<String, Object?>? _sdkStreamData(Map<String, Object?> streamUrl) {
    final raw = _nested(streamUrl, [
      'live_core_sdk_data',
      'pull_data',
      'stream_data',
    ]);
    if (raw is Map) return Map<String, Object?>.from(raw); // 容错：万一不是 string
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      return data is Map ? Map<String, Object?>.from(data) : null;
    } on FormatException {
      // 平台偶尔给截断/非 JSON：如实当作"没有该字段"，不猜。
      return null;
    }
  }

  /// 从 `stream_data` 里取出各档真实 FLV 地址（feed 里唯一有 FLV 的地方）。
  ///
  /// 返回的 key 一律**换算回档位名**（`uhd`→`FULL_HD1` 等），这样
  /// [_qualityLabel] 能命中 `resolution_name` 的平台命名；
  /// 换算不了的（`xuhd`/`md`）保留 sdk_key。
  ///
  /// 两个实测取舍：
  ///  - **剔除 `ao`**：实测是纯音频档（audio only），拿它当"可播视频清晰度"
  ///    会让用户点开后只有声音，与图文帖混发是同一类黑屏。
  ///  - 平台在 `options.qualities` 里给 `disable:1` 的档也剔除。
  Map<String, String> _sdkFlvStreams(Map<String, Object?> streamUrl) {
    final data = _sdkStreamData(streamUrl);
    if (data == null) return const {};

    final disabled = <String>{
      for (final q in _qualities(streamUrl))
        if (_int(q['disable']) != null && _int(q['disable']) != 0)
          _str(q['sdk_key']) ?? '',
    };

    final out = <String, String>{};
    for (final entry in data.entries) {
      final sdkKey = entry.key;
      if (sdkKey == 'ao' || disabled.contains(sdkKey)) continue;
      if (entry.value is! Map) continue;
      final tier = Map<String, Object?>.from(entry.value as Map);
      final main = tier['main'] is Map
          ? Map<String, Object?>.from(tier['main'] as Map)
          : const <String, Object?>{};
      final url = _str(main['flv']);
      if (url == null || url.isEmpty) continue;
      out[_resolutionNameForSdkKey(sdkKey)] = url;
    }
    return out;
  }

  /// 档位名 → sdk_key（实测 6 房间映射稳定）。
  ///
  /// 已知 `FULL_HD1→uhd  HD1→hd  SD2→sd  SD1→ld  ORIGION→origin`。
  /// 传入本来就是 sdk_key 时原样返回。
  static String _sdkKeyFor(String tier) {
    return switch (tier) {
      'FULL_HD1' => 'uhd',
      'HD1' => 'hd',
      'SD2' => 'sd',
      'SD1' => 'ld',
      'ORIGION' || 'ORIGIN' => 'origin',
      _ => tier,
    };
  }

  /// sdk_key → 档位名（上面那张表的反向；认不出就原样返回）。
  static String _resolutionNameForSdkKey(String sdkKey) {
    return switch (sdkKey) {
      'uhd' => 'FULL_HD1',
      'hd' => 'HD1',
      'sd' => 'SD2',
      'ld' => 'SD1',
      'origin' => 'ORIGION',
      _ => sdkKey,
    };
  }

  /// 平台本次下发的档位**真实质量序**（由 `options.qualities` 的
  /// `level` + `v_bit_rate` 推出来，key 同时收录 sdk_key 与档位名两种写法）。
  ///
  /// 为什么不让代码去猜档位名的顺序：
  ///
  /// ```
  /// 实测 options.qualities（6 房间一致）：
  ///   ld  level=1 v_bit_rate=1000000  name=标清  resolution=960x540
  ///   sd  level=2 v_bit_rate=3000000  name=高清  resolution=1280x720~1920x1080
  ///   hd  level=3 v_bit_rate=4000000  name=超清
  ///   uhd level=4 v_bit_rate=6015000~19792896 name=蓝光 60fps
  ///   xuhd level=7 name=蓝光帧彩
  ///
  /// 换成 hls_pull_url_map 的档位名就是：
  ///   FULL_HD1(uhd) > HD1(hd) > SD2(sd) > SD1(ld)
  /// ```
  ///
  /// 也就是说**「SD2 高清」高于「SD1 标清」**，档位名里的数字顺序与真实
  /// 质量是反的。旧实现按 `FULL_HD1 > HD1 > SD1 > SD2` 排，默认档缺失时
  /// 会选中真实质量最差的那一路；兜底数值也把 SD1 排到了 SD2 前面。
  /// 结论：**名字只能当展示，排序必须用平台给的 level/bit_rate。**
  Map<String, int> _qualityRanks = const {};

  /// 本次响应里平台下发的档位名映射（`stream_url.resolution_name`）。
  ///
  /// 为什么用实例字段而不是每次传参：`parseStream` 的调用方
  /// （适配器）只关心结果，多一层参数会让签名变脏。这里在解析
  /// `stream_url` 时先填好，[_qualityLabel] 直接读。
  ///
  /// **只在同一次解析内有效**，不跨请求缓存 —— 平台改了命名也能立刻生效。
  /// [_qualityRanks] 同理，每次 [parseStream] 都重取。
  Map<String, String> _resolutionNames = const {};

  /// 从 `options.qualities` 读出真实质量序。
  ///
  /// 分值 = `level * 100000000 + v_bit_rate`，level 相等时用码率决胜，
  /// 保证「数值大 = 更清晰」这个契约在任何档位命名下都成立。
  Map<String, int> _readQualityRanks(Map<String, Object?> streamUrl) {
    final out = <String, int>{};
    for (final q in _qualities(streamUrl)) {
      final sdkKey = _str(q['sdk_key']);
      if (sdkKey == null) continue;
      final level = _int(q['level']) ?? 0;
      final bitRate = _int(q['v_bit_rate']) ?? 0;
      final score = level * 100000000 + bitRate;
      if (score <= 0) continue;
      out[sdkKey] = score;
      out[_resolutionNameForSdkKey(sdkKey)] = score;
    }
    return out;
  }

  /// 清晰度**排序值**（越大越清晰）。
  ///
  /// 优先用平台本次下发的 `level`/`v_bit_rate`（[_qualityRanks]），
  /// 拿不到才用按实测校准过的兜底表。兜底表的关键点是
  /// **SD2 高于 SD1**，与档位名的字面顺序相反。
  int _qualityValue(String key) {
    final rank = _qualityRanks[key] ?? _qualityRanks[_sdkKeyFor(key)];
    if (rank != null) return rank;
    return switch (key) {
      'FULL_HD1' => 4000,
      'HD1' => 3000,
      // 实测 SD2（高清，level 2 / 3 Mbps）> SD1（标清，level 1 / 1 Mbps）。
      'SD2' => 2000,
      'SD1' => 1000,
      // 原画：平台把它单列在 resolution_name 里，但通常不在
      // options.qualities 中；按语义插在 HD1 与 SD2 之间。
      'ORIGION' || 'ORIGIN' => 2500,
      _ => 0,
    };
  }

  /// 按真实质量序（从大到小）稳定排序档位 key。
  ///
  /// 稳定：同分值保持传入顺序，因此调用方写在最前面的
  /// "`default_resolution`" 永远优先于任何分值。
  List<String> _sortedByRank(List<String> keys) {
    final indexed = <List<Object>>[
      for (var i = 0; i < keys.length; i++) [keys[i], i],
    ];
    indexed.sort((a, b) {
      final byScore = _qualityValue(a[0] as String)
          .compareTo(_qualityValue(b[0] as String));
      if (byScore != 0) return -byScore; // 降序
      return (a[1] as int).compareTo(b[1] as int); // 稳定
    });
    return [for (final e in indexed) e[0] as String];
  }



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
