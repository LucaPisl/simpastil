import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'horizon_model.dart';

/// Every colour the scene draws with, resolved once from the theme so custom
/// themes, dark mode and high contrast all flow through the same place.
@immutable
class HorizonPalette {
  const HorizonPalette({
    required this.brightness,
    required this.highContrast,
    required this.background,
    required this.ring,
    required this.ringFill,
    required this.mutedRing,
    required this.taken,
    required this.takenOutline,
    required this.celebrate,
    required this.groundTop,
    required this.groundBottom,
    required this.groundBack,
    required this.star,
    required this.tint,
    Color? groundLine,
    Color? moonLit,
    Color? moonDim,
    this.label,
  }) : groundLine = groundLine ?? groundBottom,
       moonLit = moonLit ?? taken,
       moonDim = moonDim ?? ringFill;

  factory HorizonPalette.from({
    required ColorScheme scheme,
    required AppSemanticColors semantic,
    required Color background,
    required bool highContrast,
    TextStyle? label,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    final hsl = HSLColor.fromColor(scheme.tertiary);
    final sat = math.max(hsl.saturation, .26);
    Color sage(double lightness, [double? saturation]) => hsl
        .withSaturation(saturation ?? sat)
        .withLightness(lightness)
        .toColor();
    final customAccent = scheme.primary.toARGB32() != _brandPrimary(dark);
    return HorizonPalette(
      brightness: scheme.brightness,
      highContrast: highContrast,
      background: background,
      ring: scheme.onSurface,
      ringFill: scheme.surface,
      mutedRing: scheme.onSurfaceVariant,
      taken: scheme.primary,
      takenOutline: scheme.surface,
      celebrate: semantic.statusTaken,
      groundTop: dark ? sage(.17, .2) : sage(.88, .22),
      groundBottom: dark ? sage(.15, .2) : sage(.86, .22),
      groundBack: dark ? sage(.14, .16) : sage(.9, .16),
      groundLine: dark ? sage(.3, .2) : sage(.72, .2),
      star: dark ? Colors.white : scheme.primary,
      moonLit: dark
          ? const Color(0xFFEDEBFF)
          : Color.lerp(scheme.primary, scheme.surface, .06)!,
      moonDim: dark
          ? const Color(0xFFEDEBFF).withValues(alpha: .12)
          : Color.lerp(scheme.primary, scheme.surface, .68)!,
      tint: customAccent ? scheme.primary : null,
      label: label,
    );
  }

  /// The default Material 3 primary for the brand seed is not exactly the
  /// seed, so treat "custom" as "differs from the hue family of the seed".
  static int _brandPrimary(bool dark) =>
      (dark ? AppTheme.dark() : AppTheme.light()).colorScheme.primary
          .toARGB32();

  final Brightness brightness;
  final bool highContrast;
  final Color background;
  final Color ring;
  final Color ringFill;
  final Color mutedRing;
  final Color taken;
  final Color takenOutline;
  final Color celebrate;
  final Color groundTop;
  final Color groundBottom;
  final Color groundBack;
  final Color star;

  /// The darker line where the ground meets the sky.
  final Color groundLine;
  final Color moonLit;
  final Color moonDim;

  /// Base style for the stack numeral (the theme's label style).
  final TextStyle? label;

  /// Non-null for a user-chosen primary: the sky leans a little toward it.
  final Color? tint;

  bool get dark => brightness == Brightness.dark;

  @override
  bool operator ==(Object other) =>
      other is HorizonPalette &&
      other.brightness == brightness &&
      other.highContrast == highContrast &&
      other.background == background &&
      other.ring == ring &&
      other.ringFill == ringFill &&
      other.mutedRing == mutedRing &&
      other.taken == taken &&
      other.takenOutline == takenOutline &&
      other.celebrate == celebrate &&
      other.groundTop == groundTop &&
      other.groundBottom == groundBottom &&
      other.groundBack == groundBack &&
      other.groundLine == groundLine &&
      other.star == star &&
      other.moonLit == moonLit &&
      other.moonDim == moonDim &&
      other.label == label &&
      other.tint == tint;

  @override
  int get hashCode => Object.hash(
    brightness,
    highContrast,
    background,
    ring,
    ringFill,
    mutedRing,
    taken,
    takenOutline,
    celebrate,
    groundTop,
    groundBottom,
    groundBack,
    groundLine,
    star,
    moonLit,
    moonDim,
    label,
    tint,
  );

  /// The colour a mark is drawn with, for contrast tests.
  Color markColor(HorizonMarkState state) => switch (state) {
    HorizonMarkState.taken => taken,
    HorizonMarkState.skipped => mutedRing,
    _ => ring,
  };
}

/// Which part of the scene a [HorizonPainter] draws. The scene splits itself
/// in two when the ambient weather is on, so clouds sit between the sky and
/// the bodies: they drift behind the sun, path and dose marks, never over them.
enum HorizonLayer {
  /// Everything, in one pass.
  all,

