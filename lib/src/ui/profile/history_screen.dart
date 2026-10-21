/// 观看历史页（本机真实播放进度）。
///
/// 数据来自 [VideoProgressStore]：记录的是**本设备上实际播放到的位置**，
/// 不是平台的观看记录接口，因此不跨设备同步。页面上必须写清这一点，
/// 否则用户会以为换了设备还能接着看。
library;

import 'package:flutter/material.dart';

import '../../core/video_progress_store.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.progressStore});

  final VideoProgressStore progressStore;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<WatchProgress> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await widget.progressStore.all();
    if (!mounted) return;
    setState(() {
      _items = all;
      _loading = false;
    });
  }

  Future<void> _remove(WatchProgress p) async {
    await widget.progressStore.remove(p.videoId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        title: const Text('观看历史'),
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.label,
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await _confirmClear();
                if (ok != true) return;
                await widget.progressStore.clear();
                await _load();
              },
              child: Text('清空', style: TextStyle(color: c.red)),
            ),
        ],
      ),
      body: _body(c),
    );
  }

  Widget _body(AppleColors c) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_items.isEmpty) {
      return const AppleEmptyState(
        title: '还没有观看记录',
        message: '在应用里播放过的视频会出现在这里，并可从上次位置继续。',
        icon: Icons.history_rounded,
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: AppleSpace.xxxl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppleSpace.pageInset,
            AppleSpace.sm,
            AppleSpace.pageInset,
            AppleSpace.sm,
          ),
          child: Text(
            '进度来自本设备实际播放位置，不是平台的观看记录，'
            '因此不会跨设备同步。',
            style: AppleType.caption1.copyWith(color: c.secondaryLabel),
          ),
        ),
        AppleGroupedSection(
          children: [
            for (var i = 0; i < _items.length; i++) ...[
              if (i > 0) const AppleDivider(),
              AppleListRow(
                title: _items[i].displayTitle,
                subtitle: '${_fmt(_items[i].position)} / '
                    '${_fmt(_items[i].duration)}'
                    '${_items[i].isFinished ? ' · 已看完' : ''}',
                trailingText: _percent(_items[i]),
                onTap: () => Navigator.pop(context, _items[i]),
                leading: IconButton(
                  iconSize: 18,
                  color: c.tertiaryLabel,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => _remove(_items[i]),
                  tooltip: '删除该记录',
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<bool?> _confirmClear() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('清空观看历史？'),
          content: const Text('只清除本设备上的进度记录，不影响平台侧数据。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空'),
            ),
          ],
        ),
      );

  static String _title(String videoId) {
    final i = videoId.indexOf(':');
    if (i < 0) return videoId;
    final platform = switch (videoId.substring(0, i)) {
      'bilibili' => 'B 站',
      'douyin' => '抖音',
      final p => p,
    };
    return '$platform · ${videoId.substring(i + 1)}';
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  static String _percent(WatchProgress p) {
    final r = p.ratio;
    if (r <= 0) return '';
    return '${(r * 100).clamp(0, 100).toStringAsFixed(0)}%';
  }
}
