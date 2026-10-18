/// 直播：列表页（支持多平台）。
///
/// 数据来源：[PlatformAdapter.fetchLiveRooms]。
/// 只展示平台真实返回的房间，不做任何本地伪造。
///
/// # 多平台
///
/// [adapters] 传入所有 `supportsLive` 的适配器。
///  - 只有一个平台时不显示平台切换（B站单独接入时的原样）
///  - 多个平台时在标题下显示平台胶囊，切换即换数据源
///
/// **每个平台的分区、房间号类型、是否支持筛选都不同**，
/// 因此切换平台时会把分区与列表一并重置，不混用状态。
library;

import 'package:flutter/material.dart';

import '../../adapters/platform_adapter.dart';
import '../../core/errors.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/live.dart';
import 'live_room_screen.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({
    super.key,
    required this.adapters,
    this.initialAdapterId,
    this.onOpenOriginal,
  });

  /// 所有支持直播的平台适配器。至少一个。
  final List<PlatformAdapter> adapters;

  /// 初始选中的平台 id。为 null 时用第一个。
  final String? initialAdapterId;

  /// 打开原平台直播间（兜底入口）。
  final void Function(PlatformAdapter adapter, LiveRoomSummary room)?
      onOpenOriginal;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  final List<LiveRoomSummary> _rooms = [];
  final List<LiveArea> _areas = [];

  late PlatformAdapter _adapter;

  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  bool _loadedOnce = false;
  FusionException? _error;

  /// 当前选中的一级分区（null = 全部）。
  int? _areaId;

  /// 列表代际。切换平台/刷新时递增，用于让旧请求的结果作废——
  /// 否则慢的旧平台响应会覆盖新平台列表（"切过去看到的是上一个平台的内容"）。
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _adapter = widget.adapters.firstWhere(
      (a) => a.id == widget.initialAdapterId,
      orElse: () => widget.adapters.first,
    );
    _scroll.addListener(_onScroll);
    _loadAreas();
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _load();
    }
  }

  Future<void> _loadAreas() async {
    final adapter = _adapter;
    try {
      final areas = await adapter.fetchLiveAreas();
      // 期间切换了平台：丢弃
      if (!mounted || adapter.id != _adapter.id) return;
      setState(() {
        _areas
          ..clear()
          ..addAll(areas);
      });
    } catch (_) {
      // 分区失败不影响列表，静默降级为"全部"
      if (!mounted) return;
      setState(() => _areas.clear());
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (!reset && !_hasMore) return;

    final adapter = _adapter;
    final generation = reset ? ++_generation : _generation;

    setState(() {
      _loading = true;
      if (reset) {
        _error = null;
        _page = 1;
        _hasMore = true;
      }
    });

    try {
      final page = await adapter.fetchLiveRooms(
        page: reset ? 1 : _page,
        pageSize: 20,
        parentAreaId: _areaId,
      );
      // 期间切换了平台：丢弃这次结果
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _rooms.clear();
        _rooms.addAll(page.items);
        _page = (reset ? 1 : _page) + 1;
        _hasMore = page.hasMore;
        _loadedOnce = true;
        _error = null;
      });
    } on FusionException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = e);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = normalizeError(e, platformId: adapter.id));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _selectArea(int? id) {
    if (_areaId == id) return;
    setState(() => _areaId = id);
    _load(reset: true);
  }

  void _selectPlatform(PlatformAdapter adapter) {
    if (adapter.id == _adapter.id) return;
    // 平台不同 → 分区、列表、分页全部重置，绝不混用
    _generation++;
    setState(() {
      _adapter = adapter;
      _rooms.clear();
      _areas.clear();
      _areaId = null;
      _page = 1;
      _hasMore = true;
      _loadedOnce = false;
      _error = null;
      _loading = false;
    });
    _loadAreas();
    _load(reset: true);
  }

  Future<void> _openRoom(LiveRoomSummary room) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveRoomScreen(
          adapter: _adapter,
          roomKey: room.roomKey,
          initialTitle: room.title,
          initialUname: room.uname,
          onOpenOriginal:
              widget.onOpenOriginal == null
                  ? null
                  : () => widget.onOpenOriginal!(_adapter, room),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpace.lg,
                AppleSpace.md,
                AppleSpace.lg,
                AppleSpace.sm,
              ),
              child: Row(
                children: [
                  Text(
                    '直播',
                    style: AppleType.largeTitle.copyWith(color: c.label),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => _load(reset: true),
                    icon: Icon(
                      Icons.refresh_rounded,
                      color: c.secondaryLabel,
                      size: 20,
                    ),
                    tooltip: '刷新',
                  ),
                ],
              ),
            ),

            // 平台切换（仅当接入多个直播平台时显示）
            if (widget.adapters.length > 1)
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppleSpace.lg,
                  ),
                  children: [
                    for (final adapter in widget.adapters)
                      _AreaChip(
                        label: adapter.displayName,
                        selected: adapter.id == _adapter.id,
                        onTap: () => _selectPlatform(adapter),
                      ),
                  ],
                ),
              ),

            // 分区筛选
            if (_areas.isNotEmpty)
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppleSpace.lg,
                  ),
                  children: [
                    _AreaChip(
                      label: '全部',
                      selected: _areaId == null,
                      onTap: () => _selectArea(null),
                    ),
                    for (final area in _areas)
                      _AreaChip(
                        label: area.name,
                        selected: _areaId == area.id,
                        onTap: () => _selectArea(area.id),
                      ),
                  ],
                ),
              ),

            const SizedBox(height: AppleSpace.sm),

            Expanded(child: _buildBody(c)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppleColors c) {
    if (_loading && _rooms.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null && _rooms.isEmpty) {
      return AppleErrorState(
        title: '直播加载失败',
        message: _error!.userMessage,
        onRetry: () => _load(reset: true),
      );
    }

    if (_loadedOnce && _rooms.isEmpty) {
      return const AppleEmptyState(
        title: '暂无直播',
        message: '当前分区没有正在直播的房间。',
        icon: Icons.live_tv_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(
          AppleSpace.lg,
          AppleSpace.sm,
          AppleSpace.lg,
          AppleSpace.xxxl,
        ),
        itemCount: _rooms.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppleSpace.lg),
        itemBuilder: (context, index) {
          final room = _rooms[index];
          return _LiveRoomCard(
            // 用 roomKey 而不是 roomId：抖音房间号是 19 位字符串
            key: ValueKey<String>(room.roomKey),
            room: room,
            onTap: () => _openRoom(room),
          );
        },
      ),
    );
  }
}

