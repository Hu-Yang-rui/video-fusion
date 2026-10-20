/// B站视频内弹幕（`/x/v2/dm/web/seg.so`）的 protobuf 解析。
///
/// # 为什么手写解析而不是引入 protobuf 包
///
/// 只需要解**一个**消息类型（`DmSegMobileReply`），字段数固定，
/// 且都是 varint / length-delimited 两种 wire type。引入 `protobuf` +
/// `protoc` 生成代码会带来：
///
///  - 一个新依赖（`protobuf` 包）与代码生成步骤
///  - 生成出来的 `.pb.dart` 几万行，与本项目的"一个能力一个文件"风格不符
///  - 协议升级时反而更难改（要重新生成）
///
/// 手写解析器约 200 行，覆盖全部需要的字段，且**未知字段直接跳过**
/// （protobuf 的前向兼容规则），因此平台加字段不会解析失败。
///
/// # 实测依据（本轮，真实视频 BV1GJ411x7h7 / cid=137649199）
///
/// ```
/// GET https://api.bilibili.com/x/v2/dm/web/seg.so
///     ?type=1&oid={cid}&pid={aid}&segment_index=1
/// → HTTP 200，163,551 字节（未登录）
/// ```
///
/// 同一 cid 的旧版 XML 接口（`/x/v1/dm/list.so?oid={cid}`）也返回 200，
/// 108,364 字节。两者内容一致，本实现**只用 protobuf**：
///
///  - XML 需要解析 10 万字符的文本，且 `<d p="...">` 里的字段位置是
///    位置耦合的（第 1 个是时间、第 2 个是模式……），改一个就错位
///  - protobuf 是字段号耦合，加字段不影响已有字段
///
/// # 分段语义
///
/// 弹幕按**视频时长**切段，每段 6 分钟（360 秒）。`segment_index` 从 1
/// 开始。段数 = `ceil(时长秒 / 360)`。实测该参数是必需的，缺了返回空。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 一条弹幕。
class VideoDanmaku {
  const VideoDanmaku({
    required this.id,
    required this.progressMs,
    required this.mode,
    required this.fontSize,
    required this.color,
    required this.sentAtSeconds,
    required this.pool,
    required this.senderHash,
    required this.rowId,
    required this.text,
  });

  /// 弹幕 ID（`dmid`，19 位数字串）。
  final String id;

  /// 出现在视频的第几毫秒。
  final int progressMs;

  /// 弹幕模式：
  ///  - 1/2/3 = 滚动（右→左）
  ///  - 4 = 底部固定
  ///  - 5 = 顶部固定
  ///  - 6 = 逆向滚动（左→右）
  ///  - 7 = 高级弹幕
  ///  - 8 = 代码弹幕
  ///  - 9 = BAS 弹幕
  final int mode;

  /// 字号（默认 25）。
  final int fontSize;

  /// 颜色（RGB 整数，例如 16777215 = 白色）。
  final int color;

  /// 发送时间（Unix 秒）。
  final int sentAtSeconds;

  /// 弹幕池：0 = 普通，1 = 字幕，2 = 特殊。
  final int pool;

  /// 发送者 ID 的哈希（平台只给哈希，不给 uid）。
  final String senderHash;

  /// 平台内部的弹幕行 ID。
  final String rowId;

  /// 弹幕正文。
  final String text;

  /// 出现时间（秒，浮点），便于直接与播放进度比较。
  double get progressSeconds => progressMs / 1000.0;

  /// 是否是滚动弹幕。
  bool get isScrolling => mode == 1 || mode == 2 || mode == 3;

  /// 是否是顶部/底部固定弹幕。
  bool get isFixed => mode == 4 || mode == 5;

  Map<String, Object?> toJson() => {
        'id': id,
        'progressMs': progressMs,
        'mode': mode,
        'fontSize': fontSize,
        'color': color,
        'sentAt': sentAtSeconds,
        'pool': pool,
        'text': text,
      };
}

/// 一页弹幕（对应一个分段）。
class DanmakuSegment {
  const DanmakuSegment({
    required this.segmentIndex,
    required this.items,
    this.totalSegments,
  });

  /// 段序号（从 1 开始）。
  final int segmentIndex;

  final List<VideoDanmaku> items;

  /// 总段数（调用方给出时才有）。
  final int? totalSegments;

  bool get isEmpty => items.isEmpty;
}

/// `DmSegMobileReply` 的字段号（实测自真实响应）。
///
/// 只列**会解析**的字段。其余字段（`state=2`、`ai_flag=3`）由 [skip]
/// 直接跳过——它们对展示无用，解析它们只会多出没处放的变量。
abstract final class _DmSegField {
  /// `repeated DanmakuElem elems = 1`。
  static const int elems = 1;
}

/// `DanmakuElem` 的字段号（实测自真实响应）。
///
/// 只列**会解析**的字段。`weight=9`（权重，平台用于折叠）、
/// `attr=13`（属性位，标识是否被举报折叠）对展示无用，直接跳过。
abstract final class _ElemField {
  static const int id = 1; // int64 dmid
  static const int progress = 2; // int32 毫秒
  static const int mode = 3; // int32
  static const int fontSize = 4; // int32
  static const int color = 5; // uint32 RGB
  static const int midHash = 6; // string 发送者哈希
  static const int content = 7; // string 正文
  static const int ctime = 8; // int64 发送时间
  static const int pool = 11; // int32
  static const int idStr = 12; // string dmid 字符串形式
}