  /// Sky gradient, stars, horizon glow and haze.
  backdrop,

  /// Sun, moon, ground, path and marks.
  bodies,
}

class HorizonPainter extends CustomPainter {
  HorizonPainter({
    required this.model,
    required this.palette,
    this.scrollOffset,
    this.pull,
    this.entry,
    this.celebrateAnimation,
    this.celebrateId,
    this.heldStars = const {},
    this.scrubX,
    this.breath,
    this.focusedId,
    this.celebrateReach = defaultCelebrateReach,
    this.twinkle = 1,
    this.collapse,
    this.sweepAnimation,
    this.sweepId,
    this.pokeAnimation,
    this.ghostShare,
    this.layer = HorizonLayer.all,
    super.repaint,
  });

  /// 0..1 of the short ripple played when the sun is tapped.
  final Animation<double>? pokeAnimation;

  /// While the sun is being scrubbed: the share of daylight the translucent
  /// ghost sun stands at. The real sun never moves.
  final ValueListenable<double?>? ghostShare;

  /// The part of the scene this painter draws.
  final HorizonLayer layer;

  /// 0..1 progress of the settled-day sweep, played once when the last dose
  /// of the day is durably recorded: the rest of the day path draws solid and
  /// the marks twinkle one after another. Idle at 0 or 1; a settled model then
  /// simply shows the whole path solid.
  final Animation<double>? sweepAnimation;
  final String? sweepId;

  /// Test hook: counts every paint so idle cost can be asserted.
  static int debugPaintCount = 0;

  /// How far the celebration ring travels beyond the mark, in dp.
  static const double defaultCelebrateReach = 46;

  final HorizonModel model;
  final HorizonPalette palette;
  final double Function()? scrollOffset;
  final ValueListenable<double>? pull;
  final Animation<double>? entry;
  final Animation<double>? celebrateAnimation;
  final String? celebrateId;

  /// Doses whose star stays hidden in its mark until their celebration.
  final Set<String> heldStars;
  final ValueListenable<double?>? scrubX;
  final Animation<double>? breath;

  /// The mark the deck is showing. Null points at [HorizonModel.nextMark].
  final String? focusedId;

  /// Reach of the celebration ring beyond the mark.
  final double celebrateReach;

  /// Scale of the celebration twinkle rays; 0 draws none.
  final double twinkle;

  /// How far a collapsing header has folded the scene away, 0..1. The sky
  /// gradient stays; bodies, ground, path and marks fade out by 1.
  final ValueListenable<double>? collapse;

  static const _golden = Color(0xFFFFC27A);
  static const _rose = Color(0xFFFFA283);
  static const _paleSun = Color(0xFFFFE7B3);
  static const _paleDawnSun = Color(0xFFFFD6BC);

  @override
  void paint(Canvas canvas, Size size) {
    debugPaintCount++;
    final e = Curves.easeOutCubic.transform(entry?.value ?? 1);
    final scroll = (scrollOffset?.call() ?? 0).clamp(0.0, 600.0);
    final pullValue = (pull?.value ?? 0).clamp(0.0, 1.4);
    final dayShift = -scroll * .4 + pullValue * 16;
    // Pulling lowers the sun toward the horizon; the ground sags with it.
    final sunShift = -scroll * .2 + 12 * (1 - e) + pullValue * 20;
    final hc = palette.highContrast;

    // Sky.
    final horizonY = model.horizonY;
    final skyRect = Rect.fromLTRB(0, -400, size.width, size.height + 400);
    if (layer == HorizonLayer.bodies) {
      // Backdrop is another painter's job.
    } else if (hc) {
      canvas.drawRect(skyRect, Paint()..color = palette.background);
    } else {
      final stops = _tinted(model.skyStops);
      canvas.save();
      canvas.translate(0, -scroll * .4);
      canvas.drawRect(
        skyRect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(0, horizonY),
            stops,
            HorizonModel.skyStopPositions,
          ),
      );
      canvas.restore();
      _paintStars(canvas, size, -scroll * .4);
      _paintHorizonGlow(canvas, size, dayShift);
      _paintHaze(canvas, size, dayShift, -scroll * .3);
      _paintPullWarmth(canvas, size, pullValue.clamp(0.0, 1.0));
    }

    if (layer == HorizonLayer.backdrop) return;
    final fold = (collapse?.value ?? 0).clamp(0.0, 1.0);
    if (fold >= 1) return;
    if (fold > 0) {
      canvas.saveLayer(
        Rect.fromLTRB(0, -400, size.width, size.height + 400),
        Paint()..color = Color.fromRGBO(0, 0, 0, 1 - fold),
      );
    }

