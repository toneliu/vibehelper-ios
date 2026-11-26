import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibehelper_client/core/app_settings.dart';
import 'package:vibehelper_client/core/vibe_socket_client.dart';
import 'package:vibehelper_client/features/connection/connection_controller.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeWebSocketSink extends Fake implements WebSocketSink {
  _FakeWebSocketSink(this._onAdd, this._onClose);

  final void Function(dynamic data) _onAdd;
  final Future<void> Function([int? code, String? reason]) _onClose;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void add(dynamic data) => _onAdd(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<dynamic> addStream(Stream<dynamic> stream) async {
    await for (final item in stream) {
      _onAdd(item);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await _onClose(closeCode, closeReason);
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

class _FakeWebSocketChannel extends Fake implements WebSocketChannel {
  _FakeWebSocketChannel({
    required this.uri,
    required Future<void> readyFuture,
    this.authErrorCode,
    this.authErrorMessage = 'Unauthorized',
    this.respondToPing = true,
  }) : _readyFuture = readyFuture {
    _sink = _FakeWebSocketSink(_handleOutgoing, _handleClose);
  }

  final Uri uri;
  final Future<void> _readyFuture;
  final String? authErrorCode;
  final String authErrorMessage;
  bool respondToPing;
  bool closed = false;

  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();
  late final _FakeWebSocketSink _sink;

  @override
  Future<void> get ready => _readyFuture;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => closed ? 1000 : null;

  @override
  String? get closeReason => null;

  void _handleOutgoing(dynamic raw) {
    if (closed || raw is! String) return;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final type = map['type'] as String?;
    final reqId = map['request_id'] as String?;

    if (type == 'auth') {
      scheduleMicrotask(() {
        if (closed || _incoming.isClosed) return;
        if (authErrorCode != null) {
          _incoming.add(jsonEncode({
            'type': 'error',
            'request_id': reqId,
            'code': authErrorCode,
            'message': authErrorMessage,
          }));
        } else {
          _incoming.add(jsonEncode({
            'type': 'auth_ack',
            'request_id': reqId,
            'ok': true,
            'protocol_version': '1.0',
            'host_info': {
              'hostname': uri.host,
              'os': 'linux',
              'display_server': 'x11',
            },
          }));
        }
      });
    } else if (type == 'ping' && respondToPing) {
      scheduleMicrotask(() {
        if (closed || _incoming.isClosed) return;
        _incoming.add(jsonEncode({
          'type': 'pong',
          'request_id': reqId,
          'timestamp': map['timestamp'],
        }));
      });
    }
  }

  Future<void> _handleClose([int? code, String? reason]) async {
    closed = true;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Startup & resume auto-connect', () {
    test(
      '1. Cold start awaits SettingsNotifier.ready and connects to persisted activeHost',
      () async {
        SharedPreferences.setMockInitialValues({
          'vh_ws_url': 'ws://10.0.0.50:8765/ws',
          'vh_active_host_id': 'linux',
          'vh_host_profiles_v1': jsonEncode([
            {
              'id': 'win',
              'name': 'Windows',
              'ws_url': 'ws://192.168.199.10:8765/ws',
              'token': '',
            },
            {
              'id': 'linux',
              'name': 'Linux Dev',
              'ws_url': 'ws://10.0.0.50:8765/ws',
              'token': 'tok-123',
            },
          ]),
        });

        final attemptedUrls = <String>[];
        late VibeSocketClient client;
        client = VibeSocketClient(
          channelFactory: (uri) {
            attemptedUrls.add(uri.toString());
            return _FakeWebSocketChannel(
              uri: uri,
              readyFuture: Future<void>.value(),
            );
          },
        );

        final container = ProviderContainer(
          overrides: [
            socketClientProvider.overrideWithValue(client),
            hostActionProvider.overrideWith(
              (ref) => HostActionController(
                ref,
                probeOverride: (p, _) async =>
                    HostHealthProbe(profileId: p.id, online: false),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Call immediately without awaiting settingsProvider.notifier.ready first.
        final ok =
            await container.read(hostActionProvider).autoConnectOnStartup();
        expect(ok, isTrue);
        expect(client.snapshot.isConnected, isTrue);
        expect(attemptedUrls, ['ws://10.0.0.50:8765/ws']);
        expect(container.read(settingsProvider).activeHostId, 'linux');
      },
    );

    test(
      '2. Multi-host autoConnectOnStartup keeps activeHost when it is online',
      () async {
        SharedPreferences.setMockInitialValues({
          'vh_active_host_id': 'h1',
          'vh_host_profiles_v1': jsonEncode([
            {
              'id': 'h1',
              'name': 'Primary',
              'ws_url': 'ws://10.0.0.1:8765/ws',
              'token': '',
            },
            {
              'id': 'h2',
              'name': 'Secondary',
              'ws_url': 'ws://10.0.0.2:8765/ws',
              'token': '',
            },
          ]),
        });

        final attemptedUrls = <String>[];
        final client = VibeSocketClient(
          channelFactory: (uri) {
            attemptedUrls.add(uri.toString());
            return _FakeWebSocketChannel(
              uri: uri,
              readyFuture: Future<void>.value(),
            );
          },
        );

        final container = ProviderContainer(
          overrides: [
            socketClientProvider.overrideWithValue(client),
            hostActionProvider.overrideWith(
              (ref) => HostActionController(
                ref,
                probeOverride: (p, _) async =>
                    HostHealthProbe(profileId: p.id, online: true, rttMs: 2),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final ok =
            await container.read(hostActionProvider).autoConnectOnStartup();
        expect(ok, isTrue);
        expect(attemptedUrls, ['ws://10.0.0.1:8765/ws']);
        expect(container.read(settingsProvider).activeHostId, 'h1');
      },
    );

    test(
      '3. Multi-host autoConnectOnStartup falls back to online host when activeHost fails',
      () async {
        SharedPreferences.setMockInitialValues({
          'vh_active_host_id': 'h1',
          'vh_host_profiles_v1': jsonEncode([
            {
              'id': 'h1',
              'name': 'Offline Primary',
              'ws_url': 'ws://10.0.0.1:8765/ws',
              'token': '',
            },
            {
              'id': 'h2',
              'name': 'Offline Second',
              'ws_url': 'ws://10.0.0.2:8765/ws',
              'token': '',
            },
            {
              'id': 'h3',
              'name': 'Online Third',
              'ws_url': 'ws://10.0.0.3:8765/ws',
              'token': '',
            },
          ]),
        });

        final attemptedUrls = <String>[];
        final client = VibeSocketClient(
          channelFactory: (uri) {
            attemptedUrls.add(uri.toString());
            if (uri.host == '10.0.0.3') {
              return _FakeWebSocketChannel(
                uri: uri,
                readyFuture: Future<void>.value(),
              );
            }
            return _FakeWebSocketChannel(
              uri: uri,
              readyFuture: Future<void>.error(StateError('Connection refused')),
            );
          },
        );

        final container = ProviderContainer(
          overrides: [
            socketClientProvider.overrideWithValue(client),
            hostActionProvider.overrideWith(
              (ref) => HostActionController(
                ref,
                probeOverride: (p, _) async => HostHealthProbe(
                  profileId: p.id,
                  online: p.id == 'h3',
                  rttMs: p.id == 'h3' ? 8 : null,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final ok =
            await container.read(hostActionProvider).autoConnectOnStartup();
        expect(ok, isTrue);
        expect(client.snapshot.isConnected, isTrue);
        expect(attemptedUrls, [
          'ws://10.0.0.1:8765/ws',
          'ws://10.0.0.3:8765/ws',
        ]);
        expect(container.read(settingsProvider).activeHostId, 'h3');
      },
    );

    test(
      '4. Multi-host autoConnectOnStartup preserves activeHostId when all hosts are offline',
      () async {
        SharedPreferences.setMockInitialValues({
          'vh_active_host_id': 'h1',
          'vh_host_profiles_v1': jsonEncode([
            {
              'id': 'h1',
              'name': 'Primary',
              'ws_url': 'ws://10.0.0.1:8765/ws',
              'token': '',
            },
            {
              'id': 'h2',
              'name': 'Secondary',
              'ws_url': 'ws://10.0.0.2:8765/ws',
              'token': '',
            },
          ]),
        });

        final client = VibeSocketClient(
          channelFactory: (uri) => _FakeWebSocketChannel(
            uri: uri,
            readyFuture: Future<void>.error(StateError('Offline')),
          ),
        );

        final container = ProviderContainer(
          overrides: [
            socketClientProvider.overrideWithValue(client),
            hostActionProvider.overrideWith(
              (ref) => HostActionController(
                ref,
                probeOverride: (p, _) async =>
                    HostHealthProbe(profileId: p.id, online: false),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final ok =
            await container.read(hostActionProvider).autoConnectOnStartup();
        expect(ok, isFalse);
        expect(client.snapshot.isConnected, isFalse);
        expect(container.read(settingsProvider).activeHostId, 'h1');
      },
    );

    test(
      '5. VibeSocketClient epoch and timer guards prevent stale connects or timers from disrupting live connection',
      () async {
        final slowReady = Completer<void>();
        late _FakeWebSocketChannel slowChannel;
        final attempts = <String>[];

        final client = VibeSocketClient(
          channelFactory: (uri) {
            attempts.add(uri.toString());
            if (uri.host == 'slow-host') {
              slowChannel = _FakeWebSocketChannel(
                uri: uri,
                readyFuture: slowReady.future,
              );
              return slowChannel;
            }
            if (uri.host == 'bad-host') {
              return _FakeWebSocketChannel(
                uri: uri,
                readyFuture: Future<void>.error(StateError('Refused')),
              );
            }
            return _FakeWebSocketChannel(
              uri: uri,
              readyFuture: Future<void>.value(),
            );
          },
        );
        addTearDown(client.dispose);

        // Start a hung attempt, then supersede it with a fresh connect.
        final slowFuture = client.connect(
          wsUrl: 'ws://slow-host:8765/ws',
          token: '',
          clientName: 'test',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.snapshot.phase, ConnectionPhase.connecting);

        await client.connect(
          wsUrl: 'ws://fast-host:8765/ws',
          token: '',
          clientName: 'test',
        );
        expect(client.snapshot.isConnected, isTrue);
        expect(client.currentWsUrl, 'ws://fast-host:8765/ws');

        // Late resolution of the superseded slow channel must be ignored & closed.
        slowReady.complete();
        await slowFuture;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(slowChannel.closed, isTrue);
        expect(client.snapshot.isConnected, isTrue);
        expect(client.currentWsUrl, 'ws://fast-host:8765/ws');

        // Start a failing attempt to schedule 1s reconnect timer, then connect cleanly.
        await client.connect(
          wsUrl: 'ws://bad-host:8765/ws',
          token: '',
          clientName: 'test',
        );
        expect(client.snapshot.phase, ConnectionPhase.reconnecting);

        attempts.clear();
        await client.connect(
          wsUrl: 'ws://good-host:8765/ws',
          token: '',
          clientName: 'test',
        );
        expect(client.snapshot.isConnected, isTrue);

        // Wait past the 1s backoff timer window; it must have been cancelled.
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(attempts, ['ws://good-host:8765/ws']);
        expect(client.snapshot.isConnected, isTrue);
        expect(client.currentWsUrl, 'ws://good-host:8765/ws');
      },
    );

    test(
      '6. reconnectOnResume recovers from stuck connecting phase and dead half-open socket',
      () async {
        SharedPreferences.setMockInitialValues({
          'vh_active_host_id': 'default',
          'vh_host_profiles_v1': jsonEncode([
            {
              'id': 'default',
              'name': 'Host',
              'ws_url': 'ws://10.0.0.9:8765/ws',
              'token': '',
            },
          ]),
        });

        int callCount = 0;
        final hungReady = Completer<void>();
        late _FakeWebSocketChannel secondChannel;
        final client = VibeSocketClient(
          channelFactory: (uri) {
            callCount += 1;
            if (callCount == 1) {
              return _FakeWebSocketChannel(
                uri: uri,
                readyFuture: hungReady.future,
              );
            }
            if (callCount == 2) {
              secondChannel = _FakeWebSocketChannel(
                uri: uri,
                readyFuture: Future<void>.value(),
                respondToPing: true,
              );
              return secondChannel;
            }
            return _FakeWebSocketChannel(
              uri: uri,
              readyFuture: Future<void>.value(),
              respondToPing: true,
            );
          },
        );

        final container = ProviderContainer(
          overrides: [
            socketClientProvider.overrideWithValue(client),
          ],
        );
        addTearDown(container.dispose);

        // Part A: Stuck in connecting phase -> reconnectOnResume supersedes immediately.
        final hungConnect = client.connect(
          wsUrl: 'ws://10.0.0.9:8765/ws',
          token: '',
          clientName: 'test',
          connectTimeout: const Duration(seconds: 30),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.snapshot.phase, ConnectionPhase.connecting);

        final recovered =
            await container.read(hostActionProvider).reconnectOnResume();
        expect(recovered, isTrue);
        expect(client.snapshot.isConnected, isTrue);
        expect(callCount, 2);

        // Let the hung future finish silently so teardown is clean.
        hungReady.completeError(StateError('aborted'));
        await hungConnect;

        // Part B: Connected socket becomes silent (half-open dead TCP) ->
        // reconnectOnResume detects ping timeout and reconnects immediately.
        secondChannel.respondToPing = false;
        final resumedLive =
            await container.read(hostActionProvider).reconnectOnResume();
        expect(resumedLive, isTrue);
        expect(client.snapshot.isConnected, isTrue);
        expect(callCount, 3);
      },
    );

    test(
      '7. Manual disconnect and UNAUTHORIZED rejection are not overridden by auto-connect',
      () async {
        SharedPreferences.setMockInitialValues({
          'vh_active_host_id': 'default',
          'vh_host_profiles_v1': jsonEncode([
            {
              'id': 'default',
              'name': 'Host',
              'ws_url': 'ws://10.0.0.9:8765/ws',
              'token': '',
            },
          ]),
        });

        String? errorCode;
        int connectCalls = 0;
        final client = VibeSocketClient(
          channelFactory: (uri) {
            connectCalls += 1;
            return _FakeWebSocketChannel(
              uri: uri,
              readyFuture: Future<void>.value(),
              authErrorCode: errorCode,
              authErrorMessage: 'Invalid token',
            );
          },
        );

        final container = ProviderContainer(
          overrides: [
            socketClientProvider.overrideWithValue(client),
          ],
        );
        addTearDown(container.dispose);

        // Subcase A: Explicit disconnect sets manualDisconnect = true.
        expect(
          await container.read(hostActionProvider).autoConnectOnStartup(),
          isTrue,
        );
        await container.read(hostActionProvider).disconnect();
        expect(client.isManualDisconnect, isTrue);

        final callsAfterDisconnect = connectCalls;
        expect(
          await container.read(hostActionProvider).autoConnectOnStartup(),
          isFalse,
        );
        expect(
          await container.read(hostActionProvider).reconnectOnResume(),
          isFalse,
        );
        expect(connectCalls, callsAfterDisconnect);

        // Subcase B: UNAUTHORIZED blocks further auto-reconnects until manual connect.
        errorCode = 'UNAUTHORIZED';
        expect(
          await container.read(hostActionProvider).connectFromSettings(),
          isFalse,
        );
        expect(client.snapshot.phase, ConnectionPhase.error);
        expect(client.snapshot.lastError, 'Invalid token');
        expect(client.isManualDisconnect, isTrue);

        final callsAfterAuthFail = connectCalls;
        expect(
          await container.read(hostActionProvider).reconnectOnResume(),
          isFalse,
        );
        expect(connectCalls, callsAfterAuthFail);
      },
    );
  });
}
