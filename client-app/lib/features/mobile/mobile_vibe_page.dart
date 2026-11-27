import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/app_build_info.dart';
import '../../core/app_settings.dart';
import '../../core/overlay_notifier.dart';
import '../../core/theme.dart';
import '../../core/vibe_socket_client.dart';
import '../../core/zoomable_viewport.dart';
import '../../protocol/messages.dart';
import '../connection/connection_controller.dart';
import '../reader/native_chat_view.dart';
import '../reader/window_content_controller.dart';
import '../stream/webrtc_stream_controller.dart';
import '../terminal/remote_terminal_view.dart';
import '../update/update_controller.dart';
import '../windows/window_controller.dart';
import '../windows/window_selector_panel.dart';
import 'access_log_sheet.dart';
import 'project_sheets.dart';

/// LingGuang-inspired minimalist 5-tab Android Vibe Coding console.
///
/// Tabs:
/// - 0 (`对话`): Pastel frosted greeting home or native AI chat + floating pill composer
/// - 1 (`控屏`): Real-time WS/WebRTC stream & interactive tap-to-click snapshot
/// - 2 (`终端`): Interactive remote PTY / PowerShell command execution over `/ws/terminal`
/// - 3 (`主机`): Multi-Host live health dashboard, AI IDE CDP launcher/switcher, target window picker
/// - 4 (`我的`): Light/Dark theme switch, voice & paste preferences, app metadata
class _PendingAttachment {
  const _PendingAttachment({
    required this.localPath,
    required this.filename,
    required this.kind,
  });

  final String localPath;
  final String filename;
  final String kind;
}

class MobileVibePage extends ConsumerStatefulWidget {
  const MobileVibePage({super.key});

  @override
  ConsumerState<MobileVibePage> createState() => _MobileVibePageState();
}

