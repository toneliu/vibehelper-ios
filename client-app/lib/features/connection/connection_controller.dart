import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/vibe_socket_client.dart';
import '../../protocol/messages.dart';

class UploadFileResult {
  const UploadFileResult({
    required this.ok,
    this.filename = '',
    this.kind = 'file',
    this.pasted = false,
    this.savedPath,
    this.sizeBytes = 0,
    this.elapsedMs = 0,
    this.message,
  });

  final bool ok;
  final String filename;
  final String kind; // 'image' | 'file'
  final bool pasted;
  final String? savedPath;
  final int sizeBytes;
  final int elapsedMs;
  final String? message;
}

class ProjectListResponse {
  const ProjectListResponse({
    this.projects = const [],
    this.defaultRootDir = '',
  });

  final List<ProjectItem> projects;
  final String defaultRootDir;
}

class HostHealthProbe {
  const HostHealthProbe({
    required this.profileId,
    this.online = false,
    this.rttMs,
    this.version = '',
    this.buildId = '',
    this.osName = '',
    this.displayServer = '',
    this.windowCount = 0,
    this.agentStatus = 'idle',
    this.activeSessionTitle = '',
    this.cdpActiveCount = 0,
    this.error,
  });

  final String profileId;
  final bool online;
  final int? rttMs;
  final String version;
  final String buildId;
  final String osName;
  final String displayServer;
  final int windowCount;
  final String agentStatus;
  final String activeSessionTitle;
  final int cdpActiveCount;
  final String? error;
}

class ModelQuotaItem {
  const ModelQuotaItem({
    required this.model,
    this.remainingPercent,
    this.resetAt = '',
    this.resetIn = '',
    this.source = 'vscdb_cache',
    this.isFresh = false,
  });

  final String model;
  final double? remainingPercent;
  final String resetAt;
  final String resetIn;
  final String source;
  final bool isFresh;

  factory ModelQuotaItem.fromJson(Map<String, dynamic> json) => ModelQuotaItem(
        model: (json['model'] as String?) ?? '',
        remainingPercent: (json['remaining_percent'] as num?)?.toDouble(),
        resetAt: (json['reset_at'] as String?) ?? '',
        resetIn: (json['reset_in'] as String?) ?? '',
        source: (json['source'] as String?) ?? 'vscdb_cache',
        isFresh: (json['is_fresh'] as bool?) ?? false,
      );
}

class ModelUsageSummary {
  const ModelUsageSummary({
    required this.model,
    this.turns = 0,
    this.estTokens = 0,
  });

  final String model;
  final int turns;
  final int estTokens;

  factory ModelUsageSummary.fromJson(Map<String, dynamic> json) =>
      ModelUsageSummary(
        model: (json['model'] as String?) ?? '',
        turns: (json['turns'] as num?)?.toInt() ?? 0,
        estTokens: (json['est_tokens'] as num?)?.toInt() ?? 0,
      );
}

class HostUsageReport {
  const HostUsageReport({
    this.quotas = const [],
    this.todayTurns = 0,
    this.todayTools = 0,
    this.todaySessions = 0,
    this.todayEstTokens = 0,
    this.byModel = const [],
    this.currentSessionId = '',
    this.currentTitle = '',
    this.currentModel = '',
    this.currentModelSource = '',
    this.currentTurns = 0,
    this.currentTools = 0,
    this.currentInputTokens = 0,
    this.currentOutputTokens = 0,
    this.currentCacheReadTokens = 0,
    this.currentContextTokens = 0,
    this.currentEstTokens = 0,
    this.currentExactTokens = false,
    this.totalSessions = 0,
    this.hasLiveCdpQuota = false,
    this.note = '',
    this.error,
  });

  final List<ModelQuotaItem> quotas;
  final int todayTurns;
  final int todayTools;
  final int todaySessions;
  final int todayEstTokens;
  final List<ModelUsageSummary> byModel;
  final String currentSessionId;
  final String currentTitle;
  final String currentModel;
  final String currentModelSource;
  final int currentTurns;
  final int currentTools;
  final int currentInputTokens;
  final int currentOutputTokens;
  final int currentCacheReadTokens;
  final int currentContextTokens;
  final int currentEstTokens;
  final bool currentExactTokens;
  final int totalSessions;
  final bool hasLiveCdpQuota;
  final String note;
  final String? error;

