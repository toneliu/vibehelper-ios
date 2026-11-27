import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';

import '../../core/app_settings.dart';
import '../../core/vibe_socket_client.dart';
import '../../protocol/messages.dart';
import '../connection/connection_controller.dart';
import '../update/update_controller.dart';
import '../windows/window_controller.dart';
import 'pcm_voice_gate.dart';

enum StreamPhase {
  idle,
  starting,
  streaming,
  error,
}

class RemoteStreamState {
  const RemoteStreamState({
    this.phase = StreamPhase.idle,
    this.mode = 'window',
    this.transport = 'ws_mjpeg', // 'ws_mjpeg' (NAT/Firewall-proof default) | 'webrtc'
    this.qualityPreset = 'balanced', // 'eco' | 'balanced' | 'hd'
    this.fps = 12,
    this.streamId,
    this.videoWidth = 1280,
    this.videoHeight = 720,
    this.hasVideoTrack = false,
    this.liveFrameBytes,
    this.liveFrameCount = 0,
    this.rendererVersion = 0,
    this.error,
    this.audioBridgeActive = false,
    this.audioBridgeDevice,
    this.audioChunksSent = 0,
    this.audioVoiceActive = false,
    this.audioSkippedSilenceChunks = 0,
  });

  final StreamPhase phase;
  final String mode; // 'window' | 'screen' | 'audio_only'
  final String transport; // 'ws_mjpeg' | 'webrtc'
  final String qualityPreset; // 'eco' | 'balanced' | 'hd'
  final int fps;
  final String? streamId;
  final int videoWidth;
  final int videoHeight;
  final bool hasVideoTrack;
  final Uint8List? liveFrameBytes;
  final int liveFrameCount;
  final int rendererVersion;
  final String? error;
  final bool audioBridgeActive;
  final String? audioBridgeDevice;
  final int audioChunksSent;
  final bool audioVoiceActive;
  final int audioSkippedSilenceChunks;

  String get qualityPresetLabel => switch (qualityPreset) {
        'eco' => '省流',
        'hd' => '高清',
        _ => '均衡',
      };

  bool get isStreaming => phase == StreamPhase.streaming;
  bool get isWsVideo => transport == 'ws_mjpeg';
  bool get isVideoStreaming =>
      isStreaming &&
      mode != 'audio_only' &&
      (isWsVideo ? liveFrameBytes != null : hasVideoTrack);
  double get aspectRatio =>
      videoHeight > 0 ? (videoWidth / videoHeight) : (16 / 9);

  RemoteStreamState copyWith({
    StreamPhase? phase,
    String? mode,
    String? transport,
    String? qualityPreset,
    int? fps,
    String? streamId,
    bool clearStreamId = false,
    int? videoWidth,
    int? videoHeight,
    bool? hasVideoTrack,
    Uint8List? liveFrameBytes,
    bool clearLiveFrame = false,
    int? liveFrameCount,
    int? rendererVersion,
    String? error,
    bool clearError = false,
    bool? audioBridgeActive,
    String? audioBridgeDevice,
    bool clearAudioDevice = false,
    int? audioChunksSent,
    bool? audioVoiceActive,
    int? audioSkippedSilenceChunks,
  }) {
    return RemoteStreamState(
      phase: phase ?? this.phase,
      mode: mode ?? this.mode,
      transport: transport ?? this.transport,
      qualityPreset: qualityPreset ?? this.qualityPreset,
      fps: fps ?? this.fps,
      streamId: clearStreamId ? null : (streamId ?? this.streamId),
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      hasVideoTrack: hasVideoTrack ?? this.hasVideoTrack,
      liveFrameBytes:
          clearLiveFrame ? null : (liveFrameBytes ?? this.liveFrameBytes),
      liveFrameCount: liveFrameCount ?? this.liveFrameCount,
      rendererVersion: rendererVersion ?? this.rendererVersion,
      error: clearError ? null : (error ?? this.error),
      audioBridgeActive: audioBridgeActive ?? this.audioBridgeActive,
      audioBridgeDevice: clearAudioDevice
          ? null
          : (audioBridgeDevice ?? this.audioBridgeDevice),
      audioChunksSent: audioChunksSent ?? this.audioChunksSent,
      audioVoiceActive: audioVoiceActive ?? this.audioVoiceActive,
      audioSkippedSilenceChunks:
          audioSkippedSilenceChunks ?? this.audioSkippedSilenceChunks,
    );
  }
}

