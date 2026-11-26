import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../protocol/messages.dart';

/// Two-tier conversation cache (in-memory LRU + persistent SharedPreferences LRU)
/// keyed by `<hostId>::<sessionId>` so sessions open instantaneously and support
/// incremental delta sync without re-downloading full histories.
class ChatCacheStore {
  ChatCacheStore({
    this.maxMemoryEntries = 24,
    this.maxDiskEntries = 8,
    this.maxDiskEntryChars = 240000,
    this.flushDebounce = const Duration(milliseconds: 1000),
  });

  static const String _indexKey = 'vh_chat_cache_index_v1';
  static const String _entryPrefix = 'vh_chat_cache_v1_';

  final int maxMemoryEntries;
  final int maxDiskEntries;
  final int maxDiskEntryChars;
  final Duration flushDebounce;

  final LinkedHashMap<String, WindowContentMessage> _memory = LinkedHashMap();
  final List<String> _diskLru = [];
  final Map<String, String> _lastByHost = {};
  final Set<String> _dirtyKeys = {};

  SharedPreferences? _prefs;
  Future<void>? _loadFuture;
  Timer? _flushTimer;
  bool _indexDirty = false;
  bool _disposed = false;

  static String _cacheKey(String hostId, String sessionId) =>
      '$hostId::$sessionId';

  static String _entryStorageKey(String compositeKey) {
    // Two independent 32-bit FNV-1a hashes to stay portable across Dart VM & JS.
    var h1 = 0x811c9dc5;
    var h2 = 0x9e3779b9;
    for (final unit in compositeKey.codeUnits) {
      h1 ^= unit;
      h1 = (h1 * 0x01000193) & 0xFFFFFFFF;
      h2 ^= (unit + 31) & 0xFF;
      h2 = (h2 * 0x85ebca6b) & 0xFFFFFFFF;
    }
    final hex1 = h1.toRadixString(16).padLeft(8, '0');
    final hex2 = h2.toRadixString(16).padLeft(8, '0');
    return '$_entryPrefix$hex1$hex2';
  }

  Future<void> ensureLoaded() {
    return _loadFuture ??= _loadInternal();
  }

