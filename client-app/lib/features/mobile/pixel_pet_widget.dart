import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 12x12 animated pixel-art walking pet matching Android's `IslandPetView.kt`.
///
/// Supports [petType]: `'shiba'` | `'cat'` | `'bot'`
/// Supports [status]:  `'working'` | `'waiting_approval'` | `'question'` | `'idle'` | `'done'` | `'disconnected'`
class PixelPetView extends StatefulWidget {
  const PixelPetView({
    super.key,
    required this.petType,
    required this.status,
  });

  final String petType;
  final String status;

  @override
  State<PixelPetView> createState() => _PixelPetViewState();
}

class _PixelPetViewState extends State<PixelPetView> {
  Timer? _timer;
  int _frameIndex = 0;
  int _pauseTicks = 0;
  double _walkPos = 0.15;
  int _walkDir = 1;

  @override
  void initState() {
    super.initState();
    _scheduleNextTick();
  }

  @override
  void didUpdateWidget(covariant PixelPetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _timer?.cancel();
      _scheduleNextTick();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration _tickDuration() {
    return switch (widget.status) {
      'working' => const Duration(milliseconds: 130),
      'waiting_approval' || 'question' => const Duration(milliseconds: 170),
      'disconnected' => const Duration(milliseconds: 500),
      _ => const Duration(milliseconds: 260),
    };
  }

  void _scheduleNextTick() {
    _timer = Timer(_tickDuration(), _onTick);
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {
      _frameIndex = (_frameIndex + 1) % 8;
      final step = switch (widget.status) {
        'working' => 0.08,
        'waiting_approval' || 'question' => 0.06,
        'disconnected' => 0.0,
        _ => 0.03,
      };
      if (step > 0) {
        if (_pauseTicks > 0) {
          _pauseTicks--;
        } else {
          _walkPos += step * _walkDir;
          if (_walkPos >= 1.0) {
            _walkPos = 1.0;
            _walkDir = -1;
            if (widget.status == 'idle' || widget.status == 'done') {
              _pauseTicks = 3;
            }
          } else if (_walkPos <= 0.0) {
            _walkPos = 0.0;
            _walkDir = 1;
            if (widget.status == 'idle' || widget.status == 'done') {
              _pauseTicks = 3;
            }
          }
        }
      }
    });
    _scheduleNextTick();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PixelPetPainter(
        petType: widget.petType,
        status: widget.status,
        frameIndex: _frameIndex,
        walkPos: _walkPos,
        walkDir: _walkDir,
      ),
    );
  }
}

class _PixelPetPainter extends CustomPainter {
  const _PixelPetPainter({
    required this.petType,
    required this.status,
    required this.frameIndex,
    required this.walkPos,
    required this.walkDir,
  });

  final String petType;
  final String status;
  final int frameIndex;
  final double walkPos;
  final int walkDir;

  String get _normPet =>
      (petType == 'cat' || petType == 'bot') ? petType : 'shiba';

  @override
  void paint(Canvas canvas, Size size) {
    final petSize = math.min(size.width, size.height);
    if (petSize <= 0) return;

    final cell = petSize / 12.0;
    final travel = math.max(0.0, size.width - petSize);
    final left = walkPos * travel;
    final top = (size.height - petSize) / 2.0;

    final sprite = switch (_normPet) {
      'cat' => _catRows(),
      'bot' => _botRows(),
      _ => _shibaRows(),
    };

    final yShift = switch (status) {
      'working' => (frameIndex % 2 == 1) ? -0.5 * cell : 0.0,
      'waiting_approval' || 'question' =>
        (frameIndex % 4 == 1) ? -0.7 * cell : 0.0,
      _ => 0.0,
    };

    final dim = status == 'disconnected';
    final paint = Paint()
      ..isAntiAlias = false
      ..style = PaintingStyle.fill;

    canvas.save();
    if (walkDir < 0) {
      final centerX = left + petSize / 2.0;
      canvas.translate(centerX, 0);
      canvas.scale(-1.0, 1.0);
      canvas.translate(-centerX, 0);
    }

    final maxRows = math.min(12, sprite.length);
    for (int r = 0; r < maxRows; r++) {
      final row = sprite[r];
      final maxCols = math.min(12, row.length);
      for (int c = 0; c < maxCols; c++) {
        final ch = row[c];
        if (ch == '.') continue;
        final color = _resolveColor(ch, dim);
        if (color == null) continue;
        paint.color = color;
        final x0 = left + c * cell;
        final y0 = (top + r * cell + yShift).clamp(0.0, size.height);
        final y1 = math.min(size.height, y0 + cell + 0.4);
        canvas.drawRect(
          Rect.fromLTRB(x0, y0, x0 + cell + 0.4, y1),
          paint,
        );
      }
    }
    canvas.restore();

    _drawStatusBadge(canvas, size, paint, left, top, cell);
  }

