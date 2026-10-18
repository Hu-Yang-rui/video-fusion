/// 发现页：长视频浏览与搜索（Apple 风格浅色界面）。
///
/// 设计意图：
///  - 短视频靠"推荐流"消费，长视频靠"主动发现"消费，两者场景不同。
///  - 这里提供：分类切换、网格浏览、搜索、下拉刷新、分页加载。
///  - 使用 Apple 的分组与留白建立层级，不做卡片堆叠。
///
/// 内容来源全部来自平台真实接口，不使用任何假数据。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';
import '../../design/components/video_widgets.dart';
import '../../models/feed.dart';
import '../../models/unified_video.dart';

/// 发现页。
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({
    super.key,
    required this.service,
    required this.onOpenVideo,
    this.onOpenSourcePicker,
    this.onOpenLinkIntake,
  });

  final VideoService service;
  final void Function(UnifiedVideo) onOpenVideo;
  final VoidCallback? onOpenSourcePicker;

  /// 打开「链接接入」面板。
  ///
  /// 该能力原先挂在短视频顶栏（一个加链图标），
  /// 属于工具语义、且占用视频画面，已移到本页工具栏。
  final VoidCallback? onOpenLinkIntake;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  List<FeedSource> _sources = const [];
  FeedSource? _active;

  final List<UnifiedVideo> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  FusionException? _error;
  bool _searchMode = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadSources();
  }

  void _loadSources() {
    final all = widget.service.describeFeedSources();
    // 发现页优先展示"热门/排行榜/搜索"类来源，推荐流留给竖滑页
    final discoverable = all.where((s) => s.available).toList();
    setState(() {
      _sources = discoverable;
      _active = discoverable.isNotEmpty ? discoverable.first : null;
    });
    if (_active != null) _reload();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (_scroll.offset >= max - 400) {
      _loadMore();
    }
  }

  Future<void> _reload() async {
    final source = _active;
    if (source == null || _loading) return;

    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
      _offset = 0;
      _hasMore = true;
    });

    final result = await widget.service.fetchFeed(
      source.id,
      request: FeedRequest(offset: 0, pageSize: 20),
    );

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok) {
        _items.addAll(result.items);
        _hasMore = result.hasMore;
        _offset = result.nextOffset;
      } else {
        _error = result.error;
      }
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _active == null) return;
    setState(() => _loadingMore = true);

    final result = await widget.service.fetchFeed(
      _active!.id,
      request: FeedRequest(offset: _offset, pageSize: 20),
    );

    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (result.ok) {
        // 去重
        final existing = _items.map((v) => v.id).toSet();
        final fresh = result.items.where((v) => !existing.contains(v.id));
        _items.addAll(fresh);
        _hasMore = result.hasMore;
        _offset = result.nextOffset;
      } else {
        _hasMore = false;
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 大标题
            AppleLargeTitleHeader(
              title: '发现',
              subtitle: _searchMode
                  ? '搜索「$_query」'
                  : (_active?.label ?? '浏览长视频'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onOpenLinkIntake != null && !_searchMode)
                    AppleIconButton(
                      icon: Icons.add_link_rounded,
                      onPressed: widget.onOpenLinkIntake,
                      color: c.label,
                    ),
                  AppleIconButton(
                    icon: _searchMode
                        ? Icons.close_rounded
                        : Icons.search_rounded,
                    onPressed: () {
                      setState(() {
                        _searchMode = !_searchMode;
                        if (!_searchMode) {
                          _searchCtrl.clear();
                          _query = '';
                          _reload();
                        }
                      });
                    },
                    color: c.label,
                  ),
                ],
              ),
            ),

            // 搜索栏
            if (_searchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppleSpace.pageInset,
                  0,
                  AppleSpace.pageInset,
                  AppleSpace.md,
                ),
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  style: AppleType.body.copyWith(color: c.label),
                  decoration: InputDecoration(
                    hintText: '搜索视频',
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: c.secondaryLabel,
                    ),
                    isDense: true,
                  ),
                  onSubmitted: (q) {
                    final text = q.trim();
                    if (text.isEmpty) return;
                    setState(() => _query = text);
                    _performSearch(text);
                  },
                ),
              ),

            // 分类切换
            if (!_searchMode && _sources.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppleSpace.pageInset,
                  ),
                  itemCount: _sources.length,
                  separatorBuilder: (_, __) => const SizedBox(width: AppleSpace.sm),
                  itemBuilder: (context, i) {
                    final s = _sources[i];
                    final selected = s.id == _active?.id;
                    return Center(
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _active = s);
                          _reload();
                        },
                        child: AnimatedContainer(
                          duration: AppleMotion.fast,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppleSpace.lg,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: selected ? c.blue : c.fill,
                            borderRadius:
                                BorderRadius.circular(AppleRadius.pill),
                          ),
                          child: Text(
                            s.label,
                            style: AppleType.footnoteEmphasized.copyWith(
                              color: selected ? Colors.white : c.label,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

            const SizedBox(height: AppleSpace.sm),

            // 内容
            Expanded(child: _buildBody(c)),
          ],
        ),
      ),
    );
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
      _hasMore = false;
    });

    final result = await widget.service.searchVideos(query, pageSize: 20);

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok) {
        _items.addAll(result.items);
      } else {
        _error = result.error;
      }
    });
  }

  Widget _buildBody(AppleColors c) {
    if (_loading) {
      return _buildSkeleton(c);
    }

    if (_error != null && _items.isEmpty) {
      return AppleErrorState(
        title: _error!.presentation.title,
        message: _error!.userMessage,
        onRetry: _searchMode ? () => _performSearch(_query) : _reload,
        secondaryLabel: '换个来源',
        onSecondary: widget.onOpenSourcePicker,
        details: _error!.retryable ? const ['该错误可重试'] : null,
      );
    }

    if (_items.isEmpty) {
      return AppleEmptyState(
        icon: Icons.video_library_outlined,
        title: _searchMode ? '没有找到相关视频' : '这个来源暂时没有内容',
        message: _searchMode
            ? '换个关键词试试，或者浏览其他内容来源。'
            : '可以切换到其他内容来源，或下拉刷新。',
        action: AppleSecondaryButton(
          label: '换个来源',
          onPressed: widget.onOpenSourcePicker,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _searchMode ? () async => _performSearch(_query) : _reload,
      color: c.blue,
      child: GridView.builder(
        controller: _scroll,
        padding: EdgeInsets.only(
          left: AppleSpace.pageInset,
          right: AppleSpace.pageInset,
          top: AppleSpace.xs,
          bottom: MediaQuery.paddingOf(context).bottom +
              AppleSize.tabBar +
              AppleSpace.xl,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: AppleSpace.lg,
          crossAxisSpacing: AppleSpace.md,
          childAspectRatio: 0.78,
        ),
        itemCount: _items.length + (_loadingMore ? 2 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                AspectRatio(
                  aspectRatio: 16 / 10,
                  child: AppleSkeleton(height: double.infinity),
                ),
                SizedBox(height: AppleSpace.sm),
                AppleSkeleton(height: 14),
                SizedBox(height: 6),
                AppleSkeleton(height: 12, width: 80),
              ],
            );
          }
          final v = _items[index];
          return VideoGridCard(
            video: v,
            onTap: () => widget.onOpenVideo(v),
          );
        },
      ),
    );
  }

  Widget _buildSkeleton(AppleColors c) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.pageInset,
        vertical: AppleSpace.xs,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: AppleSpace.lg,
        crossAxisSpacing: AppleSpace.md,
        childAspectRatio: 0.78,
      ),
      itemCount: 6,
      itemBuilder: (context, i) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: AppleSkeleton(height: double.infinity),
          ),
          SizedBox(height: AppleSpace.sm),
          AppleSkeleton(height: 14),
          SizedBox(height: 6),
          AppleSkeleton(height: 12, width: 90),
        ],
      ),
    );
  }
}