  Future<void> _loadInternal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final rawIdx = prefs.getString(_indexKey);
      if (rawIdx != null && rawIdx.isNotEmpty) {
        final decoded = jsonDecode(rawIdx);
        if (decoded is Map<String, dynamic>) {
          final rawLru = decoded['lru'];
          if (rawLru is List) {
            _diskLru
              ..clear()
              ..addAll(rawLru.map((e) => e.toString()).where((s) => s.isNotEmpty));
          }
          final rawLast = decoded['last_by_host'];
          if (rawLast is Map) {
            _lastByHost.clear();
            rawLast.forEach((k, v) {
              final ks = k.toString();
              final vs = v.toString();
              if (ks.isNotEmpty && vs.isNotEmpty) {
                _lastByHost[ks] = vs;
              }
            });
          }
        }
      }
    } catch (_) {
      // Ignore malformed cache index on startup; future writes will overwrite it.
    }
  }

  WindowContentMessage? getCached(String hostId, String sessionId) {
    if (hostId.isEmpty || sessionId.isEmpty) return null;
    final key = _cacheKey(hostId, sessionId);
    final memHit = _memory.remove(key);
    if (memHit != null) {
      _memory[key] = memHit;
      return memHit;
    }

    final prefs = _prefs;
    if (prefs == null) return null;
    final raw = prefs.getString(_entryStorageKey(key));
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final parsed = WindowContentMessage.fromJson(decoded);
      final rebuiltFullText = parsed.fullText.isNotEmpty
          ? parsed.fullText
          : buildFullTextFromBlocks(parsed.dialogBlocks);
      // Normalize volatile runtime states when hydrating cold from disk so stale
      // spinners or question cards never linger while offline.
      final normalized = WindowContentMessage(
        targetWindowId: parsed.targetWindowId,
        windowTitle: parsed.windowTitle,
        app: parsed.app,
        methodUsed: parsed.methodUsed,
        agentName: parsed.agentName,
        activeSessionId: parsed.activeSessionId ?? sessionId,
        activeModel: parsed.activeModel,
        availableModels: parsed.availableModels,
        agentStatus: 'idle',
        pendingApprovalText: '',
        pendingQuestions: const [],
        queuedMessages: const [],
        actionButtons: parsed.actionButtons,
        sessions: parsed.sessions,
        inputBoxes: parsed.inputBoxes,
        dialogBlocks: parsed.dialogBlocks,
        fullText: rebuiltFullText,
        isDelta: false,
        deltaFromIndex: 0,
        totalBlockCount: parsed.totalBlockCount > 0
            ? parsed.totalBlockCount
            : parsed.dialogBlocks.length,
        syncPrefixHash: parsed.syncPrefixHash,
        syncLastHash: parsed.syncLastHash,
        elapsedMs: parsed.elapsedMs,
        note: parsed.note,
      );
      _rememberInMemory(key, normalized);
      return normalized;
    } catch (_) {
      return null;
    }
  }

  WindowContentMessage? getLastForHost(String hostId) {
    if (hostId.isEmpty) return null;
    final sessionId = _lastByHost[hostId];
    if (sessionId == null || sessionId.isEmpty) return null;
    return getCached(hostId, sessionId);
  }

  void _rememberInMemory(String key, WindowContentMessage content) {
    _memory.remove(key);
    _memory[key] = content;
    while (_memory.length > maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  void put(
    String hostId,
    WindowContentMessage content, {
    bool immediateFlush = false,
  }) {
    final sessionId = content.activeSessionId;
    if (hostId.isEmpty ||
        sessionId == null ||
        sessionId.isEmpty ||
        content.dialogBlocks.isEmpty ||
        content.isDelta) {
      return;
    }

    final key = _cacheKey(hostId, sessionId);
    _rememberInMemory(key, content);
    _lastByHost[hostId] = sessionId;
    _diskLru.remove(key);
    _diskLru.add(key);
    _dirtyKeys.add(key);
    _indexDirty = true;

    if (_disposed) return;
    if (immediateFlush) {
      _flushTimer?.cancel();
      _flushTimer = null;
      unawaited(flush());
    } else {
      _flushTimer?.cancel();
      _flushTimer = Timer(flushDebounce, () {
        if (!_disposed) {
          unawaited(flush());
        }
      });
    }
  }

  Future<void> flush() async {
    await ensureLoaded();
    final prefs = _prefs;
    if (prefs == null) return;

    while (_diskLru.length > maxDiskEntries) {
      final evictedKey = _diskLru.removeAt(0);
      _dirtyKeys.remove(evictedKey);
      _indexDirty = true;
      await prefs.remove(_entryStorageKey(evictedKey));
    }

    final toWrite = List<String>.from(_dirtyKeys);
    _dirtyKeys.clear();
    for (final key in toWrite) {
      final item = _memory[key];
      if (item == null) continue;
      final encoded = jsonEncode(item.toCacheJson());
      if (encoded.length <= maxDiskEntryChars) {
        await prefs.setString(_entryStorageKey(key), encoded);
      } else {
        // Keep only recent tail blocks if a single session exceeds the per-entry budget.
        final trimmedBlocks = item.dialogBlocks.length > 120
            ? item.dialogBlocks.sublist(item.dialogBlocks.length - 120)
            : item.dialogBlocks;
        final compact = WindowContentMessage(
          targetWindowId: item.targetWindowId,
          windowTitle: item.windowTitle,
          app: item.app,
          methodUsed: item.methodUsed,
          agentName: item.agentName,
          activeSessionId: item.activeSessionId,
          activeModel: item.activeModel,
          availableModels: item.availableModels,
          agentStatus: item.agentStatus,
          actionButtons: item.actionButtons,
          sessions: item.sessions,
          inputBoxes: item.inputBoxes,
          dialogBlocks: trimmedBlocks,
          totalBlockCount: trimmedBlocks.length,
          syncPrefixHash: '',
          syncLastHash: '',
        );
        final compactEncoded = jsonEncode(compact.toCacheJson());
        if (compactEncoded.length <= maxDiskEntryChars) {
          await prefs.setString(_entryStorageKey(key), compactEncoded);
        } else {
          _diskLru.remove(key);
          await prefs.remove(_entryStorageKey(key));
        }
      }
      _indexDirty = true;
    }

    if (_indexDirty) {
      _indexDirty = false;
      await prefs.setString(
        _indexKey,
        jsonEncode({
          'lru': _diskLru,
          'last_by_host': _lastByHost,
        }),
      );
    }
  }

  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
