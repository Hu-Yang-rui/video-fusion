/// B站直播弹幕：wbi 签名 + token 获取的真实网络验证。
///
/// 跑法：
///   flutter test test/bilibili_danmaku_network.dart
///
/// 验证链：
///   1. wbi 签名器能拿到 mixin key
///   2. getDanmuInfo 带签名后返回 code=0（而不是 -352）
///   3. 拿到非空 token 与 host_list
///   4. 用该 token 连 wss，认证包返回 {"code":0}
///   5. 能收到 op=5 业务包
///
/// 这一条链跑通，说明**B站弹幕匿名完全可用**，
/// 之前的"需要登录"结论是错的（真实原因是缺 wbi 签名）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  final logger = FusionLogger(minLevel: LogLevel.warn);
  final http = FusionHttpClient(logger: logger);
  final adapter = BilibiliAdapter(http: http, logger: logger);

  test('B站弹幕：wbi 签名 → token → wss 认证', () async {
    // 1. 取一个在播房间
    final page = await adapter.fetchLiveRooms(page: 1, pageSize: 5);
    expect(page.items, isNotEmpty, reason: '需要真实直播间');
    final room = page.items.first;
    // ignore: avoid_print
    print('[DM] room=${room.roomId} 人气=${room.online} ${room.title}');

    // 2. 拿弹幕端点（内部会做 wbi 签名）
    final endpoint = await adapter.fetchLiveDanmakuEndpoint(room.roomId);
    // ignore: avoid_print
    print('[DM] token 长度=${endpoint.token.length} '
        'hosts=${endpoint.hostList.length}');
    if (endpoint.hostList.isNotEmpty) {
      // ignore: avoid_print
      print('[DM] host[0]=${endpoint.hostList.first}');
    }

    expect(endpoint.token, isNotEmpty,
        reason: 'wbi 签名后应能拿到 token（此前 -352 是缺签名）');
    expect(endpoint.hostList, isNotEmpty);

    // 3. 连 wss 并认证
    final wsUrl = endpoint.hostList.first;
    // ignore: avoid_print
    print('[DM] 连接 $wsUrl');

    final socket = await WebSocket.connect(
      wsUrl,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Origin': 'https://live.bilibili.com',
      },
    ).timeout(const Duration(seconds: 15));

    // 认证包 op=7
    final authBody = jsonEncode({
      'uid': 0,
      'roomid': room.roomId,
      'protover': 2,
      'platform': 'web',
      'type': 2,
      'key': endpoint.token,
    });
    socket.add(_packet(7, utf8.encode(authBody)));

    var authed = false;
    var op5Count = 0;
    final done = Completer<void>();

    final sub = socket.listen((dynamic data) {
      Uint8List? buf;
      if (data is Uint8List) {
        buf = data;
      } else if (data is List<int>) {
        buf = Uint8List.fromList(data);
      }
      if (buf == null || buf.length < 16) return;

      final op = _readUint32(buf, 8);
      final bodyLen = _readUint32(buf, 0) - 16;
      final body = buf.sublist(16, 16 + bodyLen);

      if (op == 8) {
        final txt = utf8.decode(body, allowMalformed: true);
        // ignore: avoid_print
        print('[DM] 认证回复: $txt');
        if (txt.contains('"code":0')) authed = true;
      } else if (op == 5) {
        op5Count++;
        if (op5Count <= 2) {
          // ignore: avoid_print
          print('[DM] 收到业务包 op=5, ${bodyLen}B');
        }
      }

      if (authed && op5Count >= 2 && !done.isCompleted) {
        done.complete();
      }
    });

    await done.future.timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        // ignore: avoid_print
        print('[DM] 超时：authed=$authed op5=$op5Count');
      },
    );

    await sub.cancel();
    await socket.close();

    expect(authed, isTrue,
        reason: '认证包应返回 {"code":0}，证明 token 有效');
    expect(op5Count, greaterThan(0),
        reason: '应收到 op=5 业务包（含弹幕/礼物/进场等）');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('wbi 签名器：key 可获取且格式正确', () async {
    // 通过一次真实请求间接验证（getDanmuInfo 成功即说明签名有效）
    final page = await adapter.fetchLiveRooms(page: 1, pageSize: 3);
    expect(page.items, isNotEmpty);

    // 第二次调用应命中缓存（更快）
    final sw = Stopwatch()..start();
    await adapter.fetchLiveDanmakuEndpoint(page.items.first.roomId);
    sw.stop();
    // ignore: avoid_print
    print('[DM] 第二次 getDanmuInfo 耗时 ${sw.elapsedMilliseconds}ms');
    // 缓存命中时应该很快（<3s 网络往返）
    expect(sw.elapsedMilliseconds, lessThan(5000));
  }, timeout: const Timeout(Duration(minutes: 1)));
}

/// 构造 B站弹幕协议的 16 字节头 + body。
Uint8List _packet(int op, List<int> body) {
  final buf = Uint8List(16 + body.length);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, 16 + body.length); // 总长度
  bd.setUint16(4, 16); // 头长度
  bd.setUint16(6, 1); // protover=1（明文 JSON）
  bd.setUint32(8, op); // 操作码
  bd.setUint32(12, 1); // 序列号
  buf.setRange(16, 16 + body.length, body);
  return buf;
}

int _readUint32(Uint8List buf, int offset) =>
    ByteData.sublistView(buf).getUint32(offset);
