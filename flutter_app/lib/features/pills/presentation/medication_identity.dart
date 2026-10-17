import 'package:flutter/material.dart';

import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/pill_colors.dart';

/// Shapes a medication mark can take, chosen from the medication's form.
enum MedicationShape { capsule, tablet, drop }

/// Reads a free-text form ("Tablet", "Syrup", "comprimat", ...) into a shape.
/// Anything unrecognised stays a capsule.
MedicationShape medicationShapeOf(String? form) {
  final f = (form ?? '').toLowerCase();
  const tablets = ['tablet', 'pill', 'comprimat', 'pastil', 'drajeu'];
  const drops = [
    'drop',
    'syrup',
    'liquid',
    'solution',
    'sirop',
    'pic',
    'solu',
    'lichid',
  ];
  if (tablets.any(f.contains)) return MedicationShape.tablet;
  if (drops.any(f.contains)) return MedicationShape.drop;
  return MedicationShape.capsule;
}

/// The medication's own colour; when none is set, a stable one from the
/// palette derived from its id so two medications rarely look alike.
Color medicationTint({required String id, required String? color}) {
  final own = tryColorFromHex(color);
  if (own != null) return own;
  return colorFromHex(medicationFallbackHex(id));
}

/// The palette hex a medication without its own colour is drawn in. Display
/// only: it is never written back unless the person picks it.
String medicationFallbackHex(String id) {
  final hash = id.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
  return kPillColors[hash % kPillColors.length].hex;
}

/// A medication's identity mark: its shape (capsule, tablet or drop) in its
/// own colour. Decorative; the name is always printed next to it.
///
/// Colour changes glide and a new shape swaps with a small settle, so a live
/// preview answers each keystroke. Quiet motion shows the final frame.
class MedicationMark extends StatelessWidget {
  const MedicationMark({
    super.key,
    required this.color,
    required this.shape,
    this.size = 58,
  });

  final Color color;
  final MedicationShape shape;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final quiet = AppMotion.quiet(context);
    final duration = quiet ? Duration.zero : AppMotion.standard;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: color),
          duration: duration,
          curve: AppMotion.curve,
          builder: (context, base, _) {
            final tint = base ?? color;
            return AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween(begin: .82, end: 1.0).animate(animation),
                  child: child,
                ),
              ),
              child: CustomPaint(
                key: ValueKey(shape),
                size: Size.square(size),
                painter: MedicationMarkPainter(
                  base: tint,
                  light: Color.lerp(tint, cs.surface, .55)!,
                  outline: Color.lerp(tint, cs.onSurface, .45)!,
                  shape: shape,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Paints [MedicationMark]. Drawn on a 58 dp grid and scaled to the size.
class MedicationMarkPainter extends CustomPainter {
  const MedicationMarkPainter({
    required this.base,
    required this.light,
    required this.outline,
    required this.shape,
  });
  final Color base, light, outline;
  final MedicationShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    final s = size.shortestSide / 58;
    canvas.scale(s);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 / s.clamp(.6, 2.0)
      ..color = outline;
    switch (shape) {
      case MedicationShape.tablet:
        final disc = Rect.fromCircle(center: Offset.zero, radius: 22);
        canvas.drawOval(disc, Paint()..color = base);
        canvas.drawArc(
          disc.deflate(5),
          3.4,
          1.6,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = light,
        );
        canvas.drawOval(disc.deflate(.7), line);
        canvas.drawLine(const Offset(-14, 0), const Offset(14, 0), line);
      case MedicationShape.drop:
        final drop = Path()
          ..moveTo(0, -25)
          ..cubicTo(14, -6, 20, 2, 20, 10)
          ..arcToPoint(
            const Offset(-20, 10),
            radius: const Radius.circular(20),
            clockwise: true,
          )
          ..cubicTo(-20, 2, -14, -6, 0, -25)
          ..close();
        canvas.drawPath(drop, Paint()..color = base);
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(0, 10), radius: 13),
          2.3,
          1.1,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = light,
        );
        canvas.drawPath(drop, line);
      case MedicationShape.capsule:
        canvas.rotate(-.65);
        final body = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 26, height: 50),
          const Radius.circular(13),
        );
        canvas.save();
        canvas.clipRRect(body);
        canvas.drawRect(
          const Rect.fromLTRB(-13, -25, 13, 0),
          Paint()..color = base,
        );
        canvas.drawRect(
          const Rect.fromLTRB(-13, 0, 13, 25),
          Paint()..color = light,
        );
        canvas.restore();
        canvas.drawRRect(body.deflate(.7), line);
        canvas.drawLine(const Offset(-13, 0), const Offset(13, 0), line);
    }
  }

  @override
  bool shouldRepaint(MedicationMarkPainter o) =>
      o.base != base ||
      o.light != light ||
      o.outline != outline ||
      o.shape != shape;
}
