/// 红果短剧的播放进度与分集标识。
///
/// # 为什么需要单独一层
///
/// 项目已有的 [VideoProgressStore] 按 `videoId` 存进度。
/// 但红果一部剧有几十集，**进度必须按集记**——否则：
///
///  - 第 1 集看到 10 分钟，切到第 5 集会「继承」那个进度；
///  - 历史记录里只显示一条，看不出看到第几集。
///
/// 因此这里定义一套稳定的复合标识：
///
/// ```
/// 剧集：hongguo:{seriesId}
/// 分集：hongguo:{seriesId}#{episodeIndex}
/// ```
///
/// `#` 是分隔符，和 [HongguoAdapter.resolvePlayback] 解析
/// `platformVideoId` 的约定一致。
///
/// # 为什么不用 vid
///
/// `vid` 是平台内部 ID（`7503780574541122622`），用户看不懂，
/// 而且分集顺序调整时 vid 与集数的对应关系可能变化。
/// 用 `episodeIndex` 对用户更直观，也和 UI 的「第 N 集」一致。
library;

/// 红果播放标识的编解码。
class HongguoPlaybackId {
  const HongguoPlaybackId({
    required this.seriesId,
    this.episodeIndex,
  });

  /// 剧集 ID。
  final String seriesId;

  /// 集数（从 1 开始）。null 表示整部剧（默认第 1 集）。
  final int? episodeIndex;

  /// 拼成可存进 [VideoProgressStore] 的 `videoId`。
  ///
  /// 注意：这和 [HongguoAdapter] 内部用的 `platformVideoId` 是同一格式，
  /// 因此适配器可以直接解析它来定位分集。
  String toVideoId() {
    final base = 'hongguo:$seriesId';
    if (episodeIndex == null) return base;
    return '$base#$episodeIndex';
  }

  /// 从 `videoId` 解析。
  ///
  /// 兼容三种输入：
  ///  - `hongguo:123#5`  → seriesId=123, episode=5
  ///  - `hongguo:123`    → seriesId=123, episode=null
  ///  - `123#5`          → seriesId=123, episode=5（无前缀，宽松兼容）
  static HongguoPlaybackId? parse(String videoId) {
    if (videoId.isEmpty) return null;
    var rest = videoId;
    if (rest.startsWith('hongguo:')) {
      rest = rest.substring('hongguo:'.length);
    }
    final hash = rest.indexOf('#');
    if (hash < 0) {
      return HongguoPlaybackId(seriesId: rest);
    }
    final seriesId = rest.substring(0, hash);
    final idx = int.tryParse(rest.substring(hash + 1));
    if (seriesId.isEmpty) return null;
    return HongguoPlaybackId(seriesId: seriesId, episodeIndex: idx);
  }

  /// 用于历史记录展示的标题后缀。
  String get episodeLabel =>
      episodeIndex == null ? '' : ' 第$episodeIndex集';

  @override
  String toString() => toVideoId();
}

/// 从 `videoId` 取「这部剧」的 ID（去掉分集号）。
///
/// 用途：查「我上次看到第几集」时，需要按剧聚合历史记录。
String hongguoSeriesKeyOf(String videoId) {
  final parsed = HongguoPlaybackId.parse(videoId);
  return parsed?.seriesId ?? videoId;
}

/// 判断两个 `videoId` 是否属于同一部剧。
bool hongguoSameSeries(String a, String b) =>
    hongguoSeriesKeyOf(a) == hongguoSeriesKeyOf(b);
