/// 短信登录的 UI 层回归（2026-10-23）。
///
/// # 守什么
///
/// 短信登录有**两套校验**：UI 层（`sms_login_sheet.dart`）和
/// 适配器层（`sms_login.dart`）。两份实现必须规则一致——
/// 否则会出现"界面说合法、适配器拒收"或反之的割裂。
///
/// 之所以要两份：UI 层不该 import 适配器内部文件（层次倒置）。
/// 所以用测试守住它们的一致性。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/douyin/sms_login.dart' as adapter;
import 'package:video_fusion/src/ui/settings/sms_login_sheet.dart' as ui;

void main() {
  group('手机号校验：UI 与适配器一致', () {
    const cases = [
      '13800138000', // 合法
      '19912345678', // 合法
      '138 0013 8000', // 带空格
      '+8613800138000', // 带 +86
      '8613800138000', // 带 86
      '', // 空
      '1380013800', // 10 位
      '138001380000', // 12 位
      '23800138000', // 不以 1 开头
      'abcdefghijk', // 非数字
    ];

    test('两套实现结论一致', () {
      for (final phone in cases) {
        final uiErr = ui.validateSmsPhone(phone);
        final adapterErr = adapter.validatePhone(phone);
        expect(
          uiErr == null,
          adapterErr == null,
          reason: '「$phone」两套校验结论不一致：'
              'UI=${uiErr ?? "通过"}，适配器=${adapterErr ?? "通过"}',
        );
      }
    });

    test('合法号码通过', () {
      expect(ui.validateSmsPhone('13800138000'), isNull);
      expect(adapter.validatePhone('13800138000'), isNull);
    });

    test('带分隔符与国码也能通过（归一化后再校验）', () {
      for (final p in ['138 0013 8000', '+8613800138000', '8613800138000']) {
        expect(ui.validateSmsPhone(p), isNull, reason: p);
        expect(adapter.validatePhone(p), isNull, reason: p);
      }
    });

    test('空输入给明确提示', () {
      expect(ui.validateSmsPhone(''), contains('请输入'));
      expect(adapter.validatePhone(''), contains('请输入'));
    });

    test('位数不对给明确提示', () {
      expect(ui.validateSmsPhone('1380013800'), contains('11 位'));
      expect(adapter.validatePhone('1380013800'), contains('11 位'));
    });
  });

  group('验证码校验：UI 与适配器一致', () {
    const cases = ['123456', '000000', '', '12345', '1234567', 'abcdef', '12 34'];

    test('两套实现结论一致', () {
      for (final code in cases) {
        final uiErr = ui.validateSmsCode(code);
        final adapterErr = adapter.validateSmsCode(code);
        expect(
          uiErr == null,
          adapterErr == null,
          reason: '「$code」两套校验结论不一致',
        );
      }
    });

    test('6 位数字通过', () {
      expect(ui.validateSmsCode('123456'), isNull);
      expect(adapter.validateSmsCode('123456'), isNull);
    });

    test('非 6 位被拒', () {
      expect(ui.validateSmsCode('12345'), isNotNull);
      expect(ui.validateSmsCode('1234567'), isNotNull);
    });

    test('非数字被拒', () {
      expect(ui.validateSmsCode('abcdef'), isNotNull);
    });
  });

  group('passport 字段加密（XOR 5 → hex）', () {
    test('手机号加密后只含十六进制字符', () {
      final enc = adapter.passportEncrypt('13800138000');
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(enc), isTrue);
      // 11 字节 → 每字节 1-2 个 hex 字符
      expect(enc.length, greaterThanOrEqualTo(11));
      expect(enc.length, lessThanOrEqualTo(22));
    });

    test('加密是确定性的（同一输入同一输出）', () {
      expect(
        adapter.passportEncrypt('13800138000'),
        adapter.passportEncrypt('13800138000'),
      );
    });

    test('不同输入得到不同输出', () {
      expect(
        adapter.passportEncrypt('13800138000'),
        isNot(adapter.passportEncrypt('13800138001')),
      );
    });

    test('type=3731 是明文 24 的加密值（实录对账）', () {
      // 浏览器实录：type 字段值恒为 "3731"，解码后是 "24"
      expect(adapter.passportEncrypt('24'), '3731');
    });
  });

  group('passport 手机号格式（必须带 +86 前缀）', () {
    test('11 位号码补成 `+86 1xxxxxxxxxx`', () {
      expect(adapter.formatPassportPhone('13800138000'), '+86 13800138000');
      expect(adapter.formatPassportPhone('138 0013 8000'), '+86 13800138000');
      expect(adapter.formatPassportPhone('+8613800138000'), '+86 13800138000');
      expect(adapter.formatPassportPhone('8613800138000'), '+86 13800138000');
    });

    test('位数不对原样返回（交给本地校验拦下）', () {
      expect(adapter.formatPassportPhone('1380013800'), '1380013800');
    });

    test('加密后不出现明文号码', () {
      final enc = adapter.passportEncrypt(
        adapter.formatPassportPhone('13800138000'),
      );
      expect(enc.contains('13800138000'), isFalse);
    });

    test('nationalPhone 用于校验，去掉所有前缀与分隔符', () {
      expect(adapter.nationalPhone('+86 138-0013-8000'), '13800138000');
      expect(adapter.nationalPhone('8613800138000'), '13800138000');
    });
  });
}