/// 分区筛选胶囊。
class _AreaChip extends StatelessWidget {
  const _AreaChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: AppleSpace.sm),
      child: GestureDetector(
        onTap: onTap,
        // opaque：胶囊内部有 Padding 与文字，默认 translucent 会让
        // 点击落在空白处时穿透到下层。这里显式要求整个矩形可点。
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? c.label : c.fill,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: AppleType.footnote.copyWith(
              color: selected ? c.background : c.secondaryLabel,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 直播房间卡片（单列大卡）。
///
/// # 为什么是单列大封面
///
/// 之前是两列网格、`childAspectRatio: 0.82`，实测在 1080p 手机上
/// 每张卡只有约 168dp 宽，封面被压到 168×205，标题要挤两行、
/// 主播名再占一行，信息密度过高且封面看不清。
///
/// 直播是**内容消费**场景，封面本身就是最重要的信息（主播状态、
/// 画面内容、是否在打比赛）。因此改为单列：
///  - 封面 16:9 大图（约 344×194dp），占据卡片主体
///  - 封面内叠加：左上「直播」角标、右下在线人数
///  - 封面下两行信息：标题（1 行）、主播名 + 分区（1 行）
///
/// 这与主流短视频/直播产品的列表一致，不再是"工具面板"式的密集格子。
class _LiveRoomCard extends StatelessWidget {
  const _LiveRoomCard({
    super.key,
    required this.room,
    required this.onTap,
  });

  final LiveRoomSummary room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 封面 16:9 ──────────────────────────────────
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppleRadius.lg),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (room.coverUrl != null)
                    Image.network(
                      room.coverUrl!,
                      fit: BoxFit.cover,
                      // 大卡需要更高分辨率，但仍在合理范围
                      cacheWidth: 800,
                      // 加载中显示占位色，避免闪白
                      frameBuilder: (_, child, frame, sync) {
                        if (sync || frame != null) return child;
                        return ColoredBox(color: c.fill);
                      },
                      errorBuilder: (_, _, _) => ColoredBox(color: c.fill),
                    )
                  else
                    ColoredBox(color: c.fill),

                  // 底部渐变，保证角标可读
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0x66000000)],
                        stops: [0.55, 1.0],
                      ),
                    ),
                  ),

                  // 左上：直播中角标
                  Positioned(
                    left: 8,
                    top: 8,
                    child: _LiveBadge(),
                  ),

                  // 右下：在线人数
                  if (room.online != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: _ViewerCount(count: room.online!),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: AppleSpace.sm),

          // ── 标题（单行，超出省略）─────────────────────
          Text(
            room.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppleType.subheadlineEmphasized.copyWith(
              color: c.label,
              height: 1.3,
            ),
          ),

          const SizedBox(height: 3),

          // ── 主播 + 分区 ────────────────────────────────
          Row(
            children: [
              // 主播小头像
              if (room.faceUrl != null)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: ClipOval(
                    child: Image.network(
                      room.faceUrl!,
                      width: 16,
                      height: 16,
                      fit: BoxFit.cover,
                      cacheWidth: 48,
                      errorBuilder: (_, _, _) => const SizedBox(
                        width: 16,
                        height: 16,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  room.uname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppleType.caption1.copyWith(color: c.secondaryLabel),
                ),
              ),
              if (room.areaName != null) ...[
                const SizedBox(width: AppleSpace.sm),
                Text(
                  room.areaName!,
                  style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 「直播中」角标。
class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 4,
            height: 4,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 3),
          const Text(
            '直播',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 在线人数角标。
class _ViewerCount extends StatelessWidget {
  const _ViewerCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.visibility_outlined,
            size: 10,
            color: Colors.white70,
          ),
          const SizedBox(width: 3),
          Text(
            _formatOnline(count),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatOnline(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}