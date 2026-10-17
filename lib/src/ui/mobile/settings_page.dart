/// 设置页：账号、平台能力、缓存。
///
/// 如实展示每个平台的能力边界 —— 这是"区分已实现与受限能力"
/// 在应用内的直接体现，也是用户理解"为什么某个视频刷不到"的入口。
library;

import 'package:flutter/material.dart';

import '../../core/credential_vault.dart';
import '../../core/video_service.dart';
import 'mobile_theme.dart';
import 'mobile_widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.service,
    required this.vault,
    required this.onLogout,
    this.loggedInLabel,
  });

  final VideoService service;
  final CredentialVault vault;
  final String? loggedInLabel;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final platforms = service.describePlatforms();
    final sources = service.describeFeedSources();
    final stats = service.cache.statsJson();
    final meta = stats['metadata'] as Map<String, Object?>? ?? const {};
    final cfg = stats['config'] as Map<String, Object?>? ?? const {};

    return Scaffold(
      backgroundColor: MobileTokens.lightCanvas,
      appBar: AppBar(
        backgroundColor: MobileTokens.lightCanvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded,
              size: 22, color: MobileTokens.ink),
        ),
        title: Text('设置', style: MobileText.listTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            MobileTokens.s4,
            MobileTokens.s2,
            MobileTokens.s4,
            MobileTokens.s8,
          ),
          children: [
            // ── 账号 ──────────────────────────────────────────
            _SectionTitle(title: '账号'),
            _Card(
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: loggedInLabel != null
                          ? MobileTokens.accent.withValues(alpha: 0.16)
                          : MobileTokens.lightBorder,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      loggedInLabel != null
                          ? Icons.person_rounded
                          : Icons.person_outline_rounded,
                      size: 20,
                      color: loggedInLabel != null
                          ? MobileTokens.accent
                          : MobileTokens.inkTertiary,
                    ),
                  ),
                  const SizedBox(width: MobileTokens.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          loggedInLabel ?? '未登录',
                          style: MobileText.body.copyWith(
                            color: MobileTokens.ink,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          loggedInLabel != null
                              ? '已保存加密会话凭证'
                              : '登录后可获取个性化内容',
                          style: MobileText.caption,
                        ),
                      ],
                    ),
                  ),
                  if (loggedInLabel != null)
                    TextButton(
                      onPressed: () async {
                        await onLogout();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已退出登录，本地凭证已删除')),
                          );
                        }
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: MobileTokens.danger,
                      ),
                      child: const Text('退出'),
                    ),
                ],
              ),
            ),

            const SizedBox(height: MobileTokens.s5),

            // ── 内容来源 ──────────────────────────────────────
            _SectionTitle(title: '内容来源'),
            _Card(
              child: Column(
                children: [
                  for (var i = 0; i < sources.length; i++) ...[
                    if (i > 0) const Divider(height: MobileTokens.s5),
                    _SourceRow(source: sources[i]),
                  ],
                  if (sources.isEmpty)
                    Text('暂无可用的内容来源。', style: MobileText.body),
                ],
              ),
            ),

            const SizedBox(height: MobileTokens.s5),

            // ── 平台能力 ──────────────────────────────────────
            _SectionTitle(title: '平台能力'),
            Text(
              '以下如实列出每个平台当前已实现与受限的能力。',
              style: MobileText.caption.copyWith(height: 1.5),
            ),
            const SizedBox(height: MobileTokens.s3),
            for (final p in platforms) ...[
              _Card(child: _PlatformCapability(descriptor: p)),
              const SizedBox(height: MobileTokens.s3),
            ],

            const SizedBox(height: MobileTokens.s2),

            // ── 缓存 ──────────────────────────────────────────
            _SectionTitle(title: '缓存与网络'),
            _Card(
              child: Column(
                children: [
                  _kv('元数据缓存有效期', '${cfg['metadataTtlSeconds']} 秒'),
                  _kv('播放地址缓存有效期', '${cfg['playbackTtlSeconds']} 秒'),
                  _kv('元数据缓存条目', '${meta['entries'] ?? 0}'),
                  _kv(
                    '缓存命中 / 未命中',
                    '${meta['hits'] ?? 0} / ${meta['misses'] ?? 0}',
                  ),
                  const SizedBox(height: MobileTokens.s3),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        service.cache.clear();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('缓存已清空')),
                        );
                      },
                      icon: const Icon(Icons.cleaning_services_rounded, size: 15),
                      label: const Text('清空缓存'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MobileTokens.inkSecondary,
                        side: const BorderSide(color: MobileTokens.lightBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(MobileTokens.rControl),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: MobileTokens.s5),

            // ── 合规说明 ──────────────────────────────────────
            _SectionTitle(title: '数据与合规'),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bullet('本应用仅使用各平台公开可访问的接口。'),
                  _bullet('不索取、不存储账号密码；登录通过平台官方扫码完成。'),
                  _bullet('会话凭证使用系统安全存储加密保存，不写入日志。'),
                  _bullet('不使用任何 WebView 或内嵌网页播放。'),
                  _bullet('不实现自有推荐算法，内容来自平台公开推荐流。'),
                  _bullet('不提供评论、点赞、收藏、弹幕等功能。'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: MobileTokens.s2),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: MobileText.body.copyWith(fontSize: 12.5)),
            ),
            Text(
              value,
              style: MobileText.body.copyWith(
                fontSize: 12.5,
                color: MobileTokens.ink,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );

  static Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: MobileTokens.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: 3.5,
                height: 3.5,
                decoration: const BoxDecoration(
                  color: MobileTokens.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: MobileTokens.s2),
            Expanded(
              child: Text(
                text,
                style: MobileText.caption.copyWith(height: 1.55),
              ),
            ),
          ],
        ),
      );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source});

  final dynamic source;

  @override
  Widget build(BuildContext context) {
    final available = source.available as bool;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(
            available ? Icons.check_circle_rounded : Icons.block_rounded,
            size: 15,
            color: available ? MobileTokens.positive : MobileTokens.inkTertiary,
          ),
        ),
        const SizedBox(width: MobileTokens.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                source.label as String,
                style: MobileText.body.copyWith(
                  color: available ? MobileTokens.ink : MobileTokens.inkTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                (available ? source.description : source.unavailableReason)
                        as String? ??
                    '',
                style: MobileText.caption.copyWith(height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlatformCapability extends StatelessWidget {
  const _PlatformCapability({required this.descriptor});

  final dynamic descriptor;

  @override
  Widget build(BuildContext context) {
    final caps = descriptor.capabilities;
    final mark = PlatformMark.of(descriptor.id as String);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: mark.tint,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                mark.symbol,
                style: MobileText.pill.copyWith(color: mark.onTint),
              ),
            ),
            const SizedBox(width: MobileTokens.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    descriptor.displayName as String,
                    style: MobileText.body.copyWith(
                      color: MobileTokens.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    (descriptor.hosts as List).take(2).join(' · '),
                    style: MobileText.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: MobileTokens.s3),
        Wrap(
          spacing: MobileTokens.s2,
          runSpacing: MobileTokens.s2,
          children: [
            _chip('元数据', caps.supportsMetadata as bool),
            _chip('应用内播放', caps.supportsNativePlayback as bool),
            _chip('官方嵌入', caps.supportsOfficialEmbed as bool),
            _chip('跳转原平台', caps.supportsExternalFallback as bool),
            if (caps.requiresSignature as bool) _chip('需平台签名', false),
          ],
        ),
        if (caps.maxQualityWithoutAuth != null) ...[
          const SizedBox(height: MobileTokens.s3),
          Text(
            '未登录清晰度上限：${caps.maxQualityWithoutAuth}',
            style: MobileText.caption,
          ),
        ],
        if ((caps.notes as List).isNotEmpty) ...[
          const SizedBox(height: MobileTokens.s3),
          const Divider(height: 1),
          const SizedBox(height: MobileTokens.s3),
          for (final n in (caps.notes as List))
            Padding(
              padding: const EdgeInsets.only(bottom: MobileTokens.s2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5.5),
                    child: Container(
                      width: 3.5,
                      height: 3.5,
                      decoration: const BoxDecoration(
                        color: MobileTokens.inkTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: MobileTokens.s2),
                  Expanded(
                    child: Text(
                      '$n',
                      style: MobileText.caption.copyWith(height: 1.55),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  static Widget _chip(String label, bool ok) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MobileTokens.s3,
          vertical: MobileTokens.s1 + 2,
        ),
        decoration: BoxDecoration(
          color: ok
              ? MobileTokens.positive.withValues(alpha: 0.14)
              : MobileTokens.lightBorder,
          borderRadius: BorderRadius.circular(MobileTokens.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              ok ? Icons.check_rounded : Icons.remove_rounded,
              size: 12,
              color: ok ? MobileTokens.positive : MobileTokens.inkTertiary,
            ),
            const SizedBox(width: MobileTokens.s1 + 1),
            Text(
              label,
              style: MobileText.pill.copyWith(
                color: ok ? MobileTokens.positive : MobileTokens.inkSecondary,
              ),
            ),
          ],
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: MobileTokens.s1,
        bottom: MobileTokens.s3,
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: MobileTokens.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: MobileTokens.s2),
          Text(
            title,
            style: MobileText.label.copyWith(
              color: MobileTokens.ink,
              fontWeight: FontWeight.w600,
              fontSize: 13.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(MobileTokens.s4),
      decoration: BoxDecoration(
        color: MobileTokens.lightSurface,
        borderRadius: BorderRadius.circular(MobileTokens.rCard),
        border: Border.all(color: MobileTokens.lightBorder),
      ),
      child: child,
    );
  }
}
