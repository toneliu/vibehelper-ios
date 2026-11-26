import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibehelper_client/features/stream/pcm_voice_gate.dart';
import 'package:vibehelper_client/features/update/update_controller.dart';

Uint8List _makePcmChunk(int amplitude, {int samples = 160}) {
  final bd = ByteData(samples * 2);
  for (int i = 0; i < samples; i++) {
    final val = (i.isEven ? amplitude : -amplitude).clamp(-32767, 32767);
    bd.setInt16(i * 2, val, Endian.little);
  }
  return bd.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('PcmVoiceGate silence skipping', () {
    test('drops silent frames, keeps pre-roll on speech onset, and preserves hangover', () {
      final gate = PcmVoiceGate(
        speechPeakThreshold: 500,
        speechRmsThreshold: 180,
        hangoverMs: 400,
        maxPrerollChunks: 1,
      );
      final t0 = DateTime(2026, 11, 26, 22, 0, 0);

      // 1. Sustained ambient noise (amplitude 80) -> skipped, latest chunk kept in preroll
      final r1 = gate.processChunk(_makePcmChunk(80), now: t0);
      final r2 = gate.processChunk(
        _makePcmChunk(95),
        now: t0.add(const Duration(milliseconds: 80)),
      );
      expect(r1, isEmpty);
      expect(r2, isEmpty);
      expect(gate.skippedSilenceChunks, 2);
      expect(gate.isVoiceActive, false);

      // 2. Speech starts (amplitude 1800) -> emits 1 preroll chunk + current chunk
      final speechChunk = _makePcmChunk(1800);
      final r3 = gate.processChunk(
        speechChunk,
        now: t0.add(const Duration(milliseconds: 160)),
      );
      expect(r3.length, 2);
      expect(ByteData.sublistView(r3.first).getInt16(0, Endian.little), 95);
      expect(ByteData.sublistView(r3.last).getInt16(0, Endian.little), 1800);
      expect(gate.isVoiceActive, true);

      // 3. Brief pause within hangover (250ms < 400ms) -> still forwarded
      final r4 = gate.processChunk(
        _makePcmChunk(60),
        now: t0.add(const Duration(milliseconds: 410)),
      );
      expect(r4.length, 1);
      expect(gate.isVoiceActive, true);

      // 4. Pause past hangover (500ms > 400ms) -> skipped cleanly
      final r5 = gate.processChunk(
        _makePcmChunk(60),
        now: t0.add(const Duration(milliseconds: 660)),
      );
      expect(r5, isEmpty);
      expect(gate.isVoiceActive, false);
      expect(gate.skippedSilenceChunks, 3);
    });
  });

  group('Pure-Dart SHA256 & AppUpdateController', () {
    test('computeSha256Hex matches standard NIST vector for "abc"', () {
      expect(
        computeSha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('auto-applies hot_update bundle and reports reinstall updates cleanly', () async {
      final prevHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevHttpOverrides);

      SharedPreferences.setMockInitialValues({});
      String mode = 'hot_update';

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final base = 'http://127.0.0.1:${server.port}';
        if (req.uri.path == '/api/updates/check') {
          if (mode == 'hot_update') {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'ok': true,
                'platform': 'android',
                'action': 'hot_update',
                'reason': 'hot_bundle_updated',
                'reason_text': '免重装热更新可用',
                'install_method': 'apk_in_app',
                'latest_version': '0.7.0',
                'latest_build': 7,
                'native_version': 8,
                'package_available': false,
                'hot_version': 3,
                'hot_bundle_url': '$base/api/updates/hot-bundle',
                'hot_sha256': 'abc',
                'changelog': '调高语音门限',
              }));
          } else {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'ok': true,
                'platform': 'ios',
                'action': 'reinstall',
                'reason': 'native_changed',
                'reason_text': '包含灵动岛动画原生改动，需要通过 AltStore 重新安装',
                'install_method': 'altstore',
                'latest_version': '0.8.0',
                'latest_build': 9,
                'native_version': 9,
                'package_available': true,
                'download_url': '$base/api/updates/download/ios',
                'sha256': 'deadbeef',
                'size_bytes': 1048576,
                'altstore_source_url': '$base/api/updates/altstore.json',
                'altstore_deep_link': 'altstore://source?url=encoded',
                'hot_version': 3,
                'changelog': '后台灵动岛动画',
              }));
          }
        } else if (req.uri.path == '/api/updates/hot-bundle') {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'ok': true,
              'data': {
                'hot_version': 3,
                'updated_at': '2026-11-26T22:00:00Z',
                'changelog': '调高语音门限',
                'vad': {
                  'speech_peak_threshold': 720,
                  'speech_rms_threshold': 240,
                  'hangover_ms': 600,
                },
              },
            }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(appUpdateProvider.notifier);
      final base = 'http://127.0.0.1:${server.port}';

      // 1. Auto hot update applied cleanly and persisted
      final dec1 = await ctrl.checkForUpdates(
        overrideBaseUrl: base,
        overridePlatform: 'android',
      );
      expect(dec1, isNotNull);
      final st1 = container.read(appUpdateProvider);
      expect(st1.hotConfig.hotVersion, 3);
      expect(st1.hotConfig.vadPeakThreshold, 720);
      expect(st1.hotConfig.vadHangoverMs, 600);
      expect(st1.decision?.reason, 'hot_updated');

      // 2. Native change detected -> surfaced as reinstall with AltStore URL
      mode = 'reinstall';
      final dec2 = await ctrl.checkForUpdates(
        overrideBaseUrl: base,
        overridePlatform: 'ios',
      );
      expect(dec2?.isReinstall, true);
      expect(dec2?.reason, 'native_changed');
      expect(dec2?.installMethod, 'altstore');
      expect(dec2?.altstoreDeepLink, 'altstore://source?url=encoded');
    });
  });
}
