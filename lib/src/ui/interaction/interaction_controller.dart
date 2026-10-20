/// 互动控制器：把点赞/投币/收藏/评论的登录态、状态与写操作串起来。
///
/// 设计原则（严格遵守）：
///  - **不乐观更新**。平台返回成功后重新拉取真实状态，而不是本地 +1。
///    否则会出现"界面显示已点赞，但平台实际没生效"的假象。
///  - **未登录不伪造状态**。状态未知时 UI 显示"登录后可操作"，
///    不显示"未点赞"（那会让用户以为操作被重置）。
///  - **写操作失败必须上报**。不静默吞掉，UI 需要明确反馈。
///  - **服务端确认后才是状态**。写操作成功 = 接口 code=0 **且** 复查后
///    服务端状态确实变了（B 站存在 code=0 但实际没生效的假成功）。
///  - **竞态防护**。同一视频可能有多个请求在飞（初始拉取 + 写后复查），
///    只有最后一次请求的结果可以落进状态，晚到的旧响应必须丢弃。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../adapters/platform_adapter.dart';
import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../models/interaction.dart';
import '../../models/translation.dart';
import '../../models/unified_video.dart';

/// 评论 IP 属地的可得性。
enum IpLocationAvailability {
  /// 尚未加载评论，或评论为空——此时不提示任何东西。
  unknown,

  /// 至少有一条评论带属地，正常展示。
  available,

  /// 未登录，平台不下发属地。登录后可能可得。
  unavailableAnonymous,

  /// 已登录但平台仍不下发。这是平台限制，登录也解决不了。
  unavailableLoggedIn,
}

/// 单个视频的互动控制器。
///
/// **同一视频全 App 只应有一个实例**，由 [InteractionRegistry] 按视频 ID
/// 复用。之前推荐页与详情页各建一份，导致同一视频在两个入口显示
/// 不同的点赞/收藏状态——这是"收藏后按钮不高亮/换页状态丢失"的根因之一。
class InteractionController extends ChangeNotifier {
  InteractionController({
    required this.video,
    required VideoService service,
    required CredentialVault vault,
  })  : _service = service,
        _vault = vault;

  final UnifiedVideo video;
  final VideoService _service;
  final CredentialVault _vault;

  // ── 登录态 ──────────────────────────────────────────────────

  PlatformSession? _session;
  PlatformSession? get session => _session;

  bool get isLoggedIn => _session != null;

  // ── 互动状态 ────────────────────────────────────────────────

  InteractionState _state = InteractionState.unknown;
  InteractionState get state => _state;

  /// 平台支持的互动能力。
  InteractionCapabilities get capabilities =>
      _service.capabilitiesFor(video.platformId);

  /// 该平台是否支持"选择收藏夹"（只有接口实测可用的平台为 true）。
  bool get supportsFavoriteFolders =>
      _service.supportsFavoriteFoldersFor(video.platformId);

  // ── 请求代际（竞态防护）──────────────────────────────────────
  //
  // 每次"拉取服务端状态"递增一次序号。响应回来时若序号已不是最新，
  // 说明期间又发生了新的拉取（典型：写操作后的复查与初始拉取并发），
  // 旧响应必须丢弃——否则慢的旧响应会把新状态覆盖回写操作前的值，
  // 表现为"收藏成功了但按钮又变回未收藏"。
  int _stateSeq = 0;

  // ── 进行中的操作（防重复点击）──────────────────────────────

  final Set<String> _pending = {};

  bool isPending(String action) => _pending.contains(action);

  bool get likePending => isPending('like');
  bool get coinPending => isPending('coin');
  bool get favoritePending => isPending('favorite');
  bool get watchLaterPending => isPending('watchLater');
  bool get followPending => isPending('follow');

  // ── 收藏夹 ──────────────────────────────────────────────────

  List<FavoriteFolder> _folders = const [];
  List<FavoriteFolder> get favoriteFolders => _folders;

  /// 该平台是否支持"逐夹归属扫描"。
  ///
  /// 不支持时**没有"未核对"这个概念**（平台根本给不出归属），
  /// UI 应退化为"只知道是否收藏过"，而不是给每一行打「未核对」——
  /// 后者会把"平台不提供该信息"错报成"我没查"。
  bool get supportsFolderOwnershipScan =>
      _service.supportsFolderOwnershipScanFor(video.platformId);

  /// 该视频当前真实归属的收藏夹 id（来自逐夹扫描，非本地推断）。
  Set<int> _ownership = const {};
  Set<int> get favoritedFolderIds => _ownership;

  /// **已完整核对过**（翻到底）的收藏夹 id。
  ///
  /// 归属扫描带请求预算，可能只跑完一部分夹。区分三种状态：
  ///  - 在 [favoritedFolderIds] → 已确认包含
  ///  - 在 [_ownershipChecked] 但不在上面 → 已确认不包含
  ///  - 两者都不在 → **不知道**（还没轮到 / 被限流）
  ///
  /// UI 对第三种必须显示"未核对"，不能渲染成未勾选 —— 那是假的否定。
  Set<int> _ownershipChecked = const {};

