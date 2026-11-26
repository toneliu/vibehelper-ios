import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/theme.dart';
import '../../core/zoomable_viewport.dart';
import '../connection/connection_controller.dart';
import 'webrtc_stream_controller.dart';

class RemoteScreenPanel extends ConsumerWidget {
  const RemoteScreenPanel({super.key});

  /// Compute the actual rendered video rectangle inside a BoxFit.contain container
  /// so normalized pointer coordinates stay pixel-accurate regardless of aspect ratio.
  Rect _computeVideoRect(Size boxSize, double aspectRatio) {
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

  Offset? _normalize(Offset localPos, Size boxSize, double aspectRatio) {
    final rect = _computeVideoRect(boxSize, aspectRatio);
    if (!rect.contains(localPos)) return null;
    return Offset(
      ((localPos.dx - rect.left) / rect.width).clamp(0.0, 1.0),
      ((localPos.dy - rect.top) / rect.height).clamp(0.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streamState = ref.watch(remoteStreamProvider);
    final streamCtrl = ref.read(remoteStreamProvider.notifier);
    final connected =
        ref.watch(socketSnapshotProvider).valueOrNull?.isConnected ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.live_tv_rounded,
                        size: 18, color: VibeTheme.accent),
                    const SizedBox(width: 6),
                    const Text(
                      '实时画面与控屏',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                    if (streamState.isStreaming) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${streamState.videoWidth}×${streamState.videoHeight} @${streamState.fps}fps',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: VibeTheme.success,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (streamState.isWsVideo)
                      ActionChip(
                        label: Text(
                          '画质: ${streamState.qualityPresetLabel}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: connected
                            ? () => streamCtrl.cycleQualityPreset()
                            : null,
                        visualDensity: VisualDensity.compact,
                      ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'ws_mjpeg', label: Text('WS极速流')),
                        ButtonSegment(value: 'webrtc', label: Text('WebRTC')),
                      ],
                      selected: {streamState.transport},
                      onSelectionChanged: (sel) {
                        if (sel.isNotEmpty) {
                          streamCtrl.setTransport(sel.first);
                        }
                      },
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'window', label: Text('单窗口')),
                        ButtonSegment(value: 'screen', label: Text('全屏')),
                      ],
                      selected: {streamState.mode},
                      onSelectionChanged: (sel) {
                        if (sel.isNotEmpty) streamCtrl.setMode(sel.first);
                      },
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          connected ? streamCtrl.toggleAudioBridge : null,
                      icon: Icon(
                        streamState.audioBridgeActive
                            ? Icons.settings_voice_rounded
                            : Icons.mic_external_on_rounded,
                        size: 16,
                        color: streamState.audioBridgeActive
                            ? VibeTheme.danger
                            : null,
                      ),
                      label: Text(
                        streamState.audioBridgeActive ? '虚拟麦: 开' : '虚拟麦',
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    if (streamState.isStreaming ||
                        streamState.phase == StreamPhase.starting)
                      FilledButton.tonalIcon(
                        onPressed: streamCtrl.stopStream,
                        icon: const Icon(Icons.stop_rounded, size: 16),
                        label: const Text('停止'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: VibeTheme.danger.withOpacity(0.22),
                          foregroundColor: VibeTheme.danger,
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: connected ? streamCtrl.startStream : null,
                        icon: const Icon(Icons.play_arrow_rounded, size: 16),
                        label: const Text('看屏'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            if (streamState.error != null) ...[
              const SizedBox(height: 6),
              Text(
                streamState.error!,
                style: const TextStyle(fontSize: 12, color: VibeTheme.danger),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  color: const Color(0xFF050811),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final boxSize =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return ZoomableViewport(
                        showControls: streamState.isVideoStreaming,
                        child: Listener(
                          onPointerSignal: (PointerSignalEvent event) {
                            if (!streamState.isStreaming) return;
                            if (event is PointerScrollEvent) {
                              final pt = _normalize(
                                event.localPosition,
                                boxSize,
                                streamState.aspectRatio,
                              );
                              if (pt != null) {
                                streamCtrl.sendPointer(
                                  action: 'scroll',
                                  xNorm: pt.dx,
                                  yNorm: pt.dy,
                                  deltaX: event.scrollDelta.dx.sign,
                                  deltaY: event.scrollDelta.dy.sign,
                                );
                              }
                            }
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) {
                              if (!streamState.isStreaming) return;
                              final pt = _normalize(
                                details.localPosition,
                                boxSize,
                                streamState.aspectRatio,
                              );
                              if (pt != null) {
                                streamCtrl.sendPointer(
                                  action: 'click',
                                  button: 'left',
                                  xNorm: pt.dx,
                                  yNorm: pt.dy,
                                );
                              }
                            },
                            onDoubleTapDown: (details) {
                              if (!streamState.isStreaming) return;
                              final pt = _normalize(
                                details.localPosition,
                                boxSize,
                                streamState.aspectRatio,
                              );
                              if (pt != null) {
                                streamCtrl.sendPointer(
                                  action: 'double_click',
                                  button: 'left',
                                  xNorm: pt.dx,
                                  yNorm: pt.dy,
                                );
                              }
                            },
                            onSecondaryTapUp: (details) {
                              if (!streamState.isStreaming) return;
                              final pt = _normalize(
                                details.localPosition,
                                boxSize,
                                streamState.aspectRatio,
                              );
                              if (pt != null) {
                                streamCtrl.sendPointer(
                                  action: 'right_click',
                                  button: 'right',
                                  xNorm: pt.dx,
                                  yNorm: pt.dy,
                                );
                              }
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (streamState.isVideoStreaming &&
                                    streamState.isWsVideo &&
                                    streamState.liveFrameBytes != null)
                                  Image.memory(
                                    streamState.liveFrameBytes!,
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                  )
                                else if (streamState.isVideoStreaming &&
                                    !streamState.isWsVideo)
                                  RTCVideoView(
                                    streamCtrl.renderer,
                                    objectFit: RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitContain,
                                    filterQuality: FilterQuality.medium,
                                  )
                                else
                                  Center(
                                    child: Text(
                                      streamState.phase == StreamPhase.starting
                                          ? (streamState.isWsVideo
                                              ? '正在拉取实时画面 (WS 极速流)...'
                                              : '正在建立 WebRTC 低延迟视频通道...')
                                          : '点击右上角「看屏」开启实时画面回传\n支持 WS极速流(穿透NAT/防火墙) 与 WebRTC',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: VibeTheme.muted,
                                        fontSize: 13,
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
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
