/// 稍后再看列表（平台真实数据）。
///
/// 数据来自平台接口（B站 `/x/v2/history/toview/web`），不是本地收藏的副本。
/// 平台不支持时页面直接说明"该平台未提供该能力"，不显示空列表冒充"没有内容"。
library;

import 'package:flutter/material.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/unified_video.dart';

class WatchLaterScreen extends StatefulWidget {
  const WatchLaterScreen({
    super.key,
    required this.service,
    required this.session,
    this.onOpenVideo,
  });

  final VideoService service;
  final PlatformSession session;
  final void Function(UnifiedVideo video)? onOpenVideo;

  @override
  State<WatchLaterScreen> createState() => _WatchLaterScreenState();
}

class _WatchLaterScreenState extends State<WatchLaterScreen> {
  final List<UnifiedVideo> _items = [];
  final ScrollController _scroll = ScrollController();

  bool _loading = false;
  bool _hasMore = true;
  bool _loadedOnce = false;
  int _page = 1;
  FusionException? _error;
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
      final result = await widget.service.fetchWatchLaterVideos(
        widget.session.platformId,
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
        title: const Text('稍后再看'),
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.label,
      ),
      body: _body(c),
    );
  }

  Widget _body(AppleColors c) {
    // 平台能力不支持：说明原因，而不是显示空列表
    if (!widget.service.capabilitiesFor(widget.session.platformId).watchLater) {
      return AppleEmptyState(
        title: '该平台暂不支持稍后再看',
        message: '${widget.session.displayName} 未提供可在本应用内使用的'
            '稍后再看接口。',
        icon: Icons.schedule_rounded,
      );
    }

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
        title: '稍后再看是空的',
        message: '在视频互动面板里选择「稍后再看」，它会出现在这里。',
        icon: Icons.schedule_rounded,
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: AppleSpace.xxxl),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const AppleDivider(indent: AppleSpace.lg),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(AppleSpace.lg),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final v = _items[index];
          return AppleListRow(
            title: v.title,
            subtitle: [
              if (v.author.name != null) v.author.name!,
              if (v.durationSeconds != null) _fmt(v.durationSeconds!.round()),
            ].where((s) => s.isNotEmpty).join(' · '),
            showChevron: true,
            onTap: () => widget.onOpenVideo?.call(v),
            leading: v.coverUrl == null
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(AppleRadius.xs),
                    child: Image.network(
                      v.coverUrl!,
                      width: 56,
                      height: 34,
                      fit: BoxFit.cover,
                      cacheWidth: 112,
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: c.fill,
                        child: const SizedBox(width: 56, height: 34),
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }

  static String _fmt(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m >= 60) {
      return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}'
          ':${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
