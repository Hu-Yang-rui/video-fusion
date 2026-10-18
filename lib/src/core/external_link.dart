/// 在系统默认浏览器中打开链接。
///
/// 用于「在原平台打开」这类**显式**跳转：用户点了才离开应用，
/// 不会静默把内容导流到外部。
///
/// 放在 core 而不是 UI 层：这是平台能力调用，与任何页面无关。
library;

import 'dart:io';

/// 用系统默认方式打开 [url]。
///
/// 失败时不抛出——打开外链失败属于次要路径，
/// 由调用方决定是否提示用户，不应中断当前流程。
Future<void> openInBrowser(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url], runInShell: true);
    } else if (Platform.isAndroid) {
      await Process.run(
        'am',
        ['start', '-a', 'android.intent.action.VIEW', '-d', url],
      );
    } else if (Platform.isIOS || Platform.isMacOS) {
      await Process.run('open', [url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } catch (_) {
    // 忽略：打开失败不影响应用内功能
  }
}
