/// B 站直播弹幕客户端。
///
/// # 协议
///
/// 每个包 = 16 字节头 + 包体：
/// ```
/// offset  size  field
/// 0       4     packet length (含头)
/// 4       2     header length (固定 16)
/// 6       2     protocol version (0 明文 / 2 zlib / 3 brotli)
/// 8       4     operation (2 心跳 / 5 通知 / 7 认证 / 8 认证回复)
/// 12      4     sequence
/// ```
///
/// 认证包（op=7）包体是 JSON：`{uid, roomid, protover, platform, type, key}`。
/// 认证后每 30 秒发一次心跳（op=2），否则会被服务端断开。
///
/// # 依赖
///
/// 只用 `dart:io`，不引入额外包。zlib 用 Dart 内置的 [ZLibDecoder]。
/// **protover 3（brotli）不支持** —— 因此认证时显式请求 protover 2，
/// 服务端会用 zlib 下发；若仍收到 brotli 包则跳过并记录，不崩溃。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/live.dart';
import 'logger.dart';

/// 弹幕连接状态。
enum DanmakuConnectionState {
  idle,
  connecting,
  connected,
  reconnecting,
  closed,
  failed,
}

/// 直播弹幕客户端。
///
/// 用法：
/// ```dart
/// final client = LiveDanmakuClient(logger: log);
/// client.messages.listen((m) => ...);
/// await client.connect(endpoint);
/// ...
/// await client.dispose();
/// ```
class LiveDanmakuClient {
  LiveDanmakuClient({FusionLogger? logger}) : _logger = logger ?? appLogger;

  final FusionLogger _logger;

  final StreamController<LiveMessage> _messages =
      StreamController<LiveMessage>.broadcast();

  /// 弹幕消息流（广播，可多处监听）。
  Stream<LiveMessage> get messages => _messages.stream;

  final StreamController<DanmakuConnectionState> _state =
      StreamController<DanmakuConnectionState>.broadcast();

  Stream<DanmakuConnectionState> get connectionState => _state.stream;

  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  DanmakuConnectionState _current = DanmakuConnectionState.idle;

  LiveDanmakuEndpoint? _endpoint;
  int _attempt = 0;
  bool _disposed = false;

  /// 连续重连上限。超过后停止重试并置为 failed，
  /// 避免在直播间已关播时无限重连消耗流量。
  static const int _maxReconnectAttempts = 5;

  /// 心跳间隔。B 站要求 30 秒内至少一次，否则断开。
  static const Duration _heartbeatInterval = Duration(seconds: 30);

  DanmakuConnectionState get state => _current;

