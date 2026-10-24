/// 字幕的跨层数据模型。
///
/// 放 `models/` 而不是 `adapters/bilibili/`：UI 要渲染字幕，
/// 但 UI 不得 import 具体平台适配器（见 `core/video_service.dart` 的职责边界）。
/// 类型属于"内容模型"，取数逻辑才属于平台。
library;

/// 一条字幕。
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  /// 起始（秒）。
  final double start;

  /// 结束（秒）。
  final double end;
  final String text;

  bool contains(double seconds) => seconds >= start && seconds < end;

  Map<String, Object?> toJson() => {
        'start': start,
        'end': end,
        'text': text,
      };
}

/// 一条可用字幕（列表项，尚未拉正文）。
class SubtitleTrackInfo {
  const SubtitleTrackInfo({
    required this.lan,
    required this.label,
    required this.url,
    required this.isAi,
  });

  /// 平台语言标识，如 `ai-zh` / `en-US`。
  final String lan;

  /// 面向用户的名称（平台给的 `lan_doc`，如「中文」）。
  final String label;

  /// 已补全协议的正文地址（含时效 auth_key）。
  final String url;

  /// 是否 AI 生成。要在 UI 上如实标注——AI 字幕会有识别错误。
  final bool isAi;

  /// 展示名：AI 字幕加标注，不冒充人工校对过的字幕。
  String get displayLabel => isAi ? '$label（AI）' : label;
}

/// 按时间点取当前字幕。
///
/// 单独成函数是为了可单测——二分与线性混合的边界（首条前、末条后、
/// 两条之间的空隙）最容易写错。
SubtitleCue? cueAt(List<SubtitleCue> cues, Duration position) {
  if (cues.isEmpty) return null;
  final s = position.inMilliseconds / 1000.0;
  // 字幕按时间递增，用二分定位候选，再检查邻居（容忍轻微重叠）。
  var lo = 0, hi = cues.length - 1, mid = 0;
  while (lo <= hi) {
    mid = (lo + hi) ~/ 2;
    if (cues[mid].start <= s) {
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  // hi 指向最后一个 start <= s 的条目。
  for (var i = hi; i > hi - 3 && i >= 0; i--) {
    if (cues[i].contains(s)) return cues[i];
  }
  return null;
}
