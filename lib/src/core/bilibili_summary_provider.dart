/// B 站视频 AI 总结。
///
/// # 接口
///
/// ```
/// GET https://api.bilibili.com/x/web-interface/view/conclusion/get
///     ?bvid={bvid}&cid={cid}&up_mid={up_mid}&wts={ts}&w_rid={md5}
/// ```
///
/// # 实测记录（2026-10-20，真实账号）
///
/// | 请求方式 | 结果 |
/// |---|---|
/// | 匿名，无 wbi | `code=-403 访问权限不足` |
/// | 匿名，带 wbi | `code=-101 账号未登录` |
/// | **登录 + wbi** | **`code=0`，返回真实总结** |
///
/// 说明：
///  - 接口存在（`-403`/`-101` 都不是 404）
///  - **wbi 签名是必须的**（否则 `-403`，而非 `-101`）
///  - 签名正确后只剩登录态
///
/// 实测 12 个排行榜视频，6 个有总结：
///  - 有总结：`summary` 100+ 字，`outline` 1–5 段，含秒级 `timestamp`
///  - 无总结：`code=0` 但 `summary` 为空、`outline` 为空
///
/// **「无总结」与「失败」在响应上可区分**：前者 `code=0`，后者 `code!=0`。
///
/// # 响应结构
///
/// ```json
/// {
///   "code": 0,
///   "data": {
///     "model_result": {
///       "result_type": 2,
///       "summary": "团队探访OnlyFans平台，剖析成人创作者生态…",
///       "outline": [
///         {
///           "title": "探索OnlyFans成人创作者生态",
///           "timestamp": 1,
///           "part_outline": [
///             {"timestamp": 20, "content": "onlyfans平台吸引成人内容创作者…"}
///           ]
///         }
///       ],
///       "subtitle": []
///     },
///     "stid": "...",
///     "status": 0,
///     "like_num": 0,
///     "dislike_num": 0
///   }
/// }
/// ```
library;

import 'dart:convert';

import '../adapters/bilibili/wbi_signer.dart';
import '../core/http_client.dart';
import '../core/logger.dart';
import '../models/video_summary.dart';

/// B 站视频总结 Provider。
class BilibiliSummaryProvider {
  BilibiliSummaryProvider({
    required FusionHttpClient http,
    FusionLogger? logger,
    String apiBase = 'https://api.bilibili.com',
    String referer = 'https://www.bilibili.com/',
  })  : _http = http,
        _logger = logger ?? appLogger,
        _apiBase = apiBase,
        _referer = referer;

  final FusionHttpClient _http;
  final FusionLogger _logger;
  final String _apiBase;
  final String _referer;

  late final WbiSigner _wbi = WbiSigner(http: _http, logger: _logger);

  /// 当前登录态（Cookie 头）。为空表示未登录。
  ///
  /// **不持久化、不写日志**：由调用方在每次请求前注入。
  String? cookieHeader;

  String get providerId => 'bilibili';

  bool get isAvailable => (cookieHeader ?? '').isNotEmpty;

  String? get unavailableReason =>
      isAvailable ? null : 'B 站 AI 总结需要登录后才能使用。';

  /// 拉取视频总结。
  ///
  /// [bvid] / [cid] / [upMid] 都来自已有的视频详情，不需要额外请求。
  Future<VideoSummary> fetchSummary({
    required String bvid,
    required int cid,
    required int upMid,
  }) async {
    if (!isAvailable) {
      return VideoSummary.failure(
        errorMessage: 'B 站 AI 总结需要登录。请在设置里登录 B 站账号后重试。',
        source: VideoSummarySource.platform,
        retryable: true,
        providerId: providerId,
      );
    }
    if (bvid.isEmpty || cid <= 0) {
      return VideoSummary.failure(
        errorMessage: '缺少视频标识（bvid 或 cid），无法获取总结。',
        source: VideoSummarySource.platform,
        retryable: false,
        providerId: providerId,
      );
    }

    // wbi 签名：失败重试一次（密钥可能过期，-352 会触发 invalidate）
    for (var attempt = 0; attempt < 2; attempt++) {
      final String signedQuery;
      try {
        signedQuery = await _wbi.sign({
          'bvid': bvid,
          'cid': cid,
          'up_mid': upMid,
        });
      } catch (e) {
        return VideoSummary.failure(
          errorMessage: 'B 站签名准备失败：${'$e'.split('\n').first}',
          source: VideoSummarySource.platform,
          providerId: providerId,
        );
      }

      final url =
          '$_apiBase/x/web-interface/view/conclusion/get?$signedQuery';

      HttpResult res;
      try {
        res = await _http.get(
          url,
          headers: {
            'referer': '$_referer/video/$bvid',
            'cookie': cookieHeader!,
          },
          timeout: const Duration(seconds: 15),
        );
      } catch (e) {
        return VideoSummary.failure(
          errorMessage: 'B 站总结请求失败：${'$e'.split('\n').first}',
          source: VideoSummarySource.platform,
          providerId: providerId,
        );
      }

      final result = _parse(res, bvid: bvid);

      // -352 = wbi 签名无效 → 清缓存重签一次
      if (result.upstreamCode == -352 && attempt == 0) {
        _logger.info('bilibili summary: wbi expired, re-signing');
        _wbi.invalidate();
        continue;
      }
      return result;
    }

    return VideoSummary.failure(
      errorMessage: 'B 站总结签名反复失效，请稍后重试。',
      source: VideoSummarySource.platform,
      providerId: providerId,
    );
  }

