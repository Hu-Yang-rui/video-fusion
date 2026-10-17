/// 平台注册表：适配器的唯一注册与查找入口。
///
/// 约束：
///  - 平台判断不得散落在整个应用中。所有平台识别都经过本注册表。
///  - 不得使用不断增长的硬编码条件分支控制业务。
///  - 新增平台只需注册新适配器，无需改动统一列表/详情/导航。
library;

import '../core/errors.dart';
import 'platform_adapter.dart';

class PlatformRegistry {
  PlatformRegistry({List<PlatformAdapter> adapters = const []}) {
    for (final adapter in adapters) {
      register(adapter);
    }
  }

  final Map<String, PlatformAdapter> _byId = {};

  /// 按注册顺序返回全部适配器（决定链接识别的匹配顺序）。
  List<PlatformAdapter> get adapters => List.unmodifiable(_byId.values);

  int get length => _byId.length;

  bool get isEmpty => _byId.isEmpty;

  /// 注册适配器。重复 id 会抛错，避免静默覆盖导致行为不可预期。
  void register(PlatformAdapter adapter) {
    if (_byId.containsKey(adapter.id)) {
      throw FusionException(
        code: FusionErrorCode.internalError,
        userMessage: '平台适配器注册冲突。',
        technicalMessage: 'Duplicate adapter id: ${adapter.id}',
        platformId: adapter.id,
      );
    }
    _byId[adapter.id] = adapter;
  }

  PlatformAdapter? byId(String id) => _byId[id];

  /// 按 id 获取适配器；不存在时抛 [FusionException]。
  PlatformAdapter require(String id) {
    final adapter = _byId[id];
    if (adapter == null) {
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台尚未接入。',
        technicalMessage: 'No adapter registered for platformId=$id',
        platformId: id,
      );
    }
    return adapter;
  }

  /// 依据链接找到适配器。返回 null 表示无平台匹配。
  ///
  /// 注意：这是唯一的"链接 → 平台"判定入口。UI 层不得自行做域名判断。
  PlatformAdapter? match(Uri uri) {
    for (final adapter in _byId.values) {
      if (adapter.matches(uri)) return adapter;
    }
    return null;
  }

  /// 全部平台的可接入来源描述（用于首页"来源区域"展示）。
  List<PlatformDescriptor> describeAll() => _byId.values
      .map((a) => PlatformDescriptor(
            id: a.id,
            displayName: a.displayName,
            shortLabel: a.shortLabel,
            hosts: a.supportedHosts,
            capabilities: a.capabilities,
          ))
      .toList(growable: false);
}

/// 平台来源描述，供 UI 展示"已接入的平台"。
class PlatformDescriptor {
  const PlatformDescriptor({
    required this.id,
    required this.displayName,
    required this.shortLabel,
    required this.hosts,
    required this.capabilities,
  });

  final String id;
  final String displayName;
  final String shortLabel;
  final List<String> hosts;
  final AdapterCapabilities capabilities;

  Map<String, Object?> toJson() => {
        'id': id,
        'displayName': displayName,
        'shortLabel': shortLabel,
        'hosts': hosts,
        'capabilities': capabilities.toJson(),
      };
}
