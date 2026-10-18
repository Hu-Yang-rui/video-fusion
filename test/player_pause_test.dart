/// 播放暂停/恢复的回归测试。
///
/// 覆盖四类真实缺陷：
///  1. **暂停后点不回来**：用快照 phase 判断而非内核实时状态，
///     连续两次点击读到同一个旧值。
///  2. **暂停后自己又播起来**：音轨延后挂载、起播修复等异步路径
///     无条件 `play()`，覆盖用户意图。
///  3. **播完后点播放没反应**：mpv 停在末尾，不 seek(0) 就不动。
///  4. **切换视频后旧任务污染新视频**：上一个视频的后台任务
///     对新播放器下发 seek/open。
///
/// 这些判定已抽到 `playback_intent.dart`（纯函数），因此可以真正
/// 在单元测试里验证，而不是只能靠人肉点。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/player/playback_intent.dart';

void main() {
  group('点击判定：用内核实时状态，不用快照', () {
    test('内核正在播放 → 暂停', () {
      expect(
        decideToggleAction(
          kernelPlaying: true,
          phaseFailed: false,
          released: false,
        ),
        PlaybackToggleAction.pause,
      );
    });

    test('内核已暂停 → 恢复', () {
      expect(
        decideToggleAction(
          kernelPlaying: false,
          phaseFailed: false,
          released: false,
        ),
        PlaybackToggleAction.resume,
      );
    });

    test('连续两次点击产生相反动作（不会两次都读到同一状态）', () {
      // 模拟真实点击序列：内核状态在两次点击之间被第一次点击改变。
      // 若判定依赖快照 phase，第二次会读到旧值而重复"暂停"。
      var kernelPlaying = true;

      final first = decideToggleAction(
        kernelPlaying: kernelPlaying,
        phaseFailed: false,
        released: false,
      );
      expect(first, PlaybackToggleAction.pause);
      // 第一次点击真正生效（内核状态改变）
      kernelPlaying = false;

      final second = decideToggleAction(
        kernelPlaying: kernelPlaying,
        phaseFailed: false,
        released: false,
      );
      expect(second, PlaybackToggleAction.resume,
          reason: '第二次点击必须恢复，不能重复暂停');
    });

    test('失败态不响应', () {
      expect(
        decideToggleAction(
          kernelPlaying: false,
          phaseFailed: true,
          released: false,
        ),
        PlaybackToggleAction.ignore,
      );
    });

    test('播放器已释放不响应', () {
      expect(
        decideToggleAction(
          kernelPlaying: true,
          phaseFailed: false,
          released: true,
        ),
        PlaybackToggleAction.ignore,
      );
    });

    test('释放优先于失败判定', () {
      expect(
        decideToggleAction(
          kernelPlaying: true,
          phaseFailed: true,
          released: true,
        ),
        PlaybackToggleAction.ignore,
      );
    });
  });

  group('暂停意图：自动起播必须让路', () {
    test('初始状态允许自动起播', () {
      expect(PlaybackIntent().autoPlayAllowed, isTrue);
    });

    test('用户暂停后，自动起播被拒绝', () {
      final intent = PlaybackIntent()..onUserPause();
      expect(intent.userPaused, isTrue);
      expect(intent.autoPlayAllowed, isFalse,
          reason: '音轨挂载/起播修复不得在用户暂停后强行 play()');
    });

    test('用户恢复后，自动起播重新允许', () {
      final intent = PlaybackIntent()
        ..onUserPause()
        ..onUserResume();
      expect(intent.userPaused, isFalse);
      expect(intent.autoPlayAllowed, isTrue);
    });

    test('换视频清除暂停意图', () {
      final intent = PlaybackIntent()..onUserPause();
      intent.onNewMedia();
      expect(intent.userPaused, isFalse,
          reason: '新视频应当正常自动起播，不能继承上一条的暂停状态');
      expect(intent.autoPlayAllowed, isTrue);
    });

    test('暂停 → 换视频 → 暂停，状态正确累积', () {
      final intent = PlaybackIntent();
      intent.onUserPause();
      expect(intent.autoPlayAllowed, isFalse);
      intent.onNewMedia();
      expect(intent.autoPlayAllowed, isTrue);
      intent.onUserPause();
      expect(intent.autoPlayAllowed, isFalse);
    });
  });

  group('播完后恢复：必须先回到开头', () {
    test('completed 状态需要 rewind', () {
      expect(
        shouldRewindBeforeResume(
          completed: true,
          position: Duration.zero,
          duration: const Duration(seconds: 10),
        ),
        isTrue,
      );
    });

    test('位置贴近总时长需要 rewind（吸收最后一帧误差）', () {
      expect(
        shouldRewindBeforeResume(
          completed: false,
          position: const Duration(milliseconds: 9900),
          duration: const Duration(seconds: 10),
        ),
        isTrue,
        reason: '差 100ms 到末尾时直接 play() 不会有反应',
      );
    });

    test('位置在中途不需要 rewind（从当前位置继续）', () {
      expect(
        shouldRewindBeforeResume(
          completed: false,
          position: const Duration(seconds: 5),
          duration: const Duration(seconds: 10),
        ),
        isFalse,
        reason: '恢复必须从当前位置继续，不能跳回开头',
      );
    });

    test('无时长（直播/未解析）不需要 rewind', () {
      expect(
        shouldRewindBeforeResume(
          completed: false,
          position: Duration.zero,
          duration: Duration.zero,
        ),
        isFalse,
      );
    });

    test('时长恰好等于位置时需要 rewind', () {
      expect(
        shouldRewindBeforeResume(
          completed: false,
          position: const Duration(seconds: 10),
          duration: const Duration(seconds: 10),
        ),
        isTrue,
      );
    });

    test('自定义容差生效', () {
      expect(
        shouldRewindBeforeResume(
          completed: false,
          position: const Duration(milliseconds: 9400),
          duration: const Duration(seconds: 10),
          toleranceMs: 100,
        ),
        isFalse,
        reason: '容差 100ms 时 600ms 的差距不算末尾',
      );
    });
  });

  group('可切换播放的相位判定', () {
    test('idle 不可切换（尚未加载）', () {
      expect(
        isToggleEnabledPhase(idle: true, loading: false, failed: false),
        isFalse,
      );
    });

    test('loading 不可切换（解析中）', () {
      expect(
        isToggleEnabledPhase(idle: false, loading: true, failed: false),
        isFalse,
      );
    });

    test('failed 不可切换', () {
      expect(
        isToggleEnabledPhase(idle: false, loading: false, failed: true),
        isFalse,
      );
    });

    test('ready/playing/paused/buffering/completed 均可切换', () {
      // 这些相位在实现里都被映射为"允许"
      expect(
        isToggleEnabledPhase(idle: false, loading: false, failed: false),
        isTrue,
        reason: '不能用 duration>0 判断，无时长媒体也应可暂停',
      );
    });
  });
}
