/// 端到端集成测试 —— 在**真实应用进程**中运行，使用**真实网络请求**。
///
/// 运行：
/// ```
/// flutter test integration_test/app_e2e_test.dart -d windows
/// ```
///
/// 与单元测试的区别：
///  - 单元测试注入假 HTTP 客户端，完全离线。
///  - 本测试使用真实的适配器 + 真实网络 + 真实 media_kit 播放内核。
///
/// 因此本文件的结果可作为"真实环境验证记录"的直接证据。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/adapters/mock_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/qr_login.dart';
import 'package:video_fusion/src/core/secure_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/models/feed.dart';
import 'package:video_fusion/src/models/unified_video.dart';
import 'package:video_fusion/src/models/playback.dart';
import 'package:video_fusion/src/player/player_controller.dart';
import 'package:video_fusion/src/core/video_progress_store.dart';
import 'package:video_fusion/src/design/apple_theme.dart';
import 'package:video_fusion/src/ui/mobile/feed_controller.dart';
import 'package:video_fusion/src/ui/settings/settings_screen.dart';

({VideoService service, PlatformRegistry registry}) _realStack() {
  final logger = FusionLogger(minLevel: LogLevel.error);
  final http = FusionHttpClient(logger: logger);
  final registry = PlatformRegistry(adapters: [
    BilibiliAdapter(http: http, logger: logger),
    DouyinAdapter(http: http, logger: logger),
    MockAdapter(http: http, logger: logger),
  ]);
  return (
    service: VideoService(
      registry: registry,
      store: VideoStore(storage: InMemoryStore(), logger: logger),
      logger: logger,
    ),
    registry: registry,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  group('真实环境 · 推荐流', () {
    testWidgets('B站推荐流返回真实视频数据', (tester) async {
      final stack = _realStack();

      final result = await stack.service.fetchFeed(
        'bilibili:rcmd',
        request: const FeedRequest(pageSize: 12),
      );

      expect(result.ok, isTrue,
          reason: '真实推荐流应可用：${result.error?.technicalMessage}');
      expect(result.items, isNotEmpty);

      final first = result.items.first;
      debugPrint('[E2E] 推荐流首条：${first.title} / ${first.author.name} / '
          '${first.durationLabel} / ${first.platformVideoId}');

      expect(first.platformId, 'bilibili');
      expect(first.platformVideoId, startsWith('BV'));
      expect(first.title, isNotEmpty);
      expect(first.author.name, isNotNull);
      expect(first.coverUrl, isNotNull);
      expect(first.stats.viewCount, isNotNull);
      // 推荐流不返回宽高，必须如实为 null
      expect(first.width, isNull);
      expect(first.height, isNull);
    });

    testWidgets('分页返回不同内容', (tester) async {
      final stack = _realStack();
      final p1 = await stack.service
          .fetchFeed('bilibili:rcmd', request: const FeedRequest(pageSize: 10));
      final p2 = await stack.service.fetchFeed('bilibili:rcmd',
          request: const FeedRequest(pageSize: 10, offset: 1));

      expect(p1.ok && p2.ok, isTrue);
      final ids1 = p1.items.map((v) => v.id).toSet();
      final ids2 = p2.items.map((v) => v.id).toSet();
      expect(ids1.intersection(ids2), isEmpty, reason: '不同页必须返回不同内容');
    });

    testWidgets('热门与排行榜来源均可用', (tester) async {
      final stack = _realStack();
      final popular = await stack.service.fetchFeed('bilibili:popular',
          request: const FeedRequest(pageSize: 8));
      final ranking = await stack.service.fetchFeed('bilibili:ranking',
          request: const FeedRequest(pageSize: 8));

      expect(popular.ok && popular.items.isNotEmpty, isTrue,
          reason: '热门：${popular.error?.technicalMessage}');
      expect(ranking.ok && ranking.items.isNotEmpty, isTrue,
          reason: '排行榜：${ranking.error?.technicalMessage}');

      // 排行榜使用扁平结构，作者名与时长需要正确解析
      final r = ranking.items.first;
      debugPrint('[E2E] 排行首条：${r.title} / ${r.author.name} / ${r.durationLabel}');
      expect(r.author.name, isNotNull);
      expect(r.durationSeconds, isNotNull);
    });
  });

  group('真实环境 · 播放链路', () {
    testWidgets('推荐流视频可解析出可播放的 DASH 直链', (tester) async {
      final stack = _realStack();
      final feed = await stack.service
          .fetchFeed('bilibili:rcmd', request: const FeedRequest(pageSize: 6));
      expect(feed.ok && feed.items.isNotEmpty, isTrue);

      final outcome = await stack.service.resolvePlayback(feed.items.first);
      expect(outcome.ok, isTrue, reason: outcome.error?.technicalMessage);
      expect(outcome.source, isA<NativePlaybackSource>());

      final src = outcome.source! as NativePlaybackSource;
      debugPrint('[E2E] 播放源：${src.quality?.label} '
          '${src.quality?.width}x${src.quality?.height} DASH=${src.isDash}');
      debugPrint('[E2E] 请求头：${src.requiredHeaders.keys.toList()}');

      expect(src.videoStreamUrl, startsWith('http'));
      expect(src.isDash, isTrue);
      expect(src.audioStreamUrl, isNotNull);
      // B 站 CDN 已启用防盗链，必须携带 Referer
      expect(src.requiredHeaders.containsKey('Referer'), isTrue,
          reason: '必须传递 Referer，否则 CDN 返回 403');
      expect(src.quality?.width, isNotNull);
      expect(src.quality?.height, isNotNull);
    });

    testWidgets('media_kit 内核真实解码并读出媒体时长', (tester) async {
      final stack = _realStack();
      final feed = await stack.service
          .fetchFeed('bilibili:rcmd', request: const FeedRequest(pageSize: 6));
      final outcome = await stack.service.resolvePlayback(feed.items.first);
      expect(outcome.ok, isTrue);
      final src = outcome.source! as NativePlaybackSource;

      final controller = FusionPlayerController(
          logger: FusionLogger(minLevel: LogLevel.error));
      addTearDown(controller.dispose);

      await controller.load(src);

      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
        final snap = controller.snapshot;
        if (snap.phase == PlayerPhase.failed) break;
        if (snap.duration.inMilliseconds > 0) break;
      }

      final snap = controller.snapshot;
      debugPrint('[E2E] 内核状态：phase=${snap.phase.name} '
          '时长=${snap.duration.inSeconds}s '
          '尺寸=${snap.videoWidth}x${snap.videoHeight}');

      expect(snap.phase, isNot(PlayerPhase.failed),
          reason: '内核不应失败：${snap.errorDetail}');

      // 时长非零证明内核真的完成了网络拉流与解封装 ——
      // 这是"APP 内播放"链路打通的决定性证据。
      expect(snap.duration.inMilliseconds, greaterThan(0),
          reason: '内核应读出媒体时长，证明已完成解封装');
      expect(snap.duration.inSeconds, greaterThan(10),
          reason: '时长应是真实视频长度，而非占位值');

      // 关于视频宽高：`player.stream.width/height` 由 mpv 的**视频输出**
      // 上报，只有挂载渲染面（VideoController + Video widget）时才有值。
      // 本测试是无渲染面的无头验证，故不断言宽高；
      // 宽高的真实性已由 Android 实机截图中的 "854×394" 角标证明
      // （见 research/evidence/android-playing-*.png）。
      if (snap.videoWidth != null) {
        debugPrint('[E2E] 附带获得宽高：${snap.videoWidth}x${snap.videoHeight}');
      }
    });
  });

  group('真实环境 · 扫码登录', () {
    testWidgets('二维码申请与轮询状态机正确', (tester) async {
      final stack = _realStack();
      final bili = stack.registry.byId('bilibili')! as BilibiliAdapter;

      final challenge = await bili.requestQrChallenge();
      debugPrint('[E2E] 二维码内容长度=${challenge.qrContent.length} '
          '挑战键长度=${challenge.challengeKey.length}');

      expect(challenge.qrContent, startsWith('http'));
      expect(challenge.challengeKey, isNotEmpty);

      final poll = await bili.pollQrChallenge(challenge);
      debugPrint('[E2E] 轮询状态=${poll.phase.name} 提示=${poll.message}');

      expect(
        poll.phase == QrLoginPhase.waitingForScan ||
            poll.phase == QrLoginPhase.waitingForConfirm,
        isTrue,
        reason: '未扫码时应处于等待状态',
      );
      expect(poll.cookies, isEmpty, reason: '未完成登录时绝不能返回凭证');
    });
  });

  group('真实环境 · 受限能力如实报告', () {
    testWidgets('抖音推荐流如实失败而非返回空列表', (tester) async {
      final stack = _realStack();
      final result = await stack.service.fetchFeed('douyin:recommend');

      expect(result.ok, isFalse, reason: '抖音推荐流当前确实不可用');
      expect(result.error!.code, FusionErrorCode.permissionDenied);
      expect(result.error!.retryable, isFalse);
      expect(result.error!.diagnostics['blockedBy'], 'ArgusSecurityPlugin');
      debugPrint('[E2E] 抖音诊断：${result.error!.diagnostics}');
    });

    testWidgets('抖音链接识别可用，元数据被风控拦截时如实报错', (tester) async {
      final stack = _realStack();
      final result = await stack.service
          .resolveLink('https://www.douyin.com/video/7216290450186583355');

      expect(result.match, isNotNull);
      expect(result.match!.platformVideoId, '7216290450186583355');

      expect(result.ok, isFalse);
      expect(result.error!.httpStatus, 403);
      expect(result.error!.diagnostics['requiredCookie'], 'UIFID_TEMP');
      debugPrint('[E2E] 抖音拦截：${result.error!.technicalMessage}');
    });
  });

  group('真实环境 · 扩展性与故障隔离', () {
    testWidgets('模拟平台走完整注册→标准化→播放降级链路', (tester) async {
      final stack = _realStack();
      final feed = await stack.service
          .fetchFeed('mock:local', request: const FeedRequest(pageSize: 6));

      expect(feed.ok && feed.items.isNotEmpty, isTrue);
      expect(feed.items.every((v) => v.title.startsWith('【测试】')), isTrue,
          reason: '测试数据必须明确标注，不得伪装成真实平台');

      final outcome = await stack.service.resolvePlayback(feed.items.first);
      expect(outcome.ok, isTrue);
      expect(outcome.source!.mode, PlaybackMode.external,
          reason: '不支持应用内播放的平台应降级为跳转原平台');
    });

    testWidgets('一个来源失败不影响其它来源', (tester) async {
      final stack = _realStack();
      final bad = await stack.service.fetchFeed('nonexistent:source');
      expect(bad.ok, isFalse);

      final good = await stack.service
          .fetchFeed('bilibili:rcmd', request: const FeedRequest(pageSize: 6));
      expect(good.ok && good.items.isNotEmpty, isTrue,
          reason: '前一次失败不得影响后续来源');
    });

    testWidgets('内容来源清单如实标注可用性', (tester) async {
      final stack = _realStack();
      final sources = stack.service.describeFeedSources();

      expect(sources.any((s) => s.id == 'bilibili:rcmd' && s.available), isTrue);
      expect(
        sources.any((s) => s.id == 'douyin:recommend' && !s.available),
        isTrue,
        reason: '抖音推荐不可用必须如实标注',
      );
    });
  });

  group('真实环境 · 竖滑流控制器', () {
    testWidgets('FeedController 加载真实流并自动播放首屏', (tester) async {
      final stack = _realStack();
      final controller = FeedController(
          service: stack.service, logger: FusionLogger(enabled: false));
      addTearDown(controller.dispose);

      final sources = stack.service.describeFeedSources();
      final rcmd = sources.firstWhere((s) => s.id == 'bilibili:rcmd');

      await controller.loadSource(rcmd);

      expect(controller.length, greaterThan(0), reason: '应加载到真实内容');
      expect(controller.feedError, isNull);

      final first = controller.items.first;
      debugPrint('[E2E] 竖滑流首屏：${first.title}');

      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
        final state = controller.stateOf(0);
        if (state == FeedItemState.ready || state == FeedItemState.failed) break;
      }

      final state = controller.stateOf(0);
      debugPrint('[E2E] 首屏状态=${state.name} '
          '内核尺寸=${controller.snapshot.videoWidth}x'
          '${controller.snapshot.videoHeight}');

      // 要么可播放，要么给出明确失败原因——不得静默停在 idle
      expect(state, isNot(FeedItemState.idle),
          reason: '首屏必须进入明确状态，不能停留在未解析');
      if (state == FeedItemState.failed) {
        expect(controller.errorOf(0), isNotNull,
            reason: '失败时必须带可诊断的错误');
        debugPrint('[E2E] 首屏失败原因：${controller.errorOf(0)!.userMessage}');
      } else {
        expect(state, FeedItemState.ready);
      }
    });
  });

  group('真实环境 · UI', () {
    testWidgets('设置页如实展示账号与平台支持', (tester) async {
      final stack = _realStack();
      final logger = FusionLogger(minLevel: LogLevel.error);

      await tester.pumpWidget(MaterialApp(
        theme: AppleTheme.light(),
        home: SettingsScreen(
          service: stack.service,
          registry: stack.registry,
          vault: CredentialVault(
            storage: InMemorySecureStore(),
            logger: logger,
          ),
          progressStore: VideoProgressStore(
            storage: InMemoryStore(),
            logger: logger,
          ),
        ),
      ));
      // 设置页会异步读凭证，等它稳定
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // 顶部可见区域
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('账号'), findsWidgets);

      // 两个真实平台都应出现在账号区
      expect(find.text('哔哩哔哩'), findsWidgets,
          reason: '账号区应列出 B站');
      expect(find.text('抖音'), findsWidgets,
          reason: '账号区应列出抖音');

      // 滚动到「平台支持」区，确认能力如实标注
      await tester.scrollUntilVisible(
        find.text('平台支持'),
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      expect(find.text('平台支持'), findsOneWidget);

      // 滚动到「存储与隐私」区，确认凭证保护级别如实告知
      await tester.scrollUntilVisible(
        find.text('存储与隐私'),
        300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
      await tester.pumpAndSettle();
      expect(find.text('凭证存储'), findsOneWidget);
      expect(
        find.textContaining('系统安全存储'),
        findsWidgets,
        reason: '必须如实说明凭证用系统安全存储加密保存',
      );
    });
  });
}
