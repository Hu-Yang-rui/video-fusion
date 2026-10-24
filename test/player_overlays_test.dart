/// 播放器叠加层的渲染约束（字幕层）。
///
/// 缩略图的裁切几何在 `seek_preview_test.dart` 用真实抓包逐帧验过；
/// 这里只守住"没有字幕时一个像素都不占"和"AI 标注不冒充人工字幕"。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/design/components/player_overlays.dart';
import 'package:video_fusion/src/models/subtitles.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Stack(children: [child]),
      ),
    );

void main() {
  testWidgets('没有当前字幕时不占位（不挡手势、不留黑底）', (tester) async {
    await tester.pumpWidget(_host(const SubtitleOverlay(cue: null)));
    expect(find.byType(Text), findsNothing);
    // 只应存在占位的 SizedBox
    expect(find.byType(SizedBox), findsWidgets);
  });

  testWidgets('有字幕时显示文本', (tester) async {
    await tester.pumpWidget(
      _host(
        const SubtitleOverlay(
          cue: SubtitleCue(start: 0, end: 2, text: '这是一句字幕'),
        ),
      ),
    );
    expect(find.text('这是一句字幕'), findsOneWidget);
  });

  testWidgets('AI 字幕必须带标注', (tester) async {
    const track = SubtitleTrackInfo(
      lan: 'ai-zh',
      label: '中文',
      url: 'https://example.invalid',
      isAi: true,
    );
    await tester.pumpWidget(
      _host(
        SubtitleOverlay(
          cue: const SubtitleCue(start: 0, end: 2, text: '机器识别的字'),
          cornerLabel: '字幕：${track.displayLabel}',
        ),
      ),
    );
    expect(find.text('机器识别的字'), findsOneWidget);
    expect(find.text('字幕：中文（AI）'), findsOneWidget);
  });

  test('cueAt 在空隙与边界上的行为', () {
    const cues = [
      SubtitleCue(start: 1, end: 2, text: 'a'),
      SubtitleCue(start: 5, end: 6, text: 'b'),
    ];
    expect(cueAt(cues, const Duration(milliseconds: 500)), isNull);
    expect(cueAt(cues, const Duration(milliseconds: 1500))?.text, 'a');
    // 两条之间是空隙，不该把前一条一直挂着
    expect(cueAt(cues, const Duration(milliseconds: 3000)), isNull);
    expect(cueAt(cues, const Duration(milliseconds: 5500))?.text, 'b');
    expect(cueAt(cues, const Duration(seconds: 60)), isNull);
    expect(cueAt(const [], Duration.zero), isNull);
  });
}
