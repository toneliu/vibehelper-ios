import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/messages.dart';

enum VoiceInputEngine {
  imeDirect('ime_direct', '输入法语音直发（推荐/兼容小米）'),
  nativeStt('native_stt', '系统原生 SpeechRecognizer');

  const VoiceInputEngine(this.id, this.label);
  final String id;
  final String label;

  static VoiceInputEngine fromId(String? value) {
    return VoiceInputEngine.values.firstWhere(
      (e) => e.id == value,
      orElse: () => VoiceInputEngine.imeDirect,
    );
  }
}

enum VoiceCaptureMode {
  pushToTalk('ptt', '按住说话 (PTT)'),
  continuous('continuous', '连续听写');

  const VoiceCaptureMode(this.id, this.label);
  final String id;
  final String label;

  static VoiceCaptureMode fromId(String? value) {
    return VoiceCaptureMode.values.firstWhere(
      (e) => e.id == value,
      orElse: () => VoiceCaptureMode.pushToTalk,
    );
  }
}

enum DesktopHotkeyPreset {
  altSpace('alt_space', 'Alt + Space'),
  ctrlAltV('ctrl_alt_v', 'Ctrl + Alt + V'),
  f9('f9', 'F9');

  const DesktopHotkeyPreset(this.id, this.label);
  final String id;
  final String label;

  static DesktopHotkeyPreset fromId(String? value) {
    return DesktopHotkeyPreset.values.firstWhere(
      (e) => e.id == value,
      orElse: () => DesktopHotkeyPreset.altSpace,
    );
  }
}

/// Normalize user-entered host address (`192.168.1.10`, `192.168.1.10:8765`, or full `ws://...`)
/// into a canonical `ws://host:port/ws` URL.
String normalizeWsUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'ws://127.0.0.1:8765/ws';
  if (trimmed.startsWith('ws://') || trimmed.startsWith('wss://')) {
    final uri = Uri.tryParse(trimmed);
    if (uri != null && (uri.path.isEmpty || uri.path == '/')) {
      return uri.replace(path: '/ws').toString();
    }
    return trimmed;
  }
  var cleaned = trimmed
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceAll(RegExp(r'/+$'), '');
  if (!cleaned.contains('/')) {
    if (!cleaned.contains(':')) {
      cleaned = '$cleaned:8765';
    }
    return 'ws://$cleaned/ws';
  }
  return 'ws://$cleaned';
}

String inferHostLabel(String wsUrl) {
  final uri = Uri.tryParse(wsUrl);
  if (uri != null && uri.host.isNotEmpty) {
    return uri.hasPort && uri.port != 8765
        ? '${uri.host}:${uri.port}'
        : uri.host;
  }
  return wsUrl;
}

class HostProfile {
  const HostProfile({
    required this.id,
    required this.name,
    required this.wsUrl,
    this.token = '',
  });

  final String id;
  final String name;
  final String wsUrl;
  final String token;

  HostProfile copyWith({
    String? id,
    String? name,
    String? wsUrl,
    String? token,
  }) {
    return HostProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      wsUrl: wsUrl ?? this.wsUrl,
      token: token ?? this.token,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ws_url': wsUrl,
        'token': token,
      };

  factory HostProfile.fromJson(Map<String, dynamic> json) => HostProfile(
        id: (json['id'] as String?) ??
            'host-${DateTime.now().millisecondsSinceEpoch}',
        name: (json['name'] as String?) ?? '主机',
        wsUrl: normalizeWsUrl((json['ws_url'] as String?) ?? ''),
        token: (json['token'] as String?) ?? '',
      );
}

class AppSettings {
  const AppSettings({
    this.wsUrl = 'ws://192.168.199.10:8765/ws',
    this.token = '',
    this.clientName = 'VibeHelper Client',
    this.hostProfiles = const [],
    this.activeHostId = 'default',
    this.voiceEngine = VoiceInputEngine.imeDirect,
    this.imeAutoSendOnPause = false,
    this.sttLocale = 'zh_CN',
    this.voiceMode = VoiceCaptureMode.pushToTalk,
    this.autoEnter = true,
    this.pasteShortcut = PasteShortcut.auto,
    this.restoreClipboard = true,
    this.enterDelayMs = 80,
    this.desktopHotkey = DesktopHotkeyPreset.altSpace,
    this.isDarkTheme = false,
    this.systemNotifications = true,
    this.overlayMode = 'off', // 'off' | 'island' | 'mini'
    this.islandPet = 'shiba', // 'shiba' | 'cat' | 'bot'
    this.islandAutoExpand = true,
    this.islandYOffset = 6,
    this.islandWidth = 140,
    this.backgroundKeepAlive = true,
    this.vadUseLocalOverride = false,
    this.vadPeakThreshold = 220,
    this.vadRmsThreshold = 75,
    this.vadHangoverMs = 600,
  });

