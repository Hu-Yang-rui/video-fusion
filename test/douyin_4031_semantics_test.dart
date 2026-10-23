/// 抖音 4031 的真实语义（2026-10-23 实测）。
///
/// # 实测证据
///
/// App 内（Android WebView）请求 `check_qrconnect` 得到的响应：
/// ```json
/// {"data":{"captcha":"", "desc_url":"",
///   "description":"您正在尝试访问的网站存在安全风险，为保护您的抖音
///     账号安全与隐私，已阻止此次访问。",
///   "error_code":4031},
///  "message":"error"}
/// ```
///
/// 原生直连 `get_qrcode` 得到**完全相同**的结构（`captcha` 与
/// `desc_url` 都是空串）。所以：
///
///  - 这是平台对**当前环境**的定向阻断，不是"需要用户点验证"
///  - `desc_url` 为空 ⇒ 没有可自动跑的验证页 ⇒ 客户端无法自动完成
///  - 同环境下 `aweme/detail`、`search` 正常返回 ⇒ 不是 IP 全站封禁
///
/// # 曾经的错误处理
///
/// 旧代码把 4031 一律当"风控拦截"，提示"去浏览器导入 Cookie"——
/// 方向对但没解释原因，用户以为是自己账号有问题。
///
/// 本轮加过一版"自动过验证"（加载 desc_url 让 SDK 自己跑），
/// 但实测 `desc_url` 为空，那条路径根本不触发。保留代码是为了
/// 万一将来平台改回"给验证通道"时能自动恢复，但**不能假装它现在能用**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('lib/src/adapters/douyin/web_signer.dart').readAsStringSync();
  });

  String pollBody() {
    final start = src.indexOf('Future<DouyinLoginPoll> pollLoginQr');
    expect(start, greaterThan(0));
    final end = src.indexOf('passport 接口的固定参数', start);
    expect(end, greaterThan(start));
    return src.substring(start, end);
  }

  group('4031 处理', () {
    test('读取 desc_url 与 description，而不是硬编码提示', () {
      final b = pollBody();
      expect(b.contains("d['desc_url']"), isTrue);
      expect(b.contains("d['description']"), isTrue);
    });

    test('不再有"无条件自动验证"分支', () {
      final b = pollBody();
      expect(
        b.contains('captchaRetry'),
        isFalse,
        reason: 'desc_url 恒空，自动验证分支永不执行，已删除',
      );
    });

    test('desc_url 为空时如实报 blocked + 平台原话', () {
      final b = pollBody();
      expect(b.contains('DouyinLoginPhase.blocked'), isTrue);
      expect(
        b.contains('抖音拒绝了本次登录'),
        isTrue,
        reason: '要告诉用户是平台拒绝，不是他的账号有问题',
      );
    });

    test('注释记录了 captcha/desc_url 为空这个关键事实', () {
      expect(
        src.contains('captcha') &&
            (src.contains('都是空串') || src.contains('不提供验证通道')),
        isTrue,
        reason: '这是本轮最重要的实测结论，必须写死在代码里',
      );
    });

    test('注释说明了不是 IP 全站封禁', () {
      expect(
        src.contains('定向阻断') || src.contains('不是 IP 全站封禁'),
        isTrue,
        reason: '普通接口正常、只有登录被拦，这个区别决定了该不该换 IP',
      );
    });
  });

  group('自动验证机制（已删除）', () {
    // 曾实现 `_runCaptchaInWebView`：加载 desc_url 让 rmc-nocaptcha SDK
    // 自己跑完。但实测 `desc_url` 恒为空串——平台不给验证通道，
    // 那段代码永不执行，已作为死代码删除。
    //
    // 这里守"别再加回来"：如果将来有人重新实现，必须先确认
    // desc_url 真的非空。
    test('_runCaptchaInWebView 已移除', () {
      expect(
        src.contains('_runCaptchaInWebView'),
        isFalse,
        reason: 'desc_url 恒空，这段代码永不执行；要恢复需先证明平台会给 desc_url',
      );
    });

    test('captchaRetry 参数已移除（它只为自动验证存在）', () {
      expect(src.contains('captchaRetry'), isFalse);
    });
  });

  group('登录前校正页面（Referer 修复）', () {
    test('sendSmsCode 前也校正页面', () {
      final idx = src.indexOf('Future<void> sendSmsCode(String phone)');
      expect(idx, greaterThan(0), reason: '短信登录入口应存在');
      final block = src.substring(idx, (idx + 900).clamp(0, src.length));
      expect(block.contains('_ensureOnHomePage()'), isTrue);
    });

    test('注释说明 Referer 不能由 JS 设置', () {
      expect(
        src.contains('禁止 JS 修改') || src.contains('禁止修改'),
        isTrue,
        reason: '否则后人会再试一遍在 fetch 里改 Referer（无效）',
      );
    });
  });
}
