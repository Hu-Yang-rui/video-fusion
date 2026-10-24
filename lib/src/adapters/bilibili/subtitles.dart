/// B站 CC 字幕（含 AI 字幕）+ 进度条拼图预览。
///
/// 三个实测边界：
///  - 匿名列字幕得到 `code=0` + `subtitles: []`（空数组，不是 403/404）
///  - `subtitle_url` 协议相对且带时效 `auth_key`，必须补 `https:`
///  - `videoshot` 匿名可用，但参数只能是 `aid+index`（给 bvid/cid 则 index 为空）
///
/// 自绘字幕而非 mpv `sub-add` 的理由见私有仓库总表 2G.5。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';
import '../../core/seek_preview.dart';
import '../../models/subtitles.dart';
import 'wbi_signer.dart';

// 类型定义在 models/：UI 通过 VideoService 用它们，不该 import 平台适配器。
export '../../models/subtitles.dart' show SubtitleCue, SubtitleTrackInfo, cueAt;

/// B站视频的 id 三元组（字幕与拼图预览都需要 aid + cid）。
class BilibiliVideoIds {
  const BilibiliVideoIds({
    required this.aid,
    required this.cid,
    required this.bvid,
    required this.durationSeconds,
  });

  final int aid;
  final int cid;

  /// 规范 BV 号。`platformVideoId` 可能是 `av123` 形式（来自 av 链接），
  /// 而字幕接口只认 bvid，所以必须从 view 响应里取回真 bvid。
  final String bvid;

  /// 视频总时长（秒）。用于在 videoshot 的 index 表缺项时兜底。
  final int durationSeconds;
}

/// B站字幕客户端。
class BilibiliSubtitleClient {
  BilibiliSubtitleClient({
    required FusionHttpClient http,
    FusionLogger? logger,
    String apiBase = 'https://api.bilibili.com',
  })  : _http = http,
        _logger = logger ?? appLogger,
        _apiBase = apiBase;

  final FusionHttpClient _http;
  final FusionLogger _logger;
  final String _apiBase;

  // 延迟创建：只在真要拉字幕时才取 wbi key。
  late final WbiSigner _wbi = WbiSigner(http: _http, logger: _logger);

  /// 解析后的 cue 列表缓存：按语言标识存（正文地址带时效，不缓存 URL 本身）。
  final Map<String, List<SubtitleCue>> _cueCache = {};

  void clearCache() {
    _cueCache.clear();
    _sprites.clear();
    _ids.clear();
  }

  /// 解析某视频**第一 P** 的 aid + cid + 真 bvid。
  ///
  /// 独立于 BilibiliAdapter 的私有实现：字幕与预览都只需要这三个 id，
  /// 这里用匿名可用的 `view` 接口自取，避免为一个 id 去改 5000 行的适配器。
  ///
  /// 入参可能是 `BV…`、`av123`、纯数字（`extract()` 对 av 链接就给 av 形式），
  /// 因此按形态选查询参数；返回的 `bvid` 一律取响应里的规范值，
  /// 后续字幕接口只用它。
  Future<BilibiliVideoIds?> resolveIds(String platformVideoId) async {
    final key = platformVideoId.trim();
    if (key.isEmpty) return null;
    final cached = _ids[key];
    if (cached != null) return cached;
    final av = RegExp(r'^(?:av)?(\d+)$', caseSensitive: false).firstMatch(key);
    final query = av != null
        ? 'aid=${av.group(1)}'
        : 'bvid=${Uri.encodeQueryComponent(key)}';
    try {
      final res = await _http.get(
        '$_apiBase/x/web-interface/view?$query',
        headers: const {
          'referer': 'https://www.bilibili.com/',
          'accept': 'application/json',
        },
        platformId: 'bilibili',
        timeout: const Duration(seconds: 15),
      );
      final json = res.jsonObject(platformId: 'bilibili');
      if (json['code'] != 0) return null;
      final data = json['data'];
      if (data is! Map) return null;
      final d = Map<String, Object?>.from(data);
      final ids = BilibiliVideoIds(
        aid: (d['aid'] as num?)?.toInt() ?? 0,
        cid: (d['cid'] as num?)?.toInt() ?? 0,
        bvid: '${d['bvid'] ?? ''}'.trim(),
        durationSeconds: (d['duration'] as num?)?.toInt() ?? 0,
      );
      if (ids.cid <= 0 || ids.bvid.isEmpty) return null;
      _ids[key] = ids;
      // 同一视频的 av/BV 两种写法共用一条缓存（BV↔aid 一一对应永不变更）。
      if (ids.bvid != key) _ids[ids.bvid] = ids;
      return ids;
    } catch (e) {
      _logger.warn('bili subtitle: resolveIds failed', {'error': '$e'});
      return null;
    }
  }

  final Map<String, BilibiliVideoIds> _ids = {};

