/// 私信图片 / 表情的大图查看器。
///
/// # 为什么单独一个文件
///
/// 聊天页已经有 700+ 行，图片查看是**独立交互**（全屏、可缩放、
/// 可关闭），塞进 chat_screen 会让那个文件继续膨胀。
///
/// # 行为
///
///  - 全屏黑底，点击任意位置关闭
///  - 支持双指缩放（`InteractiveViewer`）
///  - 动图有 GIF/WebP 资源时优先播动图；没有就显示静态图
///  - 加载中显示菊花，失败显示明确文案（不显示空白）
///  - 有本地文件时优先用本地（发送中的图还没远端地址）
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../design/apple_tokens.dart';

/// 打开大图查看器。
Future<void> showImImageViewer(
  BuildContext context, {
  required String url,
  String? animatedUrl,
  String? localPath,
  String title = '图片',
}) {
  final target = (animatedUrl != null && animatedUrl.isNotEmpty)
      ? animatedUrl
      : url;
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: AppleMotion.fast,
      pageBuilder: (_, __, ___) => _ImageViewerPage(
        url: target,
        localPath: localPath,
        title: title,
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _ImageViewerPage extends StatelessWidget {
  const _ImageViewerPage({
    required this.url,
    this.localPath,
    required this.title,
  });

  final String url;
  final String? localPath;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Center(
                    child: localPath != null
                        ? Image.file(
                            File(localPath!),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                _error('本地图片已不可用'),
                          )
                        : Image.network(
                            url,
                            fit: BoxFit.contain,
                            headers: const {
                              'Referer': 'https://message.bilibili.com/',
                            },
                            loadingBuilder: (context, child, progress) {
                              if (progress == null) return child;
                              return const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                              );
                            },
                            errorBuilder: (_, __, ___) =>
                                _error('图片加载失败'),
                          ),
                  ),
                ),
              ),
              // 关闭按钮：右下角，避开系统手势区
              Positioned(
                right: 12,
                bottom: 12,
                child: IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.15),
                  ),
                  tooltip: '关闭',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _error(String message) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                size: 28, color: Colors.white54),
            const SizedBox(height: 8),
            Text(
              message,
              style: AppleType.footnote.copyWith(color: Colors.white70),
            ),
          ],
        ),
      );
}
