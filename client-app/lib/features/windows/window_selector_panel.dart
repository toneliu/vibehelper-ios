import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../protocol/messages.dart';
import '../connection/connection_controller.dart';
import 'window_controller.dart';

class WindowSelectorPanel extends ConsumerWidget {
  const WindowSelectorPanel({
    super.key,
    this.onWindowPicked,
  });

  /// Optional callback (used on mobile bottom sheet to auto-close after picking).
  final VoidCallback? onWindowPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VibeTheme.paletteOf(context);
    final winState = ref.watch(windowControllerProvider);
    final winCtrl = ref.read(windowControllerProvider.notifier);
    final connSnap = ref.watch(socketSnapshotProvider).valueOrNull;
    final connected = connSnap?.isConnected ?? false;

    return Card(
      color: p.panel,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.desktop_windows_rounded, size: 18, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '目标窗口锁定',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: p.text,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新窗口列表',
                  onPressed: connected ? winCtrl.refresh : null,
                  icon: winState.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.refresh_rounded, size: 18, color: p.text),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              onChanged: winCtrl.setSearchQuery,
              style: TextStyle(color: p.text, fontSize: 13.5),
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, size: 18, color: p.muted),
                hintText: '搜索 Antigravity / ChatGPT / Claude / VS Code / 终端...',
                hintStyle: TextStyle(color: p.muted),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      winCtrl.selectWindow(null);
                      onWindowPicked?.call();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: winState.selectedWindowId == null
                            ? p.success.withValues(alpha: 0.14)
                            : p.panelAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: winState.selectedWindowId == null
                              ? p.success
                              : p.border,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.center_focus_weak_rounded,
                            size: 15,
                            color: winState.selectedWindowId == null
                                ? p.success
                                : p.muted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '跟随当前焦点窗口（Wayland 兜底）',
                              style: TextStyle(fontSize: 12, color: p.text),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text('含最小化',
                      style: TextStyle(fontSize: 11, color: p.text)),
                  selected: winState.includeMinimized,
                  onSelected: connected
                      ? (v) => winCtrl.setIncludeMinimized(v)
                      : null,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (winState.error != null) ...[
              const SizedBox(height: 8),
              Text(
                winState.error!,
                style: TextStyle(color: p.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: !connected
                  ? Center(
                      child: Text(
                        '连接被控端后自动拉取活跃窗口列表',
                        style: TextStyle(color: p.muted, fontSize: 13),
                      ),
                    )
                  : winState.filteredWindows.isEmpty
                      ? Center(
                          child: Text(
                            '暂无匹配窗口',
                            style: TextStyle(color: p.muted, fontSize: 13),
                          ),
                        )
                      : ListView.separated(
                          itemCount: winState.filteredWindows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 6),
                          itemBuilder: (context, idx) {
                            final win = winState.filteredWindows[idx];
                            final selected =
                                win.id == winState.selectedWindowId;
                            return _WindowTile(
                              window: win,
                              selected: selected,
                              onTap: () {
                                winCtrl.selectWindow(win.id);
                                onWindowPicked?.call();
                              },
                              onFocus: () => winCtrl.focusWindow(win.id),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowTile extends StatelessWidget {
  const _WindowTile({
    required this.window,
    required this.selected,
    required this.onTap,
    required this.onFocus,
  });

  final WindowInfo window;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final boundsText = window.bounds != null
        ? '${window.bounds!.width}×${window.bounds!.height}'
        : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? p.success.withValues(alpha: 0.12) : p.panelAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? p.success : p.border,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    window.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _Badge(label: window.app, color: p.accent),
                      if (window.isTerminal)
                        _Badge(label: 'Terminal', color: p.warning),
                      if (window.isActive)
                        _Badge(label: 'Active', color: p.success),
                      if (boundsText != null)
                        Text(
                          boundsText,
                          style: TextStyle(fontSize: 11, color: p.muted),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: '激活并置顶此窗口',
              onPressed: onFocus,
              icon: Icon(Icons.open_in_new_rounded, size: 17, color: p.muted),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
