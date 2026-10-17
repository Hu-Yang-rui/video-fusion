/// 真实环境验证：推荐流 + 扫码登录 + 竖滑流播放链路。
///
/// 运行：dart run tool/smoke_feed.dart
///
/// 全部使用**真实网络请求**，不使用任何模拟数据。
library;

import 'dart:io';

import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/adapters/mock_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/qr_login.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/models/unified_video.dart';

int _pass = 0;
int _fail = 0;

void check(String label, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  [PASS] $label${detail != null ? ' — $detail' : ''}');
  } else {
    _fail++;
    stdout.writeln('  [FAIL] $label${detail != null ? ' — $detail' : ''}');
  }
}

Future<void> main() async {
  final logger = FusionLogger(minLevel: LogLevel.warn);
  final http = FusionHttpClient(logger: logger);
  final registry = PlatformRegistry(adapters: [
    BilibiliAdapter(http: http, logger: logger),
    DouyinAdapter(http: http, logger: logger),
    MockAdapter(http: http, logger: logger),
  ]);
  final service = VideoService(
    registry: registry,
    store: VideoStore(storage: InMemoryStore(), logger: logger),
    logger: logger,
  );

  stdout.writeln('=' * 74);
  stdout.writeln('推荐流 / 扫码登录 / 竖滑流播放链路 — 真实环境验证');
  stdout.writeln('=' * 74);

  // ── 1. 内容来源清单 ────────────────────────────────────────
  stdout.writeln('\n[1] 内容来源清单');
  final sources = service.describeFeedSources();
  for (final s in sources) {
    stdout.writeln('    ${s.id.padRight(22)} ${s.label.padRight(10)} '
        '${s.available ? "可用" : "不可用"}');
  }
  check('存在内容来源', sources.isNotEmpty);
  check('B站推荐可用', sources.any((s) => s.id == 'bilibili:rcmd' && s.available));
  check('抖音推荐如实标记不可用',
      sources.any((s) => s.id == 'douyin:recommend' && !s.available));

  // ── 2. B站推荐流（真实网络）────────────────────────────────
  stdout.writeln('\n[2] B站推荐流（真实网络）');
  final rcmd = await service.fetchFeed('bilibili:rcmd',
      request: const FeedRequest(pageSize: 12));
  check('推荐流拉取成功', rcmd.ok, rcmd.error?.technicalMessage);
  check('返回条目非空', rcmd.items.isNotEmpty, '${rcmd.items.length} 条');

  if (rcmd.items.isNotEmpty) {
    final first = rcmd.items.first;
    stdout.writeln('    首条：${first.title}');
    stdout.writeln('         作者=${first.author.name} 时长=${first.durationLabel} '
        '播放=${first.stats.viewCount}');
    stdout.writeln('         bvid=${first.platformVideoId} 封面=${first.coverUrl != null}');
    check('首条有 bvid', first.platformVideoId.startsWith('BV'));
    check('首条有标题', first.title.isNotEmpty);
    check('首条有作者', first.author.name != null);
    check('首条有封面', first.coverUrl != null);
    check('首条有播放量', first.stats.viewCount != null);
    check('ID 格式正确', first.id == 'bilibili:${first.platformVideoId}');
    check('声明应用内播放', first.playbackModes.contains(PlaybackMode.native));
    // 推荐流不返回宽高，必须如实为 null 而不是编造
    check('宽高如实为 null（推荐流不提供）',
        first.width == null && first.height == null);
  }

  // ── 3. 分页 ────────────────────────────────────────────────
  stdout.writeln('\n[3] 推荐流分页');
  final page2 = await service.fetchFeed('bilibili:rcmd',
      request: const FeedRequest(pageSize: 12, offset: 1));
  check('第二页拉取成功', page2.ok);
  if (page2.ok && rcmd.ok) {
    final firstIds = rcmd.items.map((v) => v.id).toSet();
    final secondIds = page2.items.map((v) => v.id).toSet();
    check('第二页与第一页不同',
        firstIds.intersection(secondIds).isEmpty,
        '重叠 ${firstIds.intersection(secondIds).length} 条');
    stdout.writeln('    第二页 ${page2.items.length} 条，hasMore=${page2.hasMore}');
  }

  // ── 4. 热门 / 排行榜 ───────────────────────────────────────
  stdout.writeln('\n[4] 其它来源');
  final popular = await service.fetchFeed('bilibili:popular',
      request: const FeedRequest(pageSize: 8));
  check('热门流可用', popular.ok && popular.items.isNotEmpty,
      '${popular.items.length} 条');

  final ranking = await service.fetchFeed('bilibili:ranking',
      request: const FeedRequest(pageSize: 8));
  check('排行榜可用', ranking.ok && ranking.items.isNotEmpty,
      '${ranking.items.length} 条');

  // ── 5. 竖滑流播放链路：对推荐流首条解析播放源 ───────────────
  stdout.writeln('\n[5] 竖滑流播放链路（推荐流首条 → 播放源）');
  if (rcmd.items.isNotEmpty) {
    final video = rcmd.items.first;
    final outcome = await service.resolvePlayback(video);
    check('播放源解析成功', outcome.ok, outcome.error?.technicalMessage);

    if (outcome.source is NativePlaybackSource) {
      final src = outcome.source! as NativePlaybackSource;
      stdout.writeln('    清晰度=${src.quality?.label} '
          '(${src.quality?.width}x${src.quality?.height})');
      stdout.writeln('    DASH=${src.isDash} 音轨=${src.audioStreamUrl != null}');
      stdout.writeln('    请求头=${src.requiredHeaders.keys.toList()}');
      stdout.writeln('    视频源 host=${Uri.parse(src.videoStreamUrl).host}');

      check('可应用内播放', src.mode == PlaybackMode.native);
      check('是媒体地址非网页', !src.videoStreamUrl.contains('/video/BV'));
      check('携带防盗链 Referer',
          src.requiredHeaders.containsKey('Referer'));
      check('播放阶段获得真实宽高',
          src.quality?.width != null && src.quality?.height != null);

      // 用真实 Range 请求验证可拉流（带 Referer）
      await _probeStream('推荐流首条视频轨', src.videoStreamUrl,
          src.requiredHeaders);
      if (src.audioStreamUrl != null) {
        await _probeStream('推荐流首条音频轨', src.audioStreamUrl!,
            src.requiredHeaders);
      }
    } else {
      check('返回 NativePlaybackSource', false, '${outcome.source.runtimeType}');
    }
  }

  // ── 6. 扫码登录流程（真实网络，不完成登录）─────────────────
  stdout.writeln('\n[6] 扫码登录流程（真实网络）');
  final bili = registry.byId('bilibili') as BilibiliAdapter;
  try {
    final challenge = await bili.requestQrChallenge();
    stdout.writeln('    二维码内容长度=${challenge.qrContent.length}');
    stdout.writeln('    挑战键长度=${challenge.challengeKey.length}');
    stdout.writeln('    内容前缀=${challenge.qrContent.substring(0, 48)}…');
    check('二维码申请成功', challenge.qrContent.isNotEmpty);
    check('挑战键非空', challenge.challengeKey.isNotEmpty);
    check('二维码内容为 URL', challenge.qrContent.startsWith('http'));

    // 轮询一次（未扫码状态）
    final poll = await bili.pollQrChallenge(challenge);
    stdout.writeln('    轮询状态=${poll.phase.name} 提示=${poll.message}');
    check('轮询返回未扫码状态',
        poll.phase == QrLoginPhase.waitingForScan ||
            poll.phase == QrLoginPhase.waitingForConfirm);
    check('未扫码时不返回凭证', poll.cookies.isEmpty);
  } catch (e) {
    check('扫码登录流程', false, '$e');
  }

  // ── 7. 抖音：如实报告不可用 ────────────────────────────────
  stdout.writeln('\n[7] 抖音推荐流（应如实失败）');
  final dy = await service.fetchFeed('douyin:recommend');
  check('抖音推荐流返回失败而非空列表', !dy.ok);
  check('错误为权限类', dy.error?.code == FusionErrorCode.permissionDenied);
  check('错误不可重试', dy.error?.retryable == false);
  if (dy.error != null) {
    stdout.writeln('    错误=${dy.error!.userMessage}');
    stdout.writeln('    诊断=${dy.error!.diagnostics}');
  }

  // ── 8. 模拟流（离线，验证分页边界）─────────────────────────
  stdout.writeln('\n[8] 模拟测试流（本地，无网络）');
  final mock = await service.fetchFeed('mock:local',
      request: const FeedRequest(pageSize: 6));
  check('模拟流可用', mock.ok && mock.items.isNotEmpty,
      '${mock.items.length} 条');
  check('模拟数据带测试标记',
      mock.items.every((v) => v.title.startsWith('【测试】')));

  final mockLast = await service.fetchFeed('mock:local',
      request: const FeedRequest(pageSize: 6, offset: 2));
  check('末页 hasMore=false', mockLast.ok && !mockLast.hasMore);

  // ── 9. 故障隔离 ────────────────────────────────────────────
  stdout.writeln('\n[9] 故障隔离');
  final bad = await service.fetchFeed('nonexistent:source');
  check('未知来源返回错误', !bad.ok);
  final after = await service.fetchFeed('bilibili:rcmd',
      request: const FeedRequest(pageSize: 6));
  check('失败后其它来源仍可用', after.ok && after.items.isNotEmpty);

  _summary();
}

Future<void> _probeStream(
  String label,
  String url,
  Map<String, String> headers,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    headers.forEach(req.headers.set);
    req.headers.set('Range', 'bytes=0-2047');
    final resp = await req.close();
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final hex = bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    final isFtyp = hex.contains('66 74 79 70');
    stdout.writeln('    [$label] status=${resp.statusCode} bytes=${bytes.length} '
        'ftyp=$isFtyp');
    check('$label 可拉流', resp.statusCode == 206 || resp.statusCode == 200,
        'status=${resp.statusCode}');
    check('$label 返回真实媒体', isFtyp, 'hex=$hex');
  } catch (e) {
    check('$label 可拉流', false, '$e');
  } finally {
    client.close(force: true);
  }
}

void _summary() {
  stdout.writeln('\n${'=' * 74}');
  stdout.writeln('结果：$_pass 通过 / $_fail 失败');
  stdout.writeln('=' * 74);
  exit(_fail == 0 ? 0 : 1);
}
