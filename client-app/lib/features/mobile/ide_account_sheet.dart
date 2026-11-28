import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../connection/connection_controller.dart';

/// Opens a bottom sheet for viewing, saving, switching, renaming, and deleting
/// saved IDE account snapshots (e.g. Antigravity) on the connected Host.
Future<void> showIdeAccountSheet(
  BuildContext context,
  WidgetRef ref, {
  String ideId = 'antigravity',
  String ideName = 'Antigravity',
  VoidCallback? onAccountsChanged,
  VoidCallback? onSwitchedAccount,
  VoidCallback? onOpenRemoteScreen,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _IdeAccountSheetBody(
      hostActions: ref.read(hostActionProvider),
      ideId: ideId,
      ideName: ideName,
      onAccountsChanged: onAccountsChanged,
      onSwitchedAccount: onSwitchedAccount,
      onOpenRemoteScreen: () {
        Navigator.of(ctx).pop();
        onOpenRemoteScreen?.call();
      },
    ),
  );
}

class _IdeAccountSheetBody extends StatefulWidget {
  const _IdeAccountSheetBody({
    required this.hostActions,
    required this.ideId,
    required this.ideName,
    this.onAccountsChanged,
    this.onSwitchedAccount,
    this.onOpenRemoteScreen,
  });

  final HostActionController hostActions;
  final String ideId;
  final String ideName;
  final VoidCallback? onAccountsChanged;
  final VoidCallback? onSwitchedAccount;
  final VoidCallback? onOpenRemoteScreen;

  @override
  State<_IdeAccountSheetBody> createState() => _IdeAccountSheetBodyState();
}

