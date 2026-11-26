import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/zoomable_viewport.dart';
import '../connection/connection_controller.dart';
import '../stream/remote_screen_panel.dart';
import '../voice/voice_controller.dart';
import 'native_chat_view.dart';
import 'window_content_controller.dart';

class UnifiedViewerPanel extends ConsumerStatefulWidget {
  const UnifiedViewerPanel({super.key});

  @override
  ConsumerState<UnifiedViewerPanel> createState() => _UnifiedViewerPanelState();
}

class _UnifiedViewerPanelState extends ConsumerState<UnifiedViewerPanel> {
  int _tabIndex = 0; // 0: 对话文本 (UIA/OCR), 1: 静态快照, 2: WebRTC 看屏

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              icon: Icon(Icons.article_outlined, size: 16),
              label: Text('对话/输入框文本'),
            ),
            ButtonSegment(
              value: 1,
              icon: Icon(Icons.photo_camera_outlined, size: 16),
              label: Text('静态快照'),
            ),
            ButtonSegment(
              value: 2,
              icon: Icon(Icons.live_tv_rounded, size: 16),
              label: Text('WebRTC 看屏'),
            ),
          ],
          selected: {_tabIndex},
          onSelectionChanged: (sel) {
            if (sel.isNotEmpty) setState(() => _tabIndex = sel.first);
          },
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: switch (_tabIndex) {
            0 => const _DialogTextReaderTab(),
            1 => const _StaticSnapshotTab(),
            _ => const RemoteScreenPanel(),
          },
        ),
      ],
    );
  }
}

class _DialogTextReaderTab extends ConsumerWidget {
  const _DialogTextReaderTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(windowContentProvider);
    final ctrl = ref.read(windowContentProvider.notifier);
    final connected =
        ref.watch(socketSnapshotProvider).valueOrNull?.isConnected ?? false;
    final content = st.content;

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
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<String>(
                      value: const {'auto', 'transcript', 'uia'}
                              .contains(st.methodMode)
                          ? st.methodMode
                          : 'auto',
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                            value: 'auto', child: Text('智能(会话库+UIA)')),
                        DropdownMenuItem(
                            value: 'transcript', child: Text('仅本地会话库')),
                        DropdownMenuItem(value: 'uia', child: Text('仅 UIA')),
                      ],
                      onChanged: (v) {
                        if (v != null) ctrl.setMethodMode(v);
                      },
                    ),
                    if (content != null)
                      Text(
                        '${content.methodUsed.toUpperCase()} · ${content.elapsedMs}ms',
                        style: const TextStyle(
                          fontSize: 11,
                          color: VibeTheme.success,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      label: const Text('2s自动刷', style: TextStyle(fontSize: 11)),
                      selected: st.autoRefresh,
                      onSelected: connected ? ctrl.setAutoRefresh : null,
                      visualDensity: VisualDensity.compact,
                    ),
                    if (content != null && content.fullText.isNotEmpty)
                      IconButton(
                        tooltip: '复制全部对话文本',
                        icon: const Icon(Icons.copy_all_rounded, size: 18),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: content.fullText));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制对话框文本'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                    FilledButton.icon(
                      onPressed: connected && !st.isLoadingContent
                          ? ctrl.fetchContent
                          : null,
                      icon: st.isLoadingContent
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('抓取文本'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (st.error != null) ...[
              const SizedBox(height: 6),
              Text(
                st.error!,
                style: const TextStyle(fontSize: 12, color: VibeTheme.danger),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: NativeChatView(
                contentState: st,
                connected: connected,
                onPullDraftToInput: (draft) {
                  ref
                      .read(voiceControllerProvider.notifier)
                      .setDraftText(draft);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaticSnapshotTab extends ConsumerWidget {
  const _StaticSnapshotTab();

  Rect _computeImageRect(Size boxSize, double aspectRatio) {
    final boxAspect = boxSize.width / math.max(1.0, boxSize.height);
    if (boxAspect > aspectRatio) {
      final h = boxSize.height;
      final w = h * aspectRatio;
      return Rect.fromLTWH((boxSize.width - w) / 2, 0, w, h);
    } else {
      final w = boxSize.width;
      final h = w / math.max(0.01, aspectRatio);
      return Rect.fromLTWH(0, (boxSize.height - h) / 2, w, h);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(windowContentProvider);
    final ctrl = ref.read(windowContentProvider.notifier);
    final connected =
        ref.watch(socketSnapshotProvider).valueOrNull?.isConnected ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text(
                  '按需单帧快照（点击画面可映射鼠标点击）',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (st.snapshotBytes != null)
                  Text(
                    '${(st.snapshotBytes!.length / 1024).toStringAsFixed(0)}KB · ${st.snapshotElapsedMs}ms',
                    style: const TextStyle(
                        fontSize: 11,
                        color: VibeTheme.success,
                        fontFamily: 'monospace'),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: connected && !st.isLoadingSnapshot
                      ? () => ctrl.fetchSnapshot(mode: 'window')
                      : null,
                  icon: st.isLoadingSnapshot
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt_rounded, size: 16),
                  label: const Text('拍一帧'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  color: const Color(0xFF050811),
                  child: st.snapshotBytes == null
                      ? const Center(
                          child: Text(
                            '点击「拍一帧」拉取单张压缩快照（约 40–100 KB）\n省流量、不掉电，点击图片同样可远程点击目标窗口',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: VibeTheme.muted, fontSize: 12.5),
                          ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final box = Size(
                                constraints.maxWidth, constraints.maxHeight);
                            return ZoomableViewport(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (details) {
                                  final rect = _computeImageRect(
                                      box, st.snapshotAspectRatio);
                                  if (!rect.contains(details.localPosition)) {
                                    return;
                                  }
                                  final xn =
                                      (details.localPosition.dx - rect.left) /
                                          rect.width;
                                  final yn =
                                      (details.localPosition.dy - rect.top) /
                                          rect.height;
                                  ctrl.sendSnapshotClick(xNorm: xn, yNorm: yn);
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
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
