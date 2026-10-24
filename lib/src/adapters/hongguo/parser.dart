/// 红果短剧官网数据解析。
///
/// # 数据来源
///
/// 官网 `hongguoduanju.com` 是**服务端渲染**，数据内嵌在 HTML 的
/// 内联 JSON 里，零签名、零登录、零 Cookie。
///
/// # 真实的页面结构（2026-10-20 实测，不是推测）
///
/// 首页 HTML 里有多个内嵌 JSON 数组：
///
/// | 键名 | 内容 | 有无剧名 |
/// |---|---|---|
/// | `bannerList` | 4 个 banner | ✅ `series_name` |
/// | `mBannerList` | 移动端 banner | ✅ |
/// | `mBannerSchedule` | 排期 | — |
/// | **`homeSections`** | **4 个 tab，每 tab 9 部剧** | ✅ **`series_title`** |
/// | `video_list` | 单个数组成员 | ✅ `series_title` |
///
/// **关键：`homeSections[].video_list[]` 才是主数据源**，
/// 字段名是 `series_title`（不是 `series_name`）。
///
/// 首页里共有 46 个 `series_id`，但只有 36 个在 `homeSections` 里；
/// 其余在 banner、埋点、推荐位中。**不能把首页所有 `series_id`
/// 都当成剧集列表**。
///
/// # 三个必须避免的错误（需求明确要求）
///
///  1. **不能分别正则 `series_id` 与 `series_name` 后按下标配对**
///     ——实测 46 个 id 只有 10 个 name，数量都对不上。
///     必须解析 JSON 对象，让 id/name/cover 天然成组。
///  2. **不能用 `series_name`** ——首页主数据源用的是 `series_title`。
///  3. **不能假定 `vid_list` 在首页有内容** ——实测首页全为 0 个，
///     必须进 `/player/{series_id}` 取分集。
library;

import 'dart:convert';

/// 一部剧的列表项。
class HongguoSeries {
  const HongguoSeries({
    required this.seriesId,
    required this.title,
    this.coverUrl,
    this.description,
    this.episodeCount,
    this.rank,
    this.tabName,
  });

  final String seriesId;
  final String title;
  final String? coverUrl;
  final String? description;

  /// 平台声明的总集数（`episode_cnt`）。null 表示未提供。
  ///
  /// **不等于** `vid_list` 长度——分集要另取。
  final int? episodeCount;

  /// 榜单排名（`rank`）。
  final int? rank;

  /// 所属 tab（热播短剧 / 热播真人剧 …）。
  final String? tabName;

  @override
  String toString() => 'HongguoSeries($seriesId, $title)';
}

/// 一集。
class HongguoEpisode {
  const HongguoEpisode({
    required this.index,
    required this.vid,
    required this.title,
    required this.playUrl,
  });

  /// 集数（从 1 开始）。
  ///
  /// # 依据
  ///
  /// 播放页 `vid_list` 是**有序数组**，第 i 项即第 i+1 集。
  /// 实测确认：第 0 项 `7503780574541122622` 对应的
  /// `/video/public/7503780574541122622/360p.mp4` 返回
  /// `206 + ftyp` 魔数（有效 MP4，16.5 MB）。
  ///
  /// 这是当前**唯一验证过**的关联方式。如果后续发现平台调整顺序，
  /// 需要重新验证而不是继续假设。
  final int index;

  final String vid;
  final String title;

  /// 播放地址。**只有 360p 被验证存在**。
  final String playUrl;
}

/// 剧集详情。
class HongguoSeriesDetail {
  const HongguoSeriesDetail({
    required this.seriesId,
    required this.title,
    required this.episodes,
    this.coverUrl,
    this.description,
  });

  final String seriesId;
  final String title;
  final List<HongguoEpisode> episodes;
  final String? coverUrl;
  final String? description;

  bool get hasEpisodes => episodes.isNotEmpty;
}

/// 官网 HTML 解析器。
class HongguoParser {
  const HongguoParser({this.baseUrl = 'https://hongguoduanju.com'});

  final String baseUrl;

