/// 抖音 mssdk：换取真实 `msToken`。
///
/// # 为什么需要（实测 2026-10-23）
///
/// 抖音 passport 的短信登录（`/passport/web/send_code/`）要求请求带
/// **真实 msToken**（catbus 明确要求 ≥170 字节）。之前我用手写的
/// `'x'×107` 假 msToken，`send_code` 直接返回 `2156`「系统繁忙」——
/// 那不是平台不给路，是我的请求缺了合法凭证。
///
/// msToken 来自 `mssdk.bytedance.com/web/common`：POST 一份设备指纹
/// 上报体，响应头 `x-ms-token` 就是真 msToken。
///
/// # 已验证
///
/// 本模块的构造逻辑先经 `tool/verify_mssdk.dart` 打真实接口验证：
/// 纯 Dart 拿到 172 字节 msToken（HTTP 200，`x-ms-token` 与
/// `set-cookie` 双通道一致）。
///
/// # 与 catbus 的对应
///
/// 对照 `cv-cat/catbus`：
///  - `commonReport`（mssdk.ts）→ [buildCommonReport]
///  - `commonMstoken`（api.ts）→ [fetchMsToken]
///  - `mssdkHeaders`（api.ts）→ [_mssdkHeaders]
///  - 加密原语 → `mssdk_crypto.dart`
///
/// Dart 的 `jsonEncode` 天然等于 catbus 的 `compactJson`
/// （无空格、不转义非 ASCII、保持插入顺序），故无需额外实现。
library;

import 'dart:convert';
import 'dart:io' show HttpHeaders;
import 'dart:math';

import 'mssdk_crypto.dart';
import 'mssdk_profile_data.dart';

/// 主站 origin 与真实浏览器 UA（必须与档案里的字段一致，否则风控识别）。
const String douyinWebOrigin = 'https://www.douyin.com';
const String douyinWebUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36';
const String _secChUa =
    '"Google Chrome";v="155", "Chromium";v="155", "Not(A:Brand";v="24"';

/// mssdk 上报的 aid / pageId。
const int _aid = 6383;
const int _pageId = 6241;

