/// 收藏闭环 · **真实接口**验证（Flutter 测试环境，`--tags network`）。
///
/// 运行：
/// ```powershell
/// $env:Path = "D:\flutter\bin;" + $env:Path
/// $env:BILI_COOKIE_FILE = 'D:\vf-local\bili_cookie.txt'   # 仓库外
/// flutter test test/favorite_live_test.dart --tags network --concurrency=1
///
/// # 额外做「可逆写入」闭环（收藏→复查→取消），需要显式开启：
/// $env:VF_ALLOW_WRITE = '1'
/// ```
///
/// # 为什么需要它
///
/// `test/favorite_folders_test.dart` 用的是可编程假适配器，只能证明
/// **状态机逻辑**正确。而"点收藏只弹提示、按钮不高亮"的真正根因
/// （`archive/relation` 的 `like` 是计数器不是布尔、类型误用被 catch
/// 吞成 unknown、写入后没有复查）只有打**真实接口**才能证明已修复。
/// 本文件就是那份证据。
///
/// # 安全边界（硬约束）
///
///  - Cookie 只从 `BILI_COOKIE_FILE` / `BILI_COOKIE` 读，两者都在**仓库外**；
///    测试输出只打印 cookie 的**名字**与 uid（uid 是公开的 mid），
///    绝不打印 SESSDATA / bili_jct / sid 的取值。
///  - **默认只读**。写入闭环（收藏→复查→取消）必须 `VF_ALLOW_WRITE=1`
///    才执行，且只对固定的测试视频做、结尾必恢复原状。
///  - 绝不投币（消耗硬币）、绝不关注（改社交关系）、绝不发评论 ——
///    这些不在用户授权范围内。
///  - 若测试视频当前已被收藏，**跳过**而不是取消它：
///    不改动账号上既有的数据。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili_adapter.dart';
import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/logger.dart';

/// 固定的测试视频：一个长期存在的老稿件。
///
/// 不用"热门第一条"：那类条目会被各种探针反复收藏，
/// 且内容随时间变化，测试不可复现。
const String testBvid = 'BV1G5po6zECY';

final bool allowWrite = Platform.environment['VF_ALLOW_WRITE'] == '1';

BilibiliAdapter buildAdapter() => BilibiliAdapter(
      http: FusionHttpClient(logger: FusionLogger(enabled: false)),
      logger: FusionLogger(enabled: false),
    );

/// 从仓库外的文件读 cookie 并构造会话。
///
/// 解析出的键值只存在于内存；不写文件、不打印取值。
PlatformSession? loadSession(BilibiliAdapter adapter) {
  final raw = _loadCookie();
  if (raw.isEmpty) return null;
  final cookies = <String, String>{};
  for (final part in raw.split(';')) {
    final kv = part.trim();
    final eq = kv.indexOf('=');
    if (eq <= 0) continue;
    cookies[kv.substring(0, eq)] = kv.substring(eq + 1);
  }
  if (cookies.isEmpty) return null;
  return PlatformSession(
    platformId: adapter.id,
    displayName: 'bilibili',
    userId: cookies['DedeUserID'] ?? '',
    cookies: cookies,
    loggedInAt: DateTime.now().toUtc().toIso8601String(),
  );
}

String _loadCookie() {
  final env = Platform.environment['BILI_COOKIE'];
  if (env != null && env.trim().isNotEmpty) return env.trim();
  final path =
      Platform.environment['BILI_COOKIE_FILE'] ?? r'D:\vf-local\bili_cookie.txt';
  final f = File(path);
  if (!f.existsSync()) return '';
  return f.readAsStringSync().trim();
}

