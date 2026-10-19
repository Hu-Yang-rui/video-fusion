/// 互动状态的**跨页面共享登记表**。
///
/// # 为什么需要它（根因）
///
/// 在这一层出现之前，每个页面各自 `new InteractionController(video: ...)`：
///  - 推荐页用 `Map<videoId, InteractionController>`（`feed_screen.dart`）
///  - 详情页再建一个（`video_detail_screen.dart`）
///  - 两者互不知情
///
/// 后果是**同一视频在两个入口的点赞/收藏状态不一致**：在推荐流里点了收藏，
/// 进详情页仍显示未收藏；反之亦然。每个控制器都会各自发一次
/// `archive/relation`，既重复请求又各自缓存一份可能过期的状态。
///
/// # 本登记表做什么
///
///  - 以 **视频唯一 ID**（`platformId:platformVideoId`，即 `UnifiedVideo.id`）
///    为键复用同一个 [InteractionController]，全 App 一份。
///  - 引用计数：最后一个持有者释放时才 `dispose`，避免内存泄漏，
///    也避免"另一个页面还在用就被释放"。
///  - **登录态变化时批量校准**：导入 Cookie / 退出登录后，所有存活的
///    控制器重新拉取服务端状态，而不是继续显示登录前的 unknown。
///
/// # 不做的事
///
///  - 不做乐观更新（写成功后仍由控制器重新拉服务端状态）
///  - 不做本地持久化（收藏关系以服务端为准，本地缓存只在会话期内）
library;

import 'package:flutter/foundation.dart';

import '../../core/credential_vault.dart';
import '../../core/video_service.dart';
import '../../models/unified_video.dart';
import 'interaction_controller.dart';

class InteractionRegistry {
  InteractionRegistry({
    required VideoService service,
    required CredentialVault vault,
  })  : _service = service,
        _vault = vault;

  final VideoService _service;
  final CredentialVault _vault;

  /// 已注册的会话数据。
  final Map<String, InteractionController> _controllers = {};

  /// 每个会话的持有者数量（页面数）。
  final Map<String, int> _refs = {};

  /// 测试与诊断用：当前存活的会话数。
  @visibleForTesting
  int get activeCount => _controllers.length;

  /// 取得已登记的会话（不增加引用）。
  ///
  /// 页面已经持有某视频的引用时，重复构建直接走这里取回同一个实例，
  /// 避免 `itemBuilder` 多次调用导致引用计数虚高。
  InteractionController? peek(String videoId) => _controllers[videoId];

  /// 取得（并按需创建）某视频的互动会话。
  ///
  /// **必须与 [release] 成对调用**。返回的实例是共享的，
  /// 调用方不得 `dispose` 它 —— 由登记表在引用归零时统一释放。
  InteractionController acquire(UnifiedVideo video) {
    final id = video.id;
    final existing = _controllers[id];
    if (existing != null) {
      _refs[id] = (_refs[id] ?? 1) + 1;
      return existing;
    }

    final created = InteractionController(
      video: video,
      service: _service,
      vault: _vault,
    );
    _controllers[id] = created;
    _refs[id] = 1;
    // 异步初始化（读登录态 → 拉服务端状态），不阻塞首帧
    created.init();
    return created;
  }

  /// 释放一个持有者。引用归零时销毁会话并从登记表移除。
  void release(String videoId) {
    final n = (_refs[videoId] ?? 1) - 1;
    if (n > 0) {
      _refs[videoId] = n;
      return;
    }
    _refs.remove(videoId);
    _controllers.remove(videoId)?.dispose();
  }

  /// 登录态变化后校准所有存活会话。
  ///
  /// 由设置页在「Cookie 导入成功 / 退出登录 / 扫码登录成功」后调用。
  /// 不调用的话，已打开的推荐流会继续显示"登录后可操作"，
  /// 用户必须切走再切回才能看到真实的点赞/收藏状态。
  Future<void> recalibrateAll() async {
    final snapshot = _controllers.values.toList();
    for (final c in snapshot) {
      await c.reloadSession();
    }
  }

  /// 丢弃所有会话（退出登录时调用，确保不会残留上一个账号的状态）。
  ///
  /// 保留引用计数：页面还活着，下一次访问会重新创建并重新 init。
  void invalidateAll() {
    for (final id in _controllers.keys.toList()) {
      _controllers.remove(id)?.dispose();
    }
    _refs.clear();
  }

  /// 由页面在 dispose 里统一调用；正常路径用 [release]。
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _refs.clear();
  }
}