  /// 该夹的归属是否已核对过（翻到底）。未核对的夹状态未知。
  bool folderChecked(int folderId) => _ownershipChecked.contains(folderId);

  /// 是否因平台限流（HTTP 412）提前中断。
  bool _ownershipRateLimited = false;
  bool get favoriteFoldersRateLimited => _ownershipRateLimited;

  /// 归属扫描本身是否正在进行（区别于 [_foldersLoading]：
  /// 夹列表已到、正在逐个核对归属）。
  bool _scanning = false;
  bool get ownershipScanning => _scanning;

  /// 归属是否已解析完（扫描跑完 / 明确未收藏 / 平台不支持）。
  ///
  /// 逐夹扫描带**请求预算**（实测连发 6 个请求 B站 就返回 HTTP 412
  /// 触发验证码），所以可能只核对了一部分夹。未解析完时不得提交写操作：
  /// 拿不完整的归属算 add/del 增量会漏删或重复添加。
  bool _ownershipResolved = false;
  bool get favoriteFoldersResolved => _ownershipResolved;

  bool _foldersLoading = false;
  bool get favoriteFoldersLoading => _foldersLoading;

  FusionException? _foldersError;
  FusionException? get favoriteFoldersError => _foldersError;

  /// 收藏夹是否已拉取过（用于区分"没拉"与"拉了但为空"）。
  bool _foldersLoadedOnce = false;
  bool get favoriteFoldersLoadedOnce => _foldersLoadedOnce;

  // ── 投币余额 ────────────────────────────────────────────────

  int? _coinBalance;
  int? get coinBalance => _coinBalance;

  // ── 评论 ────────────────────────────────────────────────────

  final List<VideoComment> _comments = [];

  /// 评论的只读视图。
  ///
  /// **性能关键**：这里必须缓存包装器，不能写成
  /// `List.unmodifiable(_comments)` —— 那样每次访问都会新建一个
  /// UnmodifiableListView，而评论列表的 `itemBuilder` 每帧会为每个
  /// 可见条目访问一次，滚动时每帧产生 N 次堆分配，直接导致掉帧。
  ///
  /// 缓存后只有列表被整体替换（`_comments = ...`）时才重建包装器。
  /// 这里用 late 字段 + 在替换列表时失效的方式，保持语义正确。
  List<VideoComment>? _commentsView;
  List<VideoComment> get comments =>
      _commentsView ??= List.unmodifiable(_comments);

  /// 列表内容变更后调用，使只读视图失效。
  ///
  /// 只在"结构性变更"（追加/清空/刷新）后调用，
  /// 不在单条评论的字段变化时调用。
  void _invalidateCommentsView() {
    _commentsView = null;
  }

  int _commentPage = 0;
  int _commentTotal = 0;
  int get commentTotal => _commentTotal;

  /// 下一页游标（游标分页平台使用；0 表示从头开始）。
  int _commentCursor = 0;

  bool _commentsLoading = false;
  bool get commentsLoading => _commentsLoading;

  bool _commentsHasMore = true;
  bool get commentsHasMore => _commentsHasMore;

  FusionException? _commentsError;
  FusionException? get commentsError => _commentsError;

  bool _commentsLoadedOnce = false;
  bool get commentsLoadedOnce => _commentsLoadedOnce;

  // ── 评论翻译 ────────────────────────────────────────────────
  //
  // 状态按评论 ID 存放，**不写回 VideoComment**：
  //  - 评论是不可变值对象，且来自平台；翻译是本地会话状态
  //  - 同一评论可以切换语言、可以隐藏/显示译文
  //  - 翻译失败不能污染评论模型
  //
  // 缓存与去重由 TranslationService 负责，这里只管 UI 状态。

  final Map<String, CommentTranslation> _translations = {};

  /// 取某条评论的翻译状态（没有则返回 idle 态）。
  CommentTranslation translationOf(String commentId) =>
      _translations[commentId] ?? CommentTranslation(commentId: commentId);

  /// 该平台是否有可用的翻译能力。
  ///
  /// 抖音目前没有官方评论翻译接口，也没有已授权的通用翻译服务，
  /// 因此返回 false —— UI 据此**不渲染翻译入口**，
  /// 而不是给一个点了必然失败的按钮。
  bool get supportsTranslation => video.platformId == 'bilibili';

  /// 翻译能力的不可用原因（供 UI 在必要时说明）。
  String? get translationUnavailableReason => supportsTranslation
      ? null
      : '该平台的翻译接口需要登录态，当前不可用。';

  /// 目标语言。
  TranslationLanguage _translationLanguage = TranslationLanguage.zhHans;
  TranslationLanguage get translationLanguage => _translationLanguage;