void main() {
  final adapter = buildAdapter();
  final session = loadSession(adapter);

  group('收藏闭环（真实接口）', () {
    test('凭据可读且带 DedeUserID', () {
      if (session == null) {
        // 没有凭据时不谎称验证过：明确 skip 并说明怎么开启
        markTestSkipped('未提供 BILI_COOKIE / BILI_COOKIE_FILE（仓库外路径）');
        return;
      }
      expect(session.userId, isNotEmpty,
          reason: '收藏夹接口需要 uid；没有它整个能力无从验证');
      // 只断言键存在，不打印取值
      expect(session.cookies.containsKey('SESSDATA'), isTrue);
      expect(session.cookies.containsKey('bili_jct'), isTrue,
          reason: '收藏/取消收藏写操作必须有 csrf（bili_jct）');
    }, tags: 'network');

    test('收藏夹列表来自当前账号', () async {
      final s = session;
      if (s == null) return markTestSkipped('无凭据');
      final folders = await adapter.fetchFavoriteFolders(session: s);

      expect(folders, isNotEmpty, reason: '测试账号确实有收藏夹');
      // 名称/ID 来自接口，不是本地构造
      for (final f in folders) {
        expect(f.title, isNotEmpty);
        expect(f.id, greaterThan(0));
      }
      final defaults = folders.where((f) => f.isDefault).length;
      expect(defaults, 1,
          reason: '必须恰好识别出一个默认收藏夹（按名称判定，'
              '不能按数组下标 0 或硬编码 ID 假定）');

      // 默认夹 ID 不固定：这里只要求它与其它夹不重复
      final ids = folders.map((f) => f.id).toSet();
      expect(ids.length, folders.length, reason: '收藏夹 ID 不得重复');
    }, tags: 'network');

    test(
        '互动状态解析没有因字段类型误用而降级为 unknown'
        '（这是"收藏后按钮不高亮"的根因回归）', () async {
      final s = session;
      if (s == null) return markTestSkipped('无凭据');
      final state = await adapter.fetchInteractionState(testBvid, session: s);

      // 旧实现把布尔/计数器混着当 num 取，抛 TypeError →
      // 被外层 catch 吞成 unknown → 收藏成功也不高亮。
      expect(state.known, isTrue,
          reason: 'known=false 意味着解析失败或登录失效；'
              '此时 UI 会显示"登录后可操作"，用户看不到真实收藏态');
      // 未收藏时不该做过度的全量归属扫描
      if (!state.favorited) {
        expect(state.favoritedFolderIds, isEmpty,
            reason: '未收藏时归属必为空；非空说明状态与归属自相矛盾');
      }
    }, tags: 'network');

    test('投币余额可读（0 与"未知"必须可区分）', () async {
      final s = session;
      if (s == null) return markTestSkipped('无凭据');
      final balance = await adapter.fetchCoinBalance(session: s);
      // 不断言具体数值：余额是账号状态，且测试边界禁止消耗。
      // 这里只要求"读得到结论"，null 也是合法结论（平台未下发）。
      if (balance != null) {
        expect(balance, greaterThanOrEqualTo(0));
      }
    }, tags: 'network');

    test('稍后再看状态可单请求判定', () async {
      final s = session;
      if (s == null) return markTestSkipped('无凭据');
      final inList = await adapter.fetchWatchLater(
        platformVideoId: testBvid,
        session: s,
      );
      expect(inList, isA<bool>());
    }, tags: 'network');

    test('归属扫描返回三态，未核对的夹不会被当成"未收藏"', () async {
      final s = session;
      if (s == null) return markTestSkipped('无凭据');
      final scan = await adapter.scanFoldersContainingVideo(
        platformVideoId: testBvid,
        session: s,
        maxRequests: 6,
      );

      // 命中的夹必须也算"核对过"
      for (final id in scan.containedFolderIds) {
        expect(scan.checkedFolderIds, contains(id),
            reason: 'contained ⊆ checked；否则状态自相矛盾');
      }
      // 预算 6 在一个 145 条的夹上必然扫不完 —— 这是设计事实。
      // 关键是不许"扫不完就报成功"：exhaustive=false 时必须能被识别。
      if (!scan.exhaustive) {
        expect(scan.checkedFolderIds.length, lessThan(6 + 1),
            reason: '非 exhaustive 时不可能所有夹都已核对完');
      }
    }, tags: 'network');

    test('真实写入闭环：收藏→服务端复查→取消→恢复原状', () async {
      final s = session;
      if (s == null) return markTestSkipped('无凭据');
      if (!allowWrite) {
        return markTestSkipped(
            '写入会改动账号数据，需显式 VF_ALLOW_WRITE=1 才执行');
      }

      final before =
          await adapter.fetchInteractionState(testBvid, session: s);
      if (before.favorited) {
        return markTestSkipped('测试视频当前已被收藏，'
            '跳过以免取消用户既有的收藏关系');
      }

      final folders = await adapter.fetchFavoriteFolders(session: s);
      final target = folders.firstWhere(
        (f) => f.isDefault,
        orElse: () => folders.first,
      );

      // ── 收藏 ──────────────────────────────────────────────
      final added = await adapter.setFavorite(
        testBvid,
        favorite: true,
        session: s,
        folderIds: [target.id],
      );
      expect(added.accepted, isTrue,
          reason: '平台未接受写入：code=${added.upstreamCode} '
              'msg=${added.message}');

      // 复查 1（便宜路径）：新项在 resource/list 第 1 页
      final confirmed = await adapter.verifyRecentFavorite(
        platformVideoId: testBvid,
        folderIds: [target.id],
        session: s,
      );
      expect(confirmed, contains(target.id),
          reason: '平台返回成功但复查没确认 —— 这正是必须防的"假成功"：'
              'deal 会返回 code=0 而 data.success_num=0');

      // 复查 2（聚合布尔）：archive/relation.favorite 同步变 true
      final afterAdd =
          await adapter.fetchInteractionState(testBvid, session: s);
      expect(afterAdd.favorited, isTrue,
          reason: '收藏态未反映到状态接口 → 按钮仍不会高亮');

      // ── 取消并恢复 ────────────────────────────────────────
      final removed = await adapter.setFavorite(
        testBvid,
        favorite: false,
        session: s,
        removeFolderIds: [target.id],
        folderIds: const [],
      );
      expect(removed.accepted, isTrue);

      final afterDel =
          await adapter.fetchInteractionState(testBvid, session: s);
      expect(afterDel.favorited, isFalse,
          reason: '账号未恢复原状：必须手动检查该收藏夹');
    }, tags: 'network');

    test('不存在的收藏夹必须被识别为"未生效"（假成功拦截）', () async {
      final s = session;
      if (s == null) return markTestSkipped('无凭据');
      if (!allowWrite) return markTestSkipped('需要 VF_ALLOW_WRITE=1');

      const bogusFolder = 999999999999;
      final before =
          await adapter.fetchInteractionState(testBvid, session: s);
      if (before.favorited) return markTestSkipped('测试视频已收藏，跳过');

      final result = await adapter.setFavorite(
        testBvid,
        favorite: true,
        session: s,
        folderIds: [bogusFolder],
      );

      final confirmed = await adapter.verifyRecentFavorite(
        platformVideoId: testBvid,
        folderIds: [bogusFolder],
        session: s,
      );

      // 实测：该请求有时返回 code=0（有时 11010），
      // 但服务端确实不会写入 → 复查必须为空。
      expect(confirmed, isEmpty,
          reason: '复查确认服务端没写入。若这里非空，说明我们把'
              '"平台返回 200/code=0"当成了业务成功');
      if (result.accepted && confirmed.isEmpty) {
        // 这是被我们拦住的那类假成功；不报错，但记录事实
        // 便于回归时知道平台行为是否变了
        expect(
          (result.message ?? '').isNotEmpty,
          isTrue,
          reason: 'code=0 但未生效时，message 要能表达"未生效"',
        );
      }

      // 兜底恢复：万一平台真的写进去了（行为变化），把它清掉
      final after = await adapter.fetchInteractionState(testBvid, session: s);
      if (after.favorited) {
        await adapter.setFavorite(
          testBvid,
          favorite: false,
          session: s,
          folderIds: const [],
        );
      }
    }, tags: 'network');

    test('登录失效被如实上报，不当成"未收藏"', () async {
      final broken = PlatformSession(
        platformId: adapter.id,
        displayName: 'invalid',
        userId: session?.userId ?? '',
        cookies: const {'SESSDATA': 'invalid'},
        loggedInAt: DateTime.now().toUtc().toIso8601String(),
      );
      try {
        final state =
            await adapter.fetchInteractionState(testBvid, session: broken);
        // 没抛错就必须是 unknown，绝不能是 favorited=false 的"确定未收藏"
        expect(state.known, isFalse,
            reason: '无效凭据下返回 known=true 等于伪造服务端状态');
      } on FusionException catch (e) {
        expect(
          e.code,
          anyOf(FusionErrorCode.loginRequired, FusionErrorCode.upstreamError),
          reason: '登录类失败必须归一化成可识别的错误码',
        );
      }
    }, tags: 'network');
  });
}
