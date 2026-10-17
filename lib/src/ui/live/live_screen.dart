/// B 站直播：列表页。
///
/// 数据来源：[PlatformAdapter.fetchLiveRooms]（`room/v3/area/getRoomList`）。
/// 只展示平台真实返回的房间，不做任何本地伪造。
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
    required this.adapter,
    this.onOpenOriginal,
  });

  final PlatformAdapter adapter;

  /// 打开原平台直播间（兜底入口）。
  final void Function(LiveRoomSummary room)? onOpenOriginal;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();

  final List<LiveRoomSummary> _rooms = [];
  final List<LiveArea> _areas = [];

  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  bool _loadedOnce = false;
  FusionException? _error;

  /// 当前选中的一级分区（null = 全部）。
  int? _areaId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
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
    try {
      final areas = await widget.adapter.fetchLiveAreas();
      if (!mounted) return;
      setState(() {
        _areas
          ..clear()
          ..addAll(areas);
      });
    } catch (_) {
      // 分区失败不影响列表，静默降级为"全部"
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (!reset && !_hasMore) return;

    setState(() {
      _loading = true;
      if (reset) {
        _error = null;
        _page = 1;
        _hasMore = true;
      }
    });

    try {
      final page = await widget.adapter.fetchLiveRooms(
        page: reset ? 1 : _page,
        pageSize: 20,
        parentAreaId: _areaId,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _rooms.clear();
        _rooms.addAll(page.items);
        _page = (reset ? 1 : _page) + 1;
        _hasMore = page.hasMore;
        _loadedOnce = true;
        _error = null;
      });
    } on FusionException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = normalizeError(e, platformId: 'bilibili'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectArea(int? id) {
    if (_areaId == id) return;
    setState(() => _areaId = id);
    _load(reset: true);
  }

  Future<void> _openRoom(LiveRoomSummary room) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveRoomScreen(
          adapter: widget.adapter,
          roomId: room.roomId,
          initialTitle: room.title,
          initialUname: room.uname,
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
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(
          AppleSpace.lg,
          AppleSpace.sm,
          AppleSpace.lg,
          AppleSpace.xxxl,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: AppleSpace.md,
          crossAxisSpacing: AppleSpace.md,
          childAspectRatio: 0.82,
        ),
        itemCount: _rooms.length,
        itemBuilder: (context, index) {
          final room = _rooms[index];
          return _LiveRoomCard(
            key: ValueKey<int>(room.roomId),
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

/// 直播房间卡片。
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppleRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (room.coverUrl != null)
                    Image.network(
                      room.coverUrl!,
                      fit: BoxFit.cover,
                      // 限制解码尺寸，避免网格里多张原图同时解码
                      cacheWidth: 480,
                      errorBuilder: (_, _, _) => ColoredBox(color: c.fill),
                    )
                  else
                    ColoredBox(color: c.fill),

                  // 直播中标记
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
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
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 人气
                  if (room.online != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          _formatOnline(room.online!),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 标题
          Text(
            room.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppleType.footnote.copyWith(
              color: c.label,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 2),
          // 主播 + 分区
          Row(
            children: [
              Icon(Icons.person_outline_rounded, size: 11, color: c.tertiaryLabel),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  room.uname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
                ),
              ),
            ],
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
