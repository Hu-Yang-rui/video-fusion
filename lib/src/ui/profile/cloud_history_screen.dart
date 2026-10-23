/// 云端观看历史页。
///
/// # 与「观看历史」的区别
///
///  - 本页是**平台账号侧**的记录，跨设备同步，来自平台接口；
///  - 「我的 → 观看历史」是**本设备**的播放进度（`VideoProgressStore`），
///    换设备就没有。
///
/// 两者刻意分开：把本机进度冒充云端历史会让用户以为换了手机也能接着看。
library;

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../core/credential_vault.dart';
import '../../models/unified_video.dart';

/// 云端观看历史页。
class CloudHistoryScreen extends StatefulWidget {
  const CloudHistoryScreen({
    super.key,
    required this.service,
    required this.session,
    this.onOpenVideo,
  });

  final VideoService service;
  final PlatformSession session;
  final ValueChanged<UnifiedVideo>? onOpenVideo;

  @override
  State<CloudHistoryScreen> createState() => _CloudHistoryScreenState();
}

class _CloudHistoryScreenState extends State<CloudHistoryScreen> {
  /// 平台中文名（空态文案用）。
  ///
  /// 不写死「B 站」：现在 B 站与抖音都提供云端历史，
  /// 提示必须是当前账号所属平台，否则抖音用户会以为没同步成功。
  static String _platformLabel(String platformId) => switch (platformId) {
        'bilibili' => 'B 站',
        'douyin' => '抖音',
        _ => platformId,
      };

  final List<UnifiedVideo> _items = [];
  final ScrollController _scroll = ScrollController();

  bool _loading = false;
  bool _loadedOnce = false;
  bool _hasMore = true;
  int _cursor = 0;
  int _generation = 0;
  FusionException? _error;

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
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 320) _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (!reset && !_hasMore) return;

    final generation = reset ? ++_generation : _generation;
    setState(() {
      _loading = true;
      if (reset) {
        _error = null;
        _cursor = 0;
        _hasMore = true;
      }
    });

    try {
      final result = await widget.service.fetchHistoryVideos(
        widget.session.platformId,
        session: widget.session,
        pageSize: 20,
        cursor: reset ? 0 : _cursor,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _items.clear();
        // 去重：翻页时平台可能重复下发同一条
        final seen = _items.map((v) => v.id).toSet();
        for (final v in result.items) {
          if (seen.add(v.id)) _items.add(v);
        }
        _cursor = result.nextCursor;
        _hasMore = result.hasMore;
        _loadedOnce = true;
        _error = null;
      });
    } on FusionException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = e);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(
        () => _error = normalizeError(e, platformId: widget.session.platformId),
      );
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
        title: const Text('云端历史'),
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.label,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _loading ? null : () => _load(reset: true),
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: '刷新',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: _body(c),
      ),
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
      return AppleEmptyState(
        icon: Icons.history_rounded,
        title: '还没有观看记录',
        message: '在${_platformLabel(widget.session.platformId)}看过的视频'
            '会出现在这里，跨设备同步。',
      );
    }

    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: AppleSpace.xxxl),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const AppleDivider(indent: 68),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return Padding(
            padding: const EdgeInsets.all(AppleSpace.lg),
            child: Center(
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: _load,
                      child: const Text('加载更多'),
                    ),
            ),
          );
        }
        return _HistoryRow(
          video: _items[index],
          onTap: widget.onOpenVideo == null
              ? null
              : () => widget.onOpenVideo!(_items[index]),
        );
      },
    );
  }
}

/// 历史条目行。
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.video, this.onTap});

  final UnifiedVideo video;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    // 进度与观看时间都在 diagnostics.notes 里
    //  - B 站条目带「看到 01:23 / 05:00」（平台下发 progress）
    //  - 抖音条目带「观看于 2026-10-22 19:30」（history/read 的 aweme_date）
    // 两者都显示：前者是"接着看"的依据，后者是时间线。
    final progressNote = video.diagnostics.notes
        .where((n) => n.startsWith('看到 '))
        .firstOrNull;
    final timeNote = video.diagnostics.notes
        .where((n) => n.startsWith('观看于 '))
        .firstOrNull;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.pageInset,
          vertical: AppleSpace.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppleRadius.xs),
              child: SizedBox(
                width: 112,
                height: 63,
                child: video.coverUrl != null && video.coverUrl!.isNotEmpty
                    ? Image.network(
                        video.coverUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => ColoredBox(color: c.fill),
                        loadingBuilder: (context, child, p) =>
                            p == null ? child : ColoredBox(color: c.fill),
                      )
                    : ColoredBox(color: c.fill),
              ),
            ),
            const SizedBox(width: AppleSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.subheadline.copyWith(
                      color: c.label,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (video.author.name != null)
                    Text(
                      video.author.name!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppleType.caption1.copyWith(
                        color: c.secondaryLabel,
                      ),
                    ),
                  if (progressNote != null || timeNote != null) ...[
                    const SizedBox(height: 2),
                    // 两条都在时合成一行：「看到 02:00 / 58:31 · 观看于 …」
                    Text(
                      [
                        if (progressNote != null) progressNote,
                        if (timeNote != null) timeNote,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppleType.caption2.copyWith(
                        color: c.tertiaryLabel,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
