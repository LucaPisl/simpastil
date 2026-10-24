import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Below this radius a bead is drawn in its small form: nothing finer than a
/// 1.5 dp stroke or a ring with something inside it survives at calendar size.
const double kSmallBeadRadius = 4.0;

/// How one dose is drawn wherever the day is drawn small off Today. The
/// shape carries the meaning, so it reads without colour. Below
/// [kSmallBeadRadius] (calendar days, day lines) each state has a form of its
/// own that stays apart from the others in grayscale:
///
/// * taken: a filled dot;
/// * skipped on purpose: a short bold slash, no dot;
/// * planned, still ahead: a thick hollow ring;
/// * not recorded, its time gone: a broken (dashed) ring, never red and never
///   "missed": nothing says it was missed until a miss is recorded;
/// * recorded as missed: a bold x, no ring;
/// * as needed: a small capsule.
///
/// From [kSmallBeadRadius] up, skipped is a dot with a line through it,
/// missed a ring with a cross inside, and not recorded a faint ring with one
/// gap.
enum DoseBead {
  taken,
  skipped,
  planned,
  unrecorded,
  missed,
  asNeeded;

  /// The bead for a recorded [state]. A pending dose whose time has
  /// [passed] was simply not recorded on this phone; a dose recorded as
  /// missed has a miss on record.
  static DoseBead of(String state, {bool prn = false, bool passed = false}) {
    if (prn) return asNeeded;
    return switch (state) {
      'taken' => taken,
      'skipped' => skipped,
      'missed' => missed,
      _ => passed ? unrecorded : planned,
    };
  }

  /// The colour a bead is drawn in: colour means outcome, never medication.
  /// A planned ring is quiet ink; an as-needed capsule is the brand violet.
  Color colorIn(ThemeData theme) {
    final semantic = theme.extension<AppSemanticColors>();
    final colors = theme.colorScheme;
    return switch (this) {
      taken => semantic?.statusTaken ?? colors.primary,
      skipped => semantic?.statusSkipped ?? colors.secondary,
      planned => colors.onSurfaceVariant,
      unrecorded => semantic?.statusUnrecorded ?? colors.outline,
      missed => semantic?.statusMissed ?? colors.error,
      asNeeded => colors.primary,
    };
  }
}

/// Paints [bead] centred on [c] with radius [r].
///
/// [cut] is the colour behind the bead: it rings the bead so neighbours stay
/// apart, and it is the line through a skipped dot.
void paintDoseBead(
  Canvas canvas,
  Offset c,
  double r,
  DoseBead bead, {
  required Color color,
  required Color cut,
}) {
  if (r <= 0) return;
  canvas.drawCircle(c, r + 1.4, Paint()..color = cut);
  if (r < kSmallBeadRadius) {
    _paintSmallBead(canvas, c, r, bead, color);
    return;
  }
  switch (bead) {
    case DoseBead.taken:
      canvas.drawCircle(c, r, Paint()..color = color);
    case DoseBead.skipped:
      canvas.drawCircle(c, r, Paint()..color = color);
      final d = r * .62;
      canvas.drawLine(
        c + Offset(-d, d),
        c + Offset(d, -d),
        Paint()
          ..color = cut
          ..strokeWidth = math.max(1.2, r * .34)
          ..strokeCap = StrokeCap.round,
      );
    case DoseBead.planned:
      canvas.drawCircle(
        c,
        math.max(r - .7, .5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color,
      );
    case DoseBead.unrecorded:
      // The gap sits at the top, where a stem or a label would meet it.
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: math.max(r - .7, .5)),
        -math.pi / 2 + .55,
        math.pi * 2 - 1.1,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: color.a * .6),
      );
    case DoseBead.missed:
      canvas.drawCircle(
        c,
        math.max(r - .7, .5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color,
      );
      final d = r * .42;
      final cross = Paint()
        ..color = color
        ..strokeWidth = math.max(1.0, r * .3)
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(c + Offset(-d, -d), c + Offset(d, d), cross);
      canvas.drawLine(c + Offset(-d, d), c + Offset(d, -d), cross);
    case DoseBead.asNeeded:
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(-.55);
      final w = r * 1.05, h = r * 2.1;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w, height: h),
          Radius.circular(w / 2),
        ),
        Paint()..color = color,
      );
      canvas.restore();
  }
}

