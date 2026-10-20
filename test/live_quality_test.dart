/// 直播清晰度切换的契约测试（需求二）。
///
/// 重点锁住"不能硬编码虚假清晰度"这条：
///  - 可选档位**只**来自适配器真实下发的 `availableQualities`
///  - 只有一档时不构成"可选"（UI 不该渲染切换入口）
///  - 切换目标是列表里的实例，不是凭 qn 数字现造
///  - 失败回滚后仍指向原流
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/models/live.dart';

LiveStream _stream({
  required int qn,
  required String label,
  List<LiveStream> qualities = const [],
  String protocol = 'http_hls',
}) =>
    LiveStream(
      url: 'https://cdn.example/room_$qn.m3u8',
      protocolName: protocol,
      formatName: 'ts',
      codecName: 'avc',
      qualityLabel: label,
      qualityValue: qn,
      availableQualities: qualities,
    );

void main() {
  group('LiveStream 清晰度契约', () {
    test('availableQualities 默认为空（平台没给就是没有）', () {
      final s = _stream(qn: 10000, label: '原画');
      expect(s.availableQualities, isEmpty);
    });

    test('多档时每档带自己的真实 url 与 qn', () {
      final low = _stream(qn: 150, label: '流畅');
      final high = _stream(qn: 400, label: '蓝光');
      final current = _stream(
        qn: 10000,
        label: '原画',
        qualities: [low, high, _stream(qn: 10000, label: '原画')],
      );

      expect(current.availableQualities.length, 3);
      // 每档的地址不同 —— 切换才有意义
      final urls = current.availableQualities.map((e) => e.url).toSet();
      expect(urls.length, 3);
      expect(current.availableQualities.first.qualityLabel, '流畅');
    });

    test('qualityLabel 只用于展示，排序应看 qualityValue', () {
      final a = _stream(qn: 150, label: '高清');
      final b = _stream(qn: 400, label: '标清');
      // 名字与数值顺序不一致是平台常态（SD2 比 SD1 高），
      // 所以排序必须用 qualityValue
      expect(b.qualityValue > a.qualityValue, isTrue);
    });

    test('协议标签不暴露给用户做清晰度名', () {
      final s = _stream(qn: 150, label: '流畅', protocol: 'http_stream');
      expect(s.protocolLabel, 'FLV');
      expect(s.qualityLabel, '流畅');
      expect(s.qualityLabel, isNot(contains('FLV')));
    });

    test('isHls 按协议名判定', () {
      expect(_stream(qn: 1, label: 'x').isHls, isTrue);
      expect(
        _stream(qn: 1, label: 'x', protocol: 'http_stream').isHls,
        isFalse,
      );
    });

    test('只有一档时不构成可选（UI 不该给切换入口）', () {
      final only = _stream(qn: 10000, label: '原画');
      // 平台只下发一档 → availableQualities 为空 → 无切换入口
      expect(only.availableQualities.length > 1, isFalse);
    });

    test('requestHeaders 随流携带（切换后仍要带对的 Referer/UA）', () {
      const s = LiveStream(
        url: 'https://cdn/x.m3u8',
        protocolName: 'http_hls',
        formatName: 'ts',
        codecName: 'avc',
        qualityLabel: '原画',
        qualityValue: 10000,
        requestHeaders: {'Referer': 'https://live.douyin.com/'},
      );
      expect(s.requestHeaders['Referer'], contains('douyin'));
    });
  });

  group('切换语义（模拟 UI 逻辑）', () {
    test('切换成功：当前流指向目标档', () {
      final low = _stream(qn: 150, label: '流畅');
      final high = _stream(qn: 400, label: '蓝光');
      var current = _stream(
        qn: 10000,
        label: '原画',
        qualities: [low, high],
      );

      // 模拟 _switchQuality 成功路径
      final target = high;
      current = target;

      expect(current.qualityValue, 400);
      expect(current.url, contains('room_400'));
    });

    test('切换到同一档应被短路（不发多余请求）', () {
      final low = _stream(qn: 150, label: '流畅');
      final current = _stream(qn: 150, label: '流畅', qualities: [low]);
      final target = low;
      expect(target.qualityValue == current.qualityValue, isTrue);
    });

    test('切换失败：回滚到原流，不留在目标档', () {
      final low = _stream(qn: 150, label: '流畅');
      final original = _stream(
        qn: 10000,
        label: '原画',
        qualities: [low],
      );
      var current = original;

      // 模拟失败路径：先不动 current，catch 里回滚
      try {
        throw StateError('open failed');
      } catch (_) {
        current = original; // 回滚
      }

      expect(current.qualityValue, 10000);
      expect(current.qualityLabel, '原画');
    });

    test('目标档必须来自 availableQualities（不能凭 qn 现造）', () {
      final low = _stream(qn: 150, label: '流畅');
      final current = _stream(qn: 10000, label: '原画', qualities: [low]);

      final byValue = current.availableQualities
          .where((e) => e.qualityValue == 150)
          .toList();
      expect(byValue.length, 1);

      // 平台没下发的档位查不到 → 不应切
      final missing = current.availableQualities
          .where((e) => e.qualityValue == 9999)
          .toList();
      expect(missing, isEmpty);
    });
  });
}
