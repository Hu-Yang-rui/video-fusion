/// 私信状态仓库：会话列表、消息列表、发送、未读的**唯一真相**。
///
/// # 为什么要有这一层
///
/// 私信有两个页面（会话列表 / 聊天详情）都要读同一份数据：
///  - 会话列表要显示"最后一条消息 + 未读数"
///  - 聊天页要显示消息流，并在发送后更新列表
///
/// 如果两页各自拉各自缓存，必然出现"聊天页已读、列表还红着"、
/// "发了消息、列表最后一条还是旧的"这类串线。所以统一到这里。
///
/// # 关键约束（对应需求 3.3）
///
///  1. **去重靠 msgKey**：翻页时服务端不保证不重叠，按 key 去重。
///  2. **排序按服务端时间**：接口返回新→旧，这里统一反转成正序存，
///     避免每个页面各自 reverse 出不同结果。
///  3. **发送状态只认服务端**：本地先插一条 `sending`，成功后用服务端
///     返回的 msgKey 替换；失败标 `failed` 并保留重试入口。
///  4. **不自动全部已读**：只有用户真正打开某个会话、且拿到最新消息后，
///     才对**那一个**会话调 `markImSessionRead`。
///  5. **刷新有节流**：避免高频轮询打爆接口（实测连发会触发风控）。
///  6. **竞态防护**：每个会话一个代际号，旧响应回来时若已切换会话则丢弃。
library;

import 'package:flutter/foundation.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../models/im.dart';

/// 单个会话的消息流状态。
class ImChatState {
  ImChatState({required this.talkerId});

  final int talkerId;

  /// 按时间**正序**（旧→新）存放。服务端给的是倒序，入库时反转。
  final List<ImMessage> _messages = [];

  List<ImMessage> get messages => List.unmodifiable(_messages);

  bool loading = false;
  bool loadingMore = false;
  bool hasMore = true;
  int minSeqno = 0;
  int maxSeqno = 0;
  FusionException? error;
  bool loadedOnce = false;

  /// 代际号：切换会话 / 重新加载时递增，用于丢弃旧响应。
  int generation = 0;

  /// 已按 key 索引，去重 O(1)。
  final Set<String> _keys = {};

  /// 追加一页（服务端倒序），内部转正序并去重。
  ///
  /// 返回实际新增条数（0 表示全是重复）。
  int mergePage(ImMessagePage page) {
    var added = 0;
    // 服务端新→旧，反转后逐条插入到合适位置
    for (final m in page.items.reversed) {
      if (_keys.add(m.msgKey)) {
        _messages.add(m);
        added++;
      }
    }
    // 保证整体按时间正序（同一时间戳保持插入顺序）
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (page.minSeqno > 0) {
      minSeqno = minSeqno == 0 ? page.minSeqno : (page.minSeqno < minSeqno ? page.minSeqno : minSeqno);
    }
    if (page.maxSeqno > maxSeqno) maxSeqno = page.maxSeqno;
    hasMore = page.hasMore;
    loadedOnce = true;
    return added;
  }

  /// 插入一条本地"发送中"的消息（临时 key）。
  void addLocal(ImMessage msg) {
    if (_keys.add(msg.msgKey)) {
      _messages.add(msg);
      _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }
  }

  /// 用服务端确认结果替换本地临时消息。
  void confirmLocal(String localKey, ImMessage confirmed) {
    final i = _messages.indexWhere((m) => m.msgKey == localKey);
    if (i < 0) return;
    _keys.remove(localKey);
    _keys.add(confirmed.msgKey);
    _messages[i] = confirmed;
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// 标记某条本地消息失败。
  void failLocal(String localKey, String error) {
    final i = _messages.indexWhere((m) => m.msgKey == localKey);
    if (i < 0) return;
    _messages[i] = _messages[i].copyWith(
      sendState: ImSendState.failed,
      localError: error,
    );
  }

  void removeLocal(String localKey) {
    _messages.removeWhere((m) => m.msgKey == localKey);
    _keys.remove(localKey);
  }

  /// 取最后一条消息（用于更新会话列表摘要）。
  ImMessage? get lastMessage => _messages.isEmpty ? null : _messages.last;
}

/// 私信仓库。
class ImStore extends ChangeNotifier {
  ImStore({
    required VideoService service,
    required CredentialVault vault,
  })  : _service = service,
        _vault = vault;

