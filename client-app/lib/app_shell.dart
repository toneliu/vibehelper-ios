import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'core/vibe_socket_client.dart';
import 'features/connection/connection_controller.dart';
import 'features/connection/connection_dialog.dart';
import 'features/mobile/mobile_vibe_page.dart';
import 'features/reader/window_content_panel.dart';
import 'features/voice/voice_console_panel.dart';
import 'features/windows/window_selector_panel.dart';

class VibeHelperShell extends ConsumerStatefulWidget {
  const VibeHelperShell({super.key});

  @override
  ConsumerState<VibeHelperShell> createState() => _VibeHelperShellState();
}

class _VibeHelperShellState extends ConsumerState<VibeHelperShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(hostActionProvider).autoConnectOnStartup());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(hostActionProvider).reconnectOnResume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 860) {
          // Android / Mobile: ultra-clean, chat-first minimalist Vibe Coding console
          return const MobileVibePage();
        }
        return const _DesktopWorkbench();
      },
    );
  }
}

class _DesktopWorkbench extends ConsumerWidget {
  const _DesktopWorkbench();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connSnap =
        ref.watch(socketSnapshotProvider).valueOrNull ?? const SocketSnapshot();
    final actions = ref.read(hostActionProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: VibeTheme.panel,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 14,
        title: Row(
          children: [
            const Text(
              'VibeHelper',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            const SizedBox(width: 8),
            _StatusChip(snapshot: connSnap),
            if (connSnap.hostInfo != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${connSnap.hostInfo!.os}/${connSnap.hostInfo!.displayServer}',
                  style: const TextStyle(fontSize: 12, color: VibeTheme.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (connSnap.rttMs != null) ...[
              const SizedBox(width: 8),
              Text(
                '${connSnap.rttMs}ms',
                style: const TextStyle(
                  fontSize: 12,
                  color: VibeTheme.success,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (connSnap.isConnected)
            TextButton.icon(
              onPressed: actions.disconnect,
              icon: const Icon(Icons.link_off_rounded, size: 17),
              label: const Text('断开'),
            )
          else
            FilledButton.icon(
              onPressed: actions.connectFromSettings,
              icon: const Icon(Icons.link_rounded, size: 17),
              label: const Text('连接'),
            ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '连接与语音设置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (_) => const SettingsDialog(),
              );
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          if (connSnap.lastError != null && !connSnap.isConnected)
            Container(
              width: double.infinity,
              color: VibeTheme.danger.withOpacity(0.15),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                connSnap.lastError!,
                style: const TextStyle(color: VibeTheme.danger, fontSize: 12.5),
              ),
            ),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 300, child: WindowSelectorPanel()),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(flex: 6, child: UnifiedViewerPanel()),
                        SizedBox(height: 12),
                        Expanded(flex: 5, child: VoiceConsolePanel()),
                      ],
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
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.snapshot});

  final SocketSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (snapshot.phase) {
      ConnectionPhase.connected => ('已连接', VibeTheme.success),
      ConnectionPhase.connecting => ('连接中', VibeTheme.warning),
      ConnectionPhase.authenticating => ('鉴权中', VibeTheme.warning),
      ConnectionPhase.reconnecting => ('重连中', VibeTheme.warning),
      ConnectionPhase.error => ('错误', VibeTheme.danger),
      ConnectionPhase.disconnected => ('未连接', VibeTheme.muted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