class _MobileVibePageState extends ConsumerState<MobileVibePage>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  Timer? _pauseSendTimer;
  Timer? _draftSyncDebounce;
  StreamSubscription<ProtocolMessage>? _msgSub;
  DateTime _lastLocalEditAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastSyncedDraft = '';
  bool _applyingRemoteDraft = false;
  bool _isSending = false;
  String _lastSentText = '';
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  int _tabIndex = 0; // 0: 对话, 1: 控屏, 2: 终端, 3: 主机, 4: 我的
  int _screenSubMode = 1; // 0: 静态快照, 1: 实时画面
  bool _showPlusMenu = false;
  bool _uploadingFile = false;
  bool _holdingMic = false;
  bool _startedMicByHold = false;
  final List<String> _localQueuedMessages = [];
  final Map<String, DateTime> _localQueueAddedAt = {};
  bool _queueExpanded = true;
  bool _appInBackground = false;
  bool _notifPermGranted = false;
  bool _overlayPermGranted = false;
  bool _a11yIslandEnabled = false;
  String _lastNotifKey = '';
  final List<_PendingAttachment> _pendingAttachments = [];
  OverlayEntry? _topToastEntry;
  Timer? _topToastTimer;

  // Multi-Host health probe & IDE discovery state
  Map<String, HostHealthProbe> _hostProbes = {};
  bool _probingHosts = false;
  List<HostIdeApp> _ideApps = [];
  bool _loadingApps = false;
  String? _busyIdeId;

  // Project registry & grouping state
  List<ProjectItem> _projects = const [];
  String _defaultProjectRoot = '';
  String? _selectedProjectFilterId;
  bool _loadingProjects = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputCtrl.addListener(_onInputControllerChanged);
    _msgSub = ref.read(socketClientProvider).messages.listen(_onHostMessage);
    OverlayNotifier.setActionHandler((action) {
      if (!mounted) return;
      if (action == 'overlay_closed') {
        final s = ref.read(settingsProvider);
        if (s.overlayMode != 'off') {
          unawaited(
            ref
                .read(settingsProvider.notifier)
                .update(s.copyWith(overlayMode: 'off')),
          );
        }
        return;
      }
      if (action == 'continue') {
        unawaited(_sendText(overrideText: '继续'));
        return;
      }
      if (action == 'interrupt') {
        _interruptCurrentAgent();
        return;
      }
      final key = action == 'accept'
          ? 'vh:accept'
          : (action == 'reject' ? 'vh:reject' : '');
      if (key.isEmpty) return;
      ref.read(hostActionProvider).sendControlKey(
            key: key,
            targetWindowId: ref.read(windowControllerProvider).selectedWindowId,
          );
    });
    unawaited(_refreshPermissions());
    _syncKeepAlive();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_autoConnectOnStartup());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInBackground = state != AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      unawaited(_reconnectOnResume());
      unawaited(_refreshPermissions());
      if (_tabIndex == 0) {
        unawaited(OverlayNotifier.cancelSystemNotification());
      }
    }
  }

  Future<void> _autoConnectOnStartup() async {
    await ref.read(settingsProvider.notifier).ready;
    if (!mounted) return;
    unawaited(_probeAllHosts());
    final startedAt = DateTime.now();
    final connected = await ref.read(hostActionProvider).autoConnectOnStartup();
    if (!mounted) return;
    if (connected) {
      unawaited(_loadHostApps());
      unawaited(_loadProjects());
      unawaited(ref.read(appUpdateProvider.notifier).syncOnConnected());
      final cs = ref.read(windowContentProvider);
      final contentCtrl = ref.read(windowContentProvider.notifier);
      if (!cs.isLoadingContent && !contentCtrl.hasLiveSyncSince(startedAt)) {
        unawaited(contentCtrl.fetchContent(resetSession: true));
      }
    }
  }

  Future<void> _reconnectOnResume() async {
    final ok = await ref.read(hostActionProvider).reconnectOnResume();
    if (!mounted) return;
    unawaited(_probeAllHosts());
    if (ok) {
      unawaited(_loadHostApps());
      unawaited(_loadProjects());
      unawaited(ref.read(appUpdateProvider.notifier).syncOnConnected());
      final cs = ref.read(windowContentProvider);
      if (!cs.isLoadingContent) {
        unawaited(ref.read(windowContentProvider.notifier).fetchContent());
      }
    }
  }

  Future<void> _refreshPermissions() async {
    if (!OverlayNotifier.isNotificationSupported) return;
    final notifGranted = await OverlayNotifier.canPostNotifications();
    if (!OverlayNotifier.isOverlaySupported) {
      if (mounted && notifGranted != _notifPermGranted) {
        setState(() => _notifPermGranted = notifGranted);
      }
      if (OverlayNotifier.isIOS &&
          ref.read(settingsProvider).overlayMode == 'island') {
        await _syncActiveOverlay(forceShow: true);
      }
      return;
    }
    final overlayGranted = await OverlayNotifier.canDrawOverlays();
    final a11yEnabled = await OverlayNotifier.isAccessibilityIslandEnabled();
    if (!mounted) return;
    if (notifGranted != _notifPermGranted ||
        overlayGranted != _overlayPermGranted ||
        a11yEnabled != _a11yIslandEnabled) {
      setState(() {
        _notifPermGranted = notifGranted;
        _overlayPermGranted = overlayGranted;
        _a11yIslandEnabled = a11yEnabled;
      });
    }
    final mode = ref.read(settingsProvider).overlayMode;
    final canShow = mode == 'island'
        ? (a11yEnabled || overlayGranted)
        : (mode == 'mini' && overlayGranted);
    if (canShow) {
      await _syncActiveOverlay(forceShow: true);
    }
  }

  void _syncKeepAlive() {
    if (!OverlayNotifier.isSupported) return;
    final settings = ref.read(settingsProvider);
    if (!settings.backgroundKeepAlive) {
      unawaited(OverlayNotifier.stopKeepAlive());
      return;
    }
    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    final hostName = settings.activeHost.name.trim().isNotEmpty
        ? settings.activeHost.name.trim()
        : '宿主机';
    final subtitle =
        connected ? '已连接 $hostName · 实时接收状态与通知' : '正在等待连接 $hostName';
    unawaited(OverlayNotifier.startKeepAlive(subtitle: subtitle));
  }

  ({String title, String body, String status, bool showActions})
      _buildOverlayPayload(
    WindowContentMessage? content,
    AppSettings settings,
  ) {
    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    final hostTitle = settings.activeHost.name.trim().isNotEmpty
        ? settings.activeHost.name.trim()
        : 'VibeHelper';
    if (!connected) {
      return (
        title: hostTitle,
        body: '与宿主机连接已断开，点击进入检查网络或重启 Host',
        status: 'disconnected',
        showActions: false,
      );
    }
    if (content == null) {
      return (
        title: hostTitle,
        body: '已连接，等待 Agent 消息...',
        status: 'idle',
        showActions: false,
      );
    }

    String status = content.agentStatus;
    if (status != 'waiting_approval' && content.pendingQuestions.isNotEmpty) {
      status = 'question';
    }

    String body = '';
    if (status == 'waiting_approval') {
      final t = content.pendingApprovalText.trim();
      body = t.isNotEmpty ? t : 'Agent 请求授权操作';
    } else if (status == 'question') {
      final q = content.pendingQuestions.first.question.trim();
      body = q.isNotEmpty ? q : 'Agent 发起交互提问';
    } else if (status == 'working') {
      final t = content.pendingApprovalText.trim();
      body = t.isNotEmpty ? t : 'Agent 正在执行中...';
    } else {
      for (int i = content.dialogBlocks.length - 1; i >= 0; i--) {
        final b = content.dialogBlocks[i];
        if ((b.role == 'assistant' || b.role == 'text') &&
            b.text.trim().isNotEmpty) {
          body = b.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          break;
        }
      }
      if (body.length > 120) {
        body = '${body.substring(0, 120)}…';
      }
      if (body.isEmpty) {
        body = '当前空闲';
      }
    }

    return (
      title: hostTitle,
      body: body,
      status: status,
      showActions: status == 'waiting_approval',
    );
  }

  Future<void> _syncActiveOverlay({
    bool forceShow = false,
    bool expanded = false,
  }) async {
    if (!OverlayNotifier.isOverlaySupported && !OverlayNotifier.isIOS) return;
    final settings = ref.read(settingsProvider);
    if (settings.overlayMode == 'off') {
      await OverlayNotifier.hideIsland();
      await OverlayNotifier.hideMiniWindow();
      return;
    }

    final payload =
        _buildOverlayPayload(ref.read(windowContentProvider).content, settings);

    if (OverlayNotifier.isIOS) {
      if (settings.overlayMode == 'island') {
        if (forceShow) {
          await OverlayNotifier.showIsland(
            title: payload.title,
            body: payload.body,
            status: payload.status,
            showActions: payload.showActions,
            petType: settings.islandPet,
            autoExpand: settings.islandAutoExpand,
            yOffsetDp: settings.islandYOffset,
            widthDp: settings.islandWidth,
            expanded: expanded,
          );
        } else {
          await OverlayNotifier.updateIsland(
            title: payload.title,
            body: payload.body,
            status: payload.status,
            showActions: payload.showActions,
            petType: settings.islandPet,
            autoExpand: settings.islandAutoExpand,
            yOffsetDp: settings.islandYOffset,
            widthDp: settings.islandWidth,
          );
        }
      } else {
        await OverlayNotifier.hideIsland();
      }
      return;
    }

    final granted = await OverlayNotifier.canDrawOverlays();
    final a11yEnabled = await OverlayNotifier.isAccessibilityIslandEnabled();
    if (mounted &&
        (granted != _overlayPermGranted || a11yEnabled != _a11yIslandEnabled)) {
      setState(() {
        _overlayPermGranted = granted;
        _a11yIslandEnabled = a11yEnabled;
      });
    }
    final canShow =
        settings.overlayMode == 'island' ? (a11yEnabled || granted) : granted;
    if (!canShow || !mounted) return;

    if (settings.overlayMode == 'island') {
      await OverlayNotifier.hideMiniWindow();
      if (forceShow) {
        await OverlayNotifier.showIsland(
          title: payload.title,
          body: payload.body,
          status: payload.status,
          showActions: payload.showActions,
          petType: settings.islandPet,
          autoExpand: settings.islandAutoExpand,
          yOffsetDp: settings.islandYOffset,
          widthDp: settings.islandWidth,
          expanded: expanded,
        );
      } else {
        await OverlayNotifier.updateIsland(
          title: payload.title,
          body: payload.body,
          status: payload.status,
          showActions: payload.showActions,
          petType: settings.islandPet,
          autoExpand: settings.islandAutoExpand,
          yOffsetDp: settings.islandYOffset,
          widthDp: settings.islandWidth,
        );
      }
    } else if (settings.overlayMode == 'mini') {
      await OverlayNotifier.hideIsland();
      if (forceShow) {
        await OverlayNotifier.showMiniWindow(
          title: payload.title,
          body: payload.body,
          status: payload.status,
          showActions: payload.showActions,
          isDark: settings.isDarkTheme,
          expanded: expanded,
        );
      } else {
        await OverlayNotifier.updateMiniWindow(
          title: payload.title,
          body: payload.body,
          status: payload.status,
          showActions: payload.showActions,
          isDark: settings.isDarkTheme,
        );
      }
    }
  }

  void _onWindowContentUpdated(
    WindowContentMessage? prevContent,
    WindowContentMessage? nextContent,
  ) {
    if (nextContent != null && _localQueuedMessages.isNotEmpty) {
      final serverSet = nextContent.queuedMessages.toSet();
      final now = DateTime.now();
      final beforeLen = _localQueuedMessages.length;
      _localQueuedMessages.removeWhere((m) {
        if (serverSet.contains(m)) {
          _localQueueAddedAt.remove(m);
          return true;
        }
        final added = _localQueueAddedAt[m];
        if (added != null && now.difference(added).inMilliseconds > 3500) {
          _localQueueAddedAt.remove(m);
          return true;
        }
        return false;
      });
      if (_localQueuedMessages.length != beforeLen && mounted) {
        setState(() {});
      }
    }
    if ((!OverlayNotifier.isNotificationSupported &&
            !OverlayNotifier.isOverlaySupported) ||
        nextContent == null) {
      return;
    }
    final settings = ref.read(settingsProvider);

    // 1. Live-sync active overlay (Android Dynamic Island / Mini-Window, or iOS Live Activity)
    if ((OverlayNotifier.isOverlaySupported || OverlayNotifier.isIOS) &&
        settings.overlayMode != 'off') {
      unawaited(_syncActiveOverlay());
    }

    // 2. Real Android / iOS system heads-up notification when in background or off Chat tab
    if (!OverlayNotifier.isNotificationSupported ||
        !settings.systemNotifications) {
      return;
    }

    if (nextContent.agentStatus == 'working' &&
        nextContent.pendingQuestions.isEmpty) {
      if (_lastNotifKey.startsWith('waiting_approval|')) {
        unawaited(OverlayNotifier.cancelSystemNotification());
      }
      _lastNotifKey = '';
      return;
    }

    if (!_appInBackground && _tabIndex == 0) return;

    String kind = '';
    String title = '';
    String body = '';
    bool showActions = false;

    if (nextContent.agentStatus == 'waiting_approval') {
      kind = 'waiting_approval';
      title = 'Agent 请求授权';
      final approvalText = nextContent.pendingApprovalText.trim();
      body = approvalText.isNotEmpty ? approvalText : '有待确认的操作，请查看并决定允许或拒绝。';
      showActions = true;
    } else if (nextContent.pendingQuestions.isNotEmpty) {
      kind = 'question';
      title = 'Agent 发起提问';
      final q = nextContent.pendingQuestions.first.question.trim();
      body = q.isNotEmpty ? q : 'Agent 提出了问题等待回复。';
      showActions = false;
    } else if (prevContent?.agentStatus == 'working' &&
        nextContent.agentStatus == 'idle') {
      String preview = '';
      for (int i = nextContent.dialogBlocks.length - 1; i >= 0; i--) {
        final b = nextContent.dialogBlocks[i];
        if ((b.role == 'assistant' || b.role == 'text') &&
            b.text.trim().isNotEmpty) {
          preview = b.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          break;
        }
      }
      if (preview.length > 100) {
        preview = '${preview.substring(0, 100)}…';
      }
      kind = 'done';
      title = 'Agent 已完成回复';
      body = preview.isNotEmpty ? preview : '回复已完成，点击查看详情。';
      showActions = false;
    } else {
      return;
    }

    final key = '$kind|$body';
    if (key == _lastNotifKey) return;
    _lastNotifKey = key;

    unawaited(
      OverlayNotifier.showSystemNotification(
        title: title,
        body: body,
        showActions: showActions,
      ),
    );
  }

  @override
  void dispose() {
    OverlayNotifier.setActionHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    _pauseSendTimer?.cancel();
    _draftSyncDebounce?.cancel();
    _topToastTimer?.cancel();
    _topToastEntry?.remove();
    _topToastEntry = null;
    unawaited(_msgSub?.cancel());
    _inputCtrl.removeListener(_onInputControllerChanged);
    _inputCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onHostMessage(ProtocolMessage msg) {
    if (!mounted || msg is! DraftUpdateMessage) return;
    final composing = _inputCtrl.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return;
    }
    final incomingNorm =
        msg.text.replaceAll('\r\n', '\n').replaceAll('\u00a0', ' ');
    if (incomingNorm.trim().isNotEmpty &&
        incomingNorm.trim() == _lastSentText &&
        DateTime.now().difference(_lastSentAt).inMilliseconds < 6000) {
      return;
    }
    final localNorm =
        _inputCtrl.text.replaceAll('\r\n', '\n').replaceAll('\u00a0', ' ');
    if (incomingNorm == localNorm) {
      _lastSyncedDraft = _inputCtrl.text;
      return;
    }
    final incomingTrimRight =
        incomingNorm.replaceFirst(RegExp(r'[ \t]+$'), '');
    final localTrimRight = localNorm.replaceFirst(RegExp(r'[ \t]+$'), '');
    if (incomingTrimRight == localTrimRight) {
      return;
    }
    final elapsedMs = DateTime.now().difference(_lastLocalEditAt).inMilliseconds;
    if (elapsedMs < 2500) {
      return;
    }
    if (_inputFocus.hasFocus &&
        _inputCtrl.text.isNotEmpty &&
        incomingTrimRight.isNotEmpty &&
        localNorm.startsWith(incomingTrimRight) &&
        elapsedMs < 4500) {
      return;
    }
    _applyingRemoteDraft = true;
    _lastSyncedDraft = msg.text;
    _inputCtrl.value = TextEditingValue(
      text: msg.text,
      selection: TextSelection.collapsed(offset: msg.text.length),
    );
    _applyingRemoteDraft = false;
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Actions: Messaging, Quick Commands, File Upload, Hold/Tap Mic
  // ---------------------------------------------------------------------------

  Future<void> _sendText({
    String? overrideText,
    bool skipLocalQueue = false,
  }) async {
    if (_isSending) return;
    _isSending = true;
    try {
      _pauseSendTimer?.cancel();
      _draftSyncDebounce?.cancel();
      final text = (overrideText ?? _inputCtrl.text).trim();
      if (text.isEmpty) {
        if (overrideText == null && _pendingAttachments.isNotEmpty) {
          final connected =
              ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
          if (!connected) return;
          final winState = ref.read(windowControllerProvider);
          HapticFeedback.mediumImpact();
          ref.read(hostActionProvider).sendControlKey(
                key: 'Enter',
                targetWindowId: winState.selectedWindowId,
              );
          setState(() {
            _showPlusMenu = false;
            _pendingAttachments.clear();
          });
          Future<void>.delayed(const Duration(milliseconds: 1200), () {
            if (!mounted) return;
            unawaited(ref.read(windowContentProvider.notifier).fetchContent());
          });
        }
        return;
      }

      _lastLocalEditAt = DateTime.now();
      _lastSentText = text;
      _lastSentAt = _lastLocalEditAt;
      final winState = ref.read(windowControllerProvider);
      final selected = winState.selectedWindow;
      final previousText = overrideText == null ? _inputCtrl.text : '';
      if (overrideText == null) {
        _lastSyncedDraft = '';
        _applyingRemoteDraft = true;
        _inputCtrl.clear();
        _applyingRemoteDraft = false;
      }
      HapticFeedback.mediumImpact();

      final res = await ref.read(hostActionProvider).injectText(
            text: text,
            targetWindowId: winState.selectedWindowId,
            targetWindowTitle:
                selected != null ? '[${selected.app}] ${selected.title}' : '当前焦点窗口',
            source: overrideText != null ? 'quick_command' : 'stt_final',
            autoEnter: true,
          );

      if (!mounted) return;
      if (res != null && res.ok) {
        final contentBeforeSend = ref.read(windowContentProvider).content;
        final isWorking = contentBeforeSend?.agentStatus == 'working';
        _lastSyncedDraft = res.autoEnterSent ? '' : text;
        if (overrideText == null && !res.autoEnterSent && _inputCtrl.text.isEmpty) {
          _applyingRemoteDraft = true;
          _inputCtrl.value = TextEditingValue(
            text: previousText,
            selection: TextSelection.collapsed(offset: previousText.length),
          );
          _applyingRemoteDraft = false;
        }
        setState(() {
          _showPlusMenu = false;
          if (overrideText == null && res.autoEnterSent) {
            _pendingAttachments.clear();
          }
          if (isWorking &&
              !skipLocalQueue &&
              !_localQueuedMessages.contains(text)) {
            _localQueuedMessages.add(text);
            _localQueueAddedAt[text] = DateTime.now();
          }
        });
        Future<void>.delayed(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          unawaited(ref.read(windowContentProvider.notifier).fetchContent());
        });
      } else {
        if (overrideText == null && _inputCtrl.text.isEmpty && previousText.isNotEmpty) {
          _lastSyncedDraft = previousText;
          _applyingRemoteDraft = true;
          _inputCtrl.value = TextEditingValue(
            text: previousText,
            selection: TextSelection.collapsed(offset: previousText.length),
          );
          _applyingRemoteDraft = false;
          setState(() {});
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('发送失败，请检查被控端连接或目标窗口'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      _isSending = false;
    }
  }

  void _interruptCurrentAgent({bool pullLastPromptForEdit = false}) {
    HapticFeedback.mediumImpact();
    _pauseSendTimer?.cancel();
    ref.read(hostActionProvider).sendControlKey(
          key: 'vh:interrupt',
          targetWindowId: ref.read(windowControllerProvider).selectedWindowId,
        );
    if (pullLastPromptForEdit && _inputCtrl.text.trim().isEmpty) {
      String? lastPrompt;
      final blocks =
          ref.read(windowContentProvider).content?.dialogBlocks ?? const [];
      for (int i = blocks.length - 1; i >= 0; i--) {
        if (blocks[i].role == 'user' && blocks[i].text.trim().isNotEmpty) {
          lastPrompt = blocks[i].text.trim();
          break;
        }
      }
      lastPrompt ??=
          _lastSentText.trim().isNotEmpty ? _lastSentText.trim() : null;
      if (lastPrompt != null) {
        _lastLocalEditAt = DateTime.now();
        _inputCtrl.value = TextEditingValue(
          text: lastPrompt,
          selection: TextSelection.collapsed(offset: lastPrompt.length),
        );
        _inputFocus.requestFocus();
        _scheduleDraftSync(delayMs: 220);
        setState(() => _showPlusMenu = false);
      }
    }
    _showTopNotice(pullLastPromptForEdit ? '已停止，可重新编辑发送' : '已发送停止指令');
    for (final ms in const [500, 1400]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (!mounted) return;
        unawaited(ref.read(windowContentProvider.notifier).fetchContent());
      });
    }
  }

  Future<void> _interruptAndSteer(
    String rawText, {
    bool removeFromLocalQueue = false,
    bool clearComposer = false,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty) return;
    final targetWindowId = ref.read(windowControllerProvider).selectedWindowId;

    if (removeFromLocalQueue) {
      HapticFeedback.mediumImpact();
      setState(() {
        _localQueuedMessages.remove(text);
        _localQueueAddedAt.remove(text);
      });
      ref.read(hostActionProvider).sendControlKey(
            key: 'vh:send_now:$text',
            targetWindowId: targetWindowId,
          );
      for (final ms in const [650, 1500]) {
        Future<void>.delayed(Duration(milliseconds: ms), () {
          if (!mounted) return;
          unawaited(ref.read(windowContentProvider.notifier).fetchContent());
        });
      }
      return;
    }

    _interruptCurrentAgent();
    if (clearComposer) {
      setState(() {
        _applyingRemoteDraft = true;
        _inputCtrl.clear();
        _applyingRemoteDraft = false;
        _lastSyncedDraft = '';
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    await _sendText(overrideText: text, skipLocalQueue: true);
  }

  void _insertDraft(String draft) {
    _inputCtrl.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _inputFocus.requestFocus();
    setState(() => _showPlusMenu = false);
    _onInputChanged(draft);
  }

  void _scheduleDraftSync({int delayMs = 220}) {
    _draftSyncDebounce?.cancel();
    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return;
    _draftSyncDebounce = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      final current = _inputCtrl.text;
      if (current != _lastSyncedDraft) {
        _lastSyncedDraft = current;
        final targetId = ref.read(windowControllerProvider).selectedWindowId;
        ref
            .read(hostActionProvider)
            .syncDraft(text: current, targetWindowId: targetId);
      }
    });
  }

  void _onInputControllerChanged() {
    if (_applyingRemoteDraft || !mounted) return;
    final composing = _inputCtrl.value.composing;
    final isComposing = composing.isValid && !composing.isCollapsed;
    if (!isComposing &&
        _inputCtrl.text != _lastSyncedDraft &&
        (_draftSyncDebounce == null || !_draftSyncDebounce!.isActive)) {
      _scheduleDraftSync(delayMs: 180);
    }
  }

  void _onInputChanged(String val) {
    if (_applyingRemoteDraft) return;
    _lastLocalEditAt = DateTime.now();
    setState(() {});
    _pauseSendTimer?.cancel();

    final composing = _inputCtrl.value.composing;
    final isComposing = composing.isValid && !composing.isCollapsed;
    _scheduleDraftSync(delayMs: isComposing ? 550 : 220);

    if (isComposing) {
      return;
    }

    final settings = ref.read(settingsProvider);
    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    if (!connected || !settings.imeAutoSendOnPause || val.trim().isEmpty) {
      return;
    }
    _pauseSendTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted && _inputCtrl.text.trim().isNotEmpty) {
        unawaited(_sendText());
      }
    });
  }

  void _showTopNotice(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;
    _topToastTimer?.cancel();
    _topToastEntry?.remove();
    _topToastEntry = null;

    final p = VibeTheme.paletteOf(context);
    final topPad = MediaQuery.of(context).padding.top + 56;
    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: topPad,
        left: 16,
        right: 16,
        child: IgnorePointer(
          ignoring: true,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 420),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: p.panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isError
                        ? p.danger.withValues(alpha: 0.45)
                        : p.accent.withValues(alpha: 0.35),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: p.isDark ? 0.35 : 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isError
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 16,
                      color: isError ? p.danger : p.success,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    overlay.insert(entry);
    _topToastEntry = entry;
    _topToastTimer = Timer(duration, () {
      if (_topToastEntry == entry) {
        entry.remove();
        _topToastEntry = null;
      }
    });
  }

  Future<void> _pickAndUploadFile() async {
    if (_uploadingFile) return;
    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return;

    setState(() => _showPlusMenu = false);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final f = picked.files.first;
      final path = f.path;
      if (path == null || path.isEmpty) return;

      setState(() => _uploadingFile = true);
      HapticFeedback.lightImpact();

      final winState = ref.read(windowControllerProvider);
      final targetApp = winState.selectedWindow?.app ?? '目标窗口';
      final res = await ref.read(hostActionProvider).uploadFileToDialog(
            filePath: path,
            filename: f.name,
            targetWindowId: winState.selectedWindowId,
            autoPaste: true,
            autoEnter: false,
          );

      if (!mounted) return;
      if (res.ok) {
        final displayName =
            res.filename.isNotEmpty ? res.filename : f.name;
        final kindLabel = res.kind == 'image' ? '图片' : '文件';
        setState(() {
          _pendingAttachments.add(
            _PendingAttachment(
              localPath: path,
              filename: displayName,
              kind: res.kind,
            ),
          );
        });
        _showTopNotice(
          '已将$kindLabel「$displayName」粘贴到 $targetApp (${res.elapsedMs}ms)',
        );
      } else {
        _showTopNotice(
          res.message ?? '上传粘贴失败',
          isError: true,
          duration: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      if (mounted) {
        _showTopNotice(
          '选择或上传文件失败: $e',
          isError: true,
          duration: const Duration(seconds: 3),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingFile = false);
      }
    }
  }

  void _removePendingAttachment(int index) {
    if (index < 0 || index >= _pendingAttachments.length) return;
    final removed = _pendingAttachments[index];
    HapticFeedback.lightImpact();
    setState(() => _pendingAttachments.removeAt(index));
    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return;
    final winId = ref.read(windowControllerProvider).selectedWindowId;
    ref.read(hostActionProvider).sendControlKey(
          key: 'vh:remove_attachment:$index|${removed.filename}',
          targetWindowId: winId,
        );
  }

  void _onMicHoldStart() {
    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    if (!connected) return;
    HapticFeedback.heavyImpact();
    final streamState = ref.read(remoteStreamProvider);
    final streamCtrl = ref.read(remoteStreamProvider.notifier);
    final startedHere = !streamState.audioBridgeActive;
    setState(() {
      _holdingMic = true;
      _startedMicByHold = startedHere;
    });
    if (startedHere) {
      unawaited(streamCtrl.startAudioBridge());
    }
  }

  void _onMicHoldEnd() {
    if (!_holdingMic) return;
    final shouldStop = _startedMicByHold;
    setState(() {
      _holdingMic = false;
      _startedMicByHold = false;
    });
    if (shouldStop) {
      HapticFeedback.lightImpact();
      unawaited(
        ref.read(remoteStreamProvider.notifier).stopAudioBridge(forceSendStop: true),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Tab Switching & Multi-Host / CDP Probing
  // ---------------------------------------------------------------------------

  void _switchToTab(int nextTab) {
    if (_tabIndex == nextTab) return;
    final prevTab = _tabIndex;
    setState(() {
      _tabIndex = nextTab;
      if (nextTab != 0) _showPlusMenu = false;
    });

    final connected =
        ref.read(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    final streamCtrl = ref.read(remoteStreamProvider.notifier);
    final streamState = ref.read(remoteStreamProvider);
    final contentCtrl = ref.read(windowContentProvider.notifier);

    // Pause video when leaving Screen Control tab (virtual mic remains untouched)
    if (prevTab == 1 &&
        nextTab != 1 &&
        (streamState.isStreaming || streamState.phase == StreamPhase.starting)) {
      unawaited(streamCtrl.stopStream());
    }

    if (nextTab == 0) {
      unawaited(OverlayNotifier.cancelSystemNotification());
      if (connected) {
        unawaited(contentCtrl.fetchContent());
      }
    } else if (nextTab == 1 && connected) {
      if (_screenSubMode == 0) {
        unawaited(contentCtrl.fetchSnapshot());
      } else {
        unawaited(streamCtrl.startStream(overrideMode: 'window'));
      }
    } else if (nextTab == 3) {
      unawaited(_probeAllHosts());
      if (connected) {
        unawaited(_loadHostApps());
        unawaited(ref.read(windowControllerProvider.notifier).refresh());
      }
    }
  }

  Future<void> _probeAllHosts() async {
    if (_probingHosts) return;
    setState(() => _probingHosts = true);
    try {
      final profiles = ref.read(settingsProvider).hostProfiles;
      final actions = ref.read(hostActionProvider);
      final results = await Future.wait(
        profiles.map((p) => actions.probeHostHealth(p)),
      );
      if (!mounted) return;
      setState(() {
        _hostProbes = {for (final r in results) r.profileId: r};
      });
    } finally {
      if (mounted) {
        setState(() => _probingHosts = false);
      }
    }
  }

  Future<void> _loadHostApps() async {
    if (_loadingApps) return;
    setState(() => _loadingApps = true);
    try {
      final apps = await ref.read(hostActionProvider).fetchHostApps();
      if (!mounted) return;
      if (apps != null) {
        setState(() => _ideApps = apps);
      }
    } finally {
      if (mounted) {
        setState(() => _loadingApps = false);
      }
    }
  }

  Future<void> _loadProjects() async {
    if (_loadingProjects) return;
    _loadingProjects = true;
    try {
      final resp = await ref.read(hostActionProvider).fetchProjects();
      if (!mounted) return;
      if (resp != null) {
        setState(() {
          _projects = resp.projects;
          if (resp.defaultRootDir.isNotEmpty) {
            _defaultProjectRoot = resp.defaultRootDir;
          }
        });
      }
    } finally {
      _loadingProjects = false;
    }
  }

  Future<void> _openProjectIde(ProjectItem proj) async {
    HapticFeedback.mediumImpact();
    final (ok, msg) = await ref.read(hostActionProvider).openProjectInIde(
          projectId: proj.id,
          ideId: proj.defaultIde.isNotEmpty ? proj.defaultIde : 'antigravity',
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
    if (ok) {
      unawaited(_loadHostApps());
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) {
          unawaited(ref.read(windowControllerProvider.notifier).refresh());
        }
      });
    }
  }

  Future<void> _confirmDeleteProject(ProjectItem proj) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除项目记录'),
        content: Text(
          '确定从项目列表移除「${proj.name}」吗？\n\n宿主机本地目录（${proj.path}）中的文件不会被删除，仅清除归类记录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await ref.read(hostActionProvider).deleteProject(proj.id);
    if (!mounted) return;
    if (ok) {
      if (_selectedProjectFilterId == proj.id) {
        setState(() => _selectedProjectFilterId = null);
      }
      unawaited(_loadProjects());
      unawaited(ref.read(windowContentProvider.notifier).fetchContent());
    }
  }

  Future<void> _connectHost(HostProfile profile) async {
    HapticFeedback.lightImpact();
    await ref.read(settingsProvider.notifier).selectHostProfile(profile.id);
    await ref.read(hostActionProvider).connectFromSettings();
    if (!mounted) return;
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      await ref.read(windowControllerProvider.notifier).refresh();
      await ref
          .read(windowContentProvider.notifier)
          .fetchContent(resetSession: true);
      unawaited(_loadHostApps());
      unawaited(_loadProjects());
      unawaited(_probeAllHosts());
      unawaited(ref.read(appUpdateProvider.notifier).syncOnConnected());
    });
  }

  Future<void> _launchIde(HostIdeApp app, {required bool restart}) async {
    setState(() => _busyIdeId = app.id);
    HapticFeedback.mediumImpact();
    final (ok, msg) = await ref
        .read(hostActionProvider)
        .launchHostIde(app.id, restart: restart);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
    Future<void>.delayed(const Duration(milliseconds: 1100), () async {
      if (!mounted) return;
      await _loadHostApps();
      await ref.read(windowControllerProvider.notifier).refresh();
      unawaited(_probeAllHosts());
      if (mounted) setState(() => _busyIdeId = null);
    });
    if (!ok && mounted) {
      setState(() => _busyIdeId = null);
    }
  }

  Future<void> _focusIde(HostIdeApp app) async {
    setState(() => _busyIdeId = app.id);
    HapticFeedback.mediumImpact();
    final (ok, winId, msg) =
        await ref.read(hostActionProvider).focusHostIde(app.id);
    if (!mounted) return;
    if (ok) {
      await ref.read(windowControllerProvider.notifier).refresh();
      if (winId != null && winId.isNotEmpty) {
        ref.read(windowControllerProvider.notifier).selectWindow(winId);
      }
      unawaited(ref
          .read(windowContentProvider.notifier)
          .fetchContent(resetSession: true));
      unawaited(ref.read(windowContentProvider.notifier).fetchSnapshot());
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
    setState(() => _busyIdeId = null);
  }

  void _openWindowPickerSheet() {
    final p = VibeTheme.paletteOf(context);
    var sheetOpen = true;
    var probeTriggered = false;
    var appsTriggered = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sheetSetState) {
          if (!probeTriggered) {
            probeTriggered = true;
            unawaited(
              _probeAllHosts().then((_) {
                if (sheetOpen && ctx.mounted) {
                  sheetSetState(() {});
                }
              }),
            );
          }
          if (!appsTriggered) {
            appsTriggered = true;
            if ((ref.read(socketSnapshotProvider).valueOrNull?.isConnected ??
                    false) &&
                _ideApps.isEmpty) {
              unawaited(
                _loadHostApps().then((_) {
                  if (sheetOpen && ctx.mounted) {
                    sheetSetState(() {});
                  }
                }),
              );
            }
          }
          return Consumer(
            builder: (ctx, sheetRef, _) {
              final sheetSettings = sheetRef.watch(settingsProvider);
              final sheetConnSnap =
                  sheetRef.watch(socketSnapshotProvider).valueOrNull ??
                      const SocketSnapshot();
              final profiles = sheetSettings.hostProfiles;
              final activeHostId = sheetSettings.activeHost.id;

              return SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.78,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                  child: Column(
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: p.border,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: p.panel,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: p.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.dns_rounded,
                                    size: 16, color: p.accent),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '切换主机 (${profiles.length})',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      color: p.text,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () {
                                    Navigator.of(ctx).pop();
                                    unawaited(_showEditHostDialog());
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 3),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.add_rounded,
                                            size: 14, color: p.accent),
                                        const SizedBox(width: 2),
                                        Text(
                                          '添加',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: p.accent,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () {
                                    Navigator.of(ctx).pop();
                                    _switchToTab(3);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 3),
                                    child: Text(
                                      '管理',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: p.muted,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 54,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: profiles.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (_, i) {
                                  final profile = profiles[i];
                                  final isActive = profile.id == activeHostId;
                                  final probe = _hostProbes[profile.id];
                                  final isConnecting = isActive &&
                                      (sheetConnSnap.phase ==
                                              ConnectionPhase.connecting ||
                                          sheetConnSnap.phase ==
                                              ConnectionPhase.authenticating ||
                                          sheetConnSnap.phase ==
                                              ConnectionPhase.reconnecting);
                                  final isConnectedThis =
                                      isActive && sheetConnSnap.isConnected;
                                  final isOnline =
                                      isConnectedThis || (probe?.online ?? false);
                                  final hostDotColor = isConnecting
                                      ? p.warning
                                      : (isOnline
                                          ? p.success
                                          : (probe == null
                                              ? p.muted
                                              : p.danger));
                                  final hostLabel =
                                      inferHostLabel(profile.wsUrl);
                                  final subtitle = isConnectedThis
                                      ? '已连接'
                                      : (isConnecting
                                          ? '连接中...'
                                          : (probe == null
                                              ? hostLabel
                                              : (probe.online
                                                  ? '在线 · $hostLabel'
                                                  : '离线 · $hostLabel')));

                                  return InkWell(
                                    borderRadius: BorderRadius.circular(11),
                                    onTap: () {
                                      if (isConnectedThis) {
                                        HapticFeedback.selectionClick();
                                        unawaited(sheetRef
                                            .read(windowControllerProvider
                                                .notifier)
                                            .refresh());
                                      } else {
                                        unawaited(_connectHost(profile));
                                      }
                                    },
                                    child: Container(
                                      constraints: const BoxConstraints(
                                        minWidth: 128,
                                        maxWidth: 200,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 7),
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? p.accent.withValues(alpha: 0.13)
                                            : p.panelAlt,
                                        borderRadius: BorderRadius.circular(11),
                                        border: Border.all(
                                          color: isActive ? p.accent : p.border,
                                          width: isActive ? 1.4 : 1.0,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isConnecting)
                                            SizedBox(
                                              width: 10,
                                              height: 10,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.6,
                                                color: p.warning,
                                              ),
                                            )
                                          else
                                            Container(
                                              width: 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                color: hostDotColor,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          const SizedBox(width: 7),
                                          Flexible(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  profile.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: isActive
                                                        ? FontWeight.w700
                                                        : FontWeight.w600,
                                                    color: p.text,
                                                  ),
                                                ),
                                                const SizedBox(height: 1),
                                                Text(
                                                  subtitle,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    color: p.muted,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (isConnectedThis) ...[
                                            const SizedBox(width: 6),
                                            Icon(Icons.check_circle_rounded,
                                                size: 15, color: p.accent),
                                          ],
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (sheetConnSnap.isConnected &&
                          _sortedIdeApps().any((a) => a.installed)) ...[
                        _buildQuickAppStrip(
                          p,
                          sheetSetState: sheetSetState,
                          onDone: () {
                            if (ctx.mounted) Navigator.of(ctx).pop();
                          },
                        ),
                        const SizedBox(height: 10),
                      ],
                      Expanded(
                        child: WindowSelectorPanel(
                          onWindowPicked: () {
                            Navigator.of(ctx).pop();
                            final contentCtrl =
                                ref.read(windowContentProvider.notifier);
                            unawaited(
                                contentCtrl.fetchContent(resetSession: true));
                            unawaited(contentCtrl.fetchSnapshot());
                            if (_tabIndex == 1 && _screenSubMode == 1) {
                              unawaited(ref
                                  .read(remoteStreamProvider.notifier)
                                  .startStream(overrideMode: 'window'));
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    ).whenComplete(() => sheetOpen = false);
  }

  Future<void> _showEditHostDialog({HostProfile? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl =
        TextEditingController(text: existing?.wsUrl ?? '192.168.1.');
    final tokenCtrl = TextEditingController(text: existing?.token ?? '');

    final saved = await showDialog<HostProfile>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '新增被控端 (Host)' : '编辑被控端'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '主机名称',
                  hintText: '例如：办公室 Win11 / Ubuntu 服务器',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: '地址 (支持 IP / IP:端口 / ws://...)',
                  hintText: '192.168.110.125:8765',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tokenCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '鉴权 Token (可选)',
                  hintText: '未开启鉴权可留空',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final url = normalizeWsUrl(urlCtrl.text);
              if (url.isEmpty) return;
              Navigator.of(ctx).pop(
                HostProfile(
                  id: existing?.id ??
                      'host-${DateTime.now().millisecondsSinceEpoch}',
                  name: nameCtrl.text.trim().isEmpty
                      ? inferHostLabel(url)
                      : nameCtrl.text.trim(),
                  wsUrl: url,
                  token: tokenCtrl.text.trim(),
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    urlCtrl.dispose();
    tokenCtrl.dispose();

    if (saved != null) {
      await ref
          .read(settingsProvider.notifier)
          .upsertHostProfile(saved, select: existing == null);
      unawaited(_probeAllHosts());
    }
  }

  Future<void> _showEditClientNameDialog() async {
    final settings = ref.read(settingsProvider);
    final ctrl = TextEditingController(text: settings.clientName);
    final nextName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改本机显示名称'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: '设备名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (nextName != null && nextName.isNotEmpty) {
      await ref
          .read(settingsProvider.notifier)
          .update(settings.copyWith(clientName: nextName));
    }
  }

  // ---------------------------------------------------------------------------
  // Build Root Scaffold (Pastel Gradient / Dark Geek + Drawer + Floating Top)
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      windowContentProvider.select((s) => s.content?.agentStatus),
      (_, next) {
        if (next != 'working' &&
            (_localQueuedMessages.isNotEmpty || _localQueueAddedAt.isNotEmpty) &&
            mounted) {
          setState(() {
            _localQueuedMessages.clear();
            _localQueueAddedAt.clear();
          });
        }
      },
    );
    ref.listen<WindowContentState>(
      windowContentProvider,
      (prev, next) {
        _onWindowContentUpdated(prev?.content, next.content);
      },
    );
    ref.listen<String>(
      settingsProvider.select((s) => s.overlayMode),
      (prev, next) {
        if ((!OverlayNotifier.isIslandSupported &&
                !OverlayNotifier.isOverlaySupported) ||
            prev == next) {
          return;
        }
        unawaited(_syncActiveOverlay(forceShow: next != 'off'));
      },
    );
    ref.listen<bool>(
      settingsProvider.select((s) => s.backgroundKeepAlive),
      (prev, next) {
        if (!OverlayNotifier.isOverlaySupported || prev == next) return;
        _syncKeepAlive();
      },
    );
    ref.listen<bool?>(
      socketSnapshotProvider.select((s) => s.valueOrNull?.isConnected),
      (prev, next) {
        if (prev == next) return;
        if (next == true) {
          final connectedAt = DateTime.now();
          unawaited(_loadHostApps());
          unawaited(_loadProjects());
          Future<void>.delayed(const Duration(milliseconds: 450), () {
            if (!mounted) return;
            final cs = ref.read(windowContentProvider);
            final contentCtrl = ref.read(windowContentProvider.notifier);
            if (!cs.isLoadingContent &&
                !contentCtrl.hasLiveSyncSince(connectedAt)) {
              unawaited(contentCtrl.fetchContent(resetSession: true));
            }
          });
        }
        if (OverlayNotifier.isOverlaySupported) {
          _syncKeepAlive();
        }
        if ((OverlayNotifier.isOverlaySupported || OverlayNotifier.isIOS) &&
            ref.read(settingsProvider).overlayMode != 'off') {
          unawaited(_syncActiveOverlay());
        }
      },
    );

    final p = VibeTheme.paletteOf(context);
    final connSnap =
        ref.watch(socketSnapshotProvider).valueOrNull ?? const SocketSnapshot();
    final connected = connSnap.isConnected;
    final winState = ref.watch(windowControllerProvider);
    final contentState = ref.watch(windowContentProvider);
    final streamState = ref.watch(remoteStreamProvider);
    final updateState = ref.watch(appUpdateProvider);
    final settings = ref.watch(settingsProvider);

    final selectedWin = winState.selectedWindow;
    final isConnectingPhase = connSnap.phase == ConnectionPhase.connecting ||
        connSnap.phase == ConnectionPhase.authenticating ||
        connSnap.phase == ConnectionPhase.reconnecting;
    final dotColor = switch (connSnap.phase) {
      ConnectionPhase.connected => p.success,
      ConnectionPhase.connecting ||
      ConnectionPhase.authenticating ||
      ConnectionPhase.reconnecting =>
        p.warning,
      ConnectionPhase.error => p.danger,
      ConnectionPhase.disconnected => p.muted,
    };

    final capsuleLabel = switch (connSnap.phase) {
      ConnectionPhase.connected => selectedWin != null
          ? '${settings.activeHost.name} · ${selectedWin.app}'
          : '${settings.activeHost.name} · 焦点窗口',
      ConnectionPhase.connecting ||
      ConnectionPhase.authenticating =>
        '连接 ${settings.activeHost.name}...',
      ConnectionPhase.reconnecting => '重连 ${settings.activeHost.name}...',
      ConnectionPhase.error || ConnectionPhase.disconnected => '连接服务',
    };

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: p.bg,
      drawer: _buildSessionDrawer(p, contentState, connected, winState),
      body: Container(
        decoration: p.isDark
            ? BoxDecoration(color: p.bg)
            : const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFF3F6FC),
                    Color(0xFFEEF1FF),
                    Color(0xFFF7F0FA),
                    Color(0xFFF4F6FB),
                  ],
                  stops: [0.0, 0.35, 0.72, 1.0],
                ),
              ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 1. LingGuang-style floating minimalist top header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: [
                    // Circular `=` drawer toggle
                    Material(
                      color: p.panel.withValues(alpha: p.isDark ? 1.0 : 0.92),
                      shape: const CircleBorder(),
                      elevation: p.isDark ? 0 : 2,
                      shadowColor: Colors.black.withValues(alpha: 0.08),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _scaffoldKey.currentState?.openDrawer();
                          if (connected) {
                            unawaited(_loadProjects());
                          }
                        },
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.8),
                            ),
                          ),
                          child: Icon(
                            Icons.drag_handle_rounded,
                            size: 22,
                            color: p.text,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Top-right `连接服务 / 主机 · 应用` capsule
                    Material(
                      color: p.panel.withValues(alpha: p.isDark ? 1.0 : 0.92),
                      borderRadius: BorderRadius.circular(999),
                      elevation: p.isDark ? 0 : 2,
                      shadowColor: Colors.black.withValues(alpha: 0.08),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _openWindowPickerSheet();
                        },
                        onLongPress: () => _switchToTab(3),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 13, vertical: 9),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.85),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isConnectingPhase)
                                SizedBox(
                                  width: 9,
                                  height: 9,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.6,
                                    color: p.warning,
                                  ),
                                )
                              else
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: dotColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              const SizedBox(width: 7),
                              Icon(Icons.grid_view_rounded,
                                  size: 15, color: p.text),
                              const SizedBox(width: 5),
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 165),
                                child: Text(
                                  capsuleLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: p.text,
                                  ),
                                ),
                              ),
                              if (connected && connSnap.rttMs != null) ...[
                                const SizedBox(width: 5),
                                Text(
                                  '${connSnap.rttMs}ms',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: p.muted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Virtual mic active pulse bar or connection/stream error bar
              if (streamState.audioBridgeActive)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: p.danger.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.danger.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.graphic_eq_rounded, size: 15, color: p.danger),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          streamState.audioVoiceActive
                              ? '虚拟麦 · 说话中 (${streamState.audioChunksSent} 包)'
                              : (streamState.audioSkippedSilenceChunks > 0
                                  ? '虚拟麦 · 静音省流中 (已跳过 ${streamState.audioSkippedSilenceChunks} 包)'
                                  : '虚拟麦直传中 → ${streamState.audioBridgeDevice ?? '虚拟声卡'}'),
                          style: TextStyle(
                              fontSize: 11.5,
                              color: p.danger,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => unawaited(ref
                            .read(remoteStreamProvider.notifier)
                            .stopAudioBridge(forceSendStop: true)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: p.danger.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '停止',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: p.danger,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (streamState.error != null || contentState.error != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: p.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    streamState.error ?? contentState.error ?? '',
                    style: TextStyle(fontSize: 11.5, color: p.warning),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else if (!connected &&
                  connSnap.lastError != null &&
                  connSnap.lastError!.isNotEmpty)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: p.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          connSnap.lastError!,
                          style: TextStyle(fontSize: 11.5, color: p.danger),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => unawaited(
                          ref.read(hostActionProvider).connectFromSettings(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Text(
                            '重试',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: p.accent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              if (updateState.decision != null &&
                  updateState.decision!.isReinstall &&
                  !updateState.bannerDismissed)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.accent.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.system_update_rounded, size: 15, color: p.accent),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '发现新版 v${updateState.decision!.latestVersion}+${updateState.decision!.latestBuild}（需要重新安装）',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => _openUpdateSheet(p),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: const Text('更新', style: TextStyle(fontSize: 11.5)),
                      ),
                      InkWell(
                        onTap: () =>
                            ref.read(appUpdateProvider.notifier).dismissBanner(),
                        child: Icon(Icons.close_rounded, size: 15, color: p.muted),
                      ),
                    ],
                  ),
                ),

              // 2. Active Tab Body
              Expanded(
                child: IndexedStack(
                  index: _tabIndex,
                  children: [
                    _buildChatTab(
                      p: p,
                      contentState: contentState,
                      connected: connected,
                      connPhase: connSnap.phase,
                      activeHostName: settings.activeHost.name,
                      winState: winState,
                      streamState: streamState,
                    ),
                    _buildScreenTab(
                      p: p,
                      connected: connected,
                      contentState: contentState,
                      streamState: streamState,
                    ),
                    RemoteTerminalView(
                      wsUrl: settings.wsUrl,
                      token: settings.token,
                      hostConnected: connected,
                      isActiveTab: _tabIndex == 2,
                      hostOs: connSnap.hostInfo?.os ?? '',
                      palette: p,
                    ),
                    _buildHostTab(
                      p: p,
                      connected: connected,
                      settings: settings,
                      winState: winState,
                      liveHostInfo: connSnap.hostInfo,
                    ),
                    _buildMineTab(
                      p: p,
                      connected: connected,
                      settings: settings,
                      connSnap: connSnap,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNavBar(p),
    );
  }

  // ---------------------------------------------------------------------------
  // Left Drawer: Projects, Grouped Agent Sessions & Model Switcher
  // ---------------------------------------------------------------------------

  Widget _buildDrawerFilterChip(
    VibePalette p, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
    Color? iconColor,
    int? count,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? p.accent.withValues(alpha: 0.16) : p.panel,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? p.accent : p.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 13,
                  color: selected ? p.accent : (iconColor ?? p.muted),
                ),
                const SizedBox(width: 4),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? p.accent : p.text,
                  ),
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 4),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: selected ? p.accent : p.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDrawerProjectHeader(
    VibePalette p, {
    required ProjectItem? project,
    required String title,
    required int count,
    required bool connected,
  }) {
    final canOpenIde = connected && project != null && project.path.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
      child: Row(
        children: [
          Icon(
            project != null
                ? Icons.folder_rounded
                : Icons.folder_off_outlined,
            size: 14,
            color: project != null ? const Color(0xFFF59E0B) : p.muted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$title ($count)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: p.muted,
              ),
            ),
          ),
          if (canOpenIde)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => unawaited(_openProjectIde(project)),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new_rounded, size: 12, color: p.accent),
                    const SizedBox(width: 3),
                    Text(
                      'IDE',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDrawerSessionTile(
    VibePalette p,
    AgentSessionItem s,
    bool selected,
    List<ProjectItem> mergedProjects,
    bool connected,
  ) {
    Future<void> openAssign() async {
      await showAssignProjectSheet(
        context,
        ref,
        session: s,
        projects: mergedProjects,
        defaultRootDir: _defaultProjectRoot,
        onAssigned: () => unawaited(_loadProjects()),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).pop();
          ref
              .read(windowContentProvider.notifier)
              .selectSession(s.id, title: s.title);
        },
        onLongPress: connected ? () => unawaited(openAssign()) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? p.accent.withValues(alpha: 0.13) : p.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? p.accent : p.border),
          ),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  s.agent.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: p.accent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${s.turnCount} 条消息${s.updatedAt.isNotEmpty ? ' · ${s.updatedAt}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: p.muted),
                    ),
                  ],
                ),
              ),
              if (connected)
                IconButton(
                  tooltip: '归类到项目',
                  onPressed: () => unawaited(openAssign()),
                  icon: Icon(
                    Icons.drive_file_move_outlined,
                    size: 16,
                    color: p.muted,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              if (selected)
                Icon(Icons.check_circle_rounded, size: 16, color: p.accent),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGroupedDrawerItems(
    VibePalette p, {
    required List<AgentSessionItem> sessions,
    required List<ProjectItem> mergedProjects,
    required String? activeId,
    required bool connected,
    required String? effectiveFilterId,
  }) {
    final projectById = {for (final proj in mergedProjects) proj.id: proj};
    if (effectiveFilterId == null) {
      final grouped = <String, List<AgentSessionItem>>{};
      final groupOrder = <String>[];
      for (final s in sessions) {
        final key = s.projectId.isNotEmpty ? s.projectId : '__unassigned__';
        if (!grouped.containsKey(key)) {
          grouped[key] = <AgentSessionItem>[];
          if (key != '__unassigned__') {
            groupOrder.add(key);
          }
        }
        grouped[key]!.add(s);
      }
      if (grouped.containsKey('__unassigned__')) {
        groupOrder.add('__unassigned__');
      }

      final widgets = <Widget>[];
      for (final gid in groupOrder) {
        final items = grouped[gid]!;
        final proj = gid == '__unassigned__' ? null : projectById[gid];
        final title = gid == '__unassigned__'
            ? '未归类对话'
            : (proj?.name ??
                (items.first.projectName.isNotEmpty
                    ? items.first.projectName
                    : gid));
        widgets.add(
          _buildDrawerProjectHeader(
            p,
            project: proj,
            title: title,
            count: items.length,
            connected: connected,
          ),
        );
        for (final s in items) {
          widgets.add(
            _buildDrawerSessionTile(
              p,
              s,
              s.id == activeId,
              mergedProjects,
              connected,
            ),
          );
        }
      }

      final emptyProjects = mergedProjects
          .where((proj) => !grouped.containsKey(proj.id))
          .toList();
      if (emptyProjects.isNotEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
            child: Text(
              '其他项目 (${emptyProjects.length})',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: p.muted,
              ),
            ),
          ),
        );
        for (final proj in emptyProjects) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _selectedProjectFilterId = proj.id);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: p.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_rounded,
                          size: 17, color: Color(0xFFF59E0B)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              proj.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: p.text,
                              ),
                            ),
                            Text(
                              '暂无关联对话 · 点击查看或右上打开 IDE',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10.5, color: p.muted),
                            ),
                          ],
                        ),
                      ),
                      if (connected && proj.path.isNotEmpty)
                        IconButton(
                          tooltip: '在 IDE 打开',
                          onPressed: () => unawaited(_openProjectIde(proj)),
                          icon: Icon(Icons.open_in_new_rounded,
                              size: 15, color: p.accent),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                        ),
                      if (proj.isCustom && connected)
                        IconButton(
                          tooltip: '移除项目记录',
                          onPressed: () =>
                              unawaited(_confirmDeleteProject(proj)),
                          icon: Icon(Icons.delete_outline_rounded,
                              size: 15, color: p.muted),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
      }
      return widgets;
    }

    final filtered = sessions.where((s) {
      if (effectiveFilterId == '__unassigned__') return s.projectId.isEmpty;
      return s.projectId == effectiveFilterId;
    }).toList();

    if (filtered.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
          child: Text(
            connected
                ? '当前项目暂无历史对话\n可在上方「新建会话」或「IDE 打开」开始工作'
                : '暂无匹配的历史对话',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: p.muted, height: 1.6),
          ),
        ),
      ];
    }

    return [
      for (final s in filtered)
        _buildDrawerSessionTile(
          p,
          s,
          s.id == activeId,
          mergedProjects,
          connected,
        ),
    ];
  }

  Widget _buildSessionDrawer(
    VibePalette p,
    WindowContentState contentState,
    bool connected,
    WindowListState winState,
  ) {
    final content = contentState.content;
    final sessions = content?.sessions ?? const <AgentSessionItem>[];
    final activeId = content?.activeSessionId;
    final blocks = content?.dialogBlocks ?? const <DialogBlockItem>[];

    final mergedProjects = mergeProjectsWithSessions(_projects, sessions);
    final sessionCounts = <String, int>{};
    int unassignedCount = 0;
    for (final s in sessions) {
      if (s.projectId.isNotEmpty) {
        sessionCounts[s.projectId] = (sessionCounts[s.projectId] ?? 0) + 1;
      } else {
        unassignedCount++;
      }
    }
    String? effectiveFilterId = _selectedProjectFilterId;
    if (effectiveFilterId != null &&
        effectiveFilterId != '__unassigned__' &&
        !mergedProjects.any((proj) => proj.id == effectiveFilterId)) {
      effectiveFilterId = null;
    }
    if (effectiveFilterId == '__unassigned__' && unassignedCount == 0) {
      effectiveFilterId = null;
    }
    final activeProjFilter = effectiveFilterId != null &&
            effectiveFilterId != '__unassigned__'
        ? mergedProjects.where((proj) => proj.id == effectiveFilterId).firstOrNull
        : null;

    String activeModel = content?.activeModel ?? '';
    if (activeModel.isEmpty) {
      for (final b in blocks.reversed) {
        if (b.model.isNotEmpty) {
          activeModel = b.model;
          break;
        }
      }
    }

    return Drawer(
      backgroundColor: p.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [p.accent, const Color(0xFF06B6D4)],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.forum_rounded,
                        size: 18, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '项目与对话历史',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                          ),
                        ),
                        Text(
                          '按项目归类 · 点击同步宿主机窗口',
                          style: TextStyle(fontSize: 11, color: p.muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新项目与会话',
                    onPressed: connected
                        ? () {
                            unawaited(ref
                                .read(windowContentProvider.notifier)
                                .fetchContent());
                            unawaited(_loadProjects());
                          }
                        : null,
                    icon: Icon(Icons.refresh_rounded, size: 19, color: p.muted),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: connected
                          ? () {
                              Navigator.of(context).pop();
                              HapticFeedback.lightImpact();
                              setState(() => _localQueuedMessages.clear());
                              ref
                                  .read(windowContentProvider.notifier)
                                  .startNewSession();
                            }
                          : null,
                      icon: const Icon(Icons.add_comment_outlined, size: 15),
                      label: const Text(
                        '新建会话',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: p.accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: connected
                          ? () => unawaited(
                                showCreateProjectSheet(
                                  context,
                                  ref,
                                  defaultRootDir: _defaultProjectRoot,
                                  onCreated: () => unawaited(_loadProjects()),
                                ),
                              )
                          : null,
                      icon: const Icon(Icons.create_new_folder_outlined,
                          size: 15),
                      label: const Text(
                        '新建项目',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: connected
                    ? () {
                        Navigator.of(context).pop();
                        openModelPickerSheet(
                          context,
                          ref,
                          activeModel,
                          content?.availableModels ?? const <String>[],
                          winState.selectedWindowId,
                        );
                      }
                    : null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  side: BorderSide(color: p.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded,
                        size: 15, color: p.accent),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        activeModel.isNotEmpty
                            ? '当前模型：$activeModel'
                            : '选择模型',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: p.text),
                      ),
                    ),
                    Icon(Icons.expand_more_rounded, size: 16, color: p.muted),
                  ],
                ),
              ),
              if (mergedProjects.isNotEmpty || unassignedCount > 0) ...[
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildDrawerFilterChip(
                        p,
                        label: '全部',
                        count: sessions.length,
                        selected: effectiveFilterId == null,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _selectedProjectFilterId = null);
                        },
                      ),
                      for (final proj in mergedProjects)
                        _buildDrawerFilterChip(
                          p,
                          label: proj.name,
                          icon: Icons.folder_rounded,
                          iconColor: const Color(0xFFF59E0B),
                          count: sessionCounts[proj.id] ?? proj.sessionCount,
                          selected: effectiveFilterId == proj.id,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(
                                () => _selectedProjectFilterId = proj.id);
                          },
                        ),
                      if (unassignedCount > 0)
                        _buildDrawerFilterChip(
                          p,
                          label: '未归类',
                          icon: Icons.folder_off_outlined,
                          count: unassignedCount,
                          selected: effectiveFilterId == '__unassigned__',
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() =>
                                _selectedProjectFilterId = '__unassigned__');
                          },
                        ),
                    ],
                  ),
                ),
              ],
              if (activeProjFilter != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: p.panelAlt,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    activeProjFilter.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: p.text,
                                    ),
                                  ),
                                ),
                                if (activeProjFilter.isGit) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color:
                                          p.success.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Git',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: p.success,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (activeProjFilter.path.isNotEmpty)
                              Text(
                                activeProjFilter.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: p.muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (connected && activeProjFilter.path.isNotEmpty)
                        TextButton.icon(
                          onPressed: () =>
                              unawaited(_openProjectIde(activeProjFilter)),
                          icon: const Icon(Icons.open_in_new_rounded, size: 13),
                          label: const Text('IDE 打开',
                              style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      if (activeProjFilter.isCustom && connected)
                        IconButton(
                          tooltip: '移除项目记录',
                          onPressed: () => unawaited(
                              _confirmDeleteProject(activeProjFilter)),
                          icon: Icon(Icons.delete_outline_rounded,
                              size: 16, color: p.muted),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 26, minHeight: 26),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Divider(height: 1, color: p.border),
              const SizedBox(height: 8),
              Expanded(
                child: (sessions.isEmpty && mergedProjects.isEmpty)
                    ? Center(
                        child: Text(
                          connected
                              ? '未读取到历史会话\n点击右上角切换目标 AI IDE 窗口后刷新'
                              : '请先在「主机」页连接 PC / 服务器',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5, color: p.muted, height: 1.6),
                        ),
                      )
                    : ListView(
                        children: _buildGroupedDrawerItems(
                          p,
                          sessions: sessions,
                          mergedProjects: mergedProjects,
                          activeId: activeId,
                          connected: connected,
                          effectiveFilterId: effectiveFilterId,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 0: 对话 (LingGuang Home + NativeChatView + Floating Pill Composer)
  // ---------------------------------------------------------------------------

  Widget _buildChatTab({
    required VibePalette p,
    required WindowContentState contentState,
    required bool connected,
    required ConnectionPhase connPhase,
    required String activeHostName,
    required WindowListState winState,
    required RemoteStreamState streamState,
  }) {
    final content = contentState.content;
    final blocks = content?.dialogBlocks ?? const <DialogBlockItem>[];
    final sessions = content?.sessions ?? const <AgentSessionItem>[];
    final activeId = content?.activeSessionId;
    final activeSession =
        sessions.where((s) => s.id == activeId).firstOrNull ??
            (sessions.isNotEmpty ? sessions.first : null);
    final contentCtrl = ref.read(windowContentProvider.notifier);

    String activeModel = cleanModelDisplay(content?.activeModel ?? '');
    if (activeModel.isEmpty) {
      for (final b in blocks.reversed) {
        if (b.model.isNotEmpty) {
          activeModel = cleanModelDisplay(b.model);
          break;
        }
      }
    }

    final now = DateTime.now();
    final serverQueue = content?.queuedMessages ?? const <String>[];
    final effectiveQueue = <String>[
      ...serverQueue,
      for (final m in _localQueuedMessages)
        if (!serverQueue.contains(m) &&
            now.difference(_localQueueAddedAt[m] ?? now).inMilliseconds <=
                3500)
          m,
    ];

    return Column(
      children: [
        if (contentState.awaitingNewSession)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.accent.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.add_comment_rounded, size: 15, color: p.accent),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '新会话已就绪 · 发送第一条消息即可创建',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => contentCtrl.cancelAwaitingNewSession(),
                    child: Text(
                      '返回原会话',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: p.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Subtle session / model status pill strip when active messages exist
        if (blocks.isNotEmpty || connected)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                if (activeSession != null)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => openSessionPickerSheet(
                          context, ref, sessions, activeId),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color:
                              p.panel.withValues(alpha: p.isDark ? 0.9 : 0.78),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: p.border.withValues(alpha: 0.75)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (activeSession.projectName.isNotEmpty) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: p.accent.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.folder_rounded,
                                        size: 11, color: p.accent),
                                    const SizedBox(width: 3),
                                    ConstrainedBox(
                                      constraints:
                                          const BoxConstraints(maxWidth: 74),
                                      child: Text(
                                        activeSession.projectName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: p.accent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 5),
                            ] else ...[
                              Icon(Icons.chat_bubble_outline_rounded,
                                  size: 13, color: p.accent),
                              const SizedBox(width: 5),
                            ],
                            Expanded(
                              child: Text(
                                activeSession.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: p.text,
                                ),
                              ),
                            ),
                            Icon(Icons.expand_more_rounded,
                                size: 15, color: p.muted),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: connected
                      ? () => openModelPickerSheet(
                            context,
                            ref,
                            activeModel,
                            content?.availableModels ?? const <String>[],
                            winState.selectedWindowId,
                          )
                      : null,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: p.panel.withValues(alpha: p.isDark ? 0.9 : 0.78),
                      borderRadius: BorderRadius.circular(999),
                      border:
                          Border.all(color: p.accent.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.tune_rounded,
                            size: 12, color: p.accent),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 90),
                          child: Text(
                            activeModel.isNotEmpty ? activeModel : '模型',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: p.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: connected
                      ? () =>
                          contentCtrl.setAutoRefresh(!contentState.autoRefresh)
                      : null,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: contentState.autoRefresh
                          ? p.success.withValues(alpha: 0.14)
                          : p.panel.withValues(alpha: p.isDark ? 0.9 : 0.78),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: contentState.autoRefresh
                            ? p.success.withValues(alpha: 0.5)
                            : p.border.withValues(alpha: 0.75),
                      ),
                    ),
                    child: Text(
                      contentState.autoRefresh ? '同步:开' : '同步',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: contentState.autoRefresh ? p.success : p.muted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: connected
                      ? () => unawaited(contentCtrl.fetchContent())
                      : null,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: p.panel.withValues(alpha: p.isDark ? 0.9 : 0.78),
                      shape: BoxShape.circle,
                      border: Border.all(color: p.border.withValues(alpha: 0.75)),
                    ),
                    child: contentState.isLoadingContent
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.refresh_rounded,
                            size: 15, color: p.muted),
                  ),
                ),
              ],
            ),
          ),

        // Main content: LingGuang Greeting Home (when empty) OR Native Chat
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (_inputFocus.hasFocus) {
                _inputFocus.unfocus();
                setState(() {});
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: blocks.isEmpty
                  ? _buildGreetingHome(
                      p,
                      connected,
                      connPhase,
                      activeHostName,
                      sessions,
                      contentCtrl,
                    )
                  : NativeChatView(
                      contentState: contentState,
                      connected: connected,
                      compactHeader: true,
                      onPullDraftToInput: _insertDraft,
                    ),
            ),
          ),
        ),

        // Expandable `+` Action Drawer
        if (_showPlusMenu)
          KeyedSubtree(
            key: const ValueKey('vh_plus_drawer'),
            child: _buildPlusToolsDrawer(
                p, connected, winState, content, activeModel),
          ),

        // Fixed Collapsible Queued Messages Bar (above bottom composer)
        if (effectiveQueue.isNotEmpty) _buildQueuePanel(p, effectiveQueue),

        // Live Agent status strip when working (sole Stop button lives in composer)
        if (connected && content != null && content.agentStatus == 'working')
          Container(
            key: const ValueKey('vh_interrupt_bar'),
            margin: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.accent.withValues(alpha: 0.30)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: p.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    content.pendingApprovalText.isNotEmpty
                        ? content.pendingApprovalText
                        : (_inputCtrl.text.trim().isNotEmpty
                            ? 'Agent 运行中，可点击右侧打断并发送'
                            : 'Agent 正在思考与执行…'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: p.accent),
                  ),
                ),
                if (_inputCtrl.text.trim().isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => unawaited(
                      _interruptAndSteer(_inputCtrl.text, clearComposer: true),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: p.warning.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: p.warning.withValues(alpha: 0.55)),
                      ),
                      child: Text(
                        '打断并发送',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: p.warning,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

        // Pasted pending images / files awaiting Send
        if (_pendingAttachments.isNotEmpty)
          KeyedSubtree(
            key: const ValueKey('vh_pending_attachments'),
            child: _buildPendingAttachmentsBar(p),
          ),

        // LingGuang Floating Pill Composer
        _buildFloatingPillComposer(
          p,
          connected,
          streamState,
          isWorking: content?.agentStatus == 'working',
        ),
      ],
    );
  }

  Widget _buildGreetingHome(
    VibePalette p,
    bool connected,
    ConnectionPhase connPhase,
    String activeHostName,
    List<AgentSessionItem> sessions,
    WindowContentController contentCtrl,
  ) {
    final now = DateTime.now();
    final monthStr = '${now.month}';
    final dayStr = '/${now.day.toString().padLeft(2, '0')}';
    final isConnecting = connPhase == ConnectionPhase.connecting ||
        connPhase == ConnectionPhase.authenticating ||
        connPhase == ConnectionPhase.reconnecting;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: monthStr,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                    letterSpacing: -0.5,
                  ),
                ),
                TextSpan(
                  text: dayStr,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w400,
                    color: p.text.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '平凡开发里的大小事\n交给 VibeHelper 就好',
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w600,
              height: 1.38,
              color: p.text,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 24),
          if (connected && sessions.isNotEmpty) ...[
            for (int i = 0; i < math.min(3, sessions.length); i++) ...[
              _buildGreetingCard(
                p: p,
                icon: i == 0
                    ? Icons.auto_awesome_rounded
                    : (i == 1
                        ? Icons.code_rounded
                        : Icons.chat_bubble_outline_rounded),
                iconColor: i == 0 ? p.accent : const Color(0xFF0EA5E9),
                title: sessions[i].title,
                subtitle:
                    '${sessions[i].projectName.isNotEmpty ? '[${sessions[i].projectName}] · ' : ''}${sessions[i].agent.toUpperCase()} · ${sessions[i].turnCount} 条对话 · 点击恢复上下文',
                highlight: i == 0,
                onTap: () => contentCtrl.selectSession(
                  sessions[i].id,
                  title: sessions[i].title,
                ),
              ),
              const SizedBox(height: 12),
            ],
          ] else ...[
            _buildGreetingCard(
              p: p,
              icon: Icons.dns_rounded,
              iconColor: p.accent,
              title: connected
                  ? '已连接宿主机 · 拉取 IDE 对话'
                  : (isConnecting
                      ? '正在自动连接 $activeHostName...'
                      : '连接电脑或 Linux 宿主机'),
              subtitle: connected
                  ? '直接读取 Antigravity / ChatGPT / Claude / VS Code / Cursor 实时会话'
                  : (isConnecting
                      ? '正在探测可用宿主机并建立实时连接'
                      : '支持多 Host 健康监控与一键无感切换'),
              highlight: !connected,
              onTap: () {
                if (connected) {
                  unawaited(contentCtrl.fetchContent(resetSession: true));
                } else {
                  _switchToTab(3);
                }
              },
            ),
            const SizedBox(height: 12),
            _buildGreetingCard(
              p: p,
              icon: Icons.rocket_launch_rounded,
              iconColor: const Color(0xFF0EA5E9),
              title: '一键启动 AI IDE 与对话应用 (CDP)',
              subtitle: 'Antigravity / ChatGPT / Claude / VS Code / Cursor 启动与切换',
              onTap: () => _switchToTab(3),
            ),
            const SizedBox(height: 12),
            _buildGreetingCard(
              p: p,
              icon: Icons.screenshot_monitor_rounded,
              iconColor: const Color(0xFF10B981),
              title: '低延迟远程控屏与触控',
              subtitle: 'WS 极速流 / WebRTC 画面支持双指缩放与远程点击',
              highlight: connected,
              onTap: () => _switchToTab(1),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGreetingCard({
    required VibePalette p,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool highlight = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          gradient: highlight && !p.isDark
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFFFFFFF),
                    Color(0xFFF3F4FF),
                    Color(0xFFFCF2F8),
                  ],
                )
              : null,
          color: highlight && !p.isDark
              ? null
              : p.panel.withValues(alpha: p.isDark ? 1.0 : 0.92),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: highlight
                ? p.accent.withValues(alpha: 0.25)
                : p.border.withValues(alpha: 0.8),
          ),
          boxShadow: p.isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.035),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 22, color: iconColor),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: p.muted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: p.panelAlt,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.north_east_rounded,
                size: 18,
                color: p.text,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlusToolsDrawer(
    VibePalette p,
    bool connected,
    WindowListState winState,
    WindowContentMessage? content,
    String activeModel,
  ) {
    final actions = ref.read(hostActionProvider);
    final targetWindowId = winState.selectedWindowId;

    Widget primaryTile({
      required IconData icon,
      required String label,
      Color? tintColor,
      bool semanticTint = false,
      VoidCallback? onTap,
    }) {
      final enabled = onTap != null;
      final base = tintColor ?? p.text;
      final fg = enabled ? base : p.muted;
      final bg = semanticTint
          ? base.withValues(alpha: enabled ? 0.10 : 0.04)
          : p.panelAlt;
      final border = semanticTint
          ? base.withValues(alpha: enabled ? 0.28 : 0.12)
          : p.border;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget slashChip(String label, VoidCallback? onTap) {
      final enabled = onTap != null;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: p.panelAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: enabled ? p.text : p.muted,
            ),
          ),
        ),
      );
    }

    Widget keyCap({
      required String label,
      Color? color,
      VoidCallback? onTap,
    }) {
      final enabled = onTap != null;
      final fg = enabled ? (color ?? p.text) : p.muted;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            decoration: BoxDecoration(
              color: p.panelAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border),
        boxShadow: p.isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              primaryTile(
                icon: Icons.attach_file_rounded,
                label: _uploadingFile ? '上传中...' : '传图/文件',
                tintColor: p.accent,
                onTap: connected && !_uploadingFile ? _pickAndUploadFile : null,
              ),
              const SizedBox(width: 7),
              primaryTile(
                icon: Icons.tune_rounded,
                label: '切换模型',
                tintColor: p.accent,
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        openModelPickerSheet(
                          context,
                          ref,
                          activeModel,
                          content?.availableModels ?? const <String>[],
                          targetWindowId,
                        );
                      }
                    : null,
              ),
              const SizedBox(width: 7),
              primaryTile(
                icon: Icons.data_usage_rounded,
                label: '额度与用量',
                tintColor: p.accent,
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        showUsageQuotaSheet(context, ref);
                      }
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              primaryTile(
                icon: Icons.check_rounded,
                label: '允许',
                tintColor: p.success,
                semanticTint: true,
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        actions.sendControlKey(
                          key: 'vh:accept',
                          targetWindowId: targetWindowId,
                        );
                      }
                    : null,
              ),
              const SizedBox(width: 7),
              primaryTile(
                icon: Icons.close_rounded,
                label: '拒绝',
                tintColor: p.danger,
                semanticTint: true,
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        actions.sendControlKey(
                          key: 'vh:reject',
                          targetWindowId: targetWindowId,
                        );
                      }
                    : null,
              ),
              const SizedBox(width: 7),
              primaryTile(
                icon: Icons.play_arrow_rounded,
                label: '继续',
                tintColor: p.accent,
                semanticTint: true,
                onTap: connected ? () => _sendText(overrideText: '继续') : null,
              ),
            ],
          ),
          const SizedBox(height: 9),
          Divider(height: 1, color: p.border),
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              slashChip(
                '/plan',
                connected ? () => _insertDraft('/plan ') : null,
              ),
              slashChip(
                '/boost',
                connected ? () => _insertDraft('/boost ') : null,
              ),
              slashChip(
                '/compact',
                connected ? () => _sendText(overrideText: '/compact') : null,
              ),
              slashChip(
                '/goal',
                connected ? () => _insertDraft('/goal ') : null,
              ),
              slashChip(
                '/grill-me',
                connected ? () => _insertDraft('/grill-me ') : null,
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              keyCap(
                label: 'Esc',
                color: p.warning,
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        actions.sendControlKey(
                          key: 'Escape',
                          targetWindowId: targetWindowId,
                        );
                      }
                    : null,
              ),
              const SizedBox(width: 7),
              keyCap(
                label: 'Ctrl+Z',
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        actions.sendControlKey(
                          key: 'z',
                          modifiers: const ['ctrl'],
                          targetWindowId: targetWindowId,
                        );
                      }
                    : null,
              ),
              const SizedBox(width: 7),
              keyCap(
                label: 'Ctrl+C',
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        actions.sendControlKey(
                          key: 'c',
                          modifiers: const ['ctrl'],
                          targetWindowId: targetWindowId,
                        );
                      }
                    : null,
              ),
              const SizedBox(width: 7),
              keyCap(
                label: 'Enter',
                onTap: connected
                    ? () {
                        setState(() => _showPlusMenu = false);
                        actions.sendControlKey(
                          key: 'Enter',
                          targetWindowId: targetWindowId,
                        );
                      }
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showLocalImagePreview(_PendingAttachment att) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.6,
                maxScale: 4.0,
                child: Center(
                  child: Image.file(
                    File(att.localPath),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black.withValues(alpha: 0.6),
                shape: const CircleBorder(),
                child: IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingAttachmentsBar(VibePalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: p.panel.withValues(alpha: p.isDark ? 0.94 : 0.96),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.border),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (int i = 0; i < _pendingAttachments.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                if (_pendingAttachments[i].kind == 'image')
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: () =>
                            _showLocalImagePreview(_pendingAttachments[i]),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: p.panelAlt,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: p.border),
                            ),
                            child: Image.file(
                              File(_pendingAttachments[i].localPath),
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.broken_image_outlined,
                                size: 22,
                                color: p.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: -5,
                        right: -5,
                        child: GestureDetector(
                          onTap: () => _removePendingAttachment(i),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: p.isDark
                                  ? const Color(0xFF1F2430)
                                  : Colors.black.withValues(alpha: 0.72),
                              shape: BoxShape.circle,
                              border: Border.all(color: p.panel, width: 1.5),
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 11,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  Container(
                    height: 40,
                    padding: const EdgeInsets.fromLTRB(9, 0, 6, 0),
                    decoration: BoxDecoration(
                      color: p.panelAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.insert_drive_file_outlined,
                            size: 15, color: p.accent),
                        const SizedBox(width: 5),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 140),
                          child: Text(
                            _pendingAttachments[i].filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: p.text,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: () => _removePendingAttachment(i),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child:
                                Icon(Icons.close_rounded, size: 14, color: p.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingPillComposer(
    VibePalette p,
    bool connected,
    RemoteStreamState streamState, {
    bool isWorking = false,
  }) {
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    final canSend = hasText || _pendingAttachments.isNotEmpty;
    final showStop = connected && !canSend && isWorking;
    final micOn = streamState.audioBridgeActive;

    return Padding(
      key: const ValueKey('vh_floating_composer'),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: _holdingMic || micOn
                ? p.danger.withValues(alpha: 0.6)
                : p.border,
          ),
          boxShadow: p.isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Left `+` tools toggle
            IconButton(
              onPressed: () {
                HapticFeedback.selectionClick();
                setState(() => _showPlusMenu = !_showPlusMenu);
              },
              icon: AnimatedRotation(
                turns: _showPlusMenu ? 0.125 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(Icons.add_rounded, size: 25, color: p.text),
              ),
              tooltip: '快捷指令与附件',
            ),

            // Input TextField ("问一问或按住说话")
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                focusNode: _inputFocus,
                enabled: true,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: _onInputChanged,
                onSubmitted: connected ? (_) => _sendText() : null,
                style: TextStyle(fontSize: 15, color: p.text),
                decoration: InputDecoration(
                  hintText: _holdingMic
                      ? '正在长按说话，松开结束...'
                      : (connected ? '问一问或按住说话' : '未连接 Host，可先切换「主机」'),
                  hintStyle: TextStyle(fontSize: 15, color: p.muted),
                  filled: false,
                  fillColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
                ),
              ),
            ),

            // Keyboard dismiss button (shown on iOS / mobile when soft keyboard or focus is active)
            if (_inputFocus.hasFocus ||
                MediaQuery.of(context).viewInsets.bottom > 0)
              IconButton(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() {});
                },
                icon: Icon(
                  Icons.keyboard_hide_rounded,
                  size: 20,
                  color: p.muted,
                ),
                tooltip: '收起键盘',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
              ),

            // Mic Button: Tap toggles continuous virtual mic, Long Press holds-to-talk
            GestureDetector(
              onTap: connected
                  ? () {
                      HapticFeedback.lightImpact();
                      unawaited(
                        ref
                            .read(remoteStreamProvider.notifier)
                            .toggleAudioBridge(),
                      );
                    }
                  : null,
              onLongPressStart: connected ? (_) => _onMicHoldStart() : null,
              onLongPressEnd: connected ? (_) => _onMicHoldEnd() : null,
              onLongPressCancel: _onMicHoldEnd,
              child: Container(
                width: 38,
                height: 38,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: micOn || _holdingMic
                      ? p.danger.withValues(alpha: 0.16)
                      : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  micOn ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                  size: 22,
                  color: micOn || _holdingMic
                      ? p.danger
                      : (connected ? p.text : p.muted),
                ),
              ),
            ),

            // Right Circular Action: Send (when text/attachments) | Stop (when working) | Switch to 控屏
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: canSend
                  ? (connected ? () => _sendText() : null)
                  : showStop
                      ? () =>
                          _interruptCurrentAgent(pullLastPromptForEdit: true)
                      : () {
                          HapticFeedback.lightImpact();
                          _switchToTab(1);
                        },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: canSend
                      ? (connected ? p.accent : p.muted)
                      : (showStop ? p.danger : p.panelAlt),
                  shape: BoxShape.circle,
                  border: (canSend || showStop)
                      ? null
                      : Border.all(color: p.border),
                ),
                child: Icon(
                  canSend
                      ? Icons.arrow_upward_rounded
                      : (showStop
                          ? Icons.stop_rounded
                          : Icons.visibility_outlined),
                  size: 20,
                  color: (canSend || showStop) ? Colors.white : p.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueuePanel(VibePalette p, List<String> queue) {
    return Padding(
      key: const ValueKey('vh_queue_panel'),
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Container(
        decoration: BoxDecoration(
          color: p.panel.withValues(alpha: p.isDark ? 0.94 : 0.96),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.accent.withValues(alpha: 0.35)),
          boxShadow: p.isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _queueExpanded = !_queueExpanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  children: [
                    Icon(Icons.playlist_play_rounded,
                        size: 16, color: p.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '排队中 (${queue.length} 条待执行)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: p.accent,
                        ),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => _interruptCurrentAgent(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: p.warning.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                              color: p.warning.withValues(alpha: 0.5)),
                        ),
                        child: Text(
                          '打断',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: p.warning,
                          ),
                        ),
                      ),
                    ),
                    Icon(
                      _queueExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: p.muted,
                    ),
                  ],
                ),
              ),
            ),
            if (_queueExpanded) ...[
              Divider(height: 1, color: p.border.withValues(alpha: 0.7)),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 110),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  itemCount: queue.length,
                  itemBuilder: (_, idx) => Padding(
                    padding: EdgeInsets.only(top: idx > 0 ? 4 : 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.panelAlt,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            '${idx + 1}',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: p.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            queue[idx],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: p.text,
                              height: 1.3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          borderRadius: BorderRadius.circular(7),
                          onTap: () => unawaited(
                            _interruptAndSteer(
                              queue[idx],
                              removeFromLocalQueue: true,
                            ),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: p.accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                  color: p.accent.withValues(alpha: 0.45)),
                            ),
                            child: Text(
                              '打断发送',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: p.accent,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(7),
                          onTap: () {
                            final qText = queue[idx];
                            HapticFeedback.lightImpact();
                            setState(() {
                              _localQueuedMessages.remove(qText);
                              _localQueueAddedAt.remove(qText);
                            });
                            ref.read(hostActionProvider).sendControlKey(
                                  key: 'vh:delete_queued:$qText',
                                  targetWindowId: ref
                                      .read(windowControllerProvider)
                                      .selectedWindowId,
                                );
                            Future<void>.delayed(
                                const Duration(milliseconds: 500), () {
                              if (!mounted) return;
                              unawaited(ref
                                  .read(windowContentProvider.notifier)
                                  .fetchContent());
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: p.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: 控屏 (Live Stream / Snapshot + ZoomableViewport)
  // ---------------------------------------------------------------------------

  Widget _buildScreenTab({
    required VibePalette p,
    required bool connected,
    required WindowContentState contentState,
    required RemoteStreamState streamState,
  }) {
    final contentCtrl = ref.read(windowContentProvider.notifier);
    final streamCtrl = ref.read(remoteStreamProvider.notifier);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _screenPill(
                  p: p,
                  label: '实时画面',
                  active: _screenSubMode == 1,
                  onTap: () {
                    setState(() => _screenSubMode = 1);
                    if (connected) {
                      unawaited(streamCtrl.startStream(overrideMode: 'window'));
                    }
                  },
                ),
                const SizedBox(width: 6),
                _screenPill(
                  p: p,
                  label: '静态快照',
                  active: _screenSubMode == 0,
                  onTap: () {
                    setState(() => _screenSubMode = 0);
                    if (streamState.isStreaming) {
                      unawaited(streamCtrl.stopStream());
                    }
                    if (connected) {
                      unawaited(contentCtrl.fetchSnapshot());
                    }
                  },
                ),
                const SizedBox(width: 8),
                if (_screenSubMode == 1) ...[
                  if (streamState.isWsVideo) ...[
                    _screenPill(
                      p: p,
                      label: '画质:${streamState.qualityPresetLabel}',
                      active: false,
                      textColor: p.success,
                      onTap: connected
                          ? () => unawaited(streamCtrl.cycleQualityPreset())
                          : null,
                    ),
                    const SizedBox(width: 6),
                  ],
                  _screenPill(
                    p: p,
                    label: streamState.isWsVideo ? 'WS极速流' : 'WebRTC',
                    active: false,
                    textColor: p.accent,
                    onTap: connected
                        ? () {
                            final next = streamState.transport == 'ws_mjpeg'
                                ? 'webrtc'
                                : 'ws_mjpeg';
                            unawaited(
                              streamCtrl.startStream(overrideTransport: next),
                            );
                          }
                        : null,
                  ),
                  const SizedBox(width: 6),
                  _screenPill(
                    p: p,
                    label: streamState.mode == 'screen' ? '全屏' : '单窗',
                    active: false,
                    onTap: connected
                        ? () {
                            final next = streamState.mode == 'screen'
                                ? 'window'
                                : 'screen';
                            unawaited(
                              streamCtrl.startStream(overrideMode: next),
                            );
                          }
                        : null,
                  ),
                  const SizedBox(width: 6),
                ],
                _screenPill(
                  p: p,
                  label: '刷新',
                  active: false,
                  textColor: p.accent,
                  onTap: connected
                      ? () {
                          if (_screenSubMode == 0) {
                            unawaited(contentCtrl.fetchSnapshot());
                          } else {
                            unawaited(streamCtrl.startStream(
                              overrideMode: streamState.mode,
                            ));
                          }
                        }
                      : null,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: _screenSubMode == 0
                ? _buildSnapshotViewer(p, contentState, contentCtrl)
                : _buildWebRtcViewer(p, streamState, streamCtrl),
          ),
        ),
      ],
    );
  }

  Widget _screenPill({
    required VibePalette p,
    required String label,
    required bool active,
    Color? textColor,
    VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? p.accent : p.panel,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? p.accent : p.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : (textColor ?? p.text),
          ),
        ),
      ),
    );
  }

  Rect _fitRect(Size box, double aspect) {
    final boxAspect = box.width / math.max(1.0, box.height);
    if (boxAspect > aspect) {
      final h = box.height;
      final w = h * aspect;
      return Rect.fromLTWH((box.width - w) / 2, 0, w, h);
    }
    final w = box.width;
    final h = w / math.max(0.01, aspect);
    return Rect.fromLTWH(0, (box.height - h) / 2, w, h);
  }

  Widget _buildSnapshotViewer(
    VibePalette p,
    WindowContentState st,
    WindowContentController ctrl,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF050811),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: st.snapshotBytes == null
          ? Center(
              child: Text(
                '点击上方「刷新」抓取窗口快照\n轻触画面任意位置即可远程点击对应坐标',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            )
          : LayoutBuilder(
              builder: (ctx, c) {
                final box = Size(c.maxWidth, c.maxHeight);
                return ZoomableViewport(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) {
                      final r = _fitRect(box, st.snapshotAspectRatio);
                      if (!r.contains(d.localPosition)) return;
                      ctrl.sendSnapshotClick(
                        xNorm: (d.localPosition.dx - r.left) / r.width,
                        yNorm: (d.localPosition.dy - r.top) / r.height,
                      );
                    },
                    child: Image.memory(
                      st.snapshotBytes!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildWebRtcViewer(
    VibePalette p,
    RemoteStreamState st,
    RemoteStreamController ctrl,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF050811),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (ctx, c) {
          final box = Size(c.maxWidth, c.maxHeight);
          return ZoomableViewport(
            showControls: st.isVideoStreaming,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                if (!st.isVideoStreaming) return;
                final r = _fitRect(box, st.aspectRatio);
                if (!r.contains(d.localPosition)) return;
                ctrl.sendPointer(
                  action: 'click',
                  xNorm: (d.localPosition.dx - r.left) / r.width,
                  yNorm: (d.localPosition.dy - r.top) / r.height,
                );
              },
              onDoubleTapDown: (d) {
                if (!st.isVideoStreaming) return;
                final r = _fitRect(box, st.aspectRatio);
                if (!r.contains(d.localPosition)) return;
                ctrl.sendPointer(
                  action: 'double_click',
                  xNorm: (d.localPosition.dx - r.left) / r.width,
                  yNorm: (d.localPosition.dy - r.top) / r.height,
                );
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (st.isVideoStreaming &&
                      st.isWsVideo &&
                      st.liveFrameBytes != null)
                    Image.memory(
                      st.liveFrameBytes!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    )
                  else if (st.isVideoStreaming && !st.isWsVideo)
                    RTCVideoView(
                      ctrl.renderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      filterQuality: FilterQuality.medium,
                    )
                  else
                    Center(
                      child: Text(
                        st.phase == StreamPhase.starting
                            ? (st.isWsVideo
                                ? '正在拉取实时画面 (WS 极速流)...'
                                : '正在连接 WebRTC 视频流...')
                            : '点击上方「刷新」开启实时远程画面',
                        style: TextStyle(color: p.muted, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 2: 主机 (Multi-Host Live Health Dashboard + AI IDE CDP Launcher)
  // ---------------------------------------------------------------------------

  Widget _buildHostTab({
    required VibePalette p,
    required bool connected,
    required AppSettings settings,
    required WindowListState winState,
    HostInfo? liveHostInfo,
  }) {
    final winCtrl = ref.read(windowControllerProvider.notifier);

    return RefreshIndicator(
      onRefresh: () async {
        await _probeAllHosts();
        if (connected) {
          await _loadHostApps();
          await winCtrl.refresh();
        }
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        children: [
          // Section 1: Multi-Host Dashboard Header
          Row(
            children: [
              Icon(Icons.dns_rounded, size: 18, color: p.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '多主机实时监测',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _probingHosts ? null : _probeAllHosts,
                icon: _probingHosts
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('探测', style: TextStyle(fontSize: 12)),
              ),
              FilledButton.icon(
                onPressed: () => _showEditHostDialog(),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('新增', style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          for (final profile in settings.hostProfiles) ...[
            _buildHostHealthCard(
              p: p,
              profile: profile,
              isActive: profile.id == settings.activeHostId,
              connected: connected && profile.id == settings.activeHostId,
              probe: _hostProbes[profile.id],
              liveHostInfo: connected && profile.id == settings.activeHostId
                  ? liveHostInfo
                  : null,
              canDelete: settings.hostProfiles.length > 1,
            ),
            const SizedBox(height: 10),
          ],

          // Security & Audit Log Card
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              final active = settings.activeHost;
              final base = httpBaseFromWsUrl(active.wsUrl);
              if (base == null) {
                _showTopNotice('当前主机地址无效，无法读取访问日志', isError: true);
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AccessLogPage(
                    hostHttpBase: base,
                    hostToken: active.token,
                    hostName: active.name.trim().isNotEmpty
                        ? active.name.trim()
                        : inferHostLabel(active.wsUrl),
                  ),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: p.panel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.policy_rounded,
                        size: 20, color: p.accent),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'IP 访问与终端审计日志',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '查看所有连接过宿主机的 IP、语音/注入、终端命令与异常访问',
                          style: TextStyle(fontSize: 11.5, color: p.muted),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: p.muted),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // Section 2: AI IDE CDP Launcher & Switcher
          Row(
            children: [
              Icon(Icons.rocket_launch_rounded, size: 18, color: p.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'AI IDE 启动与切换 (CDP 零抢焦)',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新 IDE 列表',
                onPressed: connected && !_loadingApps ? _loadHostApps : null,
                icon: _loadingApps
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.refresh_rounded, size: 18, color: p.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (!connected)
            _emptyHintCard(p, '连接任意主机后，自动扫描并支持一键启动 Antigravity / ChatGPT / Claude / VS Code / Cursor / WorkBuddy')
          else if (_ideApps.isEmpty)
            _emptyHintCard(p, _loadingApps ? '正在扫描宿主机已安装的 AI 应用...' : '点击右上角刷新扫描宿主机 AI 应用')
          else
            for (final app in _sortedIdeApps()) ...[
              _buildIdeAppCard(p, app),
              const SizedBox(height: 8),
            ],

          const SizedBox(height: 10),

          // Section 3: Target Window Quick Lock
          Row(
            children: [
              Icon(Icons.desktop_windows_rounded, size: 18, color: p.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '目标窗口锁定 (${winState.windows.length})',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              TextButton(
                onPressed: connected ? _openWindowPickerSheet : null,
                child: const Text('展开全部', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (!connected)
            _emptyHintCard(p, '连接主机后可在此选择注入目标窗口')
          else if (winState.windows.isEmpty)
            _emptyHintCard(p, '暂未发现窗口，可点击顶部「焦点窗口」或下拉刷新')
          else
            for (final w in winState.windows.take(6)) ...[
              InkWell(
                borderRadius: BorderRadius.circular(13),
                onTap: () {
                  HapticFeedback.selectionClick();
                  winCtrl.selectWindow(w.id);
                  unawaited(ref
                      .read(windowContentProvider.notifier)
                      .fetchContent(resetSession: true));
                  _switchToTab(0);
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 7),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: w.id == winState.selectedWindowId
                        ? p.accent.withValues(alpha: 0.12)
                        : p.panel,
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: w.id == winState.selectedWindowId
                          ? p.accent
                          : p.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: p.panelAlt,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          w.app,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: p.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          w.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: p.text),
                        ),
                      ),
                      if (w.id == winState.selectedWindowId)
                        Icon(Icons.check_circle_rounded,
                            size: 16, color: p.accent),
                    ],
                  ),
                ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _buildHostHealthCard({
    required VibePalette p,
    required HostProfile profile,
    required bool isActive,
    required bool connected,
    required HostHealthProbe? probe,
    HostInfo? liveHostInfo,
    required bool canDelete,
  }) {
    final online = connected || (probe?.online ?? false);
    final agentStatusLabel = switch (probe?.agentStatus ?? 'idle') {
      'working' => '执行中',
      'waiting_approval' => '待审批',
      _ => '空闲',
    };
    final agentColor = switch (probe?.agentStatus ?? 'idle') {
      'working' => p.accent,
      'waiting_approval' => p.warning,
      _ => p.muted,
    };

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? p.accent : p.border,
          width: isActive ? 1.5 : 1.0,
        ),
        boxShadow: p.isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: online
                      ? p.success
                      : (probe == null ? p.warning : p.danger),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              if (connected)
                _miniTag(p, '当前已连', p.success)
              else if (isActive)
                _miniTag(p, '默认', p.accent),
              if (probe?.rttMs != null) ...[
                const SizedBox(width: 5),
                _miniTag(p, '${probe!.rttMs}ms', p.muted),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Text(
            profile.wsUrl,
            style: TextStyle(
                fontSize: 11.5, color: p.muted, fontFamily: 'monospace'),
          ),
          if (probe != null && probe.online) ...[
            const SizedBox(height: 7),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [
                _miniTag(
                  p,
                  '${probe.osName.toUpperCase()} · ${probe.displayServer}',
                  p.text,
                ),
                if (probe.version.isNotEmpty)
                  _miniTag(
                    p,
                    probe.buildId.isNotEmpty
                        ? 'v${probe.version} · ${probe.buildId}'
                        : 'v${probe.version}',
                    p.muted,
                  ),
                _miniTag(p, '窗口 ${probe.windowCount}', p.text),
                _miniTag(p, 'Agent $agentStatusLabel', agentColor),
                if (probe.cdpActiveCount > 0)
                  _miniTag(p, 'CDP ${probe.cdpActiveCount} 激活', p.success),
              ],
            ),
            if (probe.activeSessionTitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '当前会话: ${probe.activeSessionTitle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: p.muted),
              ),
            ],
          ] else if (connected) ...[
            const SizedBox(height: 7),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [
                if (liveHostInfo != null)
                  _miniTag(
                    p,
                    '${liveHostInfo.os.toUpperCase()} · ${liveHostInfo.displayServer}',
                    p.text,
                  ),
                _miniTag(p, 'WS 已连接', p.success),
              ],
            ),
          ] else if (probe != null && probe.error != null) ...[
            const SizedBox(height: 5),
            Text(
              '离线 (${probe.error})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: p.danger),
            ),
          ],
          const SizedBox(height: 9),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: () => _connectHost(profile),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: p.accent.withValues(alpha: 0.14),
                  foregroundColor: p.accent,
                ),
                child: Text(connected ? '重连并刷新' : '连接并切换',
                    style: const TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              IconButton(
                tooltip: '编辑主机',
                onPressed: () => _showEditHostDialog(existing: profile),
                icon: Icon(Icons.edit_outlined, size: 18, color: p.muted),
              ),
              if (canDelete)
                IconButton(
                  tooltip: '删除主机',
                  onPressed: () async {
                    await ref
                        .read(settingsProvider.notifier)
                        .deleteHostProfile(profile.id);
                    unawaited(_probeAllHosts());
                  },
                  icon:
                      Icon(Icons.delete_outline_rounded, size: 18, color: p.danger),
                ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _ideIconFor(String ideId) {
    return switch (ideId.toLowerCase()) {
      'antigravity' => Icons.auto_awesome_rounded,
      'chatgpt' => Icons.chat_bubble_outline_rounded,
      'claude' => Icons.psychology_rounded,
      'vscode' => Icons.code_rounded,
      'cursor' => Icons.edit_note_rounded,
      'workbuddy' => Icons.smart_toy_outlined,
      _ => Icons.terminal_rounded,
    };
  }

  List<HostIdeApp> _sortedIdeApps() {
    final list = List<HostIdeApp>.from(_ideApps);
    int rank(HostIdeApp a) {
      if (a.running && a.cdpActive) return 0;
      if (a.running) return 1;
      if (a.installed) return 2;
      return 3;
    }

    list.sort((a, b) => rank(a).compareTo(rank(b)));
    return list;
  }

  Widget _buildQuickAppStrip(
    VibePalette p, {
    required void Function(VoidCallback) sheetSetState,
    required VoidCallback onDone,
  }) {
    final installed = _sortedIdeApps().where((a) => a.installed).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.apps_rounded, size: 15, color: p.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '快捷启动 / 切换应用 (${installed.length})',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
              ),
              if (_loadingApps)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: p.accent),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: installed.length,
              separatorBuilder: (_, __) => const SizedBox(width: 7),
              itemBuilder: (_, idx) {
                final app = installed[idx];
                final busy = _busyIdeId == app.id;
                final dotColor = app.running
                    ? (app.cdpActive || app.isCli ? p.success : p.warning)
                    : p.muted;
                final actionLabel = app.running ? '切换' : '启动';
                return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: busy
                      ? null
                      : () async {
                          sheetSetState(() {});
                          if (app.running) {
                            onDone();
                            await _focusIde(app);
                          } else {
                            await _launchIde(app, restart: false);
                            sheetSetState(() {});
                          }
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: app.running
                          ? p.accent.withValues(alpha: 0.11)
                          : p.panelAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: app.running
                            ? p.accent.withValues(alpha: 0.45)
                            : p.border,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(_ideIconFor(app.id), size: 15, color: p.text),
                        const SizedBox(width: 5),
                        Text(
                          app.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          busy ? '...' : actionLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: app.running ? p.accent : p.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdeAppCard(VibePalette p, HostIdeApp app) {
    final isBusy = _busyIdeId == app.id;
    final isCli = app.isCli;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (app.cdpActive || (isCli && app.running))
              ? p.success.withValues(alpha: 0.45)
              : p.border,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (app.installed ? p.accent : p.muted).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _ideIconFor(app.id),
              size: 20,
              color: app.installed ? p.accent : p.muted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      app.name,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    if (!app.installed)
                      _miniTag(p, '未检测到', p.muted)
                    else ...[
                      _miniTag(
                        p,
                        app.running ? '运行中' : '未启动',
                        app.running ? p.success : p.muted,
                      ),
                      if (isCli)
                        _miniTag(p, 'CLI', p.accent)
                      else if (app.cdpActive)
                        _miniTag(p, 'CDP :${app.cdpPort}', p.success)
                      else if (app.running)
                        _miniTag(p, '需重启开CDP', p.warning),
                    ],
                  ],
                ),
                if (app.exePath.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    app.exePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: p.muted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (app.installed) ...[
            if (!app.running)
              OutlinedButton(
                onPressed: isBusy ? null : () => _launchIde(app, restart: false),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                child: Text(isCli ? '启动终端' : '启动 CDP', style: const TextStyle(fontSize: 11.5)),
              )
            else ...[
              if (!isCli && !app.cdpActive) ...[
                OutlinedButton(
                  onPressed:
                      isBusy ? null : () => _launchIde(app, restart: true),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  child: const Text('重启 CDP', style: TextStyle(fontSize: 11)),
                ),
                const SizedBox(width: 4),
              ],
              FilledButton.tonal(
                onPressed: isBusy ? null : () => _focusIde(app),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: p.accent.withValues(alpha: 0.14),
                  foregroundColor: p.accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                child: const Text('切换', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 3: 我的 (Theme Toggle, Voice & Input Settings, App Info)
  // ---------------------------------------------------------------------------

  Widget _buildMineTab({
    required VibePalette p,
    required bool connected,
    required AppSettings settings,
    required SocketSnapshot connSnap,
  }) {
    final settingsCtrl = ref.read(settingsProvider.notifier);
    final hotCfg = ref.watch(appUpdateProvider).hotConfig;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 22),
      children: [
        // Identity & Connection Summary Banner
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [p.accent, const Color(0xFF06B6D4)],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.bolt_rounded,
                    size: 26, color: Colors.white),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      settings.clientName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      connected
                          ? '已连接至 ${settings.activeHost.name} (${connSnap.hostInfo?.hostname ?? ''})'
                          : '当前未连接 · 默认主机: ${settings.activeHost.name}',
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _showEditClientNameDialog,
                icon: Icon(Icons.edit_outlined, size: 19, color: p.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        _settingsSection(
          p: p,
          title: '外观主题',
          children: [
            SwitchListTile(
              title: Text('深色极客主题',
                  style: TextStyle(fontSize: 14, color: p.text)),
              subtitle: Text('默认关闭即为「灵光」浅色极简毛玻璃风',
                  style: TextStyle(fontSize: 11.5, color: p.muted)),
              value: settings.isDarkTheme,
              onChanged: (v) async {
                await settingsCtrl.update(settings.copyWith(isDarkTheme: v));
                if (settings.overlayMode == 'mini' &&
                    OverlayNotifier.isSupported) {
                  await _syncActiveOverlay(forceShow: true);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),

        _settingsSection(
          p: p,
          title: OverlayNotifier.isIOS ? '通知与系统灵动岛' : '通知、保活与灵动中岛',
          children: [
            SwitchListTile(
              title: Text(
                OverlayNotifier.isIOS ? 'iOS 系统通知推送' : '系统消息通知（适配小米）',
                style: TextStyle(fontSize: 14, color: p.text),
              ),
              subtitle: Text(
                OverlayNotifier.isNotificationSupported
                    ? (_notifPermGranted
                        ? (OverlayNotifier.isIOS
                            ? '后台或切到其他页时推送 iOS 顶部横幅，支持通知栏直接允许/拒绝'
                            : '后台或切到其他页时推送高优先级系统横幅通知')
                        : (OverlayNotifier.isIOS
                            ? '需授权系统通知权限（允许横幅与声音提醒）'
                            : '需授权通知权限（小米请在系统通知设置中开启「悬浮通知」）'))
                    : '当前平台暂不支持移动系统通知栏推送',
                style: TextStyle(fontSize: 11.5, color: p.muted),
              ),
              value: settings.systemNotifications,
              onChanged: (v) async {
                await settingsCtrl
                    .update(settings.copyWith(systemNotifications: v));
                if (v && OverlayNotifier.isNotificationSupported) {
                  final granted = await OverlayNotifier.canPostNotifications();
                  if (!mounted) return;
                  setState(() => _notifPermGranted = granted);
                  if (!granted) {
                    await OverlayNotifier.requestNotificationPermission();
                  }
                }
              },
            ),
            ListTile(
              dense: true,
              title: Text(
                OverlayNotifier.isNotificationSupported
                    ? (_notifPermGranted ? '通知权限：已授权' : '通知权限：未授权')
                    : '通知权限：当前平台不支持',
                style: TextStyle(
                  fontSize: 12.5,
                  color: !OverlayNotifier.isNotificationSupported
                      ? p.muted
                      : (_notifPermGranted ? p.success : p.warning),
                ),
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: OverlayNotifier.isNotificationSupported
                        ? () => unawaited(
                              OverlayNotifier.openNotificationSettings(),
                            )
                        : null,
                    child: const Text('通知设置'),
                  ),
                  TextButton(
                    onPressed: OverlayNotifier.isNotificationSupported
                        ? () async {
                            final granted =
                                await OverlayNotifier.canPostNotifications();
                            if (!mounted) return;
                            setState(() => _notifPermGranted = granted);
                            if (!granted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    OverlayNotifier.isIOS
                                        ? '请先在弹出的系统窗口或「设置 → 通知」允许 VibeHelper 通知'
                                        : '请先授予通知权限，小米建议同时开启悬浮通知',
                                  ),
                                  duration: const Duration(seconds: 3),
                                ),
                              );
                              await OverlayNotifier.requestNotificationPermission();
                              return;
                            }
                            await OverlayNotifier.showSystemNotification(
                              title: 'Agent 请求授权',
                              body: '这是一条测试通知：如果能看到顶部横幅和允许/拒绝按钮，说明通知通道正常。',
                              showActions: true,
                            );
                          }
                        : null,
                    child: const Text('测试通知'),
                  ),
                ],
              ),
            ),
            if (!OverlayNotifier.isIOS) ...[
              Divider(height: 1, color: p.border),
              SwitchListTile(
                title: Text('小米后台保活服务',
                    style: TextStyle(fontSize: 14, color: p.text)),
                subtitle: Text(
                  OverlayNotifier.isSupported
                      ? '通过轻量前台服务防止 HyperOS / MIUI 切后台断连，保证中岛实时跳动'
                      : '仅 Android 设备支持后台保活服务',
                  style: TextStyle(fontSize: 11.5, color: p.muted),
                ),
                value: settings.backgroundKeepAlive,
                onChanged: OverlayNotifier.isSupported
                    ? (v) async {
                        await settingsCtrl
                            .update(settings.copyWith(backgroundKeepAlive: v));
                        _syncKeepAlive();
                      }
                    : null,
              ),
            ],
            Divider(height: 1, color: p.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    OverlayNotifier.isIOS ? '系统灵动岛实时活动' : '悬浮窗显示形态',
                    style: TextStyle(fontSize: 14, color: p.text),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: OverlayNotifier.isIOS
                          ? const [
                              ButtonSegment(value: 'off', label: Text('关闭')),
                              ButtonSegment(
                                  value: 'island', label: Text('系统灵动岛')),
                            ]
                          : const [
                              ButtonSegment(value: 'off', label: Text('关闭')),
                              ButtonSegment(
                                  value: 'island', label: Text('灵动中岛')),
                              ButtonSegment(
                                  value: 'mini', label: Text('简版悬浮')),
                            ],
                      selected: {
                        (OverlayNotifier.isIOS && settings.overlayMode == 'mini')
                            ? 'island'
                            : settings.overlayMode,
                      },
                      onSelectionChanged: (sel) async {
                        final nextMode = sel.first;
                        await settingsCtrl
                            .update(settings.copyWith(overlayMode: nextMode));
                        if (OverlayNotifier.isIOS) {
                          if (nextMode == 'off') {
                            await OverlayNotifier.hideIsland();
                          } else {
                            await _syncActiveOverlay(forceShow: true);
                          }
                          return;
                        }
                        if (!OverlayNotifier.isOverlaySupported) return;
                        if (nextMode == 'off') {
                          await OverlayNotifier.hideIsland();
                          await OverlayNotifier.hideMiniWindow();
                          return;
                        }
                        final granted = await OverlayNotifier.canDrawOverlays();
                        final a11yEnabled =
                            await OverlayNotifier.isAccessibilityIslandEnabled();
                        if (!mounted) return;
                        setState(() {
                          _overlayPermGranted = granted;
                          _a11yIslandEnabled = a11yEnabled;
                        });
                        final canShow =
                            nextMode == 'island' ? (a11yEnabled || granted) : granted;
                        if (!canShow) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('请授予悬浮窗权限，或在下方开启「贴顶挖孔无障碍模式」'),
                              duration: Duration(seconds: 3),
                            ),
                          );
                          await OverlayNotifier.requestOverlayPermission();
                        } else {
                          await _syncActiveOverlay(forceShow: true);
                        }
                      },
                    ),
                  ),
                  if (OverlayNotifier.isIOS) ...[
                    const SizedBox(height: 6),
                    Text(
                      '应用在前台时不显示中岛；切到后台或锁屏后在 iPhone 灵动岛与锁屏显示实时活动',
                      style: TextStyle(fontSize: 11.5, color: p.muted),
                    ),
                  ],
                ],
              ),
            ),
            if (OverlayNotifier.isSupported)
              ListTile(
                dense: true,
                title: Text(
                  _overlayPermGranted ? '悬浮窗权限：已授权' : '悬浮窗权限：未授权',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _overlayPermGranted ? p.success : p.warning,
                  ),
                ),
                trailing: TextButton(
                  onPressed: () async {
                    final granted = await OverlayNotifier.canDrawOverlays();
                    final a11yEnabled =
                        await OverlayNotifier.isAccessibilityIslandEnabled();
                    if (!mounted) return;
                    setState(() {
                      _overlayPermGranted = granted;
                      _a11yIslandEnabled = a11yEnabled;
                    });
                    final nextMode = settings.overlayMode == 'off'
                        ? 'island'
                        : settings.overlayMode;
                    final canShow =
                        nextMode == 'island' ? (a11yEnabled || granted) : granted;
                    if (!canShow) {
                      await OverlayNotifier.requestOverlayPermission();
                      return;
                    }
                    if (nextMode != settings.overlayMode) {
                      await settingsCtrl
                          .update(settings.copyWith(overlayMode: nextMode));
                    }
                    await _syncActiveOverlay(forceShow: true, expanded: true);
                  },
                  child: Text(
                    (_overlayPermGranted ||
                            (settings.overlayMode == 'island' &&
                                _a11yIslandEnabled))
                        ? '展开预览'
                        : '去授权',
                  ),
                ),
              ),
            if (settings.overlayMode == 'island' ||
                (OverlayNotifier.isIOS && settings.overlayMode != 'off')) ...[
              Divider(height: 1, color: p.border),
              if (OverlayNotifier.isSupported)
                ListTile(
                  title: Text('贴顶挖孔无障碍模式（推荐）',
                      style: TextStyle(fontSize: 13.5, color: p.text)),
                  subtitle: Text(
                    _a11yIslandEnabled
                        ? '已开启 · 中岛显示在状态栏上方，可直接贴挖孔点击展开'
                        : '未开启 · 开启后可像原生灵动岛一样直接贴顶点击（到无障碍→已下载的应用中启用「VibeHelper 灵动中岛」）',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _a11yIslandEnabled ? p.success : p.muted,
                    ),
                  ),
                  trailing: TextButton(
                    onPressed: () =>
                        unawaited(OverlayNotifier.openAccessibilitySettings()),
                    child: Text(_a11yIslandEnabled ? '已开启' : '去开启'),
                  ),
                ),
              if (OverlayNotifier.isSupported) Divider(height: 1, color: p.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('中岛小宠物形象',
                        style: TextStyle(fontSize: 13.5, color: p.text)),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'shiba', label: Text('像素柴犬')),
                          ButtonSegment(value: 'cat', label: Text('像素黑猫')),
                          ButtonSegment(value: 'bot', label: Text('机器人')),
                        ],
                        selected: {settings.islandPet},
                        onSelectionChanged: (sel) async {
                          final pet = sel.first;
                          await settingsCtrl
                              .update(settings.copyWith(islandPet: pet));
                          await _syncActiveOverlay(forceShow: true);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                title: Text('待审批 / 提问时自动展开中岛',
                    style: TextStyle(fontSize: 13.5, color: p.text)),
                subtitle: Text(
                  settings.islandAutoExpand
                      ? '自动弹出方便直接点允许/拒绝，处理后收起胶囊'
                      : '仅保留顶部胶囊高亮，需手动轻触中岛展开',
                  style: TextStyle(fontSize: 11.5, color: p.muted),
                ),
                value: settings.islandAutoExpand,
                onChanged: (v) async {
                  await settingsCtrl
                      .update(settings.copyWith(islandAutoExpand: v));
                  await _syncActiveOverlay();
                },
              ),
              if (!OverlayNotifier.isIOS) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('中岛左右宽度微调',
                              style: TextStyle(fontSize: 13, color: p.text)),
                          Text('${settings.islandWidth} dp',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: p.accent)),
                        ],
                      ),
                      Slider(
                        value: settings.islandWidth.toDouble().clamp(140, 300),
                        min: 140,
                        max: 300,
                        divisions: 32,
                        onChanged: (v) async {
                          await settingsCtrl.update(
                            settings.copyWith(islandWidth: v.round()),
                          );
                          await _syncActiveOverlay();
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('中岛顶部位置微调（适配挖孔）',
                              style: TextStyle(fontSize: 13, color: p.text)),
                          Text('${settings.islandYOffset} dp',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: p.accent)),
                        ],
                      ),
                      Slider(
                        value: settings.islandYOffset.toDouble().clamp(0, 60),
                        min: 0,
                        max: 60,
                        divisions: 60,
                        onChanged: (v) async {
                          await settingsCtrl.update(
                            settings.copyWith(islandYOffset: v.round()),
                          );
                          await _syncActiveOverlay();
                        },
                      ),
                      Text(
                        _a11yIslandEnabled
                            ? '无障碍模式已开启，可调至 6–12dp 贴合前置挖孔'
                            : '普通悬浮窗建议 24–36dp；开启上方无障碍模式后可贴顶点击',
                        style: TextStyle(fontSize: 11, color: p.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
        const SizedBox(height: 12),

        _settingsSection(
          p: p,
          title: '语音与远程输入',
          children: [
            SwitchListTile(
              title: Text('输入法语音停顿 1.8s 自动发送',
                  style: TextStyle(fontSize: 14, color: p.text)),
              subtitle: Text('用输入法语音键盘说完后，停顿自动注入远程 IDE',
                  style: TextStyle(fontSize: 11.5, color: p.muted)),
              value: settings.imeAutoSendOnPause,
              onChanged: (v) =>
                  settingsCtrl.update(settings.copyWith(imeAutoSendOnPause: v)),
            ),
            Divider(height: 1, color: p.border),
            SwitchListTile(
              title: Text('粘贴后恢复原剪贴板',
                  style: TextStyle(fontSize: 14, color: p.text)),
              value: settings.restoreClipboard,
              onChanged: (v) =>
                  settingsCtrl.update(settings.copyWith(restoreClipboard: v)),
            ),
            Divider(height: 1, color: p.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text('粘贴快捷键策略',
                        style: TextStyle(fontSize: 14, color: p.text)),
                  ),
                  DropdownButton<PasteShortcut>(
                    value: settings.pasteShortcut,
                    dropdownColor: p.panel,
                    underline: const SizedBox.shrink(),
                    style: TextStyle(fontSize: 13, color: p.accent),
                    items: const [
                      DropdownMenuItem(
                        value: PasteShortcut.auto,
                        child: Text('自动适配 (IDE/终端)'),
                      ),
                      DropdownMenuItem(
                        value: PasteShortcut.ctrlV,
                        child: Text('Ctrl + V'),
                      ),
                      DropdownMenuItem(
                        value: PasteShortcut.ctrlShiftV,
                        child: Text('Ctrl + Shift + V'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        settingsCtrl.update(
                          settings.copyWith(pasteShortcut: v),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            SwitchListTile(
              title: Text('本机自定义语音门限 (VAD)',
                  style: TextStyle(fontSize: 14, color: p.text)),
              subtitle: Text(
                settings.vadUseLocalOverride
                    ? '已启用本机参数（即时生效，不被宿主机热更新覆盖）'
                    : '跟随宿主机热补丁 #${hotCfg.hotVersion}（峰值 ${hotCfg.vadPeakThreshold} · RMS ${hotCfg.vadRmsThreshold.round()} · 尾音 ${hotCfg.vadHangoverMs}ms）',
                style: TextStyle(fontSize: 11.5, color: p.muted),
              ),
              value: settings.vadUseLocalOverride,
              onChanged: (v) {
                settingsCtrl.update(
                  v
                      ? settings.copyWith(
                          vadUseLocalOverride: true,
                          vadPeakThreshold: settings.vadPeakThreshold,
                          vadRmsThreshold: settings.vadRmsThreshold,
                          vadHangoverMs: settings.vadHangoverMs,
                        )
                      : settings.copyWith(vadUseLocalOverride: false),
                );
              },
            ),
            if (settings.vadUseLocalOverride) ...[
              Divider(height: 1, color: p.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final (label, peak, rms, hang) in const [
                          ('超灵敏（轻声）', 120, 45, 700),
                          ('标准（推荐）', 220, 75, 600),
                          ('强抗噪（嘈杂）', 520, 180, 450),
                        ])
                          ActionChip(
                            label:
                                Text(label, style: const TextStyle(fontSize: 12)),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: (settings.vadPeakThreshold == peak &&
                                    settings.vadRmsThreshold == rms &&
                                    settings.vadHangoverMs == hang)
                                ? p.accent.withValues(alpha: 0.16)
                                : p.panelAlt,
                            side: BorderSide(
                              color: (settings.vadPeakThreshold == peak &&
                                      settings.vadRmsThreshold == rms &&
                                      settings.vadHangoverMs == hang)
                                  ? p.accent
                                  : p.border,
                            ),
                            onPressed: () {
                              settingsCtrl.update(
                                settings.copyWith(
                                  vadPeakThreshold: peak,
                                  vadRmsThreshold: rms,
                                  vadHangoverMs: hang,
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    for (final (title, valueText, value, minV, maxV, divs, onVal)
                        in [
                      (
                        '峰值门限（越低越灵敏）',
                        '${settings.vadPeakThreshold}',
                        settings.vadPeakThreshold.toDouble().clamp(80.0, 1200.0),
                        80.0,
                        1200.0,
                        112,
                        (double v) => settingsCtrl.update(
                              settings.copyWith(vadPeakThreshold: v.round()),
                            ),
                      ),
                      (
                        'RMS 门限（越低越灵敏）',
                        '${settings.vadRmsThreshold}',
                        settings.vadRmsThreshold.toDouble().clamp(30.0, 500.0),
                        30.0,
                        500.0,
                        94,
                        (double v) => settingsCtrl.update(
                              settings.copyWith(vadRmsThreshold: v.round()),
                            ),
                      ),
                      (
                        '尾音保持（防止吞字）',
                        '${settings.vadHangoverMs} ms',
                        settings.vadHangoverMs.toDouble().clamp(200.0, 1500.0),
                        200.0,
                        1500.0,
                        26,
                        (double v) => settingsCtrl.update(
                              settings.copyWith(vadHangoverMs: v.round()),
                            ),
                      ),
                    ]) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(title,
                              style: TextStyle(fontSize: 13, color: p.text)),
                          Text(
                            valueText,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: p.accent,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: value,
                        min: minV,
                        max: maxV,
                        divisions: divs,
                        onChanged: onVal,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        _settingsSection(
          p: p,
          title: '多主机与关于',
          children: [
            ListTile(
              leading: Icon(Icons.data_usage_rounded, size: 20, color: p.accent),
              title: Text('使用量与剩余额度查询',
                  style: TextStyle(fontSize: 14, color: p.text)),
              subtitle: Text('查看各模型剩余额度、今日轮次与会话估算消耗',
                  style: TextStyle(fontSize: 11.5, color: p.muted)),
              trailing:
                  Icon(Icons.chevron_right_rounded, color: p.muted),
              onTap: () => showUsageQuotaSheet(context, ref),
            ),
            Divider(height: 1, color: p.border),
            ListTile(
              leading: Icon(Icons.dns_rounded, size: 20, color: p.accent),
              title: Text('管理多 Host 与 IDE (CDP)',
                  style: TextStyle(fontSize: 14, color: p.text)),
              trailing:
                  Icon(Icons.chevron_right_rounded, color: p.muted),
              onTap: () => _switchToTab(3),
            ),
            Divider(height: 1, color: p.border),
            Consumer(
              builder: (context, ref, _) {
                final upd = ref.watch(appUpdateProvider);
                final hasReinstall = upd.decision?.isReinstall ?? false;
                return ListTile(
                  leading: Icon(
                    Icons.system_update_rounded,
                    size: 20,
                    color: hasReinstall ? p.warning : p.accent,
                  ),
                  title: Text('应用更新与热补丁',
                      style: TextStyle(fontSize: 14, color: p.text)),
                  subtitle: Text(
                    hasReinstall
                        ? '发现新版 v${upd.decision!.latestVersion}+${upd.decision!.latestBuild} · 需重新安装'
                        : '当前 v${upd.clientVersion}+${upd.clientBuild} · 热补丁 #${upd.hotConfig.hotVersion}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hasReinstall ? p.warning : p.muted,
                    ),
                  ),
                  trailing: upd.checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.chevron_right_rounded, color: p.muted),
                  onTap: () => _openUpdateSheet(p),
                );
              },
            ),
            Divider(height: 1, color: p.border),
            ListTile(
              leading: Icon(Icons.info_outline_rounded, size: 20, color: p.accent),
              title: Text('VibeHelper v${AppBuildInfo.appVersion}',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: p.text)),
              subtitle: Text(
                'Electron CDP 零抢焦 · 双向会话同步 · 热更新与灵动岛协同',
                style: TextStyle(fontSize: 11.5, color: p.muted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _settingsSection({
    required VibePalette p,
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: p.muted,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: p.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _emptyHintCard(VibePalette p, String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, color: p.muted, height: 1.45),
      ),
    );
  }

  Widget _miniTag(VibePalette p, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  void _openUpdateSheet(VibePalette p) {
    unawaited(ref.read(appUpdateProvider.notifier).checkForUpdates());
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Consumer(
        builder: (ctx, sheetRef, _) {
          final upd = sheetRef.watch(appUpdateProvider);
          final ctrl = sheetRef.read(appUpdateProvider.notifier);
          final dec = upd.decision;
          final badgeColor = dec == null
              ? p.accent
              : (dec.isReinstall
                  ? p.warning
                  : (dec.reason == 'hot_updated' || dec.isHotUpdate
                      ? p.success
                      : p.muted));
          final badgeLabel = dec == null
              ? '检查中'
              : (dec.isReinstall
                  ? '系统判定：需要重新安装'
                  : (dec.reason == 'hot_updated' || dec.isHotUpdate
                      ? '系统判定：免重装热更新'
                      : '已是最新状态'));

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.system_update_rounded, size: 20, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '客户端更新中心 (Host 直连)',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                          ),
                        ),
                      ),
                      _miniTag(p, badgeLabel, badgeColor),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: p.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '当前版本：v${upd.clientVersion}+${upd.clientBuild} · 原生代 #${AppBuildInfo.nativeVersion} · 热补丁 #${upd.hotConfig.hotVersion}',
                          style: TextStyle(fontSize: 12, color: p.muted),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '语音门限：峰值 ${upd.hotConfig.vadPeakThreshold} · RMS ${upd.hotConfig.vadRmsThreshold.round()} · 尾音 ${upd.hotConfig.vadHangoverMs}ms',
                          style: TextStyle(fontSize: 11.5, color: p.muted),
                        ),
                        if (upd.statusMessage != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            upd.statusMessage!,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: p.text,
                            ),
                          ),
                        ],
                        if (dec != null && dec.changelog.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '更新说明：${dec.changelog}',
                            style: TextStyle(fontSize: 11.5, color: p.muted),
                          ),
                        ],
                        if (upd.error != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            upd.error!,
                            style: TextStyle(fontSize: 12, color: p.danger),
                          ),
                        ],
                        if (upd.downloading && upd.downloadProgress != null) ...[
                          const SizedBox(height: 10),
                          LinearProgressIndicator(value: upd.downloadProgress),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (dec != null && dec.isReinstall) ...[
                    if (!OverlayNotifier.isIOS)
                      FilledButton.icon(
                        onPressed: upd.downloading
                            ? null
                            : () => unawaited(ctrl.downloadAndInstallAndroidApk()),
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: Text(
                          upd.downloading ? '正在下载安装包...' : '下载并安装新版 APK',
                        ),
                      )
                    else ...[
                      FilledButton.icon(
                        onPressed: () => unawaited(ctrl.openIosAltStoreUpdate()),
                        icon: const Icon(Icons.phone_iphone_rounded, size: 18),
                        label: const Text('通过 AltStore 更新安装 IPA'),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: dec.altstoreSourceUrl.isEmpty
                                  ? null
                                  : () {
                                      Clipboard.setData(
                                        ClipboardData(text: dec.altstoreSourceUrl),
                                      );
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('已复制 AltStore 源地址'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    },
                              icon: const Icon(Icons.copy_rounded, size: 16),
                              label: const Text('复制 AltStore 源'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: dec.downloadUrl.isEmpty
                                  ? null
                                  : () => unawaited(ctrl.openDirectPackageUrl()),
                              icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                              label: const Text('下载 IPA'),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                  OutlinedButton.icon(
                    onPressed: upd.checking
                        ? null
                        : () => unawaited(ctrl.checkForUpdates()),
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: Text(upd.checking ? '正在检查...' : '重新检查更新'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom 4-Tab Navigation Bar
  // ---------------------------------------------------------------------------

  Widget _buildBottomNavBar(VibePalette p) {
    Widget navItem(int idx, IconData icon, IconData activeIcon, String label) {
      final active = _tabIndex == idx;
      final color = active ? (p.isDark ? p.accent : p.text) : p.muted;
      return Expanded(
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            _switchToTab(idx);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(active ? activeIcon : icon, size: 22, color: color),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: p.isDark ? 0.98 : 0.94),
        border: Border(top: BorderSide(color: p.border.withValues(alpha: 0.8))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            navItem(0, Icons.chat_bubble_outline_rounded,
                Icons.chat_bubble_rounded, '对话'),
            navItem(1, Icons.desktop_windows_outlined,
                Icons.desktop_windows_rounded, '控屏'),
            navItem(2, Icons.terminal_outlined, Icons.terminal_rounded, '终端'),
            navItem(3, Icons.dns_outlined, Icons.dns_rounded, '主机'),
            navItem(4, Icons.person_outline_rounded, Icons.person_rounded, '我的'),
          ],
        ),
      ),
    );
  }
}