  final VideoService _service;
  final CredentialVault _vault;

  // ── 会话列表 ────────────────────────────────────────────────

  final List<ImSession> _sessions = [];
  List<ImSession> get sessions => List.unmodifiable(_sessions);

  /// 用户信息缓存（昵称/头像），避免每帧都请求。
  final Map<int, ImUserInfo> _userInfos = {};
  ImUserInfo? userInfoOf(int talkerId) => _userInfos[talkerId];

  bool sessionsLoading = false;
  bool sessionsLoadingMore = false;
  bool sessionsHasMore = true;
  int _nextEndTs = 0;
  FusionException? sessionsError;
  bool sessionsLoadedOnce = false;

  ImUnread unread = const ImUnread();

  /// 当前使用的平台（B站）。
  String platformId = 'bilibili';

  PlatformSession? _session;
  PlatformSession? get session => _session;
  bool get isLoggedIn => _session != null;

  /// 我的 uid（判断消息是不是我发的）。
  int get myUid => int.tryParse(_session?.userId ?? '') ?? 0;

  // ── 每个会话的消息流 ────────────────────────────────────────

  final Map<int, ImChatState> _chats = {};
  ImChatState chatOf(int talkerId) =>
      _chats.putIfAbsent(talkerId, () => ImChatState(talkerId: talkerId));

  // ── 节流 ────────────────────────────────────────────────────

  DateTime? _lastSessionsRefresh;
  static const Duration _minRefreshInterval = Duration(seconds: 5);

  /// 会话列表是否需要刷新（节流用）。
  bool get canRefreshNow {
    final t = _lastSessionsRefresh;
    if (t == null) return true;
    return DateTime.now().difference(t) >= _minRefreshInterval;
  }

  // ── 初始化 ──────────────────────────────────────────────────

  /// 读取登录态。返回 false 表示未登录（UI 显示登录入口）。
  Future<bool> init() async {
    try {
      _session = await _vault
          .load(platformId)
          .timeout(const Duration(seconds: 5));
      debugPrint(
        '[im] init platform=$platformId '
        'session=${_session == null ? "null" : "uid=${_session!.userId}"}',
      );
    } catch (e) {
      debugPrint('[im] init failed: $e');
      _session = null;
    }
    notifyListeners();
    return _session != null;
  }

  /// 登录态变化后重新读取（从设置页导入 Cookie 回来时调用）。
  Future<void> reloadSession() async {
    final before = _session?.userId;
    await init();
    if (_session?.userId != before) {
      _sessions.clear();
      _chats.clear();
      _userInfos.clear();
      sessionsLoadedOnce = false;
      _nextEndTs = 0;
      sessionsHasMore = true;
      notifyListeners();
    }
  }

  // ── 会话列表加载 ────────────────────────────────────────────

