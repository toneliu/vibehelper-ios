import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/theme.dart';
import '../../core/vibe_socket_client.dart';
import '../reader/window_content_controller.dart';
import 'connection_controller.dart';

/// Multi-Host Manager bottom sheet / dialog: allows adding, editing, deleting,
/// and 1-tap switching between multiple Windows/Linux Hosts.
class HostManagerSheet extends ConsumerStatefulWidget {
  const HostManagerSheet({super.key, this.onHostSwitched});

  final VoidCallback? onHostSwitched;

  static Future<void> show(
    BuildContext context, {
    VoidCallback? onHostSwitched,
  }) {
    final pal = VibeTheme.paletteOf(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: pal.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => HostManagerSheet(onHostSwitched: onHostSwitched),
    );
  }

  @override
  ConsumerState<HostManagerSheet> createState() => _HostManagerSheetState();
}

class _HostManagerSheetState extends ConsumerState<HostManagerSheet> {
  Future<void> _switchToHost(HostProfile profile) async {
    await ref.read(settingsProvider.notifier).selectHostProfile(profile.id);
    if (!mounted) return;
    Navigator.of(context).pop();
    await ref.read(hostActionProvider).connectFromSettings();
    widget.onHostSwitched?.call();
    // Auto-refresh conversations on the newly connected host
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        unawaited(
          ref
              .read(windowContentProvider.notifier)
              .fetchContent(resetSession: true),
        );
      }
    });
  }

  Future<void> _showEditHostDialog({HostProfile? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(
      text: existing?.wsUrl ?? '192.168.1.',
    );
    final tokenCtrl = TextEditingController(text: existing?.token ?? '');

    final saved = await showDialog<HostProfile>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '添加被控端 (Host)' : '编辑被控端'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '主机名称',
                  hintText: '例如：家里 Win11 / Linux 服务器',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: '地址 (支持直接填 IP 或 IP:端口)',
                  hintText: '192.168.110.125:8765 或 ws://...',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tokenCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '鉴权 Token (可选)',
                  hintText: '未设置可留空',
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
              final rawUrl = urlCtrl.text.trim();
              if (rawUrl.isEmpty) return;
              final normalized = normalizeWsUrl(rawUrl);
              final label = nameCtrl.text.trim().isEmpty
                  ? inferHostLabel(normalized)
                  : nameCtrl.text.trim();
              Navigator.of(ctx).pop(
                HostProfile(
                  id: existing?.id ??
                      'host-${DateTime.now().millisecondsSinceEpoch}',
                  name: label,
                  wsUrl: normalized,
                  token: tokenCtrl.text.trim(),
                ),
              );
            },
            child: const Text('保存并连接'),
          ),
        ],
      ),
    );

    nameCtrl.dispose();
    urlCtrl.dispose();
    tokenCtrl.dispose();

    if (saved != null && mounted) {
      await ref
          .read(settingsProvider.notifier)
          .upsertHostProfile(saved, select: true);
      if (!mounted) return;
      Navigator.of(context).pop();
      await ref.read(hostActionProvider).connectFromSettings();
      widget.onHostSwitched?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = VibeTheme.paletteOf(context);
    final settings = ref.watch(settingsProvider);
    final settingsCtrl = ref.read(settingsProvider.notifier);
    final connSnap =
        ref.watch(socketSnapshotProvider).valueOrNull ?? const SocketSnapshot();
    final profiles = settings.hostProfiles;
    final canDelete = profiles.length > 1;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          14,
          14,
          14,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.dns_rounded, size: 20, color: pal.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '多被控端 (Host) 管理与切换',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: pal.text,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _showEditHostDialog(),
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text('新增 Host'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '轻触任意主机即可一键切换连接（自动同步该主机的窗口与 Agent 会话）',
              style: TextStyle(fontSize: 11.5, color: pal.muted),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.52,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: profiles.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (ctx, idx) {
                  final p = profiles[idx];
                  final isSelected = p.id == settings.activeHostId;
                  final isLive = isSelected && connSnap.isConnected;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _switchToHost(p),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? pal.accent.withValues(alpha: 0.14)
                            : pal.panel,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isLive
                              ? pal.success
                              : (isSelected ? pal.accent : pal.border),
                          width: isSelected ? 1.4 : 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: isLive
                                  ? pal.success
                                  : (isSelected ? pal.accent : pal.muted),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        p.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: pal.text,
                                        ),
                                      ),
                                    ),
                                    if (isLive) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: pal.success
                                              .withValues(alpha: 0.18),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '已连接${connSnap.rttMs != null ? ' ${connSnap.rttMs}ms' : ''}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: pal.success,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  p.wsUrl,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: pal.muted,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '编辑主机',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.edit_outlined,
                                size: 18, color: pal.muted),
                            onPressed: () => _showEditHostDialog(existing: p),
                          ),
                          if (canDelete)
                            IconButton(
                              tooltip: '删除主机',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.delete_outline_rounded,
                                  size: 18, color: pal.danger),
                              onPressed: () =>
                                  settingsCtrl.deleteHostProfile(p.id),
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
      ),
    );
  }
}
