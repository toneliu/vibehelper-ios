import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../protocol/messages.dart';
import '../connection/connection_controller.dart';
import '../reader/window_content_controller.dart';

/// Merges fetched `/api/projects` entries with any project metadata carried
/// directly on [sessions] so project filter chips and pickers stay accurate even
/// before `/api/projects` finishes refreshing or when offline from cache.
List<ProjectItem> mergeProjectsWithSessions(
  List<ProjectItem> apiProjects,
  List<AgentSessionItem> sessions,
) {
  final byId = <String, ProjectItem>{};
  for (final proj in apiProjects) {
    if (proj.id.isNotEmpty) {
      byId[proj.id] = proj;
    }
  }
  for (final s in sessions) {
    if (s.projectId.isEmpty) continue;
    if (!byId.containsKey(s.projectId)) {
      byId[s.projectId] = ProjectItem(
        id: s.projectId,
        name: s.projectName.isNotEmpty ? s.projectName : s.projectId,
        path: s.projectPath,
        defaultIde: s.agent.isNotEmpty ? s.agent : 'antigravity',
        sessionCount: 1,
        lastActiveAt: s.updatedAt,
      );
    }
  }
  return byId.values.toList();
}

/// Opens a bottom sheet to create a new project directory on the Host, register
/// it in `~/.vibehelper/projects.json`, and optionally launch it in an AI IDE.
Future<ProjectItem?> showCreateProjectSheet(
  BuildContext context,
  WidgetRef ref, {
  String defaultRootDir = '',
  VoidCallback? onCreated,
}) async {
  final p = VibeTheme.paletteOf(context);
  final nameCtrl = TextEditingController();
  final parentCtrl = TextEditingController(text: defaultRootDir);
  final descCtrl = TextEditingController();

  bool initGit = true;
  bool createReadme = true;
  bool openInIde = true;
  String ideId = 'antigravity';
  bool submitting = false;
  String? errorText;

  String joinPreview(String parent, String name) {
    final cleanName = name.trim();
    final cleanParent = parent.trim().replaceAll(RegExp(r'[/\\]+$'), '');
    if (cleanName.isEmpty) {
      return cleanParent.isNotEmpty ? '$cleanParent/<项目名>' : '<默认目录>/<项目名>';
    }
    if (cleanParent.isEmpty) return cleanName;
    final sep = cleanParent.contains('\\') ? '\\' : '/';
    return '$cleanParent$sep$cleanName';
  }

  final created = await showModalBottomSheet<ProjectItem>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
        Future<void> submit() async {
          final cleanName = nameCtrl.text.trim();
          if (cleanName.isEmpty) {
            setSheetState(() => errorText = '请输入项目名称');
            return;
          }
          if (cleanName.contains('/') ||
              cleanName.contains('\\') ||
              cleanName.contains('..')) {
            setSheetState(() => errorText = '项目名称不能包含路径分隔符或 ..');
            return;
          }
          setSheetState(() {
            submitting = true;
            errorText = null;
          });
          HapticFeedback.mediumImpact();
          final (ok, proj, message) =
              await ref.read(hostActionProvider).createProject(
                    name: cleanName,
                    parentDir: parentCtrl.text.trim().isNotEmpty
                        ? parentCtrl.text.trim()
                        : null,
                    description: descCtrl.text.trim(),
                    initGit: initGit,
                    createReadme: createReadme,
                    openInIde: openInIde,
                    ideId: ideId,
                  );
          if (!ctx.mounted) return;
          if (!ok || proj == null) {
            setSheetState(() {
              submitting = false;
              errorText = message;
            });
            return;
          }
          Navigator.of(ctx).pop(proj);
          onCreated?.call();
          unawaited(ref.read(windowContentProvider.notifier).fetchContent());
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }

        Widget ideChip(String id, String label) {
          final selected = ideId == id;
          return ChoiceChip(
            label: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : p.text,
              ),
            ),
            selected: selected,
            selectedColor: p.accent,
            backgroundColor: p.panel,
            side: BorderSide(color: selected ? p.accent : p.border),
            onSelected: submitting
                ? null
                : (_) => setSheetState(() => ideId = id),
          );
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.create_new_folder_rounded,
                          size: 21, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '新建项目（宿主机目录）',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed:
                            submitting ? null : () => Navigator.of(ctx).pop(),
                        icon: Icon(Icons.close_rounded, color: p.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    enabled: !submitting,
                    onChanged: (_) => setSheetState(() => errorText = null),
                    decoration: InputDecoration(
                      labelText: '项目名称 *',
                      hintText: '例如：my-ai-app',
                      filled: true,
                      fillColor: p.panel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: parentCtrl,
                    enabled: !submitting,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: InputDecoration(
                      labelText: '存放目录（宿主机路径）',
                      hintText: defaultRootDir.isNotEmpty
                          ? defaultRootDir
                          : '~/projects',
                      filled: true,
                      fillColor: p.panel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: p.panelAlt,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: p.border.withValues(alpha: 0.7)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.folder_outlined, size: 14, color: p.muted),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            joinPreview(parentCtrl.text, nameCtrl.text),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: p.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: descCtrl,
                    enabled: !submitting,
                    maxLines: 2,
                    minLines: 1,
                    decoration: InputDecoration(
                      labelText: '项目简介（可选）',
                      hintText: '一句话说明项目用途',
                      filled: true,
                      fillColor: p.panel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('初始化 Git 仓库',
                        style: TextStyle(fontSize: 13.5, color: p.text)),
                    value: initGit,
                    onChanged: submitting
                        ? null
                        : (v) => setSheetState(() => initGit = v),
                  ),
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('自动创建 README.md',
                        style: TextStyle(fontSize: 13.5, color: p.text)),
                    value: createReadme,
                    onChanged: submitting
                        ? null
                        : (v) => setSheetState(() => createReadme = v),
                  ),
                  SwitchListTile.adaptive(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('创建后立即在 IDE 打开',
                        style: TextStyle(fontSize: 13.5, color: p.text)),
                    value: openInIde,
                    onChanged: submitting
                        ? null
                        : (v) => setSheetState(() => openInIde = v),
                  ),
                  if (openInIde) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        ideChip('antigravity', 'Antigravity'),
                        ideChip('vscode', 'VS Code'),
                        ideChip('cursor', 'Cursor'),
                      ],
                    ),
                  ],
                  if (errorText != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      errorText!,
                      style: TextStyle(fontSize: 12.5, color: p.danger),
                    ),
                  ],
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: submitting ? null : submit,
                    icon: submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded, size: 18),
                    label: Text(submitting ? '正在创建...' : '创建项目'),
                    style: FilledButton.styleFrom(
                      backgroundColor: p.accent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  nameCtrl.dispose();
  parentCtrl.dispose();
  descCtrl.dispose();
  return created;
}

