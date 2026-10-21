/// 红果入口存在性测试。
///
/// 用户报告"看不到红果短剧的入口"。根因有二：
///
///  1. 适配器注册后曾遗漏（import 了但没进 registry），导致
///     发现页来源里根本没有它；
///  2. 来源标签写的是「首页推荐」——发现页的来源是一排 chip，
///     用户只能靠标签认出平台，不带平台名的标签等于没有入口。
///
/// 这两条都是静态可检查的，用测试钉死。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('红果入口存在性', () {
    late String mainSrc;
    late String adapterSrc;

    setUpAll(() {
      mainSrc = File('lib/main.dart').readAsStringSync();
      adapterSrc =
          File('lib/src/adapters/hongguo_adapter.dart').readAsStringSync();
    });

    test('HongguoAdapter 已注册进 PlatformRegistry', () {
      expect(
        mainSrc.contains('HongguoAdapter(http:'),
        isTrue,
        reason: 'main.dart 必须把 HongguoAdapter 注册进 registry，'
            '否则发现页来源里不会有红果',
      );
    });

    test('来源标签带平台名（不是「首页推荐」）', () {
      expect(
        adapterSrc.contains("label: '红果短剧'"),
        isTrue,
        reason: '发现页的来源是一排 chip，用户只能靠标签认出平台；'
            '「首页推荐」会与 B站/抖音的推荐来源混淆',
      );
    });

    test('来源 id 带平台前缀（不与其它平台撞名）', () {
      expect(
        adapterSrc.contains("feedSourceHome = 'hongguo:home'"),
        isTrue,
        reason: '来源 id 全仓库共享一个命名空间，裸 id（home）有撞名风险',
      );
    });

    test('来源 description 有内容', () {
      expect(
        adapterSrc.contains("description: '热播短剧、真人剧、漫剧'"),
        isTrue,
      );
    });
  });
}
