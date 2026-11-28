import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/theme.dart';
import '../../protocol/messages.dart';
import '../connection/connection_controller.dart';
import '../mobile/project_sheets.dart';
import '../windows/window_controller.dart';
import 'media_attachments.dart';
import 'window_content_controller.dart';

String _agentDisplayName(String agent) {
  return switch (agent.toLowerCase()) {
    'antigravity' => 'Antigravity',
    'workbuddy' => 'WorkBuddy',
    'cursor' => 'Cursor',
    'claude_code' || 'claude' => 'Claude',
    'chatgpt' => 'ChatGPT',
    'vscode' => 'VS Code',
    'codex' => 'Codex',
    _ => agent.isEmpty ? 'Agent' : agent,
  };
}

String _shortModelName(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '选择模型';
  return s
      .replaceAll(' (Medium)', '')
      .replaceAll(' (High)', '·High')
      .replaceAll(' (Thinking)', '·Think');
}

/// Opens the Agent session history sheet; tapping a session syncs mobile AND
/// dispatches `vh:switch_session` to the Host IDE.
void openSessionPickerSheet(
  BuildContext context,
  WidgetRef ref,
  List<AgentSessionItem> sessions,
  String? activeId,
) {
  final ctrl = ref.read(windowContentProvider.notifier);
  final p = VibeTheme.paletteOf(context);
  String? selectedProjectId;
  List<ProjectItem> fetchedProjects = const [];
  String defaultRootDir = '';
  bool loadedProjectsOnce = false;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        if (!loadedProjectsOnce) {
          loadedProjectsOnce = true;
          unawaited(
            ref.read(hostActionProvider).fetchProjects().then((resp) {
              if (!ctx.mounted || resp == null) return;
              setSheetState(() {
                fetchedProjects = resp.projects;
                defaultRootDir = resp.defaultRootDir;
              });
            }),
          );
        }

        final mergedProjects =
            mergeProjectsWithSessions(fetchedProjects, sessions);
        final unassignedCount =
            sessions.where((s) => s.projectId.isEmpty).length;
        final filtered = sessions.where((s) {
          if (selectedProjectId == null) return true;
          if (selectedProjectId == '__unassigned__') return s.projectId.isEmpty;
          return s.projectId == selectedProjectId;
        }).toList();

        Widget filterChip(String label, String? targetId) {
          final active = selectedProjectId == targetId;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => setSheetState(() => selectedProjectId = targetId),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: active ? p.accent.withValues(alpha: 0.16) : p.panel,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: active ? p.accent : p.border),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? p.accent : p.text,
                  ),
                ),
              ),
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.forum_rounded, size: 20, color: p.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '切换 Agent 会话 (同步宿主机)',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        ctrl.selectSession(null);
                      },
                      icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                      label: const Text('自动最新', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                if (mergedProjects.length >= 2 ||
                    (mergedProjects.isNotEmpty && unassignedCount > 0)) ...[
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        filterChip('全部', null),
                        for (final proj in mergedProjects)
                          filterChip('📁 ${proj.name}', proj.id),
                        if (unassignedCount > 0)
                          filterChip('未归类', '__unassigned__'),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.58,
                  ),
                  child: filtered.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Center(
                            child: Text(
                              sessions.isEmpty
                                  ? '暂无历史会话，请先连接 Host 并选择 AI IDE 窗口'
                                  : '当前项目下暂无历史会话',
                              style: TextStyle(color: p.muted, fontSize: 13),
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, idx) {
                            final s = filtered[idx];
                            final selected = s.id == activeId;
                            return InkWell(
                              borderRadius: BorderRadius.circular(13),
                              onTap: () {
                                Navigator.of(ctx).pop();
                                ctrl.selectSession(s.id, title: s.title);
                              },
                              onLongPress: () => unawaited(
                                showAssignProjectSheet(
                                  ctx,
                                  ref,
                                  session: s,
                                  projects: mergedProjects,
                                  defaultRootDir: defaultRootDir,
                                ).then((changed) {
                                  if (changed && ctx.mounted) {
                                    Navigator.of(ctx).pop();
                                  }
                                }),
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 11),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? p.accent.withValues(alpha: 0.14)
                                      : p.panel,
                                  borderRadius: BorderRadius.circular(13),
                                  border: Border.all(
                                    color: selected ? p.accent : p.border,
                                    width: selected ? 1.4 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 7, vertical: 2.5),
                                      decoration: BoxDecoration(
                                        color: p.accent.withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        _agentDisplayName(s.agent),
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                          color: p.accent,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 9),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            s.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                              color: p.text,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Row(
                                            children: [
                                              if (s.projectName.isNotEmpty) ...[
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 5,
                                                      vertical: 1),
                                                  margin: const EdgeInsets.only(
                                                      right: 6),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFF59E0B)
                                                        .withValues(alpha: 0.14),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            5),
                                                  ),
                                                  child: Text(
                                                    '📁 ${s.projectName}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 9.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: p.isDark
                                                          ? const Color(
                                                              0xFFFBBF24)
                                                          : const Color(
                                                              0xFFB45309),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              Expanded(
                                                child: Text(
                                                  '${s.turnCount} 条消息${s.updatedAt.isNotEmpty ? ' · ${s.updatedAt}' : ''}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: p.muted,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '归类到项目',
                                      onPressed: () => unawaited(
                                        showAssignProjectSheet(
                                          ctx,
                                          ref,
                                          session: s,
                                          projects: mergedProjects,
                                          defaultRootDir: defaultRootDir,
                                        ).then((changed) {
                                          if (changed && ctx.mounted) {
                                            Navigator.of(ctx).pop();
                                          }
                                        }),
                                      ),
                                      icon: Icon(
                                        Icons.drive_file_move_outlined,
                                        size: 16,
                                        color: p.muted,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                          minWidth: 28, minHeight: 28),
                                    ),
                                    if (selected)
                                      Icon(Icons.check_circle_rounded,
                                          size: 18, color: p.accent),
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
      },
    ),
  );
}

String cleanModelDisplay(String raw) {
  var s = raw.trim();
  s = s.replaceFirst(
      RegExp(r'^select\s+model,\s*current:\s*', caseSensitive: false), '');
  s = s.replaceFirst(RegExp(r'\s*·\s*\d+(?:\.\d+)?[kmgt]?\s*$',
      caseSensitive: false), '');
  return s.trim();
}

class _ModelEffortOption {
  const _ModelEffortOption({
    required this.effortLabel,
    required this.fullValue,
  });

  final String effortLabel;
  final String fullValue;
}

class _ModelGroupEntry {
  const _ModelGroupEntry({
    required this.baseName,
    required this.options,
  });

  final String baseName;
  final List<_ModelEffortOption> options;
}

({String baseName, String effortLabel}) _splitModelEffortLabel(String raw) {
  final trimmed = raw.trim();
  final match = RegExp(
    r'\s+(extra\s*high|xhigh|high|medium|low|thinking)$',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) {
    return (baseName: trimmed, effortLabel: '');
  }
  final rawEff = (match.group(1) ?? '').trim().toLowerCase();
  final eff = switch (rawEff) {
    'extra high' || 'xhigh' => 'Extra High',
    'high' => 'High',
    'medium' => 'Medium',
    'low' => 'Low',
    'thinking' => 'Thinking',
    _ => (match.group(1) ?? '').trim(),
  };
  final base = trimmed.substring(0, match.start).trim();
  return (
    baseName: base.isNotEmpty ? base : trimmed,
    effortLabel: eff,
  );
}

({
  List<_ModelGroupEntry> orchestrator,
  List<_ModelGroupEntry> standard,
  bool hasBareOrchestrator,
}) _parseModelGroups(List<String> models) {
  final orchMap = <String, List<_ModelEffortOption>>{};
  final stdMap = <String, List<_ModelEffortOption>>{};
  bool hasBareOrch = false;

  final orchRe = RegExp(
    r'^orchestrator(?:\s*[·:\-/|]\s*(.+))?$',
    caseSensitive: false,
  );

  for (final raw in models) {
    final clean = raw.trim();
    if (clean.isEmpty) continue;
    final orchMatch = orchRe.firstMatch(clean);
    if (orchMatch != null) {
      final subSpec = (orchMatch.group(1) ?? '').trim();
      if (subSpec.isEmpty) {
        hasBareOrch = true;
        continue;
      }
      final split = _splitModelEffortLabel(subSpec);
      final list = orchMap.putIfAbsent(split.baseName, () => []);
      if (!list.any(
          (o) => o.fullValue.toLowerCase() == clean.toLowerCase())) {
        list.add(_ModelEffortOption(
          effortLabel: split.effortLabel,
          fullValue: clean,
        ));
      }
      continue;
    }

    final split = _splitModelEffortLabel(clean);
    final list = stdMap.putIfAbsent(split.baseName, () => []);
    if (!list.any((o) => o.fullValue.toLowerCase() == clean.toLowerCase())) {
      list.add(_ModelEffortOption(
        effortLabel: split.effortLabel,
        fullValue: clean,
      ));
    }
  }

  return (
    orchestrator: orchMap.entries
        .map((e) => _ModelGroupEntry(baseName: e.key, options: e.value))
        .toList(),
    standard: stdMap.entries
        .map((e) => _ModelGroupEntry(baseName: e.key, options: e.value))
        .toList(),
    hasBareOrchestrator: hasBareOrch,
  );
}

String _shortEffortChipLabel(String effortLabel) {
  return switch (effortLabel.toLowerCase()) {
    'low' => '低 Low',
    'medium' => '中 Med',
    'high' => '高 High',
    'extra high' => '极高 XHigh',
    'thinking' => '深度',
    _ => effortLabel,
  };
}

String _normModelCmp(String value) => value
    .toLowerCase()
    .replaceAll('·', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Opens the remote AI model, Orchestrator sub-model, and Thinking effort picker sheet.
void openModelPickerSheet(
  BuildContext context,
  WidgetRef ref,
  String activeModel,
  List<String> availableModels,
  String? targetWindowId,
) {
  final actions = ref.read(hostActionProvider);
  final p = VibeTheme.paletteOf(context);
  const fallbackModels = <String>[
    'Gemini 4 Neon Low',
    'Gemini 4 Neon Medium',
    'Gemini 4 Neon High',
    'Gemini 4 Neon Extra High',
    'Gemini 4 Carbon Low',
    'Gemini 4 Carbon Medium',
    'Gemini 4 Carbon High',
    'Gemini 4 Argon Low',
    'Gemini 4 Argon Medium',
    'Gemini 4 Argon High',
    'Gemini 4 Hydrogen Low',
    'Gemini 4 Hydrogen Medium',
    'Gemini 4 Hydrogen High',
    'Gemini 4 Hydrogen Extra High',
    'Gemini 3.8 Flash Low',
    'Gemini 3.8 Flash Medium',
    'Gemini 3.8 Flash High',
    'Claude Opus 5.5 Low',
    'Claude Opus 5.5 Medium',
    'Claude Opus 5.5 High',
    'Claude Sonnet 5.5 Low',
    'Claude Sonnet 5.5 Medium',
    'Claude Sonnet 5.5 High',
    'GPT-OSS 120B (Medium)',
    'Orchestrator · Gemini 4 Neon Low',
    'Orchestrator · Gemini 4 Neon Medium',
    'Orchestrator · Gemini 4 Neon High',
    'Orchestrator · Gemini 4 Neon Extra High',
    'Orchestrator · Gemini 4 Carbon Low',
    'Orchestrator · Gemini 4 Carbon Medium',
    'Orchestrator · Gemini 4 Carbon High',
    'Orchestrator · Gemini 4 Argon Low',
    'Orchestrator · Gemini 4 Argon Medium',
    'Orchestrator · Gemini 4 Argon High',
    'Orchestrator · Claude Opus 5.5 Low',
    'Orchestrator · Claude Opus 5.5 Medium',
    'Orchestrator · Claude Opus 5.5 High',
  ];

  final initialCleaned = <String>[];
  for (final raw in availableModels) {
    final cleaned = cleanModelDisplay(raw);
    if (cleaned.isEmpty) continue;
    if (!RegExp(r'^select\s+model', caseSensitive: false).hasMatch(cleaned) &&
        !initialCleaned.any((e) => e.toLowerCase() == cleaned.toLowerCase())) {
      initialCleaned.add(cleaned);
    }
  }

  var models = initialCleaned.isNotEmpty
      ? initialCleaned
      : List<String>.from(fallbackModels);
  var currentActive = cleanModelDisplay(activeModel);
  var currentPermMode = '';
  var permissionModes = const <({String id, String label, String zh})>[];
  var loadingLive = true;
  var initialized = false;
  var liveSource = '';

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        Future<void> refreshModels() async {
          if (ctx.mounted) {
            setSheetState(() => loadingLive = true);
          }
          final res = await actions.fetchHostModels(windowId: targetWindowId);
          if (!ctx.mounted) return;
          setSheetState(() {
            loadingLive = false;
            if (res.source.isNotEmpty) {
              liveSource = res.source;
            }
            final fetchedClean = <String>[];
            for (final raw in res.models) {
              final cleaned = cleanModelDisplay(raw);
              if (cleaned.isEmpty) continue;
              if (!fetchedClean
                  .any((e) => e.toLowerCase() == cleaned.toLowerCase())) {
                fetchedClean.add(cleaned);
              }
            }
            if (fetchedClean.isNotEmpty) {
              models = fetchedClean;
            }
            final fetchedActive = cleanModelDisplay(res.activeModel);
            if (fetchedActive.isNotEmpty) {
              currentActive = fetchedActive;
            }
            if (res.activePermissionMode.isNotEmpty) {
              currentPermMode = res.activePermissionMode;
            }
            if (res.permissionModes.isNotEmpty) {
              permissionModes = res.permissionModes;
            }
          });
        }

        void selectTargetModel(String targetModel) {
          Navigator.of(ctx).pop();
          HapticFeedback.mediumImpact();
          actions.sendControlKey(
            key: 'vh:select_model:$targetModel',
            targetWindowId: targetWindowId,
          );
          for (final ms in const [1100, 2100]) {
            Future<void>.delayed(Duration(milliseconds: ms), () {
              unawaited(
                ref.read(windowContentProvider.notifier).fetchContent(),
              );
            });
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已向被控端发送模型切换指令: $targetModel'),
              duration: const Duration(milliseconds: 1400),
            ),
          );
        }

        void selectPermissionMode(String modeId, String displayLabel) {
          HapticFeedback.mediumImpact();
          setSheetState(() {
            currentPermMode = modeId;
          });
          actions.sendControlKey(
            key: 'vh:select_mode:$modeId',
            targetWindowId: targetWindowId,
          );
          Future<void>.delayed(const Duration(milliseconds: 900), () {
            if (ctx.mounted) {
              unawaited(refreshModels());
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已切换 Agent 权限模式: $displayLabel'),
              duration: const Duration(milliseconds: 1400),
            ),
          );
        }

        if (!initialized) {
          initialized = true;
          Future<void>.microtask(refreshModels);
        }

        final parsed = _parseModelGroups(models);
        final activeNorm = _normModelCmp(currentActive);

        bool isOptionActive(_ModelEffortOption opt) {
          if (activeNorm.isEmpty) return false;
          return activeNorm == _normModelCmp(opt.fullValue);
        }

        Widget effortPill(_ModelEffortOption opt) {
          final selected = isOptionActive(opt);
          final label = opt.effortLabel.isNotEmpty
              ? _shortEffortChipLabel(opt.effortLabel)
              : '默认';
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => selectTargetModel(opt.fullValue),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: selected
                    ? p.accent
                    : p.panelAlt.withValues(alpha: p.isDark ? 0.9 : 1.0),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? p.accent : p.border,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? Colors.white : p.text,
                ),
              ),
            ),
          );
        }

        Widget buildGroupCard(
          _ModelGroupEntry group, {
          bool insideOrchestrator = false,
        }) {
          final hasEfforts = group.options.length > 1 ||
              group.options.first.effortLabel.isNotEmpty;
          final groupSelected = group.options.any(isOptionActive);

          if (!hasEfforts && group.options.length == 1) {
            final single = group.options.first;
            final selected = isOptionActive(single);
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => selectTargetModel(single.fullValue),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? p.accent.withValues(alpha: 0.14)
                      : (insideOrchestrator ? p.bg : p.panel),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? p.accent : p.border,
                    width: selected ? 1.4 : 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      insideOrchestrator
                          ? Icons.subdirectory_arrow_right_rounded
                          : Icons.auto_awesome_rounded,
                      size: 16,
                      color: selected ? p.accent : p.muted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.baseName,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(Icons.check_circle_rounded,
                          size: 18, color: p.accent),
                  ],
                ),
              ),
            );
          }

          return Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: groupSelected
                  ? p.accent.withValues(alpha: insideOrchestrator ? 0.14 : 0.10)
                  : (insideOrchestrator ? p.bg : p.panel),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: groupSelected ? p.accent : p.border,
                width: groupSelected ? 1.4 : 1.0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      insideOrchestrator
                          ? Icons.subdirectory_arrow_right_rounded
                          : Icons.auto_awesome_rounded,
                      size: 15,
                      color: groupSelected ? p.accent : p.muted,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        group.baseName,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              groupSelected ? FontWeight.w700 : FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                    ),
                    if (groupSelected)
                      Icon(Icons.check_circle_rounded,
                          size: 16, color: p.accent),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final opt in group.options) effortPill(opt)],
                ),
              ],
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.psychology_alt_rounded, size: 20, color: p.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '模型与思考强度选择',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: loadingLive ? null : refreshModels,
                      tooltip: '刷新模型列表',
                      icon: loadingLive
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: p.accent,
                              ),
                            )
                          : Icon(Icons.refresh_rounded, size: 17, color: p.muted),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        showUsageQuotaSheet(
                          context,
                          ref,
                          targetWindowId: targetWindowId,
                        );
                      },
                      icon: const Icon(Icons.data_usage_rounded, size: 14),
                      label: const Text('额度查询', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    loadingLive
                        ? '正在从远端实时读取模型、档位与权限状态...'
                        : (liveSource == 'cdp_live'
                            ? '已同步远端实时模型列表 (${models.length} 个档位)'
                            : '当前显示可用模型与强度档位 (${models.length} 项)'),
                    style: TextStyle(fontSize: 11, color: p.muted),
                  ),
                ),
                if (permissionModes.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: p.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.shield_outlined,
                              size: 14,
                              color: p.accent,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Agent 权限模式',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: p.text,
                              ),
                            ),
                            const Spacer(),
                            if (currentPermMode.isNotEmpty)
                              Text(
                                currentPermMode.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.accent,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final mode in permissionModes)
                              Builder(
                                builder: (_) {
                                  final selected =
                                      currentPermMode.toLowerCase() ==
                                          mode.id.toLowerCase();
                                  final isTurbo =
                                      mode.id.toLowerCase() == 'turbo';
                                  final activeColor = isTurbo
                                      ? const Color(0xFFD97706)
                                      : p.accent;
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(9),
                                    onTap: () => selectPermissionMode(
                                      mode.id,
                                      '${mode.label} (${mode.zh})',
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 9,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? activeColor.withValues(
                                                alpha: 0.14)
                                            : p.bg,
                                        borderRadius: BorderRadius.circular(9),
                                        border: Border.all(
                                          color: selected
                                              ? activeColor
                                              : p.border,
                                          width: selected ? 1.3 : 1,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isTurbo) ...[
                                            Icon(
                                              Icons.bolt_rounded,
                                              size: 13,
                                              color: selected
                                                  ? activeColor
                                                  : p.muted,
                                            ),
                                            const SizedBox(width: 3),
                                          ],
                                          Text(
                                            mode.label,
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: selected
                                                  ? FontWeight.w700
                                                  : FontWeight.w600,
                                              color: selected
                                                  ? activeColor
                                                  : p.text,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            mode.zh,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: selected
                                                  ? activeColor
                                                  : p.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 2),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.56,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (parsed.orchestrator.isNotEmpty ||
                          parsed.hasBareOrchestrator) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: p.accent.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.hub_rounded,
                                      size: 17, color: p.accent),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                      'Orchestrator · 智能编排模型',
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                        color: p.text,
                                      ),
                                    ),
                                  ),
                                  if (parsed.hasBareOrchestrator &&
                                      parsed.orchestrator.isEmpty)
                                    TextButton(
                                      onPressed: () =>
                                          selectTargetModel('Orchestrator'),
                                      child: const Text('直接启用'),
                                    ),
                                ],
                              ),
                              if (parsed.orchestrator.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                for (int i = 0;
                                    i < parsed.orchestrator.length;
                                    i++) ...[
                                  if (i > 0) const SizedBox(height: 7),
                                  buildGroupCard(
                                    parsed.orchestrator[i],
                                    insideOrchestrator: true,
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ],
                      for (int i = 0; i < parsed.standard.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        buildGroupCard(parsed.standard[i]),
                      ],
                    ],
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

String _formatTokenCompact(int tokens) {
  if (tokens >= 1000000) {
    return '${(tokens / 1000000).toStringAsFixed(1)}M';
  }
  if (tokens >= 1000) {
    return '${(tokens / 1000).toStringAsFixed(1)}K';
  }
  return '$tokens';
}

/// Opens a live Usage & Remaining Quota modal bottom sheet backed by `/api/host/usage`.
void showUsageQuotaSheet(
  BuildContext context,
  WidgetRef ref, {
  String? targetWindowId,
}) {
  final p = VibeTheme.paletteOf(context);
  Future<HostUsageReport> loadUsageReport() {
    final winState = ref.read(windowControllerProvider);
    final contentState = ref.read(windowContentProvider);
    final sessionId = contentState.content?.activeSessionId ??
        contentState.selectedSessionId;
    final windowId = targetWindowId ?? winState.selectedWindowId;
    return ref.read(hostActionProvider).fetchHostUsage(
          sessionId: sessionId,
          windowId: windowId,
        );
  }

  Future<HostUsageReport> reportFuture = loadUsageReport();

  String modelSourceLabel(String src) {
    return switch (src) {
      'cdp_live' => 'CDP 实时',
      'uia_live' => '窗口实时',
      'ocr_live' => '屏幕识别',
      'transcript' => '对话日志',
      _ => '',
    };
  }

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        Widget statCard(String label, String value, Color accent) {
          return Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: p.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(fontSize: 11, color: p.muted),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.80,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.data_usage_rounded, size: 20, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '当前对话用量与剩余额度',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: p.text,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          setSheetState(() {
                            reportFuture = loadUsageReport();
                          });
                        },
                        icon: Icon(Icons.refresh_rounded, color: p.accent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Flexible(
                    child: FutureBuilder<HostUsageReport>(
                      future: reportFuture,
                      builder: (ctx, snap) {
                        if (snap.connectionState == ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 42),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            ),
                          );
                        }
                        final report = snap.data;
                        if (report == null || report.error != null) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Center(
                              child: Text(
                                report?.error ?? '暂未获取到数据',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 13, color: p.danger),
                              ),
                            ),
                          );
                        }

                        final srcLabel =
                            modelSourceLabel(report.currentModelSource);

                        return SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 1. Current active conversation (bound by session_id + window_id)
                              Text(
                                '当前对话',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: p.panel,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: p.accent.withValues(alpha: 0.35),
                                  ),
                                ),
                                child: report.currentTitle.isEmpty &&
                                        report.currentModel.isEmpty
                                    ? Text(
                                        '暂无活动会话日志，请先在聊天页选中目标窗口或对话',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: p.muted,
                                        ),
                                      )
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (report.currentTitle.isNotEmpty)
                                            Text(
                                              report.currentTitle,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                                color: p.text,
                                              ),
                                            ),
                                          if (report
                                              .currentModel.isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 8,
                                                      vertical: 3),
                                                  decoration: BoxDecoration(
                                                    color: p.accent
                                                        .withValues(alpha: 0.14),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            7),
                                                  ),
                                                  child: Text(
                                                    cleanModelDisplay(
                                                        report.currentModel),
                                                    style: TextStyle(
                                                      fontSize: 11.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: p.accent,
                                                    ),
                                                  ),
                                                ),
                                                if (srcLabel.isNotEmpty)
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 6,
                                                        vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: p.panelAlt,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              6),
                                                    ),
                                                    child: Text(
                                                      srcLabel,
                                                      style: TextStyle(
                                                        fontSize: 10.5,
                                                        color: p.muted,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                          const SizedBox(height: 10),
                                          Row(
                                            children: [
                                              statCard(
                                                '当前上下文',
                                                report.currentContextTokens > 0
                                                    ? _formatTokenCompact(report
                                                        .currentContextTokens)
                                                    : '--',
                                                p.accent,
                                              ),
                                              const SizedBox(width: 8),
                                              statCard(
                                                report.currentExactTokens
                                                    ? '累计精确 Token'
                                                    : '累计估算 Token',
                                                _formatTokenCompact(
                                                    report.currentEstTokens),
                                                p.success,
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              statCard(
                                                '对话轮次',
                                                '${report.currentTurns}',
                                                p.text,
                                              ),
                                              const SizedBox(width: 8),
                                              statCard(
                                                '工具调用',
                                                '${report.currentTools}',
                                                const Color(0xFF0EA5E9),
                                              ),
                                            ],
                                          ),
                                          if (report.currentExactTokens) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              '精确累计 · 输入 ${_formatTokenCompact(report.currentInputTokens)} · 输出 ${_formatTokenCompact(report.currentOutputTokens)} · 缓存命中 ${_formatTokenCompact(report.currentCacheReadTokens)}',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontFamily: 'monospace',
                                                color: p.muted,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                              ),

                              const SizedBox(height: 14),
                              // 2. Account / model remaining quotas
                              Text(
                                '账号剩余额度',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (report.quotas.isEmpty)
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: p.panel,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: p.border),
                                  ),
                                  child: Text(
                                    '暂无可用实时额度数据（Antigravity 2.0 账户额度由服务端下发，本地不落盘明文余额；宿主机开启 CDP 并在电脑端展开额度弹窗后点右上角刷新可读取）。',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: p.muted,
                                      height: 1.4,
                                    ),
                                  ),
                                )
                              else
                                for (final q in report.quotas) ...[
                                  Builder(
                                    builder: (_) {
                                      final pct = q.remainingPercent ?? 0.0;
                                      final barColor = pct >= 70
                                          ? p.success
                                          : (pct >= 30
                                              ? p.warning
                                              : p.danger);
                                      final sourceTag = switch (q.source) {
                                        'cdp_view_usage' => 'View Usage',
                                        'cdp_live' => 'CDP 实时',
                                        _ => q.isFresh ? '有效缓存' : '近期快照',
                                      };
                                      return Container(
                                        margin:
                                            const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.all(11),
                                        decoration: BoxDecoration(
                                          color: p.panel,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(color: p.border),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    q.model,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: p.text,
                                                    ),
                                                  ),
                                                ),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 6,
                                                      vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: p.panelAlt,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                  ),
                                                  child: Text(
                                                    sourceTag,
                                                    style: TextStyle(
                                                      fontSize: 10.5,
                                                      color: p.muted,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  q.remainingPercent != null
                                                      ? '${pct.toStringAsFixed(0)}%'
                                                      : '--',
                                                  style: TextStyle(
                                                    fontSize: 13.5,
                                                    fontWeight: FontWeight.w700,
                                                    fontFamily: 'monospace',
                                                    color: barColor,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                value: (pct / 100.0)
                                                    .clamp(0.0, 1.0),
                                                minHeight: 6,
                                                backgroundColor: p.panelAlt,
                                                valueColor:
                                                    AlwaysStoppedAnimation(
                                                        barColor),
                                              ),
                                            ),
                                            if (q.resetIn.isNotEmpty ||
                                                q.resetAt.isNotEmpty) ...[
                                              const SizedBox(height: 5),
                                              Text(
                                                [
                                                  if (q.resetIn.isNotEmpty)
                                                    q.resetIn,
                                                  if (q.resetAt.isNotEmpty)
                                                    '(${q.resetAt})',
                                                ].join(' '),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: p.muted,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ],

                              const SizedBox(height: 10),
                              // 3. Machine-wide today summary
                              Text(
                                '今日全机汇总 (${report.todaySessions} 个活跃会话)',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: p.muted,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  statCard('今日轮次', '${report.todayTurns}',
                                      p.accent),
                                  const SizedBox(width: 8),
                                  statCard('工具调用', '${report.todayTools}',
                                      const Color(0xFF0EA5E9)),
                                  const SizedBox(width: 8),
                                  statCard(
                                      '今日 Token',
                                      _formatTokenCompact(
                                          report.todayEstTokens),
                                      p.success),
                                ],
                              ),
                              if (report.byModel.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: p.panel,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: p.border),
                                  ),
                                  child: Column(
                                    children: [
                                      for (int i = 0;
                                          i < report.byModel.length;
                                          i++) ...[
                                        if (i > 0)
                                          Divider(
                                              height: 10, color: p.border),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                report.byModel[i].model,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: p.text,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              '${report.byModel[i].turns} 轮 · ${_formatTokenCompact(report.byModel[i].estTokens)} tokens',
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontFamily: 'monospace',
                                                color: p.muted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],

                              if (report.note.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(
                                  report.note,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: p.muted,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
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
}

/// Native mobile-style AI conversation reader with:
/// - Session / conversation switcher (Antigravity / WorkBuddy / Cursor / Claude Code / Codex)
/// - Remote Model Selector pill & sheet (`vh:select_model:<name>` / `vh:model_menu`)
/// - Agent Guidance & Slash Action Bar (Proceed/Accept, Reject, Continue, Remote Voice, /plan, /boost, /compact)
/// - Interactive multi-question cards (`ask_question`) with CDP or text-injection answer submission
/// - Rich Markdown rendering adapting to Light ("灵光") and Dark geek palettes
/// - Expandable/collapsible thinking, tool calls, and code diff cards
class NativeChatView extends ConsumerWidget {
  const NativeChatView({
    super.key,
    required this.contentState,
    required this.connected,
    this.onPullDraftToInput,
    this.compactHeader = false,
  });

  final WindowContentState contentState;
  final bool connected;
  final ValueChanged<String>? onPullDraftToInput;

  /// When `true` (e.g. inside MobileVibePage), hides the top session/model bar
  /// and guidance chips because sessions live in the Drawer and actions live in `+`.
  final bool compactHeader;

  Future<void> _sendQuickPrompt(
    BuildContext context,
    WidgetRef ref,
    String text, {
    bool autoSend = true,
  }) async {
    if (!connected) return;
    HapticFeedback.mediumImpact();
    if (!autoSend && onPullDraftToInput != null) {
      onPullDraftToInput!(text);
      return;
    }
    final winState = ref.read(windowControllerProvider);
    final selected = winState.selectedWindow;
    final res = await ref.read(hostActionProvider).injectText(
          text: text,
          targetWindowId: winState.selectedWindowId,
          targetWindowTitle: selected != null
              ? '[${selected.app}] ${selected.title}'
              : '当前焦点窗口',
          source: 'quick_command',
          autoEnter: true,
        );
    if (res != null && res.ok) {
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        unawaited(ref.read(windowContentProvider.notifier).fetchContent());
      });
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = VibeTheme.paletteOf(context);
    final settings = ref.watch(settingsProvider);
    final wsUri = Uri.tryParse(settings.wsUrl.trim());
    String hostHttpBase = '';
    if (wsUri != null && wsUri.host.isNotEmpty) {
      final httpScheme = wsUri.scheme == 'wss' ? 'https' : 'http';
      final httpPort =
          wsUri.hasPort ? wsUri.port : (httpScheme == 'https' ? 443 : 8765);
      hostHttpBase = Uri(
        scheme: httpScheme,
        host: wsUri.host,
        port: httpPort,
      ).toString();
    }
    final hostToken = settings.token.trim();
    final content = contentState.content;
    final sessions = content?.sessions ?? const <AgentSessionItem>[];
    final activeId = content?.activeSessionId;
    final activeSession =
        sessions.where((s) => s.id == activeId).firstOrNull ??
            (sessions.isNotEmpty ? sessions.first : null);

    final draftBox = (content != null && content.inputBoxes.isNotEmpty)
        ? content.inputBoxes.first
        : null;
    final blocks = content?.dialogBlocks ?? const <DialogBlockItem>[];
    final actions = ref.read(hostActionProvider);
    final targetWindowId = ref.watch(windowControllerProvider).selectedWindowId;

    String activeModel = cleanModelDisplay(content?.activeModel ?? '');
    if (activeModel.isEmpty) {
      for (final b in blocks.reversed) {
        if (b.model.isNotEmpty) {
          activeModel = cleanModelDisplay(b.model);
          break;
        }
      }
    }
    final availableModels = content?.availableModels ?? const <String>[];
    final pendingQuestions =
        content?.pendingQuestions ?? const <PendingQuestionItem>[];
    final pendingSig = pendingQuestions
        .map((q) => '${q.question}:${q.options.join(",")}')
        .join('|');
    final showPendingQuestions = connected &&
        pendingQuestions.isNotEmpty &&
        pendingSig != contentState.dismissedQuestionsSignature;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compactHeader) ...[
          // 1. Session Switcher, Model Selector Pill & Quick Agent Action Buttons
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: (connected && sessions.isNotEmpty)
                        ? () => openSessionPickerSheet(
                            context, ref, sessions, activeId)
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(
                        color: p.panel,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.border),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.forum_outlined, size: 14, color: p.accent),
                          const SizedBox(width: 5),
                          if (activeSession != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: p.accent.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                _agentDisplayName(activeSession.agent),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: p.accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Text(
                              activeSession != null
                                  ? '${activeSession.title} (${activeSession.turnCount})'
                                  : (content?.windowTitle.isNotEmpty == true
                                      ? content!.windowTitle
                                      : '选择会话...'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: p.text,
                              ),
                            ),
                          ),
                          if (sessions.isNotEmpty)
                            Icon(Icons.expand_more_rounded,
                                size: 16, color: p.muted),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: connected
                      ? () => openModelPickerSheet(
                            context,
                            ref,
                            activeModel,
                            availableModels,
                            targetWindowId,
                          )
                      : null,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: p.accent.withValues(alpha: 0.45)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome_rounded,
                            size: 13, color: p.accent),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 96),
                          child: Text(
                            _shortModelName(activeModel),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: p.accent,
                            ),
                          ),
                        ),
                        Icon(Icons.arrow_drop_down_rounded,
                            size: 15, color: p.muted),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                _actionIconBtn(
                  p: p,
                  icon: Icons.add_comment_outlined,
                  tooltip: '新建会话',
                  onTap: connected
                      ? () {
                          HapticFeedback.lightImpact();
                          ref
                              .read(windowContentProvider.notifier)
                              .startNewSession();
                        }
                      : null,
                ),
                const SizedBox(width: 4),
                _actionIconBtn(
                  p: p,
                  icon: Icons.stop_circle_outlined,
                  tooltip: '停止生成',
                  color: p.warning,
                  onTap: connected
                      ? () {
                          HapticFeedback.lightImpact();
                          actions.sendControlKey(
                            key: 'vh:interrupt',
                            targetWindowId: targetWindowId,
                          );
                        }
                      : null,
                ),
                if (content != null && content.fullText.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _actionIconBtn(
                    p: p,
                    icon: Icons.copy_all_rounded,
                    tooltip: '复制整个会话',
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: content.fullText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制完整会话文本'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),

          // 1b. Agent Guidance & High-Frequency Action Bar
          Container(
            height: 30,
            margin: const EdgeInsets.only(bottom: 7),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _guidanceChip(
                  p: p,
                  icon: Icons.check_circle_outline_rounded,
                  label: '接受/Proceed',
                  color: p.success,
                  onTap: connected
                      ? () {
                          HapticFeedback.mediumImpact();
                          actions.sendControlKey(
                            key: 'vh:accept',
                            targetWindowId: targetWindowId,
                          );
                        }
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.cancel_outlined,
                  label: '拒绝/Reject',
                  color: p.danger,
                  onTap: connected
                      ? () {
                          HapticFeedback.lightImpact();
                          actions.sendControlKey(
                            key: 'vh:reject',
                            targetWindowId: targetWindowId,
                          );
                        }
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.play_arrow_rounded,
                  label: '继续生成',
                  color: p.accent,
                  onTap: connected
                      ? () => _sendQuickPrompt(context, ref, '继续')
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.mic_external_on_rounded,
                  label: '唤醒远端听写',
                  color: p.warning,
                  onTap: connected
                      ? () {
                          HapticFeedback.mediumImpact();
                          actions.sendControlKey(
                            key: 'vh:voice_dictate',
                            targetWindowId: targetWindowId,
                          );
                        }
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.graphic_eq_rounded,
                  label: '远端实时语音',
                  color: p.accent,
                  onTap: connected
                      ? () {
                          HapticFeedback.mediumImpact();
                          actions.sendControlKey(
                            key: 'vh:voice_live',
                            targetWindowId: targetWindowId,
                          );
                        }
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.route_outlined,
                  label: '/plan 规划',
                  onTap: connected
                      ? () => _sendQuickPrompt(context, ref, '/plan ',
                          autoSend: false)
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.rocket_launch_outlined,
                  label: '/boost 深度',
                  onTap: connected
                      ? () => _sendQuickPrompt(context, ref, '/boost ',
                          autoSend: false)
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.compress_rounded,
                  label: '/compact 压缩',
                  onTap: connected
                      ? () => _sendQuickPrompt(context, ref, '/compact')
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.flag_outlined,
                  label: '/goal 目标',
                  onTap: connected
                      ? () => _sendQuickPrompt(context, ref, '/goal ',
                          autoSend: false)
                      : null,
                ),
                _guidanceChip(
                  p: p,
                  icon: Icons.quiz_outlined,
                  label: '/grill-me 追问',
                  onTap: connected
                      ? () => _sendQuickPrompt(context, ref, '/grill-me ',
                          autoSend: false)
                      : null,
                ),
              ],
            ),
          ),
        ],

        // 2. Remote Input Box Draft Banner (desktop/expanded mode only; mobile composer syncs live)
        if (!compactHeader && draftBox != null && draftBox.text.trim().isNotEmpty)
          InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: onPullDraftToInput != null
                ? () => onPullDraftToInput!(draftBox.text)
                : null,
            child: Container(
              margin: const EdgeInsets.only(bottom: 7),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.11),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: p.accent.withValues(alpha: 0.38)),
              ),
              child: Row(
                children: [
                  Icon(Icons.edit_note_rounded, size: 16, color: p.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '远端输入框草稿: ${draftBox.text}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: p.text),
                    ),
                  ),
                  if (onPullDraftToInput != null)
                    Text(
                      '拉入',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: p.accent,
                      ),
                    ),
                ],
              ),
            ),
          ),

        // 3. Native Chat Message Stream
        Expanded(
          child: Container(
            decoration: compactHeader
                ? null
                : BoxDecoration(
                    color: p.chatCanvas,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: p.border),
                  ),
            child: blocks.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        connected
                            ? (content?.note ??
                                '点击刷新，直接从本地存储读取 Antigravity / WorkBuddy / Cursor / Claude 完整会话\n（支持 Markdown 富文本渲染、代码块复制、模型切换、思考过程展开）')
                            : '请先点击顶部栏选择或连接被控端 (Host)',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 13,
                          height: 1.6,
                        ),
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () =>
                        ref.read(windowContentProvider.notifier).fetchContent(),
                    child: ListView.builder(
                      reverse: true,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.symmetric(
                        horizontal: compactHeader ? 6 : 10,
                        vertical: 8,
                      ),
                      itemCount: blocks.length,
                      itemBuilder: (ctx, revIdx) {
                        final block = blocks[blocks.length - 1 - revIdx];
                        return _ChatTurnCard(
                          block: block,
                          hostHttpBase: hostHttpBase,
                          hostToken: hostToken,
                          onRunCode: connected
                              ? (code) => _sendQuickPrompt(context, ref, code,
                                  autoSend: false)
                              : null,
                        );
                      },
                    ),
                  ),
          ),
        ),

        // 4. Interactive Pending Multi-Question Card (ask_question)
        if (showPendingQuestions)
          _PendingQuestionsCard(
            key: ValueKey(pendingSig),
            questions: pendingQuestions,
            targetWindowId: targetWindowId,
            onDismiss: () {
              ref
                  .read(windowContentProvider.notifier)
                  .dismissPendingQuestions(pendingSig);
            },
            onSubmitted: () {
              final notifier = ref.read(windowContentProvider.notifier);
              notifier.dismissPendingQuestions(pendingSig);
              Future<void>.delayed(const Duration(milliseconds: 1600), () {
                unawaited(notifier.fetchContent());
              });
              Future<void>.delayed(const Duration(milliseconds: 3600), () {
                unawaited(notifier.fetchContent());
              });
            },
          ),

        // 5. Agent Real-Time Approval / Running Status Banner
        if (connected &&
            content != null &&
            !showPendingQuestions &&
            content.agentStatus == 'waiting_approval')
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: p.warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.warning.withValues(alpha: 0.55)),
            ),
            child: Row(
              children: [
                Icon(Icons.notifications_active_rounded,
                    size: 16, color: p.warning),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    content.pendingApprovalText.isNotEmpty
                        ? content.pendingApprovalText
                        : 'Agent 等待确认操作',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.warning,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    actions.sendControlKey(
                      key: 'vh:accept',
                      targetWindowId: targetWindowId,
                    );
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: p.success.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: p.success),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_rounded, size: 13, color: p.success),
                        const SizedBox(width: 3),
                        Text(
                          '允许',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: p.success,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    actions.sendControlKey(
                      key: 'vh:reject',
                      targetWindowId: targetWindowId,
                    );
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: p.danger.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: p.danger),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close_rounded, size: 13, color: p.danger),
                        const SizedBox(width: 3),
                        Text(
                          '拒绝',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: p.danger,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (!compactHeader &&
            connected &&
            content != null &&
            content.agentStatus == 'working')
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.accent.withValues(alpha: 0.42)),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    content.pendingApprovalText.isNotEmpty
                        ? content.pendingApprovalText
                        : 'Agent 正在实时思考与执行 (自动推送中)...',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: p.accent,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    actions.sendControlKey(
                      key: 'vh:interrupt',
                      targetWindowId: targetWindowId,
                    );
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.stop_rounded, size: 14, color: p.warning),
                        const SizedBox(width: 2),
                        Text(
                          '停止',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: p.warning,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _guidanceChip({
    required VibePalette p,
    required IconData icon,
    required String label,
    Color? color,
    VoidCallback? onTap,
  }) {
    final c = color ?? p.text;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: color != null ? color.withValues(alpha: 0.12) : p.panel,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: color != null ? color.withValues(alpha: 0.4) : p.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 13.5,
                  color: onTap == null ? p.muted.withValues(alpha: 0.4) : c,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: onTap == null ? p.muted.withValues(alpha: 0.4) : c,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionIconBtn({
    required VibePalette p,
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Icon(
              icon,
              size: 16,
              color: onTap == null
                  ? p.muted.withValues(alpha: 0.4)
                  : (color ?? p.text),
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingQuestionsCard extends ConsumerStatefulWidget {
  const _PendingQuestionsCard({
    super.key,
    required this.questions,
    required this.targetWindowId,
    required this.onSubmitted,
    this.onDismiss,
  });

  final List<PendingQuestionItem> questions;
  final String? targetWindowId;
  final VoidCallback onSubmitted;
  final VoidCallback? onDismiss;

  @override
  ConsumerState<_PendingQuestionsCard> createState() =>
      _PendingQuestionsCardState();
}

class _PendingQuestionsCardState extends ConsumerState<_PendingQuestionsCard> {
  final Map<int, Set<int>> _selected = {};
  final TextEditingController _noteCtrl = TextEditingController();
  bool _submitting = false;
  Timer? _submitResetTimer;

  @override
  void didUpdateWidget(covariant _PendingQuestionsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.questions != widget.questions) {
      _submitResetTimer?.cancel();
      _submitting = false;
    }
  }

  @override
  void dispose() {
    _submitResetTimer?.cancel();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _toggleOption(int qIdx, int optIdx, bool isMulti) {
    HapticFeedback.selectionClick();
    setState(() {
      final current = Set<int>.from(_selected[qIdx] ?? const <int>{});
      if (isMulti) {
        if (!current.add(optIdx)) {
          current.remove(optIdx);
        }
      } else {
        current
          ..clear()
          ..add(optIdx);
      }
      _selected[qIdx] = current;
    });
  }

  bool get _hasAnyInput {
    if (_noteCtrl.text.trim().isNotEmpty) return true;
    return _selected.values.any((s) => s.isNotEmpty);
  }

  void _submit() {
    if (!_hasAnyInput || _submitting) return;
    setState(() => _submitting = true);
    _submitResetTimer?.cancel();
    _submitResetTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _submitting) {
        setState(() => _submitting = false);
      }
    });
    HapticFeedback.mediumImpact();

    final pickedOptions = <String>[];
    final formattedLines = <String>[];
    final answers = <Map<String, dynamic>>[];
    for (int i = 0; i < widget.questions.length; i++) {
      final q = widget.questions[i];
      final indices = (_selected[i] ?? const <int>{}).toList()..sort();
      final picks = indices
          .where((idx) => idx >= 0 && idx < q.options.length)
          .map((idx) => q.options[idx])
          .toList();
      if (picks.isNotEmpty) {
        pickedOptions.addAll(picks);
        formattedLines.add('${i + 1}. ${q.question}: ${picks.join("、")}');
        answers.add({
          'question': q.question,
          'options': picks,
          'option_indices': indices,
          'is_multi': q.isMultiSelect,
        });
      }
    }

    final customNote = _noteCtrl.text.trim();
    if (customNote.isNotEmpty) {
      formattedLines.add(pickedOptions.isEmpty ? customNote : '补充说明: $customNote');
    }

    final payload = {
      'picked_options': pickedOptions,
      'answers': answers,
      'has_custom_only': pickedOptions.isEmpty && customNote.isNotEmpty,
      'formatted_text': formattedLines.join('\n'),
    };

    ref.read(hostActionProvider).sendControlKey(
          key: 'vh:answer_questions:${jsonEncode(payload)}',
          targetWindowId: widget.targetWindowId,
        );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已提交回答到远程 Agent'),
        duration: Duration(milliseconds: 1200),
      ),
    );
    widget.onSubmitted();
  }

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.accent.withValues(alpha: 0.45)),
        boxShadow: p.isDark
            ? null
            : [
                BoxShadow(
                  color: p.accent.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.quiz_rounded, size: 16, color: p.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Agent 向你提问 (${widget.questions.length})',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: p.accent,
                  ),
                ),
              ),
              Text(
                '选择后一键发送',
                style: TextStyle(fontSize: 11, color: p.muted),
              ),
              if (widget.onDismiss != null) ...[
                const SizedBox(width: 4),
                InkWell(
                  onTap: widget.onDismiss,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded, size: 16, color: p.muted),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 210),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int qIdx = 0; qIdx < widget.questions.length; qIdx++) ...[
                    if (qIdx > 0) const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '${qIdx + 1}. ${widget.questions[qIdx].question}',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: p.text,
                              height: 1.35,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: p.panelAlt,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            widget.questions[qIdx].isMultiSelect ? '多选' : '单选',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: p.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (widget.questions[qIdx].options.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (int optIdx = 0;
                              optIdx < widget.questions[qIdx].options.length;
                              optIdx++)
                            Builder(
                              builder: (_) {
                                final q = widget.questions[qIdx];
                                final opt = q.options[optIdx];
                                final picked =
                                    (_selected[qIdx] ?? const <int>{})
                                        .contains(optIdx);
                                return InkWell(
                                  borderRadius: BorderRadius.circular(9),
                                  onTap: () => _toggleOption(
                                      qIdx, optIdx, q.isMultiSelect),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 9, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: picked
                                          ? p.accent.withValues(alpha: 0.14)
                                          : p.panelAlt,
                                      borderRadius: BorderRadius.circular(9),
                                      border: Border.all(
                                        color: picked ? p.accent : p.border,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          q.isMultiSelect
                                              ? (picked
                                                  ? Icons.check_box_rounded
                                                  : Icons
                                                      .check_box_outline_blank_rounded)
                                              : (picked
                                                  ? Icons
                                                      .radio_button_checked_rounded
                                                  : Icons
                                                      .radio_button_off_rounded),
                                          size: 14,
                                          color: picked ? p.accent : p.muted,
                                        ),
                                        const SizedBox(width: 5),
                                        Flexible(
                                          child: Text(
                                            opt,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: picked
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                              color: picked ? p.accent : p.text,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _noteCtrl,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(fontSize: 12.5, color: p.text),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '补充说明或自由回答（可选）',
                    hintStyle: TextStyle(fontSize: 12, color: p.muted),
                    filled: true,
                    fillColor: p.panelAlt,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: p.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: p.border),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _hasAnyInput && !_submitting ? _submit : null,
                icon: _submitting
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 15),
                label: const Text('提交', style: TextStyle(fontSize: 12.5)),
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatTurnCard extends StatefulWidget {
  const _ChatTurnCard({
    required this.block,
    this.onRunCode,
    this.hostHttpBase = '',
    this.hostToken = '',
  });

  final DialogBlockItem block;
  final ValueChanged<String>? onRunCode;
  final String hostHttpBase;
  final String hostToken;

  @override
  State<_ChatTurnCard> createState() => _ChatTurnCardState();
}

class _ChatTurnCardState extends State<_ChatTurnCard> {
  bool _showThinking = false;
  bool _showTools = false;
  bool _showDiffs = false;

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final b = widget.block;
    final isUser = b.role == 'user';
    final isAssistant = b.role == 'assistant';

    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 28),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.fromLTRB(13, 9, 13, 10),
            decoration: BoxDecoration(
              color: p.userBubbleBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
              border: Border.all(
                color: p.accent.withValues(alpha: p.isDark ? 0.45 : 0.28),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_rounded, size: 13, color: p.accent),
                    const SizedBox(width: 4),
                    Text(
                      '我',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: p.accent,
                      ),
                    ),
                    if (b.timestamp.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        b.timestamp,
                        style: TextStyle(fontSize: 10.5, color: p.muted),
                      ),
                    ],
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: b.text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已复制提问内容'),
                            duration: Duration(milliseconds: 900),
                          ),
                        );
                      },
                      child: Icon(Icons.copy_rounded, size: 13, color: p.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                if (b.images.isNotEmpty)
                  _buildImageGallery(context, p, b.images),
                if (b.attachments.isNotEmpty)
                  _buildAttachments(context, b),
                if (b.text.isNotEmpty)
                  VibeMarkdownView(data: b.text, baseColor: p.text),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: 10, right: isAssistant ? 8 : 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
        decoration: BoxDecoration(
          color: p.aiCardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.border),
          boxShadow: p.isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.035),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Icon(
                  isAssistant
                      ? Icons.smart_toy_outlined
                      : Icons.terminal_rounded,
                  size: 14,
                  color: p.success,
                ),
                const SizedBox(width: 5),
                Text(
                  isAssistant ? 'AI 回复' : '窗口内容',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: p.success,
                  ),
                ),
                if (b.model.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(5),
                      border:
                          Border.all(color: p.accent.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      b.model,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ),
                ],
                if (b.timestamp.isNotEmpty) ...[
                  const SizedBox(width: 7),
                  Text(
                    b.timestamp,
                    style: TextStyle(fontSize: 10.5, color: p.muted),
                  ),
                ],
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: b.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制该条回复 (Markdown)'),
                        duration: Duration(milliseconds: 900),
                      ),
                    );
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded, size: 12.5, color: p.muted),
                        const SizedBox(width: 3),
                        Text('复制',
                            style: TextStyle(fontSize: 10.5, color: p.muted)),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // Expandable Thinking Process pill & box
            if (b.thinking.trim().isNotEmpty) ...[
              const SizedBox(height: 7),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showThinking = !_showThinking),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: p.panelAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: p.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.psychology_outlined,
                          size: 14, color: p.warning),
                      const SizedBox(width: 5),
                      Text(
                        _showThinking
                            ? '收起思考过程 (${b.thinking.length} 字)'
                            : '展开思考过程 (${b.thinking.length} 字)',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: p.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        _showThinking
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 15,
                        color: p.warning,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showThinking)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: p.panelAlt.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(color: p.warning, width: 2.5),
                    ),
                  ),
                  child: VibeMarkdownView(
                    data: b.thinking,
                    baseFontSize: 12.5,
                    baseColor: p.muted,
                  ),
                ),
            ],

            // Expandable Tool Calls pill & list
            if (b.toolCalls.isNotEmpty) ...[
              const SizedBox(height: 6),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showTools = !_showTools),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                  decoration: BoxDecoration(
                    color: p.panelAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: p.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.build_circle_outlined,
                          size: 13.5, color: p.accent),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _showTools
                              ? '收起工具调用 (${b.toolCalls.length} 项)'
                              : '工具调用 ${b.toolCalls.length} 项: ${b.toolCalls.take(2).join(' · ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: p.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        _showTools
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 14,
                        color: p.accent,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showTools)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: b.toolCalls
                        .map(
                          (tc) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: p.panelAlt,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: p.border),
                            ),
                            child: Text(
                              tc,
                              style: TextStyle(
                                fontSize: 11,
                                color: p.muted,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],

            // Expandable File Diff & Shell Command Cards
            if (b.diffItems.isNotEmpty) ...[
              const SizedBox(height: 6),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showDiffs = !_showDiffs),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
                  decoration: BoxDecoration(
                    color: p.panelAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: p.success.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.difference_outlined,
                          size: 13.5, color: p.success),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _showDiffs
                              ? '收起代码变更与命令 (${b.diffItems.length} 项)'
                              : '代码 Diff 与命令 (${b.diffItems.length} 项): ${b.diffItems.take(2).map((d) => '${d.filePath} ${d.summary}').join(' · ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: p.success,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        _showDiffs
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 14,
                        color: p.success,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showDiffs)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children:
                        b.diffItems.map((d) => _buildDiffCard(p, d)).toList(),
                  ),
                ),
            ],

            if (b.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildImageGallery(context, p, b.images),
            ],
            if (b.attachments.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildAttachments(context, b),
            ],
            if (b.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              VibeMarkdownView(
                data: b.text,
                baseColor: p.text,
                onRunCode: widget.onRunCode,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAttachments(BuildContext context, DialogBlockItem b) {
    return MediaAttachmentList(
      attachments: b.attachments,
      hostHttpBase: widget.hostHttpBase,
      hostToken: widget.hostToken,
      knownImageUrls: b.images,
      onOpenImage: (url) => _showFullImageDialog(context, url),
    );
  }

  String _resolveImageUrl(String raw) => resolveHostMediaUrl(
        raw,
        hostHttpBase: widget.hostHttpBase,
        hostToken: widget.hostToken,
      );

  void _showFullImageDialog(BuildContext context, String url) {
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
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Material(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: '下载图片',
                      onPressed: () =>
                          downloadAndSaveMediaUrl(ctx, url, openAfter: true),
                      icon: const Icon(Icons.download_rounded,
                          color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageGallery(
    BuildContext context,
    VibePalette p,
    List<String> images,
  ) {
    final urls =
        images.map(_resolveImageUrl).where((u) => u.isNotEmpty).toList();
    if (urls.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: urls.map((url) {
          return GestureDetector(
            onTap: () => _showFullImageDialog(context, url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 148,
                height: 110,
                decoration: BoxDecoration(
                  color: p.panelAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: p.border),
                ),
                child: Image.network(
                  url,
                  width: 148,
                  height: 110,
                  fit: BoxFit.cover,
                  loadingBuilder: (ctx, child, progress) {
                    if (progress == null) return child;
                    return Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: p.accent,
                        ),
                      ),
                    );
                  },
                  errorBuilder: (_, __, ___) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined,
                            size: 22, color: p.muted),
                        const SizedBox(height: 3),
                        Text(
                          '图片加载失败',
                          style: TextStyle(fontSize: 10, color: p.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDiffCard(VibePalette p, DiffChangeItem item) {
    final isCmd = item.kind == 'command';
    final badgeColor =
        isCmd ? p.accent : (item.kind == 'write' ? p.success : p.warning);
    final kindLabel = switch (item.kind) {
      'command' => '终端命令',
      'write' => '写入文件',
      _ => '修改文件',
    };
    final lines = item.diffPreview.split('\n');

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: p.codeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: p.codeHeaderBg,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(7)),
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    kindLabel,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.filePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: p.codeText,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                if (item.summary.isNotEmpty)
                  Text(
                    item.summary,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: badgeColor,
                      fontFamily: 'monospace',
                    ),
                  ),
              ],
            ),
          ),
          if (item.diffPreview.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: lines.map((line) {
                  Color? bg;
                  Color fg = const Color(0xFFCBD5E1);
                  if (line.startsWith('+') && !line.startsWith('+++')) {
                    bg = const Color(0xFF102A1E);
                    fg = const Color(0xFF86EFAC);
                  } else if (line.startsWith('-') && !line.startsWith('---')) {
                    bg = const Color(0xFF2D1219);
                    fg = const Color(0xFFFCA5A5);
                  } else if (line.startsWith('@@') || line.startsWith(r'$ ')) {
                    fg = const Color(0xFF7DD3FC);
                  }
                  return Container(
                    color: bg,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                    child: Text(
                      line,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: fg,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

/// Zero-dependency rich Markdown renderer supporting Light & Dark themes:
/// - Headings (`#`..`######`)
/// - Fenced code blocks (` ```lang `) with copy button and run-in-remote button
/// - Tables (`| a | b |`)
/// - Blockquotes & GitHub alerts (`> [!NOTE]`, `> [!TIP]`, `> [!WARNING]`, etc.)
/// - Task checkboxes (`- [x]`, `- [ ]`), bullet lists, numbered lists
/// - Inline code (`` `code` ``), bold (`**...**`), italic (`*...*`), strikethrough (`~~...~~`), links (`[label](url)`)
class VibeMarkdownView extends StatelessWidget {
  const VibeMarkdownView({
    super.key,
    required this.data,
    this.baseFontSize = 14.0,
    this.baseColor,
    this.onRunCode,
  });

  final String data;
  final double baseFontSize;
  final Color? baseColor;
  final ValueChanged<String>? onRunCode;

  static final RegExp _headerRe = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _hrRe = RegExp(r'^(?:-{3,}|\*{3,}|_{3,})\s*$');
  static final RegExp _taskRe = RegExp(r'^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$');
  static final RegExp _ulRe = RegExp(r'^(\s*)(?:[-*+•])\s+(.*)$');
  static final RegExp _olRe = RegExp(r'^(\s*)(\d+)[.)、]\s+(.*)$');
  static final RegExp _alertTagRe = RegExp(
      r'^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$',
      caseSensitive: false);
  static final RegExp _inlineRe = RegExp(
    r'(`[^`\n]+`)|(\*\*[^*\n]+\*\*|__[^_\n]+__)|(~~[^~\n]+~~)|(\[[^\]\n]+\]\([^)\n]+\))|(\*[^*\n]+\*)',
  );

  @override
  Widget build(BuildContext context) {
    final p = VibeTheme.paletteOf(context);
    final resolvedBase = baseColor ?? p.text;
    final text = data.replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    final lines = text.split('\n');
    final widgets = <Widget>[];
    int i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // 1. Fenced Code Block (``` or ````)
      if (trimmed.startsWith('```')) {
        final fence = trimmed.startsWith('````') ? '````' : '```';
        final lang = trimmed.substring(fence.length).trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith(fence)) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        widgets.add(_buildCodeBlock(context, p, lang, codeLines.join('\n')));
        continue;
      }

      // 2. Horizontal Rule
      if (_hrRe.hasMatch(trimmed)) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: p.border, height: 1),
          ),
        );
        i++;
        continue;
      }

      // 3. Heading (# .. ######)
      final hMatch = _headerRe.firstMatch(trimmed);
      if (hMatch != null) {
        final level = hMatch.group(1)!.length;
        final hText = hMatch.group(2)!.trim();
        widgets.add(_buildHeading(p, level, hText, resolvedBase));
        i++;
        continue;
      }

      // 4. Blockquote / GitHub Alert (> ...)
      if (trimmed.startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          final q = lines[i].trim().substring(1).trimLeft();
          quoteLines.add(q);
          i++;
        }
        widgets.add(_buildBlockquote(p, quoteLines, resolvedBase));
        continue;
      }

      // 5. Markdown Table (| col1 | col2 |)
      if (trimmed.startsWith('|') &&
          trimmed.endsWith('|') &&
          i + 1 < lines.length &&
          lines[i + 1].trim().startsWith('|') &&
          lines[i + 1].contains('---')) {
        final tableLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          tableLines.add(lines[i].trim());
          i++;
        }
        widgets.add(_buildTable(p, tableLines, resolvedBase));
        continue;
      }

      // 6. Task list / Bullet list / Ordered list
      final taskMatch = _taskRe.firstMatch(line);
      if (taskMatch != null) {
        final indent = (taskMatch.group(1)!.length ~/ 2).clamp(0, 4);
        final checked = taskMatch.group(2)!.toLowerCase() == 'x';
        final itemText = taskMatch.group(3)!;
        widgets.add(_buildTaskItem(p, indent, checked, itemText, resolvedBase));
        i++;
        continue;
      }

      final ulMatch = _ulRe.firstMatch(line);
      if (ulMatch != null) {
        final indent = (ulMatch.group(1)!.length ~/ 2).clamp(0, 4);
        final itemText = ulMatch.group(2)!;
        widgets.add(_buildListItem(p, indent, '•', itemText, resolvedBase));
        i++;
        continue;
      }

      final olMatch = _olRe.firstMatch(line);
      if (olMatch != null) {
        final indent = (olMatch.group(1)!.length ~/ 2).clamp(0, 4);
        final numLabel = '${olMatch.group(2)}.';
        final itemText = olMatch.group(3)!;
        widgets
            .add(_buildListItem(p, indent, numLabel, itemText, resolvedBase));
        i++;
        continue;
      }

      // 7. Normal paragraph (merge consecutive plain lines)
      final paraLines = <String>[line];
      i++;
      while (i < lines.length) {
        final next = lines[i];
        final nextTrim = next.trim();
        if (nextTrim.isEmpty ||
            nextTrim.startsWith('```') ||
            nextTrim.startsWith('>') ||
            (nextTrim.startsWith('|') && nextTrim.endsWith('|')) ||
            _hrRe.hasMatch(nextTrim) ||
            _headerRe.hasMatch(nextTrim) ||
            _taskRe.hasMatch(next) ||
            _ulRe.hasMatch(next) ||
            _olRe.hasMatch(next)) {
          break;
        }
        paraLines.add(next);
        i++;
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _buildRichParagraph(p, paraLines.join('\n'),
              color: resolvedBase),
        ),
      );
    }

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widgets,
      ),
    );
  }

  Widget _buildHeading(
      VibePalette p, int level, String text, Color resolvedBase) {
    final size = switch (level) {
      1 => baseFontSize + 4.5,
      2 => baseFontSize + 3.0,
      3 => baseFontSize + 1.6,
      4 => baseFontSize + 0.8,
      _ => baseFontSize,
    };
    final style = TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w700,
      height: 1.4,
      color: p.text,
    );

    return Padding(
      padding: EdgeInsets.only(top: level <= 2 ? 8 : 5, bottom: 5),
      child: Container(
        padding: level <= 2
            ? const EdgeInsets.only(left: 8, bottom: 2)
            : EdgeInsets.zero,
        decoration: level <= 2
            ? BoxDecoration(
                border: Border(
                  left: BorderSide(color: p.accent, width: 3),
                ),
              )
            : null,
        child: Text.rich(
          TextSpan(children: _parseInlineSpans(p, text, style)),
        ),
      ),
    );
  }

  Widget _buildCodeBlock(
      BuildContext context, VibePalette p, String lang, String code) {
    final label = lang.isEmpty ? 'code' : lang;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: p.codeBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: p.codeHeaderBg,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(9)),
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: p.isDark ? p.accent : const Color(0xFF93C5FD),
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                if (onRunCode != null) ...[
                  InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () => onRunCode!(code),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.terminal_rounded,
                              size: 12, color: Color(0xFF4ADE80)),
                          SizedBox(width: 3),
                          Text(
                            '注入远端',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF4ADE80),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已复制 $label 代码块'),
                        duration: const Duration(milliseconds: 900),
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded,
                            size: 12, color: Color(0xFF94A3B8)),
                        SizedBox(width: 3),
                        Text(
                          '复制代码',
                          style: TextStyle(
                              fontSize: 10.5, color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            child: Text(
              code,
              style: TextStyle(
                fontSize: baseFontSize - 1.2,
                height: 1.48,
                color: p.codeText,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockquote(
      VibePalette p, List<String> quoteLines, Color resolvedBase) {
    Color borderColor = p.accent;
    String? badge;
    final bodyLines = List<String>.from(quoteLines);

    if (bodyLines.isNotEmpty) {
      final m = _alertTagRe.firstMatch(bodyLines.first);
      if (m != null) {
        final kind = m.group(1)!.toUpperCase();
        final rest = (m.group(2) ?? '').trim();
        badge = kind;
        borderColor = switch (kind) {
          'TIP' => p.success,
          'WARNING' => p.warning,
          'CAUTION' => p.danger,
          'IMPORTANT' => const Color(0xFFA855F7),
          _ => p.accent,
        };
        if (rest.isNotEmpty) {
          bodyLines[0] = rest;
        } else {
          bodyLines.removeAt(0);
        }
      }
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      decoration: BoxDecoration(
        color: borderColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: borderColor, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (badge != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                badge,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: borderColor,
                ),
              ),
            ),
          if (bodyLines.isNotEmpty)
            _buildRichParagraph(
              p,
              bodyLines.join('\n'),
              color: resolvedBase.withValues(alpha: 0.92),
            ),
        ],
      ),
    );
  }

  Widget _buildTaskItem(
    VibePalette p,
    int indent,
    bool checked,
    String text,
    Color resolvedBase,
  ) {
    return Padding(
      padding: EdgeInsets.only(left: indent * 14.0, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 6),
            child: Icon(
              checked
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 15,
              color: checked ? p.success : p.muted,
            ),
          ),
          Expanded(child: _buildRichParagraph(p, text, color: resolvedBase)),
        ],
      ),
    );
  }

  Widget _buildListItem(
    VibePalette p,
    int indent,
    String marker,
    String text,
    Color resolvedBase,
  ) {
    return Padding(
      padding: EdgeInsets.only(left: indent * 14.0, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: marker.length > 1 ? 22 : 14,
            child: Text(
              marker,
              style: TextStyle(
                fontSize: baseFontSize,
                height: 1.55,
                fontWeight: FontWeight.w700,
                color: p.accent,
              ),
            ),
          ),
          Expanded(child: _buildRichParagraph(p, text, color: resolvedBase)),
        ],
      ),
    );
  }

  Widget _buildTable(
      VibePalette p, List<String> tableLines, Color resolvedBase) {
    List<String> parseRow(String row) {
      var s = row.trim();
      if (s.startsWith('|')) s = s.substring(1);
      if (s.endsWith('|')) s = s.substring(0, s.length - 1);
      return s.split('|').map((c) => c.trim()).toList();
    }

    final rows = <List<String>>[];
    for (int idx = 0; idx < tableLines.length; idx++) {
      if (idx == 1 && tableLines[idx].contains('---')) continue;
      rows.add(parseRow(tableLines[idx]));
    }
    if (rows.isEmpty) return const SizedBox.shrink();

    final colCount =
        rows.fold<int>(1, (maxC, r) => r.length > maxC ? r.length : maxC);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(
            horizontalInside: BorderSide(color: p.border, width: 0.8),
            verticalInside: BorderSide(color: p.border, width: 0.8),
          ),
          children: List.generate(rows.length, (rIdx) {
            final row = rows[rIdx];
            final isHeader = rIdx == 0;
            return TableRow(
              decoration: isHeader ? BoxDecoration(color: p.panelAlt) : null,
              children: List.generate(colCount, (cIdx) {
                final cell = cIdx < row.length ? row[cIdx] : '';
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: _buildRichParagraph(
                    p,
                    cell,
                    fontSize: baseFontSize - 1.2,
                    color: resolvedBase,
                    fontWeight: isHeader ? FontWeight.w700 : FontWeight.w400,
                  ),
                );
              }),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildRichParagraph(
    VibePalette p,
    String text, {
    double? fontSize,
    Color? color,
    FontWeight? fontWeight,
  }) {
    final baseStyle = TextStyle(
      fontSize: fontSize ?? baseFontSize,
      height: 1.56,
      color: color ?? baseColor ?? p.text,
      fontWeight: fontWeight ?? FontWeight.w400,
    );
    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: _parseInlineSpans(p, text, baseStyle),
      ),
    );
  }

  List<InlineSpan> _parseInlineSpans(
      VibePalette p, String input, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in _inlineRe.allMatches(input)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: input.substring(lastEnd, match.start)));
      }
      final token = match.group(0)!;

      if (token.startsWith('`') && token.endsWith('`') && token.length >= 2) {
        final code = token.substring(1, token.length - 1);
        spans.add(
          TextSpan(
            text: ' $code ',
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              fontSize: (baseStyle.fontSize ?? 14) - 1.0,
              color: p.inlineCodeText,
              backgroundColor: p.inlineCodeBg,
            ),
          ),
        );
      } else if ((token.startsWith('**') && token.endsWith('**')) ||
          (token.startsWith('__') && token.endsWith('__'))) {
        final inner = token.substring(2, token.length - 2);
        final boldStyle = baseStyle.copyWith(
          fontWeight: FontWeight.w700,
          color: baseColor == null ? p.text : baseStyle.color,
        );
        spans.add(
          TextSpan(
            style: boldStyle,
            children: _parseInlineSpans(p, inner, boldStyle),
          ),
        );
      } else if (token.startsWith('~~') && token.endsWith('~~')) {
        final inner = token.substring(2, token.length - 2);
        spans.add(
          TextSpan(
            text: inner,
            style: baseStyle.copyWith(
              decoration: TextDecoration.lineThrough,
              color: p.muted,
            ),
          ),
        );
      } else if (token.startsWith('[') && token.contains('](')) {
        final closeBracket = token.indexOf('](');
        final label = token.substring(1, closeBracket);
        spans.add(
          TextSpan(
            text: label,
            style: baseStyle.copyWith(
              color: p.accent,
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      } else if (token.startsWith('*') &&
          token.endsWith('*') &&
          token.length >= 2) {
        final inner = token.substring(1, token.length - 1);
        spans.add(
          TextSpan(
            text: inner,
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else {
        spans.add(TextSpan(text: token));
      }

      lastEnd = match.end;
    }

    if (lastEnd < input.length) {
      spans.add(TextSpan(text: input.substring(lastEnd)));
    }

    return spans;
  }
}
