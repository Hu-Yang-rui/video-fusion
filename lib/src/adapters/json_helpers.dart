/// 各平台适配器共用的 JSON 取值助手。
///
/// # 为什么抽出来
///
/// `bilibili_adapter.dart`（178 KB）与 `douyin_adapter.dart`（113 KB）
/// 里各自维护了一份**完全等价**的私有工具方法：
///
/// ```
/// _toInt          把 num/String 转 int?
/// _nullableString 把任意值转 String?（空串归一为 null）
/// _stringOr       取字符串，缺失时用兜底
/// _epochToIso     秒级时间戳转 ISO 8601
/// ```
///
/// 平台接口的 JSON 里字段类型很不稳定（同一个字段有时是 `123`，
/// 有时是 `"123"`，有时是 `null`），所以每个适配器都需要这套容错
/// 转换。放在这里一份，避免两份实现漂移。
///
/// # 语义约定
///
/// - `null` 输入 → `null`（**不**转成 `0` 或 `""`）
/// - 空字符串 → `null`（平台常用空串表示"没有"）
/// - 无法解析 → `null`（**不**抛异常，调用方自己决定兜底）
library;

/// 把 `num` / `String` 转成 `int?`。
///
/// 平台接口的数值字段可能是：
/// - 数字字面量：`123`
/// - 字符串：`"123"`（大整数防精度丢失时常见）
/// - 空值：`null`
/// - 空串：`""`
int? jsonToInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }
  return null;
}

/// 把任意值转成 `String?`，空串归一为 `null`。
String? jsonToNullableString(Object? value) {
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : value;
  return value.toString();
}

/// 取字符串，缺失或为空时返回 [fallback]。
String jsonToStringOr(Object? value, String fallback) =>
    jsonToNullableString(value) ?? fallback;

/// 秒级 Unix 时间戳 → ISO 8601（UTC）。
///
/// 返回 `null` 的三种情况：
/// - 不是数字
/// - `<= 0`（平台用 0 表示"未设置"）
/// - 超出 `DateTime` 可表示范围
String? jsonEpochToIso(Object? value) {
  if (value is! num || value <= 0) return null;
  final ms = value.toInt() * 1000;
  // DateTime.fromMillisecondsSinceEpoch 在超出范围时会抛，这里守住。
  if (ms < -8640000000000000 || ms > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
      .toIso8601String();
}

/// 毫秒级 Unix 时间戳 → ISO 8601（UTC）。
///
/// 与 [jsonEpochToIso] 分开，因为平台字段有的用秒有的用毫秒，
/// 混用会得到 1970 年或 5 万年后的时间。
String? jsonEpochMsToIso(Object? value) {
  if (value is! num || value <= 0) return null;
  final ms = value.toInt();
  if (ms < -8640000000000000 || ms > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
      .toIso8601String();
}

/// 从 Map 里按多个候选键取第一个非空字符串。
///
/// 平台接口经常给同一语义的字段起不同名字（`uid` / `user_id` /
/// `sec_uid`），或在不同版本里改名。用它一次试完。
String? jsonPickString(Map<String, Object?> map, List<String> keys) {
  for (final k in keys) {
    final v = jsonToNullableString(map[k]);
    if (v != null) return v;
  }
  return null;
}

/// 从 Map 里按多个候选键取第一个非空整数。
int? jsonPickInt(Map<String, Object?> map, List<String> keys) {
  for (final k in keys) {
    final v = jsonToInt(map[k]);
    if (v != null) return v;
  }
  return null;
}
