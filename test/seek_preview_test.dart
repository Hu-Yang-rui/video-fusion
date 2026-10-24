/// 进度条预览的几何映射，用真实抓包对账（101s / 42 帧、6867s / 1290 帧）。
///
/// 抓包不入公开仓库，缺失时显式跳过而非报错。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/seek_preview.dart';

import 'support/local_fixtures.dart';

final Object _missing = skipIfMissing([
  'tool/live/_videoshot_A_login.json',
  'tool/live/_vs2_LONG_aid_index1_HTTP200.json',
]);

const _cellW = 480.0;
const _cellH = 270.0;

SpriteSheetSpec loadSpec(String file) {
  final raw = File('tool/live/$file').readAsStringSync();
  final spec = SpriteSheetSpec.parse(
    Map<String, Object?>.from(jsonDecode(raw) as Map),
  );
  expect(spec, isNotNull, reason: '$file 解析失败');
  return spec!;
}

void main() {
  late SpriteSheetSpec short;
  late SpriteSheetSpec longV;

  setUpAll(() {
    if (_missing is String) return;
    short = loadSpec('_videoshot_A_login.json');
    longV = loadSpec('_vs2_LONG_aid_index1_HTTP200.json');
  });

  group('parse', () {
    test('短视频：42 帧 / 10×10 / 480×270 / 1 张图', () {
      expect(short.cols, 10);
      expect(short.rows, 10);
      expect(short.cellWidth, 480);
      expect(short.cellHeight, 270);
      expect(short.frames.length, 42);
      expect(short.sheetUrls.length, 1);
      expect(short.totalSeconds, 245);
      expect(short.framesPerSheet, 100);
      // 协议相对地址必须补全成 https
      expect(short.sheetUrls.first.startsWith('https://'), isTrue);
    }, skip: _missing);

    test('长视频：1290 帧 / 13 张图', () {
      expect(longV.frames.length, 1290);
      expect(longV.sheetUrls.length, 13);
      expect(longV.totalSeconds, 6867);
      // 图数 = ⌈帧数 / 格子数⌉
      expect(
        longV.sheetUrls.length,
        (longV.frames.length / longV.framesPerSheet).ceil(),
      );
    }, skip: _missing);

    // 这一条只用构造数据，不依赖抓包
    test('缺字段一律返回 null，不猜默认值', () {
      expect(SpriteSheetSpec.parse(const {}), isNull);
      expect(SpriteSheetSpec.parse(const {'data': 'x'}), isNull);
      expect(
        SpriteSheetSpec.parse(const {
          'data': {'img_x_len': 10},
        }),
        isNull,
      );
      // 有格子尺寸但没帧表 → 无法定位，判为不可用
      expect(
        SpriteSheetSpec.parse(const {
          'data': {
            'img_x_len': 10,
            'img_y_len': 10,
            'img_x_size': 480,
            'img_y_size': 270,
            'image': ['//x/1.jpg'],
          },
        }),
        isNull,
      );
    });
  });

  group('帧定位', () {
    test('落在两帧之间取上一帧（不显示未来的画面）', () {
      // 实测 index 前 8 = 0,0,5,11,18,23,30,36
      expect(short.frames[0], 0);
      expect(short.frames[2], 5);
      expect(short.frames[3], 11);
      expect(frameIndexAt(short, 8), 2); // 5 ≤ 8 < 11
      expect(frameIndexAt(short, 11), 3); // 恰好命中
      expect(frameIndexAt(short, 10.9), 2);
    }, skip: _missing);

    test('边界：早于首帧给 0，晚于末帧给最后一帧', () {
      expect(frameIndexAt(short, -5), 0);
      expect(frameIndexAt(short, 0), 0);
      expect(frameIndexAt(short, 99999), short.frames.length - 1);
    }, skip: _missing);

    test('每一帧都能定位回自己（二分不错位）', () {
      for (final s in [short, longV]) {
        for (var i = 0; i < s.frames.length; i++) {
          final got = frameIndexAt(s, s.frames[i]);
          // index 开头有重复的 0，允许命中同值的前一条
          expect(s.frames[got], s.frames[i], reason: '第 $i 帧时间值不符');
          expect(got, lessThanOrEqualTo(i), reason: '第 $i 帧定位到了未来');
        }
      }
    }, skip: _missing);
  });

  group('拼图位置', () {
    test('短视频最后一帧（41）在第 1 张图第 5 行第 0 列', () {
      final c = cellFor(short, 41);
      expect(c.sheetIndex, 0);
      expect(c.rect.left, (41 % 10) * _cellW); // 1920
      expect(c.rect.top, (41 ~/ 10) * _cellH); // 270
      expect(c.rect.width, _cellW);
      expect(c.rect.height, _cellH);
    }, skip: _missing);

    test('长视频第 1289 帧落在最后一张图', () {
      final c = cellFor(longV, 1289);
      expect(c.sheetIndex, 12);
      expect(c.sheetUrl, longV.sheetUrls[12]);
      expect(c.rect.left, (89 % 10) * _cellW);
      expect(c.rect.top, (89 ~/ 10) * _cellH);
    }, skip: _missing);

    test('格坐标恒在图内（越界帧被夹住）', () {
      for (final s in [short, longV]) {
        for (final i in [0, 1, 99, 100, 101, s.frames.length - 1, 99999]) {
          final c = cellFor(s, i);
          expect(
            c.rect.left,
            inInclusiveRange(0, (s.cols - 1) * _cellW),
            reason: '帧 $i 的水平偏移越界',
          );
          expect(
            c.rect.top,
            inInclusiveRange(0, (s.rows - 1) * _cellH),
            reason: '帧 $i 的垂直偏移越界',
          );
          expect(
            c.sheetIndex,
            inInclusiveRange(0, s.sheetUrls.length - 1),
            reason: '帧 $i 指向了不存在的图',
          );
        }
      }
    }, skip: _missing);

    test('帧序号跨越整图边界时图号正确递增', () {
      // 第 99 帧仍在第 1 张（下标 0），第 100 帧起进入第 2 张
      expect(cellFor(longV, 99).sheetIndex, 0);
      expect(cellFor(longV, 100).sheetIndex, 1);
      expect(cellFor(longV, 100).rect.top, 0);
      expect(cellFor(longV, 100).rect.left, 0);
    }, skip: _missing);
  });
}