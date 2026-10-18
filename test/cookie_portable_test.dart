/// Cookie 导入 / 导出的测试。
///
/// 覆盖真实使用场景：从浏览器复制 Cookie 串、从 curl 复制、
/// JSON 格式、本应用导出格式，以及各种畸形输入。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/core/cookie_portable.dart';
import 'package:video_fusion/src/core/credential_vault.dart';

PlatformSession _biliSession() => PlatformSession(
      platformId: 'bilibili',
      displayName: '测试用户',
      userId: '12345',
      cookies: const {
        'SESSDATA': 'abc%2Cdef',
        'bili_jct': 'deadbeef',
        'DedeUserID': '12345',
      },
      loggedInAt: '2026-10-17T00:00:00Z',
    );

void main() {
  group('解析原始 Cookie 头', () {
    test('标准分号分隔', () {
      final m = CookiePortable.parseCookieHeader(
        'SESSDATA=abc; bili_jct=def; DedeUserID=123',
      );
      expect(m['SESSDATA'], 'abc');
      expect(m['bili_jct'], 'def');
      expect(m['DedeUserID'], '123');
    });

    test('去掉 Cookie: 前缀', () {
      final m = CookiePortable.parseCookieHeader(
        'Cookie: SESSDATA=abc; bili_jct=def',
      );
      expect(m['SESSDATA'], 'abc');
      expect(m['bili_jct'], 'def');
    });

    test('小写 cookie: 前缀也识别', () {
      final m = CookiePortable.parseCookieHeader('cookie:SESSDATA=abc');
      expect(m['SESSDATA'], 'abc');
    });

    test('多行粘贴会合并', () {
      final m = CookiePortable.parseCookieHeader(
        'SESSDATA=abc;\nbili_jct=def;\nDedeUserID=123',
      );
      expect(m.length, 3);
      expect(m['SESSDATA'], 'abc');
    });

    test('值里含等号时只按第一个等号切分', () {
      final m = CookiePortable.parseCookieHeader('token=a=b=c');
      expect(m['token'], 'a=b=c');
    });

    test('去掉值两侧引号', () {
      final m = CookiePortable.parseCookieHeader('a="1"; b=\'2\'');
      expect(m['a'], '1');
      expect(m['b'], '2');
    });

    test('忽略空段与无等号的段', () {
      final m = CookiePortable.parseCookieHeader('a=1; ; junk; b=2;');
      expect(m, {'a': '1', 'b': '2'});
    });

    test('空输入返回空 Map', () {
      expect(CookiePortable.parseCookieHeader(''), isEmpty);
      expect(CookiePortable.parseCookieHeader('   '), isEmpty);
    });
  });

  group('平台识别', () {
    test('识别 B 站', () {
      expect(
        CookiePortable.detectPlatform(['SESSDATA', 'bili_jct']),
        'bilibili',
      );
    });

    test('识别抖音', () {
      expect(
        CookiePortable.detectPlatform(['sessionid', 'sid_tt']),
        'douyin',
      );
    });

    test('大小写不敏感', () {
      expect(
        CookiePortable.detectPlatform(['sessdata']),
        'bilibili',
      );
    });

    test('无法识别时返回 null，不猜测', () {
      expect(CookiePortable.detectPlatform(['foo', 'bar']), isNull);
    });
  });

  group('导入', () {
    test('原始串导入成功', () {
      final r = CookiePortable.parse(
        'SESSDATA=abc; bili_jct=def; DedeUserID=999',
      );
      expect(r.ok, isTrue);
      expect(r.platformId, 'bilibili');
      expect(r.session!.cookies['SESSDATA'], 'abc');
      // 从 DedeUserID 提取用户 ID
      expect(r.session!.userId, '999');
    });

    test('platformHint 覆盖自动识别', () {
      final r = CookiePortable.parse(
        'SESSDATA=abc',
        platformHint: 'bilibili',
      );
      expect(r.ok, isTrue);
      expect(r.platformId, 'bilibili');
    });

    test('JSON 键值对象导入', () {
      final r = CookiePortable.parse(
        '{"SESSDATA":"abc","bili_jct":"def"}',
      );
      expect(r.ok, isTrue);
      expect(r.session!.cookies['SESSDATA'], 'abc');
    });

    test('本应用导出格式可再次导入（往返一致）', () {
      final exported = CookiePortable.exportSession(_biliSession());
      final r = CookiePortable.parse(exported);

      expect(r.ok, isTrue);
      expect(r.platformId, 'bilibili');
      expect(r.session!.userId, '12345');
      expect(r.session!.displayName, '测试用户');
      expect(r.session!.cookies, _biliSession().cookies);
    });

    test('空输入给出明确原因', () {
      final r = CookiePortable.parse('   ');
      expect(r.ok, isFalse);
      expect(r.error, contains('内容为空'));
    });

    test('无法识别的格式给出可操作提示', () {
      final r = CookiePortable.parse('hello world');
      expect(r.ok, isFalse);
      expect(r.error, contains('SESSDATA'));
    });

    test('平台无法判断时拒绝，不猜默认值', () {
      final r = CookiePortable.parse('foo=1; bar=2');
      expect(r.ok, isFalse);
      expect(r.error, contains('无法判断'));
    });

    test('缺少关键字段时拒绝，避免存错平台', () {
      // 指定 bilibili，但 Cookie 里没有 SESSDATA/bili_jct/DedeUserID
      final r = CookiePortable.parse(
        'foo=1; bar=2',
        platformHint: 'bilibili',
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('关键字段'));
    });

    test('嵌套 JSON 对象被忽略，不当成 Cookie', () {
      final r = CookiePortable.parse(
        '{"SESSDATA":"abc","nested":{"a":1}}',
      );
      expect(r.ok, isTrue);
      expect(r.session!.cookies.containsKey('nested'), isFalse);
    });

    test('任意 JSON（无 format 标记）走普通键值解析', () {
      final r = CookiePortable.parse(
        '{"platformId":"x","SESSDATA":"abc"}',
      );
      // 没有 format 标记，按普通键值处理；
      // platformId 会变成一条 cookie，但 SESSDATA 能识别出平台
      expect(r.ok, isTrue);
      expect(r.platformId, 'bilibili');
    });

    test('cookieNames 只含键名，不含值', () {
      final r = CookiePortable.parse('SESSDATA=secret123');
      expect(r.ok, isTrue);
      // 结果里的 cookieNames 不应泄露值
      for (final name in r.cookieNames) {
        expect(name, isNot(contains('secret123')));
      }
    });
  });

  group('导出', () {
    test('JSON 含全部字段且带 format 标记', () {
      final text = CookiePortable.exportSession(_biliSession());
      expect(text, contains('video-fusion.cookies'));
      expect(text, contains('bilibili'));
      expect(text, contains('12345'));
      expect(text, contains('SESSDATA'));
    });

    test('Cookie 头导出格式正确', () {
      final header = CookiePortable.exportCookieHeader(_biliSession());
      expect(header, contains('SESSDATA=abc%2Cdef'));
      expect(header, contains('bili_jct=deadbeef'));
      // 分号 + 空格分隔
      expect(header.split('; ').length, 3);
    });

    test('describeCookies 只显示键名与长度，不显示值', () {
      final desc = CookiePortable.describeCookies(const {
        'SESSDATA': 'supersecret',
      });
      expect(desc, contains('SESSDATA'));
      expect(desc, contains('字符'));
      expect(desc, isNot(contains('supersecret')));
    });

    test('空 Cookie 的 describeCookies 不崩溃', () {
      expect(CookiePortable.describeCookies(const {}), '（无 Cookie）');
    });
  });

  group('边界情况', () {
    test('超长 Cookie 值不截断', () {
      final long = 'x' * 2000;
      final r = CookiePortable.parse('SESSDATA=$long');
      expect(r.ok, isTrue);
      expect(r.session!.cookies['SESSDATA']!.length, 2000);
    });

    test('URL 编码的 Cookie 原样保留', () {
      const encoded = 'abc%2Cdef%3Dghi';
      final r = CookiePortable.parse('SESSDATA=$encoded');
      expect(r.session!.cookies['SESSDATA'], encoded);
    });

    test('中文值不破坏解析', () {
      final r = CookiePortable.parse('SESSDATA=测试值; bili_jct=x');
      expect(r.ok, isTrue);
      expect(r.session!.cookies['SESSDATA'], '测试值');
    });

    test('只有等号没有键名时跳过', () {
      final m = CookiePortable.parseCookieHeader('=value; a=1');
      expect(m.containsKey(''), isFalse);
      expect(m['a'], '1');
    });
  });
}
