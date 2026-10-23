/// 云端播放进度旁路上报器。
///
/// # 为什么单独一个类
///
/// 本地进度（`VideoProgressStore`）是**权威**：它必须每次都能落盘。
/// 云端上报是**尽力而为**：平台可能没这个能力（红果）、可能没登录、
/// 可能风控、可能网络抖。这些失败一个都不该影响本地进度，
/// 也不该弹给用户。
///
/// 所以这里做的三件事：
///  1. **节流**：同一视频最短 [minInterval] 才发一次（默认 30s）。
///     播放进度每秒都在变，不节流就是每秒一个请求，一定把平台打死
///     ——B站实测连续第 6 个请求起返回 412（见 scanFoldersContainingVideo）。
///  2. **失败静默**：任何异常都吞掉（只记一条不含凭证的 debug 日志）。
///     云端没同步成功，用户下次打开还有本地进度接着看。
///  3. **会话缓存**：按平台缓存 `CredentialVault.load` 的结果，
///     避免每 30 秒打一次安全存储。
///
/// # 能力边界（必须如实）
///
/// 只有 `supportsCloudProgress` 为 true 的平台会上报。
/// 当前是 **B站**（`/x/v2/history/report`，实测 code=0，进度单位是秒）。
/// 抖音**故意不报**：`play/progress` 匿名返回 `code=5 参数不合法`，
/// 连调用页面自己的上报函数也一样（那个函数被 `isLogin` 门控），
/// 没有登录态就无法验证一次真正的 code=0，按「不伪造成功」不接入。
library;

import 'dart:async';

import '../adapters/platform_adapter.dart';
import 'credential_vault.dart';
import 'errors.dart';
import 'logger.dart';
import 'video_service.dart';

/// 会话缓存条目（含"这个平台确实没登录"这一否定结果）。
class _SessionEntry {
  const _SessionEntry(this.session, this.at);
  final PlatformSession? session;
  final DateTime at;
}

class CloudProgressReporter {
  CloudProgressReporter({
    required VideoService service,
    required CredentialVault vault,
    FusionLogger? logger,
    this.minInterval = const Duration(seconds: 30),

    /// 会话缓存有效期。导入 Cookie 后最迟这么久生效。
    this.sessionTtl = const Duration(minutes: 5),
  })  : _service = service,
        _vault = vault,
        _logger = logger ?? appLogger;

  final VideoService _service;
  final CredentialVault _vault;
  final FusionLogger _logger;
  final Duration minInterval;
  final Duration sessionTtl;

  /// videoId → 上次成功发起上报的时刻。
  final Map<String, DateTime> _lastReport = {};

  /// platformId → 会话缓存。
  final Map<String, _SessionEntry> _sessions = {};

  /// videoId → 在飞的上报（同一视频不并发发两次）。
  final Set<String> _inFlight = {};

  /// 尝试上报。所有失败都被吞掉，**永不抛**。
  ///
  /// [videoId] 是统一视频 id（本地进度与去重都用它），
  /// [platformVideoId] 是平台侧 id（真正发给平台的值）。
  void maybeReport({
    required String videoId,
    required String platformId,
    required String platformVideoId,
    required Duration position,
    required Duration duration,
  }) {
    try {
      // 能力检查：不支持就什么都不做（也不记节流时刻）。
      if (!_service.supportsCloudProgressFor(platformId)) return;

      final now = DateTime.now();
      final last = _lastReport[videoId];
      if (last != null && now.difference(last) < minInterval) return;
      if (_inFlight.contains(videoId)) return;

      // 先看会话缓存：没登录就整个跳过，不打安全存储。
      final cached = _sessions[platformId];
      final cacheFresh =
          cached != null && now.difference(cached.at) < sessionTtl;
      final knownNull = cacheFresh && cached!.session == null;
      if (knownNull) return;

      unawaited(_run(
        videoId: videoId,
        platformId: platformId,
        platformVideoId: platformVideoId,
        position: position,
        duration: duration,
        now: now,
        cachedSession: cacheFresh ? cached!.session : null,
      ));
    } catch (e) {
      // 这个类**不得**因为自己的异常影响播放。
      _logger.debug('cloud progress: scheduling failed', {
        'platform': platformId,
        'errorType': e.runtimeType.toString(),
      });
    }
  }

  Future<void> _run({
    required String videoId,
    required String platformId,
    required String platformVideoId,
    required Duration position,
    required Duration duration,
    required DateTime now,
    PlatformSession? cachedSession,
  }) async {
    _inFlight.add(videoId);
    // 先占节流窗口：即使这次失败，也不要在下一秒又发一次。
    _lastReport[videoId] = now;
    try {
      final session = cachedSession ?? await _loadSession(platformId);
      if (session == null) return; // 未登录：静默跳过

      // 用平台标识直接发：这个旁路只需要 platformId + platformVideoId，
      // 不需要完整的视频实体。
      await _service.reportPlaybackProgress(
        platformId,
        platformVideoId: platformVideoId,
        position: position,
        duration: duration,
        session: session,
      );
    } on FusionException catch (e) {
      // 登录失效：清缓存，下次重新读；其余错误只记日志。
      if (e.code == FusionErrorCode.loginRequired) {
        _sessions.remove(platformId);
      }
      _logger.debug('cloud progress: report not accepted', {
        'platform': platformId,
        'code': e.code.name,
      });
    } catch (e) {
      _logger.debug('cloud progress: report failed', {
        'platform': platformId,
        'errorType': e.runtimeType.toString(),
      });
    } finally {
      _inFlight.remove(videoId);
    }
  }

  Future<PlatformSession?> _loadSession(String platformId) async {
    final entry = _sessions[platformId];
    if (entry != null &&
        DateTime.now().difference(entry.at) < sessionTtl) {
      return entry.session;
    }
    PlatformSession? session;
    try {
      session = await _vault
          .load(platformId)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      // 安全存储抖动：按"未登录"处理，不缓存失败以外的语义
      session = null;
    }
    _sessions[platformId] = _SessionEntry(session, DateTime.now());
    return session;
  }

  /// 登录态变化时调用（导入/清除 Cookie）：丢掉会话缓存，
  /// 同时清掉节流窗口，让刚登录上的账号能立刻开始上报。
  void invalidateSessions() {
    _sessions.clear();
    _lastReport.clear();
  }
}
