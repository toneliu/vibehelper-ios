/// VibeHelper Protocol v1.0 Dart models.
/// Mirrors `protocol/schema.json` and `server-host/app/protocol/messages.py`.

import 'dart:convert';

const String kProtocolVersion = '1.0';

enum PasteShortcut {
  auto('auto'),
  ctrlV('ctrl_v'),
  ctrlShiftV('ctrl_shift_v');

  const PasteShortcut(this.wireValue);
  final String wireValue;

  static PasteShortcut fromWire(String? value) {
    return PasteShortcut.values.firstWhere(
      (e) => e.wireValue == value,
      orElse: () => PasteShortcut.auto,
    );
  }
}

class WindowBounds {
  const WindowBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  factory WindowBounds.fromJson(Map<String, dynamic> json) => WindowBounds(
        x: (json['x'] as num).toInt(),
        y: (json['y'] as num).toInt(),
        width: (json['width'] as num).toInt(),
        height: (json['height'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

class WindowInfo {
  const WindowInfo({
    required this.id,
    required this.title,
    required this.app,
    this.pid,
    this.isActive = false,
    this.isMinimized = false,
    this.isTerminal = false,
    this.bounds,
  });

  final String id;
  final String title;
  final String app;
  final int? pid;
  final bool isActive;
  final bool isMinimized;
  final bool isTerminal;
  final WindowBounds? bounds;

  factory WindowInfo.fromJson(Map<String, dynamic> json) => WindowInfo(
        id: json['id'].toString(),
        title: (json['title'] as String?) ?? '',
        app: (json['app'] as String?) ?? '',
        pid: (json['pid'] as num?)?.toInt(),
        isActive: (json['is_active'] as bool?) ?? false,
        isMinimized: (json['is_minimized'] as bool?) ?? false,
        isTerminal: (json['is_terminal'] as bool?) ?? false,
        bounds: json['bounds'] is Map<String, dynamic>
            ? WindowBounds.fromJson(json['bounds'] as Map<String, dynamic>)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'app': app,
        if (pid != null) 'pid': pid,
        'is_active': isActive,
        'is_minimized': isMinimized,
        'is_terminal': isTerminal,
        if (bounds != null) 'bounds': bounds!.toJson(),
      };
}

class HostCapabilities {
  const HostCapabilities({
    this.windowEnum = true,
    this.windowFocus = true,
    this.clipboardInject = true,
    this.webrtcScreen = false,
    this.webrtcWindow = false,
    this.virtualMic = false,
  });

  final bool windowEnum;
  final bool windowFocus;
  final bool clipboardInject;
  final bool webrtcScreen;
  final bool webrtcWindow;
  final bool virtualMic;

  factory HostCapabilities.fromJson(Map<String, dynamic> json) =>
      HostCapabilities(
        windowEnum: (json['window_enum'] as bool?) ?? true,
        windowFocus: (json['window_focus'] as bool?) ?? true,
        clipboardInject: (json['clipboard_inject'] as bool?) ?? true,
        webrtcScreen: (json['webrtc_screen'] as bool?) ?? false,
        webrtcWindow: (json['webrtc_window'] as bool?) ?? false,
        virtualMic: (json['virtual_mic'] as bool?) ?? false,
      );
}

class HostInfo {
  const HostInfo({
    required this.hostname,
    required this.os,
    required this.displayServer,
    this.capabilities = const HostCapabilities(),
  });

  final String hostname;
  final String os;
  final String displayServer;
  final HostCapabilities capabilities;

  factory HostInfo.fromJson(Map<String, dynamic> json) => HostInfo(
        hostname: (json['hostname'] as String?) ?? 'unknown',
        os: (json['os'] as String?) ?? 'unknown',
        displayServer: (json['display_server'] as String?) ?? 'unknown',
        capabilities: json['capabilities'] is Map<String, dynamic>
            ? HostCapabilities.fromJson(
                json['capabilities'] as Map<String, dynamic>,
              )
            : const HostCapabilities(),
      );
}

sealed class ProtocolMessage {
  const ProtocolMessage({this.requestId, this.timestamp});

  final String? requestId;
  final int? timestamp;

  String get type;

  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());

  Map<String, dynamic> envelope() => {
        'type': type,
        if (requestId != null) 'request_id': requestId,
        if (timestamp != null) 'timestamp': timestamp,
      };
}

class AuthMessage extends ProtocolMessage {
  const AuthMessage({
    required this.token,
    this.clientName = 'unknown',
    this.platform = 'unknown',
    super.requestId,
    super.timestamp,
  });

  final String token;
  final String clientName;
  final String platform;

  @override
  String get type => 'auth';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'token': token,
        'client_name': clientName,
        'platform': platform,
      };
}

class AuthAckMessage extends ProtocolMessage {
  const AuthAckMessage({
    required this.ok,
    this.protocolVersion = kProtocolVersion,
    this.hostInfo,
    super.requestId,
    super.timestamp,
  });

  final bool ok;
  final String protocolVersion;
  final HostInfo? hostInfo;

  @override
  String get type => 'auth_ack';

  factory AuthAckMessage.fromJson(Map<String, dynamic> json) => AuthAckMessage(
        ok: (json['ok'] as bool?) ?? false,
        protocolVersion:
            (json['protocol_version'] as String?) ?? kProtocolVersion,
        hostInfo: json['host_info'] is Map<String, dynamic>
            ? HostInfo.fromJson(json['host_info'] as Map<String, dynamic>)
            : null,
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'ok': ok,
        'protocol_version': protocolVersion,
      };
}

class PingMessage extends ProtocolMessage {
  const PingMessage({super.requestId, super.timestamp});

  @override
  String get type => 'ping';

  @override
  Map<String, dynamic> toJson() => envelope();
}

class PongMessage extends ProtocolMessage {
  const PongMessage({
    required this.serverTimestamp,
    super.requestId,
    super.timestamp,
  });

  final int serverTimestamp;

  @override
  String get type => 'pong';

  factory PongMessage.fromJson(Map<String, dynamic> json) => PongMessage(
        serverTimestamp: (json['server_timestamp'] as num?)?.toInt() ?? 0,
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'server_timestamp': serverTimestamp,
      };
}

class ErrorMessage extends ProtocolMessage {
  const ErrorMessage({
    required this.code,
    required this.message,
    this.details = const {},
    super.requestId,
    super.timestamp,
  });

  final String code;
  final String message;
  final Map<String, dynamic> details;

  @override
  String get type => 'error';

  factory ErrorMessage.fromJson(Map<String, dynamic> json) => ErrorMessage(
        code: (json['code'] as String?) ?? 'INTERNAL_ERROR',
        message: (json['message'] as String?) ?? '',
        details: (json['details'] as Map<String, dynamic>?) ?? const {},
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'code': code,
        'message': message,
        'details': details,
      };
}

class GetWindowsMessage extends ProtocolMessage {
  const GetWindowsMessage({
    this.includeMinimized = false,
    super.requestId,
    super.timestamp,
  });

  final bool includeMinimized;

  @override
  String get type => 'get_windows';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'include_minimized': includeMinimized,
      };
}

class WindowListMessage extends ProtocolMessage {
  const WindowListMessage({
    required this.data,
    super.requestId,
    super.timestamp,
  });

