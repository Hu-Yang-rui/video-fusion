/// 收藏夹浏览页：真实夹列表 → 夹内真实内容。
///
/// 数据来源全部是平台接口：
///  - 夹列表：`/x/v3/fav/folder/created/list-all`（名称、内容数、公开/私密）
///  - 夹内内容：`/x/v3/fav/resource/list`（翻页）
///
/// **不显示任何本地伪造的"收藏"**，也不把某个夹的空状态写成"加载失败"。
library;

import 'package:flutter/material.dart';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/unified_video.dart';
import 'favorite_videos_screen.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({
    super.key,
    required this.service,
    required this.sessions,
    this.onOpenVideo,
  });

  final VideoService service;

  /// 当前已登录的平台会话（可多个平台）。
  final List<PlatformSession> sessions;

  final void Function(UnifiedVideo video)? onOpenVideo;

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  /// 当前选择的会话（多平台登录时）。
  PlatformSession? _session;

  bool _loading = false;
  FusionException? _error;
  bool _loadedOnce = false;

  /// 各夹的内容数直接来自接口（media_count），不是本地计数。
  List<FavoriteFolderView> _folders = const [];

  @override
  void initState() {
    super.initState();
    _session = widget.sessions.firstOrNull;
    _load();
  }

  Future<void> _load() async {
    final s = _session;
    if (s == null) return;
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final folders = await widget.service.fetchFavoriteFolders(
        s.platformId,
        session: s,
      );
      if (!mounted) return;
      setState(() {
        _folders = folders
            .map(
              (f) => FavoriteFolderView(
                id: f.id,
                title: f.title,
                mediaCount: f.mediaCount,
                isDefault: f.isDefault,
                isPublic: f.isPublic,
              ),
            )
            .toList();
        _loadedOnce = true;
        _loading = false;
      });
    } on FusionException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = normalizeError(e, platformId: s.platformId);
        _loading = false;
        _loadedOnce = true;
      });
    }
  }

  void _selectSession(PlatformSession s) {
    if (s.platformId == _session?.platformId) return;
    setState(() {
      _session = s;
      _folders = const [];
      _loadedOnce = false;
      _error = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        title: const Text('我的收藏夹'),
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.label,
      ),
      body: widget.sessions.isEmpty
          ? const AppleEmptyState(
              title: '未登录',
              message: '登录后才能查看该账号在平台上的收藏夹。',
              icon: Icons.star_outline_rounded,
            )
          : Column(
              children: [
                if (widget.sessions.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppleSpace.pageInset,
                      AppleSpace.sm,
                      AppleSpace.pageInset,
                      AppleSpace.sm,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: AppleSpace.sm,
                        children: [
                          for (final s in widget.sessions)
                            _Chip(
                              label: s.displayName.isEmpty
                                  ? s.platformId
                                  : s.displayName,
                              selected: s.platformId == _session?.platformId,
                              onTap: () => _selectSession(s),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: _body(c)),
              ],
            ),
    );
  }

  Widget _body(AppleColors c) {
    if (_loading && _folders.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null && _folders.isEmpty) {
      return AppleErrorState(
        title: _error!.presentation.title,
        message: _error!.userMessage,
        onRetry: _load,
      );
    }

    if (_loadedOnce && _folders.isEmpty) {
      return const AppleEmptyState(
        title: '还没有收藏夹',
        message: '当前账号在平台上没有可用的收藏夹。',
        icon: Icons.folder_open_rounded,
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppleSpace.xxxl),
        children: [
          AppleGroupedSection(
            children: [
              for (var i = 0; i < _folders.length; i++) ...[
                if (i > 0) const AppleDivider(),
                AppleListRow(
                  leadingIcon: Icons.folder_rounded,
                  leadingColor: _folders[i].isDefault ? c.orange : c.blue,
                  title: _folders[i].title,
                  subtitle: [
                    if (_folders[i].isDefault) '默认',
                    if (_folders[i].mediaCount != null)
                      '${_folders[i].mediaCount} 个内容',
                    if (!_folders[i].isPublic) '私密',
                  ].join(' · '),
                  trailingText: _folders[i].mediaCount?.toString(),
                  showChevron: true,
                  onTap: () => _openFolder(_folders[i]),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _openFolder(FavoriteFolderView f) {
    final s = _session;
    if (s == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FavoriteVideosScreen(
          service: widget.service,
          session: s,
          folder: f,
          onOpenVideo: widget.onOpenVideo,
        ),
      ),
    );
  }
}

/// 收藏夹视图模型（把适配器模型与 UI 解耦）。
class FavoriteFolderView {
  const FavoriteFolderView({
    required this.id,
    required this.title,
    this.mediaCount,
    this.isDefault = false,
    this.isPublic = true,
  });

  final int id;
  final String title;
  final int? mediaCount;
  final bool isDefault;
  final bool isPublic;
}

class _Chip extends StatelessWidget {
  const _Chip({
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
    return GestureDetector(
      onTap: onTap,
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
    );
  }
}