  void _drawStatusBadge(
    Canvas canvas,
    Size size,
    Paint paint,
    double left,
    double top,
    double cell,
  ) {
    switch (status) {
      case 'working':
        paint.color = (frameIndex % 2 == 0)
            ? const Color(0xFF38BDF8)
            : const Color(0xFF60A5FA);
        final sx = (frameIndex % 2 == 0) ? 10.0 : 9.0;
        final sy = (frameIndex % 4 < 2) ? 1.0 : 2.0;
        canvas.drawRect(
          Rect.fromLTWH(
            left + sx * cell,
            top + sy * cell,
            1.5 * cell,
            1.5 * cell,
          ),
          paint,
        );
        break;
      case 'waiting_approval':
        if (frameIndex % 2 == 0) {
          paint.color = const Color(0xFFF59E0B);
          canvas.drawRect(
            Rect.fromLTRB(
              left + 10 * cell,
              top + 0.5 * cell,
              left + 11.4 * cell,
              top + 3.2 * cell,
            ),
            paint,
          );
          canvas.drawRect(
            Rect.fromLTRB(
              left + 10 * cell,
              top + 4 * cell,
              left + 11.4 * cell,
              top + 5.2 * cell,
            ),
            paint,
          );
        }
        break;
      case 'question':
        final dy = (frameIndex % 2 == 0) ? 0.0 : -0.4 * cell;
        paint.color = const Color(0xFFFBBF24);
        canvas.drawRect(
          Rect.fromLTRB(
            left + 9.5 * cell,
            math.max(0.0, top + 0.5 * cell + dy),
            left + 11.5 * cell,
            top + 2.2 * cell + dy,
          ),
          paint,
        );
        canvas.drawRect(
          Rect.fromLTRB(
            left + 10 * cell,
            top + 3 * cell + dy,
            left + 11.2 * cell,
            top + 4.2 * cell + dy,
          ),
          paint,
        );
        break;
      case 'idle':
      case 'done':
        if (frameIndex % 4 < 3) {
          paint.color = const Color(0xFF34D399);
          final rise = (frameIndex % 3) * 0.45 * cell;
          canvas.drawRect(
            Rect.fromLTRB(
              left + 9.8 * cell,
              math.max(0.0, top + 2.0 * cell - rise),
              left + 11.4 * cell,
              math.max(0.4 * cell, top + 3.2 * cell - rise),
            ),
            paint,
          );
        }
        break;
    }
  }