  factory HostUsageReport.fromJson(Map<String, dynamic> json) {
    final rawQuotas = (json['quotas'] as List<dynamic>?) ?? const [];
    final today = (json['today'] as Map<String, dynamic>?) ?? const {};
    final rawByModel = (today['by_model'] as List<dynamic>?) ?? const [];
    final curr = (json['current_session'] as Map<String, dynamic>?) ?? const {};
    return HostUsageReport(
      quotas: rawQuotas
          .whereType<Map<String, dynamic>>()
          .map(ModelQuotaItem.fromJson)
          .toList(),
      todayTurns: (today['turns'] as num?)?.toInt() ?? 0,
      todayTools: (today['tool_calls'] as num?)?.toInt() ?? 0,
      todaySessions: (today['sessions'] as num?)?.toInt() ?? 0,
      todayEstTokens: (today['est_tokens'] as num?)?.toInt() ?? 0,
      byModel: rawByModel
          .whereType<Map<String, dynamic>>()
          .map(ModelUsageSummary.fromJson)
          .toList(),
      currentSessionId: (curr['session_id'] as String?) ?? '',
      currentTitle: (curr['title'] as String?) ?? '',
      currentModel: (curr['model'] as String?) ?? '',
      currentModelSource: (curr['model_source'] as String?) ?? '',
      currentTurns: (curr['turns'] as num?)?.toInt() ?? 0,
      currentTools: (curr['tool_calls'] as num?)?.toInt() ?? 0,
      currentInputTokens: (curr['input_tokens'] as num?)?.toInt() ?? 0,
      currentOutputTokens: (curr['output_tokens'] as num?)?.toInt() ?? 0,
      currentCacheReadTokens: (curr['cache_read_tokens'] as num?)?.toInt() ?? 0,
      currentContextTokens:
          (curr['latest_context_tokens'] as num?)?.toInt() ?? 0,
      currentEstTokens: (curr['est_tokens'] as num?)?.toInt() ?? 0,
      currentExactTokens: (curr['is_exact_tokens'] as bool?) ?? false,
      totalSessions: (json['total_sessions'] as num?)?.toInt() ?? 0,
      hasLiveCdpQuota: (json['has_live_cdp_quota'] as bool?) ?? false,
      note: (json['note'] as String?) ?? '',
    );
  }
}

class HostIdeApp {
  const HostIdeApp({
    required this.id,
    required this.name,
    this.installed = false,
    this.exePath = '',
    this.running = false,
    this.cdpPort = 9222,
    this.cdpActive = false,
    this.cdpPages = 0,
    this.supportsCdp = true,
    this.appKind = 'cdp',
    this.supportsAccounts = false,
    this.activeAccountId = '',
    this.activeAccountLabel = '',
    this.currentUsername = '',
    this.accountCount = 0,
  });

  final String id;
  final String name;
  final bool installed;
  final String exePath;
  final bool running;
  final int cdpPort;
  final bool cdpActive;
  final int cdpPages;
  final bool supportsCdp;
  final String appKind;
  final bool supportsAccounts;
  final String activeAccountId;
  final String activeAccountLabel;
  final String currentUsername;
  final int accountCount;

  bool get isCli => !supportsCdp || appKind == 'cli';

  factory HostIdeApp.fromJson(Map<String, dynamic> json) => HostIdeApp(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        installed: (json['installed'] as bool?) ?? false,
        exePath: (json['exe_path'] as String?) ?? '',
        running: (json['running'] as bool?) ?? false,
        cdpPort: (json['cdp_port'] as num?)?.toInt() ?? 9222,
        cdpActive: (json['cdp_active'] as bool?) ?? false,
        cdpPages: (json['cdp_pages'] as num?)?.toInt() ?? 0,
        supportsCdp: (json['supports_cdp'] as bool?) ?? true,
        appKind: (json['app_kind'] as String?) ?? 'cdp',
        supportsAccounts: (json['supports_accounts'] as bool?) ?? false,
        activeAccountId: (json['active_account_id'] as String?) ?? '',
        activeAccountLabel: (json['active_account_label'] as String?) ?? '',
        currentUsername: (json['current_username'] as String?) ?? '',
        accountCount: (json['account_count'] as num?)?.toInt() ?? 0,
      );
}

class IdeAccountItem {
  const IdeAccountItem({
    required this.id,
    required this.ideId,
    required this.label,
    this.detectedUsername = '',
    this.hasKeyringSecret = false,
    this.hasTokenFile = false,
    this.snapshotFiles = 0,
    this.isActive = false,
    this.createdAt = '',
    this.updatedAt = '',
    this.lastUsedAt = '',
  });

  final String id;
  final String ideId;
  final String label;
  final String detectedUsername;
  final bool hasKeyringSecret;
  final bool hasTokenFile;
  final int snapshotFiles;
  final bool isActive;
  final String createdAt;
  final String updatedAt;
  final String lastUsedAt;

  bool get hasPersistentCredential => hasKeyringSecret || hasTokenFile;

  factory IdeAccountItem.fromJson(Map<String, dynamic> json) => IdeAccountItem(
        id: (json['id'] as String?) ?? '',
        ideId: (json['ide_id'] as String?) ?? 'antigravity',
        label: (json['label'] as String?) ?? '',
        detectedUsername: (json['detected_username'] as String?) ?? '',
        hasKeyringSecret: (json['has_keyring_secret'] as bool?) ?? false,
        hasTokenFile: (json['has_token_file'] as bool?) ?? false,
        snapshotFiles: (json['snapshot_files'] as num?)?.toInt() ?? 0,
        isActive: (json['is_active'] as bool?) ?? false,
        createdAt: (json['created_at'] as String?) ?? '',
        updatedAt: (json['updated_at'] as String?) ?? '',
        lastUsedAt: (json['last_used_at'] as String?) ?? '',
      );
}

