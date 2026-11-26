import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/vibe_socket_client.dart';
import '../../protocol/messages.dart';
import '../connection/connection_controller.dart';
import '../windows/window_controller.dart';
import 'chat_cache_store.dart';

class WindowContentState {
  const WindowContentState({
    this.isLoadingContent = false,
    this.isLoadingSnapshot = false,
    this.autoRefresh = false,
    this.methodMode = 'auto', // 'auto' (transcript+uia) | 'transcript' | 'uia'
    this.selectedSessionId,
    this.awaitingNewSession = false,
    this.previousSessionIdBeforeNew,
    this.dismissedQuestionsSignature,
    this.content,
    this.snapshotBytes,
    this.snapshotWidth = 1280,
    this.snapshotHeight = 720,
    this.snapshotElapsedMs = 0,
    this.error,
  });

  final bool isLoadingContent;
  final bool isLoadingSnapshot;
  final bool autoRefresh;
  final String methodMode;
  final String? selectedSessionId;
  final bool awaitingNewSession;
  final String? previousSessionIdBeforeNew;
  final String? dismissedQuestionsSignature;
  final WindowContentMessage? content;
  final Uint8List? snapshotBytes;
  final int snapshotWidth;
  final int snapshotHeight;
  final int snapshotElapsedMs;
  final String? error;

  double get snapshotAspectRatio =>
      snapshotHeight > 0 ? (snapshotWidth / snapshotHeight) : (16 / 9);

