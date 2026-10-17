import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/motion/app_motion.dart';

/// One day's compartment of a weekly pill box, small enough to sit in a
/// chip. A day that is picked has its lid open with a capsule inside; the
/// rest stay shut. Changing a day swings the lid and fades the capsule in
/// [duration], at once in quiet mode. Nothing runs at rest.
class DayLid extends StatelessWidget {
  const DayLid({super.key, required this.open, this.size = 18});

  final bool open;
  final double size;

  static const duration = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: open ? 1 : 0),
        duration: AppMotion.quiet(context) ? Duration.zero : duration,
        curve: Curves.easeOut,
        builder: (context, t, _) => CustomPaint(
          size: Size.square(size),
          painter: DayLidPainter(
            open: t,
            box: Color.lerp(cs.onSurfaceVariant, cs.onSecondaryContainer, t)!,
            capsule: cs.primary,
          ),
        ),
      ),
    );
  }
}

class DayLidPainter extends CustomPainter {
  DayLidPainter({required this.open, required this.box, required this.capsule});

  /// 0 shut and empty, 1 open with a capsule inside.
  final double open;
  final Color box, capsule;

  /// How far the lid swings back on its hinge when open.
  static const swing = 42 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.shortestSide / 18;
    canvas.save();
    canvas.scale(u);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round
      ..color = box;

    // The compartment, open at the top.
    final cell = RRect.fromLTRBR(3, 9, 15, 17, const Radius.circular(2.5));
    canvas.drawRRect(cell, line);

    if (open > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(6, 11.6, 12, 14.8, const Radius.circular(1.6)),
        Paint()..color = capsule.withValues(alpha: capsule.a * open),
      );
    }

    // The lid, hinged at the back-left corner.
    canvas.translate(3, 8.4);
    canvas.rotate(-swing * open);
    canvas.drawRRect(
      RRect.fromLTRBR(0, -1.6, 12, 0, const Radius.circular(.8)),
      Paint()..color = box,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(DayLidPainter old) =>
      old.open != open || old.box != box || old.capsule != capsule;
}