  /// 切换目标语言。已翻译的条目会保留原结果（不自动重译），
  /// 用户重新点翻译时按新语言取。
  void setTranslationLanguage(TranslationLanguage language) {
    if (_translationLanguage == language) return;
    _translationLanguage = language;
    notifyListeners();
  }

  /// 切换某条评论译文的显示 / 隐藏。
  ///
  /// 原文始终保留，这只是控制第二段文本是否可见。
  void toggleTranslationVisibility(String commentId) {
    final current = translationOf(commentId);
    if (current.state != CommentTranslationState.done) return;
    _translations[commentId] = current.copyWith(visible: !current.visible);
    notifyListeners();
  }

  /// 请求翻译某条评论。
  ///
  /// 幂等：已成功的不重复请求（直接展开）；失败的可重试。
  Future<void> translateComment(String commentId) async {
    if (!supportsTranslation) return;

    final existing = translationOf(commentId);
    // 已有译文：只切换显示，不重复请求（需求四·1「优先复用有效缓存」）
    if (existing.state == CommentTranslationState.done) {
      _translations[commentId] = existing.copyWith(visible: !existing.visible);
      notifyListeners();
      return;
    }
    if (existing.state == CommentTranslationState.loading) return;

    final comment = _comments.firstWhere(
      (c) => c.id == commentId,
      orElse: () => _missingComment,
    );
    if (identical(comment, _missingComment)) return;

    _translations[commentId] =
        existing.copyWith(state: CommentTranslationState.loading, visible: true);
    notifyListeners();

    final result = await _service.translateComment(
      platformId: video.platformId,
      commentId: commentId,
      text: comment.message,
      session: _session,
      language: _translationLanguage,
    );

    // 期间评论列表被刷新 / 该条已消失：丢弃结果
    if (!_comments.any((c) => c.id == commentId)) {
      _translations.remove(commentId);
      notifyListeners();
      return;
    }

    _translations[commentId] = CommentTranslation(
      commentId: commentId,
      state: result.ok
          ? CommentTranslationState.done
          : CommentTranslationState.failed,
      result: result,
      visible: true,
    );
    notifyListeners();
  }

  /// 「找不到该评论」时的哨兵对象（避免用 null 到处判空）。
  static const VideoComment _missingComment = VideoComment(
    id: '__missing__',
    authorName: '',
    message: '',
    createdAt: '',
  );

  // ── IP 属地可得性 ───────────────────────────────────────────

  /// 当前已加载评论的属地覆盖情况。
  ///
  /// 需求要求"数据不存在时明确显示暂不可用"，但**不能**在每条评论上
  /// 都印一遍——20 条评论印 20 次"暂不可用"是噪音，不是信息。
  ///
  /// 因此在面板层给一句明确说明，单条评论缺失时整段不渲染。
  /// 三种缺失原因要分开，因为它们对应的用户行动完全不同：
  ///  - 未登录 → 提示去登录
  ///  - 已登录仍无 → 平台限制，登录也拿不到，别让用户白试
  ///  - 尚未加载 → 不提示
  IpLocationAvailability get ipLocationAvailability {
    if (!_commentsLoadedOnce) return IpLocationAvailability.unknown;
    if (_comments.isEmpty) return IpLocationAvailability.unknown;
    if (_comments.any((c) => c.ipLocation != null)) {
      return IpLocationAvailability.available;
    }
    return _session == null
        ? IpLocationAvailability.unavailableAnonymous
        : IpLocationAvailability.unavailableLoggedIn;
  }

  // ── 最近一次操作反馈 ────────────────────────────────────────

  String? _lastMessage;
  String? get lastMessage => _lastMessage;

  /// 清除一次性提示（UI 展示后调用）。
  void clearMessage() {
    if (_lastMessage == null) return;
    _lastMessage = null;
    notifyListeners();
  }

  // ── 初始化 ──────────────────────────────────────────────────

  /// 恢复登录态并拉取互动状态。
  Future<void> init() async {
    await _loadSession();
    if (_session != null) {
      await refreshState();
    }
  }

  /// 重新读取登录会话（Cookie 导入 / 登录后由登记表调用）。
  ///
  /// 与 [init] 的区别：这里**无论登录态是否变化都会重算**，
  /// 用于"用户在设置页导入了 cookie，已打开的推荐流要立刻反映新状态"。
  Future<void> reloadSession() async {
    final before = _session?.userId;
    await _loadSession();
    if (_session?.userId == before && _state.known && _session != null) {
      // 登录态没变且已有服务端状态：不重复请求
      return;
    }
    await refreshState();
  }

  Future<void> _loadSession() async {
    PlatformSession? loaded;
    try {
      loaded = await _vault
          .load(video.platformId)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      loaded = null;
    }
    _session = loaded;
    notifyListeners();
  }

