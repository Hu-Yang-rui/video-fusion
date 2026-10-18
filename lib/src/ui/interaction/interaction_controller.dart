/// 互动控制器：把点赞/投币/收藏/评论的登录态、状态与写操作串起来。
///
/// 设计原则（严格遵守）：
///  - **不乐观更新**。平台返回成功后重新拉取真实状态，而不是本地 +1。
///    否则会出现"界面显示已点赞，但平台实际没生效"的假象。
///  - **未登录不伪造状态**。状态未知时 UI 显示"登录后可操作"，
///    不显示"未点赞"（那会让用户以为操作被重置）。
///  - **写操作失败必须上报**。不静默吞掉，UI 需要明确反馈。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../models/interaction.dart';
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
/// 每个详情页/当前屏持有一个实例，避免不同视频的状态互相污染。
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

  // ── 进行中的操作（防重复点击）──────────────────────────────

  final Set<String> _pending = {};

  bool isPending(String action) => _pending.contains(action);

  bool get likePending => isPending('like');
  bool get coinPending => isPending('coin');
  bool get favoritePending => isPending('favorite');

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
    try {
      _session = await _vault
          .load(video.platformId)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      _session = null;
    }
    notifyListeners();

    if (_session != null) {
      await refreshState();
    }
  }

  /// 重新拉取互动状态（登录后 / 写操作成功后调用）。
  Future<void> refreshState() async {
    if (_session == null) {
      _state = InteractionState.unknown;
      notifyListeners();
      return;
    }
    try {
      _state = await _service.fetchInteractionState(
        video,
        session: _session,
      );
    } on FusionException catch (e) {
      // 登录态失效：清掉本地会话，让 UI 引导重新登录
      if (e.code == FusionErrorCode.loginRequired) {
        _session = null;
        _state = InteractionState.unknown;
        _lastMessage = e.userMessage;
      }
    } catch (_) {
      _state = InteractionState.unknown;
    }
    notifyListeners();
  }

  // ── 写操作 ──────────────────────────────────────────────────

  /// 点赞 / 取消点赞。
  Future<void> toggleLike() async {
    if (likePending) return;
    if (!_requireLogin('点赞')) return;

    final target = !_state.liked;
    _pending.add('like');
    notifyListeners();

    try {
      await _service.setLike(video, like: target, session: _session);
      // 成功后重新拉取真实状态，不本地累加
      await refreshState();
      _lastMessage = target ? '已点赞' : '已取消点赞';
    } on FusionException catch (e) {
      await _handleFailure(e);
    } finally {
      _pending.remove('like');
      notifyListeners();
    }
  }

  /// 投币。[count] 为 1 或 2。
  Future<void> giveCoin({int count = 1, bool alsoLike = false}) async {
    if (coinPending) return;
    if (!_requireLogin('投币')) return;

    _pending.add('coin');
    notifyListeners();

    try {
      await _service.setCoin(
        video,
        count: count,
        session: _session,
        alsoLike: alsoLike,
      );
      await refreshState();
      _lastMessage = '已投 $count 枚硬币';
    } on FusionException catch (e) {
      await _handleFailure(e);
    } finally {
      _pending.remove('coin');
      notifyListeners();
    }
  }

  /// 收藏 / 取消收藏。
  Future<void> toggleFavorite() async {
    if (favoritePending) return;
    if (!_requireLogin('收藏')) return;

    final target = !_state.favorited;
    _pending.add('favorite');
    notifyListeners();

    try {
      await _service.setFavorite(
        video,
        favorite: target,
        session: _session,
      );
      await refreshState();
      _lastMessage = target ? '已收藏' : '已取消收藏';
    } on FusionException catch (e) {
      await _handleFailure(e);
    } finally {
      _pending.remove('favorite');
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
