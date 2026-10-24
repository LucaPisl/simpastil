import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/medication/medication_shape.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/pill_colors.dart';
import '../medication_look_provider.dart';

export '../../../core/medication/medication_shape.dart';

/// The shape a medication of free-text [form] is drawn with when no shape was
/// picked for it. See [deriveMedicationShape].
MedicationShape medicationShapeOf(String? form) => deriveMedicationShape(form);

/// The medication's own colour as it is drawn (colours stored by an earlier
/// palette map to their current equivalent); when none is set, a stable one
/// from the palette derived from its id so two medications rarely look alike.
Color medicationTint({required String id, required String? color}) {
  final own = displayColorFromHex(color);
  if (own != null) return own;
  return colorFromHex(medicationFallbackHex(id));
}

/// The palette hex a medication without its own colour is drawn in. Display
/// only: it is never written back unless the person picks it.
String medicationFallbackHex(String id) {
  final hash = id.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
  return kPillColors[hash % kPillColors.length].hex;
}

/// The smallest mark that carries a letter. This is a rule, not an accident:
/// the letter is hidden on every mark under 22 px, because it would be under
/// about 9 dp tall and cannot be read. Such a mark is its shape, colour and
/// pattern alone, which still tell the medications apart, and the name is
/// always printed beside a mark that small. The colour-blind-friendly
/// guidance says the same: the letter is a bonus on marks big enough to read.
const double kImprintMinSize = 22;

/// The smallest mark that carries two letters. A smaller one shows only the
/// first, which is all the room there is.
const double kImprintTwoLetterMinSize = 28;

/// A medication's identity mark: its silhouette in its own colour, with the
/// first letter of its name debossed on it. Decorative; the name is always
/// printed next to it.
///
/// Colour changes glide and a new shape swaps with a small settle, so a live
/// preview answers each keystroke. Quiet motion shows the final frame.
class MedicationMark extends StatelessWidget {
  const MedicationMark({
    super.key,
    required this.color,
    required this.shape,
    this.imprint = '',
    this.size = 58,
  });

  final Color color;
  final MedicationShape shape;

  /// The letter, or two letters, debossed on the pill. Empty draws none.
  final String imprint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final quiet = AppMotion.quiet(context);
    final duration = quiet ? Duration.zero : AppMotion.standard;
    final fontFamily = Theme.of(context).textTheme.labelLarge?.fontFamily;
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
                  outline: pillOutlineColor(tint),
                  shape: shape,
                  imprint: imprint,
                  fontFamily: fontFamily,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A medication's mark, looked up by medication: the shape picked for it (or
/// the one [fallbackShape] derives from its form) and the imprint resolved
/// among the person's medications, so every screen draws the same pill.
///
/// Outside a provider scope, or before the lookup has answered, it draws
/// [fallbackShape] with the first letter of [name].
class PillMark extends StatelessWidget {
  const PillMark({
    super.key,
    required this.pillId,
    required this.name,
    required this.color,
    required this.fallbackShape,
    this.size = 58,
  });

  final String pillId;
  final String name;
  final Color color;
  final MedicationShape fallbackShape;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget mark(MedicationLook? look) => MedicationMark(
      color: color,
      size: size,
      shape: look?.shape ?? fallbackShape,
      imprint: look?.imprint ?? imprintInitial(name),
    );
    // Widget tests (and previews) that draw a mark without an app around it
    // still work: no scope means no lookup.
    var scoped = true;
    try {
      ProviderScope.containerOf(context, listen: false);
    } on Object {
      scoped = false;
    }
    if (!scoped) return mark(null);
    return Consumer(
      builder: (context, ref, _) =>
          mark(ref.watch(medicationLooksProvider).asData?.value[pillId]),
    );
  }
}

/// The ink an imprint is pressed in on a pill of colour [base]: the tint
/// itself taken darker or lighter until it holds at least 3:1 against the
/// pill (WCAG 1.4.11), in whichever direction reaches that with less change.
Color medicationImprintInk(Color base) {
  final baseLuminance = base.computeLuminance();
  double contrast(Color c) {
    final a = baseLuminance + .05, b = c.computeLuminance() + .05;
    return a > b ? a / b : b / a;
  }

  Color? toward(Color target) {
    for (var t = .3; t <= 1.0001; t += .05) {
      final c = Color.lerp(base, target, t)!;
      if (contrast(c) >= 3) return c;
    }
    return null;
  }

  final dark = toward(const Color(0xFF000000));
  final light = toward(const Color(0xFFFFFFFF));
  if (dark != null && light != null) {
    // Both work (mid tones): take the nearer, which keeps the tint's hue.
    return contrast(dark) <= contrast(light) ? dark : light;
  }
  return dark ?? light ?? const Color(0xFF000000);
}