class RemoteStreamController extends StateNotifier<RemoteStreamState> {
  RemoteStreamController(this._ref) : super(const RemoteStreamState()) {
    unawaited(_initRenderer());
    _msgSub = _client.messages.listen(_onHostMessage);
    _binSub = _client.binaryMessages.listen(_onBinaryFrame);
    _connSub = _client.stateStream.listen((snap) {
      if (!snap.isConnected) {
        _audioStarting = false;
        _audioStopping = false;
        _audioBridgeSending = false;
        _pendingAudioStop = false;
        unawaited(_stopWsAudioMic());
        unawaited(_cleanupPeer(resetPhase: true));
        if (state.audioBridgeActive || state.audioBridgeDevice != null) {
          state = state.copyWith(
            audioBridgeActive: false,
            audioChunksSent: 0,
            audioVoiceActive: false,
            audioSkippedSilenceChunks: 0,
            clearAudioDevice: true,
          );
        }
      }
    });
  }

  final Ref _ref;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  final AudioRecorder _pcmRecorder = AudioRecorder();
  final PcmVoiceGate _voiceGate = PcmVoiceGate();
  bool _rendererReady = false;
  bool _audioStarting = false;
  bool _audioStopping = false;
  bool _audioBridgeSending = false;
  bool _pendingAudioStop = false;

  void updateVoiceGateThresholds({
    int? speechPeakThreshold,
    double? speechRmsThreshold,
    int? hangoverMs,
  }) {
    _voiceGate.updateThresholds(
      speechPeakThreshold: speechPeakThreshold,
      speechRmsThreshold: speechRmsThreshold,
      hangoverMs: hangoverMs,
    );
  }

  RTCPeerConnection? _pc;
  RTCDataChannel? _inputDc;
  StreamSubscription<Uint8List>? _micPcmSub;

  StreamSubscription<ProtocolMessage>? _msgSub;
  StreamSubscription<Uint8List>? _binSub;
  StreamSubscription<SocketSnapshot>? _connSub;

  VibeSocketClient get _client => _ref.read(socketClientProvider);

  Future<void> _initRenderer() async {
    if (_rendererReady) return;
    await renderer.initialize();
    renderer.onResize = () {
      final w = renderer.videoWidth;
      final h = renderer.videoHeight;
      if (w > 0 && h > 0) {
        state = state.copyWith(
          videoWidth: w,
          videoHeight: h,
          rendererVersion: state.rendererVersion + 1,
        );
      }
    };
    _rendererReady = true;
  }

  void setMode(String mode) {
    state = state.copyWith(mode: mode);
  }

  void setTransport(String transport) {
    state = state.copyWith(transport: transport);
  }

  void setFps(int fps) {
    state = state.copyWith(fps: fps);
  }

  Future<void> cycleQualityPreset() async {
    final next = switch (state.qualityPreset) {
      'eco' => 'balanced',
      'balanced' => 'hd',
      _ => 'eco',
    };
    state = state.copyWith(qualityPreset: next);
    if (state.isStreaming || state.phase == StreamPhase.starting) {
      await startStream();
    }
  }

  Future<void> startStream({
    String? overrideMode,
    String? overrideTransport,
  }) async {
    if (!_client.snapshot.isConnected) {
      state = state.copyWith(phase: StreamPhase.error, error: '请先连接被控端');
      return;
    }
    final mode = overrideMode ?? state.mode;
    final transport = overrideTransport ?? state.transport;
    final targetWindowId = _ref.read(windowControllerProvider).selectedWindowId;
    final effectiveMode =
        (mode == 'window' && targetWindowId == null) ? 'screen' : mode;

    final (presetFps, presetQuality, presetMaxWidth) =
        switch (state.qualityPreset) {
      'eco' => (8, 48, 640),
      'hd' => (15, 82, 1440),
      _ => (12, 65, 960),
    };

    await _cleanupPeer(resetPhase: false);
    if (transport == 'webrtc') {
      await _initRenderer();
    }

    state = state.copyWith(
      phase: StreamPhase.starting,
      mode: effectiveMode,
      transport: transport,
      fps: presetFps,
      hasVideoTrack: false,
      clearLiveFrame: true,
      liveFrameCount: 0,
      clearError: true,
    );

    _client.send(
      StartStreamMessage(
        requestId: _client.nextRequestId(),
        timestamp: DateTime.now().millisecondsSinceEpoch,
        mode: effectiveMode,
        transport: transport,
        targetWindowId: effectiveMode == 'window' ? targetWindowId : null,
        fps: transport == 'ws_mjpeg' ? presetFps : 20,
        codec: 'vp8',
        quality: presetQuality,
        maxWidth: presetMaxWidth,
      ),
    );
  }

