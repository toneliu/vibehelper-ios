import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/messages.dart';

enum ConnectionPhase {
  disconnected,
  connecting,
  authenticating,
  connected,
  reconnecting,
  error,
}

class SocketSnapshot {
  const SocketSnapshot({
    this.phase = ConnectionPhase.disconnected,
    this.hostInfo,
    this.rttMs,
    this.lastError,
  });

  final ConnectionPhase phase;
  final HostInfo? hostInfo;
  final int? rttMs;
  final String? lastError;

  bool get isConnected => phase == ConnectionPhase.connected;

  SocketSnapshot copyWith({
    ConnectionPhase? phase,
    HostInfo? hostInfo,
    bool clearHostInfo = false,
    int? rttMs,
    bool clearRtt = false,
    String? lastError,
    bool clearError = false,
  }) {
    return SocketSnapshot(
      phase: phase ?? this.phase,
      hostInfo: clearHostInfo ? null : (hostInfo ?? this.hostInfo),
      rttMs: clearRtt ? null : (rttMs ?? this.rttMs),
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

class VibeSocketClient {
  VibeSocketClient({WebSocketChannel Function(Uri uri)? channelFactory})
      : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  static const _uuid = Uuid();

  final WebSocketChannel Function(Uri uri) _channelFactory;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  String? _wsUrl;
  String _token = '';
  String _clientName = 'VibeHelper';
  bool _manualDisconnect = false;
  int _reconnectAttempt = 0;
  int _connectEpoch = 0;
  bool _disposed = false;
  DateTime _lastFrameReceivedAt = DateTime.now();
  bool _verifyingAlive = false;

  final Map<String, Completer<ProtocolMessage>> _pending = {};
  final StreamController<SocketSnapshot> _stateController =
      StreamController<SocketSnapshot>.broadcast();
  final StreamController<ProtocolMessage> _messageController =
      StreamController<ProtocolMessage>.broadcast();
  final StreamController<Uint8List> _binaryController =
      StreamController<Uint8List>.broadcast();

  SocketSnapshot _snapshot = const SocketSnapshot();

  SocketSnapshot get snapshot => _snapshot;
  bool get isManualDisconnect => _manualDisconnect;
  int get connectEpoch => _connectEpoch;
  String? get currentWsUrl => _wsUrl;
  Stream<SocketSnapshot> get stateStream => _stateController.stream;
  Stream<ProtocolMessage> get messages => _messageController.stream;
  Stream<Uint8List> get binaryMessages => _binaryController.stream;

  void _emitState(SocketSnapshot next) {
    _snapshot = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  String _detectPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  Future<void> connect({
    required String wsUrl,
    required String token,
    required String clientName,
    Duration connectTimeout = const Duration(seconds: 6),
  }) async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _manualDisconnect = false;
    _wsUrl = wsUrl.trim();
    _token = token;
    _clientName = clientName;
    _reconnectAttempt = 0;
    await _openConnection(isReconnect: false, connectTimeout: connectTimeout);
  }

  Future<void> disconnect() async {
    _connectEpoch += 1;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocket();
    if (!_disposed) {
      _emitState(const SocketSnapshot(phase: ConnectionPhase.disconnected));
    }
  }

  Future<void> _openConnection({
    required bool isReconnect,
    Duration connectTimeout = const Duration(seconds: 6),
  }) async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final epoch = ++_connectEpoch;
    await _closeSocket();
    if (_disposed || epoch != _connectEpoch || _manualDisconnect) return;

    final url = _wsUrl;
    if (url == null || url.isEmpty) {
      _emitState(const SocketSnapshot(
        phase: ConnectionPhase.error,
        lastError: 'WebSocket 地址不能为空',
      ));
      return;
    }

    _emitState(_snapshot.copyWith(
      phase: isReconnect
          ? ConnectionPhase.reconnecting
          : ConnectionPhase.connecting,
      clearError: true,
    ));

    WebSocketChannel? channel;
    try {
      final uri = Uri.parse(url);
      channel = _channelFactory(uri);
      // Silence late async errors from channel.ready if the timeout fires first.
      unawaited(channel.ready.then<void>((_) {}, onError: (_) {}));
      await channel.ready.timeout(connectTimeout);
      if (_disposed || epoch != _connectEpoch || _manualDisconnect) {
        try {
          await channel.sink.close();
        } catch (_) {}
        return;
      }
      _channel = channel;

      _subscription = channel.stream.listen(
        (dynamic frame) {
          if (_disposed || epoch != _connectEpoch) return;
          _onRawFrame(frame);
        },
        onError: (Object err) {
          if (_disposed || epoch != _connectEpoch) return;
          _handleDrop('连接异常: $err', epoch: epoch);
        },
        onDone: () {
          if (_disposed || epoch != _connectEpoch || _manualDisconnect) return;
          _handleDrop('与被控端断开连接', epoch: epoch);
        },
      );

      _emitState(_snapshot.copyWith(phase: ConnectionPhase.authenticating));
      final detectedPlatform = _detectPlatform();
      var authResp = await sendAndWait(
        AuthMessage(
          requestId: nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          token: _token,
          clientName: _clientName,
          platform: detectedPlatform,
        ),
        timeout: const Duration(seconds: 6),
      );
      if (_disposed || epoch != _connectEpoch || _manualDisconnect) return;

      if (authResp is ErrorMessage &&
          authResp.code == 'INVALID_PAYLOAD' &&
          detectedPlatform == 'ios') {
        // Fallback for older hosts whose AuthMessage schema did not yet allow "ios"
        authResp = await sendAndWait(
          AuthMessage(
            requestId: nextRequestId(),
            timestamp: DateTime.now().millisecondsSinceEpoch,
            token: _token,
            clientName: _clientName,
            platform: 'unknown',
          ),
          timeout: const Duration(seconds: 6),
        );
        if (_disposed || epoch != _connectEpoch || _manualDisconnect) return;
      }

      if (authResp is AuthAckMessage && authResp.ok) {
        _reconnectAttempt = 0;
        _lastFrameReceivedAt = DateTime.now();
        _emitState(SocketSnapshot(
          phase: ConnectionPhase.connected,
          hostInfo: authResp.hostInfo,
        ));
        _startHeartbeat();
        // Trigger an immediate ping to show initial RTT
        unawaited(pingOnce());
      } else if (authResp is ErrorMessage &&
          (authResp.code == 'UNAUTHORIZED' || authResp.code == 'AUTH_FAILED')) {
        _manualDisconnect = true;
        await _closeSocket();
        if (_disposed || epoch != _connectEpoch) return;
        _emitState(SocketSnapshot(
          phase: ConnectionPhase.error,
          lastError: authResp.message,
        ));
      } else {
        final msg =
            authResp is ErrorMessage ? authResp.message : '鉴权未通过，正在重连';
        _handleDrop(msg, epoch: epoch);
      }
    } catch (err) {
      if (channel != null && !identical(channel, _channel)) {
        try {
          unawaited(channel.sink.close().then<void>((_) {}, onError: (_) {}));
        } catch (_) {}
      }
      if (_disposed || epoch != _connectEpoch || _manualDisconnect) return;
      _handleDrop('无法连接到 $url: $err', epoch: epoch);
    }
  }

  void _onRawFrame(dynamic frame) {
    _lastFrameReceivedAt = DateTime.now();
    if (frame is Uint8List) {
      if (!_binaryController.isClosed) {
        _binaryController.add(frame);
      }
      return;
    }
    if (frame is List<int>) {
      if (!_binaryController.isClosed) {
        _binaryController.add(Uint8List.fromList(frame));
      }
      return;
    }
    if (frame is! String) return;
    ProtocolMessage? parsed;
    try {
      parsed = parseHostMessage(frame);
    } catch (_) {
      return;
    }
    if (parsed == null) return;

    if (parsed is PongMessage && parsed.timestamp != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rtt = (now - parsed.timestamp!).clamp(0, 99999);
      _emitState(_snapshot.copyWith(rttMs: rtt));
    }

    final reqId = parsed.requestId;
    if (reqId != null && _pending.containsKey(reqId)) {
      final completer = _pending.remove(reqId)!;
      if (!completer.isCompleted) {
        completer.complete(parsed);
      }
    }

    if (!_messageController.isClosed) {
      _messageController.add(parsed);
    }
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    final epoch = _connectEpoch;
    _pingTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_disposed || epoch != _connectEpoch || !_snapshot.isConnected) return;
      if (DateTime.now().difference(_lastFrameReceivedAt).inSeconds >= 16) {
        _handleDrop('心跳超时，正在重连', epoch: epoch);
        return;
      }
      unawaited(pingOnce());
    });
  }

  Future<bool> verifyAlive({
    Duration timeout = const Duration(milliseconds: 2000),
    bool reconnectImmediately = false,
  }) async {
    if (_disposed || !_snapshot.isConnected) return false;
    if (_verifyingAlive) return _snapshot.isConnected;
    _verifyingAlive = true;
    final epoch = _connectEpoch;
    try {
      await sendAndWait(
        PingMessage(
          requestId: nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
        timeout: timeout,
        verifyOnTimeout: false,
      );
      return !_disposed && epoch == _connectEpoch && _snapshot.isConnected;
    } catch (_) {
      if (!_disposed &&
          !_manualDisconnect &&
          epoch == _connectEpoch &&
          _snapshot.isConnected) {
        _handleDrop(
          '连接无响应，正在重连',
          epoch: epoch,
          immediate: reconnectImmediately,
        );
      }
      return false;
    } finally {
      _verifyingAlive = false;
    }
  }

  Future<void> pingOnce() async {
    send(PingMessage(
      requestId: nextRequestId(),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  String nextRequestId() => _uuid.v4().substring(0, 8);

  void send(ProtocolMessage message) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(message.encode());
  }

  void sendBinary(Uint8List bytes) {
    final ch = _channel;
    if (ch == null || !_snapshot.isConnected || bytes.isEmpty) return;
    ch.sink.add(bytes);
  }

  Future<ProtocolMessage> sendAndWait(
    ProtocolMessage message, {
    Duration timeout = const Duration(seconds: 8),
    bool verifyOnTimeout = true,
  }) async {
    final ch = _channel;
    if (ch == null) {
      throw StateError('WebSocket 尚未连接');
    }
    final reqId = message.requestId;
    if (reqId == null || reqId.isEmpty) {
      throw ArgumentError('sendAndWait requires a non-empty requestId');
    }
    final completer = Completer<ProtocolMessage>();
    _pending[reqId] = completer;
    ch.sink.add(message.encode());

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      if (verifyOnTimeout &&
          _snapshot.isConnected &&
          message is! PingMessage) {
        unawaited(verifyAlive());
      }
      rethrow;
    } finally {
      _pending.remove(reqId);
    }
  }

  void _handleDrop(
    String reason, {
    int? epoch,
    bool immediate = false,
  }) {
    if (_disposed || _manualDisconnect) return;
    if (epoch != null && epoch != _connectEpoch) return;
    unawaited(_closeSocket());
    if (_manualDisconnect || _disposed) return;

    if (immediate) {
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _emitState(_snapshot.copyWith(
        phase: ConnectionPhase.reconnecting,
        clearRtt: true,
        lastError: reason,
      ));
      unawaited(_openConnection(isReconnect: true));
      return;
    }

    _reconnectAttempt += 1;
    final delaySec = (1 << (_reconnectAttempt - 1).clamp(0, 3)); // 1, 2, 4, 8s
    _emitState(_snapshot.copyWith(
      phase: ConnectionPhase.reconnecting,
      clearRtt: true,
      lastError: '$reason（${delaySec}s 后自动重连）',
    ));

    final dropEpoch = _connectEpoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (!_disposed && !_manualDisconnect && dropEpoch == _connectEpoch) {
        unawaited(_openConnection(isReconnect: true));
      }
    });
  }

  Future<void> _closeSocket() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('连接已关闭'));
      }
    }
    _pending.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    _connectEpoch += 1;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocket();
    await _stateController.close();
    await _messageController.close();
    await _binaryController.close();
  }
}
