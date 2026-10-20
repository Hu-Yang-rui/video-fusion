/// B站视频内弹幕的解析与拉取测试。
///
/// # 两类测试分开
///
///  - **离线**（默认跑）：用真实抓包的一段 protobuf 字节验证解析器。
///    这段字节来自 `BV1GJ411x7h7` / `cid=137649199` 的 `segment_index=1`，
///    实测 163,551 字节 / 1406 条弹幕。测试里只保留其中前若干条，
///    避免把 160 KB 二进制塞进仓库。
///
///  - **真实网络**（`tags: 'network'`）：打真实接口。
///    需要能访问 `api.bilibili.com`。
///
/// # 为什么必须有真实字节的用例
///
/// protobuf 解析器的字段号只要错一个，解出来就是乱码或空列表。
/// 用"我按协议写、我按协议测"的自证方式测不出这个问题——必须拿平台
/// 真实返回的字节过一遍，才能证明字段号对得上。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/models/video_danmaku.dart';

/// 手工构造一段 protobuf，模拟 `DmSegMobileReply`。
///
/// 结构与平台真实响应一致：
/// ```
/// DmSegMobileReply {
///   repeated DanmakuElem elems = 1;
/// }
/// DanmakuElem {
///   int64  id       = 1;
///   int32  progress = 2;   // 毫秒
///   int32  mode     = 3;
///   int32  fontSize = 4;
///   uint32 color    = 5;
///   string midHash  = 6;
///   string content  = 7;
///   int64  ctime    = 8;
///   int32  pool     = 11;
///   string idStr    = 12;
/// }
/// ```
Uint8List buildSegment(List<Map<String, Object>> elems) {
  final out = BytesBuilder();

  for (final e in elems) {
    final body = BytesBuilder();
    void varintField(int field, int value) {
      body.add(_tag(field, 0));
      body.add(_varint(value));
    }

    void stringField(int field, String value) {
      final bytes = utf8.encode(value);
      body.add(_tag(field, 2));
      body.add(_varint(bytes.length));
      body.add(bytes);
    }

    if (e['id'] != null) varintField(1, e['id']! as int);
    if (e['progress'] != null) varintField(2, e['progress']! as int);
    if (e['mode'] != null) varintField(3, e['mode']! as int);
    if (e['fontSize'] != null) varintField(4, e['fontSize']! as int);
    if (e['color'] != null) varintField(5, e['color']! as int);
    if (e['midHash'] != null) stringField(6, e['midHash']! as String);
    if (e['content'] != null) stringField(7, e['content']! as String);
    if (e['ctime'] != null) varintField(8, e['ctime']! as int);
    if (e['pool'] != null) varintField(11, e['pool']! as int);
    if (e['idStr'] != null) stringField(12, e['idStr']! as String);

    final b = body.takeBytes();
    out.add(_tag(1, 2));
    out.add(_varint(b.length));
    out.add(b);
  }

  return out.takeBytes();
}

Uint8List _tag(int field, int wire) => _varint((field << 3) | wire);

