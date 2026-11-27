import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native mobile platform bridge for:
/// 1) System notifications (Android NotificationManager + iOS UNUserNotificationCenter)
/// 2) Compact draggable floating mini-window (`SYSTEM_ALERT_WINDOW`, Android only)
/// 3) Top punch-hole Dynamic Island overlay with pixel pet (Android Accessibility, iOS uses in-app capsule)
/// 4) Foreground keep-alive service (Android MIUI/HyperOS)
///
/// Safe no-op on Desktop / Web and graceful fallback for unsupported native capabilities.
class OverlayNotifier {
  OverlayNotifier._();

  static const MethodChannel _channel = MethodChannel('vibehelper/overlay');

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isIOS => !kIsWeb && Platform.isIOS;
  static bool get isNotificationSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  static bool get isIslandSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  static bool get isOverlaySupported => !kIsWeb && Platform.isAndroid;
  static bool get isSupported => isOverlaySupported;

  static void setActionHandler(void Function(String action)? handler) {
    if (!isNotificationSupported) return;
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOverlayAction' && call.arguments is Map) {
        final action = (call.arguments as Map)['action']?.toString() ?? '';
        if (action.isNotEmpty) {
          handler(action);
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // System Notifications (Android & iOS UNUserNotificationCenter)
  // ---------------------------------------------------------------------------

  static Future<bool> canPostNotifications() async {
    if (!isNotificationSupported) return false;
    try {
      final granted =
          await _channel.invokeMethod<bool>('canPostNotifications');
      return granted ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> requestNotificationPermission() async {
    if (!isNotificationSupported) return;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> openNotificationSettings() async {
    if (!isNotificationSupported) return;
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> showSystemNotification({
    required String title,
    required String body,
    bool showActions = false,
    int id = 1001,
  }) async {
    if (!isNotificationSupported) return;
    try {
      await _channel.invokeMethod<void>('showSystemNotification', {
        'id': id,
        'title': title,
        'body': body,
        'showActions': showActions,
      });
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> cancelSystemNotification({int id = 1001}) async {
    if (!isNotificationSupported) return;
    try {
      await _channel.invokeMethod<void>('cancelSystemNotification', {'id': id});
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  // ---------------------------------------------------------------------------
  // Compact Floating Mini-Window & Shared Overlay Permission
  // ---------------------------------------------------------------------------

  static Future<bool> canDrawOverlays() async {
    if (!isSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('canDrawOverlays');
      return granted ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> requestOverlayPermission() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('requestOverlayPermission');
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> showMiniWindow({
    required String title,
    required String body,
    String status = 'idle',
    bool showActions = false,
    bool isDark = false,
    bool expanded = false,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('showMiniWindow', {
        'title': title,
        'body': body,
        'status': status,
        'showActions': showActions,
        'isDark': isDark,
        'expanded': expanded,
      });
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> updateMiniWindow({
    required String title,
    required String body,
    String status = 'idle',
    bool showActions = false,
    bool isDark = false,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('updateMiniWindow', {
        'title': title,
        'body': body,
        'status': status,
        'showActions': showActions,
        'isDark': isDark,
      });
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> hideMiniWindow() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('hideMiniWindow');
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  // ---------------------------------------------------------------------------
  // Dynamic Island Overlay (Top Punch-Hole Capsule + Pixel Pet)
  // ---------------------------------------------------------------------------

  static Future<bool> isAccessibilityIslandEnabled() async {
    if (!isSupported) return false;
    try {
      final enabled =
          await _channel.invokeMethod<bool>('isAccessibilityIslandEnabled');
      return enabled ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> openAccessibilitySettings() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('openAccessibilitySettings');
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> showIsland({
    required String title,
    required String body,
    String status = 'idle',
    bool showActions = false,
    String petType = 'shiba',
    bool autoExpand = true,
    int yOffsetDp = 6,
    int widthDp = 140,
    bool expanded = false,
    String? healthUrl,
    bool keepAlive = false,
  }) async {
    if (!isIslandSupported) return;
    try {
      await _channel.invokeMethod<void>('showIsland', {
        'title': title,
        'body': body,
        'status': status,
        'showActions': showActions,
        'petType': petType,
        'autoExpand': autoExpand,
        'yOffsetDp': yOffsetDp,
        'widthDp': widthDp,
        'expanded': expanded,
        if (healthUrl != null && healthUrl.isNotEmpty) 'healthUrl': healthUrl,
        'keepAlive': keepAlive,
      });
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> updateIsland({
    required String title,
    required String body,
    String status = 'idle',
    bool showActions = false,
    String petType = 'shiba',
    bool autoExpand = true,
    int yOffsetDp = 6,
    int widthDp = 140,
    String? healthUrl,
    bool keepAlive = false,
  }) async {
    if (!isIslandSupported) return;
    try {
      await _channel.invokeMethod<void>('updateIsland', {
        'title': title,
        'body': body,
        'status': status,
        'showActions': showActions,
        'petType': petType,
        'autoExpand': autoExpand,
        'yOffsetDp': yOffsetDp,
        'widthDp': widthDp,
        if (healthUrl != null && healthUrl.isNotEmpty) 'healthUrl': healthUrl,
        'keepAlive': keepAlive,
      });
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> hideIsland() async {
    if (!isIslandSupported) return;
    try {
      await _channel.invokeMethod<void>('hideIsland');
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  // ---------------------------------------------------------------------------
  // Foreground Keep-Alive Service (MIUI / HyperOS)
  // ---------------------------------------------------------------------------

  static Future<void> startKeepAlive({
    String subtitle = '正在后台保持宿主机实时连接',
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('startKeepAlive', {
        'subtitle': subtitle,
      });
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> stopKeepAlive() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopKeepAlive');
    } on MissingPluginException {
    } on PlatformException {
    }
  }
}
