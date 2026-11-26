import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/vibe_socket_client.dart';
import '../../protocol/messages.dart';
import '../connection/connection_controller.dart';

class WindowListState {
  const WindowListState({
    this.windows = const [],
    this.selectedWindowId,
    this.searchQuery = '',
    this.includeMinimized = false,
    this.isLoading = false,
    this.error,
  });

  final List<WindowInfo> windows;
  final String? selectedWindowId;
  final String searchQuery;
  final bool includeMinimized;
  final bool isLoading;
  final String? error;

  WindowInfo? get selectedWindow {
    if (selectedWindowId == null) return null;
    for (final w in windows) {
      if (w.id == selectedWindowId) return w;
    }
    return null;
  }

  List<WindowInfo> get filteredWindows {
    final q = searchQuery.trim().toLowerCase();
    if (q.isEmpty) return windows;
    return windows
        .where((w) =>
            w.title.toLowerCase().contains(q) ||
            w.app.toLowerCase().contains(q) ||
            w.id.toLowerCase().contains(q))
        .toList();
  }

  WindowListState copyWith({
    List<WindowInfo>? windows,
    String? selectedWindowId,
    bool clearSelected = false,
    String? searchQuery,
    bool? includeMinimized,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return WindowListState(
      windows: windows ?? this.windows,
      selectedWindowId: clearSelected
          ? null
          : (selectedWindowId ?? this.selectedWindowId),
      searchQuery: searchQuery ?? this.searchQuery,
      includeMinimized: includeMinimized ?? this.includeMinimized,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class WindowController extends StateNotifier<WindowListState> {
  WindowController(this._client) : super(const WindowListState()) {
    _stateSub = _client.stateStream.listen((snap) {
      if (snap.isConnected) {
        unawaited(refresh());
      } else if (snap.phase == ConnectionPhase.disconnected ||
          snap.phase == ConnectionPhase.connecting) {
        state = state.copyWith(
          windows: const [],
          clearSelected: true,
          isLoading: false,
        );
      }
    });
  }

  final VibeSocketClient _client;
  StreamSubscription<SocketSnapshot>? _stateSub;

  Future<void> refresh() async {
    if (!_client.snapshot.isConnected) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final resp = await _client.sendAndWait(
        GetWindowsMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          includeMinimized: state.includeMinimized,
        ),
      );
      if (resp is WindowListMessage) {
        String? autoSelectId = state.selectedWindowId;
        final existsInNewList = autoSelectId != null &&
            resp.data.any((w) => w.id == autoSelectId);
        if (!existsInNewList) {
          autoSelectId = null;
        }
        if (autoSelectId == null && resp.data.isNotEmpty) {
          for (final w in resp.data) {
            final appLow = w.app.toLowerCase();
            final titleLow = w.title.toLowerCase();
            if (appLow.contains('antigravity') ||
                appLow.contains('workbuddy') ||
                appLow.contains('cursor') ||
                appLow.contains('chatgpt') ||
                appLow.contains('claude') ||
                appLow == 'code' ||
                appLow == 'code.exe' ||
                titleLow.contains('visual studio code')) {
              autoSelectId = w.id;
              break;
            }
          }
          autoSelectId ??= resp.data.first.id;
        }
        state = state.copyWith(
          windows: resp.data,
          selectedWindowId: autoSelectId,
          clearSelected: autoSelectId == null,
          isLoading: false,
          clearError: true,
        );
      } else if (resp is ErrorMessage) {
        state = state.copyWith(isLoading: false, error: resp.message);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '刷新窗口失败: $e');
    }
  }

  void selectWindow(String? windowId) {
    if (windowId == null) {
      state = state.copyWith(clearSelected: true);
    } else {
      state = state.copyWith(selectedWindowId: windowId);
      unawaited(focusWindow(windowId));
    }
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  Future<void> setIncludeMinimized(bool value) async {
    state = state.copyWith(includeMinimized: value);
    await refresh();
  }

  Future<bool> focusWindow(String windowId) async {
    if (!_client.snapshot.isConnected) return false;
    try {
      final resp = await _client.sendAndWait(
        FocusWindowMessage(
          requestId: _client.nextRequestId(),
          timestamp: DateTime.now().millisecondsSinceEpoch,
          targetWindowId: windowId,
        ),
      );
      if (resp is FocusResultMessage && resp.ok) {
        return true;
      }
      if (resp is ErrorMessage) {
        state = state.copyWith(error: resp.message);
      }
      return false;
    } catch (e) {
      state = state.copyWith(error: '激活窗口失败: $e');
      return false;
    }
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    super.dispose();
  }
}

final windowControllerProvider =
    StateNotifierProvider<WindowController, WindowListState>((ref) {
  final client = ref.watch(socketClientProvider);
  return WindowController(client);
});
