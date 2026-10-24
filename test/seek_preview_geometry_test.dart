/// 进度条预览的定位（纯几何，不打网络）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/design/components/video_widgets.dart';

void main() {
  group('seekPreviewLeft', () {
    test('居中：指针在中间时左右留白相等', () {
      const track = 368.0; // 比预览宽(168)大一档，能居中
      final left = seekPreviewLeft(track, 0.5);
      expect(left, (track - kSeekPreviewWidth) / 2);
    });

    test('左端夹住：进度 0 时不出现负偏移', () {
      expect(seekPreviewLeft(368.0, 0.0), 0);
    });

    test('右端夹住：进度 1 时不越出轨道', () {
      const track = 368.0;
      expect(seekPreviewLeft(track, 1.0), track - kSeekPreviewWidth);
    });

    test('轨道比预览还窄时恒为 0（不返回负数）', () {
      expect(seekPreviewLeft(100.0, 0.5), 0);
      expect(seekPreviewLeft(100.0, 1.0), 0);
    });

    test('全程不越界', () {
      const track = 368.0;
      const max = track - kSeekPreviewWidth;
      for (var p = 0.0; p <= 1.0001; p += 0.05) {
        final l = seekPreviewLeft(track, p);
        expect(l, inInclusiveRange(0, max), reason: 'progress=$p');
      }
    });
  });
}