  /// 拉会话列表。[refresh] 为 true 时从第一页重新拉。
  Future<void> loadSessions({bool refresh = false}) async {
    final s = _session;
    if (s == null) return;
    if (refresh) {
      if (!canRefreshNow && sessionsLoadedOnce) return; // 节流
      sessionsLoading = true;
      sessionsError = null;
      _nextEndTs = 0;
      sessionsHasMore = true;
      notifyListeners();
    } else {
      if (sessionsLoadingMore || !sessionsHasMore) return;
      sessionsLoadingMore = true;
      notifyListeners();
    }

    try {
      debugPrint('[im] loadSessions start (refresh=$refresh)');
      final page = await _service.fetchImSessions(
        platformId,
        session: s,
        endTs: refresh ? 0 : _nextEndTs,
      );
      debugPrint('[im] fetchImSessions ok: ${page.items.length} 条');
      if (refresh) _sessions.clear();
      // 去重：同一 talkerId 只保留一条（服务端可能因时间相近重复下发）
      final existing = _sessions.map((e) => e.talkerId).toSet();
      for (final item in page.items) {
        if (existing.add(item.talkerId)) _sessions.add(item);
      }
      sessionsHasMore = page.hasMore;
      _nextEndTs = page.nextEndTs;
      sessionsLoadedOnce = true;
      sessionsError = null;
      _lastSessionsRefresh = DateTime.now();

      // 按服务端语义排序：置顶优先，其次 session_ts 倒序。
      // 为什么本地也要排：翻页是追加的，而且发送消息后会本地改
      // session_ts，不重排就会出现"刚发过消息的会话沉在下面"。
      _sessions.sort((a, b) {
        if (a.isTop != b.isTop) return a.isTop ? -1 : 1;
        return b.sessionTs.compareTo(a.sessionTs);
      });

      // 列表已经可渲染：先通知一次，别让用户等昵称/未读。
      debugPrint('[im] _sessions.length=${_sessions.length} '
          'loading=$sessionsLoading loggedIn=${_session != null}');
      notifyListeners();

      // 补昵称/头像（一次批量请求）
      await _ensureUserInfos(_sessions.map((e) => e.talkerId).toList());
      debugPrint('[im] userInfos ok');

      // 未读汇总（失败不影响列表）
      try {
        unread = await _service.fetchImUnread(platformId, session: s);
      } on FusionException {
        // 未读拿不到就不显示红点，不阻断列表
      }
    } on FusionException catch (e) {
      debugPrint('[im] sessions FusionException: ${e.code} ${e.userMessage}');
      sessionsError = e;
      if (e.code == FusionErrorCode.loginRequired) {
        _session = null;
      }
    } catch (e) {
      debugPrint('[im] sessions error: $e');
      sessionsError = normalizeError(e, platformId: platformId);
    } finally {
      sessionsLoading = false;
      sessionsLoadingMore = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreSessions() => loadSessions();

  /// 批量补用户信息（只请求缺的）。
  Future<void> _ensureUserInfos(List<int> ids) async {
    final s = _session;
    if (s == null) return;
    final missing = ids.where((id) => !_userInfos.containsKey(id)).toList();
    if (missing.isEmpty) return;
    try {
      final infos = await _service.fetchImUserInfos(
        platformId,
        session: s,
        uids: missing,
      );
      _userInfos.addAll(infos);
    } on FusionException {
      // 头像/昵称拿不到就用占位，不影响会话可用
    }
  }

  /// 会话展示名：优先 user_infos 的 name，其次群名，最后 uid。
  String titleOf(ImSession s) {
    final info = _userInfos[s.talkerId];
    if (info?.name != null && info!.name!.isNotEmpty) return info.name!;
    return s.displayTitle;
  }

  String? avatarOf(ImSession s) {
    final info = _userInfos[s.talkerId];
    if (info?.faceUrl != null && info!.faceUrl!.isNotEmpty) return info.faceUrl;
    return s.groupCoverUrl;
  }

  // ── 消息加载 ────────────────────────────────────────────────

  /// 首次加载某会话的最新一页。
  Future<void> loadMessages(int talkerId, {bool refresh = false}) async {
    final s = _session;
    if (s == null) return;
    final chat = chatOf(talkerId);
    if (chat.loading) return;

    chat.loading = true;
    chat.error = null;
    if (refresh) {
      chat.generation++;
      chat.hasMore = true;
      chat.minSeqno = 0;
      chat.maxSeqno = 0;
    }
    final gen = chat.generation;
    notifyListeners();

    try {
      final page = await _service.fetchImMessages(
        platformId,
        session: s,
        talkerId: talkerId,
      );
      // 期间切换了会话 / 重新加载：丢弃
      if (gen != chat.generation) return;
      chat.mergePage(page);
    } on FusionException catch (e) {
      if (gen != chat.generation) return;
      chat.error = e;
      if (e.code == FusionErrorCode.loginRequired) _session = null;
    } catch (e) {
      if (gen != chat.generation) return;
      chat.error = normalizeError(e, platformId: platformId);
    } finally {
      if (gen == chat.generation) chat.loading = false;
      notifyListeners();
    }
  }

  /// 往前翻历史（用 min_seqno 作 end_seqno）。
  Future<void> loadOlderMessages(int talkerId) async {
    final s = _session;
    if (s == null) return;
    final chat = chatOf(talkerId);
    if (chat.loadingMore || !chat.hasMore || chat.minSeqno == 0) return;

    chat.loadingMore = true;
    notifyListeners();
    final gen = chat.generation;
    try {
      final page = await _service.fetchImMessages(
        platformId,
        session: s,
        talkerId: talkerId,
        endSeqno: chat.minSeqno,
      );
      if (gen != chat.generation) return;
      chat.mergePage(page);
    } on FusionException catch (e) {
      if (gen != chat.generation) return;
      chat.error = e;
    } finally {
      if (gen == chat.generation) chat.loadingMore = false;
      notifyListeners();
    }
  }

  // ── 发送 ────────────────────────────────────────────────────

  /// 发送文本消息。
  ///
  /// 流程：本地插入 sending → 调接口 → 成功则用服务端 msgKey 替换 →
  /// 失败标 failed 并保留在列表里（可重试）。
  ///
  /// **不谎报成功**：只有 `result.accepted` 为 true 才变 `sent`。
  Future<bool> sendText(int talkerId, String text) async {
    final s = _session;
    if (s == null) return false;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    final chat = chatOf(talkerId);
    final localKey = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    chat.addLocal(ImMessage(
      msgKey: localKey,
      senderUid: myUid,
      receiverId: talkerId,
      receiverType: 1,
      msgType: 1,
      timestamp: now,
      content: '{"content":"$trimmed"}',
      text: trimmed,
      sendState: ImSendState.sending,
    ));
    notifyListeners();

    try {
      final result = await _service.sendImMessage(
        platformId,
        session: s,
        talkerId: talkerId,
        content: trimmed,
      );
      if (result.accepted && result.msgKey != null) {
        chat.confirmLocal(
          localKey,
          ImMessage(
            msgKey: result.msgKey!,
            senderUid: myUid,
            receiverId: talkerId,
            receiverType: 1,
            msgType: 1,
            timestamp: now,
            content: result.msgContent ?? '{"content":"$trimmed"}',
            text: trimmed,
            sendState: ImSendState.sent,
          ),
        );
        // 发送成功后同步会话列表的最后一条（不重新拉全量，省请求）
        _bumpSessionPreview(talkerId, trimmed, now);
        notifyListeners();
        return true;
      }
      chat.failLocal(localKey, result.message ?? '发送失败');
      notifyListeners();
      return false;
    } on FusionException catch (e) {
      chat.failLocal(localKey, e.userMessage);
      if (e.code == FusionErrorCode.loginRequired) _session = null;
      notifyListeners();
      return false;
    } catch (e) {
      chat.failLocal(localKey, '网络异常，请重试');
      notifyListeners();
      return false;
    }
  }

  /// 重发一条失败消息。
  Future<bool> resend(ImMessage failed) async {
    final chat = chatOf(failed.receiverId);
    chat.removeLocal(failed.msgKey);
    notifyListeners();
    // 图片消息走图片通道，不能当成文本重发
    if (failed.type == ImMessageType.image) {
      final path = failed.localPreviewPath;
      if (path == null) {
        // 没有本地文件了（重启/缓存清理）：如实失败，不假装重发
        chat.addLocal(failed.copyWith(
          msgKey: failed.msgKey,
          sendState: ImSendState.failed,
          localError: '本地图片已不可用，请重新选择图片发送。',
        ));
        notifyListeners();
        return false;
      }
      return sendImage(failed.receiverId, filePath: path);
    }
    return sendText(failed.receiverId, failed.text ?? '');
  }

  // ── 发送图片 ────────────────────────────────────────────────
  //
  // 流程（需求一·2）：
  //  1. 本地校验（格式/大小）——不合格直接拒绝，不浪费一次上传
  //  2. 插入"sending"气泡（带本地预览路径）
  //  3. 上传 → 拿到服务端 image_url
  //  4. 用真实 URL 构造图片消息发送
  //  5. 服务端确认 → 替换气泡为 sent；任一步失败 → failed 可重试
  //
  // **不假装成功**：上传失败不会发消息；发送失败不会显示图片已送达。

  /// 当前上传进度（0..1），按本地消息 key 索引。
  ///
  /// 只有"上传中"这一阶段有进度；发送消息本身是单次请求，没有中间进度。
  final Map<String, double> _uploadProgress = {};

  double? uploadProgressOf(String localKey) => _uploadProgress[localKey];

  /// 发送一张本地图片。
  ///
  /// [filePath] 是设备上的文件路径。**只用于上传与本地预览**，
  /// 绝不作为远端地址塞进消息体。
  Future<bool> sendImage(int talkerId, {required String filePath}) async {
    final s = _session;
    if (s == null) return false;
    if (!_service.supportsImImageSendFor(platformId)) return false;

    // 读文件（IO 错误由 service 归一化）
    List<int> bytes;
    try {
      bytes = await _service.readLocalImage(filePath);
    } on FusionException catch (e) {
      _pushTransientError(e.userMessage);
      return false;
    } catch (e) {
      _pushTransientError('读取图片失败，请重新选择。');
      return false;
    }

    final filename = filePath.split(RegExp(r'[\\/]')).last;

    final chat = chatOf(talkerId);
    final localKey = 'local-img-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    chat.addLocal(ImMessage(
      msgKey: localKey,
      senderUid: myUid,
      receiverId: talkerId,
      receiverType: 1,
      msgType: 2,
      timestamp: now,
      content: '',
      sendState: ImSendState.sending,
      localPreviewPath: filePath,
    ));
    _uploadProgress[localKey] = 0;
    notifyListeners();

    // 1) 上传
    ImMedia media;
    try {
      media = await _service.uploadImImage(
        platformId,
        session: s,
        bytes: bytes,
        filename: filename,
      );
      _uploadProgress[localKey] = 1;
      notifyListeners();
    } on FusionException catch (e) {
      chat.failLocal(localKey, e.userMessage);
      _uploadProgress.remove(localKey);
      if (e.code == FusionErrorCode.loginRequired) _session = null;
      notifyListeners();
      return false;
    } catch (e) {
      chat.failLocal(localKey, '图片上传失败，请重试。');
      _uploadProgress.remove(localKey);
      notifyListeners();
      return false;
    }

    // 2) 发送图片消息
    try {
      final result = await _service.sendImImage(
        platformId,
        session: s,
        talkerId: talkerId,
        media: media,
      );
      _uploadProgress.remove(localKey);
      if (result.accepted && result.msgKey != null) {
        chat.confirmLocal(
          localKey,
          ImMessage(
            msgKey: result.msgKey!,
            senderUid: myUid,
            receiverId: talkerId,
            receiverType: 1,
            msgType: 2,
            timestamp: now,
            content: result.msgContent ?? '',
            sendState: ImSendState.sent,
            media: media,
            // 保留本地预览路径：远端图加载前先显示本地图，避免闪空
            localPreviewPath: filePath,
          ),
        );
        _bumpSessionPreview(talkerId, '[图片]', now);
        notifyListeners();
        return true;
      }
      chat.failLocal(localKey, result.message ?? '图片发送失败');
      notifyListeners();
      return false;
    } on FusionException catch (e) {
      _uploadProgress.remove(localKey);
      chat.failLocal(localKey, e.userMessage);
      if (e.code == FusionErrorCode.loginRequired) _session = null;
      notifyListeners();
      return false;
    } catch (e) {
      _uploadProgress.remove(localKey);
      chat.failLocal(localKey, '图片发送失败，请重试。');
      notifyListeners();
      return false;
    }
  }