    // Celestial bodies sit behind the ground so they can set into it.
    // The words stay put while the bodies drift, so a body that was clear of
    // them at rest is held clear of them wherever the drift takes it.
    Offset moved(Offset rest, double radius) => HorizonModel.keepClearOfText(
      rest,
      rest.translate(0, sunShift),
      radius,
      model.textZones,
    );
    final sun = model.sun;
    if (sun != null) {
      final shifted = moved(sun, HorizonModel.sunRadius);
      _paintSun(canvas, shifted, e);
      _paintPoke(canvas, shifted);
    }
    _paintGhost(canvas, sunShift);
    final moon = model.moon;
    if (moon != null) {
      _paintMoon(canvas, moved(moon, HorizonModel.moonRadius), e);
    }

    canvas.save();
    canvas.translate(0, dayShift);
    _paintGround(canvas, size);
    _paintPath(canvas, size, e);
    _paintConstellation(canvas, e);
    _paintMarks(canvas, e);
    canvas.restore();
    if (fold > 0) canvas.restore();
  }

  List<Color> _tinted(List<Color> stops) {
    final tint = palette.tint;
    if (tint == null) return stops;
    return [
      for (final c in stops) Color.lerp(c, tint, palette.dark ? .10 : .07)!,
    ];
  }

  void _paintStars(Canvas canvas, Size size, double dy) {
    final alpha = model.starAlpha;
    if (alpha <= .02) return;
    final rng = _Lcg(7);
    final paint = Paint();
    final maxY = model.horizonY * .72;
    for (var i = 0; i < 34; i++) {
      final x = rng.next() * size.width;
      final y = rng.next() * maxY;
      final r = (palette.dark ? .6 : .75) + rng.next() * .9;
      final a =
          (palette.dark ? .35 + rng.next() * .5 : .26 + rng.next() * .3) *
          alpha;
      paint.color = palette.star.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y + dy), r, paint);
      if (i % 9 == 0) {
        final line = Paint()
          ..color = palette.star.withValues(alpha: a * .55)
          ..strokeWidth = .8
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(Offset(x - 3.5, y + dy), Offset(x + 3.5, y + dy), line);
        canvas.drawLine(Offset(x, y + dy - 3.5), Offset(x, y + dy + 3.5), line);
      }
    }
  }

  void _paintHorizonGlow(Canvas canvas, Size size, double dy) {
    final twilight = (1 - model.dayness - model.starAlpha).clamp(0.0, 1.0);
    if (twilight <= .02) return;
    final sun = model.sun;
    final cx = sun?.dx ?? size.width / 2;
    final warm = Color.lerp(_rose, _golden, model.minutes < 720 ? .35 : .15)!;
    final strength = twilight * (palette.dark ? .30 : .42);
    final center = Offset(cx, model.horizonY + dy);
    final rect = Rect.fromCenter(
      center: center,
      width: size.width * 1.7,
      height: model.horizonY * 1.15,
    );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1, rect.height / rect.width);
    canvas.drawCircle(
      Offset.zero,
      rect.width / 2,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          rect.width / 2,
          [
            warm.withValues(alpha: strength),
            warm.withValues(alpha: strength * .35),
            warm.withValues(alpha: 0),
          ],
          [0, .45, 1],
        ),
    );
    canvas.restore();
  }

  /// Soft light instead of clouds: a luminous band of air along the horizon
  /// and one long, blurred veil high up. Nothing with an outline.
  void _paintHaze(Canvas canvas, Size size, double groundDy, double dy) {
    final h = model.horizonY + groundDy;
    final air = (1 - model.starAlpha * .7).clamp(0.0, 1.0);
    if (air > .02) {
      final top = h - model.horizonY * .42;
      final haze = palette.dark
          ? const Color(0xFF9C95E8).withValues(alpha: .07 * air)
          : Colors.white.withValues(alpha: .62 * air);
      canvas.drawRect(
        Rect.fromLTRB(0, top, size.width, h + 2),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, top), Offset(0, h), [
            haze.withValues(alpha: 0),
            haze,
          ]),
      );
    }
    final veil = model.dayness + (1 - model.dayness - model.starAlpha) * .5;
    if (veil <= .03) return;
    final color = palette.dark
        ? const Color(0xFF8C86E0).withValues(alpha: .06 * veil)
        : Colors.white.withValues(alpha: .5 * veil);
    final paint = Paint()
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9);
    final c = Offset(size.width * .64, model.horizonY * .3 + dy);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: size.width * .62, height: 9),
        const Radius.circular(9),
      ),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: c.translate(-size.width * .2, 11),
          width: size.width * .34,
          height: 6,
        ),
        const Radius.circular(6),
      ),
      paint..color = color.withValues(alpha: color.a * .7),
    );
  }

  /// A low, warm wash that rises from the horizon as the sky is pulled down,
  /// like the glow of a sinking sun. Pure feedback: it carries no status.
  void _paintPullWarmth(Canvas canvas, Size size, double pull) {
    if (pull <= 0 || palette.highContrast) return;
    final top = model.horizonY * .35;
    final rect = Rect.fromLTRB(0, top, size.width, model.horizonY + 24);
    final color = _sunColor;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          color.withValues(alpha: 0),
          color.withValues(alpha: (palette.dark ? .22 : .3) * pull),
        ]),
    );
  }

  Color get _sunColor => sunColorOf(model, dark: palette.dark);

  /// The sun's colour for [model]: warmer toward the ends of the day.
  static Color sunColorOf(HorizonModel model, {required bool dark}) {
    final warmth = (1 - model.dayness).clamp(0.0, 1.0);
    if (dark) return Color.lerp(_golden, _rose, warmth)!;
    return Color.lerp(_paleSun, _paleDawnSun, warmth)!;
  }

  /// A soft ripple that leaves the sun when it is tapped.
  void _paintPoke(Canvas canvas, Offset c) {
    final t = pokeAnimation?.value ?? 0;
    if (t <= 0 || t >= 1) return;
    final ease = Curves.easeOutCubic.transform(t);
    canvas.drawCircle(
      c,
      HorizonModel.sunRadius + 6 + 34 * ease,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * (1 - ease)
        ..color = (palette.highContrast ? palette.ring : _sunColor).withValues(
          alpha: .6 * (1 - ease),
        ),
    );
  }

  /// The translucent sun that follows a long press along the sun's own arc.
  void _paintGhost(Canvas canvas, double sunShift) {
    final share = ghostShare?.value;
    if (share == null) return;
    final c = model.sunAtShare(share).translate(0, sunShift);
    final color = _sunColor;
    canvas.drawCircle(
      c,
      HorizonModel.sunRadius + 7,
      Paint()
        ..shader = ui.Gradient.radial(c, HorizonModel.sunRadius + 7, [
          color.withValues(alpha: .35),
          color.withValues(alpha: 0),
        ]),
    );
    canvas.drawCircle(
      c,
      HorizonModel.sunRadius,
      palette.highContrast
          ? (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = palette.ring.withValues(alpha: .6))
          : (Paint()..color = color.withValues(alpha: .5)),
    );
  }

  void _paintSun(Canvas canvas, Offset c, double entry) {
    const r = HorizonModel.sunRadius;
    final color = _sunColor;
    if (palette.highContrast) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = palette.ring,
      );
      return;
    }
    final settle = model.settled ? 1.3 : 1.0;
    final breathe = 1 + (breath?.value ?? 0) * .08;
    if (palette.dark) {
      final haloR = r * 4.6 * settle * breathe;
      // Under the ground the halo is cut by the horizon, which reads as a
      // rising or setting sun without an extra clip.
      canvas.drawCircle(
        c,
        haloR,
        Paint()
          ..shader = ui.Gradient.radial(
            c,
            haloR,
            [
              color.withValues(alpha: .42 * entry),
              color.withValues(alpha: .42 * .38 * entry),
              color.withValues(alpha: 0),
            ],
            [0, .35, 1],
          ),
      );
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = ui.Gradient.radial(
            c.translate(-r * .25, -r * .3),
            r * 1.3,
            [Color.lerp(color, Colors.white, .55)!, color],
          ),
      );
      return;
    }
    // Light: a pale warm disc in a wide, faint veil of light. No rim.
    final wide = (r + 58) * settle * breathe;
    canvas.drawCircle(
      c,
      wide,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          wide,
          [
            color.withValues(alpha: .34 * entry),
            color.withValues(alpha: .12 * entry),
            color.withValues(alpha: 0),
          ],
          [0, .4, 1],
        ),
    );
    final halo = (r + 24) * breathe;
    canvas.drawCircle(
      c,
      halo,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          halo,
          [
            Colors.white.withValues(alpha: .7 * entry),
            Colors.white.withValues(alpha: .22 * entry),
            Colors.white.withValues(alpha: 0),
          ],
          [0, .45, 1],
        ),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = ui.Gradient.radial(c.translate(-r * .2, -r * .25), r * 1.2, [
          Color.lerp(color, Colors.white, .5)!.withValues(alpha: entry),
          color.withValues(alpha: .92 * entry),
        ]),
    );
  }

  void _paintMoon(Canvas canvas, Offset c, double entry) {
    const r = HorizonModel.moonRadius;
    final p = model.moonPhase;
    final lit = palette.moonLit;
    final dim = palette.moonDim;
    final k = math.cos(2 * math.pi * p);
    final waxing = p < .5;
    final path = Path()
      ..arcTo(
        Rect.fromCircle(center: Offset.zero, radius: r),
        -math.pi / 2,
        math.pi,
        true,
      );
    final tw = (k.abs() * r).clamp(.01, r);
    path.arcTo(
      Rect.fromLTRB(-tw, -r, tw, r),
      math.pi / 2,
      k > 0 ? -math.pi : math.pi,
      false,
    );
    path.close();

    canvas.save();
    canvas.translate(c.dx, c.dy);
    if (!waxing) canvas.scale(-1, 1);
    if (palette.highContrast) {
      canvas.drawCircle(
        Offset.zero,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = palette.ring,
      );
      canvas.drawPath(path, Paint()..color = palette.ring);
    } else {
      final glow = palette.dark
          ? lit.withValues(alpha: .22 * entry)
          : Colors.white.withValues(alpha: .75 * entry);
      canvas.drawCircle(
        Offset.zero,
        r * 3.4,
        Paint()
          ..shader = ui.Gradient.radial(Offset.zero, r * 3.4, [
            glow,
            glow.withValues(alpha: 0),
          ]),
      );
      if (!palette.dark) {
        // A surface rim so the disc stands clear of a pale lilac sky.
        canvas.drawCircle(
          Offset.zero,
          r + 1.5,
          Paint()..color = palette.takenOutline.withValues(alpha: entry),
        );
      }
      canvas.drawCircle(
        Offset.zero,
        r,
        Paint()..color = dim.withValues(alpha: dim.a * entry),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = lit.withValues(alpha: (palette.dark ? .95 : .9) * entry),
      );
    }
    canvas.restore();
  }

  /// A two-tone silhouette: a pale far ridge, a narrow meadow band with a
  /// crisp horizon line, then the page itself. Text below the band sits on
  /// the page colour, never on a fading stain.
  void _paintGround(Canvas canvas, Size size) {
    final h = model.horizonY;
    final w = size.width;
    final bottom = size.height + 400;
    if (palette.highContrast) {
      canvas.drawLine(
        Offset(0, h),
        Offset(w, h),
        Paint()
          ..color = palette.ring
          ..strokeWidth = 2,
      );
      return;
    }
    const band = 12.0;
    final back = Path()
      ..moveTo(0, h - 4)
      ..cubicTo(w * .2, h - 13, w * .36, h - 3, w * .56, h - 8)
      ..cubicTo(w * .76, h - 13, w * .9, h - 5, w, h - 9)
      ..lineTo(w, h + band)
      ..lineTo(0, h + band)
      ..close();
    canvas.drawPath(
      back,
      Paint()..color = Color.lerp(palette.groundBack, model.skyStops[2], .35)!,
    );
    final ridge = Path()
      ..moveTo(0, h + 2)
      ..cubicTo(w * .2, h - 3, w * .44, h + 4, w * .68, h)
      ..cubicTo(w * .84, h - 3, w * .94, h + 1, w, h - 1);
    final front = Path.from(ridge)
      ..lineTo(w, h + band)
      ..lineTo(0, h + band)
      ..close();
    canvas.drawPath(
      front,
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, h - 3), Offset(0, h + band), [
          palette.groundTop,
          palette.groundBottom,
        ]),
    );
    canvas.drawPath(
      ridge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = palette.groundLine,
    );
    // The page begins under the band, with a short soft edge.
    const soft = 5.0;
    canvas.drawRect(
      Rect.fromLTRB(0, h + band - soft, w, h + band + .5),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, h + band - soft),
          Offset(0, h + band),
          [palette.background.withValues(alpha: 0), palette.background],
        ),
    );
    canvas.drawRect(
      Rect.fromLTRB(0, h + band, w, bottom),
      Paint()..color = palette.background,
    );
  }

  /// The day path: solid for the hours already behind us, dotted ahead.
  void _paintPath(Canvas canvas, Size size, double entry) {
    final hc = palette.highContrast;
    final progress = model.dayProgress;
    final sweep = sweepAnimation?.value ?? 0;
    final sweeping = sweepId != null && sweep > 0 && sweep < 1;
    // How far the solid line reaches: the hours behind us, all of it once the
    // day is settled, and the sweep's leading edge while it plays.
    final reach = sweeping
        ? progress + (1 - progress) * Curves.easeInOutCubic.transform(sweep)
        : (model.settled ? 1.0 : progress);
    final ahead = Paint()
      ..color = palette.ring.withValues(alpha: (hc ? .85 : .34) * entry);
    final inner = math.max(1.0, size.width - 2 * HorizonModel.sideInset);
    const spacing = 6.0;
    final dots = (inner / spacing).floor();
    for (var i = 0; i <= dots; i++) {
      final t = i / dots;
      if (t < reach) continue;
      canvas.drawCircle(model.pathAt(t), hc ? 1.1 : .95, ahead);
    }
    if (reach <= 0) return;
    final behind = Path();
    const steps = 64;
    final end = (reach * steps).ceil();
    for (var i = 0; i <= end; i++) {
      final p = model.pathAt(math.min(i / steps, reach));
      i == 0 ? behind.moveTo(p.dx, p.dy) : behind.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      behind,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = hc ? 2 : 1.5
        ..strokeCap = StrokeCap.round
        ..color = (hc ? palette.ring : palette.taken).withValues(
          alpha: (hc ? 1 : .42) * entry,
        ),
    );
    if (sweeping && !hc) {
      // A soft spark rides the leading edge of the sweep.
      final tip = model.pathAt(reach);
      canvas.drawCircle(
        tip,
        9,
        Paint()
          ..shader = ui.Gradient.radial(tip, 9, [
            palette.celebrate.withValues(
              alpha: .55 * math.sin(math.pi * sweep),
            ),
            palette.celebrate.withValues(alpha: 0),
          ]),
      );
    }
  }

  void _paintMarks(Canvas canvas, double entry) {
    final marks = model.marks;
    if (marks.isEmpty) return;
    final order = <HorizonMark, int>{
      for (var i = 0; i < marks.length; i++) marks[i]: i,
    };
    final visible = [...marks.where((m) => !m.hidden)];
    final cel = celebrateAnimation?.value ?? 0;
    final celebrating = celebrateId != null && cel > 0 && cel < 1;
    final scrub = scrubX?.value;
    final scrubbed = scrub == null ? null : model.nearestMarkByX(scrub);
    final focusId = focusedId ?? model.nextMark?.id;
    HorizonMark? focus;
    for (final m in visible) {
      if (m.id == focusId) focus = m;
    }
    // A hidden (collapsed) focus is shown on the capsule it collapsed onto.
    if (focus == null && focusId != null) {
      for (final m in marks) {
        if (m.id == focusId && m.hidden) {
          focus = visible.lastWhere(
            (v) => v.minute == m.minute,
            orElse: () => m,
          );
        }
      }
    }

    if (scrub != null) {
      canvas.drawLine(
        Offset(scrub, model.horizonY - 70),
        Offset(scrub, model.horizonY + 6),
        Paint()
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..color = palette.ring.withValues(alpha: .45),
      );
    }

    double staggerOf(HorizonMark mark) => Curves.easeOut.transform(
      ((entry * 1.6 - (order[mark]! * .09).clamp(0.0, .7)) / .6).clamp(
        0.0,
        1.0,
      ),
    );

    // Focus halo goes under every capsule.
    if (focus != null && !palette.highContrast) {
      final a = staggerOf(focus);
      final c = focus.rect.center;
      canvas.drawCircle(
        c,
        19,
        Paint()
          ..shader = ui.Gradient.radial(c, 19, [
            palette.taken.withValues(alpha: (palette.dark ? .34 : .2) * a),
            palette.taken.withValues(alpha: 0),
          ]),
      );
    }

    for (final mark in visible) {
      final alpha = staggerOf(mark);
      if (alpha <= 0) continue;
      var scale = 1.0;
      final isCelebrated = celebrating && mark.id == celebrateId;
      if (isCelebrated) {
        scale *= 1 + .38 * math.sin(math.pi * (cel / .45).clamp(0.0, 1.0));
      }
      final focused = identical(mark, focus);
      if (focused) scale *= 1.12;
      if (scrubbed != null && scrubbed.id == mark.id) scale *= 1.2;
      _paintCapsule(canvas, mark, scale, alpha, focused: focused);
    }

    if (celebrating) {
      for (final mark in marks) {
        if (mark.id == celebrateId) {
          _paintCelebration(canvas, mark.rect.center, cel);
          break;
        }
      }
    }

    final sweep = sweepAnimation?.value ?? 0;
    if (sweepId != null && sweep > 0 && sweep < 1) {
      // Settled day: every mark twinkles in turn, left to right.
      final ordered = [...visible]..sort((a, b) => a.minute - b.minute);
      for (var i = 0; i < ordered.length; i++) {
        // The take that settled the day already twinkles on its own.
        if (celebrating && ordered[i].id == celebrateId) continue;
        final start = ordered.length == 1
            ? 0.0
            : .55 * i / (ordered.length - 1);
        final local = ((sweep - start) / .45).clamp(0.0, 1.0);
        if (local > 0 && local < 1) {
          _paintCelebration(canvas, ordered[i].rect.center, local);
        }
      }
    }

    // A numeral over groups taller than the visible limit.
    final groups = <int, List<HorizonMark>>{};
    for (final m in visible) {
      if (m.stackCount > HorizonModel.maxVisibleStack) {
        groups.putIfAbsent(m.minute, () => []).add(m);
      }
    }
    for (final group in groups.values) {
      final count = group.first.stackCount;
      final cx =
          group.fold<double>(0, (sum, m) => sum + m.rect.center.dx) /
          group.length;
      final top = group.fold<double>(
        double.infinity,
        (y, m) => math.min(y, m.rect.top),
      );
      _paintNumeral(canvas, '$count', Offset(cx, top - 2), entry);
    }
  }

  void _paintNumeral(
    Canvas canvas,
    String text,
    Offset bottomCenter,
    double a,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: (palette.label ?? const TextStyle()).copyWith(
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
          color: palette.ring.withValues(alpha: a),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final pill = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: bottomCenter.translate(0, -tp.height / 2 - 3),
        width: math.max(tp.width + 8, tp.height + 6),
        height: tp.height + 6,
      ),
      const Radius.circular(99),
    );
    if (!palette.highContrast) {
      canvas.drawRRect(
        pill,
        Paint()..color = palette.ringFill.withValues(alpha: .9 * a),
      );
    }
    canvas.drawRRect(
      pill,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = palette.highContrast ? 1.5 : 1
        ..color = palette.ring.withValues(
          alpha: (palette.highContrast ? 1 : .5) * a,
        ),
    );
    tp.paint(
      canvas,
      Offset(pill.center.dx - tp.width / 2, pill.center.dy - tp.height / 2),
    );
    tp.dispose();
  }

  /// One capsule, tilted like the brand glyph. Taken is filled with a
  /// surface outline, pending is an outline, skipped is a muted outline with
  /// a seam: shape carries the state, colour only repeats it.
  void _paintCapsule(
    Canvas canvas,
    HorizonMark mark,
    double scale,
    double alpha, {
    required bool focused,
  }) {
    const r = HorizonModel.markRadius;
    final hc = palette.highContrast;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset.zero,
        width: r * 2,
        height: HorizonModel.markLength,
      ),
      const Radius.circular(r),
    );
    canvas.save();
    canvas.translate(mark.rect.center.dx, mark.rect.center.dy);
    canvas.rotate(HorizonModel.markTilt);
    canvas.scale(scale);

    if (focused) {
      canvas.drawRRect(
        body.inflate(4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = hc ? 2 : 1.5
          ..color = palette.ring.withValues(alpha: (hc ? 1 : .8) * alpha),
      );
    }

    switch (mark.state) {
      case HorizonMarkState.taken:
        if (hc) {
          canvas.drawRRect(
            body.deflate(1.25),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5
              ..color = palette.ring.withValues(alpha: alpha),
          );
          canvas.save();
          canvas.clipRect(
            const Rect.fromLTRB(-r, 0, r, HorizonModel.markLength),
          );
          canvas.drawRRect(
            body,
            Paint()..color = palette.ring.withValues(alpha: alpha),
          );
          canvas.restore();
          break;
        }
        canvas.drawRRect(
          body.inflate(1.5),
          Paint()..color = palette.takenOutline.withValues(alpha: alpha),
        );
        canvas.drawRRect(
          body,
          Paint()..color = palette.taken.withValues(alpha: alpha),
        );
        // A soft highlight down one side, so it reads as a capsule.
        canvas.drawLine(
          const Offset(-r * .42, -HorizonModel.markLength / 2 + r * .9),
          const Offset(-r * .42, -r * .2),
          Paint()
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: .38 * alpha),
        );
      case HorizonMarkState.skipped:
        final color = palette.mutedRing.withValues(alpha: alpha);
        if (!hc) {
          canvas.drawRRect(
            body,
            Paint()..color = palette.ringFill.withValues(alpha: .8 * alpha),
          );
        }
        canvas.drawRRect(
          body.deflate(1),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = hc ? 2.25 : 1.75
            ..color = color,
        );
        canvas.drawLine(
          const Offset(-r * .55, 0),
          const Offset(r * .55, 0),
          Paint()
            ..strokeWidth = 1.75
            ..strokeCap = StrokeCap.round
            ..color = color,
        );
      case HorizonMarkState.pending:
      case HorizonMarkState.missed:
        if (!hc) {
          canvas.drawRRect(
            body,
            Paint()..color = palette.ringFill.withValues(alpha: .86 * alpha),
          );
        }
        canvas.drawRRect(
          body.deflate(1),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = hc ? 2.25 : 2
            ..color = palette.ring.withValues(alpha: alpha),
        );
    }
    canvas.restore();
  }

  /// After sunset each dose taken today rises out of its mark as a star and
  /// the day's stars join up in time order. They climb with the dusk (the
  /// night weight), so the constellation assembles over the evening; a dose
  /// taken at night sends its own star up on the receipt.
  void _paintConstellation(Canvas canvas, double e) {
    final stars = [
      for (final star in model.constellation)
        if (!heldStars.contains(star.id)) star,
    ];
    final night = model.starAlpha;
    if (stars.isEmpty || night <= .02 || palette.highContrast) return;
    final cel = celebrateAnimation?.value ?? 0;
    // Its first frame is still at 0, and the star must not show at home then.
    final launching =
        celebrateId != null &&
        (celebrateAnimation?.status == AnimationStatus.forward ||
            (cel > 0 && cel < 1));
    final rise = Curves.easeInOutCubic.transform(night);
    final progress = <double>[
      for (final star in stars)
        launching && star.id == celebrateId
            ? rise *
                  Curves.easeInOutCubic.transform(
                    ((cel - .18) / .72).clamp(0.0, 1.0),
                  )
            : rise,
    ];
    final at = <Offset>[
      for (var i = 0; i < stars.length; i++)
        Offset.lerp(stars[i].origin, stars[i].home, progress[i])!,
    ];
    final color = palette.star;
    final strength = (palette.dark ? 1.0 : .85) * e;

    // The lines come once the stars are nearly home.
    final join = ((night - .55) / .45).clamp(0.0, 1.0);
    if (join > 0 && stars.length > 1) {
      final line = Paint()
        ..strokeWidth = .9
        ..strokeCap = StrokeCap.round;
      for (var i = 1; i < stars.length; i++) {
        final settled = math.min(progress[i - 1], progress[i]) / rise;
        final a = .3 * join * strength * settled * settled;
        if (a <= .01) continue;
        line.color = color.withValues(alpha: a);
        canvas.drawLine(at[i - 1], at[i], line);
      }
    }

    for (var i = 0; i < stars.length; i++) {
      final p = progress[i];
      final c = at[i];
      final origin = stars[i].origin;
      // A fading trail back to the mark while the star climbs.
      final climbing = math.sin(math.pi * p.clamp(0.0, 1.0));
      if (climbing > .02 && (c - origin).distance > 2) {
        canvas.drawLine(
          origin,
          c,
          Paint()
            ..strokeWidth = 1.4
            ..strokeCap = StrokeCap.round
            ..shader = ui.Gradient.linear(origin, c, [
              color.withValues(alpha: 0),
              color.withValues(alpha: .45 * climbing * strength),
            ]),
        );
      }
      // Arriving home after a launch, the star flares once.
      final flare = launching && stars[i].id == celebrateId
          ? math.sin(math.pi * ((cel - .78) / .22).clamp(0.0, 1.0))
          : 0.0;
      final a = (.35 + .65 * p) * strength;
      final glow = 7 + 6 * flare;
      canvas.drawCircle(
        c,
        glow,
        Paint()
          ..shader = ui.Gradient.radial(c, glow, [
            color.withValues(alpha: (.28 + .3 * flare) * a),
            color.withValues(alpha: 0),
          ]),
      );
      canvas.drawCircle(
        c,
        1.9 + .8 * flare,
        Paint()..color = color.withValues(alpha: .95 * a),
      );
      final ray = Paint()
        ..strokeWidth = .9
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: .6 * a);
      final long = 4.5 + 5 * flare;
      canvas.drawLine(c.translate(-long, 0), c.translate(long, 0), ray);
      canvas.drawLine(c.translate(0, -long), c.translate(0, long), ray);
    }
  }

  /// Receipt echo on the sky: two expanding rings and a short twinkle, sized
  /// so it reads at arm's length rather than as a hairline artefact.
  void _paintCelebration(Canvas canvas, Offset c, double cel) {
    final color = palette.celebrate;
    final t = Curves.easeOutCubic.transform(cel);
    final fade = math.pow(1 - cel, 1.3).toDouble();
    const start = 13.0;
    if (!palette.highContrast) {
      final glowR = start + celebrateReach * .5 * t;
      canvas.drawCircle(
        c,
        glowR,
        Paint()
          ..shader = ui.Gradient.radial(c, glowR, [
            color.withValues(alpha: .22 * fade),
            color.withValues(alpha: 0),
          ]),
      );
    }
    canvas.drawCircle(
      c,
      start + celebrateReach * t,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 + 3 * (1 - t)
        ..color = color.withValues(alpha: .95 * fade),
    );
    final c2 = ((cel - .16) / .84).clamp(0.0, 1.0);
    if (c2 > 0) {
      final t2 = Curves.easeOutCubic.transform(c2);
      canvas.drawCircle(
        c,
        start + celebrateReach * .62 * t2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .75 + 2 * (1 - t2)
          ..color = color.withValues(alpha: .7 * math.pow(1 - c2, 1.3)),
      );
    }
    if (twinkle <= 0) return;
    final burst = math.sin(math.pi * (cel / .7).clamp(0.0, 1.0));
    if (burst <= 0) return;
    final ray = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: .9 * burst);
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4 + math.pi / 8;
      final long = i.isEven;
      final inner = start + 3 + 8 * t * twinkle;
      final outer = inner + (long ? 9 : 5) * twinkle * burst;
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(c + dir * inner, c + dir * outer, ray);
    }
  }

  @override
  bool shouldRepaint(HorizonPainter old) =>
      old.model != model ||
      old.layer != layer ||
      old.palette != palette ||
      old.celebrateId != celebrateId ||
      !setEquals(old.heldStars, heldStars) ||
      old.sweepId != sweepId ||
      old.focusedId != focusedId ||
      old.celebrateReach != celebrateReach ||
      old.twinkle != twinkle;
}

class _Lcg {
  _Lcg(this._s);
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }
}