/// The small forms: one bold mark per state, no ring around an x or a slash,
/// so a missed and a skipped bead differ by more than a hairline.
void _paintSmallBead(
  Canvas canvas,
  Offset c,
  double r,
  DoseBead bead,
  Color color,
) {
  final bold = math.max(1.6, r * .62);
  Paint stroke(double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..color = color;
  switch (bead) {
    case DoseBead.taken:
      canvas.drawCircle(c, r, Paint()..color = color);
    case DoseBead.skipped:
      final d = r * .95;
      canvas.drawLine(
        c + Offset(-d, d * .8),
        c + Offset(d, -d * .8),
        stroke(bold),
      );
    case DoseBead.planned:
      canvas.drawCircle(c, math.max(r - bold / 2, .5), stroke(bold * .8));
    case DoseBead.unrecorded:
      // Four arcs with four gaps: a ring that reads as broken, not faint.
      final ring = Rect.fromCircle(
        center: c,
        radius: math.max(r - bold * .4, .5),
      );
      final paint = stroke(math.max(1.4, bold * .75))
        ..strokeCap = StrokeCap.butt;
      const sweep = math.pi / 4;
      for (var k = 0; k < 4; k++) {
        canvas.drawArc(
          ring,
          k * math.pi / 2 + sweep / 2,
          sweep * 1.1,
          false,
          paint,
        );
      }
    case DoseBead.missed:
      final d = r * .85;
      final x = stroke(bold);
      canvas.drawLine(c + Offset(-d, -d), c + Offset(d, d), x);
      canvas.drawLine(c + Offset(-d, d), c + Offset(d, -d), x);
    case DoseBead.asNeeded:
      // Lying flat and thick, so it never reads as the skipped slash.
      final h = r * 1.3;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: r * 2.3, height: h),
          Radius.circular(h / 2),
        ),
        Paint()..color = color,
      );
  }
}

/// The "now" pin: a dot on a short stem standing on the line at [base].
void paintNowPin(
  Canvas canvas,
  Offset base, {
  required Color color,
  double stem = 9,
  double r = 2.6,
}) {
  final top = base.translate(0, -stem);
  canvas.drawLine(
    base.translate(0, 3),
    top,
    Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round,
  );
  canvas.drawCircle(top, r, Paint()..color = color);
}

/// Paints [beads] centred in [size], in order, as one row, or two rows when
/// one is too long; beads shrink only when two rows still do not fit.
///
/// With [tray] the row first gets a rounded well of the [cut] colour, so the
/// beads keep the page behind them on a coloured background.
void paintBeadRow(
  Canvas canvas,
  Size size,
  List<({DoseBead bead, Color color})> beads, {
  required Color cut,
  double radius = 3,
  double gap = 2.6,
  bool tray = false,
}) {
  if (beads.isEmpty || size.isEmpty) return;
  var pitch = radius * 2 + gap;
  var r = radius;
  var perRow = math.max(1, (size.width / pitch).floor());
  var rows = (beads.length / perRow).ceil();
  if (rows > 2 || rows * pitch > size.height + gap) {
    rows = math.min(2, beads.length);
    perRow = (beads.length / rows).ceil();
    pitch = math.min(size.width / perRow, size.height / rows);
    r = math.min(radius, pitch * .36);
  }
  final top = (size.height - rows * pitch) / 2 + pitch / 2;
  if (tray) {
    final widest = math.min(perRow, beads.length) * pitch;
    final well = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: math.min(widest + pitch * .7, size.width + 4),
      height: rows * pitch + pitch * .5,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(well, Radius.circular(math.min(9, pitch))),
      Paint()..color = cut,
    );
  }
  for (var row = 0; row < rows; row++) {
    final from = row * perRow;
    final count = math.min(perRow, beads.length - from);
    final left = (size.width - count * pitch) / 2 + pitch / 2;
    for (var k = 0; k < count; k++) {
      final b = beads[from + k];
      paintDoseBead(
        canvas,
        Offset(left + k * pitch, top + row * pitch),
        r,
        b.bead,
        color: b.color,
        cut: cut,
      );
    }
  }
}