  Future<void> stopStream() async {
    if (_client.snapshot.isConnected) {
      _client.send(
        StopStreamMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          streamId: state.streamId,
        ),
      );
    }
    await _cleanupPeer(resetPhase: true);
  }

  /// Step 5: Real-time virtual microphone bridge over WebSocket Binary PCM (`ws_binary`).
  /// Works over LAN, 4G/5G, NAT port-forwarding, FRP, and Windows Firewall with ZERO UDP dependency!
  Future<void> toggleAudioBridge() async {
    if (_audioStopping) return;
    if (_audioStarting) {
      // User tapped stop while start_audio_bridge ack is still in flight -> cancel cleanly
      await stopAudioBridge(forceSendStop: true);
      return;
    }
    if (state.audioBridgeActive) {
      await stopAudioBridge(forceSendStop: true);
    } else {
      await startAudioBridge();
    }
  }

  Future<void> startAudioBridge() async {
    if (!_client.snapshot.isConnected) {
      state = state.copyWith(error: '请先连接被控端');
      return;
    }
    if (state.audioBridgeActive || _audioStarting || _audioStopping) {
      return;
    }

    _audioStarting = true;
    _pendingAudioStop = false;
    _audioBridgeSending = false;
    final targetWindowId = _ref.read(windowControllerProvider).selectedWindowId;
    bool hostBridgeStarted = false;

    try {
      final hasPerm = await _pcmRecorder.hasPermission();
      if (!hasPerm) {
        state = state.copyWith(
          audioBridgeActive: false,
          error: '请授予麦克风录音权限后再开启虚拟麦',
        );
        return;
      }

      if (_pendingAudioStop || !_client.snapshot.isConnected) {
        _pendingAudioStop = false;
        state = state.copyWith(
          audioBridgeActive: false,
          audioChunksSent: 0,
          clearAudioDevice: true,
        );
        return;
      }

      // 1. Open Host virtual microphone (VB-Cable / PipeWire) at 16kHz 16-bit mono
      // and align remote IDE voice button state to active
      final ack = await _client.sendAndWait(
        AudioBridgeStartMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          transport: 'ws_binary',
          codec: 'pcm_s16le',
          sampleRate: 16000,
          channels: 1,
          frameDurationMs: 20,
          targetWindowId: targetWindowId,
          autoTriggerVoice: true,
        ),
        timeout: const Duration(seconds: 6),
      );

      if (ack is AudioBridgeStateMessage && ack.status != 'active') {
        state = state.copyWith(
          audioBridgeActive: false,
          clearAudioDevice: true,
          error: ack.status == 'idle'
              ? null
              : '虚拟麦启动失败: ${ack.error ?? '未知错误'}',
        );
        return;
      }

      hostBridgeStarted = true;
      if (_pendingAudioStop || !_client.snapshot.isConnected) {
        _pendingAudioStop = false;
        if (_client.snapshot.isConnected) {
          _client.send(AudioBridgeStopMessage(
            requestId: _client.nextRequestId(),
            timestamp: DateTime.now().millisecondsSinceEpoch,
            targetWindowId: targetWindowId,
            autoTriggerVoice: true,
          ));
        }
        state = state.copyWith(
          audioBridgeActive: false,
          audioChunksSent: 0,
          clearAudioDevice: true,
        );
        return;
      }

      final devName =
          ack is AudioBridgeStateMessage ? ack.virtualDevice : null;

      // 2. Stream raw s16le PCM frames straight over the already-connected WebSocket
      final pcmStream = await _pcmRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );

      if (_pendingAudioStop || !_client.snapshot.isConnected) {
        _pendingAudioStop = false;
        await _stopWsAudioMic();
        if (hostBridgeStarted && _client.snapshot.isConnected) {
          _client.send(AudioBridgeStopMessage(
            requestId: _client.nextRequestId(),
            timestamp: DateTime.now().millisecondsSinceEpoch,
            targetWindowId: targetWindowId,
            autoTriggerVoice: true,
          ));
        }
        state = state.copyWith(
          audioBridgeActive: false,
          audioChunksSent: 0,
          clearAudioDevice: true,
        );
        return;
      }

      _voiceGate.reset();
      _audioBridgeSending = true;
      int sentChunks = 0;
      int silenceTicks = 0;
      _micPcmSub = pcmStream.listen(
        (Uint8List chunk) {
          if (!_audioBridgeSending ||
              _audioStopping ||
              _pendingAudioStop ||
              chunk.isEmpty ||
              !_client.snapshot.isConnected) {
            return;
          }
          final toSend = _voiceGate.processChunk(chunk);
          if (toSend.isEmpty) {
            silenceTicks++;
            if (state.audioVoiceActive || silenceTicks % 15 == 0) {
              state = state.copyWith(
                audioVoiceActive: false,
                audioSkippedSilenceChunks: _voiceGate.skippedSilenceChunks,
              );
            }
            return;
          }
          for (final pcm in toSend) {
            // Prefix 4-byte magic "VPCM" so Host cleanly routes speech frames
            final packet = Uint8List(4 + pcm.length);
            packet[0] = 0x56; // V
            packet[1] = 0x50; // P
            packet[2] = 0x43; // C
            packet[3] = 0x4D; // M
            packet.setRange(4, packet.length, pcm);
            _client.sendBinary(packet);
            sentChunks++;
          }
          if (!state.audioVoiceActive || sentChunks == 1 || sentChunks % 10 == 0) {
            state = state.copyWith(
              audioChunksSent: sentChunks,
              audioVoiceActive: true,
              audioSkippedSilenceChunks: _voiceGate.skippedSilenceChunks,
            );
          }
        },
        onError: (Object err) {
          state = state.copyWith(
            error: '麦克风采集异常: $err',
          );
          unawaited(stopAudioBridge(forceSendStop: true));
        },
      );

      state = state.copyWith(
        audioBridgeActive: true,
        audioBridgeDevice: devName ?? '虚拟麦克风',
        audioChunksSent: 0,
        audioVoiceActive: false,
        audioSkippedSilenceChunks: 0,
        clearError: true,
      );
    } catch (e) {
      _audioBridgeSending = false;
      await _stopWsAudioMic();
      if (hostBridgeStarted && _client.snapshot.isConnected) {
        _client.send(AudioBridgeStopMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          targetWindowId: targetWindowId,
          autoTriggerVoice: true,
        ));
      }
      state = state.copyWith(
        audioBridgeActive: false,
        audioChunksSent: 0,
        clearAudioDevice: true,
        error: '无法开启实时语音直传: $e',
      );
    } finally {
      _audioStarting = false;
      if (_pendingAudioStop) {
        _pendingAudioStop = false;
        if (state.audioBridgeActive) {
          await stopAudioBridge(forceSendStop: true);
        }
      }
    }
  }

  Future<void> stopAudioBridge({bool forceSendStop = false}) async {
    _audioBridgeSending = false;
    _voiceGate.reset();
    if (_audioStarting) {
      _pendingAudioStop = true;
      if (state.audioBridgeActive) {
        state = state.copyWith(
          audioBridgeActive: false,
          audioChunksSent: 0,
          audioVoiceActive: false,
          audioSkippedSilenceChunks: 0,
          clearAudioDevice: true,
        );
      }
      return;
    }
    if (_audioStopping) {
      return;
    }
    if (!state.audioBridgeActive && !forceSendStop) {
      return;
    }
    _audioStopping = true;
    final targetWindowId = _ref.read(windowControllerProvider).selectedWindowId;
    try {
      await _stopWsAudioMic();
      if (_client.snapshot.isConnected) {
        try {
          await _client.sendAndWait(
            AudioBridgeStopMessage(
              requestId: _client.nextRequestId(),
              timestamp: DateTime.now().millisecondsSinceEpoch,
              targetWindowId: targetWindowId,
              autoTriggerVoice: true,
            ),
            timeout: const Duration(seconds: 3),
          );
        } catch (_) {
          // Best-effort ack wait; local mic and UI still reset cleanly below
        }
      }
      state = state.copyWith(
        audioBridgeActive: false,
        audioChunksSent: 0,
        audioVoiceActive: false,
        audioSkippedSilenceChunks: 0,
        clearAudioDevice: true,
      );
    } finally {
      _audioStopping = false;
      _pendingAudioStop = false;
    }
  }

  Future<void> _stopWsAudioMic() async {
    await _micPcmSub?.cancel();
    _micPcmSub = null;
    try {
      if (await _pcmRecorder.isRecording()) {
        await _pcmRecorder.stop();
      }
    } catch (_) {}
  }

  void sendPointer({
    required String action,
    required double xNorm,
    required double yNorm,
    String button = 'left',
    double deltaX = 0.0,
    double deltaY = 0.0,
  }) {
    final targetWindowId = _ref.read(windowControllerProvider).selectedWindowId;
    final msg = InputPointerMessage(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: action,
      button: button,
      xNorm: xNorm.clamp(0.0, 1.0),
      yNorm: yNorm.clamp(0.0, 1.0),
      deltaX: deltaX,
      deltaY: deltaY,
      targetWindowId: targetWindowId,
    );

    final dc = _inputDc;
    if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      dc.send(RTCDataChannelMessage(msg.encode()));
    } else if (_client.snapshot.isConnected) {
      _client.send(msg);
    }
  }

  void _onBinaryFrame(Uint8List frame) {
    // Magic header: 'VIMG' (0x56 0x49 0x4D 0x47) + uint16 width + uint16 height + JPEG payload
    if (frame.length <= 8) return;
    if (frame[0] != 0x56 ||
        frame[1] != 0x49 ||
        frame[2] != 0x4D ||
        frame[3] != 0x47) {
      return;
    }
    final w = (frame[4] << 8) | frame[5];
    final h = (frame[6] << 8) | frame[7];
    final jpeg = Uint8List.sublistView(frame, 8);
    if (jpeg.isEmpty) return;

    state = state.copyWith(
      phase: StreamPhase.streaming,
      transport: 'ws_mjpeg',
      videoWidth: w > 0 ? w : state.videoWidth,
      videoHeight: h > 0 ? h : state.videoHeight,
      liveFrameBytes: jpeg,
      liveFrameCount: state.liveFrameCount + 1,
      clearError: true,
    );
  }

  void _onHostMessage(ProtocolMessage msg) {
    if (msg is WebRTCSignalMessage && msg.type == 'webrtc_offer') {
      unawaited(_handleOffer(msg));
    } else if (msg is StreamStateMessage) {
      switch (msg.status) {
        case 'starting':
          state = state.copyWith(
            phase: StreamPhase.starting,
            streamId: msg.streamId,
            transport: msg.transport ?? state.transport,
            videoWidth: (msg.width != null && msg.width! > 0)
                ? msg.width
                : state.videoWidth,
            videoHeight: (msg.height != null && msg.height! > 0)
                ? msg.height
                : state.videoHeight,
          );
        case 'streaming':
          state = state.copyWith(
            phase: StreamPhase.streaming,
            streamId: msg.streamId,
            transport: msg.transport ?? state.transport,
            videoWidth: (msg.width != null && msg.width! > 0)
                ? msg.width
                : state.videoWidth,
            videoHeight: (msg.height != null && msg.height! > 0)
                ? msg.height
                : state.videoHeight,
            clearError: true,
          );
        case 'error':
          unawaited(_cleanupPeer(resetPhase: false));
          state = state.copyWith(
            phase: StreamPhase.error,
            error: msg.error ?? '推流失败',
          );
        case 'stopped':
          unawaited(_cleanupPeer(resetPhase: true));
      }
    } else if (msg is AudioBridgeStateMessage) {
      if (msg.status == 'active') {
        if (_audioStopping || _pendingAudioStop || !_audioStarting && !state.audioBridgeActive) {
          return;
        }
        state = state.copyWith(
          audioBridgeActive: true,
          audioBridgeDevice: msg.virtualDevice,
          clearError: true,
        );
      } else if (msg.status == 'error') {
        _audioBridgeSending = false;
        _voiceGate.reset();
        unawaited(_stopWsAudioMic());
        state = state.copyWith(
          audioBridgeActive: false,
          audioVoiceActive: false,
          audioSkippedSilenceChunks: 0,
          clearAudioDevice: true,
          error: '虚拟麦启动失败: ${msg.error ?? ''}',
        );
      } else {
        _audioBridgeSending = false;
        _voiceGate.reset();
        unawaited(_stopWsAudioMic());
        state = state.copyWith(
          audioBridgeActive: false,
          audioChunksSent: 0,
          audioVoiceActive: false,
          audioSkippedSilenceChunks: 0,
          clearAudioDevice: true,
        );
      }
    }
  }

  Future<void> _handleOffer(WebRTCSignalMessage offerMsg) async {
    if (offerMsg.sdp == null) return;
    await _cleanupPeer(resetPhase: false);
    await _initRenderer();

    // Direct LAN candidates by default (instant ICE gathering without blocked public STUN)
    final pc = await createPeerConnection({
      'iceServers': const <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video') {
        unawaited(_attachVideoTrack(event));
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState iceState) {
      if (iceState == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        if (state.transport == 'webrtc' && mounted) {
          state = state.copyWith(
            error: 'WebRTC UDP通道受限（NAT/防火墙），请切换至「WS极速流」',
          );
        }
      } else if (iceState ==
              RTCIceConnectionState.RTCIceConnectionStateConnected ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        if (state.transport == 'webrtc' && mounted) {
          state = state.copyWith(
            phase: StreamPhase.streaming,
            clearError: true,
          );
        }
      }
    };

    pc.onDataChannel = (RTCDataChannel channel) {
      _inputDc = channel;
    };

    pc.onIceCandidate = (RTCIceCandidate cand) {
      if (cand.candidate != null && cand.candidate!.isNotEmpty) {
        _client.send(
          WebRTCSignalMessage(
            signalType: 'webrtc_ice',
            streamId: offerMsg.streamId,
            candidate: cand.candidate,
            sdpMid: cand.sdpMid,
            sdpMLineIndex: cand.sdpMLineIndex,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    };

    await pc.setRemoteDescription(
      RTCSessionDescription(offerMsg.sdp!, 'offer'),
    );

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    _client.send(
      WebRTCSignalMessage(
        signalType: 'webrtc_answer',
        streamId: offerMsg.streamId,
        sdp: answer.sdp,
        sdpType: 'answer',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _attachVideoTrack(RTCTrackEvent event) async {
    await _initRenderer();
    MediaStream stream;
    if (event.streams.isNotEmpty) {
      stream = event.streams.first;
    } else {
      stream = await createLocalMediaStream(
        'remote-video-${state.rendererVersion + 1}',
      );
      await stream.addTrack(event.track);
    }
    renderer.srcObject = stream;
    state = state.copyWith(
      hasVideoTrack: true,
      rendererVersion: state.rendererVersion + 1,
    );
  }

  Future<void> _cleanupPeer({required bool resetPhase}) async {
    try {
      await _inputDc?.close();
    } catch (_) {}
    _inputDc = null;

    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    if (_rendererReady) {
      renderer.srcObject = null;
    }

    if (resetPhase) {
      state = state.copyWith(
        phase: StreamPhase.idle,
        hasVideoTrack: false,
        clearLiveFrame: true,
        liveFrameCount: 0,
        clearStreamId: true,
      );
    }
  }

  @override
  void dispose() {
    unawaited(_msgSub?.cancel());
    unawaited(_binSub?.cancel());
    unawaited(_connSub?.cancel());
    unawaited(_stopWsAudioMic());
    unawaited(_pcmRecorder.dispose());
    unawaited(_cleanupPeer(resetPhase: false));
    if (_rendererReady) {
      unawaited(renderer.dispose());
    }
    super.dispose();
  }
}

final remoteStreamProvider =
    StateNotifierProvider<RemoteStreamController, RemoteStreamState>((ref) {
  final ctrl = RemoteStreamController(ref);

  void applyVad() {
    final s = ref.read(settingsProvider);
    final cfg = ref.read(appUpdateProvider).hotConfig;
    if (s.vadUseLocalOverride) {
      ctrl.updateVoiceGateThresholds(
        speechPeakThreshold: s.vadPeakThreshold,
        speechRmsThreshold: s.vadRmsThreshold.toDouble(),
        hangoverMs: s.vadHangoverMs,
      );
    } else {
      ctrl.updateVoiceGateThresholds(
        speechPeakThreshold: cfg.vadPeakThreshold,
        speechRmsThreshold: cfg.vadRmsThreshold,
        hangoverMs: cfg.vadHangoverMs,
      );
    }
  }

  applyVad();
  ref.listen<HotUpdateConfig>(
    appUpdateProvider.select((s) => s.hotConfig),
    (_, __) => applyVad(),
  );
  ref.listen<(bool, int, int, int)>(
    settingsProvider.select((s) => (
          s.vadUseLocalOverride,
          s.vadPeakThreshold,
          s.vadRmsThreshold,
          s.vadHangoverMs,
        )),
    (_, __) => applyVad(),
  );
  return ctrl;
});
