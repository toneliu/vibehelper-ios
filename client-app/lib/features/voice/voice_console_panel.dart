import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/theme.dart';
import '../connection/connection_controller.dart';
import '../stream/webrtc_stream_controller.dart';
import '../windows/window_controller.dart';
import 'voice_controller.dart';

class VoiceConsolePanel extends ConsumerStatefulWidget {
  const VoiceConsolePanel({super.key});

  @override
  ConsumerState<VoiceConsolePanel> createState() => _VoiceConsolePanelState();
}

class _VoiceConsolePanelState extends ConsumerState<VoiceConsolePanel> {
  final TextEditingController _promptCtrl = TextEditingController();
  final FocusNode _promptFocus = FocusNode();
  Timer? _pauseSendTimer;
  bool _slideCancelling = false;
  bool _uploadingFile = false;

  Future<void> _pickAndUploadFile() async {
    if (_uploadingFile) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final path = f.path;
    if (path == null || path.isEmpty) return;
    setState(() => _uploadingFile = true);
    try {
      final winState = ref.read(windowControllerProvider);
      final res = await ref.read(hostActionProvider).uploadFileToDialog(
            filePath: path,
            filename: f.name,
            targetWindowId: winState.selectedWindowId,
            autoPaste: true,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            res.ok
                ? '已将${res.kind == 'image' ? '图片' : '文件'}「${res.filename}」粘贴到目标窗口'
                : (res.message ?? '上传粘贴失败'),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) setState(() => _uploadingFile = false);
    }
  }