  WindowContentState copyWith({
    bool? isLoadingContent,
    bool? isLoadingSnapshot,
    bool? autoRefresh,
    String? methodMode,
    String? selectedSessionId,
    bool clearSelectedSession = false,
    bool? awaitingNewSession,
    String? previousSessionIdBeforeNew,
    bool clearPreviousSessionId = false,
    String? dismissedQuestionsSignature,
    bool clearDismissedQuestions = false,
    WindowContentMessage? content,
    bool clearContent = false,
    Uint8List? snapshotBytes,
    bool clearSnapshot = false,
    int? snapshotWidth,
    int? snapshotHeight,
    int? snapshotElapsedMs,
    String? error,
    bool clearError = false,
  }) {
    return WindowContentState(
      isLoadingContent: isLoadingContent ?? this.isLoadingContent,
      isLoadingSnapshot: isLoadingSnapshot ?? this.isLoadingSnapshot,
      autoRefresh: autoRefresh ?? this.autoRefresh,
      methodMode: methodMode ?? this.methodMode,
      selectedSessionId: clearSelectedSession
          ? null
          : (selectedSessionId ?? this.selectedSessionId),
      awaitingNewSession: awaitingNewSession ?? this.awaitingNewSession,
      previousSessionIdBeforeNew: clearPreviousSessionId
          ? null
          : (previousSessionIdBeforeNew ?? this.previousSessionIdBeforeNew),
      dismissedQuestionsSignature: clearDismissedQuestions
          ? null
          : (dismissedQuestionsSignature ?? this.dismissedQuestionsSignature),
      content: clearContent ? null : (content ?? this.content),
      snapshotBytes:
          clearSnapshot ? null : (snapshotBytes ?? this.snapshotBytes),
      snapshotWidth: snapshotWidth ?? this.snapshotWidth,
      snapshotHeight: snapshotHeight ?? this.snapshotHeight,
      snapshotElapsedMs: snapshotElapsedMs ?? this.snapshotElapsedMs,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class WindowContentController extends StateNotifier<WindowContentState> {
  WindowContentController(this._ref) : super(const WindowContentState()) {
    _msgSub = _client.messages.listen(_onPushedHostMessage);
    unawaited(_hydrateInitialCache());
    _ref.listen<String>(
      settingsProvider.select((s) => s.activeHost.id),
      (prev, next) {
        if (prev == next) return;
        unawaited(_onActiveHostChanged(next));
      },
    );
    // Automatically clear old view and refresh both content & snapshot whenever target window changes
    _ref.listen<String?>(
      windowControllerProvider.select((s) => s.selectedWindowId),
      (prev, next) {
        if (prev == next) return;
        if (prev == null && next != null) {
          // Keep startup-hydrated cache on screen while checking for delta updates.
          if (_client.snapshot.isConnected) {
            unawaited(fetchContent(resetSession: true));
            unawaited(fetchSnapshot());
          }
          return;
        }
        if (next == null && !_client.snapshot.isConnected) {
          return;
        }
        state = state.copyWith(
          clearSelectedSession: true,
          awaitingNewSession: false,
          clearPreviousSessionId: true,
          clearDismissedQuestions: true,
          clearContent: true,
          clearSnapshot: true,
          clearError: true,
        );
        if (_client.snapshot.isConnected) {
          unawaited(fetchContent(resetSession: true));
          unawaited(fetchSnapshot());
        }
      },
    );
  }

  final Ref _ref;
  final ChatCacheStore _cacheStore = ChatCacheStore();
  Timer? _pollTimer;
  StreamSubscription<ProtocolMessage>? _msgSub;
  DateTime? _lastLiveSyncAt;
  bool _disposed = false;

  VibeSocketClient get _client => _ref.read(socketClientProvider);
  String get _activeHostId => _ref.read(settingsProvider).activeHost.id;
  bool hasLiveSyncSince(DateTime since) =>
      _lastLiveSyncAt != null && !_lastLiveSyncAt!.isBefore(since);

  Future<void> _hydrateInitialCache() async {
    await _ref.read(settingsProvider.notifier).ready;
    await _cacheStore.ensureLoaded();
    if (_disposed || state.content != null) return;
    final cached = _cacheStore.getLastForHost(_activeHostId);
    if (cached != null) {
      state = state.copyWith(
        content: cached,
        selectedSessionId: cached.activeSessionId,
        clearError: true,
      );
    }
  }

  Future<void> _onActiveHostChanged(String nextHostId) async {
    await _cacheStore.ensureLoaded();
    if (_disposed || _activeHostId != nextHostId) return;
    final cached = _cacheStore.getLastForHost(nextHostId);
    if (cached != null) {
      state = state.copyWith(
        selectedSessionId: cached.activeSessionId,
        awaitingNewSession: false,
        clearPreviousSessionId: true,
        clearDismissedQuestions: true,
        content: cached,
        clearSnapshot: true,
        clearError: true,
      );
    } else {
      state = state.copyWith(
        clearSelectedSession: true,
        awaitingNewSession: false,
        clearPreviousSessionId: true,
        clearDismissedQuestions: true,
        clearContent: true,
        clearSnapshot: true,
        clearError: true,
      );
    }
  }

  void dismissPendingQuestions(String signature) {
    if (signature.trim().isEmpty) return;
    state = state.copyWith(dismissedQuestionsSignature: signature);
  }

  WindowContentMessage? _resolveDeltaBase({
    required bool resetSession,
    required bool forceFull,
    String? incomingSessionId,
  }) {
    if (forceFull) return null;
    final targetSid = incomingSessionId ??
        (resetSession ? null : state.selectedSessionId);
    final cur = state.content;
    if (targetSid != null && targetSid.isNotEmpty) {
      if (cur != null && cur.activeSessionId == targetSid) {
        return cur;
      }
      return _cacheStore.getCached(_activeHostId, targetSid);
    }
    if (cur != null &&
        cur.activeSessionId != null &&
        cur.activeSessionId!.isNotEmpty) {
      return cur;
    }
    if (resetSession && !state.awaitingNewSession) {
      return _cacheStore.getLastForHost(_activeHostId);
    }
    return null;
  }

  WindowContentMessage? _mergeDelta(WindowContentMessage msg) {
    final sid = msg.activeSessionId;
    final base = _resolveDeltaBase(
      resetSession: false,
      forceFull: false,
      incomingSessionId: sid,
    );
    if (base == null ||
        msg.deltaFromIndex < 0 ||
        msg.deltaFromIndex > base.dialogBlocks.length ||
        (msg.totalBlockCount > 0 &&
            msg.deltaFromIndex + msg.dialogBlocks.length != msg.totalBlockCount)) {
      return null;
    }

    final mergedBlocks = <DialogBlockItem>[
      ...base.dialogBlocks.sublist(0, msg.deltaFromIndex),
      ...msg.dialogBlocks,
    ];
    final rebuiltFullText = msg.fullText.isNotEmpty
        ? msg.fullText
        : buildFullTextFromBlocks(mergedBlocks);
    return WindowContentMessage(
      targetWindowId: msg.targetWindowId ?? base.targetWindowId,
      windowTitle: msg.windowTitle.isNotEmpty ? msg.windowTitle : base.windowTitle,
      app: msg.app.isNotEmpty ? msg.app : base.app,
      methodUsed: msg.methodUsed != 'none' ? msg.methodUsed : base.methodUsed,
      agentName: msg.agentName.isNotEmpty ? msg.agentName : base.agentName,
      activeSessionId: msg.activeSessionId ?? base.activeSessionId,
      activeModel: msg.activeModel.isNotEmpty ? msg.activeModel : base.activeModel,
      availableModels: msg.availableModels.isNotEmpty
          ? msg.availableModels
          : base.availableModels,
      agentStatus: msg.agentStatus,
      pendingApprovalText: msg.pendingApprovalText,
      pendingQuestions: msg.pendingQuestions,
      queuedMessages: msg.queuedMessages,
      actionButtons: msg.actionButtons,
      sessions: msg.sessions.isNotEmpty ? msg.sessions : base.sessions,
      inputBoxes: msg.inputBoxes,
      dialogBlocks: mergedBlocks,
      fullText: rebuiltFullText,
      isDelta: false,
      deltaFromIndex: 0,
      totalBlockCount: msg.totalBlockCount > 0
          ? msg.totalBlockCount
          : mergedBlocks.length,
      syncPrefixHash: msg.syncPrefixHash,
      syncLastHash: msg.syncLastHash,
      elapsedMs: msg.elapsedMs,
      note: msg.note,
      requestId: msg.requestId,
      timestamp: msg.timestamp,
    );
  }

  void _cacheResolved(WindowContentMessage resolved) {
    final sid = resolved.activeSessionId;
    if (sid == null || sid.isEmpty || resolved.dialogBlocks.isEmpty) return;
    _cacheStore.put(
      _activeHostId,
      resolved,
      immediateFlush: resolved.agentStatus != 'working',
    );
  }

  WindowContentState _applyIncomingContent(WindowContentMessage msg) {
    late final WindowContentMessage resolved;
    if (msg.isDelta) {
      final merged = _mergeDelta(msg);
      if (merged == null) {
        if (!state.awaitingNewSession && _client.snapshot.isConnected) {
          unawaited(fetchContent(forceFull: true));
        }
        return state.copyWith(isLoadingContent: false);
      }
      resolved = merged;
    } else {
      resolved = msg;
    }

    _lastLiveSyncAt = DateTime.now();

    final incomingSig = resolved.pendingQuestions
        .map((q) => '${q.question}:${q.options.join(",")}')
        .join('|');
    final shouldClearDismissed =
        resolved.pendingQuestions.isEmpty ||
            (state.dismissedQuestionsSignature != null &&
                incomingSig != state.dismissedQuestionsSignature);
    if (state.awaitingNewSession) {
      final prevId = state.previousSessionIdBeforeNew;
      final nextId = resolved.activeSessionId;
      final switchedToFresh =
          nextId != null && nextId.isNotEmpty && nextId != prevId;
      if (!switchedToFresh) {
        final cur = state.content;
        final blankKeepingMeta = WindowContentMessage(
          targetWindowId: resolved.targetWindowId ?? cur?.targetWindowId,
          windowTitle: resolved.windowTitle.isNotEmpty
              ? resolved.windowTitle
              : (cur?.windowTitle ?? ''),
          app: resolved.app.isNotEmpty ? resolved.app : (cur?.app ?? ''),
          methodUsed: resolved.methodUsed,
          agentName: resolved.agentName.isNotEmpty
              ? resolved.agentName
              : (cur?.agentName ?? ''),
          activeSessionId: null,
          activeModel: resolved.activeModel.isNotEmpty
              ? resolved.activeModel
              : (cur?.activeModel ?? ''),
          availableModels: resolved.availableModels.isNotEmpty
              ? resolved.availableModels
              : (cur?.availableModels ?? const []),
          agentStatus: 'idle',
          sessions: resolved.sessions.isNotEmpty
              ? resolved.sessions
              : (cur?.sessions ?? const []),
          dialogBlocks: const [],
          fullText: '',
        );
        return state.copyWith(
          isLoadingContent: false,
          content: blankKeepingMeta,
          clearDismissedQuestions: shouldClearDismissed,
          clearError: true,
        );
      }
      _cacheResolved(resolved);
      return state.copyWith(
        isLoadingContent: false,
        awaitingNewSession: false,
        clearPreviousSessionId: true,
        clearDismissedQuestions: shouldClearDismissed,
        selectedSessionId: nextId,
        content: resolved,
        clearError: true,
      );
    }
    _cacheResolved(resolved);
    return state.copyWith(
      isLoadingContent: false,
      clearDismissedQuestions: shouldClearDismissed,
      content: resolved,
      clearError: true,
    );
  }

  void _onPushedHostMessage(ProtocolMessage msg) {
    if (msg is WindowContentMessage && msg.requestId == 'push') {
      final prevStatus = state.content?.agentStatus;
      state = _applyIncomingContent(msg);
      if (!state.awaitingNewSession &&
          prevStatus == 'working' &&
          (msg.agentStatus == 'waiting_approval' ||
              msg.agentStatus == 'idle')) {
        HapticFeedback.heavyImpact();
      }
    }
  }

  void startNewSession() {
    final cur = state.content;
    final prevId = cur?.activeSessionId ?? state.selectedSessionId;
    final cleared = WindowContentMessage(
      targetWindowId: cur?.targetWindowId,
      windowTitle: cur?.windowTitle ?? '',
      app: cur?.app ?? '',
      methodUsed: cur?.methodUsed ?? 'none',
      agentName: cur?.agentName ?? '',
      activeSessionId: null,
      activeModel: cur?.activeModel ?? '',
      availableModels: cur?.availableModels ?? const [],
      agentStatus: 'idle',
      sessions: cur?.sessions ?? const [],
      dialogBlocks: const [],
      fullText: '',
    );
    state = state.copyWith(
      awaitingNewSession: true,
      previousSessionIdBeforeNew: prevId,
      clearSelectedSession: true,
      content: cleared,
      clearError: true,
    );
    if (_client.snapshot.isConnected) {
      final targetId = _ref.read(windowControllerProvider).selectedWindowId;
      _client.send(
        InputKeyMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          key: 'vh:new_session',
          modifiers: const [],
          targetWindowId: targetId,
        ),
      );
    }
  }

  void cancelAwaitingNewSession() {
    state = state.copyWith(
      awaitingNewSession: false,
      clearPreviousSessionId: true,
    );
    unawaited(fetchContent());
  }

  void setMethodMode(String mode) {
    state = state.copyWith(methodMode: mode);
    unawaited(fetchContent());
  }

  void selectSession(String? sessionId, {String? title}) {
    if (sessionId == null || sessionId.isEmpty) {
      state = state.copyWith(
        clearSelectedSession: true,
        awaitingNewSession: false,
        clearPreviousSessionId: true,
      );
    } else {
      final cached = _cacheStore.getCached(_activeHostId, sessionId);
      state = state.copyWith(
        selectedSessionId: sessionId,
        awaitingNewSession: false,
        clearPreviousSessionId: true,
        content: cached,
        clearError: true,
      );
      // Sync session switch onto Host IDE (CDP DOM click or Windows UIA sidebar / Claude CLI resume)
      if (_client.snapshot.isConnected) {
        String effectiveTitle = title ?? '';
        if (effectiveTitle.isEmpty && state.content != null) {
          for (final s in state.content!.sessions) {
            if (s.id == sessionId) {
              effectiveTitle = s.title;
              break;
            }
          }
        }
        final targetId = _ref.read(windowControllerProvider).selectedWindowId;
        _client.send(
          InputKeyMessage(
            requestId: _client.nextRequestId(),
            timestamp: DateTime.now().millisecondsSinceEpoch,
            key: 'vh:switch_session:$sessionId|$effectiveTitle',
            modifiers: const [],
            targetWindowId: targetId,
          ),
        );
      }
    }
    unawaited(fetchContent());
  }

  void setAutoRefresh(bool enabled) {
    _pollTimer?.cancel();
    _pollTimer = null;
    state = state.copyWith(autoRefresh: enabled);
    if (enabled) {
      unawaited(fetchContent());
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_client.snapshot.isConnected && !state.isLoadingContent) {
          unawaited(fetchContent());
        }
      });
    }
  }

  List<String> _resolveMethods() {
    return switch (state.methodMode) {
      'transcript' => const ['transcript'],
      'uia' => const ['uia'],
      _ => const ['transcript', 'uia'],
    };
  }

  Future<void> fetchContent({
    bool resetSession = false,
    bool forceFull = false,
  }) async {
    if (!_client.snapshot.isConnected) return;
    await _cacheStore.ensureLoaded();
    if (_disposed) return;

    final base = _resolveDeltaBase(
      resetSession: resetSession,
      forceFull: forceFull,
    );
    if (resetSession) {
      state = state.copyWith(
        isLoadingContent: true,
        clearSelectedSession: true,
        clearError: true,
      );
    } else {
      state = state.copyWith(isLoadingContent: true, clearError: true);
    }
    final targetId = _ref.read(windowControllerProvider).selectedWindowId;
    final canUseDelta = !forceFull &&
        base != null &&
        base.activeSessionId != null &&
        base.activeSessionId!.isNotEmpty &&
        base.dialogBlocks.isNotEmpty;
    try {
      final resp = await _client.sendAndWait(
        GetWindowContentMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          targetWindowId: targetId,
          sessionId: resetSession ? null : state.selectedSessionId,
          methods: _resolveMethods(),
          supportsDelta: !forceFull,
          knownSessionId: canUseDelta ? base.activeSessionId : null,
          knownBlockCount: canUseDelta ? base.dialogBlocks.length : 0,
          knownPrefixHash: canUseDelta ? base.syncPrefixHash : '',
          knownLastHash: canUseDelta ? base.syncLastHash : '',
        ),
        timeout: const Duration(seconds: 12),
      );
      if (resp is WindowContentMessage) {
        state = _applyIncomingContent(resp);
      } else if (resp is ErrorMessage) {
        state = state.copyWith(isLoadingContent: false, error: resp.message);
      } else {
        state = state.copyWith(isLoadingContent: false);
      }
    } catch (e) {
      state = state.copyWith(isLoadingContent: false, error: '读取窗口内容失败: $e');
    }
  }

  Future<void> fetchSnapshot({String mode = 'window'}) async {
    if (!_client.snapshot.isConnected) return;
    state = state.copyWith(isLoadingSnapshot: true, clearError: true);
    final targetId = _ref.read(windowControllerProvider).selectedWindowId;
    final effectiveMode = (mode == 'window' && targetId == null) ? 'screen' : mode;
    try {
      final resp = await _client.sendAndWait(
        GetSnapshotMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          mode: effectiveMode,
          targetWindowId: effectiveMode == 'window' ? targetId : null,
          quality: 70,
          maxWidth: 1280,
        ),
        timeout: const Duration(seconds: 10),
      );
      if (resp is WindowSnapshotMessage && resp.imageBase64.isNotEmpty) {
        final bytes = base64Decode(resp.imageBase64);
        state = state.copyWith(
          isLoadingSnapshot: false,
          snapshotBytes: bytes,
          snapshotWidth: resp.width,
          snapshotHeight: resp.height,
          snapshotElapsedMs: resp.elapsedMs,
          clearError: true,
        );
      } else if (resp is ErrorMessage) {
        state = state.copyWith(isLoadingSnapshot: false, error: resp.message);
      } else {
        state = state.copyWith(isLoadingSnapshot: false);
      }
    } catch (e) {
      state = state.copyWith(isLoadingSnapshot: false, error: '抓取快照失败: $e');
    }
  }

  void sendSnapshotClick({
    required double xNorm,
    required double yNorm,
    String action = 'click',
    String button = 'left',
  }) {
    if (!_client.snapshot.isConnected) return;
    final targetId = _ref.read(windowControllerProvider).selectedWindowId;
    _client.send(
      InputPointerMessage(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        action: action,
        button: button,
        xNorm: xNorm.clamp(0.0, 1.0),
        yNorm: yNorm.clamp(0.0, 1.0),
        targetWindowId: targetId,
      ),
    );
    // Automatically refresh snapshot briefly after click so user sees updated UI
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (_client.snapshot.isConnected && !state.isLoadingSnapshot) {
        unawaited(fetchSnapshot());
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _cacheStore.dispose();
    unawaited(_msgSub?.cancel());
    super.dispose();
  }
}

final windowContentProvider =
    StateNotifierProvider<WindowContentController, WindowContentState>((ref) {
  return WindowContentController(ref);
});
