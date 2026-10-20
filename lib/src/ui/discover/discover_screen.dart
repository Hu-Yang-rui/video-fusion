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

  /// 请求代际号：每次"换来源 / 换关键词 / 刷新"递增。
  ///
  /// # 为什么必须有它（真实缺陷）
  ///
  /// 发现页有三个并发入口：分类切换、下拉刷新、搜索。它们都写同一组
  /// `_items` / `_offset` / `_error`。没有代际号时：
  ///   - 用户点分类 A → 请求发出
  ///   - 立刻点分类 B → 请求发出，`_items.clear()`
  ///   - **A 的响应后到** → 把 A 的内容写进"B 的列表"
  ///
  /// 表现为"点了 B 却显示 A 的视频"，且下拉刷新后可能变成两者混杂。
  /// 递增代际号后，旧响应回来直接丢弃。
  int _generation = 0;

  /// 当前是否处于"用户主动切换"的状态（决定是否显示整页骨架）。
  ///
  /// 关键：**刷新已有内容时不显示骨架**，否则列表会闪一下空白再回来，
  /// 这是发现页"点视频前页面跳动"的观感来源之一。
  bool get _showSkeleton => _loading && _items.isEmpty;

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
    if (source == null) return;

    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _offset = 0;
      _hasMore = true;
      // 换来源 / 刷新时清空，避免旧内容与新内容混杂
      _items.clear();
    });

    final result = await widget.service.fetchFeed(
      source.id,
      request: FeedRequest(offset: 0, pageSize: 20),
    );

    // 期间换了来源 / 又刷新了一次：丢弃
    if (!mounted || gen != _generation) return;
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
    final gen = _generation;
    setState(() => _loadingMore = true);

    final result = await widget.service.fetchFeed(
      _active!.id,
      request: FeedRequest(offset: _offset, pageSize: 20),
    );

    if (!mounted || gen != _generation) return;
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

  /// 网格代理：按**内容实际高度**算每格高度，而不是写死宽高比。
  ///
  /// # 为什么不能用固定 childAspectRatio（真实缺陷）
  ///
  /// 卡片内容是「16:10 封面 + 2 行标题 + 1 行作者」，文字高度会随
  /// 系统字号缩放变化。写死 `childAspectRatio: 0.78` 时：
  ///  - 默认字号下：格子 230dp，内容约 180dp → 底部多出 50dp 空白
  ///  - 系统字号 2.0 倍下：文字块涨到约 236dp > 230dp → **溢出**
  ///
  /// 溢出表现为黄黑条 / "BOTTOM OVERFLOWED"，且在小屏机上更容易触发。
  /// 改为 `mainAxisExtent`：用当前 `textScaler` 把标题与作者行的真实
  /// 高度算出来，再加上封面高度，格子永远刚好装得下内容。
  ///
  /// 这样也顺带解决了"底部留白过大"的观感问题。
  SliverGridDelegate _gridDelegate(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // 两列：减去左右 pageInset 与列间距后对半分
    final cardWidth =
        (width - AppleSpace.pageInset * 2 - AppleSpace.md) / 2;
    // 封面固定 16:10（与 VideoGridCard 的 AspectRatio 一致）
    final coverHeight = cardWidth * 10 / 16;

    final scaler = MediaQuery.textScalerOf(context);
    final titleSize = scaler.scale(AppleType.subheadline.fontSize ?? 15);
    final authorSize = scaler.scale(AppleType.caption1.fontSize ?? 12);
    // 标题 2 行（行高 1.35）+ 间距 3 + 作者 1 行（行高约 1.3）
    final textBlock = titleSize * 1.35 * 2 + 3 + authorSize * 1.3;

    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisSpacing: AppleSpace.lg,
      crossAxisSpacing: AppleSpace.md,
      mainAxisExtent: coverHeight + AppleSpace.sm + textBlock + 2,
    );
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
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
      _hasMore = false;
    });

    final result = await widget.service.searchVideos(query, pageSize: 20);

    if (!mounted || gen != _generation) return;
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
    // 只在"首次加载 / 换来源后还没内容"时显示骨架。
    // 已有内容时的刷新走 RefreshIndicator 的转圈，不替换整页 ——
    // 否则每次下拉都闪一次空白，观感像页面在跳。
    if (_showSkeleton) {
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
        gridDelegate: _gridDelegate(context),
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
      // 骨架与真实卡片用同一个代理：否则加载完成的一瞬间
      // 格子高度会变，列表整体跳动一下（这正是"进入前闪一下"的成因）。
      gridDelegate: _gridDelegate(context),
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
