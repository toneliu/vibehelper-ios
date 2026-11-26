import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../../core/app_settings.dart';

/// Registers a system-wide global shortcut on Windows desktop for voice capture.
/// Safely no-ops on Android and Web.
class DesktopHotkeyService {
  bool get isSupported => !kIsWeb && Platform.isWindows;

  Future<void> registerPreset(
    DesktopHotkeyPreset preset, {
    required VoidCallback onTriggered,
  }) async {
    if (!isSupported) return;
    await hotKeyManager.unregisterAll();

    final HotKey hotKey = switch (preset) {
      DesktopHotkeyPreset.altSpace => HotKey(
          key: PhysicalKeyboardKey.space,
          modifiers: [HotKeyModifier.alt],
          scope: HotKeyScope.system,
        ),
      DesktopHotkeyPreset.ctrlAltV => HotKey(
          key: PhysicalKeyboardKey.keyV,
          modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
          scope: HotKeyScope.system,
        ),
      DesktopHotkeyPreset.f9 => HotKey(
          key: PhysicalKeyboardKey.f9,
          scope: HotKeyScope.system,
        ),
    };

    await hotKeyManager.register(
      hotKey,
      keyDownHandler: (_) => onTriggered(),
    );
  }

  Future<void> unregisterAll() async {
    if (!isSupported) return;
    await hotKeyManager.unregisterAll();
  }
}
