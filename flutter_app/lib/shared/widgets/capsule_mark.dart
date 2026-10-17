import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/focus_tokens.dart';

/// The familiar capsule keeps its two dots and two dashes at every scale.
///
/// [progress] morphs the capsule into its recorded state: the dots and dashes
/// fold away, the two halves click shut (a 2° settle) and an upright check is
/// drawn on in the taken colour. `0` is the brand mark, `1` is "taken". The
/// mark is decorative; the recorded state is always also said in words.
class CapsuleMark extends StatelessWidget {
  const CapsuleMark({super.key, this.size = 56, this.progress = 0});
  final double size;
  final double progress;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.brightness == Brightness.light
        ? FocusTokens.violet
        : colors.primary;
    final done =
        theme.extension<AppSemanticColors>()?.statusTaken ?? colors.primary;
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: CapsuleMarkPainter(
          progress: progress,
          fill: colors.primaryContainer,
          accent: accent,
          done: done,
        ),
      ),
    );
  }
}

/// Paints [CapsuleMark]; public so scene and hero code can reuse one drawing.
class CapsuleMarkPainter extends CustomPainter {
  const CapsuleMarkPainter({
    required this.progress,
    required this.fill,
    required this.accent,
    required this.done,
  });

  final double progress;
  final Color fill;
  final Color accent;
  final Color done;

  static const _tilt = -.55;
  static const _click = 2 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final p = progress.clamp(0.0, 1.0);
    // The halves part a hair and click shut while the mark changes state.
    final pulse = math.sin(math.pi * Curves.easeOut.transform(p));
    final gap = s * .03 * pulse;
    final body = Rect.fromCenter(
      center: Offset.zero,
      width: s * .58,
      height: s * .9,
    );
    final rrect = RRect.fromRectAndRadius(body, Radius.circular(s));
    final fillPaint = Paint()
      ..color = Color.lerp(
        fill,
        Color.alphaBlend(done.withValues(alpha: .2), fill),
        p,
      )!;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..color = Color.lerp(accent, done, p)!;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(_tilt + _click * pulse);
    for (final half in [-1.0, 1.0]) {
      canvas.save();
      canvas.translate(0, half * gap);
      canvas.clipRect(
        half < 0 ? Rect.fromLTRB(-s, -s, s, 0) : Rect.fromLTRB(-s, 0, s, s),
      );
      canvas.drawRRect(rrect, fillPaint);
      canvas.drawRRect(rrect.deflate(stroke.strokeWidth / 2), stroke);
      canvas.restore();
    }

    // Dots and dashes fold toward the seam during the first half.
    final marks = (1 - p * 2).clamp(0.0, 1.0);
    if (marks > 0) {
      final ink = Paint()..color = accent.withValues(alpha: accent.a * marks);
      final fold = .6 + .4 * marks;
      for (final row in [-1.0, 1.0]) {
        final y = row * s * .0975 * fold;
        canvas.drawCircle(Offset(-s * .1075, y), s * .0325 * fold, ink);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(s * .06, y),
              width: s * .16 * fold,
              height: s * .06 * fold,
            ),
            Radius.circular(s),
          ),
          ink,
        );
      }
    }
    canvas.restore();

    // The check is drawn upright, on in the second half.
    final draw = ((p - .3) / .7).clamp(0.0, 1.0);
    if (draw > 0) {
      canvas.save();
      canvas.translate(size.width / 2, size.height / 2);
      final check = Path()
        ..moveTo(-s * .15, s * .01)
        ..lineTo(-s * .045, s * .11)
        ..lineTo(s * .155, -s * .1);
      final metrics = check.computeMetrics().toList();
      final total = metrics.fold<double>(0, (sum, m) => sum + m.length);
      var remaining = total * Curves.easeInOut.transform(draw);
      final visible = Path();
      for (final PathMetric metric in metrics) {
        if (remaining <= 0) break;
        visible.addPath(
          metric.extractPath(0, math.min(remaining, metric.length)),
          Offset.zero,
        );
        remaining -= metric.length;
      }
      canvas.drawPath(
        visible,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.7, s * .085)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = done,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(CapsuleMarkPainter old) =>
      old.progress != progress ||
      old.fill != fill ||
      old.accent != accent ||
      old.done != done;
}