  final String wsUrl;
  final String token;
  final String clientName;
  final List<HostProfile> hostProfiles;
  final String activeHostId;
  final VoiceInputEngine voiceEngine;
  final bool imeAutoSendOnPause;
  final String sttLocale;
  final VoiceCaptureMode voiceMode;
  final bool autoEnter;
  final PasteShortcut pasteShortcut;
  final bool restoreClipboard;
  final int enterDelayMs;
  final DesktopHotkeyPreset desktopHotkey;
  final bool isDarkTheme;
  final bool systemNotifications;
  final String overlayMode;
  final String islandPet;
  final bool islandAutoExpand;
  final int islandYOffset;
  final int islandWidth;
  final bool backgroundKeepAlive;
  final bool vadUseLocalOverride;
  final int vadPeakThreshold;
  final int vadRmsThreshold;
  final int vadHangoverMs;

  HostProfile get activeHost {
    for (final h in hostProfiles) {
      if (h.id == activeHostId) return h;
    }
    if (hostProfiles.isNotEmpty) return hostProfiles.first;
    return HostProfile(
      id: 'default',
      name: inferHostLabel(wsUrl),
      wsUrl: wsUrl,
      token: token,
    );
  }

  AppSettings copyWith({
    String? wsUrl,
    String? token,
    String? clientName,
    List<HostProfile>? hostProfiles,
    String? activeHostId,
    VoiceInputEngine? voiceEngine,
    bool? imeAutoSendOnPause,
    String? sttLocale,
    VoiceCaptureMode? voiceMode,
    bool? autoEnter,
    PasteShortcut? pasteShortcut,
    bool? restoreClipboard,
    int? enterDelayMs,
    DesktopHotkeyPreset? desktopHotkey,
    bool? isDarkTheme,
    bool? systemNotifications,
    String? overlayMode,
    String? islandPet,
    bool? islandAutoExpand,
    int? islandYOffset,
    int? islandWidth,
    bool? backgroundKeepAlive,
    bool? vadUseLocalOverride,
    int? vadPeakThreshold,
    int? vadRmsThreshold,
    int? vadHangoverMs,
  }) {
    return AppSettings(
      wsUrl: wsUrl ?? this.wsUrl,
      token: token ?? this.token,
      clientName: clientName ?? this.clientName,
      hostProfiles: hostProfiles ?? this.hostProfiles,
      activeHostId: activeHostId ?? this.activeHostId,
      voiceEngine: voiceEngine ?? this.voiceEngine,
      imeAutoSendOnPause: imeAutoSendOnPause ?? this.imeAutoSendOnPause,
      sttLocale: sttLocale ?? this.sttLocale,
      voiceMode: voiceMode ?? this.voiceMode,
      autoEnter: autoEnter ?? this.autoEnter,
      pasteShortcut: pasteShortcut ?? this.pasteShortcut,
      restoreClipboard: restoreClipboard ?? this.restoreClipboard,
      enterDelayMs: enterDelayMs ?? this.enterDelayMs,
      desktopHotkey: desktopHotkey ?? this.desktopHotkey,
      isDarkTheme: isDarkTheme ?? this.isDarkTheme,
      systemNotifications: systemNotifications ?? this.systemNotifications,
      overlayMode: overlayMode ?? this.overlayMode,
      islandPet: islandPet ?? this.islandPet,
      islandAutoExpand: islandAutoExpand ?? this.islandAutoExpand,
      islandYOffset: islandYOffset ?? this.islandYOffset,
      islandWidth: islandWidth ?? this.islandWidth,
      backgroundKeepAlive: backgroundKeepAlive ?? this.backgroundKeepAlive,
      vadUseLocalOverride: vadUseLocalOverride ?? this.vadUseLocalOverride,
      vadPeakThreshold: vadPeakThreshold ?? this.vadPeakThreshold,
      vadRmsThreshold: vadRmsThreshold ?? this.vadRmsThreshold,
      vadHangoverMs: vadHangoverMs ?? this.vadHangoverMs,
    );
  }
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(_defaultForPlatform()) {
    _loadFuture = _load();
  }

  late final Future<void> _loadFuture;
  Future<void> get ready => _loadFuture;

