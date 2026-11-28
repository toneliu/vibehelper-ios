import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibehelper_client/core/app_settings.dart';
import 'package:vibehelper_client/core/pinned_http_client.dart';

void main() {
  group('normalizeWsUrl', () {
    test('preserves https:// and wss:// as wss://', () {
      expect(normalizeWsUrl('https://home.ddns.net'), 'wss://home.ddns.net:8765/ws');
      expect(normalizeWsUrl('https://home.ddns.net:9443'), 'wss://home.ddns.net:9443/ws');
      expect(normalizeWsUrl('wss://home.ddns.net:8765'), 'wss://home.ddns.net:8765/ws');
      expect(normalizeWsUrl('wss://home.ddns.net:8765/ws'), 'wss://home.ddns.net:8765/ws');
    });

    test('normalizes bare IP, port, http:// and ws:// cleanly', () {
      expect(normalizeWsUrl('192.168.1.50'), 'ws://192.168.1.50:8765/ws');
      expect(normalizeWsUrl('192.168.1.50:9000'), 'ws://192.168.1.50:9000/ws');
      expect(normalizeWsUrl('http://10.0.0.2:8765'), 'ws://10.0.0.2:8765/ws');
      expect(normalizeWsUrl('ws://10.0.0.2:8765/ws'), 'ws://10.0.0.2:8765/ws');
    });
  });

  group('HostProfile', () {
    test('backward-compatible serialization with and without auth/TLS fields', () {
      final legacy = HostProfile.fromJson(const {
        'id': 'h1',
        'name': 'Home',
        'ws_url': '192.168.1.9:8765',
        'token': 'abc',
      });
      expect(legacy.wsUrl, 'ws://192.168.1.9:8765/ws');
      expect(legacy.deviceId, '');
      expect(legacy.tlsCertSha256, '');
      expect(legacy.isTls, isFalse);

      final paired = HostProfile(
        id: 'h2',
        name: 'Office',
        wsUrl: 'wss://office.example.com:8765/ws',
        token: 'vhdev_xyz',
        deviceId: 'dev-1234',
        tlsCertSha256: 'AA:BB:CC',
        authMode: 'paired',
      );
      final roundTrip = HostProfile.fromJson(paired.toJson());
      expect(roundTrip.isTls, isTrue);
      expect(roundTrip.hasPinnedCert, isTrue);
      expect(roundTrip.deviceId, 'dev-1234');
      expect(roundTrip.tlsCertSha256, 'AA:BB:CC');
      expect(roundTrip.authMode, 'paired');
    });
  });

  group('sha256ColonHex', () {
    test('matches NIST FIPS 180-4 test vectors', () {
      // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      expect(
        sha256ColonHex(const <int>[]).replaceAll(':', '').toLowerCase(),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
      expect(
        sha256ColonHex(utf8.encode('abc')).replaceAll(':', '').toLowerCase(),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });
}
