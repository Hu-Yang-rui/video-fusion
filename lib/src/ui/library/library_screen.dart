/// 媒体库页：观看历史、继续观看（Apple 风格）。
///
/// 数据全部来自本地存储（用户自己的行为记录），不上传任何服务器。
/// 观看进度由播放器在播放时回调写入，是真实数据而非占位。
library;

import 'package:flutter/material.dart';

import '../../core/video_progress_store.dart';
import '../../core/video_service.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_controls.dart';
import '../../design/components/apple_layout.dart';
import '../../design/components/video_widgets.dart';
import '../../models/unified_video.dart';

/// 媒体库页。
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.service,
    required this.progressStore,
    required this.onOpenVideo,
  });

  final VideoService service;
  final VideoProgressStore progressStore;

  /// 打开视频。[resumeAt] 为续播位置（可能为 null）。
  final void Function(UnifiedVideo video, Duration? resumeAt) onOpenVideo;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _tab = 0;
  List<UnifiedVideo> _videos = const [];
  Map<String, WatchProgress> _progress = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final videos = await widget.service.listVideos();
    final records = await widget.progressStore.all();
    if (!mounted) return;
    setState(() {
      _videos = videos;
      _progress = {for (final r in records) r.videoId: r};
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    final visible = _tab == 0
        ? _videos
        : _videos
            .where((v) => _progress[v.id]?.isResumable ?? false)
            .toList();

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            AppleLargeTitleHeader(
              title: '媒体库',
              subtitle: _tab == 0
                  ? '${_videos.length} 个视频'
                  : '${visible.length} 个可续播',
              trailing: AppleIconButton(
                icon: Icons.refresh_rounded,
                onPressed: _load,
                color: c.label,
              ),
            ),

            // 分段切换
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppleSpace.pageInset,
              ),
              child: AppleSegmentedControl<int>(
                segments: const [0, 1],
                selected: _tab,
                onChanged: (v) => setState(() => _tab = v),
                labelOf: (v) => v == 0 ? '全部' : '继续观看',
              ),
            ),

            const SizedBox(height: AppleSpace.md),

            Expanded(
              child: _loading
                  ? const Center(child: AppleSpinner())
                  : _buildList(c, visible),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(AppleColors c, List<UnifiedVideo> list) {
    if (list.isEmpty) {
      return AppleEmptyState(
        icon: Icons.bookmark_outline_rounded,
        title: _tab == 0 ? '媒体库是空的' : '没有可续播的视频',
        message: _tab == 0
            ? '通过链接导入视频，或从推荐流打开视频后，会出现在这里。'
            : '观看过但没看完的视频会出现在这里。',
      );
    }

    return ListView.separated(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom +
            AppleSize.tabBar +
            AppleSpace.xl,
      ),
      itemCount: list.length,
      separatorBuilder: (_, __) => Padding(
        padding: const EdgeInsets.only(left: 164),
        child: Container(height: 0.5, color: c.separator),
      ),
      itemBuilder: (context, i) {
        final v = list[i];
        final record = _progress[v.id];
        return VideoListTile(
          video: v,
          progress: record?.ratio,
          onTap: () => widget.onOpenVideo(
            v,
            record != null && record.isResumable ? record.position : null,
          ),
          trailing: AppleIconButton(
            icon: Icons.chevron_right_rounded,
            onPressed: () => widget.onOpenVideo(v, null),
            color: c.tertiaryLabel,
            size: 18,
          ),
        );
      },
    );
  }
}