  void _setState(DanmakuConnectionState s) {
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  /// 连接弹幕服务器。
  Future<void> connect(LiveDanmakuEndpoint endpoint) async {
    if (_disposed) return;
    _endpoint = endpoint;
    _attempt = 0;
    await _connectInternal();
  }

  Future<void> _connectInternal() async {
    if (_disposed) return;
    final endpoint = _endpoint;
    if (endpoint == null) return;

    _setState(_attempt == 0
        ? DanmakuConnectionState.connecting
        : DanmakuConnectionState.reconnecting);

    // 依次尝试 host 列表
    WebSocket? socket;
    Object? lastError;
    for (final host in endpoint.hostList) {
      try {
        socket = await WebSocket.connect(host).timeout(
          const Duration(seconds: 10),
        );
        _logger.info('danmaku: connected', {'host': host});
        break;
      } catch (e) {
        lastError = e;
        _logger.warn('danmaku: host failed', {'host': host, 'error': '$e'});
      }
    }

    if (socket == null) {
      _logger.error('danmaku: all hosts failed', {'error': '$lastError'});
      _scheduleReconnect();
      return;
    }

    _socket = socket;
    socket.listen(
      _onData,
      onError: (Object e) {
        _logger.warn('danmaku: socket error', {'error': '$e'});
        _scheduleReconnect();
      },
      onDone: () {
        _logger.info('danmaku: socket closed', {
          'code': socket?.closeCode,
          'reason': socket?.closeReason,
        });
        _scheduleReconnect();
      },
      cancelOnError: true,
    );

    // 认证
    _sendAuth(endpoint);
    _setState(DanmakuConnectionState.connected);
    _attempt = 0;

    // 心跳
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _reconnectTimer?.cancel();

    _attempt++;
    if (_attempt > _maxReconnectAttempts) {
      _logger.warn('danmaku: giving up after $_attempt attempts');
      _setState(DanmakuConnectionState.failed);
      return;
    }

    // 指数退避：2s, 4s, 8s, 16s, 32s
    final delay = Duration(seconds: 1 << _attempt);
    _logger.info('danmaku: reconnect in ${delay.inSeconds}s');
    _setState(DanmakuConnectionState.reconnecting);

    _reconnectTimer = Timer(delay, () {
      if (!_disposed) _connectInternal();
    });
  }

  // ── 包编解码 ────────────────────────────────────────────────

  static const int _opHeartbeat = 2;
  static const int _opNotification = 5;
  static const int _opAuth = 7;
  static const int _opAuthReply = 8;

  /// 构造一个发送包。
  Uint8List _encodePacket(int operation, List<int> body) {
    final header = ByteData(16);
    header.setUint32(0, 16 + body.length, Endian.big); // total length
    header.setUint16(4, 16, Endian.big); // header length
    header.setUint16(6, 1, Endian.big); // protover = 1 (明文)
    header.setUint32(8, operation, Endian.big);
    header.setUint32(12, 1, Endian.big); // sequence
    return Uint8List.fromList([...header.buffer.asUint8List(), ...body]);
  }

  void _sendAuth(LiveDanmakuEndpoint endpoint) {
    // 显式请求 protover 2（zlib），因为本实现不解 brotli
    final body = utf8.encode(
      jsonEncode({
        'uid': endpoint.uid,
        'roomid': endpoint.roomId,
        'protover': 2,
        'platform': 'web',
        'type': 2,
        'key': endpoint.token,
      }),
    );
    _socket?.add(_encodePacket(_opAuth, body));
    _logger.info('danmaku: auth sent', {'room': endpoint.roomId});
  }

  void _sendHeartbeat() {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(_encodePacket(_opHeartbeat, const []));
    } catch (e) {
      _logger.warn('danmaku: heartbeat failed', {'error': '$e'});
    }
  }

  void _onData(dynamic data) {
    if (data is! List<int>) return;
    try {
      _parsePackets(Uint8List.fromList(data));
    } catch (e) {
      _logger.warn('danmaku: parse error', {'error': '$e'});
    }
  }

  /// 一个 TCP 帧里可能有多个包，需要循环切分。
  void _parsePackets(Uint8List bytes) {
    var offset = 0;
    while (offset + 16 <= bytes.length) {
      final header = ByteData.sublistView(bytes, offset, offset + 16);
      final totalLen = header.getUint32(0, Endian.big);
      final headerLen = header.getUint16(4, Endian.big);
      final protoVer = header.getUint16(6, Endian.big);
      final operation = header.getUint32(8, Endian.big);

      if (totalLen < headerLen || offset + totalLen > bytes.length) break;

      final body = Uint8List.sublistView(
        bytes,
        offset + headerLen,
        offset + totalLen,
      );

      switch (operation) {
        case _opNotification:
          if (protoVer == 2) {
            // zlib 压缩，解压后内部还是完整的包序列
            try {
              final inflated = ZLibDecoder().convert(body);
              _parsePackets(Uint8List.fromList(inflated));
            } catch (e) {
              _logger.warn('danmaku: zlib decode failed', {'error': '$e'});
            }
          } else if (protoVer == 3) {
            // brotli：本实现不支持，跳过（不崩溃）
            _logger.debug('danmaku: skip brotli packet');
          } else {
            _handlePayload(body);
          }
        case _opAuthReply:
          _logger.info('danmaku: auth ok');
        case _opHeartbeat:
          // 心跳回复，忽略
          break;
      }

      offset += totalLen;
    }
  }