  /// 发送一个表情（以表情短代码作为文本消息发出）。
  ///
  /// # 为什么是文本短代码而不是表情图片消息
  ///
  /// 平台的 `msg_type=6`（`FAV_EMOJI`）语义是**"收藏的表情"**，
  /// 发送未收藏的表情很可能被拒（本项目未验证）。
  /// 而把 `[doge]` 作为普通文本发出去，接收端一定会按表情渲染——
  /// 这是 B 站私信里表情的实际传递方式，且不依赖收藏关系。
  ///
  /// 因此这里选择"文本短代码"这条**确定可用**的路径，
  /// 而不是拼一个未经验证的自定义表情消息。
  Future<bool> sendEmote(int talkerId, String shortcode) async {
    final code = shortcode.trim();
    if (code.isEmpty) return false;
    return sendText(talkerId, code);
  }

  /// 拉取表情面板。
  Future<ImEmotePanel> loadEmotePanel() async {
    final s = _session;
    if (s == null) {
      return const ImEmotePanel(unavailableReason: '需要登录后才能使用表情。');
    }
    if (_emotePanel != null && _emotePanel!.loaded) return _emotePanel!;
    if (_emoteLoading) return _emotePanel ?? const ImEmotePanel();

    _emoteLoading = true;
    notifyListeners();
    try {
      final panel = await _service.fetchImEmotePanel(platformId, session: s);
      _emotePanel = panel;
      return panel;
    } finally {
      _emoteLoading = false;
      notifyListeners();
    }
  }