/// Paints [MedicationMark]. Drawn on a 58 dp grid and scaled to the size.
class MedicationMarkPainter extends CustomPainter {
  const MedicationMarkPainter({
    required this.base,
    required this.light,
    required this.outline,
    required this.shape,
    this.imprint = '',
    this.fontFamily,
  });
  final Color base, light, outline;
  final MedicationShape shape;
  final String imprint;
  final String? fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(size.width / 2, size.height / 2);
    final s = size.shortestSide / 58;
    canvas.scale(s);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 / s.clamp(.6, 2.0)
      ..color = outline;
    final fill = Paint()..color = base;
    final gloss = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = light;
    // Where the imprint sits, in the unrotated frame, and how large the
    // pressed letter may be on this silhouette.
    var imprintAt = Offset.zero;
    var letterSize = 1.0;
    switch (shape) {
      case MedicationShape.round:
        final disc = Rect.fromCircle(center: Offset.zero, radius: 22);
        canvas.drawOval(disc, fill);
        canvas.drawArc(disc.deflate(5), 3.4, 1.6, false, gloss);
        canvas.drawOval(disc.deflate(.7), line);
      case MedicationShape.caplet:
        canvas.save();
        canvas.rotate(-.65);
        final body = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 24, height: 50),
          const Radius.circular(9),
        );
        canvas.drawRRect(body, fill);
        canvas.drawLine(const Offset(-6.5, -16), const Offset(-6.5, 8), gloss);
        canvas.drawRRect(body.deflate(.7), line);
        canvas.restore();
        letterSize = .8;
      case MedicationShape.oval:
        final ellipse = Rect.fromCenter(
          center: Offset.zero,
          width: 52,
          height: 34,
        );
        canvas.drawOval(ellipse, fill);
        canvas.drawArc(ellipse.deflate(5), 3.5, 1.4, false, gloss);
        canvas.drawOval(ellipse.deflate(.7), line);
      case MedicationShape.softgel:
        canvas.save();
        canvas.rotate(-.5);
        final ellipse = Rect.fromCenter(
          center: Offset.zero,
          width: 46,
          height: 28,
        );
        canvas.drawOval(ellipse, fill);
        // A soft gel is glossy: a bright sheen on the upper edge.
        canvas.drawOval(
          Rect.fromCenter(center: const Offset(-8, -7), width: 15, height: 5),
          Paint()..color = light,
        );
        canvas.drawOval(ellipse.deflate(.7), line);
        canvas.restore();
        letterSize = .85;
        imprintAt = const Offset(2, 3);
      case MedicationShape.capsule:
        canvas.save();
        canvas.rotate(-.65);
        final body = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 26, height: 50),
          const Radius.circular(13),
        );
        canvas.save();
        canvas.clipRRect(body);
        canvas.drawRect(const Rect.fromLTRB(-13, -25, 13, 0), fill);
        canvas.drawRect(
          const Rect.fromLTRB(-13, 0, 13, 25),
          Paint()..color = light,
        );
        canvas.restore();
        canvas.drawRRect(body.deflate(.7), line);
        canvas.drawLine(const Offset(-13, 0), const Offset(13, 0), line);
        canvas.restore();
        // The letter sits in the coloured half, which the tilt carries up and
        // to the left of the centre.
        imprintAt = Offset(-math.sin(.65) * 12.5, -math.cos(.65) * 12.5);
        letterSize = .7;
      case MedicationShape.triangle:
        final triangle = _roundedPolygon(const [
          Offset(0, -25),
          Offset(24, 18),
          Offset(-24, 18),
        ], 5);
        canvas.drawPath(triangle, fill);
        canvas.drawPath(triangle, line);
        imprintAt = const Offset(0, 6);
        letterSize = .75;
      case MedicationShape.square:
        final square = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 40, height: 40),
          const Radius.circular(8),
        );
        canvas.drawRRect(square, fill);
        canvas.drawLine(const Offset(-14, -14), const Offset(-14, -6), gloss);
        canvas.drawRRect(square.deflate(.7), line);
      case MedicationShape.diamond:
        final diamond = _roundedPolygon(const [
          Offset(0, -27),
          Offset(21, 0),
          Offset(0, 27),
          Offset(-21, 0),
        ], 4);
        canvas.drawPath(diamond, fill);
        canvas.drawPath(diamond, line);
        letterSize = .85;
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
        canvas.drawPath(drop, fill);
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(0, 10), radius: 13),
          2.3,
          1.1,
          false,
          gloss,
        );
        canvas.drawPath(drop, line);
        imprintAt = const Offset(0, 9);
        letterSize = .85;
    }
    _paintImprint(canvas, size, imprintAt, letterSize);
  }

  /// A polygon through [corners] with each corner rounded by [radius].
  static Path _roundedPolygon(List<Offset> corners, double radius) {
    final path = Path();
    final n = corners.length;
    for (var i = 0; i < n; i++) {
      final prev = corners[(i + n - 1) % n];
      final at = corners[i];
      final next = corners[(i + 1) % n];
      final toPrev = (prev - at) / (prev - at).distance;
      final toNext = (next - at) / (next - at).distance;
      final start = at + toPrev * radius;
      final end = at + toNext * radius;
      if (i == 0) {
        path.moveTo(start.dx, start.dy);
      } else {
        path.lineTo(start.dx, start.dy);
      }
      path.quadraticBezierTo(at.dx, at.dy, end.dx, end.dy);
    }
    return path..close();
  }

  /// Debosses the imprint: a faint light edge below the letter, then the
  /// letter in a darker or lighter tint of the pill's own colour.
  void _paintImprint(Canvas canvas, Size size, Offset at, double fit) {
    var text = imprint.characters.take(2).toString();
    final px = size.shortestSide;
    if (text.isEmpty || px < kImprintMinSize) return;
    if (text.characters.length > 1 && px < kImprintTwoLetterMinSize) {
      text = text.characters.first;
    }
    final two = text.characters.length > 1;
    final fontSize = (two ? 17.0 : 23.0) * fit;
    TextPainter glyphs(Color color) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final ink = glyphs(medicationImprintInk(base));
    final centre = at - Offset(ink.width / 2, ink.height / 2);
    // The edge catches the light just below the pressed letter. It is only
    // worth its blur when the mark is big enough to show it.
    if (px >= 40) {
      glyphs(
        const Color(0xFFFFFFFF).withValues(alpha: .55),
      ).paint(canvas, centre + const Offset(0, .9));
    }
    ink.paint(canvas, centre);
  }

  @override
  bool shouldRepaint(MedicationMarkPainter o) =>
      o.base != base ||
      o.light != light ||
      o.outline != outline ||
      o.shape != shape ||
      o.imprint != imprint ||
      o.fontFamily != fontFamily;
}
