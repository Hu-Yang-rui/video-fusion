/// 抖音弹幕解析器的真实数据测试。
///
/// 用 `tool/capture_douyin_frames.mjs` 抓到的**真实 WebSocket 帧**
/// 验证 [DouyinDanmakuCodec] 能否正确解出弹幕。
///
/// 为什么这样做：
///  - 抖音弹幕的 ws 需要执行平台风控 JS（`sign.js`）生成 signature，
///    那部分不搬进 Dart（见 HANDOVER §3.18）。
///  - 但**解析层**是纯逻辑，可以用真实帧离线验证。
///  - 这样"解析正确"和"签名可得"两件事被分开证明，不混为一谈。
///
/// 帧文件在 `build/dyframes/`（由脚本生成，不进仓库）。
/// 文件不存在时整个 group 跳过，不报失败——保证 CI 无网络也能过。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/danmaku_codec.dart';
import 'package:video_fusion/src/models/live.dart';

void main() {
  final dir = Directory('build/dyframes');
  final frames = dir.existsSync()
      ? (dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.bin'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('抖音弹幕解析（真实帧）', () {
    test('帧文件存在（由 capture_douyin_frames.mjs 生成）', () {
      if (frames.isEmpty) {
        // ignore: avoid_print
        print('[SKIP] build/dyframes 为空，先跑 '
            'node tool/capture_douyin_frames.mjs');
        return;
      }
      expect(frames, isNotEmpty);
      // ignore: avoid_print
      print('[INFO] 待解析帧数: ${frames.length}');
    });

    test('能解出至少一条真实弹幕', () {
      if (frames.isEmpty) return;

      const codec = DouyinDanmakuCodec();
      final chats = <LiveMessage>[];
      var totalMessages = 0;
      var framesWithPayload = 0;

      for (final f in frames) {
        final bytes = Uint8List.fromList(f.readAsBytesSync());
        final result = codec.parseFrame(bytes);
        if (result == null) continue;
        framesWithPayload++;
        totalMessages += result.messages.length;
        for (final m in result.messages) {
          if (m.type == LiveMessageType.chat) chats.add(m);
        }
      }

      // ignore: avoid_print
      print('[INFO] 有 payload 的帧: $framesWithPayload/${frames.length}');
      // ignore: avoid_print
      print('[INFO] 解析出消息: $totalMessages 条，其中弹幕 ${chats.length} 条');

      expect(framesWithPayload, greaterThan(0),
          reason: '至少应有一帧带 payload');

      // 打印前几条，便于人工核对是不是真的弹幕
      for (final c in chats.take(8)) {
        // ignore: avoid_print
        print('[CHAT] ${c.uname ?? "(无昵称)"}: ${c.text}');
      }

      // 真实房间里 25 帧必然包含弹幕；但极冷清的房间可能没有。
      // 这里用"消息总数 > 0"作为硬断言，弹幕数只做提示。
      expect(totalMessages, greaterThan(0),
          reason: '真实帧里应能解出消息');
    });

    test('解出的弹幕文本非空且是合法 UTF-8', () {
      if (frames.isEmpty) return;

      const codec = DouyinDanmakuCodec();
      final chats = <LiveMessage>[];
      for (final f in frames) {
        final result =
            codec.parseFrame(Uint8List.fromList(f.readAsBytesSync()));
        if (result == null) continue;
        chats.addAll(result.messages.where((m) => m.type == LiveMessageType.chat));
      }

      for (final c in chats) {
        expect(c.text, isNotEmpty);
        // 不能是替换字符（U+FFFD），那说明 UTF-8 解错了
        expect(c.text.contains('\uFFFD'), isFalse,
            reason: '弹幕文本不该含替换字符，说明解码正确');
      }
    });

    test('垃圾数据不崩溃（健壮性）', () {
      const codec = DouyinDanmakuCodec();

      // 空
      expect(codec.parseFrame(Uint8List(0)), isNull);
      // 随机字节
      expect(codec.parseFrame(Uint8List.fromList([0xff, 0xfe, 0x00, 0x01])),
          isNull);
      // 截断的合法前缀
      expect(
        codec.parseFrame(Uint8List.fromList([0x42, 0x08, 0x01])),
        isNull,
      );
      // 超长 varint
      expect(
        codec.parseFrame(Uint8List.fromList(List.filled(20, 0xff))),
        isNull,
      );
    });
  });
}
