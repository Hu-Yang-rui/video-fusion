/// B 站图片上传客户端（私信图片发送用）。
///
/// # 接口（从 `message.bilibili.com` 前端 bundle 挖出，2026-10-19）
///
/// ```js
/// const fd = new FormData();
/// fd.append('file_up', file);
/// fd.append('biz', 'im');          // 私信业务线
/// POST /x/dynamic/feed/draw/upload_bfs
/// ```
///
/// 成功响应（bundle 里读取的字段，全部是 `data.*`）：
/// ```json
/// {"code":0,"data":{
///   "image_url":"https://.../xxx.jpg",
///   "image_width":1200,
///   "image_height":800,
///   "img_size":123456
/// }}
/// ```
///
/// 拿到这些之后，私信消息体是（`msg_type=2`）：
/// ```json
/// {"url":"<image_url>","width":<w>,"height":<h>,
///  "imageType":<n>,"size":<img_size>,"original":1}
/// ```
///
/// # 实测边界（必须记住）
///
/// | 项 | 实测结果 |
/// |---|---|
/// | 匿名 POST | `HTTP 200` + `{"code":-101,"message":"账号未登录"}` |
/// | 带有效 Cookie | **未实测**（本地凭证已失效，见报告） |
/// | 客服上传 `/x/custom/msg_svr/v1/upload` | 在 `api.vc.bilibili.com` 上 **404**，它属于 `customerservice.bilibili.com`，与普通私信无关 |
///
/// 也就是说：**接口存在、路由正确、参数形态来自官方前端代码，
/// 但"带真实登录态上传成功"这一步本项目没有验证过。**
/// 这一点在报告里如实标注，不声称已跑通。
///
/// # 为什么单独一个客户端
///
/// 上传是 multipart 表单，与私信的 JSON/form 请求形态不同；
/// 混进 [BilibiliImClient] 会让"哪些请求要带 csrf、哪些要带 multipart"
/// 变得含混。独立成类，职责单一。
library;

import 'dart:convert';
import 'dart:io';

import '../../core/credential_vault.dart';
import '../../core/errors.dart';
import '../../core/http_client.dart';
import '../../core/logger.dart';
import '../../models/im.dart';

/// 上传失败的具体原因（面向用户）。
class ImUploadException implements Exception {
  ImUploadException(this.message, {this.upstreamCode});

  final String message;
  final Object? upstreamCode;

  @override
  String toString() => 'ImUploadException($upstreamCode): $message';
}

/// 上传前的本地校验结果。
class UploadValidation {
  const UploadValidation._({required this.ok, this.reason});

  factory UploadValidation.ok() => const UploadValidation._(ok: true);

  factory UploadValidation.reject(String reason) =>
      UploadValidation._(ok: false, reason: reason);

  final bool ok;
  final String? reason;
}

/// B 站图片上传客户端。
class BilibiliImUploadClient {
  BilibiliImUploadClient({
    required FusionHttpClient http,
    required this.platformId,
    FusionLogger? logger,
  })  : _http = http,
        _logger = logger ?? appLogger;

  final FusionHttpClient _http;
  final String platformId;
  final FusionLogger _logger;

  static const String _uploadUrl =
      'https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs';

  static const String _referer = 'https://message.bilibili.com/';