  final List<WindowInfo> data;

  @override
  String get type => 'window_list';

  factory WindowListMessage.fromJson(Map<String, dynamic> json) {
    final rawList = (json['data'] as List<dynamic>?) ?? const [];
    return WindowListMessage(
      data: rawList
          .whereType<Map<String, dynamic>>()
          .map(WindowInfo.fromJson)
          .toList(),
      requestId: json['request_id'] as String?,
      timestamp: (json['timestamp'] as num?)?.toInt(),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'data': data.map((w) => w.toJson()).toList(),
      };
}

class FocusWindowMessage extends ProtocolMessage {
  const FocusWindowMessage({
    required this.targetWindowId,
    super.requestId,
    super.timestamp,
  });

  final String targetWindowId;

  @override
  String get type => 'focus_window';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'target_window_id': targetWindowId,
      };
}

class FocusResultMessage extends ProtocolMessage {
  const FocusResultMessage({
    required this.ok,
    required this.targetWindowId,
    super.requestId,
    super.timestamp,
  });

  final bool ok;
  final String targetWindowId;

  @override
  String get type => 'focus_result';

  factory FocusResultMessage.fromJson(Map<String, dynamic> json) =>
      FocusResultMessage(
        ok: (json['ok'] as bool?) ?? false,
        targetWindowId: (json['target_window_id'] as String?) ?? '',
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'ok': ok,
        'target_window_id': targetWindowId,
      };
}

class InjectTextMessage extends ProtocolMessage {
  const InjectTextMessage({
    required this.text,
    this.targetWindowId,
    this.autoEnter = false,
    this.pasteShortcut = PasteShortcut.auto,
    this.restoreClipboard = true,
    this.enterDelayMs = 80,
    this.source = 'stt_final',
    super.requestId,
    super.timestamp,
  });

  final String? targetWindowId;
  final String text;
  final bool autoEnter;
  final PasteShortcut pasteShortcut;
  final bool restoreClipboard;
  final int enterDelayMs;
  final String source;

  @override
  String get type => 'inject_text';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'target_window_id': targetWindowId,
        'text': text,
        'auto_enter': autoEnter,
        'paste_shortcut': pasteShortcut.wireValue,
        'restore_clipboard': restoreClipboard,
        'enter_delay_ms': enterDelayMs,
        'source': source,
      };
}