  /// 列出某视频某 P 的可用字幕。
  ///
  /// 未登录返回空列表——**这是平台的真实行为**（实测 `code=0` + `subtitles: []`），
  /// 不抛异常；UI 想区分"没字幕"与"没登录"，交给调用方看登录态。
  Future<List<SubtitleTrackInfo>> list({
    required String bvid,
    required int cid,
    required String cookieHeader,
  }) async {
    final Map<String, Object?> json;
    try {
      final signed = await _wbi.sign({'bvid': bvid, 'cid': cid});
      final res = await _http.get(
        '$_apiBase/x/player/wbi/v2?$signed',
        headers: {
          'referer': 'https://www.bilibili.com/video/$bvid',
          'cookie': cookieHeader,
          'accept': 'application/json, text/plain, */*',
        },
        platformId: 'bilibili',
        timeout: const Duration(seconds: 15),
      );
      json = res.jsonObject(platformId: 'bilibili');
    } on FusionException {
      rethrow;
    } catch (e) {
      _logger.warn('bili subtitle: list failed', {'error': '$e'});
      return const [];
    }

    if (json['code'] != 0) return const [];
    final data = json['data'];
    if (data is! Map) return const [];
    final sub = (data['subtitle'] as Map?)?['subtitles'];
    if (sub is! List) return const [];

    return sub
        .whereType<Map>()
        .map((e) {
          final url = _absolutize('${e['subtitle_url'] ?? ''}');
          if (url.isEmpty) return null;
          final lan = '${e['lan'] ?? ''}';
          return SubtitleTrackInfo(
            lan: lan,
            label: '${e['lan_doc'] ?? lan}',
            url: url,
            // 平台用 ai_type / ai_status 标记 AI 字幕；lan 的 ai- 前缀是
            // 更稳的判据（实测两种条目都有）。
            isAi: lan.startsWith('ai-') ||
                ((e['ai_type'] as num?)?.toInt() ?? 0) != 0,
          );
        })
        .whereType<SubtitleTrackInfo>()
        .toList(growable: false);
  }

  /// 拉取并解析某条字幕的正文。
  ///
  /// 失败返回空列表（不抛）：字幕是增强信息，不该因为拉不到就打断播放。
  Future<List<SubtitleCue>> fetchCues(SubtitleTrackInfo track) async {
    final cached = _cueCache[track.lan];
    if (cached != null) return cached;
    try {
      final res = await _http.get(
        track.url,
        headers: const {
          'referer': 'https://www.bilibili.com/',
          'accept': '*/*',
        },
        platformId: 'bilibili',
        timeout: const Duration(seconds: 15),
      );
      final cues = parseSubtitleBody(res.body);
      if (cues.isNotEmpty) _cueCache[track.lan] = cues;
      return cues;
    } catch (e) {
      _logger.warn('bili subtitle: fetch body failed', {
        'lan': track.lan,
        'error': '$e',
      });
      return const [];
    }
  }

  /// `//host/path` → `https://host/path`。
  static String _absolutize(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('//')) return 'https:$t';
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    return '';
  }

  /// 拉进度条拖动预览用的拼图（`/x/player/videoshot`）。
  ///
  /// **匿名即可用**（实测登录与匿名响应一致），所以不要求 Cookie。
  /// 参数形态必须是 `aid + index=1`：实测 `?bvid=` 与 `?aid=&cid=`
  /// 都返回 `image` 有值但 **`index` 为空数组**，只有 `aid+index` 给全表。
  /// 解析失败/字段缺失返回 null（几何层会再判一次 isEmpty）。
  Future<SpriteSheetSpec?> fetchSprite(int aid, {int page = 1}) async {
    if (aid <= 0) return null;
    final cached = _sprites[aid];
    if (cached != null) return cached;
    try {
      final res = await _http.get(
        '$_apiBase/x/player/videoshot?aid=$aid&index=$page',
        headers: const {
          'referer': 'https://www.bilibili.com/',
          'accept': 'application/json, text/plain, */*',
        },
        platformId: 'bilibili',
        timeout: const Duration(seconds: 15),
      );
      final spec = SpriteSheetSpec.parse(res.jsonObject(platformId: 'bilibili'));
      if (spec != null && !spec.isEmpty) {
        _sprites[aid] = spec;
        return spec;
      }
      return null;
    } catch (e) {
      _logger.warn('bili subtitle: videoshot failed', {
        'aid': aid,
        'error': '$e',
      });
      return null;
    }
  }

  final Map<int, SpriteSheetSpec> _sprites = {};

  /// 拉一张拼图的**原始字节**（整图实测 4800×2700 JPEG ≈ 300 KB）。
  ///
  /// 必须走 `keepRawBytes`：拼图是二进制，按 UTF-8 解成 `body` 会丢字节。
  /// CDN 实测不校验 Referer/UA（无 referer 也 200），但照常带上以防变化。
  Future<Uint8List?> fetchSpriteBytes(String url) async {
    if (url.isEmpty) return null;
    try {
      final res = await _http.get(
        url,
        headers: const {
          'referer': 'https://www.bilibili.com/',
          'accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        },
        platformId: 'bilibili',
        timeout: const Duration(seconds: 20),
        keepRawBytes: true,
      );
      return res.rawBytes;
    } catch (e) {
      _logger.warn('bili subtitle: sprite sheet fetch failed', {
        'error': '$e',
      });
      return null;
    }
  }

  /// 解析字幕正文。
  ///
  /// 结构：`{"body":[{"from":0.06,"to":2.42,"content":"…"}]}`
  ///  - `from`/`to` 是**秒**（double）
  ///  - 容忍 `to` 缺省（用下一条的 `from`，最后一条给 +2s）
  ///  - 空内容、时间轴倒挂的条目直接丢——宁可少一条，不画错时间
  static List<SubtitleCue> parseSubtitleBody(String raw) {
    if (raw.trim().isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final body = decoded['body'];
    if (body is! List) return const [];

    final parsed = <(double, double?, String)>[];
    for (final item in body) {
      if (item is! Map) continue;
      final text = '${item['content'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      final from = _toDouble(item['from']);
      if (from == null) continue;
      parsed.add((from, _toDouble(item['to']), text));
    }

    final cues = <SubtitleCue>[];
    for (var i = 0; i < parsed.length; i++) {
      final (from, toOpt, text) = parsed[i];
      // 缺 to 时用下一条的 from 兜底，最后一条给 2 秒显示时长。
      final end = toOpt ??
          (i + 1 < parsed.length
              ? parsed[i + 1].$1
              : from + 2);
      if (end <= from) continue;
      cues.add(SubtitleCue(start: from, end: end, text: text));
    }
    return cues;
  }

  static double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