class _IdeAccountSheetBodyState extends State<_IdeAccountSheetBody> {
  IdeAccountsSnapshot? _snapshot;
  bool _loading = true;
  bool _busy = false;
  String? _statusMsg;
  bool _statusIsError = false;
  bool _awaitingNewLogin = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    final snap = await widget.hostActions.fetchIdeAccounts(ideId: widget.ideId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (snap != null) {
        _snapshot = snap;
      } else {
        _statusMsg = '获取账号列表失败，请确认宿主机连接正常';
        _statusIsError = true;
      }
    });
  }

  Future<String?> _promptText({
    required String title,
    required String label,
    required String initialValue,
    required String confirmText,
    String? helperText,
  }) async {
    final ctrl = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: label,
            helperText: helperText,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _saveCurrent({IdeAccountItem? overwriteTarget}) async {
    if (_busy) return;
    final snap = _snapshot;
    final initial = overwriteTarget?.label ??
        ((snap?.activeAccountLabel.isNotEmpty ?? false)
            ? snap!.activeAccountLabel
            : (snap?.currentUsername ?? ''));
    final label = await _promptText(
      title: overwriteTarget != null
          ? '更新账号快照「${overwriteTarget.label}」'
          : '保存当前 ${widget.ideName} 账号',
      label: '账号别名（留空则使用当前登录邮箱）',
      initialValue: initial,
      confirmText: '保存快照',
      helperText: (snap?.currentUsername.isNotEmpty ?? false)
          ? '当前检测到登录邮箱: ${snap!.currentUsername}'
          : null,
    );
    if (label == null || !mounted) return;

    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    final (ok, msg) = await widget.hostActions.saveIdeAccount(
      ideId: widget.ideId,
      label: label,
      accountId: overwriteTarget?.id,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusMsg = msg;
      _statusIsError = !ok;
      if (ok) _awaitingNewLogin = false;
    });
    if (ok) {
      widget.onAccountsChanged?.call();
      await _refresh();
    }
  }

  Future<void> _switchTo(IdeAccountItem item) async {
    if (_busy) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _statusMsg = '正在关闭 ${widget.ideName}、切换至「${item.label}」并重启...';
      _statusIsError = false;
      _awaitingNewLogin = false;
    });
    final (ok, msg) = await widget.hostActions.switchIdeAccount(
      ideId: widget.ideId,
      accountId: item.id,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusMsg = msg;
      _statusIsError = !ok;
    });
    if (ok) {
      widget.onSwitchedAccount?.call();
    } else {
      widget.onAccountsChanged?.call();
    }
    await _refresh();
  }

  Future<void> _prepareNewLogin() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增账号（退出并重新登录）'),
        content: Text(
          '将会：\n'
          '1. 自动关闭 ${widget.ideName} 并备份当前账号凭据与登录态；\n'
          '2. 清空当前登录态后重启 ${widget.ideName}（保留全部对话历史与项目）；\n'
          '3. 你可以在电脑端或通过手机「控屏」完成新账号登录，再回来点「保存当前账号」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续重登'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _statusMsg = '正在备份原账号并重启 ${widget.ideName} 进入登录界面...';
      _statusIsError = false;
    });
    final (ok, msg) = await widget.hostActions.prepareIdeAccountLogin(
      ideId: widget.ideId,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusMsg = msg;
      _statusIsError = !ok;
      _awaitingNewLogin = ok;
    });
    widget.onAccountsChanged?.call();
    await _refresh();
  }

  Future<void> _rename(IdeAccountItem item) async {
    if (_busy) return;
    final nextLabel = await _promptText(
      title: '重命名账号',
      label: '新别名',
      initialValue: item.label,
      confirmText: '保存',
    );
    if (nextLabel == null || nextLabel.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final (ok, msg) = await widget.hostActions.renameIdeAccount(
      ideId: widget.ideId,
      accountId: item.id,
      label: nextLabel,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusMsg = msg;
      _statusIsError = !ok;
    });
    if (ok) {
      widget.onAccountsChanged?.call();
      await _refresh();
    }
  }

  Future<void> _delete(IdeAccountItem item) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号快照'),
        content: Text('确定删除已保存的账号「${item.label}」吗？删除后需重新登录才能再切回该账号。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final (ok, msg) = await widget.hostActions.deleteIdeAccount(
      ideId: widget.ideId,
      accountId: item.id,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusMsg = msg;
      _statusIsError = !ok;
    });
    if (ok) {
      widget.onAccountsChanged?.call();
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final snap = _snapshot;
    final accounts = snap?.accounts ?? const <IdeAccountItem>[];
    final maxH = MediaQuery.of(context).size.height * 0.84;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.all(color: p.border),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: p.border,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Row(
            children: [
              Icon(Icons.manage_accounts_rounded, size: 21, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.ideName} 账号管理与切换',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: p.text,
                      ),
                    ),
                    Text(
                      '保留全部对话历史与项目 · 切号将重启 IDE 并重连 CDP',
                      style: TextStyle(fontSize: 11, color: p.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: (_loading || _busy) ? null : _refresh,
                icon: (_loading || _busy)
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.refresh_rounded, size: 20, color: p.muted),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded, size: 20, color: p.muted),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Current login summary card
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
                Row(
                  children: [
                    Icon(
                      (snap?.hasActiveCredential ?? false)
                          ? Icons.verified_user_rounded
                          : Icons.person_off_rounded,
                      size: 16,
                      color: (snap?.hasActiveCredential ?? false)
                          ? p.success
                          : p.warning,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        (snap == null)
                            ? '正在检测当前登录状态...'
                            : (snap.hasActiveCredential
                                ? '当前账号：${snap.activeAccountLabel.isNotEmpty ? snap.activeAccountLabel : (snap.currentUsername.isNotEmpty ? snap.currentUsername : "已登录")}'
                                : '当前未检测到已登录账号'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (snap != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: (snap.keyringSupported ? p.success : p.accent)
                              .withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          snap.keyringSupported ? '密钥环就绪' : '轻量配置快照',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color:
                                snap.keyringSupported ? p.success : p.accent,
                          ),
                        ),
                      ),
                  ],
                ),
                if ((snap?.currentUsername ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '邮箱 / 标识: ${snap!.currentUsername}',
                    style: TextStyle(fontSize: 11.5, color: p.muted),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            (_busy || _loading) ? null : () => _saveCurrent(),
                        icon: const Icon(Icons.bookmark_add_rounded, size: 16),
                        label: const Text('保存当前账号',
                            style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            (_busy || _loading) ? null : _prepareNewLogin,
                        icon: const Icon(Icons.person_add_alt_1_rounded,
                            size: 16),
                        label: const Text('新增账号登录',
                            style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_statusMsg != null) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: (_statusIsError ? p.danger : p.accent)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: (_statusIsError ? p.danger : p.accent)
                      .withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _statusMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _statusIsError ? p.danger : p.text,
                      ),
                    ),
                  ),
                  if (_awaitingNewLogin && widget.onOpenRemoteScreen != null)
                    TextButton(
                      onPressed: widget.onOpenRemoteScreen,
                      child: const Text('去控屏登录', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '已保存账号 (${accounts.length})',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: p.text,
                ),
              ),
              const Spacer(),
              Text(
                '点击即可切换并自动备份当前号',
                style: TextStyle(fontSize: 11, color: p.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),

          Flexible(
            child: accounts.isEmpty
                ? Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 22, horizontal: 14),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: p.border),
                    ),
                    child: Text(
                      _loading
                          ? '正在读取已保存账号...'
                          : '还没有保存过账号。\n先点击上方「保存当前账号」创建第一个快照，之后点「新增账号登录」即可录入第二个号并在两者间秒切。',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 12.5, color: p.muted, height: 1.5),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: accounts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, idx) {
                      final acc = accounts[idx];
                      return InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: (_busy || acc.isActive)
                            ? null
                            : () => _switchTo(acc),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: acc.isActive
                                ? p.accent.withValues(alpha: 0.1)
                                : p.panel,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: acc.isActive ? p.accent : p.border,
                            ),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 17,
                                backgroundColor:
                                    (acc.isActive ? p.accent : p.muted)
                                        .withValues(alpha: 0.16),
                                child: Text(
                                  acc.label.isNotEmpty
                                      ? acc.label.characters.first.toUpperCase()
                                      : 'A',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: acc.isActive ? p.accent : p.text,
                                  ),
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
                                            acc.label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w700,
                                              color: p.text,
                                            ),
                                          ),
                                        ),
                                        if (acc.isActive) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color: p.success
                                                  .withValues(alpha: 0.15),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              '当前使用',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700,
                                                color: p.success,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      [
                                        if (acc.detectedUsername.isNotEmpty &&
                                            acc.detectedUsername != acc.label)
                                          acc.detectedUsername,
                                        if (acc.hasKeyringSecret) '含密钥环凭据',
                                        '${acc.snapshotFiles} 项状态',
                                      ].join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11, color: p.muted),
                                    ),
                                  ],
                                ),
                              ),
                              if (!acc.isActive)
                                FilledButton.tonal(
                                  onPressed:
                                      _busy ? null : () => _switchTo(acc),
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                  ),
                                  child: const Text('切换',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              PopupMenuButton<String>(
                                enabled: !_busy,
                                icon: Icon(Icons.more_vert_rounded,
                                    size: 18, color: p.muted),
                                onSelected: (val) {
                                  if (val == 'update') {
                                    unawaited(
                                        _saveCurrent(overwriteTarget: acc));
                                  } else if (val == 'rename') {
                                    unawaited(_rename(acc));
                                  } else if (val == 'delete') {
                                    unawaited(_delete(acc));
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'update',
                                    child: Text('用当前登录态更新快照'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('重命名'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('删除快照'),
                                  ),
                                ],
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
}