class IdeAccountsSnapshot {
  const IdeAccountsSnapshot({
    required this.ideId,
    this.supported = true,
    this.keyringSupported = false,
    this.hasTokenFile = false,
    this.hasActiveCredential = false,
    this.currentUsername = '',
    this.activeAccountId = '',
    this.activeAccountLabel = '',
    this.accounts = const [],
  });

  final String ideId;
  final bool supported;
  final bool keyringSupported;
  final bool hasTokenFile;
  final bool hasActiveCredential;
  final String currentUsername;
  final String activeAccountId;
  final String activeAccountLabel;
  final List<IdeAccountItem> accounts;

  factory IdeAccountsSnapshot.fromJson(Map<String, dynamic> json) {
    final rawList = (json['accounts'] as List<dynamic>?) ?? const [];
    return IdeAccountsSnapshot(
      ideId: (json['ide_id'] as String?) ?? 'antigravity',
      supported: (json['supported'] as bool?) ?? false,
      keyringSupported: (json['keyring_supported'] as bool?) ?? false,
      hasTokenFile: (json['has_token_file'] as bool?) ?? false,
      hasActiveCredential: (json['has_active_credential'] as bool?) ?? false,
      currentUsername: (json['current_username'] as String?) ?? '',
      activeAccountId: (json['active_account_id'] as String?) ?? '',
      activeAccountLabel: (json['active_account_label'] as String?) ?? '',
      accounts: rawList
          .whereType<Map<String, dynamic>>()
          .map(IdeAccountItem.fromJson)
          .toList(),
    );
  }
}

class InjectionRecord {
  const InjectionRecord({
    required this.text,
    required this.timestamp,
    required this.ok,
    this.targetWindowTitle,
    this.shortcutUsed,
    this.elapsedMs,
    this.errorMessage,
  });

  final String text;
  final DateTime timestamp;
  final bool ok;
  final String? targetWindowTitle;
  final String? shortcutUsed;
  final int? elapsedMs;
  final String? errorMessage;
}

final socketClientProvider = Provider<VibeSocketClient>((ref) {
  final client = VibeSocketClient();
  ref.onDispose(() {
    unawaited(client.dispose());
  });
  return client;
});

final socketSnapshotProvider = StreamProvider<SocketSnapshot>((ref) async* {
  final client = ref.watch(socketClientProvider);
  yield client.snapshot;
  yield* client.stateStream;
});

class InjectionHistoryNotifier extends StateNotifier<List<InjectionRecord>> {
  InjectionHistoryNotifier() : super(const []);

  void add(InjectionRecord record) {
    state = [record, ...state].take(25).toList();
  }

  void clear() {
    state = const [];
  }
}

final injectionHistoryProvider =
    StateNotifierProvider<InjectionHistoryNotifier, List<InjectionRecord>>(
  (ref) => InjectionHistoryNotifier(),
);

class HostActionController {
  HostActionController(this._ref, {this.probeOverride});

  final Ref _ref;
  final Future<HostHealthProbe> Function(HostProfile profile, Duration timeout)?
      probeOverride;
  Future<bool>? _autoConnectInFlight;

  VibeSocketClient get _client => _ref.read(socketClientProvider);

  Future<bool> connectFromSettings({
    Duration connectTimeout = const Duration(seconds: 6),
  }) async {
    await _ref.read(settingsProvider.notifier).ready;
    final settings = _ref.read(settingsProvider);
    final active = settings.activeHost;
    if (active.wsUrl.trim().isEmpty) return false;
    await _client.connect(
      wsUrl: active.wsUrl,
      token: active.token,
      clientName: settings.clientName,
      connectTimeout: connectTimeout,
    );
    return _client.snapshot.isConnected;
  }

  Future<bool> autoConnectOnStartup({bool allowFallback = true}) {
    return _ensureConnected(isResume: false, allowFallback: allowFallback);
  }

  Future<bool> reconnectOnResume({bool allowFallback = true}) {
    return _ensureConnected(isResume: true, allowFallback: allowFallback);
  }

  Future<bool> _ensureConnected({
    required bool isResume,
    required bool allowFallback,
  }) {
    final inFlight = _autoConnectInFlight;
    if (inFlight != null) return inFlight;

    final future = _runEnsureConnected(
      isResume: isResume,
      allowFallback: allowFallback,
    );
    _autoConnectInFlight = future;
    return future.whenComplete(() {
      if (identical(_autoConnectInFlight, future)) {
        _autoConnectInFlight = null;
      }
    });
  }

