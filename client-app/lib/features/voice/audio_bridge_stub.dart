import '../../core/vibe_socket_client.dart';
import '../../protocol/messages.dart';

/// Reserved Mode-2 Audio Stream Bridge interface (implemented in Step 5).
/// Streams Opus-encoded microphone PCM to Host's virtual microphone device
/// (PulseAudio module-pipe-source on Linux / Virtual Audio Cable on Windows).
abstract class AudioBridgeService {
  bool get isStreaming;

  Future<void> startOpusBridge({
    int sampleRate = 48000,
    int channels = 1,
    int frameDurationMs = 20,
  });

  Future<void> stopOpusBridge();
}

class StubAudioBridgeService implements AudioBridgeService {
  StubAudioBridgeService(this._client);

  final VibeSocketClient _client;
  bool _streaming = false;

  @override
  bool get isStreaming => _streaming;

  @override
  Future<void> startOpusBridge({
    int sampleRate = 48000,
    int channels = 1,
    int frameDurationMs = 20,
  }) async {
    if (!_client.snapshot.isConnected) {
      throw StateError('请先连接到被控端');
    }
    _client.send(
      AudioBridgeStartMessage(
        requestId: _client.nextRequestId(),
        timestamp: DateTime.now().millisecondsSinceEpoch,
        sampleRate: sampleRate,
        channels: channels,
        frameDurationMs: frameDurationMs,
      ),
    );
    _streaming = false;
  }

  @override
  Future<void> stopOpusBridge() async {
    if (_client.snapshot.isConnected) {
      _client.send(
        AudioBridgeStopMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    _streaming = false;
  }
}
