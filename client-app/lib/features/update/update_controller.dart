import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_build_info.dart';
import '../../core/app_settings.dart';

/// Computes standard 256-bit SHA-2 digest hex dynamically without static constant tables.
String computeSha256Hex(List<int> input) {
  final primes = <int>[];
  int cand = 2;
  while (primes.length < 64) {
    bool isPrime = true;
    for (int d = 2; d * d <= cand; d++) {
      if (cand % d == 0) {
        isPrime = false;
        break;
      }
    }
    if (isPrime) primes.add(cand);
    cand++;
  }

  final h = List<int>.generate(8, (i) {
    final frac = math.sqrt(primes[i]) % 1.0;
    return (frac * 4294967296.0).floor() & 0xFFFFFFFF;
  });
  final k = List<int>.generate(64, (i) {
    final frac = math.pow(primes[i], 1.0 / 3.0) % 1.0;
    return (frac * 4294967296.0).floor() & 0xFFFFFFFF;
  });

  int rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

  final bitLen = input.length * 8;
  final paddedLen = ((input.length + 9 + 63) ~/ 64) * 64;
  final data = Uint8List(paddedLen);
  data.setRange(0, input.length, input);
  data[input.length] = 0x80;
  final bd = ByteData.sublistView(data);
  bd.setUint32(paddedLen - 8, (bitLen ~/ 4294967296) & 0xFFFFFFFF, Endian.big);
  bd.setUint32(paddedLen - 4, bitLen & 0xFFFFFFFF, Endian.big);

  final w = List<int>.filled(64, 0);
  for (int off = 0; off < paddedLen; off += 64) {
    for (int i = 0; i < 16; i++) {
      w[i] = bd.getUint32(off + i * 4, Endian.big);
    }
    for (int i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    int a = h[0], b = h[1], c = h[2], d = h[3];
    int e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      final sigma1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (hh + sigma1 + ch + k[i] + w[i]) & 0xFFFFFFFF;
      final sigma0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (sigma0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }

  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}

/// Helper executed in a background isolate to hash a downloaded APK without stalling UI.
String _sha256FilePathSync(String filePath) {
  final bytes = File(filePath).readAsBytesSync();
  return computeSha256Hex(bytes);
}

class HotUpdateConfig {
  const HotUpdateConfig({
    this.hotVersion = 1,
    this.updatedAt = '',
    this.changelog = '',
    this.vadPeakThreshold = 220,
    this.vadRmsThreshold = 75.0,
    this.vadHangoverMs = 600,
    this.quickCommands = const [],
    this.announcement = '',
  });

  final int hotVersion;
  final String updatedAt;
  final String changelog;
  final int vadPeakThreshold;
  final double vadRmsThreshold;
  final int vadHangoverMs;
  final List<String> quickCommands;
  final String announcement;

  factory HotUpdateConfig.fromJson(Map<String, dynamic> json) {
    final vad = (json['vad'] as Map<String, dynamic>?) ?? const {};
    final rawCmds = (json['quick_commands'] as List<dynamic>?) ?? const [];
    return HotUpdateConfig(
      hotVersion: (json['hot_version'] as num?)?.toInt() ?? 1,
      updatedAt: (json['updated_at'] as String?) ?? '',
      changelog: (json['changelog'] as String?) ?? '',
      vadPeakThreshold:
          (vad['speech_peak_threshold'] as num?)?.toInt() ?? 220,
      vadRmsThreshold:
          (vad['speech_rms_threshold'] as num?)?.toDouble() ?? 75.0,
      vadHangoverMs: (vad['hangover_ms'] as num?)?.toInt() ?? 600,
      quickCommands: rawCmds
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      announcement: (json['announcement'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'hot_version': hotVersion,
        'updated_at': updatedAt,
        'changelog': changelog,
        'vad': {
          'speech_peak_threshold': vadPeakThreshold,
          'speech_rms_threshold': vadRmsThreshold,
          'hangover_ms': vadHangoverMs,
        },
        'quick_commands': quickCommands,
        'announcement': announcement,
      };
}

class UpdateDecisionInfo {
  const UpdateDecisionInfo({
    required this.action,
    required this.reason,
    required this.reasonText,
    required this.installMethod,
    required this.latestVersion,
    required this.latestBuild,
    required this.nativeVersion,
    required this.packageAvailable,
    this.downloadUrl = '',
    this.sha256 = '',
    this.sizeBytes = 0,
    this.altstoreSourceUrl = '',
    this.altstoreDeepLink = '',
    this.hotVersion = 1,
    this.hotBundleUrl = '',
    this.hotSha256 = '',
    this.changelog = '',
  });

  final String action; // 'none' | 'hot_update' | 'reinstall' | 'reinstall_unavailable'
  final String reason;
  final String reasonText;
  final String installMethod; // 'apk_in_app' | 'altstore' | 'zip_download'
  final String latestVersion;
  final int latestBuild;
  final int nativeVersion;
  final bool packageAvailable;
  final String downloadUrl;
  final String sha256;
  final int sizeBytes;
  final String altstoreSourceUrl;
  final String altstoreDeepLink;
  final int hotVersion;
  final String hotBundleUrl;
  final String hotSha256;
  final String changelog;

  bool get isReinstall => action == 'reinstall';
  bool get isHotUpdate => action == 'hot_update';
  bool get hasActionableUpdate =>
      action == 'reinstall' || action == 'hot_update';

  factory UpdateDecisionInfo.fromJson(Map<String, dynamic> json) =>
      UpdateDecisionInfo(
        action: (json['action'] as String?) ?? 'none',
        reason: (json['reason'] as String?) ?? '',
        reasonText: (json['reason_text'] as String?) ?? '',
        installMethod: (json['install_method'] as String?) ?? '',
        latestVersion: (json['latest_version'] as String?) ?? '',
        latestBuild: (json['latest_build'] as num?)?.toInt() ?? 0,
        nativeVersion: (json['native_version'] as num?)?.toInt() ?? 0,
        packageAvailable: (json['package_available'] as bool?) ?? false,
        downloadUrl: (json['download_url'] as String?) ?? '',
        sha256: (json['sha256'] as String?) ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        altstoreSourceUrl: (json['altstore_source_url'] as String?) ?? '',
        altstoreDeepLink: (json['altstore_deep_link'] as String?) ?? '',
        hotVersion: (json['hot_version'] as num?)?.toInt() ?? 1,
        hotBundleUrl: (json['hot_bundle_url'] as String?) ?? '',
        hotSha256: (json['hot_sha256'] as String?) ?? '',
        changelog: (json['changelog'] as String?) ?? '',
      );
}

class AppUpdateState {
  const AppUpdateState({
    this.checking = false,
    this.downloading = false,
    this.downloadProgress,
    this.clientVersion = AppBuildInfo.appVersion,
    this.clientBuild = AppBuildInfo.buildNumber,
    this.hotConfig = const HotUpdateConfig(),
    this.decision,
    this.bannerDismissed = false,
    this.statusMessage,
    this.error,
  });

  final bool checking;
  final bool downloading;
  final double? downloadProgress;
  final String clientVersion;
  final int clientBuild;
  final HotUpdateConfig hotConfig;
  final UpdateDecisionInfo? decision;
  final bool bannerDismissed;
  final String? statusMessage;
  final String? error;

  AppUpdateState copyWith({
    bool? checking,
    bool? downloading,
    double? downloadProgress,
    bool clearProgress = false,
    String? clientVersion,
    int? clientBuild,
    HotUpdateConfig? hotConfig,
    UpdateDecisionInfo? decision,
    bool clearDecision = false,
    bool? bannerDismissed,
    String? statusMessage,
    bool clearStatus = false,
    String? error,
    bool clearError = false,
  }) {
    return AppUpdateState(
      checking: checking ?? this.checking,
      downloading: downloading ?? this.downloading,
      downloadProgress:
          clearProgress ? null : (downloadProgress ?? this.downloadProgress),
      clientVersion: clientVersion ?? this.clientVersion,
      clientBuild: clientBuild ?? this.clientBuild,
      hotConfig: hotConfig ?? this.hotConfig,
      decision: clearDecision ? null : (decision ?? this.decision),
      bannerDismissed: bannerDismissed ?? this.bannerDismissed,
      statusMessage:
          clearStatus ? null : (statusMessage ?? this.statusMessage),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class AppUpdateController extends StateNotifier<AppUpdateState> {
  AppUpdateController(this._ref) : super(const AppUpdateState()) {
    unawaited(_init());
  }

  static const MethodChannel _channel = MethodChannel('vibehelper/updater');
  static const String _hotPrefKey = 'vh_hot_bundle_v1';

  final Ref _ref;
  String? _lastAutoCheckedHostId;

  String get _currentPlatform {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'linux';
  }

  Future<void> _init() async {
    await _loadCachedHotConfig();
    await _loadNativeBuildInfo();
  }

  Future<void> _loadCachedHotConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_hotPrefKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final cfg = HotUpdateConfig.fromJson(map);
        _applyHotConfig(cfg);
      }
    } catch (_) {}
  }

  Future<void> _loadNativeBuildInfo() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('getAppVersion');
      if (info == null || !mounted) return;
      final ver = (info['version'] as String?) ?? state.clientVersion;
      final bld = (info['buildNumber'] as num?)?.toInt() ?? state.clientBuild;
      state = state.copyWith(clientVersion: ver, clientBuild: bld);
    } on MissingPluginException {
      // Safe no-op in headless tests / desktop
    } on PlatformException {
      // Fall back to compile-time AppBuildInfo
    }
  }

  static String? _httpBaseFromWs(String rawWsUrl) {
    final wsUri = Uri.tryParse(rawWsUrl.trim());
    if (wsUri == null || wsUri.host.isEmpty) return null;
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final port = wsUri.hasPort ? wsUri.port : (scheme == 'https' ? 443 : 8765);
    return '$scheme://${wsUri.host}:$port';
  }

  void _applyHotConfig(HotUpdateConfig cfg) {
    if (!mounted) return;
    state = state.copyWith(hotConfig: cfg);
  }

  Future<void> _saveHotConfig(HotUpdateConfig cfg) async {
    _applyHotConfig(cfg);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hotPrefKey, jsonEncode(cfg.toJson()));
    } catch (_) {}
  }

  Future<void> syncOnConnected() async {
    final hostId = _ref.read(settingsProvider).activeHost.id;
    if (_lastAutoCheckedHostId == hostId && state.decision != null) return;
    _lastAutoCheckedHostId = hostId;
    await checkForUpdates(silent: true);
  }

  void dismissBanner() {
    state = state.copyWith(bannerDismissed: true);
  }

  Future<UpdateDecisionInfo?> checkForUpdates({
    bool silent = false,
    String? overrideBaseUrl,
    String? overrideToken,
    String? overridePlatform,
  }) async {
    if (state.checking) return state.decision;

    final activeHost = _ref.read(settingsProvider).activeHost;
    final baseUrl =
        overrideBaseUrl ?? _httpBaseFromWs(activeHost.wsUrl);
    if (baseUrl == null || baseUrl.isEmpty) {
      if (!silent) {
        state = state.copyWith(error: '当前 Host 地址无效，无法检查更新');
      }
      return null;
    }
    final token = (overrideToken ?? activeHost.token).trim();

    state = state.copyWith(
      checking: true,
      clearError: true,
      clearStatus: !silent,
    );

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('$baseUrl/api/updates/check').replace(
        queryParameters: {
          'platform': overridePlatform ?? _currentPlatform,
          'version': state.clientVersion,
          'build': '${state.clientBuild}',
          'native_version': '${AppBuildInfo.nativeVersion}',
          'native_fp': AppBuildInfo.nativeFingerprint,
          'build_id': AppBuildInfo.buildId,
          'hot_version': '${state.hotConfig.hotVersion}',
          if (token.isNotEmpty) 'token': token,
        },
      );
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final bodyStr = await utf8.decoder.bind(resp).join();
      if (!mounted) return null;
      final decoded = jsonDecode(bodyStr) as Map<String, dynamic>;
      if (resp.statusCode != 200 || decoded['ok'] != true) {
        final msg = (decoded['message'] as String?) ??
            '检查更新失败 (HTTP ${resp.statusCode})';
        state = state.copyWith(
          checking: false,
          error: silent ? null : msg,
        );
        return null;
      }

      final decision = UpdateDecisionInfo.fromJson(decoded);
      if (decision.isHotUpdate) {
        await _fetchAndApplyHotBundle(
          client: client,
          baseUrl: baseUrl,
          token: token,
          decision: decision,
        );
        if (!mounted) return decision;
      } else {
        state = state.copyWith(
          checking: false,
          decision: decision,
          bannerDismissed: false,
          statusMessage: decision.reasonText,
          clearError: true,
        );
      }
      return state.decision ?? decision;
    } catch (e) {
      if (!mounted) return null;
      state = state.copyWith(
        checking: false,
        error: silent ? null : '检查更新异常: $e',
      );
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _fetchAndApplyHotBundle({
    required HttpClient client,
    required String baseUrl,
    required String token,
    required UpdateDecisionInfo decision,
  }) async {
    final hotUri = decision.hotBundleUrl.isNotEmpty
        ? Uri.parse(decision.hotBundleUrl)
        : Uri.parse('$baseUrl/api/updates/hot-bundle').replace(
            queryParameters: token.isNotEmpty ? {'token': token} : null,
          );
    final req = await client.getUrl(hotUri);
    final resp = await req.close().timeout(const Duration(seconds: 6));
    final bodyStr = await utf8.decoder.bind(resp).join();
    if (!mounted) return;
    final decoded = jsonDecode(bodyStr) as Map<String, dynamic>;
    final rawBundle = decoded['data'] as Map<String, dynamic>?;
    if (resp.statusCode == 200 && rawBundle != null) {
      final cfg = HotUpdateConfig.fromJson(rawBundle);
      await _saveHotConfig(cfg);
      if (!mounted) return;
      final updatedDecision = UpdateDecisionInfo(
        action: 'none',
        reason: 'hot_updated',
        reasonText: '已免重装热更新至补丁 #${cfg.hotVersion}（${cfg.changelog}）',
        installMethod: decision.installMethod,
        latestVersion: decision.latestVersion,
        latestBuild: decision.latestBuild,
        nativeVersion: decision.nativeVersion,
        packageAvailable: decision.packageAvailable,
        downloadUrl: decision.downloadUrl,
        sha256: decision.sha256,
        sizeBytes: decision.sizeBytes,
        altstoreSourceUrl: decision.altstoreSourceUrl,
        altstoreDeepLink: decision.altstoreDeepLink,
        hotVersion: cfg.hotVersion,
        hotBundleUrl: decision.hotBundleUrl,
        hotSha256: decision.hotSha256,
        changelog: cfg.changelog,
      );
      state = state.copyWith(
        checking: false,
        decision: updatedDecision,
        statusMessage: updatedDecision.reasonText,
        clearError: true,
      );
    } else {
      if (!mounted) return;
      state = state.copyWith(
        checking: false,
        decision: decision,
        error: '热更新包拉取失败',
      );
    }
  }

  Future<bool> downloadAndInstallAndroidApk() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    final decision = state.decision;
    if (decision == null || decision.downloadUrl.isEmpty) {
      state = state.copyWith(error: '当前没有可下载的 APK 安装包');
      return false;
    }
    if (state.downloading) return false;

    state = state.copyWith(
      downloading: true,
      downloadProgress: 0.0,
      statusMessage: '正在准备下载 APK...',
      clearError: true,
    );

    HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final canInstall =
          await _channel.invokeMethod<bool>('canInstallPackages') ?? true;
      if (!canInstall) {
        await _channel.invokeMethod<bool>('openInstallPermissionSettings');
        state = state.copyWith(
          downloading: false,
          clearProgress: true,
          error: '请先允许 VibeHelper 安装未知应用权限，授权后再点一次「下载并安装」',
        );
        return false;
      }

      final cacheDir =
          await _channel.invokeMethod<String>('getUpdateCacheDir');
      if (cacheDir == null || cacheDir.isEmpty) {
        throw StateError('无法获取应用缓存目录');
      }
      final outPath = '$cacheDir/vibehelper-update.apk';
      final partFile = File('$outPath.part');
      final metaFile = File('$outPath.meta');
      final outFile = File(outPath);

      final expectedSha = decision.sha256.trim().toLowerCase();
      int total = decision.sizeBytes;
      int received = 0;

      if (partFile.existsSync()) {
        final existingMeta = metaFile.existsSync()
            ? (await metaFile.readAsString()).trim().toLowerCase()
            : '';
        final existingLen = await partFile.length();
        final matchesMeta =
            expectedSha.isNotEmpty && existingMeta == expectedSha;
        final validLen =
            existingLen > 0 && (total <= 0 || existingLen <= total);
        if (matchesMeta && validLen) {
          received = existingLen;
        } else {
          await partFile.delete();
        }
      }
      await metaFile.writeAsString(expectedSha);

      const int chunkBytes = 1024 * 1024; // 1 MB resumable range chunks
      const int maxZeroProgressRetries = 8;
      int consecutiveErrors = 0;
      int lastUiBytes = received;

      while (total <= 0 || received < total) {
        final int beforeAttempt = received;
        try {
          final uri = Uri.parse(decision.downloadUrl);
          final req = await client.getUrl(uri);
          final int rangeEnd = total > 0
              ? math.min(received + chunkBytes - 1, total - 1)
              : (received + chunkBytes - 1);
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-$rangeEnd');
          final resp = await req.close().timeout(const Duration(seconds: 35));

          if (resp.statusCode == 416) {
            await resp.drain<void>();
            if (total > 0 && received >= total) break;
            throw const HttpException('下载失败 (HTTP 416)');
          }
          if (resp.statusCode == 401 ||
              resp.statusCode == 403 ||
              resp.statusCode == 404) {
            await resp.drain<void>();
            throw StateError('下载失败 (HTTP ${resp.statusCode})');
          }
          if (resp.statusCode != 206 && resp.statusCode != 200) {
            await resp.drain<void>();
            throw HttpException('下载失败 (HTTP ${resp.statusCode})');
          }

          final bool isPartial = resp.statusCode == 206;
          if (isPartial) {
            if (total <= 0) {
              final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
              final m = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(cr);
              if (m != null) {
                total = int.tryParse(m.group(1)!) ?? total;
              }
            }
          } else {
            received = 0;
            lastUiBytes = 0;
            if (total <= 0 && resp.contentLength > 0) {
              total = resp.contentLength;
            }
          }

          final sink = partFile.openWrite(
            mode: isPartial ? FileMode.append : FileMode.write,
          );
          try {
            await for (final chunk
                in resp.timeout(const Duration(seconds: 35))) {
              sink.add(chunk);
              received += chunk.length;
              if (total > 0 &&
                  ((received - lastUiBytes) >= 128 * 1024 ||
                      received >= total)) {
                lastUiBytes = received;
                state = state.copyWith(
                  downloadProgress: (received / total).clamp(0.0, 1.0),
                  statusMessage:
                      '下载中 ${(received / (1024 * 1024)).toStringAsFixed(1)} / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB',
                );
              }
            }
            await sink.flush();
          } finally {
            await sink.close();
          }

          consecutiveErrors = 0;
          if (total > 0 &&
              ((received - lastUiBytes) > 0 || received >= total)) {
            lastUiBytes = received;
            state = state.copyWith(
              downloadProgress: (received / total).clamp(0.0, 1.0),
              statusMessage:
                  '下载中 ${(received / (1024 * 1024)).toStringAsFixed(1)} / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB',
            );
          }
          if (!isPartial && total <= 0) break;
        } catch (e) {
          if (e is! HttpException &&
              e is! SocketException &&
              e is! TimeoutException &&
              e is! IOException) {
            rethrow;
          }
          received = partFile.existsSync() ? await partFile.length() : 0;
          lastUiBytes = received;
          if (received > beforeAttempt) {
            consecutiveErrors = 0;
          } else {
            consecutiveErrors += 1;
          }
          if (consecutiveErrors >= maxZeroProgressRetries) {
            rethrow;
          }
          client.close(force: true);
          client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 8);
          state = state.copyWith(
            downloadProgress:
                total > 0 ? (received / total).clamp(0.0, 1.0) : null,
            statusMessage:
                '网络波动，正在断点续传 (${(received / (1024 * 1024)).toStringAsFixed(1)} MB)...',
          );
          await Future<void>.delayed(
            Duration(milliseconds: math.min(2500, 400 * (consecutiveErrors + 1))),
          );
        }
      }

      if (received <= 0) {
        throw const HttpException('下载的 APK 为空');
      }
      if (expectedSha.isNotEmpty) {
        state = state.copyWith(statusMessage: '正在校验安装包完整性...');
        final actualSha = await compute(_sha256FilePathSync, partFile.path);
        if (actualSha != expectedSha) {
          if (partFile.existsSync()) await partFile.delete();
          if (metaFile.existsSync()) await metaFile.delete();
          throw HttpException('安装包校验失败（文件可能损坏）');
        }
      }
      if (outFile.existsSync()) await outFile.delete();
      await partFile.rename(outFile.path);
      if (metaFile.existsSync()) await metaFile.delete();
      state = state.copyWith(
        downloadProgress: 1.0,
        statusMessage: '校验通过，正在调起系统安装器...',
      );
      await _channel.invokeMethod<bool>('installLocalApk', {
        'filePath': outPath,
      });
      state = state.copyWith(
        downloading: false,
        statusMessage: '已调起系统安装器，请确认安装新版 VibeHelper',
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        downloading: false,
        clearProgress: true,
        error: '更新失败: $e',
      );
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> openIosAltStoreUpdate() async {
    final decision = state.decision;
    if (decision == null || kIsWeb || !Platform.isIOS) return false;
    try {
      final deepLink = decision.altstoreDeepLink;
      if (deepLink.isNotEmpty) {
        final canAlt = await _channel.invokeMethod<bool>(
              'canOpenUrl',
              {'url': deepLink},
            ) ??
            false;
        if (canAlt) {
          final opened = await _channel.invokeMethod<bool>(
                'openExternalUrl',
                {'url': deepLink},
              ) ??
              false;
          if (opened) {
            state = state.copyWith(
              statusMessage: '已跳转 AltStore 添加源/刷新安装新版 IPA',
              clearError: true,
            );
            return true;
          }
        }
      }
      if (decision.downloadUrl.isNotEmpty) {
        final opened = await _channel.invokeMethod<bool>(
              'openExternalUrl',
              {'url': decision.downloadUrl},
            ) ??
            false;
        if (opened) {
          state = state.copyWith(
            statusMessage: '已在浏览器开始下载 IPA，下载后可在 AltStore 中选择安装',
            clearError: true,
          );
          return true;
        }
      }
      state = state.copyWith(
        error: '无法自动调起 AltStore，请复制下方 AltStore 源地址并在 AltStore 内粘贴',
      );
      return false;
    } catch (e) {
      state = state.copyWith(error: '跳转 AltStore 失败: $e');
      return false;
    }
  }

  Future<bool> openDirectPackageUrl() async {
    final url = state.decision?.downloadUrl ?? '';
    if (url.isEmpty || kIsWeb) return false;
    try {
      if (Platform.isIOS) {
        return await _channel.invokeMethod<bool>(
              'openExternalUrl',
              {'url': url},
            ) ??
            false;
      }
    } catch (_) {}
    return false;
  }
}

final appUpdateProvider =
    StateNotifierProvider<AppUpdateController, AppUpdateState>((ref) {
  return AppUpdateController(ref);
});
