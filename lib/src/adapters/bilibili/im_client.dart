/// B站私信（IM）HTTP 客户端。
///
/// # 为什么单独一个客户端
///
/// 私信不在 `api.bilibili.com`，而在 **`api.vc.bilibili.com`**，
/// 且请求要带 `Referer/Origin: https://message.bilibili.com/`。
/// 混进主适配器会让"哪个 host 该带什么头"变得含混，所以独立成类。
///
/// # 端点全部实测（2026-10-19，B站 8.91.1）
///
/// | 用途 | 端点 | 实测 |
/// |---|---|---|
/// | 会话列表 | `GET /session_svr/v1/session_svr/get_sessions` | code=0，20 条/页，`has_more` |
/// | 历史消息 | `GET /svr_sync/v1/svr_sync/fetch_session_msgs` | code=0，**降序（新→旧）** |
/// | 发送消息 | `POST /web_im/v1/web_im/send_msg` | 缺 csrf → -111；空内容 → -400；自聊 → 21026 |
/// | 未读汇总 | `GET /session_svr/v1/session_svr/single_unread` | code=0，8 个字段 |
/// | 用户信息 | `GET /x/im/user_infos?uids=` | code=0，字段是 `mid/name/face` |
/// | 标记已读 | `POST /session_svr/v1/session_svr/update_ack` | code=0 |
///
/// **两个容易踩的坑**（都是实测出来的）：
///  1. 历史消息的路径是 `svr_sync`（**下划线**），写成 `svr-sync`（连字符）
///     会返回 404 HTML。
///  2. `x/im/user_infos` 的字段是 `mid` / `name` / `face`，
///     不是 `uid` / `nick`。按直觉解析会全部拿到 null。
///
/// # 关于"实时"
///
/// 没有接入 WebSocket/长轮询：`svr_sync/v1/svr-sync/interface` 实测 404，
/// 且前端 bundle 里的 `session_svr/v1/out_queue` 属于需要额外握手的通道，
/// 未验证。因此本客户端**只提供拉取式接口**，实时性由 UI 的有频率限制
/// 的增量刷新承担，并在页面上如实说明"非实时推送"。
library;

import 'dart:convert';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';
import '../../models/im.dart';

/// B站私信客户端。
class BilibiliImClient {
  BilibiliImClient({
    required FusionHttpClient http,
    required this.platformId,
    FusionLogger? logger,
  })  : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final String platformId;
  final FusionLogger _logger;

  /// IM 专用 host（与主 API 不同）。
  static const String _imBase = 'https://api.vc.bilibili.com';

  /// IM 请求必须带这个来源，否则部分接口返回 404/风控。
  static const String _referer = 'https://message.bilibili.com/';

  Map<String, String> _headers(PlatformSession session) => {
        'Referer': _referer,
        'Origin': 'https://message.bilibili.com',
        'Cookie': session.cookieHeader,
        'Accept': 'application/json, text/plain, */*',
      };

  /// CSRF（B站用 `bili_jct`）。写操作必须带。
  String _csrf(PlatformSession session) => session.cookies['bili_jct'] ?? '';

