// 抖音直播真实网络验证（不是单元测试，是端到端探针）。
//
// 跑法：
//   flutter test test/douyin_live_live_test.dart --tags network
//
// 验证四件事：
//   1. 列表接口返回真实直播间（数量 > 0）
//   2. 每个房间都有封面、标题、主播名
//   3. 至少一个房间能解析出可播放的 HLS 地址
//   4. 该 HLS 地址能被真实 HTTP 请求命中（不是空地址）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/live_client.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  final logger = FusionLogger(minLevel: LogLevel.warn);
  final http = FusionHttpClient(logger: logger);

  test(
    '抖音直播推荐流：真实数据 + 可播放地址',
    () async {
      final client = DouyinLiveClient(http: http, logger: logger);

      // 1. 列表
      final rooms = await client.fetchFeed(count: 10);
      // ignore: avoid_print
      print('[LIVE] 房间数: ${rooms.length}');
      expect(rooms, isNotEmpty, reason: '推荐流应返回真实直播间');

      // 2. 字段完整性
      for (final r in rooms.take(6)) {
        // ignore: avoid_print
        print('[LIVE] ${r.roomKey} | ${r.uname} | ${r.online}人 | '
            '${r.title}');
        expect(r.roomKey, isNotEmpty);
        expect(r.title, isNotEmpty);
        expect(r.uname, isNotEmpty);
        expect(r.coverUrl, isNotNull, reason: '列表应带封面');
      }

      // 3. 播放地址
      //
      // 注意：`webcast/feed` 会随机返回空 body（实测单次成功率约 60%，
      // 与请求间隔无关）。`findRoomInFeed` 内部已做 5 次重试，
      // 但仍可能整轮失败——这是**平台行为**，不是代码缺陷。
      // 因此这里不要求"每个房间都解析成功"，只要求"至少有一个能播"。
      var withStream = 0;
      String? firstUrl;
      for (final r in rooms.take(4)) {
        Map<String, Object?>? room;
        try {
          room = await client.findRoomInFeed(r.roomKey);
        } on FusionException catch (e) {
          // 空 body 用尽重试：跳过这个房间，继续试下一个
          // ignore: avoid_print
          print('[LIVE] ${r.roomKey} 取详情失败（${e.code.name}），跳过');
          continue;
        }
        if (room == null) continue;
        final stream = client.parseStream(room);
        if (stream != null) {
          withStream++;
          firstUrl ??= stream.url;
          // ignore: avoid_print
          print('[LIVE] ${r.roomKey} -> ${stream.protocolLabel} '
              '${stream.qualityLabel}');
        }
      }
      // ignore: avoid_print
      print('[LIVE] 成功解析播放地址的房间: $withStream');
      expect(withStream, greaterThan(0), reason: '至少要有一个可播放房间');
      expect(firstUrl, isNotNull);

      // 4. 地址真的能取到内容（不是空串/假地址）
      final uri = Uri.parse(firstUrl!);
      expect(uri.scheme, 'https', reason: '必须升级到 https');
      final client2 = HttpClient();
      try {
        final req = await client2.getUrl(uri);
        req.headers.set('User-Agent', 'Mozilla/5.0');
        final resp = await req.close();
        final first = await resp.first;
        // ignore: avoid_print
        print('[LIVE] 播放地址 HTTP=${resp.statusCode} '
            '首块=${first.length}B');
        expect(resp.statusCode, anyOf(200, 206),
            reason: '直播流地址应可访问');
        expect(first, isNotEmpty);
      } finally {
        client2.close(force: true);
      }
    },
    tags: 'network',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
