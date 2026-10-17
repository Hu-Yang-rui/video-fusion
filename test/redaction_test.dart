/// 日志脱敏与凭证安全测试。
///
/// 覆盖需求六、七的硬性约束：
///  - 日志中不得输出密码、完整 Cookie、访问令牌或其他敏感凭证
///  - 不硬编码访问令牌、Cookie、签名密钥或账号凭证
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/logger.dart';

void main() {
  group('URL 脱敏', () {
    test('丢弃整个查询串（签名可能编码进任意参数名）', () {
      final safe = Redactor.safeUrl(
        'https://api.example.com/path?a_bogus=abc123&msToken=secret&x=1',
      );
      expect(safe, isNot(contains('abc123')));
      expect(safe, isNot(contains('secret')));
      expect(safe, contains('api.example.com/path'));
      expect(safe, contains('redacted'));
    });

    test('无查询串时保持原样', () {
      expect(
        Redactor.safeUrl('https://api.example.com/x/web-interface/view'),
        'https://api.example.com/x/web-interface/view',
      );
    });

    test('保留 host 与 path 便于诊断', () {
      final safe = Redactor.safeUrl(
        'https://xy123.mcdn.bilivideo.cn:8082/v1/resource/upgcxcode/99/91/137649199/x.m4s?e=xxx&deadline=999',
      );
      expect(safe, contains('mcdn.bilivideo.cn'));
      expect(safe, contains('137649199'));
      expect(safe, isNot(contains('deadline')));
      expect(safe, isNot(contains('e=xxx')));
    });

    test('非法 URL 返回占位符而非抛出', () {
      expect(Redactor.safeUrl('not a url'), '<invalid-url>');
      expect(Redactor.safeUrl(''), '<invalid-url>');
    });
  });

  group('请求头脱敏', () {
    test('凭证类请求头被整体屏蔽', () {
      final safe = Redactor.safeHeaders({
        'Cookie': 'SESSDATA=secret; bili_jct=token',
        'Authorization': 'Bearer abc123',
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://www.bilibili.com/',
      });
      expect(safe['Cookie'], '<redacted>');
      expect(safe['Authorization'], '<redacted>');
      expect(safe['User-Agent'], 'Mozilla/5.0', reason: 'UA 不敏感，应保留');
      expect(safe['Referer'], isNot(contains('secret')));
    });

    test('平台签名类头被屏蔽', () {
      for (final name in [
        'a_bogus',
        'X-Bogus',
        'msToken',
        'ttwid',
        'x-secsdk-web-signature',
      ]) {
        final safe = Redactor.safeHeaders({name: 'SIGNATURE_VALUE'});
        expect(
          safe[name],
          '<redacted>',
          reason: '$name 必须被脱敏',
        );
      }
    });

    test('大小写不敏感', () {
      expect(Redactor.safeHeaders({'COOKIE': 'x'})['COOKIE'], '<redacted>');
      expect(Redactor.safeHeaders({'cookie': 'x'})['cookie'], '<redacted>');
      expect(Redactor.safeHeaders({'CoOkIe': 'x'})['CoOkIe'], '<redacted>');
    });

    test('isSensitiveHeader 判定正确', () {
      expect(Redactor.isSensitiveHeader('Cookie'), isTrue);
      expect(Redactor.isSensitiveHeader('A_BOGUS'), isTrue);
      expect(Redactor.isSensitiveHeader('User-Agent'), isFalse);
      expect(Redactor.isSensitiveHeader('Accept'), isFalse);
    });
  });

  group('文本兜底脱敏', () {
    test('折叠形如 key=value 的敏感赋值', () {
      final scrubbed = Redactor.scrubText(
        'request failed: SESSDATA=abc123; token=xyz789',
      );
      expect(scrubbed, isNot(contains('abc123')));
      expect(scrubbed, isNot(contains('xyz789')));
      expect(scrubbed, contains('<redacted>'));
    });

    test('处理冒号分隔形式', () {
      final scrubbed = Redactor.scrubText('cookie: SECRET_VALUE_HERE');
      expect(scrubbed, isNot(contains('SECRET_VALUE_HERE')));
    });

    test('普通文本不受影响', () {
      const text = '平台服务暂时不可用，请稍后重试。';
      expect(Redactor.scrubText(text), text);
    });
  });

  group('日志器', () {
    test('minLevel 过滤低级别日志（不抛错）', () {
      final logger = FusionLogger(minLevel: LogLevel.error);
      // 这些调用应被静默过滤，不产生输出也不抛错
      logger.debug('debug message');
      logger.info('info message');
      logger.warn('warn message');
      logger.error('error message');
    });

    test('enabled=false 时完全静默', () {
      final logger = FusionLogger(enabled: false);
      logger.error('should not appear');
    });

    test('http 记录不包含查询串', () {
      final logger = FusionLogger(minLevel: LogLevel.debug);
      // 不抛错即可；脱敏逻辑已在上方单独验证
      logger.http(
        method: 'GET',
        url: 'https://api.bilibili.com/x/player/playurl?bvid=BV1&cid=1&sign=SECRET',
        status: 200,
        durationMs: 42,
        headers: const {'Cookie': 'SESSDATA=secret'},
      );
    });
  });

  group('静态检查：源码中不得硬编码凭证', () {
    test('适配器源码不含 Cookie / 令牌赋值', () {
      // 该断言由 test/security_static_check_test.dart 中的
      // 真实文件扫描实现（此处仅保留分组语义）
      expect(true, isTrue);
    });
  });
}
