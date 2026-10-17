/// 直播模块与 IP 属地的测试。
///
/// 覆盖：
///  - B 站直播接口真实可用性（列表 / 详情 / 播放流 / 弹幕参数）
///  - 未开播房间的处理
///  - 抖音如实声明不支持直播
///  - B 站评论 IP 属地解析（含前缀剥离、缺失字段）
///  - 抖音评论 ip_label 解析
///
/// 真实网络用例标记 tags: 'network'。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/douyin_adapter.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/interaction.dart';
import 'package:video_fusion/src/models/live.dart';

BilibiliAdapter _bili() => BilibiliAdapter(
      http: FusionHttpClient(logger: FusionLogger(enabled: false)),
      logger: FusionLogger(enabled: false),
    );

DouyinAdapter _douyin() => DouyinAdapter(
      http: FusionHttpClient(logger: FusionLogger(enabled: false)),
      logger: FusionLogger(enabled: false),
    );

void main() {
  group('能力声明（离线）', () {
    test('B 站声明支持直播', () {
      expect(_bili().supportsLive, isTrue);
    });

    test('抖音如实声明不支持直播', () {
      expect(_douyin().supportsLive, isFalse);
    });

    test('抖音的直播方法明确抛错，不返回空列表', () async {
      expect(
        () => _douyin().fetchLiveRooms(),
        throwsA(
          isA<FusionException>().having(
            (e) => e.code,
            'code',
            FusionErrorCode.unsupportedPlatform,
          ),
        ),
      );
    });
  });

  group('B 站直播列表（真实网络）', () {
    test('返回真实房间且字段完整', () async {
      final page = await _bili().fetchLiveRooms(page: 1, pageSize: 10);

      expect(page.items, isNotEmpty, reason: '直播列表应有真实数据');
      expect(page.totalCount, greaterThan(0));

      for (final room in page.items) {
        expect(room.roomId, greaterThan(0));
        expect(room.title, isNotEmpty);
        expect(room.uname, isNotEmpty);
      }
    }, tags: 'network');

    test('分页可用', () async {
      final a = _bili();
      final p1 = await a.fetchLiveRooms(page: 1, pageSize: 10);
      final p2 = await a.fetchLiveRooms(page: 2, pageSize: 10);

      expect(p1.items, isNotEmpty);
      expect(p2.items, isNotEmpty);

      final ids1 = p1.items.map((r) => r.roomId).toSet();
      final ids2 = p2.items.map((r) => r.roomId).toSet();
      // 热度排序下可能偶有重叠，但不应完全相同
      expect(ids1.difference(ids2), isNotEmpty);
    }, tags: 'network');
  });

  group('B 站直播分区（真实网络）', () {
    test('返回一级与二级分区', () async {
      final areas = await _bili().fetchLiveAreas();

      expect(areas, isNotEmpty, reason: '分区列表应有数据');
      for (final a in areas) {
        expect(a.id, greaterThan(0));
        expect(a.name, isNotEmpty);
      }
      // 至少一个分区有子分区
      expect(areas.any((a) => a.children.isNotEmpty), isTrue);
    }, tags: 'network');
  });

  group('B 站直播间详情与播放（真实网络）', () {
    test('直播中的房间能解析出可播放流', () async {
      final a = _bili();
      // 多取几页，提高命中正在直播房间的概率
      final page = await a.fetchLiveRooms(page: 1, pageSize: 20);
      expect(page.items, isNotEmpty);

      LiveRoomInfo? liveInfo;
      int? liveRoomId;
      for (final room in page.items) {
        try {
          final info = await a.fetchLiveRoomInfo(room.roomId);
          if (info.isLive) {
            liveInfo = info;
            liveRoomId = room.roomId;
            break;
          }
        } catch (_) {
          continue;
        }
      }

      // 列表按热度排序，正常情况下必有直播中的房间；
      // 若平台接口异常导致全部查不到，跳过而不是误报成功。
      if (liveRoomId == null) {
        markTestSkipped('当前列表中没有可查到 live_status=1 的房间');
        return;
      }

      expect(liveInfo!.liveStatus, 1);

      final stream = await a.resolveLiveStream(liveRoomId);
      expect(stream.url, isNotEmpty);
      expect(stream.url, startsWith('http'));
      // 协议必须是 FLV 或 HLS
      expect(
        stream.protocolName,
        anyOf('http_stream', 'http_hls'),
      );
      expect(stream.qualityLabel, isNotEmpty);
    }, tags: 'network');

    test('未开播的房间明确抛错而不是返回假流', () async {
      // 用一个极不可能是直播间的 room id
      expect(
        () => _bili().resolveLiveStream(999999999),
        throwsA(isA<FusionException>()),
      );
    }, tags: 'network');
  });

  group('B 站弹幕连接参数（真实网络）', () {
    test('未登录时弹幕接口返回风控错误，如实抛出而非伪造', () async {
      // 实测（2026-10，未登录）：getDanmuInfo 返回 code=-352（风控）。
      // 该接口需要登录态 Cookie 才能换取 token。
      //
      // 这里断言两种可接受结果：
      //  1. 拿到 token（若平台放开或已登录）
      //  2. 明确抛 FusionException（当前实际情况）
      // 不允许的是：返回空 token 却假装成功。
      final a = _bili();
      final page = await a.fetchLiveRooms(page: 1, pageSize: 5);
      expect(page.items, isNotEmpty);

      try {
        final endpoint =
            await a.fetchLiveDanmakuEndpoint(page.items.first.roomId);
        // 若成功，必须有真实的 wss 地址
        expect(endpoint.hostList, isNotEmpty);
        expect(endpoint.hostList.first, startsWith('wss://'));
        expect(endpoint.roomId, page.items.first.roomId);
      } on FusionException catch (e) {
        // 当前预期路径：风控拦截
        expect(
          e.code,
          anyOf(
            FusionErrorCode.upstreamError,
            FusionErrorCode.permissionDenied,
          ),
        );
        expect(e.technicalMessage, contains('-352'));
      }
    }, tags: 'network');
  });

  group('直播数据模型（离线）', () {
    test('LiveRoomInfo 状态文案正确', () {
      const live = LiveRoomInfo(
        roomId: 1,
        shortId: 0,
        uid: 1,
        title: 't',
        liveStatus: 1,
      );
      const offline = LiveRoomInfo(
        roomId: 2,
        shortId: 0,
        uid: 1,
        title: 't',
        liveStatus: 0,
      );
      const round = LiveRoomInfo(
        roomId: 3,
        shortId: 0,
        uid: 1,
        title: 't',
        liveStatus: 2,
      );

      expect(live.isLive, isTrue);
      expect(live.statusLabel, '直播中');
      expect(offline.isLive, isFalse);
      expect(offline.statusLabel, '未开播');
      expect(round.statusLabel, '轮播中');
    });

    test('LiveStream 协议标签正确', () {
      const hls = LiveStream(
        url: 'https://x/y.m3u8',
        protocolName: 'http_hls',
        formatName: 'fmp4',
        codecName: 'avc',
        qualityLabel: '原画',
        qualityValue: 10000,
      );
      const flv = LiveStream(
        url: 'https://x/y.flv',
        protocolName: 'http_stream',
        formatName: 'flv',
        codecName: 'avc',
        qualityLabel: '高清',
        qualityValue: 150,
      );

      expect(hls.isHls, isTrue);
      expect(hls.protocolLabel, 'HLS');
      expect(flv.isHls, isFalse);
      expect(flv.protocolLabel, 'FLV');
    });
  });

  group('IP 属地（离线解析）', () {
    test('VideoComment 未提供属地时为 null', () {
      const c = VideoComment(
        id: '1',
        authorName: 'a',
        message: 'm',
        createdAt: '2026-01-01T00:00:00Z',
      );
      expect(c.ipLocation, isNull);
    });

    test('VideoComment 携带属地时正确保留', () {
      const c = VideoComment(
        id: '1',
        authorName: 'a',
        message: 'm',
        createdAt: '2026-01-01T00:00:00Z',
        ipLocation: '广东',
      );
      expect(c.ipLocation, '广东');
    });

    test('toJson 包含 ipLocation', () {
      const c = VideoComment(
        id: '1',
        authorName: 'a',
        message: 'm',
        createdAt: '2026-01-01T00:00:00Z',
        ipLocation: '日本',
      );
      expect(c.toJson()['ipLocation'], '日本');
    });
  });

  group('B 站评论 IP 属地（真实网络）', () {
    test('未登录时属地可能缺失，但解析不应崩溃', () async {
      // 实测：B 站未登录请求的评论响应里没有 reply_control.location，
      // 因此这里断言"要么有值、要么为 null"，且不得抛错。
      final page = await _bili().fetchComments(
        'BV1GJ411x7h7',
        page: 1,
        pageSize: 10,
      );

      expect(page.items, isNotEmpty);
      for (final c in page.items) {
        // 不强制要求有值（未登录拿不到），但类型必须是 String? 且非空串
        if (c.ipLocation != null) {
          expect(c.ipLocation, isNotEmpty);
          // 不得残留前缀
          expect(c.ipLocation!.contains('IP属地'), isFalse);
        }
      }
    }, tags: 'network');
  });
}
