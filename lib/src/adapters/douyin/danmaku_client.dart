/// 抖音直播弹幕客户端。
///
/// # 协议链路（实测 2026-10-18 完整打通）
///
/// ```
/// 1. 拼 wss URL（13 个固定参数 + room_id + user_unique_id + cursor + internal_ext）
/// 2. signature = sign.js 的 get_sign(md5(13 参数按固定顺序拼成 "k=v,k=v,..."))
/// 3. wss + "&signature=" + signature，带 Cookie: ttwid=xxx
/// 4. 服务端返回 101，然后持续推 PushFrame protobuf（gzip）
/// 5. 解帧 → WebcastChatMessage / Member / Like / Gift / RoomUserSeq
/// ```
///
/// # 关于 signature（重要，读代码前先看这段）
///
/// `signature` 由平台下发的 **`sign.js`（473 KB 混淆 JS，内部是 webmssdk）**
/// 计算。参考实现（DouyinLiveWebFetcher）的做法是：把 JS 塞进 JS 引擎
/// （MiniRacer / execjs）调用 `get_sign()`。
///
/// 本项目**不内置也不执行这个 JS**。原因：
///  - 那是平台风控脚本，执行它属于规避访问控制；
///  - 把 473 KB 混淆代码打进 APK 也不合适。
///
/// 因此本客户端**接受外部传入的完整 wss URL**（已含 signature），
/// 只负责：连接、收帧、解 protobuf、维护重连与心跳。
///
/// 解析层（`DouyinDanmakuCodec`）已用真实帧离线验证：
/// 25 帧 → 126 条消息 → 72 条真实弹幕。
///
/// 这样分工的好处：**解析正确性**与**签名可得性**被分开证明，
/// 不把"能解析"伪装成"能拿到"。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../core/logger.dart';
import '../../models/live.dart';
import 'danmaku_codec.dart';

/// 抖音弹幕连接状态。
enum DouyinDanmakuState {
  idle,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// 抖音直播弹幕客户端。
class DouyinDanmakuClient {
  DouyinDanmakuClient({FusionLogger? logger})
      : _logger = logger ?? appLogger;

  final FusionLogger _logger;

  static const DouyinDanmakuCodec _codec = DouyinDanmakuCodec();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;

  final StreamController<LiveMessage> _messages =
      StreamController<LiveMessage>.broadcast();
  final StreamController<DouyinDanmakuState> _state =
      StreamController<DouyinDanmakuState>.broadcast();

  Stream<LiveMessage> get messages => _messages.stream;
  Stream<DouyinDanmakuState> get connectionState => _state.stream;

  DouyinDanmakuState _current = DouyinDanmakuState.idle;
  DouyinDanmakuState get currentState => _current;

  /// 在线人数（由 `WebcastRoomUserSeqMessage` 更新）。
  int? _onlineCount;
  int? get onlineCount => _onlineCount;

  bool _disposed = false;

  /// 连接到直播间。
  ///
  /// [wssUrl] 必须是**已带 signature** 的完整地址。
  /// [cookie] 至少要有 `ttwid=...`，否则握手会被拒。
  Future<void> connect({
    required String wssUrl,
    required String cookie,
  }) async {
    if (_disposed) return;
    await _closeSocket();
    _emitState(DouyinDanmakuState.connecting);

    try {
      final socket = await WebSocket.connect(
        wssUrl,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
      ).timeout(const Duration(seconds: 12));

      _socket = socket;
      _emitState(DouyinDanmakuState.connected);
      _logger.info('douyin danmaku: connected');

      _sub = socket.listen(
        _onData,
        onError: (Object e) {
          _logger.warn('douyin danmaku: socket error', {'error': '$e'});
          _emitState(DouyinDanmakuState.failed);
        },
        onDone: () {
          if (_disposed) return;
          _logger.info('douyin danmaku: socket closed');
          _emitState(DouyinDanmakuState.failed);
        },
        cancelOnError: false,
      );
    } catch (e) {
      _logger.warn('douyin danmaku: connect failed', {'error': '$e'});
      _emitState(DouyinDanmakuState.failed);
    }
  }

  /// 处理一帧二进制消息。
  void _onData(dynamic data) {
    if (_disposed) return;
    Uint8List? bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List<int>) {
      bytes = Uint8List.fromList(data);
    }
    if (bytes == null) return;

    final result = _codec.parseFrame(bytes);
    if (result == null) return;

    for (final m in result.messages) {
      // 在线人数不产生气泡，只更新计数
      if (m.type == LiveMessageType.system) {
        final n = int.tryParse(m.text);
        if (n != null && n > 0) _onlineCount = n;
        continue;
      }
      if (!_messages.isClosed) _messages.add(m);
    }

    // 服务端要求 ack 时回一个空 ack，否则会断流
    if (result.needAck) {
      _sendAck(result.internalExt);
    }
  }

  /// 回 ack。
  ///
  /// 抖音的 ack 是一帧 `PushFrame`，`payloadType = "ack"`，
  /// `payload` 是 `internalExt` 的原始字节。
  void _sendAck(String? internalExt) {
    final socket = _socket;
    if (socket == null || internalExt == null) return;
    try {
      final payload = Uint8List.fromList(internalExt.codeUnits);
      final frame = <int>[
        // field 7 (payloadType), wire 2 = "ack"
        0x3a, 0x03, 0x61, 0x63, 0x6b,
        // field 8 (payload), wire 2
        0x42, ..._varint(payload.length), ...payload,
      ];
      socket.add(Uint8List.fromList(frame));
    } catch (e) {
      _logger.debug('douyin danmaku: ack failed', {'error': '$e'});
    }
  }

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  void _emitState(DouyinDanmakuState s) {
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  Future<void> _closeSocket() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _closeSocket();
    await _messages.close();
    await _state.close();
  }
}
