/// 抖音签名（`X-Argus` 系）能力检测与提供方接口。
///
/// # 这个文件为什么存在
///
/// 需求要求：**先审计、再决定实现路径**，并且"如果没有可用且获授权的
/// 实现途径，必须明确记录具体阻塞接口和证据"。
///
/// 所以这里不是一个"签名实现"，而是一个**能力检测 + 提供方契约**：
///  - [DouyinSignatureCapability]：当前审计结论（可用 / 不可用 + 原因 + 证据）
///  - [DouyinSignatureProvider]：将来若拿到**平台授权或官方 SDK**，
///    实现这个接口即可接入，UI 与适配器都不用改
///
/// # 审计结论（2026-10-19，抖音 40.7.0 官方 APK 静态分析 + 真实接口实测）
///
/// **不可用，且没有合法可维护的实现路径。** 证据链：
///
///  1. APK 内 `argus` 命中 23 次、26 个 `Argus*` 类，其中
///     `ArgusGeckoLoader` 是**远程资源加载器**，`bytegecko.com` 在 dex 里
///     出现 193 次（占 host 出现频次前 3 位）→ 签名 JS 从 CDN 下发。
///  2. `ArgusWebChromeClient` + `TuringVerifyWebView` → 在 **WebView** 里执行。
///  3. `ArgusMotionEventParams` → 还采集触摸行为做风控。
///  4. `ArgusAesGcmCipher` → 结果加密。
///  5. 真实接口实测：`aweme/v1/aweme/detail`、`multi/aweme/detail`、
///     `comment/list` 匿名请求全部返回**空 body**（不是 4xx，是静默空）。
///
/// 因此：**算法不在 APK 内**，要复刻必须让 App 执行平台远程下发的风控脚本，
/// 属于规避访问控制。本项目不实现，也不用随机头 / 过期签名 / 改名
/// `a_bogus` 冒充。
///
/// # 与 `a_bogus` 的区别（不能混为一谈）
///
/// | | `a_bogus` | `X-Argus` |
/// |---|---|---|
/// | 归属 | Web 端风控 | App 端风控 |
/// | 算法位置 | **本地可算**（纯 Dart 已实现，见 `_abogus.dart`） | 远程下发 JS + WebView |
/// | 本项目状态 | 已实现，用于扫码登录轮询 | **不实现** |
/// | 影响的接口 | 登录链路（`check_qrconnect`） | `/aweme/` 系详情/搜索/话题/互动 |
library;

import '../../core/errors.dart';

/// 签名提供方的种类。
enum DouyinSignatureKind {
  /// 没有可用提供方（当前状态）。
  none,

  /// 平台官方 SDK / 开放平台授权。
  ///
  /// **这是唯一被本项目接受的实现途径**：由平台签发、有文档、可维护。
  /// 当前抖音开放平台未提供视频详情/搜索的通用签名 SDK。
  platformSdk,

  /// 第三方授权服务（需有明确授权与合同依据）。
  authorizedThirdParty,
}

/// 一个受签名保护的接口（审计记录用）。
class SignedEndpointAudit {
  const SignedEndpointAudit({
    required this.endpoint,
    required this.purpose,
    required this.requiresLogin,
    required this.requiresSignature,
    required this.observedResult,
    this.workaround,
  });

  /// 接口路径。
  final String endpoint;

  /// 用途（人话）。
  final String purpose;

  final bool requiresLogin;
  final bool requiresSignature;

  /// 真实实测结果（脱敏）。
  final String observedResult;

  /// 有没有**不依赖签名**的替代路径（有就写清楚）。
  final String? workaround;
}

/// 当前签名能力。
class DouyinSignatureCapability {
  const DouyinSignatureCapability({
    required this.kind,
    required this.available,
    required this.reason,
    this.affectedEndpoints = const [],
    this.verifiedAt,
    this.evidence = const [],
  });

  final DouyinSignatureKind kind;

  /// 是否能生成**被服务端接受**的签名。
  ///
  /// 注意语义：这里指"本项目有合法途径拿到签名"，
  /// 不是"平台有没有这个机制"（平台当然有）。
  final bool available;

  /// 不可用时的原因（面向开发者，可写进诊断）。
  final String reason;

  /// 受影响的接口清单（审计证据）。
  final List<SignedEndpointAudit> affectedEndpoints;

  /// 审计时间（ISO 8601）。
  final String? verifiedAt;

  /// 证据要点（每条一句话，可追溯）。
  final List<String> evidence;

