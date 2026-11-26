import 'dart:math' as math;
import 'dart:typed_data';

/// Client-side PCM s16le voice activity gate for virtual microphone streaming.
///
/// Drops ambient-silence frames on mobile so zero network packets are sent while
/// the user is silent, while keeping a short pre-roll and hangover window so
/// word onsets and trailing syllables are never clipped.
class PcmVoiceGate {
  PcmVoiceGate({
    int speechPeakThreshold = 520,
    double speechRmsThreshold = 180.0,
    int hangoverMs = 450,
    this.maxPrerollChunks = 1,
  })  : _speechPeakThreshold = speechPeakThreshold.clamp(80, 16000),
        _speechRmsThreshold = speechRmsThreshold.clamp(30.0, 8000.0),
        _hangoverMs = hangoverMs.clamp(100, 3000);

  int _speechPeakThreshold;
  double _speechRmsThreshold;
  int _hangoverMs;
  final int maxPrerollChunks;

  final List<Uint8List> _preroll = <Uint8List>[];
  DateTime? _lastSpeechAt;
  bool _isVoiceActive = false;
  int _skippedSilenceChunks = 0;

  int get speechPeakThreshold => _speechPeakThreshold;
  double get speechRmsThreshold => _speechRmsThreshold;
  int get hangoverMs => _hangoverMs;
  bool get isVoiceActive => _isVoiceActive;
  int get skippedSilenceChunks => _skippedSilenceChunks;

  void updateThresholds({
    int? speechPeakThreshold,
    double? speechRmsThreshold,
    int? hangoverMs,
  }) {
    if (speechPeakThreshold != null) {
      _speechPeakThreshold = speechPeakThreshold.clamp(80, 16000);
    }
    if (speechRmsThreshold != null) {
      _speechRmsThreshold = speechRmsThreshold.clamp(30.0, 8000.0);
    }
    if (hangoverMs != null) {
      _hangoverMs = hangoverMs.clamp(100, 3000);
    }
  }

  void reset() {
    _preroll.clear();
    _lastSpeechAt = null;
    _isVoiceActive = false;
    _skippedSilenceChunks = 0;
  }

  /// Inspect one signed 16-bit little-endian PCM chunk and return the chunk(s) to send.
  /// Returns an empty list during sustained silence.
  List<Uint8List> processChunk(Uint8List chunk, {DateTime? now}) {
    if (chunk.length < 2) return const [];
    final ts = now ?? DateTime.now();

    final sampleCount = chunk.length ~/ 2;
    final view = ByteData.sublistView(chunk);
    int peak = 0;
    double sumSq = 0;
    for (int i = 0; i < sampleCount; i++) {
      final s = view.getInt16(i * 2, Endian.little);
      final absS = s < 0 ? -s : s;
      if (absS > peak) peak = absS;
      sumSq += s.toDouble() * s.toDouble();
    }
    final rms = sampleCount > 0 ? math.sqrt(sumSq / sampleCount) : 0.0;
    final hasSpeech = peak >= _speechPeakThreshold || rms >= _speechRmsThreshold;

    if (hasSpeech) {
      final wasActive = _isVoiceActive;
      _lastSpeechAt = ts;
      _isVoiceActive = true;
      if (!wasActive && _preroll.isNotEmpty) {
        final out = <Uint8List>[..._preroll, chunk];
        _preroll.clear();
        return out;
      }
      _preroll.clear();
      return <Uint8List>[chunk];
    }

    if (_lastSpeechAt != null &&
        ts.difference(_lastSpeechAt!).inMilliseconds <= _hangoverMs) {
      _isVoiceActive = true;
      return <Uint8List>[chunk];
    }

    _isVoiceActive = false;
    _skippedSilenceChunks++;
    if (maxPrerollChunks > 0) {
      _preroll.add(chunk);
      while (_preroll.length > maxPrerollChunks) {
        _preroll.removeAt(0);
      }
    }
    return const [];
  }
}