  /// 重新拉取互动状态（登录后 / 写操作成功后调用）。
  Future<void> refreshState() async {
    final seq = ++_stateSeq;
    if (_session == null) {
      _state = InteractionState.unknown;
      _folders = const [];
      _ownership = const {};
      _foldersLoadedOnce = false;
      notifyListeners();
      return;
    }
    try {
      final next = await _service.fetchInteractionState(
        video,
        session: _session,
      );
      // 期间又发起了新的拉取：丢弃这次（可能过期的）结果
      if (seq != _stateSeq) return;
      _state = next;

      // ── 归属不能被状态接口"清空" ────────────────────────────
      //
      // 契约：`archive/relation` 只给聚合布尔 `favorite`，
      // **不返回**"在哪些收藏夹里"（要拿到归属只能逐夹扫描，
      // 而扫描有预算、会被 412 打断）。所以适配器这里恒给空列表。
      //
      // 早先这里写的是 `_ownership = next.favoritedFolderIds.toSet()`，
      // 后果是收藏成功后紧接着的 `refreshState()` 把面板扫描到的
      // 勾选态抹掉 → 再开面板全不勾，用户以为没收藏上。
      _ownership = _ownershipFor(next);
      // 状态对象里的归属要与控制器一致：适配器那里恒为空
      // （聚合布尔不含"在哪个夹"），若不同步就会有读取方
      // 直接看 state.favoritedFolderIds 而得出"哪都没收藏"的假结论。
      if (_ownership.isNotEmpty) {
        _state = _state.copyWith(favoritedFolderIds: _ownership.toList());
      }
    } on FusionException catch (e) {
      if (seq != _stateSeq) return;
      // 登录态失效：清掉本地会话，让 UI 引导重新登录
      if (e.code == FusionErrorCode.loginRequired) {
        _session = null;
        _state = InteractionState.unknown;
        _lastMessage = e.userMessage;
      }
    } catch (_) {
      if (seq != _stateSeq) return;
      _state = InteractionState.unknown;
    }
    notifyListeners();
  }

  // ── 点赞 ────────────────────────────────────────────────────

  /// 点赞 / 取消点赞。
  Future<void> toggleLike() async {
    if (likePending) return;
    if (!_requireLogin('点赞')) return;

    final target = !_state.liked;
    _pending.add('like');
    notifyListeners();

    try {
      final r = await _service.setLike(
        video,
        like: target,
        session: _session,
      );
      if (!r.accepted) {
        _lastMessage = r.message ?? '操作未被平台接受，请稍后重试。';
      } else {
        // 成功后重新拉取真实状态，不本地累加
        await refreshState();
        _lastMessage = target ? '已点赞' : '已取消点赞';
      }
    } on FusionException catch (e) {
      await _handleFailure(e);
    } finally {
      _pending.remove('like');
      notifyListeners();
    }
  }

  // ── 投币 ────────────────────────────────────────────────────