  /// 解析首页，提取所有 tab 的剧集。
  ///
  /// 数据源：`homeSections[].video_list[]`。
  List<HongguoSeries> parseHomepage(String html) {
    final sectionsRaw = _extractJsonArray(html, 'homeSections');
    if (sectionsRaw == null) {
      // 兜底：尝试顶层 video_list
      return _parseTopLevelVideoList(html);
    }

    final List<Object?> sections;
    try {
      final decoded = jsonDecode(sectionsRaw);
      if (decoded is! List) return _parseTopLevelVideoList(html);
      sections = decoded;
    } catch (_) {
      return _parseTopLevelVideoList(html);
    }

    final out = <HongguoSeries>[];
    final seen = <String>{};

    for (final sec in sections) {
      if (sec is! Map) continue;
      final m = Map<String, Object?>.from(sec);
      final tabName = (m['tab_name'] as String?)?.trim();
      final list = m['video_list'];
      if (list is! List) continue;

      for (final item in list) {
        if (item is! Map) continue;
        final v = Map<String, Object?>.from(item);
        final id = _str(v['series_id']);
        if (id == null || id.isEmpty) continue;
        if (seen.contains(id)) continue;

        // 主数据源用 series_title；兼容 series_name
        final title = _str(v['series_title']) ?? _str(v['series_name']) ?? '';
        if (title.isEmpty) continue;

        seen.add(id);
        out.add(
          HongguoSeries(
            seriesId: id,
            title: title,
            coverUrl: _str(v['series_cover']) ?? _str(v['series_cover_pc']),
            description: _str(v['series_intro']),
            episodeCount: _toInt(v['episode_cnt']),
            rank: _toInt(v['rank']),
            tabName: tabName,
          ),
        );
      }
    }

    if (out.isEmpty) return _parseTopLevelVideoList(html);
    return out;
  }

  /// 解析分类页，提取剧集列表。
  ///
  /// 数据源是 `recommendList[]`，字段名用 `series_name`（不是首页的
  /// `series_title`）。每页 24 部。
  ///
  /// 分类路径：
  ///   `/category/real-drama`   真人剧
  ///   `/category/comic-drama`  漫剧
  ///   `/category/ai-drama`     AI 剧
  List<HongguoSeries> parseCategoryPage(String html) {
    final raw = _extractJsonArray(html, 'recommendList');
    if (raw == null) return const [];

    final List<Object?> items;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      items = decoded;
    } catch (_) {
      return const [];
    }