  /// 当前审计结论。
  ///
  /// **不可用**：没有平台授权 SDK，也没有可维护的本地实现。
  static DouyinSignatureCapability audited() => DouyinSignatureCapability(
        kind: DouyinSignatureKind.none,
        available: false,
        reason: '抖音 App 端 X-Argus 签名由远程下发 JS 在 WebView 内生成，'
            '算法不在 APK 内；平台未提供可用于该场景的授权 SDK，'
            '因此本项目不实现。受影响的接口如实降级为"不可用"。',
        verifiedAt: '2026-10-19',
        evidence: const [
          'APK 40.7.0 dex：argus 命中 23 次，26 个 Argus* 类',
          'bytegecko.com 在 dex 中命中 193 次（远程 JS/资源 CDN）',
          'ArgusGeckoLoader = 远程资源加载器；ArgusWebChromeClient + TuringVerifyWebView = WebView 执行',
          'ArgusMotionEventParams = 采集触摸行为做风控；ArgusAesGcmCipher = 结果加密',
          '实测 aweme/v1/aweme/detail 匿名 → HTTP 200 + 空 body（非 4xx，静默拒绝）',
          '实测 aweme/v1/multi/aweme/detail、aweme/v1/comment/list 同样空 body',
        ],
        affectedEndpoints: const [
          SignedEndpointAudit(
            endpoint: '/aweme/v1/aweme/detail/',
            purpose: '按 aweme_id 查视频详情',
            requiresLogin: false,
            requiresSignature: true,
            observedResult: 'HTTP 200，body 长度 0',
            workaround: '推荐流（aweme/v2/feed）里已带的条目可复用；'
                '按 id 单独补查不可用',
          ),
          SignedEndpointAudit(
            endpoint: '/aweme/v1/multi/aweme/detail/',
            purpose: '批量查详情',
            requiresLogin: false,
            requiresSignature: true,
            observedResult: 'HTTP 200，body 长度 0',
          ),
          SignedEndpointAudit(
            endpoint: '/aweme/v1/general/search/single/',
            purpose: '搜索视频',
            requiresLogin: true,
            requiresSignature: true,
            observedResult: 'status_code=2483「请先登录，再继续搜索吧」',
            workaround: '无。UI 已如实标注"该平台不支持搜索"',
          ),
          SignedEndpointAudit(
            endpoint: '/aweme/v1/challenge/detail/',
            purpose: '话题详情',
            requiresLogin: false,
            requiresSignature: true,
            observedResult: 'HTTP 200，body 长度 0',
          ),
          SignedEndpointAudit(
            endpoint: '/aweme/v1/commit/item/digg/',
            purpose: '点赞',
            requiresLogin: true,
            requiresSignature: true,
            observedResult: '需登录（未登录直接拒绝）',
            workaround: '无。UI 不渲染抖音点赞按钮',
          ),
          SignedEndpointAudit(
            endpoint: '/aweme/v1/aweme/favorite/',
            purpose: '收藏',
            requiresLogin: true,
            requiresSignature: true,
            observedResult: '需登录',
          ),
        ],
      );

  /// 面向用户的降级说明（UI 直接显示）。
  ///
  /// 刻意不写技术细节：用户不需要知道 Gecko/WebView，
  /// 只需要知道"这个平台的这个功能在本应用里用不了，以及为什么"。
  String get userFacingNotice => available
      ? '该能力可用。'
      : '抖音的视频详情、搜索、话题与点赞收藏接口受平台风控签名保护，'
          '本应用不实现该签名，因此这些功能不可用。'
          '推荐流、直播与评论读取不受影响。';

  Map<String, Object?> toDiagnostics() => {
        'kind': kind.name,
        'available': available,
        'reason': reason,
        'verifiedAt': verifiedAt,
        'affectedEndpoints':
            affectedEndpoints.map((e) => e.endpoint).toList(growable: false),
        'evidence': evidence,
      };
}

/// 一次签名请求的上下文。
///
/// 若将来接入授权提供方，用它描述"签什么"。
class DouyinSignatureContext {
  const DouyinSignatureContext({
    required this.method,
    required this.path,
    required this.query,
    required this.timestampMs,
    this.body,
  });

  final String method;

  /// 接口路径（不含 host）。
  final String path;

  /// 已排序的 query 串。
  final String query;

  /// 请求体（GET 为 null）。
  final String? body;

  /// 毫秒时间戳（签名通常与时间绑定，必须由调用方给，便于测试）。
  final int timestampMs;
}

/// 一次签名结果。
class DouyinSignatureResult {
  const DouyinSignatureResult({
    required this.headers,
    required this.expiresAtMs,
  });

  /// 需要附加到请求上的头（如 `X-Argus` / `X-Gorgon` / `X-Khronos`）。
  ///
  /// **不得写入日志**：这些值有时效性且可用于重放。
  final Map<String, String> headers;

  /// 过期时间（毫秒时间戳）。调用方应在过期前重新签。
  final int expiresAtMs;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;
}

/// 签名提供方接口。
///
/// # 只有拿到平台授权才实现
///
/// 默认实现抛 [FusionErrorCode.unsupportedPlatform]，这样任何调用方
/// 都能立刻拿到明确错误，而不是"返回空签名让请求静默失败"。
///
/// # 契约
///
///  - [sign] 必须**快速失败**：不允许在请求路径上做长耗时初始化。
///  - [sign] 抛错时调用方应走降级（把该能力标记为不可用），
///    不得重试到打爆接口。
///  - 实现方**不得**把密钥、设备指纹或授权凭据写进日志或异常信息。
abstract class DouyinSignatureProvider {
  /// 该提供方是否可用（例如 SDK 是否初始化成功）。
  bool get isAvailable;

  /// 生成签名。
  ///
  /// [timeout] 是硬上限：超时必须抛错，不能挂住请求。
  Future<DouyinSignatureResult> sign(
    DouyinSignatureContext context, {
    Duration timeout = const Duration(seconds: 3),
  });

  /// 默认实现：明确声明不可用。
  static DouyinSignatureProvider get unavailable => _UnavailableProvider();
}

class _UnavailableProvider implements DouyinSignatureProvider {
  @override
  bool get isAvailable => false;

  @override
  Future<DouyinSignatureResult> sign(
    DouyinSignatureContext context, {
    Duration timeout = const Duration(seconds: 3),
  }) async =>
      throw FusionException(
        code: FusionErrorCode.unsupportedPlatform,
        userMessage: '该平台的部分接口需要平台签名，本应用不提供。',
        technicalMessage: 'DouyinSignatureProvider unavailable: '
            'no authorized X-Argus provider configured '
            '(path=${context.path})',
        retryable: false,
      );
}