/// Opens a bottom sheet allowing the user to assign/reassign a conversation
/// session to an existing project, create a new project for it, or revert to auto.
Future<bool> showAssignProjectSheet(
  BuildContext context,
  WidgetRef ref, {
  required AgentSessionItem session,
  required List<ProjectItem> projects,
  String defaultRootDir = '',
  VoidCallback? onAssigned,
}) async {
  final p = VibeTheme.paletteOf(context);
  bool saving = false;

  Future<void> applyAssignment(
    BuildContext sheetCtx, {
    required String projectId,
    String projectName = '',
    String projectPath = '',
    required void Function(VoidCallback) setSheetState,
  }) async {
    setSheetState(() => saving = true);
    HapticFeedback.selectionClick();
    final (ok, msg) = await ref.read(hostActionProvider).assignSessionProject(
          sessionId: session.id,
          projectId: projectId,
          projectName: projectName,
          projectPath: projectPath,
        );
    if (!sheetCtx.mounted) return;
    if (ok) {
      Navigator.of(sheetCtx).pop(true);
      onAssigned?.call();
      unawaited(ref.read(windowContentProvider.notifier).fetchContent());
    } else {
      setSheetState(() => saving = false);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(milliseconds: 1600),
        ),
      );
    }
  }

  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.72,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.drive_file_move_outlined,
                          size: 20, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '归类对话到项目',
                              style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                color: p.text,
                              ),
                            ),
                            Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: p.muted),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: saving
                            ? null
                            : () async {
                                final newProj = await showCreateProjectSheet(
                                  ctx,
                                  ref,
                                  defaultRootDir: defaultRootDir,
                                );
                                if (newProj != null && ctx.mounted) {
                                  await applyAssignment(
                                    ctx,
                                    projectId: newProj.id,
                                    projectName: newProj.name,
                                    projectPath: newProj.path,
                                    setSheetState: setSheetState,
                                  );
                                }
                              },
                        icon: const Icon(Icons.create_new_folder_outlined,
                            size: 16),
                        label:
                            const Text('新建并归入', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        if (projects.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              '当前暂无可用项目，请点击右上角「新建并归入」创建一个项目。',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, color: p.muted),
                            ),
                          ),
                        for (final proj in projects) ...[
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: saving
                                ? null
                                : () => applyAssignment(
                                      ctx,
                                      projectId: proj.id,
                                      projectName: proj.name,
                                      projectPath: proj.path,
                                      setSheetState: setSheetState,
                                    ),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 7),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: proj.id == session.projectId
                                    ? p.accent.withValues(alpha: 0.14)
                                    : p.panel,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: proj.id == session.projectId
                                      ? p.accent
                                      : p.border,
                                  width: proj.id == session.projectId ? 1.4 : 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.folder_rounded,
                                    size: 18,
                                    color: proj.id == session.projectId
                                        ? p.accent
                                        : const Color(0xFFF59E0B),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          proj.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight:
                                                proj.id == session.projectId
                                                    ? FontWeight.w700
                                                    : FontWeight.w600,
                                            color: p.text,
                                          ),
                                        ),
                                        if (proj.path.isNotEmpty)
                                          Text(
                                            proj.path,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontFamily: 'monospace',
                                              color: p.muted,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (proj.id == session.projectId)
                                    Icon(Icons.check_circle_rounded,
                                        size: 18, color: p.accent),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const Divider(height: 16),
                        ListTile(
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: Icon(Icons.auto_awesome_rounded,
                              size: 18, color: p.accent),
                          title: Text('恢复自动识别（清除手动归类）',
                              style: TextStyle(fontSize: 13, color: p.text)),
                          onTap: saving
                              ? null
                              : () => applyAssignment(
                                    ctx,
                                    projectId: '',
                                    setSheetState: setSheetState,
                                  ),
                        ),
                        ListTile(
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: Icon(Icons.folder_off_outlined,
                              size: 18, color: p.muted),
                          title: Text('移至未归类',
                              style: TextStyle(fontSize: 13, color: p.muted)),
                          onTap: saving
                              ? null
                              : () => applyAssignment(
                                    ctx,
                                    projectId: '__unassigned__',
                                    setSheetState: setSheetState,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
  return changed == true;
}
