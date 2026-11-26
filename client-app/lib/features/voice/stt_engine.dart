import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef PartialResultCallback = void Function(String text);
typedef FinalResultCallback = void Function(String text);
typedef ErrorCallback = void Function(String message);

/// Native OS Speech-to-Text engine backed by Android SpeechRecognizer / iOS SFSpeechRecognizer.
class NativeSttEngine {
  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;
  ErrorCallback? _activeErrorCb;
  String _latestWords = '';
  bool _finalDelivered = false;

  String get _fallbackHint => (!kIsWeb && Platform.isIOS)
      ? '请确认已在 iOS「设置 → 隐私与安全性」开启麦克风与语音识别权限，或使用顶部「虚拟麦」直传'
      : '小米等国产手机请使用「输入法语音直发」或顶部「虚拟麦」直传';

  Future<bool> ensureReady() async {
    if (_initialized && _speech.isAvailable) return true;
    try {
      _initialized = await _speech.initialize(
        onError: (SpeechRecognitionError err) {
          _activeErrorCb?.call(
            '系统原生语音不可用(${err.errorMsg})：$_fallbackHint',
          );
        },
      );
    } catch (_) {
      _initialized = false;
    }
    return _initialized;
  }

  Future<void> startListening({
    required String localeId,
    required PartialResultCallback onPartial,
    required FinalResultCallback onFinal,
    required ErrorCallback onError,
  }) async {
    _activeErrorCb = onError;
    _latestWords = '';
    _finalDelivered = false;

    final ready = await ensureReady();
    if (!ready) {
      onError('当前设备未提供系统原生语音服务（$_fallbackHint）');
      return;
    }

    await _speech.listen(
      localeId: localeId,
      onResult: (SpeechRecognitionResult result) {
        _latestWords = result.recognizedWords.trim();
        if (_latestWords.isEmpty) return;
        onPartial(_latestWords);
        if (result.finalResult && !_finalDelivered) {
          _finalDelivered = true;
          onFinal(_latestWords);
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        cancelOnError: false,
      ),
    );
  }

  Future<String?> stopListening() async {
    if (_speech.isListening) {
      await _speech.stop();
    }
    if (!_finalDelivered && _latestWords.isNotEmpty) {
      _finalDelivered = true;
      return _latestWords;
    }
    return null;
  }

  Future<void> cancelListening() async {
    _latestWords = '';
    _finalDelivered = true;
    if (_speech.isListening) {
      await _speech.cancel();
    }
  }

  Future<void> dispose() async {
    await cancelListening();
  }
}
