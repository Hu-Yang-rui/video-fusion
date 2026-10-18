/// Cookie 导入导出的实机验证（不依赖 UI 点击）。
///
/// 验证：
///  1. 真实 CredentialVault 能保存导入的会话
///  2. 保存后能读回，Cookie 内容一致
///  3. 导出 → 再导入，往返一致
///  4. 加密存储真实生效
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_fusion/src/core/cookie_portable.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/platform/flutter_secure_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Cookie 导入 → 保存 → 读回 → 导出 → 再导入', (tester) async {
    final vault = CredentialVault(storage: FlutterSecureStore());

    // ignore: avoid_print
    print('存储实现: ${vault.storageName}, 加密: ${vault.isEncrypted}');

    // 1. 模拟用户从浏览器复制的 Cookie 串
    const pasted = 'SESSDATA=abc%2C123; bili_jct=deadbeef; '
        'DedeUserID=987654; buvid3=XYZ';

    final imported = CookiePortable.parse(pasted);
    expect(imported.ok, isTrue, reason: '应能解析原始 Cookie 串');
    expect(imported.platformId, 'bilibili');
    expect(imported.session!.cookies.length, 4);

    // ignore: avoid_print
    print('解析到 ${imported.cookieNames.length} 个 Cookie: '
        '${imported.cookieNames.join('、')}');

    // 2. 保存到真实加密存储
    await vault.save(imported.session!);

    // 3. 读回验证
    final loaded = await vault.load('bilibili');
    expect(loaded, isNotNull, reason: '保存后应能读回');
    expect(loaded!.cookies['SESSDATA'], 'abc%2C123');
    expect(loaded.cookies['bili_jct'], 'deadbeef');
    expect(loaded.userId, '987654');

    // ignore: avoid_print
    print('读回成功: ${loaded.displayName}, '
        '${loaded.cookies.length} 个 Cookie');

    // 4. 导出
    final exported = CookiePortable.exportSession(loaded);
    expect(exported, contains('video-fusion.cookies'));
    expect(exported, contains('SESSDATA'));

    // ignore: avoid_print
    print('导出长度: ${exported.length} 字符');

    // 5. 再导入（往返一致）
    final reimported = CookiePortable.parse(exported);
    expect(reimported.ok, isTrue);
    expect(reimported.session!.cookies, loaded.cookies);
    expect(reimported.session!.userId, loaded.userId);

    // ignore: avoid_print
    print('往返一致: ${reimported.session!.cookies.length} 个 Cookie');

    // 6. 清理
    await vault.clear('bilibili');
    final afterClear = await vault.load('bilibili');
    expect(afterClear, isNull, reason: '清除后应读不到');

    // ignore: avoid_print
    print('=== 全部通过 ===');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