/// protobuf wire type。
abstract final class _Wire {
  static const int varint = 0;
  static const int fixed64 = 1;
  static const int lengthDelimited = 2;
  static const int fixed32 = 5;
}

/// 解析 `/x/v2/dm/web/seg.so` 的响应体。
///
/// 返回该段的全部弹幕。**未知字段被跳过**，因此平台加字段不会导致失败。
///
/// [segmentIndex] 只用于回填到结果里，不参与解析。
///
/// 解析失败（数据被截断、不是 protobuf）时抛 [FormatException]，
/// 由调用方映射为 `parseError`——**不返回空列表**，那会把"数据坏了"
/// 伪装成"这个视频没有弹幕"。
DanmakuSegment parseDanmakuSegment(
  Uint8List bytes, {
  required int segmentIndex,
  int? totalSegments,
}) {
  final items = <VideoDanmaku>[];
  final reader = _Reader(bytes);

  while (!reader.isAtEnd) {
    final tag = reader.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;

    if (field == _DmSegField.elems && wire == _Wire.lengthDelimited) {
      final len = reader.readVarint();
      final sub = reader.readBytes(len);
      final item = _parseElem(sub);
      if (item != null) items.add(item);
    } else {
      reader.skip(wire);
    }
  }

  return DanmakuSegment(
    segmentIndex: segmentIndex,
    items: items,
    totalSegments: totalSegments,
  );
}

/// 解析单个 `DanmakuElem`。字段全缺时返回 null（丢弃畸形条目）。
VideoDanmaku? _parseElem(Uint8List bytes) {
  var id = '';
  var idStr = '';
  var progress = 0;
  var mode = 0;
  var fontSize = 0;
  var color = 0;
  var midHash = '';
  var content = '';
  var ctime = 0;
  var pool = 0;

  final reader = _Reader(bytes);
  while (!reader.isAtEnd) {
    final tag = reader.readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;

    switch (field) {
      case _ElemField.id:
        if (wire == _Wire.varint) id = '${reader.readVarint()}';
      case _ElemField.progress:
        if (wire == _Wire.varint) progress = reader.readVarint();
      case _ElemField.mode:
        if (wire == _Wire.varint) mode = reader.readVarint();
      case _ElemField.fontSize:
        if (wire == _Wire.varint) fontSize = reader.readVarint();
      case _ElemField.color:
        if (wire == _Wire.varint) color = reader.readVarint();
      case _ElemField.midHash:
        if (wire == _Wire.lengthDelimited) {
          midHash = reader.readString(reader.readVarint());
        }
      case _ElemField.content:
        if (wire == _Wire.lengthDelimited) {
          content = reader.readString(reader.readVarint());
        }
      case _ElemField.ctime:
        if (wire == _Wire.varint) ctime = reader.readVarint();
      case _ElemField.pool:
        if (wire == _Wire.varint) pool = reader.readVarint();
      case _ElemField.idStr:
        if (wire == _Wire.lengthDelimited) {
          idStr = reader.readString(reader.readVarint());
        }
      default:
        reader.skip(wire);
    }
  }

  // 正文为空说明不是有效弹幕（实测空正文条目确实存在，多为被删除的）。
  if (content.isEmpty) return null;

  return VideoDanmaku(
    id: idStr.isNotEmpty ? idStr : id,
    progressMs: progress,
    mode: mode,
    fontSize: fontSize,
    color: color,
    sentAtSeconds: ctime,
    pool: pool,
    senderHash: midHash,
    rowId: id,
    text: content,
  );
}

/// 极简 protobuf 读取器。
class _Reader {
  _Reader(this._bytes) : _pos = 0;

  final Uint8List _bytes;
  int _pos;

  bool get isAtEnd => _pos >= _bytes.length;

  /// 读一个 varint（最多 10 字节，64 位）。
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _bytes.length) {
        throw const FormatException('protobuf: truncated varint');
      }
      final b = _bytes[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) {
        throw const FormatException('protobuf: varint too long');
      }
    }
    return result;
  }

  Uint8List readBytes(int len) {
    if (len < 0 || _pos + len > _bytes.length) {
      throw const FormatException('protobuf: truncated bytes');
    }
    final out = Uint8List.sublistView(_bytes, _pos, _pos + len);
    _pos += len;
    return out;
  }

  String readString(int len) {
    final bytes = readBytes(len);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // 弹幕里偶有非 UTF-8 字节（老客户端发的老弹幕），
      // 用 latin1 兜底而不是整段失败。
      return latin1.decode(bytes);
    }
  }

  /// 跳过一个字段的值。
  void skip(int wire) {
    switch (wire) {
      case _Wire.varint:
        readVarint();
      case _Wire.fixed64:
        _pos += 8;
      case _Wire.lengthDelimited:
        final len = readVarint();
        _pos += len;
      case _Wire.fixed32:
        _pos += 4;
      default:
        throw FormatException('protobuf: unknown wire type $wire');
    }
    if (_pos > _bytes.length) {
      throw const FormatException('protobuf: skip past end');
    }
  }
}

/// 按视频时长算需要拉几段弹幕。
///
/// 平台按 6 分钟一段切分，`segment_index` 从 1 开始。
/// 时长未知（null 或 <= 0）时按 1 段处理。
int danmakuSegmentCount(double? durationSeconds) {
  if (durationSeconds == null || durationSeconds <= 0) return 1;
  return (durationSeconds / 360).ceil().clamp(1, 1000);
}