class InjectResultMessage extends ProtocolMessage {
  const InjectResultMessage({
    required this.ok,
    this.targetWindowId,
    this.injectedChars = 0,
    this.shortcutUsed = 'ctrl_v',
    this.autoEnterSent = false,
    this.elapsedMs = 0,
    super.requestId,
    super.timestamp,
  });

  final bool ok;
  final String? targetWindowId;
  final int injectedChars;
  final String shortcutUsed;
  final bool autoEnterSent;
  final int elapsedMs;

  @override
  String get type => 'inject_result';

  factory InjectResultMessage.fromJson(Map<String, dynamic> json) =>
      InjectResultMessage(
        ok: (json['ok'] as bool?) ?? false,
        targetWindowId: json['target_window_id'] as String?,
        injectedChars: (json['injected_chars'] as num?)?.toInt() ?? 0,
        shortcutUsed: (json['shortcut_used'] as String?) ?? 'ctrl_v',
        autoEnterSent: (json['auto_enter_sent'] as bool?) ?? false,
        elapsedMs: (json['elapsed_ms'] as num?)?.toInt() ?? 0,
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'ok': ok,
        'target_window_id': targetWindowId,
        'injected_chars': injectedChars,
        'shortcut_used': shortcutUsed,
        'auto_enter_sent': autoEnterSent,
        'elapsed_ms': elapsedMs,
      };
}

class SttPartialMessage extends ProtocolMessage {
  const SttPartialMessage({
    required this.text,
    this.isFinal = false,
    super.requestId,
    super.timestamp,
  });

  final String text;
  final bool isFinal;

  @override
  String get type => 'stt_partial';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'text': text,
        'is_final': isFinal,
      };
}

class StartStreamMessage extends ProtocolMessage {
  const StartStreamMessage({
    this.mode = 'window',
    this.transport = 'ws_mjpeg',
    this.targetWindowId,
    this.monitorIndex = 0,
    this.fps = 12,
    this.maxBitrateKbps = 4000,
    this.codec = 'vp8',
    this.quality = 62,
    this.maxWidth = 960,
    super.requestId,
    super.timestamp,
  });

  final String mode;
  final String transport; // 'ws_mjpeg' | 'webrtc'
  final String? targetWindowId;
  final int monitorIndex;
  final int fps;
  final int maxBitrateKbps;
  final String codec;
  final int quality;
  final int maxWidth;

  @override
  String get type => 'start_stream';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'mode': mode,
        'transport': transport,
        'target_window_id': targetWindowId,
        'monitor_index': monitorIndex,
        'fps': fps,
        'max_bitrate_kbps': maxBitrateKbps,
        'codec': codec,
        'quality': quality,
        'max_width': maxWidth,
      };
}

class StopStreamMessage extends ProtocolMessage {
  const StopStreamMessage({
    this.streamId,
    super.requestId,
    super.timestamp,
  });

  final String? streamId;

  @override
  String get type => 'stop_stream';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        if (streamId != null) 'stream_id': streamId,
      };
}

class StreamStateMessage extends ProtocolMessage {
  const StreamStateMessage({
    required this.status,
    this.streamId,
    this.mode,
    this.transport,
    this.targetWindowId,
    this.width,
    this.height,
    this.fps,
    this.error,
    super.requestId,
    super.timestamp,
  });

  final String status;
  final String? streamId;
  final String? mode;
  final String? transport;
  final String? targetWindowId;
  final int? width;
  final int? height;
  final int? fps;
  final String? error;

  @override
  String get type => 'stream_state';

  factory StreamStateMessage.fromJson(Map<String, dynamic> json) =>
      StreamStateMessage(
        status: (json['status'] as String?) ?? 'stopped',
        streamId: json['stream_id'] as String?,
        mode: json['mode'] as String?,
        transport: json['transport'] as String?,
        targetWindowId: json['target_window_id'] as String?,
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
        fps: (json['fps'] as num?)?.toInt(),
        error: json['error'] as String?,
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'status': status,
        if (streamId != null) 'stream_id': streamId,
        if (mode != null) 'mode': mode,
        if (transport != null) 'transport': transport,
        if (targetWindowId != null) 'target_window_id': targetWindowId,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (fps != null) 'fps': fps,
        if (error != null) 'error': error,
      };
}

class WebRTCSignalMessage extends ProtocolMessage {
  const WebRTCSignalMessage({
    required this.signalType,
    this.streamId,
    this.sdp,
    this.sdpType,
    this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
    super.requestId,
    super.timestamp,
  });

  final String signalType; // webrtc_offer | webrtc_answer | webrtc_ice
  final String? streamId;
  final String? sdp;
  final String? sdpType;
  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  @override
  String get type => signalType;