/// 生成 UUID v4。
String _uuid4(Random r) {
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant
  String hex(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${hex(0)}${hex(1)}${hex(2)}${hex(3)}-${hex(4)}${hex(5)}-'
      '${hex(6)}${hex(7)}-${hex(8)}${hex(9)}-${hex(10)}${hex(11)}'
      '${hex(12)}${hex(13)}${hex(14)}${hex(15)}';
}

/// 构造 `/web/common` 的 msgType=1 上报体。
///
/// [profile] 是解码后的档案（会被就地修改，调用方每次传新副本）。
/// 逻辑逐字段对照 catbus `commonReport`（非短信分支）：
///  - `nWID.custom` 重算 uuid + collectTime=randint(10,99)
///  - `nWID.canvas.crc32 = 'A7996F6A'`
///  - `nWID.audio.audioContext.state = 'running'`
///  - `wID`：msgType=1、timestamp、aid、pageId、nap
///  - 整体 compactJson 后 RC4+自定义 base64 → strData
String buildCommonReport(Map<String, dynamic> profile, Random r,
    {int? nowMs}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final n = (profile['nWID'] as Map).cast<String, dynamic>();

  Map<String, dynamic> custom;
  final rawCustom = n['custom'];
  if (rawCustom is String) {
    custom = (jsonDecode(rawCustom) as Map).cast<String, dynamic>();
  } else {
    custom = ((rawCustom as Map?) ?? const {}).cast<String, dynamic>();
  }
  custom['version'] ??= n['ms_version'] ?? '0.0.0.1';
  custom['fxgDid'] ??= '';
  custom['uuid'] = _uuid4(r);
  custom['collectTime'] = 10 + r.nextInt(89); // randint(10,99)

  final msVersion = n['ms_version'] ?? '0.0.0.1';
  n.remove('ms_version');
  n['custom'] = jsonEncode(custom);
  n['ms_version'] = msVersion;

  n['canvas'] ??= <String, dynamic>{};
  (n['canvas'] as Map)['crc32'] = 'A7996F6A';
  n['audio'] ??= <String, dynamic>{};
  (n['audio'] as Map)['audioContext'] ??= <String, dynamic>{};
  ((n['audio'] as Map)['audioContext'] as Map)['state'] = 'running';

  final wid = (profile['wID'] as Map).cast<String, dynamic>();
  wid['msgType'] = 1;
  wid['timestamp'] = '$now';
  wid['aid'] = _aid;
  wid['pageId'] = _pageId;
  wid['nap'] = '11311144242322244122';

  profile['nWID'] = n;
  profile['wID'] = wid;

  final nonce = r.nextInt(256);
  final strData = encodeStrData(jsonEncode(profile), nonce);
  return jsonEncode({
    'magic': 538969122,
    'version': 1,
    'dataType': 8,
    'strData': strData,
    'tspFromClient': now + 10,
    'ulr': 0,
  });
}

/// 解码内嵌档案为可修改副本。
Map<String, dynamic> decodeMssdkProfile() =>
    (jsonDecode(utf8.decode(base64Decode(mssdkProfileB64))) as Map)
        .cast<String, dynamic>();

/// mssdk 上报的请求头（对照 catbus `mssdkHeaders(true)`）。
Map<String, String> mssdkHeaders() => {
      'sec-ch-ua-platform': '"Windows"',
      'referer': '$douyinWebOrigin/',
      'user-agent': douyinWebUa,
      'sec-ch-ua': _secChUa,
      'content-type': 'text/plain;charset=UTF-8',
      'sec-ch-ua-mobile': '?0',
      'accept': '*/*',
      'accept-language': 'zh-CN,zh;q=0.9',
      'cache-control': 'no-cache',
      'origin': douyinWebOrigin,
      'pragma': 'no-cache',
      'priority': 'u=1, i',
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'cross-site',
      'sec-fetch-storage-access': 'active',
    };

/// 从响应头提取 msToken（对照 catbus `msTokenOf`）。
///
/// 优先 `x-ms-token`，回退 `set-cookie` 里的 `msToken=`。
String msTokenFromHeaders(HttpHeaders headers) {
  final xms = headers.value('x-ms-token') ?? '';
  if (xms.isNotEmpty) return xms;
  for (final line in (headers['set-cookie'] ?? const <String>[])) {
    final m = RegExp(r'msToken=([^;]+)').firstMatch(line);
    if (m != null) return Uri.decodeComponent(m.group(1)!);
  }
  return '';
}

/// 与 [msTokenFromHeaders] 等价，但吃的是"已经解析好的头"。
///
/// 纯 HTTP 登录链路（`passport_client.dart`）用的是自己那一层响应封装，
/// 里面只有 `Map<String,String>` 与 `Set-Cookie` 原始行，拿不到
/// `dart:io` 的 [HttpHeaders]。抽出来才可离线单测。
String msTokenFromHeaderValues(String? xMsToken, List<String> setCookies) {
  if (xMsToken != null && xMsToken.isNotEmpty) return xMsToken;
  for (final line in setCookies) {
    final m = RegExp(r'msToken=([^;]+)').firstMatch(line);
    if (m != null) return Uri.decodeComponent(m.group(1)!);
  }
  return '';
}

/// 完整换一次 msToken：解码档案 → 构造上报体。
///
/// 返回 (上报体, 请求头, url)。实际 HTTP 由调用方发（便于注入会话 cookie
/// 与统一日志），拿到响应后用 [msTokenFromHeaders] 提取。
({String body, Map<String, String> headers, String url}) prepareMsTokenRequest({
  String? current,
}) {
  final r = Random.secure();
  final body = buildCommonReport(decodeMssdkProfile(), r);
  var url = 'https://mssdk.bytedance.com/web/common?ms_appid=$_aid';
  if (current != null && current.isNotEmpty) {
    url += '&msToken=${Uri.encodeComponent(current)}';
  }
  return (body: body, headers: mssdkHeaders(), url: url);
}
