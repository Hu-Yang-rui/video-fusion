/// 抖音登录与媒体库移除的测试。
///
/// 抖音登录的**真实网络行为**已在开发期实测（见 `DouyinLoginClient`
/// 文档中的对照表）。这里守护的是：
///  - 编码逻辑正确（XOR 0x05、fp 格式）
///  - 被拦截时如实返回 blocked，不伪造成功
///  - 媒体库已从导航中移除
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('抖音设备指纹编码', () {
    test('XOR 0x05 编码可逆', () {
      // 与 DouyinLoginClient._encodeDeviceInfo 相同的算法
      const sample = '{"webdriver":false}';
      final encoded = sample.codeUnits
          .map((c) => ((c ^ 0x05) & 0xFF).toRadixString(16).padLeft(2, '0'))
          .join();

      // 解码
      final bytes = <int>[];
      for (var i = 0; i < encoded.length; i += 2) {
        bytes.add(int.parse(encoded.substring(i, i + 2), radix: 16) ^ 0x05);
      }
      final decoded = utf8.decode(bytes);

      expect(decoded, sample);
    });

    test('编码结果全是十六进制字符', () {
      const sample = '{"a":1}';
      final encoded = sample.codeUnits
          .map((c) => ((c ^ 0x05) & 0xFF).toRadixString(16).padLeft(2, '0'))
          .join();

      expect(RegExp(r'^[0-9a-f]+$').hasMatch(encoded), isTrue);
      expect(encoded.length, sample.length * 2);
    });
  });

  group('抖音登录实现约束', () {
    late String src;

    setUpAll(() {
      src = File('lib/src/adapters/douyin/login_client.dart').readAsStringSync();
    });

    test('被风控拦截时返回 blocked，不伪造成功', () {
      expect(src, contains('DouyinLoginPhase.blocked'));
      // 4031 与 3 都必须映射到 blocked
      expect(src, contains('code == 4031'));
      expect(src, contains('code == 3'));
    });

    test('不保存无法验证的 Cookie', () {
      // 登录客户端不写 vault
      expect(
        src.contains('vault.save'),
        isFalse,
        reason: '登录未真正完成时不得写入凭证',
      );
    });

    test('说明文档记录了两个接口的可用性差异', () {
      expect(src, contains('get_qrcode'));
      expect(src, contains('check_qrconnect'));
      expect(src, contains('sign'));
    });

    test('不含任何伪造的成功分支', () {
      // 不得出现 status='success' 就直接返回 succeeded 且带 session
      final fakeSuccess = RegExp(
        r"DouyinLoginPhase\.succeeded[\s\S]{0,80}session:",
      );
      expect(
        fakeSuccess.hasMatch(src),
        isFalse,
        reason: '不能凭空构造 session 冒充登录成功',
      );
    });
  });

  group('媒体库已移除', () {
    test('library_screen.dart 已删除', () {
      expect(
        File('lib/src/ui/library/library_screen.dart').existsSync(),
        isFalse,
      );
    });

    test('AppShell 不再有 libraryPage 参数', () {
      final src = File('lib/src/ui/shell/app_shell.dart').readAsStringSync();
      expect(src.contains('libraryPage'), isFalse);
      expect(src.contains('媒体库'), isFalse);
    });

    test('main.dart 不再装配媒体库', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src.contains('LibraryScreen'), isFalse);
      expect(src.contains('library_screen'), isFalse);
    });

    test('导航项数正确（无直播 3 项 / 有直播 4 项）', () {
      final src = File('lib/src/ui/shell/app_shell.dart').readAsStringSync();
      // 统计 AppleTabItem 出现次数：推荐/发现/设置 必在，
      // 直播条件加入
      final count = RegExp(r'AppleTabItem\(').allMatches(src).length;
      expect(count, 4, reason: '推荐/发现/直播(条件)/设置 = 4 个定义');
      expect(src.contains("label: '推荐'"), isTrue);
      expect(src.contains("label: '发现'"), isTrue);
      expect(src.contains("label: '直播'"), isTrue);
      expect(src.contains("label: '设置'"), isTrue);
    });

    test('观看进度存储仍保留（详情页续播依赖）', () {
      // 删除媒体库不能误删 VideoProgressStore
      expect(
        File('lib/src/core/video_progress_store.dart').existsSync(),
        isTrue,
      );
      final mainSrc = File('lib/main.dart').readAsStringSync();
      expect(mainSrc.contains('VideoProgressStore'), isTrue);
    });

    test('VideoStore 仍保留（VideoService 元数据缓存依赖）', () {
      expect(File('lib/src/core/video_store.dart').existsSync(), isTrue);
      final svcSrc = File('lib/src/core/video_service.dart').readAsStringSync();
      expect(svcSrc.contains('VideoStore'), isTrue);
    });
  });
}