  /// 解析响应。**不把 HTTP 200 当成功**，必须看 `code` 与 `summary`。
  VideoSummary _parse(HttpResult res, {required String bvid}) {
    if (res.statusCode != 200) {
      return VideoSummary.failure(
        errorMessage: 'B 站总结请求失败（HTTP ${res.statusCode}）。',
        source: VideoSummarySource.platform,
        upstreamCode: res.statusCode,
        providerId: providerId,
      );
    }

    final Map<String, Object?> json;
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        return VideoSummary.failure(
          errorMessage: 'B 站总结返回了非对象结构。',
          source: VideoSummarySource.platform,
          providerId: providerId,
        );
      }
      json = Map<String, Object?>.from(decoded);
    } catch (_) {
      return VideoSummary.failure(
        errorMessage: 'B 站总结返回了无法解析的内容。',
        source: VideoSummarySource.platform,
        providerId: providerId,
      );
    }

    final code = json['code'];
    if (code != 0) {
      final message = (json['message'] ?? json['msg'] ?? '').toString();
      return VideoSummary.failure(
        errorMessage: _mapCode(code, message),
        source: VideoSummarySource.platform,
        upstreamCode: code,
        providerId: providerId,
        retryable: code != -404 && code != -403,
      );
    }

    // code == 0 → 看 model_result
    final data = json['data'];
    if (data is! Map) {
      return VideoSummary.noSummary(
        source: VideoSummarySource.platform,
        providerId: providerId,
        reason: '该视频暂无 AI 总结。',
      );
    }
    final model = data['model_result'];
    if (model is! Map) {
      return VideoSummary.noSummary(
        source: VideoSummarySource.platform,
        providerId: providerId,
        reason: '该视频暂无 AI 总结。',
      );
    }

    final summary = (model['summary'] as String?)?.trim() ?? '';
    final outline = model['outline'];

    final chapters = <SummaryChapter>[];
    if (outline is List) {
      for (final item in outline) {
        if (item is! Map) continue;
        final m = Map<String, Object?>.from(item);
        final title = (m['title'] as String?)?.trim() ?? '';
        final ts = _toInt(m['timestamp']);
        final points = <SummaryPoint>[];
        final parts = m['part_outline'];
        if (parts is List) {
          for (final p in parts) {
            if (p is! Map) continue;
            final pm = Map<String, Object?>.from(p);
            final content = (pm['content'] as String?)?.trim() ?? '';
            if (content.isEmpty) continue;
            points.add(SummaryPoint(
              content: content,
              timestampSeconds: _toInt(pm['timestamp']),
            ));
          }
        }
        if (title.isEmpty && points.isEmpty) continue;
        chapters.add(SummaryChapter(
          title: title,
          timestampSeconds: ts,
          points: points,
        ));
      }
    }

    // 关键：summary 为空且无章节 → 「无总结」，不是失败
    if (summary.isEmpty && chapters.isEmpty) {
      return VideoSummary.noSummary(
        source: VideoSummarySource.platform,
        providerId: providerId,
        reason: '该视频暂无 AI 总结。',
      );
    }

    return VideoSummary.success(
      summary: summary.isEmpty ? _chaptersToText(chapters) : summary,
      source: VideoSummarySource.platform,
      chapters: chapters,
      providerId: providerId,
    );
  }

  /// 业务码 → 用户可读原因。
  String _mapCode(Object? code, String message) {
    switch (code) {
      case -101:
        return 'B 站账号未登录，请登录后重试。';
      case -403:
        return 'B 站拒绝了该请求（权限不足）。可能是签名或登录态问题。';
      case -352:
        return 'B 站签名失效，正在重试。';
      case -404:
        return '该视频不存在或已删除。';
      case -412:
        return 'B 站限流，请稍后再试。';
      case -500:
        return 'B 站服务异常，请稍后重试。';
      default:
        return message.isEmpty
            ? 'B 站总结失败（code=$code）。'
            : 'B 站总结失败：$message（code=$code）';
    }
  }

  /// 章节兜底成纯文本（当 summary 为空但 outline 有内容时）。
  String _chaptersToText(List<SummaryChapter> chapters) {
    final buf = StringBuffer();
    for (final c in chapters) {
      if (c.title.isNotEmpty) buf.writeln(c.title);
      for (final p in c.points) {
        buf.writeln('· ${p.content}');
      }
    }
    return buf.toString().trim();
  }

  static int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