  /// 拉取硬币余额（B 站：`/x/member/web/exp/reward` 的 `data.coins`）。
  ///
  /// 投币前必须知道余额：实测该账号余额为 0，若不做前置检查，
  /// 用户点"投 1 枚"只会收到一条平台的失败码，体验是"按钮坏了"。
  /// 平台不提供余额接口时返回 null，UI 退化为"余额未知"。
  Future<int?> loadCoinBalance() async {
    if (_session == null) return null;
    if (!_service.capabilitiesFor(video.platformId).coinBalance) return null;
    try {
      final v = await _service.fetchCoinBalance(
        video.platformId,
        session: _session!,
      );
      _coinBalance = v;
      notifyListeners();
      return v;
    } on FusionException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 还能不能投币：已投数上限 2，且需要余额。
  ///
  /// 返回 false 时 UI 必须禁用投币按钮并说明原因，
  /// 而不是让用户点了之后收到一条平台报错。
  ({bool allowed, String reason}) coinAvailability() {
    if (_session == null) return (allowed: false, reason: '请先登录');
    if (_state.coined >= 2) return (allowed: false, reason: '该视频最多投 2 枚硬币，已投满');
    final b = _coinBalance;
    if (b != null && b <= 0) return (allowed: false, reason: '硬币余额不足');
    return (allowed: true, reason: '');
  }

  /// 投币。[count] 为 1 或 2。
  Future<void> giveCoin({int count = 1, bool alsoLike = false}) async {
    if (coinPending) return;
    if (!_requireLogin('投币')) return;

    // 余额未知时先查一次：这是"根据接口实际能力展示确认流程"的要求
    if (_coinBalance == null) await loadCoinBalance();
    final avail = coinAvailability();
    if (!avail.allowed) {
      _lastMessage = avail.reason;
      notifyListeners();
      return;
    }

    // 平台上限：每个视频最多 2 枚，已投 coined 枚 → 还能投 2 - coined 枚；
    // 同时不得超过余额。夹在 [1, 剩余可投] 之间。
    final maxByQuota = 2 - _state.coined;
    final maxByBalance = _coinBalance ?? maxByQuota;
    final maxAllowed = maxByQuota < maxByBalance ? maxByQuota : maxByBalance;
    if (maxAllowed < 1) {
      _lastMessage = '当前无法投币（已达上限或余额不足）。';
      notifyListeners();
      return;
    }
    final actual = count > maxAllowed ? maxAllowed : count;
    _pending.add('coin');
    notifyListeners();

    try {
      final r = await _service.setCoin(
        video,
        count: actual,
        session: _session,
        alsoLike: alsoLike,
      );
      if (!r.accepted) {
        _lastMessage = r.message ?? '投币未成功：${r.upstreamCode ?? '未知原因'}';
      } else {
        await refreshState();
        // 余额被消耗，必须作废，否则下一次投币仍显示旧余额
        _coinBalance = null;
        _lastMessage = '已投 $actual 枚硬币';
      }
    } on FusionException catch (e) {
      await _handleFailure(e);
    } finally {
      _pending.remove('coin');
      notifyListeners();
    }
  }

  // ── 收藏（含收藏夹选择）──────────────────────────────────────

  /// 依据服务端聚合布尔决定归属集合，**不清空已扫描到的结果**。
  ///
  /// 契约背景：`archive/relation` 只回答"收藏过没有"，不回答
  /// "在哪些收藏夹里"；后者只能逐夹扫描（有预算、会被 412 打断），
  /// 所以适配器在 [InteractionState.favoritedFolderIds] 上恒给空列表。
  ///
  /// 三种情况：
  ///  - `favorited == false` → 归属必为空，并把"已解析"关掉，
  ///    下次开面板重新扫（用户可能刚在别处收藏了它）。
  ///  - `favorited == true` 且本会话已扫到归属 → **原样保留**。
  ///    这条就是用来修"收藏成功后重拉状态把勾选抹掉"的问题。
  ///  - `favorited == true` 但还没扫过 → 保持空且未解析，
  ///    面板打开时才扫，避免每次进详情页都花掉数个请求。
  Set<int> _ownershipFor(InteractionState next) {
    if (!next.favorited) {
      _ownershipResolved = false;
      _ownershipChecked = const {};
      return const {};
    }
    // 平台若直接回报了归属，以它为准（比本地扫描更新）。
    // 目前只有 B站 走"只给布尔"这条路，但契约上不该假定所有平台都如此。
    if (next.favoritedFolderIds.isNotEmpty) {
      _ownershipResolved = true;
      return next.favoritedFolderIds.toSet();
    }
    // 平台只给聚合布尔：保留本会话已扫到的归属，不要清空。
    return _ownership;
  }

  /// 拉取当前账号的真实收藏夹列表，并扫描该视频的归属。
  ///
  /// # 为什么必须扫描（实测结论）
  ///
  /// B站的 `created/list-all?bvid=` 里的 `fav_state` **与"该视频是否在此夹"无关**
  /// ——它描述的是"我是否收藏了这个夹子"，对自己创建的夹恒为 0（已用判别实验
  /// 证伪：确定在夹内的视频，其所在夹 fav_state 仍为 0）。
  ///
  /// 唯一可靠的归属判定是逐夹翻 `resource/list` 找该 bvid。
  /// 因此这里在**服务端已确认收藏过**（[InteractionState.favorited]）时才扫描，
  /// 未收藏直接是空集合，省掉一整轮请求。
  ///
  /// 每次打开面板都重新拉：收藏夹可能被改名/新建/删除，
  /// 默认夹的 ID 也不能假定不变（实测该账号 6 个夹、ID 8~10 位）。
  Future<void> loadFavoriteFolders({bool forceScan = false}) async {
    if (_session == null) return;
    if (_foldersLoading) return;

    // 重复打开面板不重新全量扫描。
    //
    // 实测：B站在连发 6 个请求后返回 HTTP 412（status_msg=triggered
    // captcha，业务码 -70103112），而"归属"要逐夹翻 resource/list，
    // 且服务端 ps 硬上限 20 —— 一个 145 条的夹要翻 8 页。
    // 每次开面板都重扫必然被限流，用户看到的是"转圈后失败"。
    //
    // 因此：本会话内已解析过归属就用缓存；
    // 只有写操作之后（forceScan: true）才强制重扫以确认服务端变化。
    if (!forceScan && _foldersLoadedOnce && _ownershipResolved) return;

    _foldersLoading = true;
    _foldersError = null;
    notifyListeners();

    try {
      final list = await _service.fetchFavoriteFolders(
        video.platformId,
        session: _session!,
      );
      _folders = list;
      _foldersLoadedOnce = true;
      // 夹列表先到：面板立刻可交互，归属随后填上
      notifyListeners();

      // 归属扫描：仅在服务端说"收藏过"时才有意义
      final shouldScan = forceScan || _state.favorited;
      if (shouldScan &&
          list.isNotEmpty &&
          _service.supportsFolderOwnershipScanFor(video.platformId)) {
        _scanning = true;
        notifyListeners();
        final scan = await _service.scanFoldersContainingVideo(
          video.platformId,
          platformVideoId: video.platformVideoId,
          session: _session!,
        );
        _scanning = false;
        _ownership = scan.containedFolderIds.toSet();
        _ownershipChecked = scan.checkedFolderIds.toSet();
        _ownershipRateLimited = scan.rateLimited;
        // exhaustive=false 时仍有夹没核对：那些夹的状态是"不知道"，
        // 面板必须显示"未核对"，不能渲染成未勾选（假的否定比不否定糟）。
        _ownershipResolved = scan.exhaustive || !scan.rateLimited;

        // 扫描结果比 archive/relation 的布尔更具体：
        //  扫到了归属 → 收藏态必为真；
        //  全部夹都核对完却一个没命中 → 收藏关系其实已不存在
        //  （例如在其它设备上被移除），此时以扫描结果为准；
        //  没核对完 → 不动 favorited，保留服务端布尔，避免误清高亮。
        if (scan.exhaustive) {
          _state = _state.copyWith(
            known: true,
            favorited: _ownership.isNotEmpty,
            favoritedFolderIds: _ownership.toList(),
          );
        } else if (_ownership.isNotEmpty) {
          _state = _state.copyWith(
            known: true,
            favorited: true,
            favoritedFolderIds: _ownership.toList(),
          );
        }
      } else if (!shouldScan) {
        _ownership = const {};
        _ownershipChecked = const {};
        _ownershipResolved = true;
        _state = _state.copyWith(
          favoritedFolderIds: const [],
        );
      } else {
        // 平台不支持归属查询：能收藏，但无法回显已勾选的夹
        _ownershipResolved = true;
      }
    } on FusionException catch (e) {
      _foldersError = e;
      _scanning = false;
      _ownershipResolved = false;
      if (e.code == FusionErrorCode.loginRequired) {
        _session = null;
        _state = InteractionState.unknown;
      }
    } catch (e) {
      _foldersError = normalizeError(e, platformId: video.platformId);
      _scanning = false;
      _ownershipResolved = false;
    } finally {
      _foldersLoading = false;
      notifyListeners();
    }
  }

  /// 按选中的收藏夹集合执行收藏调整。
  ///
  /// # 语义
  ///
  /// [selected] 是**用户最终想要的归属集合**，不是增量。
  /// 内部按服务端真实归属算出"要加的夹"和"要删的夹"，分别提交：
  ///  - 加：`add_media_ids = selected - current`
  ///  - 删：`del_media_ids = current - selected`
  ///
  /// 这样"取消某个夹"不会被误写成"取消整条收藏"，
  /// 符合"取消操作不得误改原有收藏关系"的要求。
  ///
  /// [selected] 为空 = 从所有夹移除（等价于取消收藏）。
  ///
  /// 成功后**复查服务端**再更新 UI：B 站的 `fav/resource/deal` 对
  /// 不存在的收藏夹会返回 `code=0 OK`（实测），只看响应码会产生
  /// "提示已收藏但按钮不高亮"的假成功。
  Future<bool> applyFavoriteFolders(Set<int> selected) async {
    if (favoritePending) return false;
    if (!_requireLogin('收藏')) return false;

    // 归属未知时先补齐（面板正常路径已经拉过，这里是防直接调用）
    if (!_foldersLoadedOnce) {
      await loadFavoriteFolders(forceScan: true);
      if (_foldersError != null) {
        _lastMessage = _foldersError!.userMessage;
        notifyListeners();
        return false;
      }
    }

    final current = _ownership;
    final toAdd = selected.difference(current);
    final toRemove = current.difference(selected);

    // 集合没变 → 不发写请求（避免重复提交），但要把 UI 校准回服务端。
    if (toAdd.isEmpty && toRemove.isEmpty) {
      _lastMessage = '收藏状态没有变化。';
      await refreshState();
      return true;
    }

    _pending.add('favorite');
    notifyListeners();

    try {
      // 平台接口支持一次同时 add + del，因此合并为一次写请求。
      final r = await _service.setFavorite(
        video,
        favorite: toAdd.isNotEmpty,
        session: _session,
        folderIds: toAdd.isEmpty ? null : toAdd.toList(),
        removeFolderIds: toRemove.isEmpty ? null : toRemove.toList(),
      );

      // ── 写入后复查 ──────────────────────────────────────────
      //
      // 写请求被接受 ≠ 服务端真的变了：B站的 deal 会返回
      // `code=0 message=OK data={success_num: 0}`（实测），
      // 对不存在的夹有时返回 0、有时返回 11010。
      //
      // 复查走 verifyRecentFavorite（每个目标夹最多翻 2 页，
      // 因为新加入的项按 mtime 排在第 1 页），
      // **不走** scanFoldersContainingVideo：后者要逐夹翻到底，
      // 实测连发 6 个请求就触发 HTTP 412 人机验证，
      // 用它做每次收藏的复查会让用户"点了就撞验证码"。
      final verifyIds = <int>[...toAdd, ...toRemove];
      List<int> confirmed = const [];
      bool verified = false;
      if (_service.supportsFavoriteVerify(video.platformId)) {
        try {
          confirmed = await _service.verifyRecentFavorite(
            video.platformId,
            platformVideoId: video.platformVideoId,
            folderIds: verifyIds,
            session: _session!,
          );
          verified = true;
        } on FusionException {
          // 复查本身失败（网络/限流）不等于写入失败：
          // 下面退回到状态接口再判一次。
          verified = false;
        }
      }

      // 加入方向：目标夹里确认到了才算生效
      final addOk = toAdd.isEmpty || confirmed.toSet().containsAll(toAdd);
      // 移除方向：目标夹里"确认没有了"才算生效。
      // 复查返回的是"已确认包含"，所以移除后不再出现即为成功。
      final removeOk = toRemove.isEmpty ||
          toRemove.intersection(confirmed.toSet()).isEmpty;

      // 复查不可用时（平台没这个能力，或复查请求失败）：
      // 用聚合布尔兜一次，并如实告诉用户"未确认"，
      // 不假装已验证，也不把"没确认到"断言成"收藏失败"。
      bool? aggregateFavorited;
      if (!verified || (!addOk && toAdd.isNotEmpty)) {
        // 便宜复查没确认到，可能是平台列表缓存滞后：
        // 再看一次 archive/relation 的布尔（单请求，不受翻页影响）
        try {
          final fresh = await _service.fetchInteractionState(
            video,
            session: _session,
          );
          aggregateFavorited = fresh.favorited;
          _ownership = fresh.favoritedFolderIds.toSet();
        } on FusionException {
          aggregateFavorited = null;
        }
      }

      final addConfirmed = addOk ||
          (toAdd.isNotEmpty && aggregateFavorited == true && !verified);
      final accepted = r.accepted && addConfirmed && removeOk;

      if (!accepted) {
        // 失败或未确认：状态保持服务端实际值，绝不标记为"收藏成功"。
        final detail = r.message != null && r.message!.isNotEmpty
            ? r.message!
            : '平台未返回生效确认';
        _lastMessage = verified
            ? '收藏未生效：$detail'
            : '收藏已提交，但未确认到服务端变化（$detail）。请下拉刷新核对。';
        notifyListeners();
        return false;
      }

      // 写入已被服务端确认：把这次变更并入本地归属认知。
      //
      // 必须做，因为 `refreshState()` 拿不到归属（`archive/relation`
      // 只给聚合布尔）。不并的话，收藏成功后 `_ownership` 仍是旧值，
      // 面板再打开时目标夹不勾选 —— 用户会以为没收藏上。
      final merged = {..._ownership}
        ..removeAll(toRemove)
        ..addAll(verified ? confirmed : toAdd);
      _ownership = merged;
      _ownershipChecked = {..._ownershipChecked, ...toRemove, ...toAdd};
      _ownershipResolved = true;

      await refreshState();
      _lastMessage = selected.isEmpty
          ? '已取消收藏'
          : (toAdd.isNotEmpty && toRemove.isEmpty
              ? '已收藏到 ${_folderNames(toAdd)}'
              : '收藏已更新');
      return true;
    } on FusionException catch (e) {
      await _handleFailure(e);
      return false;
    } finally {
      _pending.remove('favorite');
      notifyListeners();
    }
  }

  String _folderNames(Set<int> ids) {
    final names = _folders
        .where((f) => ids.contains(f.id))
        .map((f) => f.title)
        .toList();
    if (names.isEmpty) return '${ids.length} 个收藏夹';
    return names.length <= 2
        ? names.join('、')
        : '${names.take(2).join('、')} 等 ${names.length} 个';
  }

  /// 收藏按钮点击后的入口：直接支持收藏时收藏到默认夹，
  /// 需要选择时由 UI 打开面板再调 [applyFavoriteFolders]。
  Future<void> toggleFavorite() async {
    if (favoritePending) return;
    if (!_requireLogin('收藏')) return;

    if (_state.favorited) {
      // 已收藏 → 取消（从当前归属的所有夹移除）
      await applyFavoriteFolders(const {});
    } else {
      // 未收藏 → 收藏到默认收藏夹（平台自己的默认夹，不是本地猜的）
      if (!_foldersLoadedOnce) await loadFavoriteFolders();
      final def = _folders.where((f) => f.isDefault).firstOrNull ??
          _folders.firstOrNull;
      if (def == null) {
        _lastMessage = '当前账号没有可用收藏夹，请先在平台创建一个。';
        notifyListeners();
        return;
      }
      await applyFavoriteFolders({def.id});
    }
  }

  // ── 稍后再看 ────────────────────────────────────────────────

  Future<void> toggleWatchLater() async {
    if (watchLaterPending) return;
    if (!_requireLogin('稍后再看')) return;
    if (!capabilities.watchLater) {
      _lastMessage = '该平台暂不支持稍后再看。';
      notifyListeners();
      return;
    }

    final target = !_state.watchLater;
    _pending.add('watchLater');
    notifyListeners();

    try {
      final r = await _service.setWatchLater(
        video.platformId,
        platformVideoId: video.platformVideoId,
        add: target,
        session: _session!,
      );
      if (!r.accepted) {
        _lastMessage = r.message ?? '操作未被平台接受。';
      } else {
        final server = await _service.fetchWatchLater(
          video.platformId,
          platformVideoId: video.platformVideoId,
          session: _session!,
        );
        _state = _state.copyWith(known: true, watchLater: server);
        _lastMessage = server ? '已加入稍后再看' : '已从稍后再看移除';
      }
    } on FusionException catch (e) {
      await _handleFailure(e);
    } finally {
      _pending.remove('watchLater');
      notifyListeners();
    }
  }

  // ── 关注 UP 主 ──────────────────────────────────────────────

  String? get authorId => video.author.platformAuthorId;

  bool get canFollowAuthor =>
      capabilities.follow && (authorId?.isNotEmpty ?? false);

  Future<void> toggleFollowAuthor() async {
    if (followPending) return;
    if (!_requireLogin('关注')) return;
    final mid = authorId;
    if (mid == null || mid.isEmpty) {
      _lastMessage = '无法从该视频确定 UP 主，暂不能关注。';
      notifyListeners();
      return;
    }

    final target = !_state.following;
    _pending.add('follow');
    notifyListeners();

    try {
      final r = await _service.setFollowAuthor(
        video.platformId,
        targetMid: mid,
        follow: target,
        session: _session!,
      );
      if (!r.accepted) {
        _lastMessage = r.message ?? '操作未被平台接受。';
      } else {
        await refreshState();
        _lastMessage = target ? '已关注 UP 主' : '已取消关注';
      }
    } on FusionException catch (e) {
      await _handleFailure(e);
    } finally {
      _pending.remove('follow');
      notifyListeners();
    }
  }

  // ── 评论加载 ────────────────────────────────────────────────

  /// 加载评论。首次调用拉第 1 页，之后按 [loadMoreComments] 追加。
  Future<void> loadComments({bool refresh = false}) async {
    if (_commentsLoading) return;
    if (!capabilities.comments) return;

    if (refresh) {
      _comments.clear();
      _invalidateCommentsView();
      _commentPage = 0;
      _commentCursor = 0;
      _commentsHasMore = true;
      _commentsError = null;
    }
    if (!_commentsHasMore && _commentPage > 0) return;

    _commentsLoading = true;
    _commentsError = null;
    notifyListeners();

    try {
      // 游标分页：第一次用 page=1（next=0），
      // 之后用上一页返回的 nextCursor 作为 page 传入。
      final requestPage = _commentPage == 0 ? 1 : _commentCursor;
      final page = await _service.fetchComments(
        video,
        page: requestPage,
        pageSize: 20,
        session: _session,
      );
      _commentPage += 1;
      _commentTotal = page.totalCount;
      _commentsHasMore = page.hasMore;
      _commentCursor = page.nextCursor;

      // 去重：游标分页理论上不重复，但仍做防护
      final existing = _comments.map((c) => c.id).toSet();
      var added = false;
      for (final c in page.items) {
        if (!existing.contains(c.id)) {
          _comments.add(c);
          added = true;
        }
      }
      if (added) _invalidateCommentsView();
      _commentsLoadedOnce = true;
    } on FusionException catch (e) {
      _commentsError = e;
    } catch (e) {
      _commentsError = normalizeError(e, platformId: video.platformId);
    } finally {
      _commentsLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreComments() async {
    if (!_commentsHasMore || _commentsLoading) return;
    await loadComments();
  }

  // ── 内部 ────────────────────────────────────────────────────

  /// 前置检查：未登录时给出明确提示并返回 false。
  bool _requireLogin(String action) {
    if (_session != null) return true;
    _lastMessage = '请先登录 ${_platformLabel()} 账号后再$action';
    notifyListeners();
    return false;
  }

  /// 统一失败处理：登录失效时清会话，其余原样上报。
  Future<void> _handleFailure(FusionException e) async {
    _lastMessage = e.userMessage;
    if (e.code == FusionErrorCode.loginRequired ||
        e.code == FusionErrorCode.permissionDenied) {
      // 凭证可能已失效：清掉，让用户重新登录
      try {
        await _vault.clear(video.platformId);
      } catch (_) {}
      _session = null;
      _state = InteractionState.unknown;
    }
  }

  String _platformLabel() => switch (video.platformId) {
        'bilibili' => '哔哩哔哩',
        'douyin' => '抖音',
        'tiktok' => 'TikTok',
        _ => video.platformId,
      };
}
