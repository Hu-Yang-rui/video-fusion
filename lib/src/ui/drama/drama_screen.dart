/// 影视页：短剧 / 真人剧 / 漫剧 / AI 剧。
///
/// 与「推荐」页的定位区别：
///
///  - 推荐：短视频沉浸式刷，一屏一个，上下滑
///  - 影视：找剧、挑剧、看剧，网格浏览 + 分类切换
///
/// 数据来自各适配器注册的 `FeedSource`，按平台分组展示。
library;

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';
import '../../design/components/video_widgets.dart';
import '../../models/feed.dart';
import '../../models/unified_video.dart';
import '../shell/app_shell.dart' show tabBarInsets;

/// 影视页。
class DramaScreen extends StatefulWidget {
  const DramaScreen({super.key, required this.service, this.onOpenVideo});

  final VideoService service;

  /// 点击剧集后的回调。为 null 时点击无响应。
  final ValueChanged<UnifiedVideo>? onOpenVideo;

  @override
  State<DramaScreen> createState() => _DramaScreenState();
}

class _DramaScreenState extends State<DramaScreen> {
  List<FeedSource> _sources = const [];
  FeedSource? _active;
  List<UnifiedVideo> _items = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  void _boot() {
    // 先渲染，再异步读数据：避免 SecureStore 超时导致整页空白。
    final all = widget.service.describeFeedSources();
    // 只保留「长内容」来源：红果短剧的分类与首页
    final drama = all.where(_isDramaSource).toList();
    if (!mounted) return;
    setState(() {
      _sources = drama;
      _active = drama.isEmpty ? null : drama.first;
    });
    if (drama.isNotEmpty) {
      _load(drama.first);
    }
  }

  /// 判断某个来源是否属于影视页。
  ///
  /// 红果的 id 形如 `hongguo:home` / `hongguo:category:real-drama`。
  static bool _isDramaSource(FeedSource s) {
    if (s.adapterId == 'hongguo') return true;
    // 其它平台的影视来源可按需扩展
    return false;
  }

  Future<void> _load(FeedSource source) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.service.fetchFeed(
        source.id,
        request: const FeedRequest(offset: 0, pageSize: 60),
      );
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _loading = false;
      });
    } on FusionException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _items = const [];
        _loading = false;
      });
    } catch (e) {
      appLogger.warn('drama: load failed', {'sourceId': source.id, 'error': '$e'});
      if (!mounted) return;
      setState(() {
        _error = '加载失败，请稍后重试。';
        _items = const [];
        _loading = false;
      });
    }
  }

  void _select(FeedSource source) {
    if (_active?.id == source.id) return;
    setState(() {
      _active = source;
      _items = const [];
    });
    _load(source);
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
            _header(c),
            if (_sources.length > 1) _sourceBar(c),
            Expanded(child: _body(c)),
          ],
        ),
      ),
    );
  }

  Widget _header(AppleColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpace.pageInset,
        AppleSpace.sm,
        AppleSpace.pageInset,
        AppleSpace.xs,
      ),
      child: Row(
        children: [
          Text(
            '影视',
            style: AppleType.largeTitle.copyWith(
              color: c.label,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          if (_loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _sourceBar(AppleColors c) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppleSpace.pageInset),
        itemCount: _sources.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppleSpace.xs),
        itemBuilder: (context, i) {
          final s = _sources[i];
          final active = s.id == _active?.id;
          return Center(
            child: GestureDetector(
              onTap: () => _select(s),
              child: AnimatedContainer(
                duration: AppleMotion.fast,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpace.md,
                  vertical: AppleSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: active ? c.label : c.fill,
                  borderRadius: BorderRadius.circular(AppleRadius.pill),
                ),
                child: Text(
                  s.label,
                  style: AppleType.subheadline.copyWith(
                    color: active ? c.groupedBackground : c.label,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _body(AppleColors c) {
    if (_error != null) {
      return AppleEmptyState(
        title: '暂时取不到内容',
        message: _error!,
        icon: Icons.cloud_off_rounded,
      );
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const AppleEmptyState(
        title: '还没有内容',
        message: '这个分类暂时没有可显示的剧集。',
        icon: Icons.movie_outlined,
      );
    }

    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        AppleSpace.pageInset,
        AppleSpace.sm,
        AppleSpace.pageInset,
        tabBarInsets(context).bottom + AppleSpace.lg,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.52,
        crossAxisSpacing: AppleSpace.sm,
        mainAxisSpacing: AppleSpace.md,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) => _card(c, _items[i]),
    );
  }

  Widget _card(AppleColors c, UnifiedVideo v) {
    final episodes = v.diagnostics.notes
        .where((n) => n.startsWith('共 ') && n.endsWith(' 集'))
        .firstOrNull;

    return GestureDetector(
      onTap: widget.onOpenVideo == null
          ? null
          : () => widget.onOpenVideo!(v),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppleRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (v.coverUrl != null && v.coverUrl!.isNotEmpty)
                    Image.network(
                      v.coverUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _placeholder(c),
                      loadingBuilder: (context, child, progress) =>
                          progress == null ? child : _placeholder(c),
                    )
                  else
                    _placeholder(c),
                  if (episodes != null)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          episodes.replaceAll('共 ', '').replaceAll(' 集', ' 集'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppleSpace.xxs),
          Text(
            v.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppleType.caption1.copyWith(
              color: c.label,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(AppleColors c) => ColoredBox(
        color: c.fill,
        child: Icon(
          Icons.movie_outlined,
          color: c.tertiaryLabel,
          size: 28,
        ),
      );
}