  static AppSettings _defaultForPlatform() {
    final isWin = !kIsWeb && Platform.isWindows;
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final isIOS = !kIsWeb && Platform.isIOS;
    final defaultName = isWin
        ? 'Windows Desktop'
        : (isAndroid
            ? 'Android Mobile'
            : (isIOS ? 'iPhone / iPad' : 'VibeHelper'));
    final defaultUrl =
        isWin ? 'ws://127.0.0.1:8765/ws' : 'ws://192.168.199.10:8765/ws';
    return AppSettings(
      wsUrl: defaultUrl,
      clientName: defaultName,
      hostProfiles: [
        HostProfile(
          id: 'default',
          name: isWin ? '本机 Windows' : '默认主机',
          wsUrl: defaultUrl,
        ),
      ],
      activeHostId: 'default',
      voiceEngine: VoiceInputEngine.imeDirect,
    );
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final loadedUrl =
          normalizeWsUrl(prefs.getString('vh_ws_url') ?? state.wsUrl);
      final loadedToken = prefs.getString('vh_token') ?? state.token;
      var activeId = prefs.getString('vh_active_host_id') ?? 'default';

      List<HostProfile> profiles = [];
      final rawProfiles = prefs.getString('vh_host_profiles_v1');
      if (rawProfiles != null && rawProfiles.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawProfiles);
          if (decoded is List) {
            profiles = decoded
                .whereType<Map<String, dynamic>>()
                .map(HostProfile.fromJson)
                .toList();
          }
        } catch (_) {}
      }

      if (profiles.isEmpty) {
        profiles = [
          HostProfile(
            id: 'default',
            name: inferHostLabel(loadedUrl),
            wsUrl: loadedUrl,
            token: loadedToken,
          ),
        ];
        activeId = 'default';
      } else if (!profiles.any((p) => p.id == activeId)) {
        activeId = profiles.first.id;
      }

      final activeProfile = profiles.firstWhere((p) => p.id == activeId,
          orElse: () => profiles.first);

      final savedOverlayMode = prefs.getString('vh_overlay_mode');
      final migratedOverlayMode = savedOverlayMode ??
          ((prefs.getBool('vh_floating_mini') ?? false)
              ? 'mini'
              : state.overlayMode);

      state = state.copyWith(
        wsUrl: activeProfile.wsUrl,
        token: activeProfile.token,
        hostProfiles: profiles,
        activeHostId: activeProfile.id,
        clientName: prefs.getString('vh_client_name') ?? state.clientName,
        voiceEngine:
            VoiceInputEngine.fromId(prefs.getString('vh_voice_engine')),
        imeAutoSendOnPause:
            prefs.getBool('vh_ime_auto_send') ?? state.imeAutoSendOnPause,
        sttLocale: prefs.getString('vh_stt_locale') ?? state.sttLocale,
        voiceMode: VoiceCaptureMode.fromId(prefs.getString('vh_voice_mode')),
        autoEnter: prefs.getBool('vh_auto_enter') ?? state.autoEnter,
        pasteShortcut:
            PasteShortcut.fromWire(prefs.getString('vh_paste_shortcut')),
        restoreClipboard:
            prefs.getBool('vh_restore_clipboard') ?? state.restoreClipboard,
        enterDelayMs: prefs.getInt('vh_enter_delay_ms') ?? state.enterDelayMs,
        desktopHotkey:
            DesktopHotkeyPreset.fromId(prefs.getString('vh_desktop_hotkey')),
        isDarkTheme: prefs.getBool('vh_dark_theme') ?? false,
        systemNotifications:
            prefs.getBool('vh_system_notify') ?? state.systemNotifications,
        overlayMode: migratedOverlayMode,
        islandPet: prefs.getString('vh_island_pet') ?? state.islandPet,
        islandAutoExpand:
            prefs.getBool('vh_island_auto_expand') ?? state.islandAutoExpand,
        islandYOffset:
            prefs.getInt('vh_island_y_offset') ?? state.islandYOffset,
        islandWidth: prefs.getInt('vh_island_width') ?? state.islandWidth,
        backgroundKeepAlive:
            prefs.getBool('vh_bg_keep_alive') ?? state.backgroundKeepAlive,
        vadUseLocalOverride:
            prefs.getBool('vh_vad_local_override') ?? state.vadUseLocalOverride,
        vadPeakThreshold:
            prefs.getInt('vh_vad_peak') ?? state.vadPeakThreshold,
        vadRmsThreshold: prefs.getInt('vh_vad_rms') ?? state.vadRmsThreshold,
        vadHangoverMs:
            prefs.getInt('vh_vad_hangover_ms') ?? state.vadHangoverMs,
      );
    } catch (_) {}
  }

  Future<void> update(AppSettings next) async {
    // Keep active HostProfile synced when wsUrl/token are edited in settings
    final normalizedUrl = normalizeWsUrl(next.wsUrl);
    final updatedProfiles = next.hostProfiles.map((p) {
      if (p.id == next.activeHostId) {
        return p.copyWith(wsUrl: normalizedUrl, token: next.token);
      }
      return p;
    }).toList();

    final synced = next.copyWith(
      wsUrl: normalizedUrl,
      hostProfiles: updatedProfiles,
    );
    state = synced;
    await _persist(synced);
  }

  Future<void> upsertHostProfile(
    HostProfile profile, {
    bool select = true,
  }) async {
    final normalized = profile.copyWith(
      name: profile.name.trim().isEmpty
          ? inferHostLabel(profile.wsUrl)
          : profile.name.trim(),
      wsUrl: normalizeWsUrl(profile.wsUrl),
    );
    final list = [...state.hostProfiles];
    final idx = list.indexWhere((p) => p.id == normalized.id);
    if (idx >= 0) {
      list[idx] = normalized;
    } else {
      list.add(normalized);
    }

    final nextActiveId = select ? normalized.id : state.activeHostId;
    final active =
        list.firstWhere((p) => p.id == nextActiveId, orElse: () => list.first);

    final next = state.copyWith(
      hostProfiles: list,
      activeHostId: active.id,
      wsUrl: active.wsUrl,
      token: active.token,
    );
    state = next;
    await _persist(next);
  }

  Future<void> selectHostProfile(String id) async {
    final target = state.hostProfiles.where((p) => p.id == id).firstOrNull;
    if (target == null) return;
    final next = state.copyWith(
      activeHostId: target.id,
      wsUrl: target.wsUrl,
      token: target.token,
    );
    state = next;
    await _persist(next);
  }

  Future<void> deleteHostProfile(String id) async {
    if (state.hostProfiles.length <= 1) return;
    final remaining = state.hostProfiles.where((p) => p.id != id).toList();
    final active = remaining.firstWhere(
      (p) => p.id == state.activeHostId,
      orElse: () => remaining.first,
    );
    final next = state.copyWith(
      hostProfiles: remaining,
      activeHostId: active.id,
      wsUrl: active.wsUrl,
      token: active.token,
    );
    state = next;
    await _persist(next);
  }

  Future<void> _persist(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    final profilesJson =
        jsonEncode(s.hostProfiles.map((p) => p.toJson()).toList());
    await Future.wait([
      prefs.setString('vh_ws_url', s.wsUrl),
      prefs.setString('vh_token', s.token),
      prefs.setString('vh_active_host_id', s.activeHostId),
      prefs.setString('vh_host_profiles_v1', profilesJson),
      prefs.setString('vh_client_name', s.clientName),
      prefs.setString('vh_voice_engine', s.voiceEngine.id),
      prefs.setBool('vh_ime_auto_send', s.imeAutoSendOnPause),
      prefs.setString('vh_stt_locale', s.sttLocale),
      prefs.setString('vh_voice_mode', s.voiceMode.id),
      prefs.setBool('vh_auto_enter', s.autoEnter),
      prefs.setString('vh_paste_shortcut', s.pasteShortcut.wireValue),
      prefs.setBool('vh_restore_clipboard', s.restoreClipboard),
      prefs.setInt('vh_enter_delay_ms', s.enterDelayMs),
      prefs.setString('vh_desktop_hotkey', s.desktopHotkey.id),
      prefs.setBool('vh_dark_theme', s.isDarkTheme),
      prefs.setBool('vh_system_notify', s.systemNotifications),
      prefs.setString('vh_overlay_mode', s.overlayMode),
      prefs.setString('vh_island_pet', s.islandPet),
      prefs.setBool('vh_island_auto_expand', s.islandAutoExpand),
      prefs.setInt('vh_island_y_offset', s.islandYOffset),
      prefs.setInt('vh_island_width', s.islandWidth),
      prefs.setBool('vh_bg_keep_alive', s.backgroundKeepAlive),
      prefs.setBool('vh_vad_local_override', s.vadUseLocalOverride),
      prefs.setInt('vh_vad_peak', s.vadPeakThreshold),
      prefs.setInt('vh_vad_rms', s.vadRmsThreshold),
      prefs.setInt('vh_vad_hangover_ms', s.vadHangoverMs),
    ]);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier();
});