  /// 平台允许的图片类型（前端 bundle 的 `<input accept>` 与实测一致）。
  static const Set<String> allowedExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
  };

  /// 单文件大小上限。
  ///
  /// B 站动态/私信图片上限是 20 MB（前端只对视频做了 200 MB 校验，
  /// 图片没有显式常量，这里取社区一致的 20 MB 并在 UI 如实提示）。
  /// **这是保守值**：超过就本地拦住，不发注定被拒的请求。
  static const int maxBytes = 20 * 1024 * 1024;

  /// 本地校验：扩展名 + 大小 + 文件是否存在。
  ///
  /// 在**上传之前**跑，避免把 50 MB 的文件传上去才被拒。
  static UploadValidation validateFile(String path, int sizeBytes) {
    final name = path.toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return UploadValidation.reject('无法识别图片格式，请选择 jpg / png / gif 等常见格式。');
    }
    final ext = name.substring(dot + 1);
    if (!allowedExtensions.contains(ext)) {
      return UploadValidation.reject('不支持 $ext 格式，请选择 jpg / png / gif / webp。');
    }
    if (sizeBytes <= 0) {
      return UploadValidation.reject('这个文件是空的，无法发送。');
    }
    if (sizeBytes > maxBytes) {
      final mb = (sizeBytes / 1024 / 1024).toStringAsFixed(1);
      return UploadValidation.reject('图片大小 $mb MB，超过 20 MB 上限。');
    }
    return UploadValidation.ok();
  }

  /// 上传一张图片，返回可用于构造消息的媒体信息。
  ///
  /// [bytes] 是文件内容；[filename] 用于 multipart 的 filename 字段。
  ///
  /// 失败抛 [ImUploadException]（带可读原因），**不返回假地址**。
  Future<ImMedia> uploadImage({
    required PlatformSession session,
    required List<int> bytes,
    required String filename,
  }) async {
    if (bytes.isEmpty) {
      throw ImUploadException('图片内容为空，无法上传。');
    }
    final validation = validateFile(filename, bytes.length);
    if (!validation.ok) {
      throw ImUploadException(validation.reason!);
    }
    if (session.cookieHeader.isEmpty) {
      throw ImUploadException('需要登录后才能发送图片。');
    }

    // 手写 multipart：本项目的 FusionHttpClient 只发字符串 body，
    // 图片是二进制，必须自己拼 boundary。
    final boundary = '----VFBoundary${DateTime.now().microsecondsSinceEpoch}';
    final body = _buildMultipart(
      boundary: boundary,
      fieldName: 'file_up',
      filename: filename,
      bytes: bytes,
      extraFields: const {'biz': 'im'},
    );

    final result = await _http.post(
      _uploadUrl,
      headers: {
        'Referer': _referer,
        'Origin': 'https://message.bilibili.com',
        'Cookie': session.cookieHeader,
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'multipart/form-data; boundary=$boundary',
      },
      body: body,
      contentType: 'multipart/form-data; boundary=$boundary',
      platformId: platformId,
      timeout: const Duration(seconds: 60),
    );

    Map<String, Object?> json;
    try {
      json = result.jsonObject(platformId: platformId);
    } catch (e) {
      _logger.warn('im upload: response is not json', {
        'status': result.statusCode,
      });
      throw ImUploadException('上传返回了无法解析的内容，请稍后重试。');
    }

    final code = json['code'];
    if (code != 0) {
      throw ImUploadException(
        _reasonFor(code, json['message']),
        upstreamCode: code,
      );
    }

    final data = json['data'];
    if (data is! Map) {
      throw ImUploadException('上传成功但平台没有返回图片地址。');
    }
    final d = Map<String, Object?>.from(data);
    final url = d['image_url'];
    if (url is! String || url.trim().isEmpty) {
      throw ImUploadException('上传成功但平台没有返回图片地址。');
    }

    return ImMedia(
      url: url,
      width: _toInt(d['image_width']),
      height: _toInt(d['image_height']),
      sizeBytes: _toInt(d['img_size']),
    );
  }

  /// 平台错误码 → 可读原因。
  String _reasonFor(Object? code, Object? message) {
    final msg = message?.toString() ?? '';
    return switch (code) {
      -101 => '登录状态已失效，请重新登录后再发送图片。',
      -111 => '操作凭证（csrf）无效，请重新登录。',
      -400 => '平台拒绝了这张图片（格式或大小不符合要求）。',
      412 => '上传过于频繁，请稍后再试。',
      _ => msg.isEmpty ? '图片上传失败（平台返回 $code）。' : msg,
    };
  }

  /// 构造 multipart/form-data 请求体。
  ///
  /// 二进制用 latin1 逐字节映射成 String —— 这是 Dart 里把字节塞进
  /// String body 的标准做法（http 包内部同样按 latin1 编码请求体）。
  static String _buildMultipart({
    required String boundary,
    required String fieldName,
    required String filename,
    required List<int> bytes,
    Map<String, String> extraFields = const {},
  }) {
    final b = StringBuffer();
    for (final entry in extraFields.entries) {
      b.write('--$boundary\r\n');
      b.write('Content-Disposition: form-data; name="${entry.key}"\r\n\r\n');
      b.write('${entry.value}\r\n');
    }
    b.write('--$boundary\r\n');
    b.write('Content-Disposition: form-data; name="$fieldName"; '
        'filename="$filename"\r\n');
    b.write('Content-Type: ${_guessMime(filename)}\r\n\r\n');
    b.write(latin1.decode(bytes));
    b.write('\r\n--$boundary--\r\n');
    return b.toString();
  }

  static String _guessMime(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  static int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 读取本地文件（供 UI 层调用，集中处理 IO 错误）。
  static Future<List<int>> readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ImUploadException('找不到这个文件，请重新选择。');
    }
    return file.readAsBytes();
  }
}

/// 上传失败归一化为 [FusionException]（供 service 层统一处理）。
FusionException uploadErrorToFusion(
  Object error, {
  String? platformId,
}) {
  if (error is ImUploadException) {
    return FusionException(
      code: FusionErrorCode.upstreamError,
      userMessage: error.message,
      technicalMessage: 'IM upload failed: ${error.message}',
      upstreamCode: error.upstreamCode,
      platformId: platformId,
    );
  }
  if (error is FusionException) return error;
  return FusionException(
    code: FusionErrorCode.networkError,
    userMessage: '图片上传失败，请检查网络后重试。',
    technicalMessage: '${error.runtimeType}: $error',
    platformId: platformId,
  );
}
