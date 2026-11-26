import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/theme.dart';
import '../../protocol/messages.dart';
import 'connection_controller.dart';
import 'host_manager_sheet.dart';

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  late final TextEditingController _wsUrlCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _clientNameCtrl;

  late VoiceInputEngine _voiceEngine;
  late bool _imeAutoSendOnPause;
  late String _sttLocale;
  late bool _autoEnter;
  late PasteShortcut _pasteShortcut;
  late bool _restoreClipboard;
  late DesktopHotkeyPreset _desktopHotkey;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _wsUrlCtrl = TextEditingController(text: s.wsUrl);
    _tokenCtrl = TextEditingController(text: s.token);
    _clientNameCtrl = TextEditingController(text: s.clientName);
    _voiceEngine = s.voiceEngine;
    _imeAutoSendOnPause = s.imeAutoSendOnPause;
    _sttLocale = s.sttLocale;
    _autoEnter = s.autoEnter;
    _pasteShortcut = s.pasteShortcut;
    _restoreClipboard = s.restoreClipboard;
    _desktopHotkey = s.desktopHotkey;
  }

  @override
  void dispose() {
    _wsUrlCtrl.dispose();
    _tokenCtrl.dispose();
    _clientNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save({required bool reconnect}) async {
    final prev = ref.read(settingsProvider);
    final updated = prev.copyWith(
      wsUrl: _wsUrlCtrl.text.trim(),
      token: _tokenCtrl.text.trim(),
      clientName: _clientNameCtrl.text.trim().isEmpty
          ? prev.clientName
          : _clientNameCtrl.text.trim(),
      voiceEngine: _voiceEngine,
      imeAutoSendOnPause: _imeAutoSendOnPause,
      sttLocale: _sttLocale,
      autoEnter: _autoEnter,
      pasteShortcut: _pasteShortcut,
      restoreClipboard: _restoreClipboard,
      desktopHotkey: _desktopHotkey,
    );
    await ref.read(settingsProvider.notifier).update(updated);
    if (reconnect) {
      await ref.read(hostActionProvider).connectFromSettings();
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isWindows = !kIsWeb && Platform.isWindows;

    return AlertDialog(
      backgroundColor: VibeTheme.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: VibeTheme.border),
      ),
      title: const Text('连接与语音设置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: _sectionTitle('被控端连接')),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      HostManagerSheet.show(context);
                    },
                    icon: const Icon(Icons.dns_rounded, size: 15),
                    label: const Text('多 Host 管理/切换',
                        style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _wsUrlCtrl,
                decoration: const InputDecoration(
                  labelText: 'WebSocket 地址',
                  hintText: 'ws://192.168.199.10:8765/ws',
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _tokenCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '访问 Token（可选）',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _clientNameCtrl,
                      decoration: const InputDecoration(
                        labelText: '设备名称',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionTitle('语音输入方式'),
              const SizedBox(height: 8),
              DropdownButtonFormField<VoiceInputEngine>(
                value: _voiceEngine,
                decoration: const InputDecoration(labelText: '输入引擎'),
                items: VoiceInputEngine.values
                    .map((e) => DropdownMenuItem(value: e, child: Text(e.label)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _voiceEngine = v);
                },
              ),
              if (_voiceEngine == VoiceInputEngine.imeDirect) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('语音停顿自动注入（1.8 秒）'),
                  subtitle: const Text('用微信/豆包/讯飞输入法语音说完停顿后自动远程粘贴'),
                  value: _imeAutoSendOnPause,
                  onChanged: (v) => setState(() => _imeAutoSendOnPause = v),
                ),
              ] else ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _sttLocale,
                  decoration: const InputDecoration(labelText: '原生识别语言'),
                  items: const [
                    DropdownMenuItem(value: 'zh_CN', child: Text('中文（zh_CN）')),
                    DropdownMenuItem(
                        value: 'en_US', child: Text('English（en_US）')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _sttLocale = v);
                  },
                ),
              ],
              if (isWindows) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<DesktopHotkeyPreset>(
                  value: _desktopHotkey,
                  decoration: const InputDecoration(
                    labelText: 'Windows 全局语音热键',
                  ),
                  items: DesktopHotkeyPreset.values
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text(e.label)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _desktopHotkey = v);
                  },
                ),
              ],
              const SizedBox(height: 16),
              _sectionTitle('文本安全注入策略'),
              const SizedBox(height: 8),
              DropdownButtonFormField<PasteShortcut>(
                value: _pasteShortcut,
                decoration: const InputDecoration(labelText: '粘贴快捷键'),
                items: const [
                  DropdownMenuItem(
                    value: PasteShortcut.auto,
                    child: Text('auto（自动识别 GUI / 终端）'),
                  ),
                  DropdownMenuItem(
                    value: PasteShortcut.ctrlV,
                    child: Text('ctrl_v（强制 Ctrl+V）'),
                  ),
                  DropdownMenuItem(
                    value: PasteShortcut.ctrlShiftV,
                    child: Text('ctrl_shift_v（强制 Ctrl+Shift+V）'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _pasteShortcut = v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('粘贴后自动发送 Enter'),
                subtitle: const Text('适合 AI 对话框 / 终端直接提交'),
                value: _autoEnter,
                onChanged: (v) => setState(() => _autoEnter = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('粘贴后恢复原剪贴板'),
                value: _restoreClipboard,
                onChanged: (v) => setState(() => _restoreClipboard = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        OutlinedButton(
          onPressed: () => _save(reconnect: false),
          child: const Text('仅保存'),
        ),
        FilledButton(
          onPressed: () => _save(reconnect: true),
          child: const Text('保存并连接'),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: VibeTheme.accent,
      ),
    );
  }
}
