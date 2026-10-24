// 用子代理实测到的真实字幕 JSON 验证解析器（离线，不打网络）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili/subtitles.dart';

import 'support/local_fixtures.dart';

/// 字幕抓包不入公开仓库，缺失时显式跳过。
final Object _missing = skipIfMissing([
  'tool/live/_subtitle_body_login.json',
  'tool/live/_subtitle_list_login.json',
]);

void main() {
  test('解析真实 AI 字幕正文', () {
    final raw =
        File('tool/live/_subtitle_body_login.json').readAsStringSync();
    final cues = BilibiliSubtitleClient.parseSubtitleBody(raw);
    expect(cues, isNotEmpty);
    // 实测第一条：from 0.06 → to 2.42
    expect(cues.first.start, closeTo(0.06, 0.001));
    expect(cues.first.end, closeTo(2.42, 0.001));
    expect(cues.first.text.isNotEmpty, isTrue);
    // 时间轴必须递增，否则二分定位会错
    for (var i = 1; i < cues.length; i++) {
      expect(cues[i].start, greaterThanOrEqualTo(cues[i - 1].start),
          reason: '第 $i 条时间轴倒挂');
      expect(cues[i].end, greaterThan(cues[i].start));
    }
    // 中间时刻应命中某条
    final probe = cues[cues.length ~/ 2];
    final hit = cueAt(cues, Duration(milliseconds: (probe.start * 1000).round()));
    expect(hit, isNotNull, reason: '二分定位漏掉了自身起点');
    expect(hit!.text, probe.text);
    // 首条之前不应有字幕
    expect(cueAt(cues, Duration.zero), isNull);
  }, skip: _missing);

  test('空/坏输入返回空列表', () {
    expect(BilibiliSubtitleClient.parseSubtitleBody(''), isEmpty);
    expect(BilibiliSubtitleClient.parseSubtitleBody('not json'), isEmpty);
    expect(
      BilibiliSubtitleClient.parseSubtitleBody(jsonEncode({'body': []})),
      isEmpty,
    );
    // content 为空的条目被丢弃
    expect(
      BilibiliSubtitleClient.parseSubtitleBody(
        jsonEncode({
          'body': [
            {'from': 0, 'to': 2, 'content': '  '},
          ],
        }),
      ),
      isEmpty,
    );
    // to 缺省时用下一条 from 兜底
    final cues = BilibiliSubtitleClient.parseSubtitleBody(
      jsonEncode({
        'body': [
          {'from': 1, 'content': 'a'},
          {'from': 3, 'to': 5, 'content': 'b'},
        ],
      }),
    );
    expect(cues.length, 2);
    expect(cues[0].end, 3);
  });

  // 真实抓包：语言集只有 ai-zh / ai-en / ai-ja，URL 全是协议相对
  test('列表项解析：协议补全 + AI 标注', () {
    final raw = File('tool/live/_subtitle_list_login.json').readAsStringSync();
    final list = (jsonDecode(raw) as List).cast<Map>();
    final infos = list
        .map((e) {
          final url = '${e['subtitle_url']}';
          return (
            lan: '${e['lan']}',
            abs: url.startsWith('//') ? 'https:$url' : url,
            ai: '${e['lan']}'.startsWith('ai-'),
          );
        })
        .toList();
    expect(infos, isNotEmpty);
    for (final i in infos) {
      expect(i.abs.startsWith('https://'), isTrue, reason: i.lan);
      expect(i.ai, isTrue, reason: '${i.lan} 应是 AI 字幕');
    }
    expect(infos.map((e) => e.lan), containsAll(['ai-zh', 'ai-en', 'ai-ja']));
  }, skip: _missing);

  test('displayLabel 必须如实标注 AI（不依赖抓包）', () {
    const ai = SubtitleTrackInfo(
      lan: 'ai-zh',
      label: '中文',
      url: 'https://x',
      isAi: true,
    );
    expect(ai.displayLabel, '中文（AI）');
    const human = SubtitleTrackInfo(
      lan: 'zh-CN',
      label: '中文',
      url: 'https://x',
      isAi: false,
    );
    expect(human.displayLabel, '中文');
  });
}
