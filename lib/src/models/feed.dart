/// 推荐流契约。
///
/// 产品定位为中心化短视频平台，主界面是**全屏竖滑视频流**，
/// 内容来自各平台公开的推荐/榜单接口。
///
/// 重要边界（与需求文档一致）：
///  - 本系统**不实现自己的推荐算法**。这里只是消费平台已有的
///    公开推荐/榜单接口，属于"内容获取"，不是"推荐算法"。
///  - 不实现个性化排序、用户画像或行为埋点。
///  - 分页必须有限，避免无限翻页对平台造成压力。
library;

import '../models/unified_video.dart';

/// 推荐流的一次分页结果。
class FeedPage {
  const FeedPage({
    required this.items,
    required this.hasMore,
    required this.adapterId,
    required this.upstreamEndpoint,
    this.nextOffset = 0,
    this.notes = const [],
  });

  /// 本页视频（已标准化）。
  final List<UnifiedVideo> items;

  /// 是否还有更多内容。
  final bool hasMore;

  /// 提供该页的适配器 id。
  final String adapterId;

  /// 实际使用的上游接口标识（用于报告，不含凭证）。
  final String upstreamEndpoint;

  /// 下一页游标。
  final int nextOffset;

  /// 诊断说明（已脱敏）。
  final List<String> notes;

  bool get isEmpty => items.isEmpty;
}

/// 推荐流请求。
class FeedRequest {
  const FeedRequest({
    this.pageSize = 12,
    this.offset = 0,
    this.freshIndex = 1,
  });

  /// 每页条数。限制在合理范围内，避免过度请求。
  final int pageSize;

  /// 翻页游标（各平台语义不同，由适配器解释）。
  final int offset;

  /// 推荐刷新轮次（B 站 rcmd 的 fresh_idx）。
  final int freshIndex;

  /// 归一化后的页大小，硬性夹在 [4, 30] 之间。
  int get safePageSize => pageSize.clamp(4, 30);
}

/// 推荐流来源描述，供 UI 展示"内容来源"切换。
class FeedSource {
  const FeedSource({
    required this.id,
    required this.adapterId,
    required this.label,
    required this.description,
    this.requiresAuth = false,
    this.available = true,
    this.unavailableReason,
  });

  /// 来源稳定标识，例如 'bilibili:rcmd'。
  final String id;

  /// 归属适配器。
  final String adapterId;

  /// 面向用户的名称，例如 '推荐'。
  final String label;

  /// 说明文字。
  final String description;

  /// 是否需要登录。
  final bool requiresAuth;

  /// 当前是否可用（依据实测结果）。
  final bool available;

  /// 不可用原因（面向用户）。
  final String? unavailableReason;
}