  @override
  void dispose() {
    _pauseSendTimer?.cancel();
    _promptCtrl.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  Future<void> _sendPromptText({String source = 'manual'}) async {
    _pauseSendTimer?.cancel();
    final text = _promptCtrl.text.trim();
    if (text.isEmpty) return;
    final winState = ref.read(windowControllerProvider);
    final selected = winState.selectedWindow;
    final res = await ref.read(hostActionProvider).injectText(
          text: text,
          targetWindowId: winState.selectedWindowId,
          targetWindowTitle:
              selected != null ? '[${selected.app}] ${selected.title}' : '当前焦点窗口',
          source: source,
        );
    if (res != null && res.ok && mounted) {
      _promptCtrl.clear();
    }
  }

  void _onImeTextChanged(String value, AppSettings settings, bool connected) {
    _pauseSendTimer?.cancel();
    if (!connected ||
        settings.voiceEngine != VoiceInputEngine.imeDirect ||
        !settings.imeAutoSendOnPause) {
      return;
    }
    if (value.trim().isEmpty) return;
    _pauseSendTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted && _promptCtrl.text.trim().isNotEmpty) {
        unawaited(_sendPromptText(source: 'stt_final'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final voiceState = ref.watch(voiceControllerProvider);
    final voiceCtrl = ref.read(voiceControllerProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final settingsCtrl = ref.read(settingsProvider.notifier);
    final winState = ref.watch(windowControllerProvider);
    final history = ref.watch(injectionHistoryProvider);
    final streamState = ref.watch(remoteStreamProvider);
    final streamCtrl = ref.read(remoteStreamProvider.notifier);
    final connSnap = ref.watch(socketSnapshotProvider).valueOrNull;
    final connected = connSnap?.isConnected ?? false;

    ref.listen<String>(
      voiceControllerProvider.select((s) => s.liveTranscript),
      (_, next) {
        if (next.isNotEmpty && _promptCtrl.text != next) {
          _promptCtrl.value = TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: next.length),
          );
        }
      },
    );

    final isWindows = !kIsWeb && Platform.isWindows;
    final isImeMode = settings.voiceEngine == VoiceInputEngine.imeDirect;
    final targetLabel = winState.selectedWindow != null
        ? '[${winState.selectedWindow!.app}] ${winState.selectedWindow!.title}'
        : '当前焦点窗口（未固定 ID）';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.my_location_rounded,
                        size: 15, color: VibeTheme.success),
                    const SizedBox(width: 5),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(
                        targetLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                SegmentedButton<VoiceInputEngine>(
                  segments: const [
                    ButtonSegment(
                      value: VoiceInputEngine.imeDirect,
                      label: Text('输入法语音'),
                    ),
                    ButtonSegment(
                      value: VoiceInputEngine.nativeStt,
                      label: Text('原生STT'),
                    ),
                  ],
                  selected: {settings.voiceEngine},
                  onSelectionChanged: (sel) {
                    if (sel.isNotEmpty) {
                      settingsCtrl
                          .update(settings.copyWith(voiceEngine: sel.first));
                    }
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Editable prompt box (supports Xiaomi / WeChat / Doubao / iFlytek IME voice key + Enter-to-send!)
            TextField(
              controller: _promptCtrl,
              focusNode: _promptFocus,
              maxLines: 3,
              minLines: 2,
              textInputAction: TextInputAction.send,
              onChanged: (v) => _onImeTextChanged(v, settings, connected),
              onSubmitted: (_) {
                if (connected) unawaited(_sendPromptText(source: 'stt_final'));
              },
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: isImeMode
                    ? '点此呼出小米/微信/豆包输入法语音键说话，点键盘「发送」即刻无损注入...'
                    : '语音转写文本实时显示在此，也可手动编辑补发...',
                suffixIcon: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '清空',
                      icon: const Icon(Icons.clear_rounded, size: 17),
                      onPressed: () => _promptCtrl.clear(),
                    ),
                    IconButton(
                      tooltip: '立即注入',
                      icon: const Icon(Icons.send_rounded,
                          size: 18, color: VibeTheme.accent),
                      onPressed: connected ? () => _sendPromptText() : null,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Quick toggles + Virtual Mic + Control keys
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: const Text('自动回车', style: TextStyle(fontSize: 11.5)),
                  selected: settings.autoEnter,
                  onSelected: (v) =>
                      settingsCtrl.update(settings.copyWith(autoEnter: v)),
                  visualDensity: VisualDensity.compact,
                ),
                if (isImeMode)
                  FilterChip(
                    label:
                        const Text('停顿自动发', style: TextStyle(fontSize: 11.5)),
                    selected: settings.imeAutoSendOnPause,
                    onSelected: (v) => settingsCtrl
                        .update(settings.copyWith(imeAutoSendOnPause: v)),
                    visualDensity: VisualDensity.compact,
                  ),
                ActionChip(
                  avatar: Icon(
                    streamState.audioBridgeActive
                        ? Icons.settings_voice_rounded
                        : Icons.mic_external_on_rounded,
                    size: 15,
                    color: streamState.audioBridgeActive
                        ? VibeTheme.danger
                        : VibeTheme.accent,
                  ),
                  label: Text(
                    streamState.audioBridgeActive ? '虚拟麦:开' : '虚拟麦',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  onPressed: connected ? streamCtrl.toggleAudioBridge : null,
                  visualDensity: VisualDensity.compact,
                ),
                ActionChip(
                  avatar: const Icon(Icons.attach_file_rounded,
                      size: 15, color: VibeTheme.accent),
                  label: Text(
                    _uploadingFile ? '上传中...' : '传图/文件',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  onPressed:
                      (connected && !_uploadingFile) ? _pickAndUploadFile : null,
                  visualDensity: VisualDensity.compact,
                ),
                ..._quickControlButtons(connected, winState.selectedWindowId),
              ],
            ),
            const SizedBox(height: 8),

            // Primary action bar: IME direct send OR Native STT PTT
            if (isImeMode)
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton.icon(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        _promptFocus.requestFocus();
                      },
                      icon: const Icon(Icons.keyboard_voice_rounded, size: 20),
                      label: const Text('呼出输入法语音'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        backgroundColor: VibeTheme.panelAlt,
                        foregroundColor: VibeTheme.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: FilledButton.icon(
                      onPressed: connected
                          ? () {
                              HapticFeedback.mediumImpact();
                              _sendPromptText(source: 'stt_final');
                            }
                          : null,
                      icon: const Icon(Icons.send_rounded, size: 19),
                      label: const Text('无损注入目标窗口'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              )
            else
              _buildNativePttArea(
                voiceState: voiceState,
                voiceCtrl: voiceCtrl,
                settings: settings,
                settingsCtrl: settingsCtrl,
                connected: connected,
                isWindows: isWindows,
              ),

            const SizedBox(height: 8),
            Row(
              children: [
                const Text(
                  '最近注入记录',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: VibeTheme.muted),
                ),
                const Spacer(),
                if (history.isNotEmpty)
                  TextButton(
                    onPressed: () =>
                        ref.read(injectionHistoryProvider.notifier).clear(),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: const Text('清空', style: TextStyle(fontSize: 11.5)),
                  ),
              ],
            ),
            Expanded(
              child: history.isEmpty
                  ? const Center(
                      child: Text(
                        '锁定目标窗口后即可通过输入法语音或虚拟麦开始远程编程',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: VibeTheme.muted, fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      itemCount: history.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 5),
                      itemBuilder: (context, idx) {
                        final rec = history[idx];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 6),
                          decoration: BoxDecoration(
                            color: VibeTheme.panelAlt,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: rec.ok
                                  ? VibeTheme.border
                                  : VibeTheme.danger.withOpacity(0.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                rec.ok
                                    ? Icons.check_circle_rounded
                                    : Icons.error_outline_rounded,
                                size: 15,
                                color: rec.ok
                                    ? VibeTheme.success
                                    : VibeTheme.danger,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      rec.text,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      rec.ok
                                          ? '${rec.shortcutUsed ?? 'ctrl_v'} · ${rec.elapsedMs ?? 0}ms'
                                          : (rec.errorMessage ?? '失败'),
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: rec.ok
                                            ? VibeTheme.muted
                                            : VibeTheme.danger,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: '重发',
                                icon:
                                    const Icon(Icons.replay_rounded, size: 15),
                                visualDensity: VisualDensity.compact,
                                onPressed: connected
                                    ? () {
                                        _promptCtrl.text = rec.text;
                                        _sendPromptText();
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _quickControlButtons(bool connected, String? targetWindowId) {
    final actions = ref.read(hostActionProvider);
    Widget btn(String label, String key, [List<String> mods = const []]) {
      return OutlinedButton(
        onPressed: connected
            ? () => actions.sendControlKey(
                  key: key,
                  modifiers: mods,
                  targetWindowId: targetWindowId,
                )
            : null,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          minimumSize: const Size(0, 30),
          side: const BorderSide(color: VibeTheme.border),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11.5)),
      );
    }

    return [
      btn('Enter', 'Enter'),
      btn('⌫', 'Backspace'),
      btn('Esc', 'Escape'),
      btn('Ctrl+Z', 'z', const ['ctrl']),
      btn('Ctrl+C', 'c', const ['ctrl']),
    ];
  }

  Widget _buildNativePttArea({
    required VoiceState voiceState,
    required VoiceController voiceCtrl,
    required AppSettings settings,
    required SettingsNotifier settingsCtrl,
    required bool connected,
    required bool isWindows,
  }) {
    final isListening = voiceState.phase == VoicePhase.listening;
    final bgColor = !connected
        ? VibeTheme.panelAlt
        : (_slideCancelling
            ? VibeTheme.warning
            : (isListening ? VibeTheme.danger : VibeTheme.accent));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onLongPressStart: !connected
              ? null
              : (_) {
                  HapticFeedback.mediumImpact();
                  setState(() => _slideCancelling = false);
                  voiceCtrl.startCapture(continuous: false);
                },
          onLongPressMoveUpdate: !connected
              ? null
              : (details) {
                  final cancel = details.localOffsetFromOrigin.dy < -55;
                  if (cancel != _slideCancelling) {
                    setState(() => _slideCancelling = cancel);
                  }
                },
          onLongPressEnd: !connected
              ? null
              : (_) {
                  final cancel = _slideCancelling;
                  setState(() => _slideCancelling = false);
                  if (cancel) {
                    voiceCtrl.cancelCapture();
                  } else {
                    voiceCtrl.stopCaptureAndInject();
                  }
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
                  size: 22,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    !connected
                        ? '请先连接被控端'
                        : (_slideCancelling
                            ? '松开取消'
                            : (isListening ? '正在聆听（松开注入，上滑取消）' : '按住说话（系统原生识别）')),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                voiceState.statusHint,
                style: TextStyle(
                  fontSize: 11.5,
                  color: voiceState.phase == VoicePhase.error
                      ? VibeTheme.danger
                      : VibeTheme.muted,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (voiceState.phase == VoicePhase.error)
              TextButton(
                onPressed: () => settingsCtrl.update(
                  settings.copyWith(voiceEngine: VoiceInputEngine.imeDirect),
                ),
                child: const Text('切输入法语音', style: TextStyle(fontSize: 11.5)),
              ),
          ],
        ),
      ],
    );
  }
}
