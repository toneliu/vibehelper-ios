import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Pure-Dart FIPS 180-4 SHA-256 digest (avoids adding native crypto dependencies).
Uint8List sha256Bytes(List<int> input) {
  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  int h0 = 0x6a09e667;
  int h1 = 0xbb67ae85;
  int h2 = 0x3c6ef372;
  int h3 = 0xa54ff53a;
  int h4 = 0x510e527f;
  int h5 = 0x9b05688c;
  int h6 = 0x1f83d9ab;
  int h7 = 0x5be0cd19;

  final len = input.length;
  final bitLen = len * 8;
  final padLen = ((len + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(padLen);
  for (var i = 0; i < len; i++) {
    padded[i] = input[i] & 0xff;
  }
  padded[len] = 0x80;
  // 64-bit big-endian bit length
  final hiLen = bitLen ~/ 0x100000000;
  final loLen = bitLen & 0xffffffff;
  padded[padLen - 8] = (hiLen >> 24) & 0xff;
  padded[padLen - 7] = (hiLen >> 16) & 0xff;
  padded[padLen - 6] = (hiLen >> 8) & 0xff;
  padded[padLen - 5] = hiLen & 0xff;
  padded[padLen - 4] = (loLen >> 24) & 0xff;
  padded[padLen - 3] = (loLen >> 16) & 0xff;
  padded[padLen - 2] = (loLen >> 8) & 0xff;
  padded[padLen - 1] = loLen & 0xff;

  int rotr(int x, int n) => ((x & 0xffffffff) >>> n) | ((x << (32 - n)) & 0xffffffff);

  final w = Uint32List(64);
  for (var off = 0; off < padLen; off += 64) {
    for (var i = 0; i < 16; i++) {
      final b = off + i * 4;
      w[i] = ((padded[b] << 24) |
              (padded[b + 1] << 16) |
              (padded[b + 2] << 8) |
              padded[b + 3]) &
          0xffffffff;
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var i = 0; i < 64; i++) {
      final S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + S1 + ch + k[i] + w[i]) & 0xffffffff;
      final S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (S0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final out = Uint8List(32);
  final words = [h0, h1, h2, h3, h4, h5, h6, h7];
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (words[i] >> 24) & 0xff;
    out[i * 4 + 1] = (words[i] >> 16) & 0xff;
    out[i * 4 + 2] = (words[i] >> 8) & 0xff;
    out[i * 4 + 3] = words[i] & 0xff;
  }
  return out;
}

String normalizeCertFingerprint(String raw) {
  return raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
}

String sha256ColonHex(List<int> input) {
  final digest = sha256Bytes(input);
  return digest.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
}

/// Global registry of SHA-256 pinned self-signed host certificates so `Image.network`
/// and platform `HttpClient` automatically verify pinned hosts while rejecting random untrusted certs.
class PinnedCertStore {
  PinnedCertStore._();
  static final PinnedCertStore instance = PinnedCertStore._();

  final Map<String, String> _pins = HashMap<String, String>();

  static String _key(String host, int port) => '${host.trim().toLowerCase()}:$port';

  void setPin(String host, int port, String sha256) {
    final norm = normalizeCertFingerprint(sha256);
    if (host.trim().isEmpty || norm.isEmpty) return;
    _pins[_key(host, port)] = norm;
  }

  void clearAll() => _pins.clear();

  String? lookup(String host, int port) => _pins[_key(host, port)];

  bool matches(String host, int port, X509Certificate cert) {
    final pinned = lookup(host, port);
    if (pinned == null || pinned.isEmpty) return false;
    final actual = normalizeCertFingerprint(sha256ColonHex(cert.der));
    return actual.isNotEmpty && actual == pinned;
  }
}

class PinnedHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) {
      return PinnedCertStore.instance.matches(host, port, cert);
    };
    return client;
  }
}

/// Create a dedicated `HttpClient` that checks explicit `pinnedCertSha256` (if given),
/// falls back to `PinnedCertStore.instance`, or allows probe-capture when `allowUntrustedForProbe` is true.
HttpClient createPinnedHttpClient({
  String? pinnedCertSha256,
  Duration connectionTimeout = const Duration(seconds: 8),
  bool allowUntrustedForProbe = false,
  void Function(String sha256Colon)? onPeerCertSha256,
}) {
  final expected = normalizeCertFingerprint(pinnedCertSha256 ?? '');
  final client = HttpClient()..connectionTimeout = connectionTimeout;
  client.badCertificateCallback = (X509Certificate cert, String host, int port) {
    final fp = sha256ColonHex(cert.der);
    onPeerCertSha256?.call(fp);
    if (allowUntrustedForProbe) return true;
    if (expected.isNotEmpty && normalizeCertFingerprint(fp) == expected) {
      return true;
    }
    return PinnedCertStore.instance.matches(host, port, cert);
  };
  return client;
}

void applyAuthHeaders(HttpClientRequest req, String token) {
  final t = token.trim();
  if (t.isNotEmpty) {
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
  }
}