  void _handlePayload(Uint8List body) {
    if (body.isEmpty) return;
    Map<String, Object?> json;
    try {
      final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
      if (decoded is! Map) return;
      json = Map<String, Object?>.from(decoded);
    } catch (_) {
      return;
    }

    final cmd = (json['cmd'] as String?) ?? '';
    final message = _toMessage(cmd, json);
    if (message != null && !_messages.isClosed) {
      _messages.add(message);
    }
  }

  LiveMessage? _toMessage(String cmd, Map<String, Object?> json) {
    final now = DateTime.now();

    // 弹幕
    if (cmd.startsWith('DANMU_MSG')) {
      // info 是混合数组，文本在 [1]，用户信息在 [2]
      final info = json['info'];
      if (info is! List || info.length < 3) return null;
      final text = '${info[1] ?? ''}';
      if (text.isEmpty) return null;

      final user = info[2];
      String? uname;
      int? uid;
      bool isAdmin = false;
      bool isVip = false;
      if (user is List && user.length > 2) {
        uid = (user[0] as num?)?.toInt();
        uname = user[1]?.toString();
        // user[2] 是房管标记（1 = 房管）
        isAdmin = (user[2] as num?)?.toInt() == 1;
      }
      // info[3] 是粉丝勋章等身份信息
      final medal = info[3];
      if (medal is List && medal.isNotEmpty) isVip = true;

      return LiveMessage(
        type: LiveMessageType.chat,
        text: text,
        receivedAt: now,
        uname: uname,
        uid: uid,
        isAdmin: isAdmin,
        isVip: isVip,
      );
    }

    // 礼物
    if (cmd.startsWith('SEND_GIFT')) {
      final data = json['data'];
      if (data is! Map) return null;
      final d = Map<String, Object?>.from(data);
      final giftName = d['giftName']?.toString() ?? '礼物';
      // 注意：不能把变量命名为 num，会遮蔽 Dart 的 num 类型
      final giftCount = (d['num'] as num?)?.toInt() ?? 1;
      final uname = d['uname']?.toString();
      return LiveMessage(
        type: LiveMessageType.gift,
        text: '\$uname 送出 \$giftName ×\$giftCount',
        receivedAt: now,
        uname: uname,
        giftName: giftName,
        giftCount: giftCount,
      );
    }

    // 进场
    if (cmd.startsWith('INTERACT_WORD')) {
      final data = json['data'];
      if (data is! Map) return null;
      final d = Map<String, Object?>.from(data);
      final uname = d['uname']?.toString();
      if (uname == null || uname.isEmpty) return null;
      return LiveMessage(
        type: LiveMessageType.memberEnter,
        text: '\$uname 进入直播间',
        receivedAt: now,
        uname: uname,
        uid: (d['uid'] as num?)?.toInt(),
      );
    }

    // 系统公告 / 禁言提示
    if (cmd.startsWith('NOTICE_MSG') ||
        cmd.startsWith('ROOM_BLOCK_MSG') ||
        cmd.startsWith('ROOM_SILENT_ON') ||
        cmd.startsWith('ROOM_SILENT_OFF') ||
        cmd.startsWith('WARNING')) {
      final text = json['msg']?.toString() ??
          json['msg_common']?.toString() ??
          json['data']?.toString();
      if (text == null || text.isEmpty) return null;
      return LiveMessage(
        type: LiveMessageType.system,
        text: text,
        receivedAt: now,
      );
    }

    // 关注/分享等互动
    if (cmd.startsWith('ONLINE_RANK') || cmd.startsWith('LIKE_INFO_V3')) {
      return null; // 这类事件量大且信息价值低，不进入消息流
    }

    return null;
  }

  /// 释放连接与定时器。
  Future<void> dispose() async {
    _disposed = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(1000, 'client closed');
      } catch (_) {}
    }

    _setState(DanmakuConnectionState.closed);
    await _messages.close();
    await _state.close();
  }
}
