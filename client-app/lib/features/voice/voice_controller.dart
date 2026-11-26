import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../connection/connection_controller.dart';
import '../windows/window_controller.dart';
import 'desktop_hotkey_service.dart';
import 'stt_engine.dart';

enum VoicePhase {
  idle,
  listening,
  transcribing,
  injecting,
  error,
}

class VoiceState {
  const VoiceState({
    this.phase = VoicePhase.idle,
    this.liveTranscript = '',
    this.statusHint = '点击下方输入框用手机输入法语音键说话，发送即可无损注入',
    this.error,
    this.continuousActive = false,
  });

  final VoicePhase phase;
  final String liveTranscript;
  final String statusHint;
  final String? error;
  final bool continuousActive;

  VoiceState copyWith({
    VoicePhase? phase,
    String? liveTranscript,
    String? statusHint,
    String? error,
    bool clearError = false,
    bool? continuousActive,
  }) {
    return VoiceState(
      phase: phase ?? this.phase,
      liveTranscript: liveTranscript ?? this.liveTranscript,
      statusHint: statusHint ?? this.statusHint,
      error: clearError ? null : (error ?? this.error),
      continuousActive: continuousActive ?? this.continuousActive,
    );
  }
}

class VoiceController extends StateNotifier<VoiceState> {
  VoiceController(this._ref) : super(const VoiceState()) {
    _hotkeyService = DesktopHotkeyService();
    _syncDesktopHotkey(_ref.read(settingsProvider).desktopHotkey);
    _ref.listen<DesktopHotkeyPreset>(
      settingsProvider.select((s) => s.desktopHotkey),
      (_, next) => _syncDesktopHotkey(next),
    );
  }

  final Ref _ref;
  late final DesktopHotkeyService _hotkeyService;
  NativeSttEngine? _nativeEngine;
  bool _injectedCurrentSession = false;

  void _syncDesktopHotkey(DesktopHotkeyPreset preset) {
    unawaited(
      _hotkeyService.registerPreset(
        preset,
        onTriggered: () => unawaited(toggleGlobalHotkeyCapture()),
      ),
    );
  }

  Future<void> _disposeEngine() async {
    final prev = _nativeEngine;
    _nativeEngine = null;
    if (prev != null) {
      await prev.dispose();
    }
  }

  Future<void> toggleGlobalHotkeyCapture() async {
    if (state.phase == VoicePhase.listening) {
      await stopCaptureAndInject();
    } else if (state.phase == VoicePhase.idle ||
        state.phase == VoicePhase.error) {
      await startCapture(continuous: false);
    }
  }

  void setDraftText(String text) {
    state = state.copyWith(liveTranscript: text, clearError: true);
  }

  Future<void> startCapture({bool continuous = false}) async {
    if (state.phase == VoicePhase.listening) return;

    await _disposeEngine();
    final settings = _ref.read(settingsProvider);
    final engine = NativeSttEngine();
    _nativeEngine = engine;
    _injectedCurrentSession = false;

    state = state.copyWith(
      phase: VoicePhase.listening,
      liveTranscript: '',
      statusHint: continuous ? '系统语音连续听写中...' : '正在聆听，松开即可注入...',
      clearError: true,
      continuousActive: continuous,
    );

    await engine.startListening(
      localeId: settings.sttLocale,
      onPartial: (partial) {
        state = state.copyWith(liveTranscript: partial);
        _ref.read(hostActionProvider).sendSttPartial(partial, isFinal: false);
      },
      onFinal: (finalText) {
        unawaited(_handleFinalTranscript(finalText));
      },
      onError: (errMsg) {
        state = state.copyWith(
          phase: VoicePhase.error,
          error: errMsg,
          statusHint: errMsg,
          continuousActive: false,
        );
      },
    );
  }

  Future<void> stopCaptureAndInject() async {
    final engine = _nativeEngine;
    if (engine == null) {
      state = state.copyWith(phase: VoicePhase.idle, continuousActive: false);
      return;
    }
    state = state.copyWith(
      phase: VoicePhase.transcribing,
      statusHint: '正在整理识别结果...',
      continuousActive: false,
    );
    final fallbackText = await engine.stopListening();
    if (!_injectedCurrentSession &&
        fallbackText != null &&
        fallbackText.trim().isNotEmpty) {
      await _handleFinalTranscript(fallbackText);
    } else if (!_injectedCurrentSession && state.phase != VoicePhase.error) {
      state = state.copyWith(phase: VoicePhase.idle, statusHint: '未检测到有效语音');
    }
  }

  Future<void> cancelCapture() async {
    _injectedCurrentSession = true;
    await _nativeEngine?.cancelListening();
    state = state.copyWith(
      phase: VoicePhase.idle,
      liveTranscript: '',
      statusHint: '已取消本次录音',
      clearError: true,
      continuousActive: false,
    );
  }

  Future<void> toggleContinuous() async {
    if (state.continuousActive || state.phase == VoicePhase.listening) {
      await stopCaptureAndInject();
    } else {
      await startCapture(continuous: true);
    }
  }

  Future<void> _handleFinalTranscript(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty || _injectedCurrentSession) return;
    _injectedCurrentSession = true;

    final shouldRestartContinuous = state.continuousActive;
    state = state.copyWith(
      phase: VoicePhase.injecting,
      liveTranscript: text,
      statusHint: '正在安全粘贴到目标窗口...',
    );

    final winState = _ref.read(windowControllerProvider);
    final selectedWin = winState.selectedWindow;
    final actions = _ref.read(hostActionProvider);
    actions.sendSttPartial(text, isFinal: true);

    final result = await actions.injectText(
      text: text,
      targetWindowId: winState.selectedWindowId,
      targetWindowTitle:
          selectedWin != null ? '[${selectedWin.app}] ${selectedWin.title}' : '当前焦点窗口',
      source: 'stt_final',
    );

    if (result != null && result.ok) {
      state = state.copyWith(
        phase: VoicePhase.idle,
        statusHint:
            '已注入 ${result.injectedChars} 字符（${result.shortcutUsed}，${result.elapsedMs}ms）',
        clearError: true,
      );
    } else {
      state = state.copyWith(
        phase: VoicePhase.error,
        error: '注入失败，请检查连接或重新锁定目标窗口',
        statusHint: '注入失败（文本已保留在下方编辑框，可点击补发）',
      );
    }

    if (shouldRestartContinuous) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (state.continuousActive) {
        await startCapture(continuous: true);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_hotkeyService.unregisterAll());
    unawaited(_disposeEngine());
    super.dispose();
  }
}

final voiceControllerProvider =
    StateNotifierProvider<VoiceController, VoiceState>((ref) {
  return VoiceController(ref);
});
