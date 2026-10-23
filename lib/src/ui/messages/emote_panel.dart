/// 私信表情面板。
///
/// # 数据来源
///
/// 全部来自 `api.bilibili.com/x/emote/user/panel/web` 的真实响应
/// （见 `BilibiliEmoteClient`）。**没有任何内置假表情**。
///
/// # 加载不出来的表现（重要）
///
/// 实测：未登录 / 登录态失效时，接口返回 `code=0` 但 `packages: null`。
/// 这是"拿不到"，不是"没有表情"。面板必须如实区分：
///
/// | 情况 | 显示 |
/// |---|---|
/// | 加载中 | 菊花 |
/// | `loaded=false` | 一行说明 + 重试按钮（原因来自服务端/网络） |
/// | `loaded=true` 且为空 | "这个账号还没有可用的表情包" |
/// | 正常 | 按包分组的网格 |
///
/// # 点击行为
///
/// 点击表情 → 发送 `[短代码]` 文本消息。
/// 这是 B 站私信里表情的**实际传递方式**，且不依赖"该表情是否在你的收藏里"
/// （自定义表情消息 `msg_type=6` 有收藏前提，本项目未验证，故不采用）。
library;

import 'package:flutter/material.dart';

import '../../design/apple_tokens.dart';
import '../../models/im.dart';

class EmotePanel extends StatefulWidget {
  const EmotePanel({
    super.key,
    required this.panel,
    required this.loading,
    required this.onSelect,
  });

  /// 已加载的面板（可能为 null = 还没请求）。
  final ImEmotePanel? panel;

  /// 是否正在加载。
  final bool loading;

  /// 选中一个表情。
  final void Function(ImEmote) onSelect;

  @override
  State<EmotePanel> createState() => _EmotePanelState();
}

class _EmotePanelState extends State<EmotePanel> {
  int _activePackage = 0;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final panel = widget.panel;

    return Container(
      height: 240,
      decoration: BoxDecoration(
        color: c.secondaryGroupedBackground,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: Column(
        children: [
          Expanded(child: _body(c, panel)),
          if (panel != null && panel.loaded && panel.packages.length > 1)
            _packageTabs(c, panel),
        ],
      ),
    );
  }

  Widget _body(AppleColors c, ImEmotePanel? panel) {
    if (widget.loading || panel == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (!panel.loaded) {
      // 如实说明拿不到，并给出原因。不做"假装没有表情"的处理。
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppleSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.emoji_emotions_outlined,
                  size: 24, color: c.tertiaryLabel),
              const SizedBox(height: AppleSpace.sm),
              Text(
                panel.unavailableReason ?? '表情暂时无法加载。',
                textAlign: TextAlign.center,
                style: AppleType.caption1.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
        ),
      );
    }

    if (panel.isEmpty) {
      return Center(
        child: Text(
          '这个账号还没有可用的表情包。',
          style: AppleType.caption1.copyWith(color: c.secondaryLabel),
        ),
      );
    }

    final pkg = panel.packages[_activePackage.clamp(0, panel.packages.length - 1)];
    return GridView.builder(
      padding: const EdgeInsets.all(AppleSpace.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: AppleSpace.sm,
        crossAxisSpacing: AppleSpace.sm,
      ),
      itemCount: pkg.emotes.length,
      itemBuilder: (context, i) {
        final e = pkg.emotes[i];
        return GestureDetector(
          onTap: () => widget.onSelect(e),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Image.network(
              e.displayUrl,
              width: 32,
              height: 32,
              fit: BoxFit.contain,
              // 表情原图很小，按 2x 解码足够
              cacheWidth: 64,
              headers: const {'Referer': 'https://message.bilibili.com/'},
              errorBuilder: (_, __, ___) => Text(
                e.shortcode,
                style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _packageTabs(AppleColors c, ImEmotePanel panel) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppleSpace.md),
        itemCount: panel.packages.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppleSpace.sm),
        itemBuilder: (context, i) {
          final selected = i == _activePackage;
          final pkg = panel.packages[i];
          return Center(
            child: GestureDetector(
              onTap: () => setState(() => _activePackage = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpace.sm,
                  vertical: 6,
                ),
                child: Text(
                  pkg.name,
                  style: AppleType.caption1.copyWith(
                    color: selected ? c.blue : c.secondaryLabel,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