  factory WebRTCSignalMessage.fromJson(Map<String, dynamic> json) =>
      WebRTCSignalMessage(
        signalType: json['type'] as String,
        streamId: json['stream_id'] as String?,
        sdp: json['sdp'] as String?,
        sdpType: json['sdp_type'] as String?,
        candidate: json['candidate'] as String?,
        sdpMid: json['sdp_mid'] as String?,
        sdpMLineIndex: (json['sdp_m_line_index'] as num?)?.toInt(),
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        if (streamId != null) 'stream_id': streamId,
        if (sdp != null) 'sdp': sdp,
        if (sdpType != null) 'sdp_type': sdpType,
        if (candidate != null) 'candidate': candidate,
        if (sdpMid != null) 'sdp_mid': sdpMid,
        if (sdpMLineIndex != null) 'sdp_m_line_index': sdpMLineIndex,
      };
}

class InputPointerMessage extends ProtocolMessage {
  const InputPointerMessage({
    required this.action,
    required this.xNorm,
    required this.yNorm,
    this.button = 'left',
    this.deltaX = 0.0,
    this.deltaY = 0.0,
    this.targetWindowId,
    super.requestId,
    super.timestamp,
  });

  final String action;
  final String button;
  final double xNorm;
  final double yNorm;
  final double deltaX;
  final double deltaY;
  final String? targetWindowId;

  @override
  String get type => 'input_pointer';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'action': action,
        'button': button,
        'x_norm': xNorm,
        'y_norm': yNorm,
        'delta_x': deltaX,
        'delta_y': deltaY,
        if (targetWindowId != null) 'target_window_id': targetWindowId,
      };
}

class InputKeyMessage extends ProtocolMessage {
  const InputKeyMessage({
    required this.key,
    this.modifiers = const [],
    this.targetWindowId,
    super.requestId,
    super.timestamp,
  });

  final String key;
  final List<String> modifiers;
  final String? targetWindowId;

  @override
  String get type => 'input_key';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'key': key,
        'modifiers': modifiers,
        if (targetWindowId != null) 'target_window_id': targetWindowId,
      };
}

class AudioBridgeStartMessage extends ProtocolMessage {
  const AudioBridgeStartMessage({
    this.transport = 'webrtc_audio',
    this.codec = 'opus',
    this.sampleRate = 48000,
    this.channels = 1,
    this.frameDurationMs = 20,
    this.targetWindowId,
    this.autoTriggerVoice = true,
    super.requestId,
    super.timestamp,
  });

  final String transport;
  final String codec;
  final int sampleRate;
  final int channels;
  final int frameDurationMs;
  final String? targetWindowId;
  final bool autoTriggerVoice;

  @override
  String get type => 'audio_bridge_start';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'transport': transport,
        'codec': codec,
        'sample_rate': sampleRate,
        'channels': channels,
        'frame_duration_ms': frameDurationMs,
        if (targetWindowId != null) 'target_window_id': targetWindowId,
        'auto_trigger_voice': autoTriggerVoice,
      };
}

class AudioBridgeStopMessage extends ProtocolMessage {
  const AudioBridgeStopMessage({
    this.targetWindowId,
    this.autoTriggerVoice = false,
    super.requestId,
    super.timestamp,
  });

  final String? targetWindowId;
  final bool autoTriggerVoice;

  @override
  String get type => 'audio_bridge_stop';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        if (targetWindowId != null) 'target_window_id': targetWindowId,
        'auto_trigger_voice': autoTriggerVoice,
      };
}

class AudioBridgeStateMessage extends ProtocolMessage {
  const AudioBridgeStateMessage({
    required this.status,
    this.virtualDevice,
    this.voiceTriggered = false,
    this.error,
    super.requestId,
    super.timestamp,
  });

  final String status;
  final String? virtualDevice;
  final bool voiceTriggered;
  final String? error;

  @override
  String get type => 'audio_bridge_state';

  factory AudioBridgeStateMessage.fromJson(Map<String, dynamic> json) =>
      AudioBridgeStateMessage(
        status: (json['status'] as String?) ?? 'idle',
        virtualDevice: json['virtual_device'] as String?,
        voiceTriggered: (json['voice_triggered'] as bool?) ?? false,
        error: json['error'] as String?,
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'status': status,
        if (virtualDevice != null) 'virtual_device': virtualDevice,
        'voice_triggered': voiceTriggered,
        if (error != null) 'error': error,
      };
}

class InputBoxItem {
  const InputBoxItem({
    this.name = '',
    this.text = '',
    this.focused = false,
  });

  final String name;
  final String text;
  final bool focused;