    final out = <HongguoSeries>[];
    final seen = <String>{};
    for (final item in items) {
      if (item is! Map) continue;
      final v = Map<String, Object?>.from(item);
      final id = _str(v['series_id']);
      final title = _str(v['series_name']) ?? _str(v['series_title']) ?? '';
      if (id == null || id.isEmpty || title.isEmpty) continue;
      if (!seen.add(id)) continue;
      out.add(
        HongguoSeries(
          seriesId: id,
          title: title,
          coverUrl: _str(v['series_cover']),
          description: _str(v['series_intro']),
          episodeCount: _toInt(v['episode_cnt']),
          rank: _toInt(v['rank']),
        ),
      );
    }
    return out;
  }

  /// 解析**搜索接口**返回的 JSON（不是 HTML）。
  ///
  /// 接口：`GET /api/search/result/?query={关键词}&page={页码}`
  ///
  /// # 实测（2026-10-23，`query=总裁`）
  ///
  /// 响应结构：
  /// ```json
  /// {
  ///   "searchList": [
  ///     {"doc_type":23, "name":"总裁是我前女友",
  ///      "keyword":"7688352674999176254",
  ///      "video_data":{"series_id":"...","series_title":"...",
  ///                    "series_cover":"https://...","episode_cnt":95,
  ///                    "series_intro":"...", ...}}
  ///   ],
  ///   "totalCount": 204, "pageNum": 1, "totalPages": 21, "hasMore": true
  /// }
  /// ```
  ///
  /// 三个必须知道的坑：
  ///  1. 剧集信息在 **`video_data` 子对象**里，不在条目顶层；
  ///     顶层的 `name` 是搜索命中的展示名，`series_title` 才是剧名。
  ///  2. 字段名是 `series_cover`（不是分类页的 `series_cover_pc`）。
  ///  3. 每页**固定 10 条**，`count` 参数不生效；分页用 `page`。
  ///
  /// 解析失败或空列表返回空（由适配器决定报"没搜到"还是"解析失败"）。
  SearchParseResult parseSearchResult(String body) {
    final Map<String, Object?> root;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return SearchParseResult.empty;
      root = Map<String, Object?>.from(decoded);
    } catch (_) {
      return SearchParseResult.empty;
    }

    final rawList = root['searchList'];
    final out = <HongguoSeries>[];
    final seen = <String>{};
    if (rawList is List) {
      for (final item in rawList) {
        if (item is! Map) continue;
        final entry = Map<String, Object?>.from(item);

        // 剧集数据在 video_data 里；没有就跳过（可能是演员/话题命中）
        final vd = entry['video_data'];
        if (vd is! Map) continue;
        final v = Map<String, Object?>.from(vd);

        final seriesId = _str(v['series_id']);
        if (seriesId == null || seriesId.isEmpty) continue;
        if (!seen.add(seriesId)) continue;

        final title = _str(v['series_title']) ??
            _str(v['series_name']) ??
            _str(entry['name']) ??
            '';
        if (title.isEmpty) continue;

        out.add(
          HongguoSeries(
            seriesId: seriesId,
            title: title,
            coverUrl: _str(v['series_cover']) ?? _str(v['series_cover_pc']),
            description: _str(v['series_intro']),
            episodeCount: _toInt(v['episode_cnt']),
          ),
        );
      }
    }

    return SearchParseResult(
      items: out,
      totalCount: _toInt(root['totalCount']) ?? 0,
      pageNum: _toInt(root['pageNum']) ?? 1,
      totalPages: _toInt(root['totalPages']) ?? 1,
      hasMore: root['hasMore'] == true,
    );
  }

  /// 解析排行榜页，提取 `rankList`。
  ///
  /// # 数据形态（2026-10-24 实测，推翻了"无 SSR 数据"的旧结论）
  ///
  /// 榜单数据在 HTML 里被 **HTML 实体转义**过：
  /// ```
  /// &quot;rankList&quot;:[{&quot;id&quot;:&quot;...&quot;,
  ///   &quot;seriesId&quot;:&quot;7697209269287914521&quot;,
  ///   &quot;rank&quot;:1,&quot;title&quot;:&quot;持械入宋：第十季&quot;,
  ///   &quot;cover&quot;:&quot;https://...&quot;,
  ///   &quot;heatText&quot;:&quot;7921万热度&quot;,...}]
  /// ```
  /// 所以必须先把 `&quot;` 解回 `"` 才能当 JSON 解析。
  ///
  /// 四个榜单路径实测各 20 部：
  ///   `/rank/hot-drama` `/rank/hot-real-drama`
  ///   `/rank/hot-comic-drama` `/rank/hot-ai-drama`
  ///
  /// 字段名与首页/分类页**都不同**：这里是 `seriesId`（驼峰）、
  /// `title`、`cover`，不是 `series_id` / `series_title` / `series_cover`。
  List<HongguoSeries> parseRankPage(String html) {
    // HTML 实体解码：只处理会破坏 JSON 的几个
    final decoded = html
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&amp;', '&');

    final raw = _extractJsonArray(decoded, 'rankList');
    if (raw == null) return const [];

    final List<Object?> items;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List) return const [];
      items = parsed;
    } catch (_) {
      return const [];
    }

    final out = <HongguoSeries>[];
    final seen = <String>{};
    for (final item in items) {
      if (item is! Map) continue;
      final v = Map<String, Object?>.from(item);

      // 榜单用驼峰 seriesId；兼容下划线写法
      final id = _str(v['seriesId']) ?? _str(v['series_id']);
      final title = _str(v['title']) ?? _str(v['series_title']) ?? '';
      if (id == null || id.isEmpty || title.isEmpty) continue;
      if (!seen.add(id)) continue;

      out.add(
        HongguoSeries(
          seriesId: id,
          title: title,
          coverUrl: _str(v['cover']) ?? _str(v['series_cover']),
          description: _str(v['description']),
          rank: _toInt(v['rank']),
        ),
      );
    }
    return out;
  }

  /// 兜底：解析顶层 `video_list`（首页只有 9 部时可能走这里）。
  List<HongguoSeries> _parseTopLevelVideoList(String html) {
    final raw = _extractJsonArray(html, 'video_list');
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <HongguoSeries>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final v = Map<String, Object?>.from(item);
        final id = _str(v['series_id']);
        final title = _str(v['series_title']) ?? _str(v['series_name']) ?? '';
        if (id == null || id.isEmpty || title.isEmpty) continue;
        out.add(
          HongguoSeries(
            seriesId: id,
            title: title,
            coverUrl: _str(v['series_cover']),
            description: _str(v['series_intro']),
            episodeCount: _toInt(v['episode_cnt']),
            rank: _toInt(v['rank']),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 解析播放页，提取分集列表。
  HongguoSeriesDetail? parsePlayerPage(
    String html, {
    required String seriesId,
  }) {
    final vidListRaw = _extractJsonArray(html, 'vid_list');
    if (vidListRaw == null) return null;

    final List<Object?> list;
    try {
      final decoded = jsonDecode(vidListRaw);
      if (decoded is! List) return null;
      list = decoded;
    } catch (_) {
      return null;
    }

    final vids = list
        .map((e) => _str(e) ?? '')
        .where((s) => RegExp(r'^\d+$').hasMatch(s))
        .toList();
    if (vids.isEmpty) return null;

    final title =
        _str(_firstJsonValue(html, 'series_name')) ??
        _str(_firstJsonValue(html, 'series_title')) ??
        '';

    final cover = _str(_firstJsonValue(html, 'series_cover'));
    final desc = _str(_firstJsonValue(html, 'series_intro'));

    final episodes = <HongguoEpisode>[];
    for (var i = 0; i < vids.length; i++) {
      final vid = vids[i];
      episodes.add(
        HongguoEpisode(
          index: i + 1,
          vid: vid,
          title: '第${i + 1}集',
          // 只拼 360p —— 实测仅此档存在（540p/720p/1080p 均 404）
          playUrl: '$baseUrl/video/public/$vid/360p.mp4',
        ),
      );
    }

    return HongguoSeriesDetail(
      seriesId: seriesId,
      title: title,
      episodes: episodes,
      coverUrl: cover,
      description: desc,
    );
  }

  /// 判断页面是否不含剧集数据（下架 / 不存在）。
  bool isMissingPage(String html) =>
      !html.contains('vid_list') && !html.contains('series_title');

  // ── 工具 ──────────────────────────────────────────────────

  /// 从 HTML 里抠出 `"key": [...]` 的完整 JSON 数组文本。
  ///
  /// 用括号配对扫描，正确处理字符串内的 `[` `]` 与转义。
  static String? _extractJsonArray(String html, String key) {
    final idx = html.indexOf('"$key"');
    if (idx < 0) return null;
    final start = html.indexOf('[', idx);
    if (start < 0) return null;

    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < html.length; i++) {
      final c = html[i];
      if (esc) {
        esc = false;
        continue;
      }
      if (c == '\\') {
        esc = true;
        continue;
      }
      if (c == '"') {
        inStr = !inStr;
        continue;
      }
      if (inStr) continue;
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) return html.substring(start, i + 1);
      }
    }
    return null;
  }

  /// 取某个键第一次出现的值（字符串或数字）。
  static Object? _firstJsonValue(String html, String key) {
    final m = RegExp('"$key"\\s*:\\s*("([^"]{1,300})"|(\\d+))')
        .firstMatch(html);
    if (m == null) return null;
    return m.group(2) ?? m.group(3);
  }

  static String? _str(Object? v) {
    if (v == null) return null;
    if (v is String) return v.trim().isEmpty ? null : v.trim();
    return '$v';
  }

  static int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// 搜索接口的解析结果（含分页信息）。
///
/// 与 [HongguoSeries] 列表分开返回：搜索结果需要 `totalCount` / `hasMore`
/// 才能正确渲染"共 N 部，还有更多"，只返回列表会丢掉这些。
class SearchParseResult {
  const SearchParseResult({
    required this.items,
    required this.totalCount,
    required this.pageNum,
    required this.totalPages,
    required this.hasMore,
  });

  static const SearchParseResult empty = SearchParseResult(
    items: [],
    totalCount: 0,
    pageNum: 1,
    totalPages: 1,
    hasMore: false,
  );

  final List<HongguoSeries> items;

  /// 平台口径的命中总数（实测 `query=总裁` → 204）。
  final int totalCount;

  /// 当前页（从 1 开始，平台回显）。
  final int pageNum;

  final int totalPages;

  /// 平台是否声明还有下一页。
  final bool hasMore;

  bool get isEmpty => items.isEmpty;
}
