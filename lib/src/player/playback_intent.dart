/// 播放意图与暂停/恢复判定（纯逻辑，无内核依赖）。
///
/// 抽出来的原因：这些判定是"暂停后点不回来""暂停后又自己播起来"
/// 两类缺陷的全部根因所在，但它们此前埋在 [FusionPlayerController]
/// 里、与 `media_kit` 的 `Player` 强耦合，无法在单元测试中验证。
///
/// 这里只保留**决策**，副作用（真正调 `pause()`/`play()`）留在控制器。
library;

/// 一次点击应当产生的动作。
enum PlaybackToggleAction {
  /// 暂停当前播放。
  pause,

  /// 从当前位置恢复播放。
  resume,

  /// 不响应（加载中、失败、已释放）。
  ignore,
}

/// 播放意图状态机。
///
/// 核心职责：记录**用户显式**的暂停意图，并让所有"自动起播"路径
/// 在它面前让路。
///
/// 内核里有三条异步自动起播路径（音轨延后挂载、起播修复的
/// `seek(0)+play`、以及失败回滚时的重新 `open(play:true)`），
/// 它们都可能在用户已经按下暂停之后才执行。若不统一记录意图，
/// 表现就是"暂停了过一会儿自己又播起来"。
class PlaybackIntent {
  bool _userPaused = false;

  /// 用户是否显式暂停过。
  bool get userPaused => _userPaused;

  /// 用户按下暂停。
  void onUserPause() => _userPaused = true;

  /// 用户按下恢复。
  void onUserResume() => _userPaused = false;

  /// 载入了新媒体（换源/换视频）。
  ///
  /// 新视频应当正常自动起播，因此清除上一次的暂停意图。
  void onNewMedia() => _userPaused = false;

  /// 自动起播前调用：允许则返回 true。
  ///
  /// **所有**自动起播点都必须先问这一句。
  bool get autoPlayAllowed => !_userPaused;
}

/// 判定一次点击应做什么。
///
/// [kernelPlaying] 必须是**内核实时状态**（`player.state.playing`），
/// 不能是快照里的 phase。快照由事件流驱动，与点击之间有几十毫秒延迟，
/// 连续两次点击会读到同一个旧值——这正是"暂停后点不回来"的直接原因。
///
/// [phaseFailed] 为 true 时忽略：失败态下切换播放没有意义。
/// [released] 为 true 时忽略：播放器已释放。
PlaybackToggleAction decideToggleAction({
  required bool kernelPlaying,
  required bool phaseFailed,
  required bool released,
}) {
  if (released) return PlaybackToggleAction.ignore;
  if (phaseFailed) return PlaybackToggleAction.ignore;
  return kernelPlaying
      ? PlaybackToggleAction.pause
      : PlaybackToggleAction.resume;
}

/// 恢复播放前是否需要先回到开头。
///
/// 播完之后 mpv 停在末尾，直接 `play()` 不会有任何反应——
/// 用户看到的就是"点了完全没反应"。必须先 `seek(0)`。
///
/// [toleranceMs] 用于吸收 position 与 duration 之间的微小差值
/// （最后一帧的时间戳通常略小于总时长）。
bool shouldRewindBeforeResume({
  required bool completed,
  required Duration position,
  required Duration duration,
  int toleranceMs = 300,
}) {
  if (completed) return true;
  if (duration.inMilliseconds <= 0) return false;
  return position.inMilliseconds >= duration.inMilliseconds - toleranceMs;
}

/// 判定"媒体是否已经可以被用户暂停/恢复"。
///
/// 不能用 `duration > 0` 判断：部分源要等首个分片才有总时长，
/// 无时长媒体（直播）永远没有 duration。这两种情况下
/// 用户点画面完全无响应，看起来就是"暂停坏了"。
///
/// 改为看快照 phase 是否处于"已加载"的任一态。
bool isToggleEnabledPhase({
  required bool idle,
  required bool loading,
  required bool failed,
}) =>
    !idle && !loading && !failed;
