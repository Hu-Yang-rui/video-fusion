/// 某个收藏夹里的真实内容列表。
///
/// 数据来源：`/x/v3/fav/resource/list`（翻页）。
/// 条目由适配器映射成 [UnifiedVideo]，因此点开后进详情页走的
/// 是**与推荐流完全相同的播放解析链路**，没有第二套播放实现。
library;

import 'package:flutter/material.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/unified_video.dart';
import 'favorites_screen.dart' show FavoriteFolderView;

class FavoriteVideosScreen extends StatefulWidget {
  const FavoriteVideosScreen({
    super.key,
    required this.service,
    required this.session,
    required this.folder,
    this.onOpenVideo,
  });

  final VideoService service;
  final PlatformSession session;
  final FavoriteFolderView folder;
  final void Function(UnifiedVideo video)? onOpenVideo;

  @override
  State<FavoriteVideosScreen> createState() => _FavoriteVideosScreenState();
}

class _FavoriteVideosScreenState extends State<FavoriteVideosScreen> {
  final List<UnifiedVideo> _items = [];
  final ScrollController _scroll = ScrollController();

  bool _loading = false;
  bool _hasMore = true;
  bool _loadedOnce = false;
  int _page = 1;
  FusionException? _error;

  /// 请求代际：刷新时递增，让旧的翻页响应作废。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
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

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (!reset && !_hasMore) return;

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
      final result = await widget.service.fetchFavoriteFolderVideos(
        widget.session.platformId,
        widget.folder.id,
        session: widget.session,
        page: reset ? 1 : _page,
        pageSize: 20,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(result.items);
        _page += 1;
        _hasMore = result.hasMore;
        _loadedOnce = true;
        _error = null;
      });
    } on FusionException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = e);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = normalizeError(e, platformId: widget.session.platformId));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        title: Text(
          widget.folder.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppleType.headline,
        ),
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.label,
      ),
      body: _body(c),
    );
  }

  Widget _body(AppleColors c) {
    if (_loading && _items.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null && _items.isEmpty) {
      return AppleErrorState(
        title: _error!.presentation.title,
        message: _error!.userMessage,
        onRetry: () => _load(reset: true),
      );
    }

    if (_loadedOnce && _items.isEmpty) {
      return const AppleEmptyState(
        title: '这个收藏夹是空的',
        message: '平台接口返回该收藏夹内没有内容。',
        icon: Icons.folder_open_rounded,
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(
          AppleSpace.pageInset,
          AppleSpace.sm,
          AppleSpace.pageInset,
          AppleSpace.xxxl,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.62,
          crossAxisSpacing: AppleSpace.md,
          mainAxisSpacing: AppleSpace.lg,
        ),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final v = _items[index];
          return _VideoGridTile(
            key: ValueKey<String>(v.id),
            video: v,
            onTap: () => widget.onOpenVideo?.call(v),
          );
        },
      ),
    );
  }
}

/// 网格条目：封面 + 标题 + UP 主 + 时长。
class _VideoGridTile extends StatelessWidget {
  const _VideoGridTile({
    super.key,
    required this.video,
    required this.onTap,
  });

  final UnifiedVideo video;
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
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppleRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (video.coverUrl != null)
                    Image.network(
                      video.coverUrl!,
                      fit: BoxFit.cover,
                      cacheWidth: 400,
                      frameBuilder: (_, child, frame, sync) =>
                          (sync || frame != null) ? child : ColoredBox(color: c.fill),
                      errorBuilder: (_, _, _) => ColoredBox(color: c.fill),
                    )
                  else
                    ColoredBox(color: c.fill),

                  // 时长角标（真实秒数，接口没有就不显示）
                  if (video.durationSeconds != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          _fmtDuration(video.durationSeconds!),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
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
          Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppleType.footnote.copyWith(
              color: c.label,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Text(
                  video.author.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppleType.caption2.copyWith(color: c.secondaryLabel),
                ),
              ),
              if (video.stats.viewCount != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.play_arrow_rounded,
                  size: 11,
                  color: c.tertiaryLabel,
                ),
                Text(
                  _fmt(video.stats.viewCount!),
                  style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtDuration(double seconds) {
    final t = seconds.round();
    final m = t ~/ 60;
    final s = t % 60;
    if (m >= 60) {
      return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}'
          ':${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _fmt(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}