  ImEmotePanel? _emotePanel;
  ImEmotePanel? get emotePanel => _emotePanel;

  bool _emoteLoading = false;
  bool get emoteLoading => _emoteLoading;

  /// 该平台是否支持发送图片（供聊天页决定是否渲染图片入口）。
  bool get supportsImageSend => _service.supportsImImageSendFor(platformId);

  /// 该平台是否支持表情面板。
  bool get supportsEmote => _service.supportsImEmoteFor(platformId);

  /// 一次性错误提示（供 UI 弹 SnackBar）。
  String? _transientError;
  String? get transientError => _transientError;

  void clearTransientError() {
    if (_transientError == null) return;
    _transientError = null;
    notifyListeners();
  }

  void _pushTransientError(String message) {
    _transientError = message;
    notifyListeners();
  }

  void _bumpSessionPreview(int talkerId, String text, int ts) {
    final i = _sessions.indexWhere((e) => e.talkerId == talkerId);
    if (i < 0) return;
    _sessions[i] = _sessions[i].copyWith(
      lastMsgText: text,
      lastMsgTimestamp: ts,
      sessionTs: ts,
    );
    // 有动静的会话排到前面（置顶的保持在最前）
    _sessions.sort((a, b) {
      if (a.isTop != b.isTop) return a.isTop ? -1 : 1;
      return b.sessionTs.compareTo(a.sessionTs);
    });
  }