  Future<bool> _runEnsureConnected({
    required bool isResume,
    required bool allowFallback,
  }) async {
    await _ref.read(settingsProvider.notifier).ready;
    if (_client.isManualDisconnect) return false;

    final snap = _client.snapshot;
    if (snap.isConnected) {
      if (!isResume) return true;
      final alive = await _client.verifyAlive(
        timeout: const Duration(milliseconds: 2000),
        reconnectImmediately: false,
      );
      if (alive || _client.isManualDisconnect || _client.snapshot.isConnected) {
        return _client.snapshot.isConnected;
      }
    } else if (!isResume &&
        (snap.phase == ConnectionPhase.connecting ||
            snap.phase == ConnectionPhase.authenticating)) {
      return false;
    }

    final settings = _ref.read(settingsProvider);
    final active = settings.activeHost;
    final profiles = settings.hostProfiles;
    if (active.wsUrl.trim().isEmpty && profiles.isEmpty) return false;

    final otherProfiles = allowFallback && profiles.length > 1
        ? profiles
            .where((p) => p.id != active.id && p.wsUrl.trim().isNotEmpty)
            .toList()
        : const <HostProfile>[];

    Future<List<HostHealthProbe>>? probeFuture;
    if (otherProfiles.isNotEmpty) {
      probeFuture = Future.wait(
        otherProfiles.map((p) async {
          try {
            return await probeHostHealth(
              p,
              timeout: const Duration(seconds: 3),
            );
          } catch (e) {
            return HostHealthProbe(
              profileId: p.id,
              online: false,
              error: e.toString(),
            );
          }
        }),
      );
      unawaited(probeFuture.then<void>((_) {}, onError: (_) {}));
    }

    final initialActiveId = active.id;
    final primaryTimeout = otherProfiles.isNotEmpty
        ? const Duration(seconds: 4)
        : const Duration(seconds: 6);
    if (active.wsUrl.trim().isNotEmpty) {
      await _client.connect(
        wsUrl: active.wsUrl,
        token: active.token,
        clientName: settings.clientName,
        connectTimeout: primaryTimeout,
      );
      if (_client.snapshot.isConnected) return true;
    }

    if (probeFuture == null || _client.isManualDisconnect) {
      return _client.snapshot.isConnected;
    }

    final epochAfterActive = _client.connectEpoch;
    final probes = await probeFuture;
    if (_client.isManualDisconnect ||
        _client.snapshot.isConnected ||
        _client.connectEpoch != epochAfterActive ||
        _ref.read(settingsProvider).activeHost.id != initialActiveId) {
      return _client.snapshot.isConnected;
    }

    final indexedOnline = <({int idx, HostProfile profile, int rtt})>[];
    for (int i = 0; i < otherProfiles.length; i++) {
      final probe = probes[i];
      if (probe.online) {
        indexedOnline.add((
          idx: i,
          profile: otherProfiles[i],
          rtt: probe.rttMs ?? 999999,
        ));
      }
    }
    if (indexedOnline.isEmpty) return false;

    indexedOnline.sort((a, b) {
      final cmp = a.rtt.compareTo(b.rtt);
      return cmp != 0 ? cmp : a.idx.compareTo(b.idx);
    });

    for (final entry in indexedOnline) {
      if (_client.isManualDisconnect) return false;
      final candidate = entry.profile;
      await _ref.read(settingsProvider.notifier).selectHostProfile(candidate.id);
      await _client.connect(
        wsUrl: candidate.wsUrl,
        token: candidate.token,
        clientName: _ref.read(settingsProvider).clientName,
        connectTimeout: const Duration(seconds: 4),
      );
      if (_client.snapshot.isConnected) return true;
      if (_client.isManualDisconnect ||
          _ref.read(settingsProvider).activeHost.id != candidate.id) {
        return _client.snapshot.isConnected;
      }
    }

    if (_ref.read(settingsProvider).activeHost.id != initialActiveId) {
      await _ref.read(settingsProvider.notifier).selectHostProfile(initialActiveId);
    }
    return false;
  }

  Future<void> disconnect() => _client.disconnect();

