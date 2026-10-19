/// 页面架构回归测试（需求 9.2）。
///
/// 守护的不是一时的视觉决定，而是**已经付出的修复成本**：
///
///  1. **一级导航只放内容消费**（推荐/发现/直播/我的）。
///     「设置」曾被放在一级导航，导致收藏夹、历史、稍后再看这些
///     内容型入口无处安放，只能挤进设置页 —— 用户不会去设置里找
///     自己的收藏。设置现在必须是「我的」页的次级入口。
///
///  2. **互动状态跨页面共享**。推荐流与详情页必须通过
///     [InteractionRegistry] 复用同一个会话，否则在推荐流收藏后
///     进详情页仍显示未收藏 —— 这正是本次要修的缺陷。
///
///  3. **短视频手势与底栏互不干扰**。底栏的下滑唤出走 Listener
///     旁路观察，不参与手势竞技场；导航判定按标签语义而不是下标，
///     否则接入/移除直播平台后规则会错位到别的页面。
///
///  4. **未接入的能力不出现死按钮**。历史/稍后再看/收藏夹入口
///     在未登录或平台不支持时按能力降级，不伪装可用。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/design/apple_tokens.dart';

/// 用源码文本断言架构决定的测试。
///
/// 为什么不用 widget 断言：这些约束是"某个入口在不在一级导航里"
/// 这类**结构性**事实。widget 测试要构造真实的 FeedScreen/
/// DiscoverScreen/ProfileScreen，得把 VideoService、CredentialVault、
/// media_kit 播放器全套装配起来，还会触发真实网络 —— 那种测试
/// 脆弱且慢，不适合守架构。这里直接读源码文本，稳定、快、可读。
///
/// 代价：它测的是"代码怎么写的"而不是"运行时行为"。所以每条
/// 断言都同时说明**为什么这个结构决定重要**，改动的人能看懂
/// 自己在破坏什么。运行时行为由 widget 测试与实机验证覆盖
/// （见 favorite_live_test.dart 与 HANDOVER 的真机清单）。
void main() {
  String src(String path) => File(path).readAsStringSync();

  group('一级导航：内容优先', () {
    final shell = src('lib/src/ui/shell/app_shell.dart');

    test('四个标签语义固定为 推荐/发现/直播/我的', () {
      for (final member in ['feed', 'discover', 'live', 'profile']) {
        expect(shell, contains(member), reason: 'AppTab.$member 必须存在');
      }
      expect(shell, contains("label: '我的'"));
      expect(shell, contains("label: '推荐'"));
      expect(shell, contains("label: '发现'"));
      expect(shell, contains("label: '直播'"));
    });

    test('「设置」不是一级导航项（降为「我的」页的次级入口）', () {
      // AppleTabItem 的 label 里不允许出现"设置"
      final labels = RegExp(r"label:\s*'([^']+)'")
          .allMatches(shell)
          .map((m) => m.group(1))
          .toList();
      expect(labels, isNot(contains('设置')),
          reason: '设置是低频功能，占一级导航会挤掉内容型入口'
              '（收藏夹/历史/稍后再看），已改为「我的」页内进入');
      expect(labels, contains('我的'));
    });

    test('AppShell 不再暴露 settingsPage 参数', () {
      expect(shell, isNot(contains('settingsPage')),
          reason: '页面集合改成按 AppTab 语义映射，'
              '避免"下标随直播平台增减而错位"这类隐性 bug');
      expect(shell, contains('profilePage'));
    });

    test('直播标签缺席时导航自动收缩，不出现空页面', () {
      expect(shell, contains('if (widget.livePage != null) AppTab.live'),
          reason: '没有直播平台时不该渲染一个点进去没内容的标签');
    });

    test('沉浸式判定按标签语义而不是硬编码下标', () {
      expect(shell, contains('currentTab == AppTab.feed'),
          reason: '按下标（如 _index == 0）判定会在直播平台接入/移除时'
              '把手势规则错位到别的页面上');
      expect(shell, isNot(contains('_index == 0')),
          reason: '不要残留按下标的沉浸式判断');
    });
  });

  group('推荐流手势与底栏', () {
    final shell = src('lib/src/ui/shell/app_shell.dart');
    final gesture = src('lib/src/ui/shell/nav_gesture.dart');

    test('底栏手势用 Listener 旁路观察，不参与手势竞技场', () {
      expect(shell, contains('Listener('),
          reason: '若改用 GestureDetector 会与 PageView 的竖滑争抢，'
              '表现为"切不了视频"或"导航栏乱弹"');
      expect(shell, contains('onPointerDown'));
      expect(shell, contains('onPointerUp'));
    });

    test('唤出导航栏要求起点在屏幕下部且位移足够', () {
      expect(gesture, contains('kNavRevealZoneRatio'));
      expect(gesture, contains('kNavGestureMinDistance'));
    });

    test('页面状态用 IndexedStack 保住，不整页重建', () {
      expect(shell, contains('IndexedStack'),
          reason: '整页重建会让播放器反复初始化、视频从头播放，'
              '并丢失各页滚动位置');
    });

    test('切走推荐页时通知上层暂停播放', () {
      expect(shell, contains('onFeedVisibilityChanged'));
    });
  });

  group('互动状态跨页共享（收藏不高亮的架构性根因）', () {
    test('存在全局登记表，按视频 ID 复用会话', () {
      final registry = src('lib/src/ui/interaction/interaction_registry.dart');
      expect(registry, contains('class InteractionRegistry'));
      expect(registry, contains('acquire'));
      expect(registry, contains('release'));
      expect(registry, contains('recalibrateAll'),
          reason: '导入 Cookie 后必须能校准所有存活会话，'
              '否则已打开的推荐流仍显示"登录后可操作"');
    });

    test('推荐流不再自建控制器 Map，改用登记表', () {
      final feed = src('lib/src/ui/feed/feed_screen.dart');
      expect(feed, contains('InteractionRegistry'),
          reason: '页面私有的 Map<videoId, Controller> 与详情页各建一份，'
              '是"两个入口状态不一致"的根因');
      expect(feed, isNot(contains('Map<String, InteractionController>')),
          reason: '不要退回页面私有缓存');
    });

    test('详情页优先复用登记表的会话', () {
      final detail = src('lib/src/ui/detail/video_detail_screen.dart');
      expect(detail, contains('interactions'),
          reason: '详情页要能拿到与推荐流同一个实例');
      expect(detail, contains('registry.acquire'),
          reason: 'acquire/release 必须成对，否则共享会话会被提前销毁'
              '或引用计数泄漏');
    });

    test('收藏/投币/稍后再看/关注都走真实控制器而非本地布尔', () {
      final controller = src('lib/src/ui/interaction/interaction_controller.dart');
      expect(controller, contains('applyFavoriteFolders'));
      expect(controller, contains('verifyRecentFavorite'),
          reason: '写操作必须由服务端复查确认；只看接口返回码会相信'
              '"code=0 但没生效"的假成功');
      expect(controller, contains('coinAvailability'),
          reason: '投币要先查真实余额，不能让用户点了才收到平台报错');
      expect(controller, contains('_stateSeq'),
          reason: '竞态防护：晚到的旧响应不得覆盖新状态');
    });
  });

  group('「我的」页：内容入口与能力降级', () {
    final profile = src('lib/src/ui/profile/profile_screen.dart');

    test('内容入口在首屏，设置是次级入口', () {
      expect(profile, contains('我的收藏夹'));
      expect(profile, contains('稍后再看'));
      expect(profile, contains('观看历史'));
      expect(profile, contains("title: '设置'"));
    });

    test('平台不支持的能力不伪装可用', () {
      expect(profile, contains('_watchLaterUsable'),
          reason: '稍后再看依赖平台接口能力；不支持时要说明原因，'
              '不能显示一个点进去空白的入口');
      expect(profile, contains('capabilitiesFor'),
          reason: '能力判定必须来自服务层，UI 不写平台名分支');
    });

    test('观看历史如实说明是本机进度而非平台记录', () {
      expect(profile.contains('不跨设备同步') || profile.contains('本设备'), isTrue,
          reason: '历史来自 VideoProgressStore（本机播放进度），'
              '与平台观看历史接口是两回事，混为一谈会误导用户');
    });

    test('账号卡片不含任何 cookie 值', () {
      expect(profile, isNot(contains('cookieHeader')));
      expect(profile, isNot(contains('SESSDATA')));
      expect(profile, anyOf(contains('safeSummary'), contains('userId')),
          reason: '只展示平台侧的公开账号信息（昵称/UID/头像）');
    });
  });

  group('直播：统一入口与资源释放', () {
    final live = src('lib/src/ui/live/live_room_screen.dart');

    test('退出/重连时释放播放器，避免音频残留与双播放器', () {
      expect(live, contains('_releasePlayer'));
      expect(live, contains('stop'),
          reason: '只 dispose 不 stop 时，直播拉流可能仍在后台跑');
    });

    test('监听断流与下播，而不是静止一帧', () {
      expect(live, contains('completed'),
          reason: '直播流被关闭表现为播放完成事件，不是 HTTP 错误');
      expect(live, contains('player.stream.error'),
          reason: '错误事件必须呈现，不能静默');
    });

    test('按平台声明决定弹幕可用，不显示假弹幕', () {
      expect(live, anyOf(contains('抖音直播暂不提供弹幕'), contains('fetchLiveDanmakuEndpoint')),
          reason: '弹幕不可用时如实说明原因，不许用模拟消息填充');
    });
  });

  group('设计系统未被破坏', () {
    test('底栏高度与安全区内边距仍由设计令牌提供', () {
      expect(AppleSize.tabBar, 49);
      final shell = src('lib/src/ui/shell/app_shell.dart');
      expect(shell, contains('tabBarInsets'));
      expect(shell, contains('AppleSize.tabBar + bottomInset'));
    });

    test('页面没有重新引入已删除的旧组件体系', () {
      // 项目已删除旧版 Mobile UI 与媒体库；这里守住不回退
      expect(Directory('lib/src/ui/library').existsSync(), isFalse);
      final main = src('lib/main.dart');
      expect(main, isNot(contains('LibraryScreen')));
    });
  });
}
