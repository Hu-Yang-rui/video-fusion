/// 消息页未登录状态的渲染测试。
///
/// 用户报告"消息那里啥都没有"。UI 代码里有「未登录 + 去登录」
/// 的空状态，但必须验证它真的渲染出来——如果 `_initialized`
/// 永远不置 true，页面会一直停在加载圈上，看起来就像空的。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/mock_adapter.dart';
import 'package:video_fusion/src/adapters/platform_registry.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/http_client.dart';
import 'package:video_fusion/src/core/key_value_store.dart';
import 'package:video_fusion/src/core/logger.dart';
import 'package:video_fusion/src/core/secure_store.dart';
import 'package:video_fusion/src/core/video_service.dart';
import 'package:video_fusion/src/core/video_store.dart';
import 'package:video_fusion/src/ui/messages/im_store.dart';
import 'package:video_fusion/src/ui/messages/messages_screen.dart';

/// 恒为空的 SecureStore（未登录态）。
class _EmptySecureStore implements SecureStore {
  @override
  bool get isEncrypted => false;

  @override
  String get implementationName => 'test-in-memory';

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

ImStore _makeStore() {
  final service = VideoService(
    registry: PlatformRegistry(adapters: [
      MockAdapter(http: FusionHttpClient(), logger: FusionLogger(enabled: false)),
    ]),
    store: VideoStore(storage: InMemoryStore()),
    logger: FusionLogger(enabled: false),
  );
  return ImStore(
    service: service,
    vault: CredentialVault(storage: _EmptySecureStore()),
  );
}

void main() {
  testWidgets('未登录时显示「未登录」空状态与登录按钮', (tester) async {
    final store = _makeStore();

    await tester.pumpWidget(MaterialApp(
      home: MessagesScreen(store: store, onOpenLogin: () {}),
    ));
    await tester.pumpAndSettle();

    expect(find.text('未登录'), findsOneWidget,
        reason: '未登录必须显示明确的空状态，不能是一片空白');
    expect(find.text('私信需要登录 B 站账号。登录后这里会显示你的真实会话。'),
        findsOneWidget);
    expect(find.text('去登录'), findsOneWidget, reason: '必须给出登录入口');
  });

  testWidgets('页面有「消息」标题', (tester) async {
    final store = _makeStore();

    await tester.pumpWidget(MaterialApp(
      home: MessagesScreen(store: store, onOpenLogin: () {}),
    ));
    await tester.pumpAndSettle();

    expect(find.text('消息'), findsOneWidget);
  });
}
