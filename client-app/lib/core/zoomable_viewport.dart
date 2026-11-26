import 'package:flutter/material.dart';

import 'theme.dart';

/// Reusable pinch-to-zoom, drag-to-pan, and floating +/-/1x reset viewport wrapper.
///
/// Placing pointer/tap GestureDetectors inside [child] ensures Flutter automatically
/// inverse-transforms tap coordinates into unzoomed space so remote click mapping stays
/// pixel-accurate at any zoom level.
class ZoomableViewport extends StatefulWidget {
  const ZoomableViewport({
    super.key,
    required this.child,
    this.minScale = 1.0,
    this.maxScale = 6.0,
    this.showControls = true,
  });

  final Widget child;
  final double minScale;
  final double maxScale;
  final bool showControls;

  @override
  State<ZoomableViewport> createState() => _ZoomableViewportState();
}

class _ZoomableViewportState extends State<ZoomableViewport> {
  final TransformationController _ctrl = TransformationController();
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTransformChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final next = _ctrl.value.getMaxScaleOnAxis();
    if ((next - _scale).abs() > 0.02) {
      setState(() => _scale = next);
    }
  }

  void _applyScale(double targetScale, Size viewportSize) {
    final clamped = targetScale.clamp(widget.minScale, widget.maxScale);
    if (clamped <= widget.minScale + 0.01) {
      _ctrl.value = Matrix4.identity();
      return;
    }

    final current = _ctrl.value;
    final oldScale = current.getMaxScaleOnAxis().clamp(0.01, 100.0);
    final oldTx = current.storage[12];
    final oldTy = current.storage[13];

    // Zoom smoothly around viewport center
    final cx = viewportSize.width / 2;
    final cy = viewportSize.height / 2;
    final contentX = (cx - oldTx) / oldScale;
    final contentY = (cy - oldTy) / oldScale;

    var nextTx = cx - contentX * clamped;
    var nextTy = cy - contentY * clamped;

    // Clamp translation so content never drifts outside viewport bounds
    final minTx = viewportSize.width - viewportSize.width * clamped;
    final minTy = viewportSize.height - viewportSize.height * clamped;
    nextTx = nextTx.clamp(minTx, 0.0);
    nextTy = nextTy.clamp(minTy, 0.0);

    final m = Matrix4.diagonal3Values(clamped, clamped, 1.0)
      ..setTranslationRaw(nextTx, nextTy, 0.0);
    _ctrl.value = m;
  }

  void _resetZoom() {
    _ctrl.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              transformationController: _ctrl,
              minScale: widget.minScale,
              maxScale: widget.maxScale,
              panEnabled: _scale > 1.01,
              scaleEnabled: true,
              boundaryMargin: EdgeInsets.zero,
              child: SizedBox(
                width: viewportSize.width,
                height: viewportSize.height,
                child: widget.child,
              ),
            ),
            if (widget.showControls)
              Positioned(
                right: 8,
                bottom: 8,
                child: Material(
                  color: VibeTheme.panel.withOpacity(0.86),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: VibeTheme.border),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _zoomBtn(
                          icon: Icons.remove_rounded,
                          tooltip: '缩小',
                          onTap: _scale > widget.minScale + 0.01
                              ? () => _applyScale(_scale / 1.45, viewportSize)
                              : null,
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: _scale > 1.01 ? _resetZoom : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 5),
                            child: Text(
                              '${_scale.toStringAsFixed(1)}×',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                                color: _scale > 1.01
                                    ? VibeTheme.accent
                                    : VibeTheme.muted,
                              ),
                            ),
                          ),
                        ),
                        _zoomBtn(
                          icon: Icons.add_rounded,
                          tooltip: '放大',
                          onTap: _scale < widget.maxScale - 0.05
                              ? () => _applyScale(_scale * 1.45, viewportSize)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _zoomBtn({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 16,
            color: onTap == null ? VibeTheme.muted.withOpacity(0.4) : VibeTheme.text,
          ),
        ),
      ),
    );
  }
}