  Future<InjectResultMessage?> injectText({
    required String text,
    required String? targetWindowId,
    String? targetWindowTitle,
    String source = 'stt_final',
    bool? autoEnter,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (!_client.snapshot.isConnected) {
      _ref.read(injectionHistoryProvider.notifier).add(
            InjectionRecord(
              text: trimmed,
              timestamp: DateTime.now(),
              ok: false,
              targetWindowTitle: targetWindowTitle,
              errorMessage: '尚未连接到被控端',
            ),
          );
      return null;
    }

    final settings = _ref.read(settingsProvider);
    final req = InjectTextMessage(
      requestId: _client.nextRequestId(),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      targetWindowId: targetWindowId,
      text: trimmed,
      autoEnter: autoEnter ?? settings.autoEnter,
      pasteShortcut: settings.pasteShortcut,
      restoreClipboard: settings.restoreClipboard,
      enterDelayMs: settings.enterDelayMs,
      source: source,
    );

    try {
      final resp = await _client.sendAndWait(req);
      if (resp is InjectResultMessage && resp.ok) {
        _ref.read(injectionHistoryProvider.notifier).add(
              InjectionRecord(
                text: trimmed,
                timestamp: DateTime.now(),
                ok: true,
                targetWindowTitle: targetWindowTitle,
                shortcutUsed: resp.shortcutUsed,
                elapsedMs: resp.elapsedMs,
              ),
            );
        return resp;
      }
      final errText = resp is ErrorMessage ? resp.message : '文本注入失败';
      _ref.read(injectionHistoryProvider.notifier).add(
            InjectionRecord(
              text: trimmed,
              timestamp: DateTime.now(),
              ok: false,
              targetWindowTitle: targetWindowTitle,
              errorMessage: errText,
            ),
          );
      return null;
    } catch (e) {
      _ref.read(injectionHistoryProvider.notifier).add(
            InjectionRecord(
              text: trimmed,
              timestamp: DateTime.now(),
              ok: false,
              targetWindowTitle: targetWindowTitle,
              errorMessage: e.toString(),
            ),
          );
      return null;
    }
  }

  void sendSttPartial(String text, {bool isFinal = false}) {
    if (!_client.snapshot.isConnected) return;
    _client.send(
      SttPartialMessage(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        text: text,
        isFinal: isFinal,
      ),
    );
  }

  void syncDraft({required String text, String? targetWindowId}) {
    if (!_client.snapshot.isConnected) return;
    _client.send(
      SyncDraftMessage(
        requestId: _client.nextRequestId(),
        timestamp: DateTime.now().millisecondsSinceEpoch,
        targetWindowId: targetWindowId,
        text: text,
      ),
    );
  }

  void sendControlKey({
    required String key,
    List<String> modifiers = const [],
    String? targetWindowId,
  }) {
    if (!_client.snapshot.isConnected) return;
    _client.send(
      InputKeyMessage(
        requestId: _client.nextRequestId(),
        timestamp: DateTime.now().millisecondsSinceEpoch,
        key: key,
        modifiers: modifiers,
        targetWindowId: targetWindowId,
      ),
    );
  }

  /// Upload a local image or file to the Host and paste it directly into the target dialog box.
  Future<UploadFileResult> uploadFileToDialog({
    required String filePath,
    required String filename,
    String? targetWindowId,
    bool autoPaste = true,
    bool autoEnter = false,
  }) async {
    if (!_client.snapshot.isConnected) {
      return const UploadFileResult(ok: false, message: '尚未连接到被控端');
    }
    final settings = _ref.read(settingsProvider);
    final wsUri = Uri.tryParse(settings.wsUrl.trim());
    if (wsUri == null || wsUri.host.isEmpty) {
      return const UploadFileResult(ok: false, message: '被控端地址无效');
    }

    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    final query = <String, String>{
      'filename': filename,
      'auto_paste': autoPaste ? 'true' : 'false',
      'auto_enter': autoEnter ? 'true' : 'false',
      if (targetWindowId != null && targetWindowId.isNotEmpty)
        'target_window_id': targetWindowId,
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uploadUri = Uri(
      scheme: scheme,
      host: wsUri.host,
      port: wsUri.hasPort ? wsUri.port : (scheme == 'https' ? 443 : 8765),
      path: '/api/upload',
      queryParameters: query,
    );

    final httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final bytes = await File(filePath).readAsBytes();
      final req = await httpClient.postUrl(uploadUri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream');
      req.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 45));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return UploadFileResult(
          ok: decoded['ok'] == true,
          filename: (decoded['filename'] as String?) ?? filename,
          kind: (decoded['kind'] as String?) ?? 'file',
          pasted: decoded['pasted'] == true,
          savedPath: decoded['saved_path'] as String?,
          sizeBytes: (decoded['size_bytes'] as num?)?.toInt() ?? bytes.length,
          elapsedMs: (decoded['elapsed_ms'] as num?)?.toInt() ?? 0,
          message: decoded['message'] as String?,
        );
      }
      return UploadFileResult(ok: false, message: '服务器返回异常: HTTP ${resp.statusCode}');
    } catch (e) {
      return UploadFileResult(ok: false, message: '上传失败: $e');
    } finally {
      httpClient.close(force: true);
    }
  }

  Uri? _buildHostHttpUri(
    String wsUrl,
    String path, [
    Map<String, String>? query,
  ]) {
    final wsUri = Uri.tryParse(wsUrl.trim());
    if (wsUri == null || wsUri.host.isEmpty) return null;
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return Uri(
      scheme: scheme,
      host: wsUri.host,
      port: wsUri.hasPort ? wsUri.port : (scheme == 'https' ? 443 : 8765),
      path: path,
      queryParameters: (query != null && query.isNotEmpty) ? query : null,
    );
  }

  Future<HostHealthProbe> probeHostHealth(
    HostProfile profile, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (probeOverride != null) {
      return probeOverride!(profile, timeout);
    }
    final uri = _buildHostHttpUri(profile.wsUrl, '/api/health');
    if (uri == null) {
      return HostHealthProbe(
        profileId: profile.id,
        online: false,
        error: '地址无效',
      );
    }
    final sw = Stopwatch()..start();
    final httpClient = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await httpClient.getUrl(uri);
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join();
      sw.stop();
      if (resp.statusCode != 200) {
        return HostHealthProbe(
          profileId: profile.id,
          online: false,
          error: 'HTTP ${resp.statusCode}',
        );
      }
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        return HostHealthProbe(profileId: profile.id, online: false);
      }
      final info = data['host_info'] as Map<String, dynamic>?;
      return HostHealthProbe(
        profileId: profile.id,
        online: data['status'] == 'ok',
        rttMs: sw.elapsedMilliseconds,
        version: (data['version'] as String?) ?? '',
        buildId: (data['build_id'] as String?) ?? '',
        osName: (info?['os'] as String?) ?? '',
        displayServer: (info?['display_server'] as String?) ?? '',
        windowCount: (data['window_count'] as num?)?.toInt() ?? 0,
        agentStatus: (data['agent_status'] as String?) ?? 'idle',
        activeSessionTitle: (data['active_session_title'] as String?) ?? '',
        cdpActiveCount: (data['cdp_active_count'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      return HostHealthProbe(
        profileId: profile.id,
        online: false,
        error: e.toString(),
      );
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<List<HostIdeApp>?> fetchHostApps() async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uri = _buildHostHttpUri(settings.wsUrl, '/api/host/apps', query);
    if (uri == null) return null;
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await httpClient.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['ok'] == true) {
        final list = (decoded['data'] as List<dynamic>?) ?? const [];
        return list
            .whereType<Map<String, dynamic>>()
            .map(HostIdeApp.fromJson)
            .toList();
      }
    } catch (_) {
      return null;
    } finally {
      httpClient.close(force: true);
    }
    return null;
  }

  Future<(bool ok, String message)> launchHostIde(
    String ideId, {
    bool restart = false,
    String? workspacePath,
  }) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uri =
        _buildHostHttpUri(settings.wsUrl, '/api/host/launch-ide', query);
    if (uri == null) return (false, 'Host 地址无效');
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await httpClient.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'ide_id': ideId,
        'restart_if_running': restart,
        if (workspacePath != null && workspacePath.trim().isNotEmpty)
          'workspace_path': workspacePath.trim(),
      }));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return (
          decoded['ok'] == true,
          (decoded['message'] as String?) ?? '操作完成',
        );
      }
      return (false, '返回格式异常');
    } catch (e) {
      return (false, '启动 IDE 请求失败: $e');
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<(bool ok, String? windowId, String message)> focusHostIde(
    String ideId,
  ) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uri = _buildHostHttpUri(settings.wsUrl, '/api/host/focus-ide', query);
    if (uri == null) return (false, null, 'Host 地址无效');
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await httpClient.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'ide_id': ideId}));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final win = decoded['window'] as Map<String, dynamic>?;
        return (
          decoded['ok'] == true,
          win?['id'] as String?,
          (decoded['message'] as String?) ?? '',
        );
      }
      return (false, null, '返回格式异常');
    } catch (e) {
      return (false, null, '切换 IDE 失败: $e');
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<HostUsageReport> fetchHostUsage({
    String? sessionId,
    String? windowId,
  }) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
      if (sessionId != null && sessionId.trim().isNotEmpty)
        'session_id': sessionId.trim(),
      if (windowId != null && windowId.trim().isNotEmpty)
        'window_id': windowId.trim(),
    };
    final uri = _buildHostHttpUri(settings.wsUrl, '/api/host/usage', query);
    if (uri == null) {
      return const HostUsageReport(error: 'Host 地址无效，请先在「主机」页配置连接');
    }
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await httpClient.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        if (decoded['ok'] == true && decoded['data'] is Map<String, dynamic>) {
          return HostUsageReport.fromJson(
            decoded['data'] as Map<String, dynamic>,
          );
        }
        return HostUsageReport(
          error: (decoded['message'] as String?) ?? '查询失败',
        );
      }
      return const HostUsageReport(error: '返回格式异常');
    } catch (e) {
      return HostUsageReport(error: '连接宿主机查询失败: $e');
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<
      ({
        String activeModel,
        List<String> models,
        String source,
        String activePermissionMode,
        List<({String id, String label, String zh})> permissionModes,
      })> fetchHostModels({String? windowId}) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
      if (windowId != null && windowId.trim().isNotEmpty)
        'window_id': windowId.trim(),
    };
    final uri = _buildHostHttpUri(settings.wsUrl, '/api/host/models', query);
    if (uri == null) {
      return (
        activeModel: '',
        models: const <String>[],
        source: '',
        activePermissionMode: '',
        permissionModes: const <({String id, String label, String zh})>[],
      );
    }
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await httpClient.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> &&
          decoded['ok'] == true &&
          decoded['data'] is Map<String, dynamic>) {
        final data = decoded['data'] as Map<String, dynamic>;
        final rawList = data['models'];
        final models = rawList is List
            ? rawList
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList()
            : const <String>[];
        final rawPerms = data['permission_modes'];
        final permissionModes = <({String id, String label, String zh})>[];
        if (rawPerms is List) {
          for (final item in rawPerms) {
            if (item is! Map) continue;
            final id = (item['id'] as String?)?.trim() ?? '';
            if (id.isEmpty) continue;
            final label = (item['label'] as String?)?.trim() ?? id;
            final zh = (item['zh'] as String?)?.trim() ?? label;
            permissionModes.add((id: id, label: label, zh: zh));
          }
        }
        return (
          activeModel: (data['active_model'] as String?)?.trim() ?? '',
          models: models,
          source: (data['model_source'] as String?)?.trim() ?? '',
          activePermissionMode:
              (data['active_permission_mode'] as String?)?.trim() ?? '',
          permissionModes: permissionModes,
        );
      }
    } catch (_) {
    } finally {
      httpClient.close(force: true);
    }
    return (
      activeModel: '',
      models: const <String>[],
      source: '',
      activePermissionMode: '',
      permissionModes: const <({String id, String label, String zh})>[],
    );
  }

  Future<ProjectListResponse?> fetchProjects() async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uri = _buildHostHttpUri(settings.wsUrl, '/api/projects', query);
    if (uri == null) return null;
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await httpClient.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['ok'] == true) {
        final rawList = (decoded['projects'] as List<dynamic>?) ?? const [];
        final projects = rawList
            .whereType<Map<String, dynamic>>()
            .map(ProjectItem.fromJson)
            .toList();
        return ProjectListResponse(
          projects: projects,
          defaultRootDir:
              (decoded['default_root_dir'] as String?)?.trim() ?? '',
        );
      }
    } catch (_) {
      return null;
    } finally {
      httpClient.close(force: true);
    }
    return null;
  }

  Future<(bool ok, ProjectItem? project, String message)> createProject({
    required String name,
    String? parentDir,
    String? path,
    String description = '',
    bool initGit = true,
    bool createReadme = true,
    bool openInIde = true,
    String ideId = 'antigravity',
  }) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uri = _buildHostHttpUri(settings.wsUrl, '/api/projects', query);
    if (uri == null) return (false, null, 'Host 地址无效');
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await httpClient.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'name': name.trim(),
        if (parentDir != null && parentDir.trim().isNotEmpty)
          'parent_dir': parentDir.trim(),
        if (path != null && path.trim().isNotEmpty) 'path': path.trim(),
        'description': description.trim(),
        'init_git': initGit,
        'create_readme': createReadme,
        'open_in_ide': openInIde,
        'ide_id': ideId,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final ok = resp.statusCode == 200 && decoded['ok'] == true;
        final rawProj = decoded['project'];
        final proj = rawProj is Map<String, dynamic>
            ? ProjectItem.fromJson(rawProj)
            : null;
        final ideLaunch = decoded['ide_launch'];
        String msg = (decoded['message'] as String?) ?? '';
        if (ok && msg.isEmpty) {
          msg = ideLaunch is Map<String, dynamic> &&
                  (ideLaunch['message'] as String?)?.isNotEmpty == true
              ? '已创建项目「${proj?.name ?? name}」，${ideLaunch['message']}'
              : '已创建项目「${proj?.name ?? name}」';
        }
        return (ok, proj, msg.isNotEmpty ? msg : (ok ? '项目已创建' : '创建失败'));
      }
      return (false, null, '返回格式异常');
    } catch (e) {
      return (false, null, '创建项目失败: $e');
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<(bool ok, String message)> assignSessionProject({
    required String sessionId,
    required String projectId,
    String projectName = '',
    String projectPath = '',
  }) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uri =
        _buildHostHttpUri(settings.wsUrl, '/api/projects/assign', query);
    if (uri == null) return (false, 'Host 地址无效');
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await httpClient.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'session_id': sessionId,
        'project_id': projectId,
        if (projectName.isNotEmpty) 'project_name': projectName,
        if (projectPath.isNotEmpty) 'project_path': projectPath,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final ok = resp.statusCode == 200 && decoded['ok'] == true;
        final msg = (decoded['message'] as String?) ??
            (ok
                ? (projectId.isEmpty ? '已恢复自动识别项目' : '已更新会话归属项目')
                : '归类失败');
        return (ok, msg);
      }
      return (false, '返回格式异常');
    } catch (e) {
      return (false, '更新项目归属失败: $e');
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<(bool ok, String message)> openProjectInIde({
    required String projectId,
    String ideId = 'antigravity',
  }) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final safeId = Uri.encodeComponent(projectId);
    final uri =
        _buildHostHttpUri(settings.wsUrl, '/api/projects/$safeId/open', query);
    if (uri == null) return (false, 'Host 地址无效');
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await httpClient.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'ide_id': ideId}));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return (
          resp.statusCode == 200 && decoded['ok'] == true,
          (decoded['message'] as String?) ?? '操作完成',
        );
      }
      return (false, '返回格式异常');
    } catch (e) {
      return (false, '打开项目失败: $e');
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<bool> deleteProject(String projectId) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final safeId = Uri.encodeComponent(projectId);
    final uri =
        _buildHostHttpUri(settings.wsUrl, '/api/projects/$safeId', query);
    if (uri == null) return false;
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await httpClient.deleteUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return resp.statusCode == 200 &&
          decoded is Map<String, dynamic> &&
          decoded['ok'] == true;
    } catch (_) {
      return false;
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<(bool ok, String message, Map<String, dynamic>? data)> _accountHttpJson(
    String method,
    String path, {
    Map<String, String>? extraQuery,
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final settings = _ref.read(settingsProvider);
    final query = <String, String>{
      if (extraQuery != null) ...extraQuery,
      if (settings.token.trim().isNotEmpty) 'token': settings.token.trim(),
    };
    final uri = _buildHostHttpUri(settings.wsUrl, path, query);
    if (uri == null) return (false, 'Host 地址无效', null);
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final HttpClientRequest req;
      switch (method) {
        case 'GET':
          req = await httpClient.getUrl(uri);
        case 'POST':
          req = await httpClient.postUrl(uri);
        case 'PATCH':
          req = await httpClient.patchUrl(uri);
        case 'DELETE':
          req = await httpClient.deleteUrl(uri);
        default:
          req = await httpClient.openUrl(method, uri);
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(timeout);
      final raw = await resp.transform(utf8.decoder).join();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final ok = resp.statusCode >= 200 &&
            resp.statusCode < 300 &&
            decoded['ok'] == true;
        final msg = (decoded['message'] as String?) ?? (ok ? '操作完成' : '请求失败');
        return (ok, msg, decoded);
      }
      return (false, '返回格式异常', null);
    } catch (e) {
      return (false, '账号请求失败: $e', null);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<IdeAccountsSnapshot?> fetchIdeAccounts({
    String ideId = 'antigravity',
  }) async {
    final (ok, _, decoded) = await _accountHttpJson(
      'GET',
      '/api/host/accounts',
      extraQuery: {'ide_id': ideId},
    );
    if (!ok || decoded == null) return null;
    return IdeAccountsSnapshot.fromJson(decoded);
  }

  Future<(bool ok, String message)> saveIdeAccount({
    String ideId = 'antigravity',
    String label = '',
    String? accountId,
  }) async {
    final (ok, msg, _) = await _accountHttpJson(
      'POST',
      '/api/host/accounts/save',
      body: {
        'ide_id': ideId,
        'label': label,
        if (accountId != null && accountId.isNotEmpty) 'account_id': accountId,
      },
    );
    return (ok, msg);
  }

  Future<(bool ok, String message)> switchIdeAccount({
    String ideId = 'antigravity',
    required String accountId,
  }) async {
    final (ok, msg, _) = await _accountHttpJson(
      'POST',
      '/api/host/accounts/switch',
      body: {
        'ide_id': ideId,
        'account_id': accountId,
      },
      timeout: const Duration(seconds: 25),
    );
    return (ok, msg);
  }

  Future<(bool ok, String message)> prepareIdeAccountLogin({
    String ideId = 'antigravity',
  }) async {
    final (ok, msg, _) = await _accountHttpJson(
      'POST',
      '/api/host/accounts/prepare-login',
      body: {'ide_id': ideId},
      timeout: const Duration(seconds: 25),
    );
    return (ok, msg);
  }

  Future<(bool ok, String message)> renameIdeAccount({
    String ideId = 'antigravity',
    required String accountId,
    required String label,
  }) async {
    final safeId = Uri.encodeComponent(accountId);
    final (ok, msg, _) = await _accountHttpJson(
      'PATCH',
      '/api/host/accounts/$safeId',
      body: {'ide_id': ideId, 'label': label},
    );
    return (ok, msg);
  }

  Future<(bool ok, String message)> deleteIdeAccount({
    String ideId = 'antigravity',
    required String accountId,
  }) async {
    final safeId = Uri.encodeComponent(accountId);
    final (ok, msg, _) = await _accountHttpJson(
      'DELETE',
      '/api/host/accounts/$safeId',
      extraQuery: {'ide_id': ideId},
    );
    return (ok, msg);
  }
}

final hostActionProvider = Provider<HostActionController>((ref) {
  return HostActionController(ref);
});
