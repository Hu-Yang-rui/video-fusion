/// 测试替身共用：声明"不支持私信"的一整套成员。
///
/// # 为什么需要它
///
/// `PlatformAdapter` 里私信成员带默认实现（抛 unsupportedPlatform），
/// 但 Dart 的 `implements` **只继承签名、不继承默认实现** —— 这是本
/// 项目已经踩过一次的坑（见 HANDOVER）。所以每个
/// `implements PlatformAdapter` 的测试替身都必须逐个重写这 7 个成员，
/// 否则编译不过。
///
/// 与其在 5 个文件里复制 7 遍样板，不如集中在这里一处，
/// 将来私信接口再变只需改这一个文件。
///
/// # 语义
///
/// 这里刻意**全部抛 unsupportedPlatform**，而不是返回空数据：
/// 返回空会把"能力不存在"伪装成"这个账号没有内容"，那正是
/// 本项目反复强调不能做的事。
library;

import 'package:video_fusion/src/adapters/platform_adapter.dart';
import 'package:video_fusion/src/core/credential_vault.dart';
import 'package:video_fusion/src/core/errors.dart';
import 'package:video_fusion/src/models/im.dart';

/// 给测试替身混入"不支持私信"的实现。
///
/// 用法：`class FakeX extends/implements PlatformAdapter with NoImSupport`
mixin NoImSupport on PlatformAdapter {
  FusionException get _unsupported => FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台暂不支持私信。',
        technicalMessage: 'test fake $id does not implement IM',
        platformId: id,
      );

  @override
  bool get supportsIm => false;

  @override
  Future<ImSessionPage> fetchImSessions({
    required PlatformSession session,
    int count = 20,
    int endTs = 0,
  }) =>
      throw _unsupported;

  @override
  Future<ImMessagePage> fetchImMessages({
    required PlatformSession session,
    required int talkerId,
    int size = 20,
    int endSeqno = 0,
  }) =>
      throw _unsupported;

  @override
  Future<ImSendResult> sendImMessage({
    required PlatformSession session,
    required int talkerId,
    required String content,
  }) =>
      throw _unsupported;

  @override
  Future<ImUnread> fetchImUnread({required PlatformSession session}) =>
      throw _unsupported;

  @override
  Future<Map<int, ImUserInfo>> fetchImUserInfos({
    required PlatformSession session,
    required List<int> uids,
  }) async =>
      const {};

  @override
  Future<bool> markImSessionRead({
    required PlatformSession session,
    required int talkerId,
    required int ackSeqno,
  }) async =>
      false;

  // ── 私信媒体能力（v0.5.0 新增，同样要逐个重写）──────────────
  //
  // 与上面同理：`implements` 不继承默认实现。这 7 个成员是
  // 图片/表情/视频相关能力，测试替身一律声明不可用。

  @override
  bool get supportsImImageSend => false;

  @override
  bool get supportsImEmote => false;

  @override
  bool get supportsImCustomEmojiSend => false;

  @override
  Future<ImMedia> uploadImImage({
    required PlatformSession session,
    required List<int> bytes,
    required String filename,
  }) =>
      throw _unsupported;

  @override
  Future<ImSendResult> sendImImage({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      throw _unsupported;

  @override
  Future<ImSendResult> sendImCustomEmoji({
    required PlatformSession session,
    required int talkerId,
    required ImMedia media,
  }) =>
      throw _unsupported;

  @override
  Future<ImEmotePanel> fetchImEmotePanel({
    required PlatformSession session,
  }) async =>
      const ImEmotePanel(unavailableReason: '测试替身不支持表情面板。');
}