  factory InputBoxItem.fromJson(Map<String, dynamic> json) => InputBoxItem(
        name: (json['name'] as String?) ?? '',
        text: (json['text'] as String?) ?? '',
        focused: (json['focused'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'text': text,
        'focused': focused,
      };
}

class DiffChangeItem {
  const DiffChangeItem({
    required this.filePath,
    this.kind = 'edit',
    this.summary = '',
    this.diffPreview = '',
  });

  final String filePath;
  final String kind; // 'edit' | 'write' | 'command'
  final String summary;
  final String diffPreview;

  factory DiffChangeItem.fromJson(Map<String, dynamic> json) => DiffChangeItem(
        filePath: (json['file_path'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'edit',
        summary: (json['summary'] as String?) ?? '',
        diffPreview: (json['diff_preview'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'file_path': filePath,
        'kind': kind,
        'summary': summary,
        'diff_preview': diffPreview,
      };
}

class PendingQuestionItem {
  const PendingQuestionItem({
    required this.question,
    this.options = const [],
    this.isMultiSelect = false,
  });

  final String question;
  final List<String> options;
  final bool isMultiSelect;

  factory PendingQuestionItem.fromJson(Map<String, dynamic> json) {
    final rawOpts = (json['options'] as List<dynamic>?) ?? const [];
    return PendingQuestionItem(
      question: (json['question'] as String?) ?? '',
      options: rawOpts.map((e) => e.toString()).toList(),
      isMultiSelect: (json['is_multi_select'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'question': question,
        'options': options,
        'is_multi_select': isMultiSelect,
      };
}

/// File referenced by a dialog turn that can be previewed / played / downloaded.
/// `url` is host-relative (`/api/media?path=...`) and needs the host token appended.
class MediaAttachment {
  const MediaAttachment({
    required this.url,
    this.kind = 'file',
    this.name = '',
    this.mime = '',
    this.size = 0,
    this.path = '',
  });

  final String url;

  /// image | audio | video | file
  final String kind;
  final String name;
  final String mime;
  final int size;
  final String path;

  bool get isImage => kind == 'image';
  bool get isAudio => kind == 'audio';
  bool get isVideo => kind == 'video';

  String get displayName {
    if (name.isNotEmpty) return name;
    final segs = path.split(RegExp(r'[\\/]'));
    return segs.isNotEmpty && segs.last.isNotEmpty ? segs.last : '文件';
  }

  factory MediaAttachment.fromJson(Map<String, dynamic> json) => MediaAttachment(
        url: (json['url'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'file',
        name: (json['name'] as String?) ?? '',
        mime: (json['mime'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        path: (json['path'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'kind': kind,
        'name': name,
        'mime': mime,
        'size': size,
        'path': path,
      };
}

class DialogBlockItem {
  const DialogBlockItem({
    this.role = 'text',
    required this.text,
    this.thinking = '',
    this.toolCalls = const [],
    this.diffItems = const [],
    this.images = const [],
    this.attachments = const [],
    this.timestamp = '',
    this.model = '',
  });

  final String role;
  final String text;
  final String thinking;
  final List<String> toolCalls;
  final List<DiffChangeItem> diffItems;
  final List<String> images;
  final List<MediaAttachment> attachments;
  final String timestamp;
  final String model;

  factory DialogBlockItem.fromJson(Map<String, dynamic> json) {
    final rawTools = (json['tool_calls'] as List<dynamic>?) ?? const [];
    final rawDiffs = (json['diff_items'] as List<dynamic>?) ?? const [];
    final rawImages = (json['images'] as List<dynamic>?) ?? const [];
    final rawAttachments = (json['attachments'] as List<dynamic>?) ?? const [];
    return DialogBlockItem(
      role: (json['role'] as String?) ?? 'text',
      text: (json['text'] as String?) ?? '',
      thinking: (json['thinking'] as String?) ?? '',
      toolCalls: rawTools.map((e) => e.toString()).toList(),
      diffItems: rawDiffs
          .whereType<Map<String, dynamic>>()
          .map(DiffChangeItem.fromJson)
          .toList(),
      images: rawImages
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList(),
      attachments: rawAttachments
          .whereType<Map<String, dynamic>>()
          .map(MediaAttachment.fromJson)
          .where((a) => a.url.isNotEmpty)
          .toList(),
      timestamp: (json['timestamp'] as String?) ?? '',
      model: (json['model'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'thinking': thinking,
        'tool_calls': toolCalls,
        'diff_items': diffItems.map((d) => d.toJson()).toList(),
        'images': images,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'timestamp': timestamp,
        'model': model,
      };
}

String buildFullTextFromBlocks(
  List<DialogBlockItem> blocks, {
  int maxChars = 40000,
}) {
  final parts = <String>[];
  for (final b in blocks) {
    final txt = b.text.trim();
    if (txt.isEmpty) continue;
    if (b.role == 'user') {
      parts.add('【我】$txt');
    } else if (b.role == 'assistant') {
      parts.add('【AI】$txt');
    } else {
      parts.add(txt);
    }
  }
  final joined = parts.join('\n\n');
  if (joined.length <= maxChars) return joined;
  final tailLen = (maxChars - 16).clamp(0, joined.length);
  return '...(前文已截断)...\n${joined.substring(joined.length - tailLen)}';
}

class AgentSessionItem {
  const AgentSessionItem({
    required this.id,
    this.agent = 'antigravity',
    required this.title,
    this.updatedAt = '',
    this.turnCount = 0,
    this.projectId = '',
    this.projectName = '',
    this.projectPath = '',
  });

  final String id;
  final String agent;
  final String title;
  final String updatedAt;
  final int turnCount;
  final String projectId;
  final String projectName;
  final String projectPath;

  factory AgentSessionItem.fromJson(Map<String, dynamic> json) =>
      AgentSessionItem(
        id: (json['id'] as String?) ?? '',
        agent: (json['agent'] as String?) ?? 'antigravity',
        title: (json['title'] as String?) ?? '',
        updatedAt: (json['updated_at'] as String?) ?? '',
        turnCount: (json['turn_count'] as num?)?.toInt() ?? 0,
        projectId: (json['project_id'] as String?) ?? '',
        projectName: (json['project_name'] as String?) ?? '',
        projectPath: (json['project_path'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'agent': agent,
        'title': title,
        'updated_at': updatedAt,
        'turn_count': turnCount,
        if (projectId.isNotEmpty) 'project_id': projectId,
        if (projectName.isNotEmpty) 'project_name': projectName,
        if (projectPath.isNotEmpty) 'project_path': projectPath,
      };
}

class ProjectItem {
  const ProjectItem({
    required this.id,
    required this.name,
    this.path = '',
    this.description = '',
    this.createdAt = '',
    this.defaultIde = 'antigravity',
    this.exists = true,
    this.isGit = false,
    this.isCustom = false,
    this.sessionCount = 0,
    this.lastActiveAt = '',
  });

  final String id;
  final String name;
  final String path;
  final String description;
  final String createdAt;
  final String defaultIde;
  final bool exists;
  final bool isGit;
  final bool isCustom;
  final int sessionCount;
  final String lastActiveAt;

  factory ProjectItem.fromJson(Map<String, dynamic> json) => ProjectItem(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        path: (json['path'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
        defaultIde: (json['default_ide'] as String?) ?? 'antigravity',
        exists: json['exists'] != false,
        isGit: json['is_git'] == true,
        isCustom: json['is_custom'] == true,
        sessionCount: (json['session_count'] as num?)?.toInt() ?? 0,
        lastActiveAt: (json['last_active_at'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'description': description,
        'created_at': createdAt,
        'default_ide': defaultIde,
        'exists': exists,
        'is_git': isGit,
        'is_custom': isCustom,
        'session_count': sessionCount,
        'last_active_at': lastActiveAt,
      };
}

class GetWindowContentMessage extends ProtocolMessage {
  const GetWindowContentMessage({
    this.targetWindowId,
    this.sessionId,
    this.methods = const ['transcript', 'uia'],
    this.maxChars = 40000,
    this.supportsDelta = false,
    this.knownSessionId,
    this.knownBlockCount = 0,
    this.knownPrefixHash = '',
    this.knownLastHash = '',
    super.requestId,
    super.timestamp,
  });

  final String? targetWindowId;
  final String? sessionId;
  final List<String> methods;
  final int maxChars;
  final bool supportsDelta;
  final String? knownSessionId;
  final int knownBlockCount;
  final String knownPrefixHash;
  final String knownLastHash;

  @override
  String get type => 'get_window_content';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'target_window_id': targetWindowId,
        if (sessionId != null) 'session_id': sessionId,
        'methods': methods,
        'max_chars': maxChars,
        if (supportsDelta) 'supports_delta': true,
        if (knownSessionId != null && knownSessionId!.isNotEmpty)
          'known_session_id': knownSessionId,
        if (knownBlockCount > 0) 'known_block_count': knownBlockCount,
        if (knownPrefixHash.isNotEmpty) 'known_prefix_hash': knownPrefixHash,
        if (knownLastHash.isNotEmpty) 'known_last_hash': knownLastHash,
      };
}

class WindowContentMessage extends ProtocolMessage {
  const WindowContentMessage({
    this.targetWindowId,
    this.windowTitle = '',
    this.app = '',
    this.methodUsed = 'none',
    this.agentName = '',
    this.activeSessionId,
    this.activeModel = '',
    this.availableModels = const [],
    this.agentStatus = 'idle',
    this.pendingApprovalText = '',
    this.pendingQuestions = const [],
    this.queuedMessages = const [],
    this.actionButtons = const [],
    this.sessions = const [],
    this.inputBoxes = const [],
    this.dialogBlocks = const [],
    this.fullText = '',
    this.isDelta = false,
    this.deltaFromIndex = 0,
    this.totalBlockCount = 0,
    this.syncPrefixHash = '',
    this.syncLastHash = '',
    this.elapsedMs = 0,
    this.note,
    super.requestId,
    super.timestamp,
  });

  final String? targetWindowId;
  final String windowTitle;
  final String app;
  final String methodUsed;
  final String agentName;
  final String? activeSessionId;
  final String activeModel;
  final List<String> availableModels;
  final String agentStatus; // 'idle' | 'working' | 'waiting_approval'
  final String pendingApprovalText;
  final List<PendingQuestionItem> pendingQuestions;
  final List<String> queuedMessages;
  final List<String> actionButtons;
  final List<AgentSessionItem> sessions;
  final List<InputBoxItem> inputBoxes;
  final List<DialogBlockItem> dialogBlocks;
  final String fullText;
  final bool isDelta;
  final int deltaFromIndex;
  final int totalBlockCount;
  final String syncPrefixHash;
  final String syncLastHash;
  final int elapsedMs;
  final String? note;

  @override
  String get type => 'window_content';

  factory WindowContentMessage.fromJson(Map<String, dynamic> json) {
    final rawInputs = (json['input_boxes'] as List<dynamic>?) ?? const [];
    final rawDialogs = (json['dialog_blocks'] as List<dynamic>?) ?? const [];
    final rawSessions = (json['sessions'] as List<dynamic>?) ?? const [];
    final rawModels = (json['available_models'] as List<dynamic>?) ?? const [];
    final rawQuestions = (json['pending_questions'] as List<dynamic>?) ?? const [];
    final rawQueued = (json['queued_messages'] as List<dynamic>?) ?? const [];
    final rawActions = (json['action_buttons'] as List<dynamic>?) ?? const [];
    return WindowContentMessage(
      targetWindowId: json['target_window_id'] as String?,
      windowTitle: (json['window_title'] as String?) ?? '',
      app: (json['app'] as String?) ?? '',
      methodUsed: (json['method_used'] as String?) ?? 'none',
      agentName: (json['agent_name'] as String?) ?? '',
      activeSessionId: json['active_session_id'] as String?,
      activeModel: (json['active_model'] as String?) ?? '',
      availableModels: rawModels.map((e) => e.toString()).toList(),
      agentStatus: (json['agent_status'] as String?) ?? 'idle',
      pendingApprovalText: (json['pending_approval_text'] as String?) ?? '',
      pendingQuestions: rawQuestions
          .whereType<Map<String, dynamic>>()
          .map(PendingQuestionItem.fromJson)
          .toList(),
      queuedMessages: rawQueued
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList(),
      actionButtons: rawActions.map((e) => e.toString()).toList(),
      sessions: rawSessions
          .whereType<Map<String, dynamic>>()
          .map(AgentSessionItem.fromJson)
          .toList(),
      inputBoxes: rawInputs
          .whereType<Map<String, dynamic>>()
          .map(InputBoxItem.fromJson)
          .toList(),
      dialogBlocks: rawDialogs
          .whereType<Map<String, dynamic>>()
          .map(DialogBlockItem.fromJson)
          .toList(),
      fullText: (json['full_text'] as String?) ?? '',
      isDelta: (json['is_delta'] as bool?) ?? false,
      deltaFromIndex: (json['delta_from_index'] as num?)?.toInt() ?? 0,
      totalBlockCount: (json['total_block_count'] as num?)?.toInt() ?? 0,
      syncPrefixHash: (json['sync_prefix_hash'] as String?) ?? '',
      syncLastHash: (json['sync_last_hash'] as String?) ?? '',
      elapsedMs: (json['elapsed_ms'] as num?)?.toInt() ?? 0,
      note: json['note'] as String?,
      requestId: json['request_id'] as String?,
      timestamp: (json['timestamp'] as num?)?.toInt(),
    );
  }

  @override
  Map<String, dynamic> toJson({bool includeFullText = false}) => {
        ...envelope(),
        'target_window_id': targetWindowId,
        'window_title': windowTitle,
        'app': app,
        'method_used': methodUsed,
        'agent_name': agentName,
        'active_session_id': activeSessionId,
        'active_model': activeModel,
        'available_models': availableModels,
        'agent_status': agentStatus,
        'pending_approval_text': pendingApprovalText,
        'pending_questions': pendingQuestions.map((q) => q.toJson()).toList(),
        'queued_messages': queuedMessages,
        'action_buttons': actionButtons,
        'sessions': sessions.map((s) => s.toJson()).toList(),
        'input_boxes': inputBoxes.map((b) => b.toJson()).toList(),
        'dialog_blocks': dialogBlocks.map((d) => d.toJson()).toList(),
        if (includeFullText) 'full_text': fullText,
        'is_delta': isDelta,
        'delta_from_index': deltaFromIndex,
        'total_block_count': totalBlockCount,
        'sync_prefix_hash': syncPrefixHash,
        'sync_last_hash': syncLastHash,
        'elapsed_ms': elapsedMs,
        if (note != null) 'note': note,
      };

  Map<String, dynamic> toCacheJson() => toJson(includeFullText: false);
}

class GetSnapshotMessage extends ProtocolMessage {
  const GetSnapshotMessage({
    this.mode = 'window',
    this.targetWindowId,
    this.monitorIndex = 0,
    this.quality = 70,
    this.maxWidth = 1280,
    super.requestId,
    super.timestamp,
  });

  final String mode;
  final String? targetWindowId;
  final int monitorIndex;
  final int quality;
  final int maxWidth;

  @override
  String get type => 'get_snapshot';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'mode': mode,
        'target_window_id': targetWindowId,
        'monitor_index': monitorIndex,
        'quality': quality,
        'max_width': maxWidth,
      };
}

class WindowSnapshotMessage extends ProtocolMessage {
  const WindowSnapshotMessage({
    this.targetWindowId,
    this.mode = 'window',
    this.width = 0,
    this.height = 0,
    this.mimeType = 'image/jpeg',
    this.imageBase64 = '',
    this.elapsedMs = 0,
    super.requestId,
    super.timestamp,
  });

  final String? targetWindowId;
  final String mode;
  final int width;
  final int height;
  final String mimeType;
  final String imageBase64;
  final int elapsedMs;

  @override
  String get type => 'window_snapshot';

  factory WindowSnapshotMessage.fromJson(Map<String, dynamic> json) =>
      WindowSnapshotMessage(
        targetWindowId: json['target_window_id'] as String?,
        mode: (json['mode'] as String?) ?? 'window',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        mimeType: (json['mime_type'] as String?) ?? 'image/jpeg',
        imageBase64: (json['image_base64'] as String?) ?? '',
        elapsedMs: (json['elapsed_ms'] as num?)?.toInt() ?? 0,
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'target_window_id': targetWindowId,
        'mode': mode,
        'width': width,
        'height': height,
        'mime_type': mimeType,
        'image_base64': imageBase64,
        'elapsed_ms': elapsedMs,
      };
}

class SyncDraftMessage extends ProtocolMessage {
  const SyncDraftMessage({
    this.targetWindowId,
    this.text = '',
    super.requestId,
    super.timestamp,
  });

  final String? targetWindowId;
  final String text;

  @override
  String get type => 'sync_draft';

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'target_window_id': targetWindowId,
        'text': text,
      };
}

class DraftUpdateMessage extends ProtocolMessage {
  const DraftUpdateMessage({
    this.targetWindowId,
    this.text = '',
    this.method = 'none',
    super.requestId,
    super.timestamp,
  });

  final String? targetWindowId;
  final String text;
  final String method;

  @override
  String get type => 'draft_update';

  factory DraftUpdateMessage.fromJson(Map<String, dynamic> json) =>
      DraftUpdateMessage(
        targetWindowId: json['target_window_id'] as String?,
        text: (json['text'] as String?) ?? '',
        method: (json['method'] as String?) ?? 'none',
        requestId: json['request_id'] as String?,
        timestamp: (json['timestamp'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        ...envelope(),
        'target_window_id': targetWindowId,
        'text': text,
        'method': method,
      };
}

ProtocolMessage? parseHostMessage(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! Map<String, dynamic>) return null;
  return switch (decoded['type']) {
    'auth_ack' => AuthAckMessage.fromJson(decoded),
    'pong' => PongMessage.fromJson(decoded),
    'error' => ErrorMessage.fromJson(decoded),
    'window_list' => WindowListMessage.fromJson(decoded),
    'focus_result' => FocusResultMessage.fromJson(decoded),
    'inject_result' => InjectResultMessage.fromJson(decoded),
    'stream_state' => StreamStateMessage.fromJson(decoded),
    'webrtc_offer' ||
    'webrtc_answer' ||
    'webrtc_ice' =>
      WebRTCSignalMessage.fromJson(decoded),
    'audio_bridge_state' => AudioBridgeStateMessage.fromJson(decoded),
    'window_content' => WindowContentMessage.fromJson(decoded),
    'window_snapshot' => WindowSnapshotMessage.fromJson(decoded),
    'draft_update' => DraftUpdateMessage.fromJson(decoded),
    _ => null,
  };
}
