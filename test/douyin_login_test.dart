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

    test('风控拦截时返回 blocked，不伪造成功', () {
      expect(src, contains('DouyinLoginPhase.blocked'));
      // 4031（安全风险）必须映射到 blocked
      expect(src, contains('code == 4031'));
    });

    test('token 放在 POST body 里（这是之前失败的原因）', () {
      // 关键：token 在 body，不在 query
      expect(
        src.contains("'&token=\${challenge.token}'"),
        isTrue,
        reason: 'token 必须在 POST body 里，放 query 会返回 error_code 3',
      );
    });

    test('使用纯 Dart 的 a_bogus 签名', () {
      expect(src, contains('ABogus'));
      expect(src, contains("import '_abogus.dart'"));
    });

    test('签名同时覆盖 query 与 body', () {
      // a_bogus 必须基于完整 query + body 计算
      expect(src, contains('getValue(query, body: body)'));
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

    test('登录成功只有一个出口，且必须先校验凭证', () {
      // 旧断言是一条正则：禁止 `succeeded` 附近出现 `session:`。
      // 那是为了防"status=confirmed 就直接伪造 session"。
      // 但凭证换取实现后，合法的 succeeded 本来就该带 session，
      // 正则会把正确代码也判为违规。
      //
      // 改为断言真正的不变量：succeeded 只有一个返回点（便于审计），
      // 且该路径必须经过 _buildSession 的空值检查。
      // 统计"把相位置为 succeeded"的位置（不含 getter 里的比较）
      final succeededReturns =
          RegExp(r'phase: DouyinLoginPhase\.succeeded').allMatches(src).length;
      expect(succeededReturns, 1,
          reason: '只允许一个 succeeded 出口，任何新增都必须过审');

      expect(
        src.contains('if (session == null)'),
        isTrue,
        reason: '拿到凭证前必须先判空，空则如实报失败',
      );

      expect(
        src.contains('final session = _buildSession();'),
        isTrue,
        reason: '会话必须由真实 cookie 构造，不能内联伪造',
      );
    });

    test('会话凭证必须来自真实下发的 cookie', () {
      // _buildSession 只在命中会话 cookie 时才产出会话
      for (final key in ['sessionid', 'sessionid_ss', 'sid_tt', 'sid_guard']) {
        expect(src.contains("'$key'"), isTrue,
            reason: '必须识别会话 cookie：$key');
      }
      expect(
        src.contains('if (!hasSession) return null;'),
        isTrue,
        reason: '没有会话 cookie 时必须返回 null，不得兜底造一个',
      );
    });

    test('HTTP 层必须接住 Set-Cookie', () {
      final httpSrc =
          File('lib/src/core/http_client.dart').readAsStringSync();
      expect(httpSrc.contains('set-cookie'), isTrue,
          reason: 'Set-Cookie 必须单独读取，否则会话凭证被丢弃');
      expect(httpSrc.contains('parsedSetCookies'), isTrue);
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
