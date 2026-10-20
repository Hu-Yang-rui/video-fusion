/// 私信媒体（图片 / 表情 / 视频）解析与上传校验的单元测试（需求一）。
///
/// 覆盖：
///  - `msg_type` 枚举映射（含实测真值 0/1/2/5/6/7/10/17/18/10001）
///  - 图片 / 表情 / 视频 content 解析（含动图变体、缺字段降级）
///  - **图片与表情不混为一类**
///  - 表情短代码提取（去重、排除纯数字方括号）
///  - 上传前本地校验（扩展名 / 大小 / 空文件）
///  - 绝不把本地路径当远端地址
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/bilibili/im_client.dart';
import 'package:video_fusion/src/adapters/bilibili/im_upload_client.dart';
import 'package:video_fusion/src/models/im.dart';

void main() {
  group('msg_type 枚举映射（实测真值）', () {
    test('文本：1 与 18 都映射到 text', () {
      expect(ImMessageType.fromRaw(1), ImMessageType.text);
      expect(ImMessageType.fromRaw(18), ImMessageType.text);
    });

    test('图片 2 → image', () {
      expect(ImMessageType.fromRaw(2), ImMessageType.image);
    });

    test('自定义表情 6（FAV_EMOJI）→ customEmoji，不与图片合并', () {
      expect(ImMessageType.fromRaw(6), ImMessageType.customEmoji);
      expect(
        ImMessageType.fromRaw(6),
        isNot(ImMessageType.fromRaw(2)),
        reason: '表情与图片必须是不同类型（需求明令不得混为一类）',
      );
    });

    test('视频 17 / 撤回 5 / 分享 7 / 系统 10', () {
      expect(ImMessageType.fromRaw(17), ImMessageType.video);
      expect(ImMessageType.fromRaw(5), ImMessageType.withdraw);
      expect(ImMessageType.fromRaw(7), ImMessageType.shareCard);
      expect(ImMessageType.fromRaw(10), ImMessageType.systemCard);
    });

    test('未知类型安全降级，不猜', () {
      expect(ImMessageType.fromRaw(0), ImMessageType.unknown);
      expect(ImMessageType.fromRaw(10001), ImMessageType.unknown);
      expect(ImMessageType.fromRaw(null), ImMessageType.unknown);
      expect(ImMessageType.fromRaw(99999), ImMessageType.unknown);
    });

    test('hasReadableText 只对文本/系统/撤回为真', () {
      expect(ImMessageType.text.hasReadableText, isTrue);
      expect(ImMessageType.systemCard.hasReadableText, isTrue);
      expect(ImMessageType.withdraw.hasReadableText, isTrue);
      expect(ImMessageType.image.hasReadableText, isFalse);
      expect(ImMessageType.customEmoji.hasReadableText, isFalse);
      expect(ImMessageType.video.hasReadableText, isFalse);
    });
  });

  group('图片 content 解析', () {
    test('完整字段解析出 url/宽高/大小', () {
      final media = BilibiliImClient.extractMedia(
        2,
        '{"url":"https://i0.hdslb.com/a.jpg","width":1200,"height":800,'
            '"size":123456,"imageType":1,"original":1}',
      );
      expect(media, isNotNull);
      expect(media!.url, 'https://i0.hdslb.com/a.jpg');
      expect(media.width, 1200);
      expect(media.height, 800);
      expect(media.sizeBytes, 123456);
      expect(media.aspectRatio, closeTo(1.5, 0.001));
      expect(media.hasAnimation, isFalse);
    });

    test('缺宽高时 aspectRatio 为 null（UI 用固定占位，不猜比例）', () {
      final media = BilibiliImClient.extractMedia(
        2,
        '{"url":"https://x/a.jpg"}',
      );
      expect(media, isNotNull);
      expect(media!.aspectRatio, isNull);
    });

    test('缺 url 返回 null（不伪造地址）', () {
      final media = BilibiliImClient.extractMedia(2, '{"width":10,"height":10}');
      expect(media, isNull);
    });

    test('坏 JSON 返回 null 而不抛异常', () {
      expect(BilibiliImClient.extractMedia(2, '{not json'), isNull);
      expect(BilibiliImClient.extractMedia(2, ''), isNull);
    });

    test('文本消息不产生媒体', () {
      expect(
        BilibiliImClient.extractMedia(1, '{"content":"hi"}'),
        isNull,
      );
    });
  });

  group('自定义表情 content 解析', () {
    test('静态表情解析成功', () {
      final media = BilibiliImClient.extractMedia(
        6,
        '{"url":"https://i0.hdslb.com/e/doge.png","width":100,"height":100}',
      );
      expect(media, isNotNull);
      expect(media!.url, contains('doge.png'));
      expect(media.hasAnimation, isFalse);
    });

    test('有 gif_url 时视为动图，displayUrl 优先动图', () {
      final media = BilibiliImClient.extractMedia(
        6,
        '{"url":"https://x/doge.png","gif_url":"https://x/doge.gif"}',
      );
      expect(media, isNotNull);
      expect(media!.hasAnimation, isTrue);
      expect(media.displayUrl, 'https://x/doge.gif');
      // 静态图地址仍然保留
      expect(media.url, 'https://x/doge.png');
    });

    test('webp_url 也认作动图变体', () {
      final media = BilibiliImClient.extractMedia(
        6,
        '{"url":"https://x/e.png","webp_url":"https://x/e.webp"}',
      );
      expect(media!.hasAnimation, isTrue);
      expect(media.displayUrl, 'https://x/e.webp');
    });
  });

  group('视频消息 content 解析', () {
    test('封面走 img 字段，且能取到宽高', () {
      final media = BilibiliImClient.extractMedia(
        17,
        '{"duration":12,"img":"https://x/cover.jpg",'
            '"img_width":640,"img_height":360,"key":"k","video_url":"https://x/v.mp4"}',
      );
      expect(media, isNotNull);
      expect(media!.url, 'https://x/cover.jpg');
      expect(media.width, 640);
      expect(media.height, 360);
    });
  });

  group('extractText 各类型', () {
    test('文本取 content 字段', () {
      expect(
        BilibiliImClient.extractText(1, '{"content":"你好"}'),
        '你好',
      );
    });

    test('系统卡片优先 text，退而 title', () {
      expect(
        BilibiliImClient.extractText(10, '{"text":"正文","title":"标题"}'),
        '正文',
      );
      expect(
        BilibiliImClient.extractText(10, '{"title":"标题"}'),
        '标题',
      );
    });

    test('撤回消息给稳定文案（不显示空白）', () {
      expect(
        BilibiliImClient.extractText(5, ''),
        '这条消息已被撤回',
      );
    });

    test('图片/表情/视频没有文本', () {
      expect(BilibiliImClient.extractText(2, '{"url":"https://x/a.jpg"}'), isNull);
      expect(BilibiliImClient.extractText(6, '{"url":"https://x/a.gif"}'), isNull);
      expect(BilibiliImClient.extractText(17, '{"img":"https://x/c.jpg"}'), isNull);
    });
  });

  group('表情短代码提取', () {
    test('单个短代码', () {
      expect(extractEmojiShortcodes('哈哈[doge]'), ['doge']);
    });

    test('多个短代码按顺序去重', () {
      expect(
        extractEmojiShortcodes('[doge]好[笑哭]耶[doge]'),
        ['doge', '笑哭'],
      );
    });

    test('纯数字方括号不算表情（更像引用标记）', () {
      expect(extractEmojiShortcodes('见[1]和[2]'), isEmpty);
    });

    test('没有短代码返回空', () {
      expect(extractEmojiShortcodes('普通文本'), isEmpty);
      expect(extractEmojiShortcodes(null), isEmpty);
      expect(extractEmojiShortcodes(''), isEmpty);
    });

    test('嵌套/超长方括号不误判', () {
      expect(extractEmojiShortcodes('[[doge]]'), isEmpty);
      expect(
        extractEmojiShortcodes('[${'x' * 30}]'),
        isEmpty,
        reason: '超过 20 字符不当表情',
      );
    });
  });

  group('上传前本地校验', () {
    test('常见图片格式通过', () {
      for (final ext in ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp']) {
        final v = BilibiliImUploadClient.validateFile('a.$ext', 1024);
        expect(v.ok, isTrue, reason: '$ext 应被接受');
      }
    });

    test('不支持的格式被拒，原因可读', () {
      final v = BilibiliImUploadClient.validateFile('a.tiff', 1024);
      expect(v.ok, isFalse);
      expect(v.reason, contains('tiff'));
    });

    test('没有扩展名被拒', () {
      final v = BilibiliImUploadClient.validateFile('noext', 1024);
      expect(v.ok, isFalse);
    });

    test('空文件被拒', () {
      final v = BilibiliImUploadClient.validateFile('a.jpg', 0);
      expect(v.ok, isFalse);
      expect(v.reason, contains('空'));
    });

    test('超过 20MB 被拒，并给出实际大小', () {
      final v = BilibiliImUploadClient.validateFile(
        'a.jpg',
        BilibiliImUploadClient.maxBytes + 1,
      );
      expect(v.ok, isFalse);
      expect(v.reason, contains('20 MB'));
    });

    test('刚好 20MB 通过（边界）', () {
      final v = BilibiliImUploadClient.validateFile(
        'a.jpg',
        BilibiliImUploadClient.maxBytes,
      );
      expect(v.ok, isTrue);
    });
  });

  group('ImMessage 契约', () {
    test('本地预览路径与远端地址是两个字段，不会互相顶替', () {
      const media = ImMedia(url: 'https://remote/a.jpg', width: 10, height: 10);
      const m = ImMessage(
        msgKey: 'k1',
        senderUid: 1,
        receiverId: 2,
        receiverType: 1,
        msgType: 2,
        timestamp: 0,
        content: '',
        media: media,
        localPreviewPath: '/local/a.jpg',
      );
      expect(m.media!.url, 'https://remote/a.jpg');
      expect(m.localPreviewPath, '/local/a.jpg');
      expect(
        m.media!.url,
        isNot(m.localPreviewPath),
        reason: '本地路径绝不能当远端地址用',
      );
    });

    test('发送中状态不是 sent（不谎报成功）', () {
      const m = ImMessage(
        msgKey: 'local-1',
        senderUid: 1,
        receiverId: 2,
        receiverType: 1,
        msgType: 2,
        timestamp: 0,
        content: '',
        sendState: ImSendState.sending,
      );
      expect(m.sendState, isNot(ImSendState.sent));
    });

    test('copyWith 能带出媒体与预览路径', () {
      const m = ImMessage(
        msgKey: 'k1',
        senderUid: 1,
        receiverId: 2,
        receiverType: 1,
        msgType: 2,
        timestamp: 0,
        content: '',
      );
      final next = m.copyWith(
        media: const ImMedia(url: 'https://x/a.jpg'),
        emojiShortcodes: const ['doge'],
      );
      expect(next.media, isNotNull);
      expect(next.emojiShortcodes, ['doge']);
    });
  });
}