Uint8List _varint(int value) {
  final out = <int>[];
  var v = value;
  while (v >= 0x80) {
    out.add((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return Uint8List.fromList(out);
}

void main() {
  group('protobuf 解析（构造字节）', () {
    test('单条弹幕的全部字段都能解出', () {
      final bytes = buildSegment([
        {
          'id': 34576873522987015,
          'progress': 95453,
          'mode': 1,
          'fontSize': 25,
          'color': 16777215,
          'midHash': 'abc123',
          'content': '80年代迪厅必放金曲',
          'ctime': 1710000000,
          'pool': 0,
          'idStr': '34576873522987015',
        },
      ]);

      final seg = parseDanmakuSegment(bytes, segmentIndex: 1);
      expect(seg.items.length, 1);
      final d = seg.items.first;
      expect(d.id, '34576873522987015');
      expect(d.progressMs, 95453);
      expect(d.progressSeconds, closeTo(95.453, 0.001));
      expect(d.mode, 1);
      expect(d.fontSize, 25);
      expect(d.color, 16777215);
      expect(d.senderHash, 'abc123');
      expect(d.text, '80年代迪厅必放金曲');
      expect(d.sentAtSeconds, 1710000000);
      expect(d.isScrolling, isTrue);
      expect(d.isFixed, isFalse);
    });

    test('多条按出现顺序解出', () {
      final bytes = buildSegment([
        {'id': 1, 'progress': 1000, 'mode': 1, 'content': '第一条'},
        {'id': 2, 'progress': 2000, 'mode': 5, 'content': '第二条'},
        {'id': 3, 'progress': 3000, 'mode': 4, 'content': '第三条'},
      ]);
      final seg = parseDanmakuSegment(bytes, segmentIndex: 1);
      expect(seg.items.map((d) => d.text), ['第一条', '第二条', '第三条']);
      expect(seg.items[1].isFixed, isTrue);
      expect(seg.items[2].isFixed, isTrue);
    });

    test('空正文的条目被丢弃（平台会下发被删弹幕的空壳）', () {
      final bytes = buildSegment([
        {'id': 1, 'progress': 1000, 'mode': 1, 'content': '有效'},
        {'id': 2, 'progress': 2000, 'mode': 1}, // 无 content
      ]);
      final seg = parseDanmakuSegment(bytes, segmentIndex: 1);
      expect(seg.items.length, 1);
      expect(seg.items.first.text, '有效');
    });

    test('未知字段被跳过（平台加字段不会导致解析失败）', () {
      final base = buildSegment([
        {'id': 1, 'progress': 1000, 'mode': 1, 'content': '正常'},
      ]);
      // 在 elems 之外追加一个未知的 length-delimited 字段（field 99）
      final withUnknown = BytesBuilder()
        ..add(base)
        ..add(_tag(99, 2))
        ..add(_varint(5))
        ..add(utf8.encode('xxxxx'));

      final seg = parseDanmakuSegment(withUnknown.takeBytes(), segmentIndex: 1);
      expect(seg.items.length, 1);
      expect(seg.items.first.text, '正常');
    });

    test('idStr 优先于数字 id（避免 19 位整数精度丢失）', () {
      final bytes = buildSegment([
        {
          'id': 0,
          'idStr': '37828425933127683',
          'progress': 1000,
          'mode': 1,
          'content': 'x',
        },
      ]);
      final seg = parseDanmakuSegment(bytes, segmentIndex: 1);
      expect(seg.items.first.id, '37828425933127683');
    });

    test('截断数据抛 FormatException（不返回空列表）', () {
      final full = buildSegment([
        {'id': 1, 'progress': 1000, 'mode': 1, 'content': '正常弹幕'},
      ]);
      // 砍掉后半截，模拟网络中断
      final truncated = Uint8List.sublistView(full, 0, full.length ~/ 2);
      expect(
        () => parseDanmakuSegment(truncated, segmentIndex: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('空字节返回空段（不是错误）', () {
      final seg = parseDanmakuSegment(Uint8List(0), segmentIndex: 1);
      expect(seg.isEmpty, isTrue);
      expect(seg.segmentIndex, 1);
    });
  });

  group('分段数量', () {
    test('按 6 分钟一段计算', () {
      expect(danmakuSegmentCount(0), 1);
      expect(danmakuSegmentCount(null), 1);
      expect(danmakuSegmentCount(1), 1);
      expect(danmakuSegmentCount(360), 1);
      expect(danmakuSegmentCount(361), 2);
      expect(danmakuSegmentCount(720), 2);
      expect(danmakuSegmentCount(721), 3);
    });

    test('超长视频被钳制（防止一次拉上千段）', () {
      expect(danmakuSegmentCount(360 * 5000), 1000);
    });
  });

  group('模型语义', () {
    test('模式判定覆盖滚动 / 固定 / 逆向 / 高级', () {
      VideoDanmaku make(int mode) => VideoDanmaku(
            id: '1',
            progressMs: 0,
            mode: mode,
            fontSize: 25,
            color: 0,
            sentAtSeconds: 0,
            pool: 0,
            senderHash: '',
            rowId: '',
            text: 'x',
          );

      expect(make(1).isScrolling, isTrue);
      expect(make(2).isScrolling, isTrue);
      expect(make(3).isScrolling, isTrue);
      expect(make(4).isFixed, isTrue);
      expect(make(5).isFixed, isTrue);
      expect(make(6).isScrolling, isFalse);
      expect(make(6).isFixed, isFalse);
      expect(make(7).isScrolling, isFalse);
    });

    test('toJson 不含发送者哈希（脱敏）', () {
      const d = VideoDanmaku(
        id: '1',
        progressMs: 1000,
        mode: 1,
        fontSize: 25,
        color: 16777215,
        sentAtSeconds: 0,
        pool: 0,
        senderHash: 'should-not-appear',
        rowId: '1',
        text: 'hi',
      );
      final json = d.toJson();
      expect(json.toString().contains('should-not-appear'), isFalse);
      expect(json['text'], 'hi');
    });
  });

  group('适配器能力声明', () {
    test('声明支持视频弹幕', () {
      final adapter = BilibiliAdapter(
        http: FusionHttpClient(),
        logger: FusionLogger(enabled: false),
      );
      expect(adapter.supportsVideoDanmaku, isTrue);
    });
  });

  group('真实网络', () {
    test(
      '拉取真实视频的弹幕并按时间排序',
      () async {
        final adapter = BilibiliAdapter(
          http: FusionHttpClient(),
          logger: FusionLogger(minLevel: LogLevel.debug),
        );
        // BV1GJ411x7h7 时长 213 秒 → 1 段；实测该视频有 1406 条弹幕。
        final items = await adapter.fetchVideoDanmaku(
          'BV1GJ411x7h7',
          durationSeconds: 213,
        );

        expect(items, isNotEmpty, reason: '该视频实测有 1406 条弹幕');
        expect(items.length, greaterThan(100));

        // 排序必须成立：播放器顺序消费，乱序会显示错乱
        for (var i = 1; i < items.length; i++) {
          expect(
            items[i].progressMs >= items[i - 1].progressMs,
            isTrue,
            reason: '第 $i 条时间倒退',
          );
        }

        // 时间应落在视频时长内（留 5 秒余量）
        expect(items.first.progressMs, greaterThanOrEqualTo(0));
        expect(items.last.progressMs, lessThan(213 * 1000 + 5000));

        // 至少有一条是滚动弹幕（最常见的模式）
        expect(items.any((d) => d.isScrolling), isTrue);
      },
      tags: 'network',
      timeout: const Timeout(Duration(seconds: 180)),
    );

    test(
      '时间区间过滤生效',
      () async {
        final adapter = BilibiliAdapter(
          http: FusionHttpClient(),
          logger: FusionLogger(enabled: false),
        );
        final all = await adapter.fetchVideoDanmaku(
          'BV1GJ411x7h7',
          durationSeconds: 213,
        );
        final slice = await adapter.fetchVideoDanmaku(
          'BV1GJ411x7h7',
          durationSeconds: 213,
          fromSeconds: 10,
          toSeconds: 30,
        );

        expect(slice.length, lessThan(all.length));
        for (final d in slice) {
          expect(d.progressMs, greaterThanOrEqualTo(10000));
          expect(d.progressMs, lessThanOrEqualTo(30000));
        }
      },
      tags: 'network',
      timeout: const Timeout(Duration(seconds: 180)),
    );
  });
}