  Color? _resolveColor(String ch, bool dim) {
    final Color? raw = switch (_normPet) {
      'cat' => switch (ch) {
          'K' => const Color(0xFF3B4254),
          'D' => const Color(0xFF232836),
          'E' => const Color(0xFFFACC15),
          'P' => const Color(0xFFF472B6),
          'W' => const Color(0xFFE2E8F0),
          _ => null,
        },
      'bot' => switch (ch) {
          'M' => const Color(0xFF94A3B8),
          'L' => const Color(0xFFCBD5E1),
          'S' => const Color(0xFF1E293B),
          'C' => switch (status) {
              'waiting_approval' || 'question' => const Color(0xFFF59E0B),
              'disconnected' => const Color(0xFF64748B),
              _ => const Color(0xFF38BDF8),
            },
          'A' => (status == 'working' && frameIndex % 2 == 0)
              ? const Color(0xFF22D3EE)
              : const Color(0xFFF59E0B),
          _ => null,
        },
      _ => switch (ch) {
          'O' => const Color(0xFFE59A3C),
          'B' => const Color(0xFF8A4B18),
          'C' => const Color(0xFFFFF3D6),
          'E' => const Color(0xFF1E1B18),
          'P' => const Color(0xFFF472B6),
          _ => null,
        },
    };
    if (raw == null || !dim) return raw;
    return Color.fromARGB(
      255,
      ((raw.r * 255.0) * 0.45).round(),
      ((raw.g * 255.0) * 0.45).round(),
      ((raw.b * 255.0) * 0.45).round(),
    );
  }

  List<String> _shibaRows() {
    final blink = (status == 'idle' || status == 'done') && frameIndex % 8 == 7;
    final wagLeft = frameIndex % 4 < 2;
    final working = status == 'working';
    final eye = blink ? 'B' : 'E';
    final tailRow6 = wagLeft ? '..BBBBBBBB..' : '...BBBBBBBO.';
    final tailRow7 = wagLeft ? '.BOOOOOOOB..' : '..OOOOOOOOB.';
    final pawRow = (working && frameIndex % 2 == 1)
        ? '..C.CCCC.C..'
        : '..CC....CC..';
    return [
      '............',
      '..BB....BB..',
      '..BOOOOOOB..',
      '.BOOOOOOOOB.',
      '.BOO${eye}OO${eye}OOB.',
      '.BOCECCCOOB.',
      tailRow6,
      tailRow7,
      '..OOCCCCOO..',
      '..OOOOOOOO..',
      pawRow,
      '............',
    ];
  }

  List<String> _catRows() {
    final blink = (status == 'idle' || status == 'done') && frameIndex % 8 == 7;
    final tailUp = frameIndex % 2 == 0;
    final eye = blink ? 'K' : 'E';
    final tailA = tailUp ? 'KKKKKKKKKK.K' : 'KKKKKKKKKK..';
    final tailB = tailUp ? '.KDDDDDDK.K.' : '.KDDDDDDKKK.';
    final pawRow = (status == 'working' && frameIndex % 2 == 1)
        ? '..W.KKKK.W..'
        : '..KK....WW..';
    return [
      '............',
      '..KP....PK..',
      '..KKKKKKKK..',
      '.KKKKKKKKKK.',
      '.KK${eye}KKKK${eye}KK.',
      '.KKKKPPKKKK.',
      tailA,
      tailB,
      '..KKKKKKKK..',
      '..KKKKKKKK..',
      pawRow,
      '............',
    ];
  }

  List<String> _botRows() {
    final blink = frameIndex % 6 == 5 && status != 'working';
    final visorEye = blink ? 'S' : 'C';
    final antRow = (frameIndex % 2 == 0) ? '.....AA.....' : '.....MM.....';
    final footRow = (status == 'working' && frameIndex % 2 == 1)
        ? '..M......M..'
        : '...MM..MM...';
    return [
      antRow,
      '.....MM.....',
      '..LLLLLLLL..',
      '.LMMMMMMMMM.',
      '.LMSSSSSSSM.',
      '.LMS${visorEye}SSS${visorEye}SM.',
      '.LMSSSSSSSM.',
      '..LLLLLLLL..',
      '..MMMMMMMM..',
      '..MMCCCCMM..',
      footRow,
      '............',
    ];
  }

  @override
  bool shouldRepaint(covariant _PixelPetPainter oldDelegate) {
    return oldDelegate.petType != petType ||
        oldDelegate.status != status ||
        oldDelegate.frameIndex != frameIndex ||
        oldDelegate.walkPos != walkPos ||
        oldDelegate.walkDir != walkDir;
  }
}