  /// 统一的响应处理：把平台的登录/CSRF/参数错误映射成明确错误码。
  ///
  /// **不把"失败"伪装成"空数据"**：调用方必须能区分
  /// "真的没有会话"与"登录失效/请求失败"。
  Map<String, Object?> _unwrap(
    Map<String, Object?> json, {
    required String endpoint,
    PlatformSession? session,
  }) {
    final code = json['code'];
    if (code == 0) return json;
    final message = (json['message'] as String?) ?? '';

    if (code == -101) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '登录状态已失效，请重新登录后查看私信。',
        technicalMessage: '$endpoint returned -101',
        upstreamCode: code,
        platformId: platformId,
      );
    }

    // ⚠️ 实测的重要差异（2026-10-19）：
    //   完全无 Cookie      → -101「账号未登录」
    //   空 SESSDATA        → -101
    //   **伪造/失效 SESSDATA → -400「请求错误」**  ← 不是 -101！
    //   有效 Cookie        → code=0
    //
    // 所以"带了 SESSDATA 却收到 -400"必须提示重新登录，
    // 否则用户 Cookie 过期时只会看到"请求参数有误"这种误导文案。
    // 判据是"请求确实带了 SESSDATA"，不是猜错误码语义。
    if (code == -400 &&
        session != null &&
        (session.cookies['SESSDATA'] ?? '').isNotEmpty) {
      throw FusionException(
        code: FusionErrorCode.loginRequired,
        userMessage: '登录凭证已失效，请重新登录后再查看私信。',
        technicalMessage: '$endpoint returned -400 with SESSDATA present '
            '(实测：失效凭证在 IM 接口上表现为 -400 而非 -101)',
        upstreamCode: code,
        platformId: platformId,
      );
    }
    if (code == -111) {
      throw FusionException(
        code: FusionErrorCode.permissionDenied,
        userMessage: '操作凭证（csrf）无效，请重新登录。',
        technicalMessage: '$endpoint returned -111',
        upstreamCode: code,
        platformId: platformId,
      );
    }
    if (code == -400 || code == 2) {
      throw FusionException(
        code: FusionErrorCode.upstreamError,
        userMessage: '请求参数有误：${message.isEmpty ? '平台拒绝' : message}',
        technicalMessage: '$endpoint returned $code ($message)',
        upstreamCode: code,
        platformId: platformId,
      );
    }
    throw FusionException(
      code: FusionErrorCode.upstreamError,
      userMessage: message.isEmpty ? '私信请求失败，请稍后重试。' : message,
      technicalMessage: '$endpoint returned $code',
      upstreamCode: code,
      platformId: platformId,
    );
  }

  // ── 会话列表 ────────────────────────────────────────────────

  /// 拉一页会话。
  ///
  /// [endTs] 为上一页最后一条的 `session_ts`，首页传 0。
  /// 是否还有下一页看返回的 [ImSessionPage.hasMore]（服务端 `has_more`）。
  Future<ImSessionPage> fetchSessions({
    required PlatformSession session,
    int count = 20,
    int endTs = 0,
  }) async {
    const endpoint = '/session_svr/v1/session_svr/get_sessions';
    final url = '$_imBase$endpoint'
        '?session_type=1&group_id=0&count=$count&build=0&mobi_app=web'
        '&end_ts=$endTs';
    final result = await _http.get(
      url,
      headers: _headers(session),
      platformId: platformId,
    );
    final json = _unwrap(result.jsonObject(platformId: platformId), endpoint: endpoint, session: session);

    final data = json['data'];
    if (data is! Map) {
      return const ImSessionPage(items: [], hasMore: false);
    }
    final d = Map<String, Object?>.from(data);
    final rawList = d['session_list'];
    final items = <ImSession>[];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final parsed = _parseSession(Map<String, Object?>.from(raw));
        if (parsed != null) items.add(parsed);
      }
    }
    final lastTs = items.isEmpty ? 0 : items.last.sessionTs;
    return ImSessionPage(
      items: items,
      hasMore: d['has_more'] == 1 || d['has_more'] == true,
      nextEndTs: lastTs,
    );
  }

  ImSession? _parseSession(Map<String, Object?> m) {
    final talkerId = _toInt(m['talker_id']);
    if (talkerId == null) return null;

    final lastMsg = m['last_msg'] is Map
        ? Map<String, Object?>.from(m['last_msg'] as Map)
        : const <String, Object?>{};

    return ImSession(
      talkerId: talkerId,
      sessionType: _toInt(m['session_type']) ?? 1,
      unreadCount: _toInt(m['unread_count']) ?? 0,
      sessionTs: _toInt(m['session_ts']) ?? 0,
      ackSeqno: _toInt(m['ack_seqno']) ?? 0,
      maxSeqno: _toInt(m['max_seqno']) ?? 0,
      isTop: (_toInt(m['top_ts']) ?? 0) > 0,
      isFollow: m['is_follow'] == 1 || m['is_follow'] == true,
      isDnd: m['is_dnd'] == 1 || m['is_dnd'] == true,
      groupName: _str(m['group_name']),
      groupCoverUrl: _str(m['group_cover']),
      lastMsgType: _toInt(lastMsg['msg_type']),
      lastMsgTimestamp: _toInt(lastMsg['timestamp']) ?? 0,
      liveStatus: _toInt(m['live_status']) ?? 0,
      userLabel: m['user_label'],
    );
  }

  // ── 历史消息 ────────────────────────────────────────────────

  /// 拉一页历史消息。
  ///
  /// **服务端按新→旧返回**（实测时间戳单调递减），UI 需要自己反转成
  /// 正序显示。翻页时传上一页的 `minSeqno` 作为 [endSeqno]。
  Future<ImMessagePage> fetchMessages({
    required PlatformSession session,
    required int talkerId,
    int size = 20,
    int endSeqno = 0,
  }) async {
    const endpoint = '/svr_sync/v1/svr_sync/fetch_session_msgs';
    final url = '$_imBase$endpoint'
        '?talker_id=$talkerId&session_type=1&size=$size&build=0&mobi_app=web'
        '${endSeqno > 0 ? '&end_seqno=$endSeqno' : ''}';
    final result = await _http.get(
      url,
      headers: _headers(session),
      platformId: platformId,
    );
    final json = _unwrap(result.jsonObject(platformId: platformId), endpoint: endpoint, session: session);

    final data = json['data'];
    if (data is! Map) {
      return const ImMessagePage(items: [], hasMore: false);
    }
    final d = Map<String, Object?>.from(data);
    final rawList = d['messages'];
    final items = <ImMessage>[];
    if (rawList is List) {
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final parsed = _parseMessage(Map<String, Object?>.from(raw));
        if (parsed != null) items.add(parsed);
      }
    }
    return ImMessagePage(
      items: items,
      hasMore: d['has_more'] == 1 || d['has_more'] == true,
      minSeqno: _toInt(d['min_seqno']) ?? 0,
      maxSeqno: _toInt(d['max_seqno']) ?? 0,
    );
  }

  /// 解析一条消息。
  ///
  /// **任何字段缺失或 content 解析失败都不抛异常** —— 一条脏消息
  /// 不能让整个会话打不开。解析不出文本时 [ImMessage.text] 为 null，
  /// UI 显示"该消息类型暂不支持显示"。
  ImMessage? _parseMessage(Map<String, Object?> m) {
    final msgKey = _str(m['msg_key']);
    if (msgKey == null) return null;
    final msgType = _toInt(m['msg_type']) ?? 0;
    final content = _str(m['content']) ?? '';
    final text = extractText(msgType, content);

    return ImMessage(
      msgKey: msgKey,
      senderUid: _toInt(m['sender_uid']) ?? 0,
      receiverId: _toInt(m['receiver_id']) ?? 0,
      receiverType: _toInt(m['receiver_type']) ?? 1,
      msgType: msgType,
      timestamp: _toInt(m['timestamp']) ?? 0,
      content: content,
      msgSeqno: _toInt(m['msg_seqno']) ?? 0,
      msgStatus: _toInt(m['msg_status']) ?? 0,
      atUids: _str(m['at_uids']),
      notifyCode: _toInt(m['notify_code']),
      msgSource: _toInt(m['msg_source']),
      rawType: msgType,
      text: text,
      media: extractMedia(msgType, content),
      emojiShortcodes: extractEmojiShortcodes(text),
    );
  }

  /// 从 content JSON 里解析图片 / 表情 / 视频封面资产。
  ///
  /// 实测结构（见 [ImMedia] 文档）。解析失败返回 null（不抛）。
  ///
  /// # 为什么不用 `media ?? 占位`
  ///
  /// 返回 null 的语义是"这条消息确实没有媒体"或"平台没给可用的 URL"，
  /// 两种情况 UI 都显示"图片无法显示"，而不是渲染一个空框。
  /// **不会**用本地缓存图或随机图冒充。
  static ImMedia? extractMedia(int msgType, String content) {
    if (content.isEmpty) return null;
    final type = ImMessageType.fromRaw(msgType);
    if (!type.isImageBearing) return null;

    Object? decoded;
    try {
      decoded = _jsonDecode(content);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = Map<String, Object?>.from(decoded);

    // 图片/表情用 `url`；视频消息的封面用 `img`。
    final url = _firstNonEmpty([
      map['url'],
      map['img'],
      map['cover'],
      map['cover_url'],
    ]);
    if (url == null) return null;

    // 动图变体：只有平台确实下发才用。
    final animated = _firstNonEmpty([
      map['gif_url'],
      map['webp_url'],
      map['animation_url'],
    ]);

    return ImMedia(
      url: url,
      width: _toInt(map['width']) ?? _toInt(map['img_width']),
      height: _toInt(map['height']) ?? _toInt(map['img_height']),
      sizeBytes: _toInt(map['size']) ?? _toInt(map['img_size']),
      animatedUrl: animated,
      mimeType: _str(map['mime_type']),
    );
  }

  static String? _firstNonEmpty(List<Object?> candidates) {
    for (final c in candidates) {
      if (c is String && c.trim().isNotEmpty) return c;
    }
    return null;
  }

  /// 从 content JSON 里取可读文本。
  ///
  /// 实测结构：
  ///  - `1`/`18` → `{"content":"..."}`
  ///  - `10` → `{"title":..,"text":..,"jump_text":..,...}`
  ///  - `5`（撤回）→ 可能是 `{"content":"..."}` 或空；统一给撤回提示
  ///  - `2`（图片）/ `6`（自定义表情）/ `17`（视频）→ 没有文本
  ///
  /// 解析失败返回 null（不抛）。这是 static 且纯函数，便于单测。
  static String? extractText(int msgType, String content) {
    final type = ImMessageType.fromRaw(msgType);
    if (type == ImMessageType.withdraw) {
      // 撤回消息的正文是平台文案，但常为空；给一句稳定的本地文案
      // 比显示空白好，且**不伪造具体是谁撤回的**。
      return '这条消息已被撤回';
    }
    if (content.isEmpty) return null;
    Object? decoded;
    try {
      decoded = _jsonDecode(content);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = Map<String, Object?>.from(decoded);
    switch (type) {
      case ImMessageType.text:
        final c = map['content'];
        return c is String && c.trim().isNotEmpty ? c : null;
      case ImMessageType.systemCard:
        // 系统卡片：优先 text，退而用 title
        final t = map['text'];
        if (t is String && t.trim().isNotEmpty) return t;
        final title = map['title'];
        if (title is String && title.trim().isNotEmpty) return title;
        return null;
      case ImMessageType.shareCard:
        final t = map['title'] ?? map['text'];
        return t is String && t.trim().isNotEmpty ? t : null;
      case ImMessageType.image:
      case ImMessageType.customEmoji:
      case ImMessageType.video:
      case ImMessageType.withdraw:
      case ImMessageType.unknown:
        return null;
    }
  }

  // ── 发送 ────────────────────────────────────────────────────

  /// 发送一条文本消息。
  ///
  /// # 成功判据
  ///
  /// **只有 `code == 0` 且服务端回了 `msg_key` 才算成功**。
  /// 实测反例（都必须如实落到失败）：
  ///  - 缺 csrf → `-111 CSRF 校验失败`
  ///  - 空内容 → `-400 请求错误`
  ///  - 发给自己 → `21026 不能给自己发送消息哦~`
  ///
  /// `dev_id` 实测传 `"0"` 可被接受（平台未强制要求真实设备号）。
  Future<ImSendResult> sendMessage({
    required PlatformSession session,
    required int talkerId,
    required String content,
    int msgType = 1,
  }) async {
    // 文本消息的 content 是 {"content": "..."}。
    // 图片/表情消息的 content 结构完全不同（见 sendMediaMessage），
    // 所以这条路径只处理文本，避免"改个 msg_type 就当图片发"的错误做法。
    if (msgType != 1) {
      throw FusionException(
        code: FusionErrorCode.internalError,
        userMessage: '发送失败：消息类型与内容不匹配。',
        technicalMessage: 'sendMessage() only supports msg_type=1, '
            'got $msgType; use sendMediaMessage() for media',
        platformId: platformId,
      );
    }
    return _send(
      session: session,
      talkerId: talkerId,
      msgType: msgType,
      contentJson: _jsonEncode({'content': content.trim()}),
    );
  }

  /// 发送图片消息（`msg_type=2`）。
  ///
  /// [media] 必须来自 [BilibiliImUploadClient.uploadImage] 的真实返回。
  /// **不接受本地路径**：本地路径不是远端地址，直接塞进消息体是错的。
  Future<ImSendResult> sendImageMessage({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      _send(
        session: session,
        talkerId: talkerId,
        msgType: 2,
        contentJson: _jsonEncode({
          'url': media.url,
          if (media.width != null) 'width': media.width,
          if (media.height != null) 'height': media.height,
          if (media.sizeBytes != null) 'size': media.sizeBytes,
          'imageType': 1,
          'original': 1,
        }),
      );

  /// 发送自定义表情（`msg_type=6`，`FAV_EMOJI`）。
  ///
  /// # 与图片的差别
  ///
  /// 表情也是图片形态，但 `msg_type` 不同（6 vs 2），
  /// 接收端据此决定渲染尺寸与语义。
  ///
  /// # 实测边界
  ///
  /// 平台对"自定义表情"的发送**可能要求该表情已在你的收藏里**
  /// （`FAV_EMOJI` 的语义是"收藏的表情"）。本项目没有验证这一点，
  /// 因此这里只提供协议能力，UI 侧目前**不暴露"发送自定义表情"按钮**，
  /// 只做接收侧渲染。这一点在报告里如实标注。
  Future<ImSendResult> sendCustomEmojiMessage({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      _send(
        session: session,
        talkerId: talkerId,
        msgType: 6,
        contentJson: _jsonEncode({
          'url': media.url,
          if (media.width != null) 'width': media.width,
          if (media.height != null) 'height': media.height,
          if (media.sizeBytes != null) 'size': media.sizeBytes,
          'imageType': 1,
        }),
      );

  /// 发送的公共实现：拼表单、判成功、映射错误。
  Future<ImSendResult> _send({
    required PlatformSession session,
    required int talkerId,
    required int msgType,
    required String contentJson,
  }) async {
    const endpoint = '/web_im/v1/web_im/send_msg';

    final body = <String, String>{
      'msg[sender_uid]': session.userId,
      'msg[receiver_id]': '$talkerId',
      'msg[receiver_type]': '1',
      'msg[msg_type]': '$msgType',
      'msg[msg_status]': '0',
      'msg[content]': contentJson,
      'msg[timestamp]': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'msg[dev_id]': '0',
      'csrf': _csrf(session),
    };

    final result = await _http.post(
      '$_imBase$endpoint',
      headers: _headers(session),
      body: body.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'),
      platformId: platformId,
    );
    final json = result.jsonObject(platformId: platformId);
    final code = json['code'];
    final message = _str(json['message']);

    if (code == 0) {
      final data = json['data'];
      final d = data is Map ? Map<String, Object?>.from(data) : const <String, Object?>{};
      final key = d['msg_key'];
      // 有些平台版本 code=0 但 data 为 null —— 这种情况不能算"确认成功"
      if (key == null) {
        _logger.warn('im send: code=0 but no msg_key', {
          'endpoint': endpoint,
          'msg_type': msgType,
        });
        return ImSendResult(
          accepted: false,
          upstreamCode: code,
          message: '平台未返回消息 ID，无法确认发送成功。',
        );
      }
      return ImSendResult(
        accepted: true,
        msgKey: '$key',
        msgContent: _str(d['msg_content']),
        upstreamCode: code,
        message: message,
      );
    }

    // 业务失败：交给 _unwrap 抛出带正确错误码的异常
    _unwrap(json, endpoint: endpoint, session: session);
    // 理论不可达
    return ImSendResult(accepted: false, upstreamCode: code, message: message);
  }

  // ── 未读 ────────────────────────────────────────────────────

  /// 拉未读汇总（入口红点用）。
  Future<ImUnread> fetchUnread({required PlatformSession session}) async {
    const endpoint = '/session_svr/v1/session_svr/single_unread';
    final result = await _http.get(
      '$_imBase$endpoint'
      '?unread_type=0&show_unfollow_list=0&build=0&mobi_app=web',
      headers: _headers(session),
      platformId: platformId,
    );
    final json = _unwrap(result.jsonObject(platformId: platformId), endpoint: endpoint, session: session);
    final data = json['data'];
    if (data is! Map) return const ImUnread();
    final d = Map<String, Object?>.from(data);
    return ImUnread(
      unfollowUnread: _toInt(d['unfollow_unread']) ?? 0,
      followUnread: _toInt(d['follow_unread']) ?? 0,
      bizMsgUnfollowUnread: _toInt(d['biz_msg_unfollow_unread']) ?? 0,
      bizMsgFollowUnread: _toInt(d['biz_msg_follow_unread']) ?? 0,
      dustbinUnread: _toInt(d['dustbin_unread']) ?? 0,
      customUnread: _toInt(d['custom_unread']) ?? 0,
    );
  }

  // ── 用户信息 ────────────────────────────────────────────────

  /// 批量取用户信息（昵称/头像）。
  ///
  /// 注意字段名是 **`mid` / `name` / `face`**（实测），不是 `uid`/`nick`。
  Future<Map<int, ImUserInfo>> fetchUserInfos({
    required PlatformSession session,
    required List<int> uids,
  }) async {
    if (uids.isEmpty) return const {};
    const endpoint = '/x/im/user_infos';
    final result = await _http.get(
      '$_imBase$endpoint?uids=${uids.join(',')}',
      headers: _headers(session),
      platformId: platformId,
    );
    final json = _unwrap(result.jsonObject(platformId: platformId), endpoint: endpoint, session: session);
    final data = json['data'];
    if (data is! List) return const {};
    final out = <int, ImUserInfo>{};
    for (final raw in data) {
      if (raw is! Map) continue;
      final m = Map<String, Object?>.from(raw);
      final mid = _toInt(m['mid']);
      if (mid == null) continue;
      out[mid] = ImUserInfo(
        mid: mid,
        name: _str(m['name']),
        faceUrl: _str(m['face']),
        sign: _str(m['sign']),
        level: _toInt(m['level']),
      );
    }
    return out;
  }

  // ── 标记已读 ────────────────────────────────────────────────

  /// 把某个会话标记为已读。
  ///
  /// 实测：`POST update_ack`，参数 `talker_id` / `session_type` /
  /// `ack_seqno` / `csrf` → `code=0`。
  ///
  /// **只在用户真正打开会话、且拉到最新消息后调用** ——
  /// 不能"进了消息页就把全部会话标记已读"。
  Future<bool> markRead({
    required PlatformSession session,
    required int talkerId,
    required int ackSeqno,
  }) async {
    const endpoint = '/session_svr/v1/session_svr/update_ack';
    final result = await _http.post(
      '$_imBase$endpoint',
      headers: _headers(session),
      body: 'talker_id=$talkerId&session_type=1&ack_seqno=$ackSeqno'
          '&csrf=${Uri.encodeQueryComponent(_csrf(session))}',
      platformId: platformId,
    );
    final json = _unwrap(result.jsonObject(platformId: platformId), endpoint: endpoint, session: session);
    return json['code'] == 0;
  }

  // ── 小工具 ──────────────────────────────────────────────────

  static int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String? _str(Object? v) {
    if (v is String) return v;
    if (v == null) return null;
    return '$v';
  }

  static Object? _jsonDecode(String s) => json.decode(s);

  static String _jsonEncode(Object? o) => json.encode(o);
}