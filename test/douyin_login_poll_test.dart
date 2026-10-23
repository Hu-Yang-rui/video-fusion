/// 抖音扫码登录的离线回归（2026-10-23）。
///
/// # 修掉的两个真 bug
///
/// 模拟器实测发现扫码登录永远失败（提示"风控拦截了本次登录"）。
/// 根因有两个，都不是"抖音不给登录"，而是代码把平台的正常响应当成失败：
///
/// ## ① status 是字符串，代码只认数字
///
/// 实测 `check_qrconnect` 的正常响应：
/// ```json
/// {"data":{"error_code":0,"status":"new"},"message":"success"}
/// ```
/// 但旧代码 `switch (status)` 只匹配 `'1'`/`'2'`/`'3'`，
/// `"new"` 落进 `default` → 报"未知登录状态：new"。
/// 即使真扫码成功（`status` 为 `"confirmed"` 之类），也永远匹配不到
/// 成功分支——**登录功能整体不可用**。
///
/// ## ② error_code 缺失被当成错误
///
/// 旧代码 `?? -1`，把"平台没给这个字段"当成错误码 -1，
/// 直接走 `code != 0` 报「登录失败（错误码 -1）」。
///
/// # 还有一个环境相关的坑（不在本文件测）
///
/// `Referer` 是浏览器禁止 JS 修改的请求头。WebView 停在视频页时，
/// passport 接口的 Referer 变成视频页 URL → 抖音返回 4031。
/// 修法是登录前把页面导航到首页（`_ensureOnHomePage`）。
/// 这条需要真机/模拟器验证，离线测不了。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/src/adapters/douyin/web_signer.dart').readAsStringSync();
  });

  group('pollLoginQr：status 字符串映射', () {
    /// 取 pollLoginQr 方法体，避免误匹配到文件其它位置的同名 case。
    String pollBody() {
      final start = src.indexOf('Future<DouyinLoginPoll> pollLoginQr');
      expect(start, greaterThan(0), reason: '找不到 pollLoginQr');
      final end = src.indexOf('passport 接口的固定参数', start);
      expect(end, greaterThan(start));
      return src.substring(start, end);
    }

    test('认字符串 "new"（实测未扫码状态）', () {
      expect(pollBody().contains("case 'new':"), isTrue,
          reason: '实测 status="new" 是最常见的正常状态，不认就会报错');
    });

    test('认字符串 "expired"', () {
      expect(pollBody().contains("case 'expired':"), isTrue);
    });

    test('认字符串 "scanned"（已扫码待确认）', () {
      expect(pollBody().contains("case 'scanned':"), isTrue);
    });

    test('认字符串 "confirmed" 与 "success"（登录成功）', () {
      final b = pollBody();
      expect(b.contains("case 'confirmed':"), isTrue,
          reason: '成功分支不认字符串就永远登录不了');
      expect(b.contains("case 'success':"), isTrue);
    });

    test('保留数字形式兼容（1/2/3）', () {
      final b = pollBody();
      expect(b.contains("case '1':"), isTrue);
      expect(b.contains("case '2':"), isTrue);
      expect(b.contains("case '3':"), isTrue);
    });

    test('未知状态仍然如实报错（不静默成功）', () {
      expect(pollBody().contains('未知登录状态'), isTrue);
    });
  });

  group('pollLoginQr：error_code 语义', () {
    String pollBody() {
      final start = src.indexOf('Future<DouyinLoginPoll> pollLoginQr');
      final end = src.indexOf('passport 接口的固定参数', start);
      return src.substring(start, end);
    }

    test('不再把缺失的 error_code 当成 -1', () {
      expect(
        pollBody().contains("(d['error_code'] as num?)?.toInt() ?? -1"),
        isFalse,
        reason: '这就是 bug：缺失被当成错误码 -1，正常响应被误判为失败',
      );
    });

    test('只有明确非 0 错误码才算失败', () {
      expect(pollBody().contains('code != null && code != 0'), isTrue);
    });

    test('4031 仍映射为 blocked（风控）', () {
      expect(pollBody().contains('code == 4031'), isTrue);
      expect(pollBody().contains('DouyinLoginPhase.blocked'), isTrue);
    });
  });

  group('Referer 修复', () {
    test('存在 _ensureOnHomePage，且短信登录入口调用它', () {
      expect(src.contains('Future<void> _ensureOnHomePage()'), isTrue);
      // 扫码路径现在优先走页面弹窗（fetchLoginQr 开头调
      // _openLoginModalAndGrabQr），所以这里改守短信入口。
      final idx = src.indexOf('Future<void> sendSmsCode(String phone)');
      expect(idx, greaterThan(0), reason: '短信登录是当前可用路径');
      final block = src.substring(idx, (idx + 900).clamp(0, src.length));
      expect(block.contains('_ensureOnHomePage()'), isTrue,
          reason: 'Referer 由页面地址决定，登录前必须把页面挪回首页');
    });

    test('pollLoginQr 每次轮询前也校正页面', () {
      final start = src.indexOf('Future<DouyinLoginPoll> pollLoginQr');
      final end = src.indexOf('passport 接口的固定参数', start);
      final body = src.substring(start, end);
      expect(body.contains('_ensureOnHomePage()'), isTrue,
          reason: '轮询期间页面可能被导航走，Referer 一变就 4031');
    });

    test('注释说明了 Referer 不可由 JS 设置', () {
      expect(
        src.contains('Referer') &&
            (src.contains('禁止 JS 修改') || src.contains('禁止修改')),
        isTrue,
        reason: '这个坑必须写清楚，否则后人会再试一遍改 header',
      );
    });
  });
}