  // ── 已读 ────────────────────────────────────────────────────

  /// 把某个会话标记为已读（只对这一个）。
  ///
  /// 由聊天页在**拿到最新消息之后**调用；不在列表页批量调用。
  Future<void> markRead(int talkerId) async {
    final s = _session;
    if (s == null) return;
    final i = _sessions.indexWhere((e) => e.talkerId == talkerId);
    if (i < 0) return;
    final target = _sessions[i];
    if (target.unreadCount == 0) return;

    final chat = chatOf(talkerId);
    final ack = chat.maxSeqno > 0 ? chat.maxSeqno : target.maxSeqno;
    if (ack == 0) return;

    try {
      final ok = await _service.markImSessionRead(
        platformId,
        session: s,
        talkerId: talkerId,
        ackSeqno: ack,
      );
      if (!ok) return;
      _sessions[i] = target.copyWith(unreadCount: 0, ackSeqno: ack);
      // 重新取一次汇总，让入口红点与真实值一致
      try {
        unread = await _service.fetchImUnread(platformId, session: s);
      } on FusionException {
        // 汇总失败：本地已清零，红点可能短暂不一致，下次刷新会校准
      }
      notifyListeners();
    } on FusionException {
      // 标记已读失败不改本地状态 —— 宁可红点还在，也不假装已读
    }
  }

  /// 未读总数（入口红点）。
  int get unreadTotal => unread.total;
}
