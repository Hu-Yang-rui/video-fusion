/// 红果端到端验证：走真实的适配器代码路径，拉真实网络。
///
/// 跑法：
///   dart run tool/verify_hongguo_e2e.dart
///
/// 验证内容：
///  1. 首页剧集列表
///  2. 剧集详情 + 分集
///  3. 1080p 播放直链（含 CDN 可播性）
///  4. 分集进度隔离
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/media_client.dart';
import 'package:video_fusion/src/adapters/hongguo_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

void main() {
  test('红果端到端：首页 → 详情 → 1080p → CDN 可播', () async {
  final logger = FusionLogger(enabled: false);
  final http = FusionHttpClient();

  // ── 1. 首页剧集 ──────────────────────────────────────────
  print('[1] 首页剧集列表');
  final adapter = HongguoAdapter(http: http, logger: logger);
  List<dynamic> series;
  try {
    series = await adapter.fetchSeriesList();
    print('    ✅ 拉到 ${series.length} 部');
    for (final s in series.take(3)) {
      print('       · ${s.title}（${s.episodeCount ?? "?"} 集）');
    }
  } catch (e) {
    print('    ❌ $e');
    return;
  }

  // ── 2. 详情 + 分集 ───────────────────────────────────────
  print('\n[2] 剧集详情 + 分集');
  final seriesId = series.first.seriesId as String;
  dynamic detail;
  try {
    detail = await adapter.fetchSeriesDetail(seriesId);
    print('    ✅ ${detail.title}');
    print('       共 ${detail.episodes.length} 集');
    print('       第 1 集 vid: ${detail.episodes.first.vid}');
  } catch (e) {
    print('    ❌ $e');
    return;
  }

  // ── 3. 1080p 播放直链 ────────────────────────────────────
  print('\n[3] 播放直链（请求 1080p）');

  try {
    final source = await adapter.resolvePlayback(PlaybackRequest(
      platformVideoId: '${detail.seriesId}#1',
      canonicalUrl: 'https://hongguoduanju.com/player/$seriesId',
      preferredMode: PlaybackMode.native,
      preferQuality: 1080,
    ));

    if (source is NativePlaybackSource) {
      print('    ✅ 选中档位: ${source.quality?.label}');
      print('       分辨率: ${source.quality?.width}x${source.quality?.height}');
      print('       可选档位: ${source.availableQualities.map((q) => q.label).join(" / ")}');
      print('       直链 host: ${Uri.parse(source.videoStreamUrl).host}');

      // 验证 CDN 可播
      print('\n[4] CDN 可播性验证');
      final res = await http.get(
        source.videoStreamUrl,
        headers: const {'range': 'bytes=0-65535'},
        timeout: const Duration(seconds: 30),
        keepRawBytes: true,
      );
      final bytes = res.rawBytes ?? Uint8List(0);
      print('    HTTP ${res.statusCode}，拿到 ${bytes.length} 字节');
      if (bytes.length >= 12) {
        final isFtyp = bytes[4] == 0x66 &&
            bytes[5] == 0x74 &&
            bytes[6] == 0x79 &&
            bytes[7] == 0x70;
        print('    ${isFtyp ? "✅" : "❌"} ftyp 标志: $isFtyp（标准 MP4）');
      }
    } else {
      print('    ⚠️ 返回类型: ${source.runtimeType}');
    }
  } catch (e) {
    print('    ❌ $e');
  }

  // ── 5. 分集进度隔离 ──────────────────────────────────────
  print('\n[5] 分集进度标识');
  for (var i = 1; i <= 3; i++) {
    final ep = adapter.episodeVideo(
      seriesId: seriesId,
      seriesTitle: detail.title as String,
      episodeIndex: i,
      totalEpisodes: detail.episodes.length as int,
    );
    print('    第 $i 集 id: ${ep.id}');
  }

  // ── 6. 多集覆盖验证 ──────────────────────────────────────
  print('\n[6] 多集 1080p 覆盖（抽 4 集）');
  final client = HongguoMediaClient(http: http, logger: logger);
  final sampleIdx = [0, 20, 40, detail.episodes.length - 1];
  var ok = 0;
  for (final idx in sampleIdx) {
    if (idx >= detail.episodes.length) continue;
    final vid = detail.episodes[idx].vid as String;
    try {
      final media = await client.fetchEpisodeMedia(vid);
      final has1080 = media.qualities.any((q) => q.height >= 1080);
      print('    第 ${idx + 1} 集: ${media.qualities.length} 档'
          '${has1080 ? "，含 1080p ✅" : ""}');
      if (has1080) ok++;
    } catch (e) {
      print('    第 ${idx + 1} 集: ❌ ${"$e".split("\n").first}');
    }
  }

  print('\n═══════════════════════════════════════════════════════');
  print('结果: ${ok}/${sampleIdx.length} 集有 1080p');
  print('═══════════════════════════════════════════════════════');

  });
}
