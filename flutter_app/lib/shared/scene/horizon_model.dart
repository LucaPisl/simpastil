import 'dart:math' as math;
import 'dart:ui';

import 'sun_table.dart';

enum HorizonPhase { dawn, day, dusk, night }

/// One dose as the scene needs it. Only [plannedLocalTime] ("HH:mm[:ss]"),
/// [state] ("taken" | "skipped" | "missed" | anything else is pending) and an
/// opaque [id] matter for drawing.
class HorizonDose {
  const HorizonDose({
    required this.id,
    required this.plannedLocalTime,
    required this.state,
    required this.person,
  });

  final String id;
  final String? plannedLocalTime;
  final String state;
  final String person;
}

enum HorizonMarkState { pending, taken, skipped, missed }

/// A dose mark. [rect] bounds the drawn capsule; hit-testing uses the same
/// rect so painter and gestures cannot drift apart.
class HorizonMark {
  const HorizonMark({
    required this.id,
    required this.rect,
    required this.state,
    required this.minute,
    required this.stackIndex,
    required this.stackCount,
    required this.person,
  });

  final String id;
  final Rect rect;
  final HorizonMarkState state;
  final int minute;
  final int stackIndex;
  final int stackCount;
  final String person;

  /// More than [HorizonModel.maxVisibleStack] same-minute doses collapse onto
  /// the last visible capsule, and the group then carries a numeral.
  bool get hidden => stackIndex >= HorizonModel.maxVisibleStack;
}

/// A dose taken today, as a star: after sunset each taken dose rises out
/// of its mark into the sky above it, and the day's stars join up in time
/// order, a constellation of the day's care.
class HorizonStar {
  const HorizonStar({
    required this.id,
    required this.home,
    required this.origin,
    required this.minute,
  });

  /// The mark's id.
  final String id;

  /// Where the star rests once night has fallen.
  final Offset home;

  /// The centre of the mark it rises from.
  final Offset origin;
  final int minute;
}

/// Pure geometry and colour keyframes for the day sky. No widgets, no
/// ColorScheme: [HorizonPainter] adds theme colours on top.
class HorizonModel {
  HorizonModel._({
    required this.phase,
    required this.minutes,
    required this.size,
    required this.horizonY,
    required this.sun,
    required this.moon,
    required this.moonPhase,
    required this.skyStops,
    required this.starAlpha,
    required this.dayness,
    required this.marks,
    required this.settled,
    required this.recorded,
    required this.total,
    required this.highContrast,
    required this.brightness,
    required this.sunTimes,
    required this.dayProgress,
    required this.pathBaseY,
    required this.pathLift,
    required this.constellation,
    required this.textZones,
  });

  static const maxVisibleStack = 3;

  /// Same-minute capsules fan out sideways along the day path, this far apart.
  static const stackStep = 16.0;

  /// Half the capsule's width; the capsule is [markLength] long.
  static const markRadius = 6.0;
  static const markLength = 20.0;

  /// Capsules lean like the brand's capsule glyph.
  static const markTilt = -.55;
  static const sideInset = 28.0;
  static const skyStopPositions = <double>[0, .62, 1];

  final HorizonPhase phase;

  /// Effective minute of the day the sky is drawn for.
  final double minutes;
  final Size size;
  final double horizonY;

  /// Centre of the sun when it is up (or just touching the horizon).
  final Offset? sun;
  final Offset? moon;

  /// 0 new, 0.5 full, 1 new again.
  final double moonPhase;

  /// Top, middle and horizon colour of the sky, always three entries.
  final List<Color> skyStops;
  final double starAlpha;
  final double dayness;

  /// Today's taken doses as stars, in time order. They rest at their home
  /// once night has fallen ([starAlpha] 1) and sit on their marks by day.
  final List<HorizonStar> constellation;

  /// Where the header words sit, in scene coordinates. The painter keeps
  /// shifted bodies out of them too.
  final List<Rect> textZones;

  /// Radius kept clear around a constellation star.
  static const double starRadius = 5;
  final List<HorizonMark> marks;

  /// Everything planned for this day is recorded (taken or skipped).
  final bool settled;
  final int recorded;
  final int total;
  final bool highContrast;
  final Brightness brightness;
  final SunTimes sunTimes;

  /// How much of the day path is behind us: 0 for a future day, 1 for a past
  /// day, otherwise the clock's share of 24 hours.
  final double dayProgress;

  /// The day path is a shallow arc from midnight (left) to midnight (right):
  /// its ends sit at [pathBaseY] and its middle rises by [pathLift].
  final double pathBaseY;
  final double pathLift;

  static const double sunRadius = 11;
  static const double moonRadius = 11;

  /// Gap kept between a sky body and any dose mark.
  static const double bodyClearance = 6;

  /// The marks are the hero: a body that would cover one rises straight up
  /// until it clears every mark by [bodyClearance] (never above the top).
  static Offset clearOfMarks(
    Offset center,
    double radius,
    List<HorizonMark> marks,
  ) {
    var c = center;
    for (var pass = 0; pass < 4; pass++) {
      double? top;
      for (final mark in marks) {
        final zone = mark.rect.inflate(radius + bodyClearance);
        if (zone.contains(c)) {
          top = math.min(top ?? zone.top, zone.top);
        }
      }
      if (top == null) return c;
      c = Offset(c.dx, math.max(radius + 1, top - .5));
      if (c.dy <= radius + 1) return c;
    }
    return c;
  }

  /// Gap kept between a sky body and header text.
  static const double textClearance = 4;

  /// Words sit on top of the sky, so a body must never sit behind them: one
  /// that would overlap a text zone drops below it, else rises above it, else
  /// stays out of the scene for now (it is back once the text no longer
  /// covers its spot). Returns null when no clear spot exists.
  static Offset? clearOfText(
    Offset center,
    double radius,
    List<Rect> zones, {
    required double lowest,
    List<Rect> avoid = const [],
  }) {
    if (zones.isEmpty) return center;
    final pad = radius + textClearance;
    bool covered(Offset c) =>
        zones.any((z) => z.inflate(pad).contains(c)) ||
        avoid.any((r) => r.inflate(radius + bodyClearance).contains(c));
    if (!zones.any((z) => z.inflate(pad).contains(center))) return center;
    var below = center.dy;
    var above = center.dy;
    for (final z in zones) {
      if (z.inflate(pad).contains(Offset(center.dx, below))) {
        below = math.max(below, z.bottom + pad + .5);
      }
      if (z.inflate(pad).contains(Offset(center.dx, above))) {
        above = math.min(above, z.top - pad - .5);
      }
    }
    final down = Offset(center.dx, below);
    if (below <= lowest && !covered(down)) return down;
    final up = Offset(center.dx, above);
    if (above >= radius + 1 && !covered(up)) return up;
    return null;
  }

  /// A body is placed clear of the words at rest, but the painter then moves
  /// it (parallax on scroll, the rise-in, the pull) while the words stay put.
  /// This keeps the moved body on the side of each zone it rests on: it may
  /// slide away from the words, never into them.
  static Offset keepClearOfText(
    Offset rest,
    Offset shifted,
    double radius,
    List<Rect> zones,
  ) {
    final pad = radius + textClearance;
    var dy = shifted.dy;
    for (final z in zones) {
      final reach = z.inflate(pad);
      if (shifted.dx < reach.left || shifted.dx > reach.right) continue;
      if (rest.dy < z.center.dy) {
        dy = math.min(dy, z.top - pad - .5);
      } else {
        dy = math.max(dy, z.bottom + pad + .5);
      }
    }
    return Offset(shifted.dx, dy);
  }

  /// [date] is the day being shown, [now] the clock. A past day shows its
  /// evening sky, a future day shows dawn, today follows [now].
  factory HorizonModel.compute({
    required DateTime date,
    required DateTime now,
    required Brightness b,
    required bool highContrast,
    required List<HorizonDose> doses,
    required Size size,
    List<Rect> textZones = const [],
  }) {
    final times = SunTable.forDate(date);
    final day = DateTime(date.year, date.month, date.day);
    final today = DateTime(now.year, now.month, now.day);
    final double m;
    final double progress;
    if (day.isBefore(today)) {
      m = times.sunset - 10;
      progress = 1;
    } else if (day.isAfter(today)) {
      m = times.sunrise + 12;
      progress = 0;
    } else {
      m = now.hour * 60.0 + now.minute + now.second / 60;
      progress = (m / 1440).clamp(0.0, 1.0);
    }

    final horizonY = (size.height * .8).roundToDouble();
    final arc = horizonY * .62;
    final sunT = (m - times.sunrise) / times.daylight;
    Offset? sun;
    if (sunT > -.06 && sunT < 1.06) {
      sun = _onArc(size, horizonY, arc, sunT);
    }
    final nightLen = 1440 - times.daylight;
    final sinceSunset = m >= times.sunset
        ? m - times.sunset
        : m + 1440 - times.sunset;
    final moonT = sinceSunset / nightLen;
    Offset? moon;
    if (sun == null && moonT > -.02 && moonT < 1.02) {
      moon = _onArc(size, horizonY, arc * .85, moonT);
    }

    final phase = _phaseAt(m, times);
    final weights = _weights(m, times);
    final palette = b == Brightness.light ? _lightPalette : _darkPalette;
    final stops = List<Color>.generate(3, (i) {
      var r = 0.0, g = 0.0, bl = 0.0;
      for (final entry in weights.entries) {
        final c = palette[entry.key]![i];
        r += c.r * entry.value;
        g += c.g * entry.value;
        bl += c.b * entry.value;
      }
      return Color.from(alpha: 1, red: r, green: g, blue: bl);
    });

    final marks = <HorizonMark>[];
    final byMinute = <int, List<HorizonDose>>{};
    for (final dose in doses) {
      final minute = _parseMinute(dose.plannedLocalTime);
      if (minute == null) continue;
      byMinute.putIfAbsent(minute, () => []).add(dose);
    }
    final pathBaseY = horizonY - 12;
    // Shallow on purpose: the header text sits above the path, and the arc
    // only has to read as "the day rises and falls", not as the sun's track.
    final pathLift = math.min(14.0, horizonY * .1);
    final inner = math.max(1.0, size.width - 2 * sideInset);
    final ordered = byMinute.keys.toList()..sort();
    for (final minute in ordered) {
      final group = byMinute[minute]!;
      final x0 = sideInset + minute / 1440 * inner;
      final visibleCount = math.min(group.length, maxVisibleStack);
      for (var i = 0; i < group.length; i++) {
        final dose = group[i];
        final visible = math.min(i, maxVisibleStack - 1);
        final x = x0 + (visible - (visibleCount - 1) / 2) * stackStep;
        var cy = pathY(x, size.width, pathBaseY, pathLift);
        // The day path flattens before a mark would rise behind header words.
        final halfW = markBounds.width / 2, halfH = markBounds.height / 2;
        for (final z in textZones) {
          if (x + halfW > z.left && x - halfW < z.right) {
            cy = math.max(cy, z.bottom + textClearance / 2 + halfH);
          }
        }
        final c = Offset(x, math.min(cy, pathBaseY));
        marks.add(
          HorizonMark(
            id: dose.id,
            rect: Rect.fromCenter(
              center: c,
              width: markBounds.width,
              height: markBounds.height,
            ),
            state: _stateOf(dose.state),
            minute: minute,
            stackIndex: i,
            stackCount: group.length,
            person: dose.person,
          ),
        );
      }
    }
    final recorded = marks
        .where(
          (m) =>
              m.state == HorizonMarkState.taken ||
              m.state == HorizonMarkState.skipped,
        )
        .length;
    if (moon != null) moon = clearOfMarks(moon, moonRadius, marks);
    // Text zones come last: nothing may sit behind the header words.
    final lowest = horizonY - 2;
    final markRects = [for (final mark in marks) mark.rect];
    if (sun != null) {
      sun = clearOfText(
        sun,
        sunRadius,
        textZones,
        lowest: lowest,
        avoid: markRects,
      );
    }
    if (moon != null) {
      moon = clearOfText(
        moon,
        moonRadius,
        textZones,
        lowest: lowest,
        avoid: markRects,
      );
    }

    final constellation = _constellation(
      marks: marks,
      size: size,
      textZones: textZones,
      bodies: [
        if (sun != null) Rect.fromCircle(center: sun, radius: sunRadius + 8),
        if (moon != null) Rect.fromCircle(center: moon, radius: moonRadius + 8),
      ],
    );

    return HorizonModel._(
      phase: phase,
      minutes: m,
      size: size,
      horizonY: horizonY,
      sun: sun,
      moon: moon,
      moonPhase: moonPhaseOf(date),
      skyStops: stops,
      starAlpha: weights[HorizonPhase.night] ?? 0,
      dayness: weights[HorizonPhase.day] ?? 0,
      marks: List.unmodifiable(marks),
      settled: marks.isNotEmpty && recorded == marks.length,
      recorded: recorded,
      total: marks.length,
      highContrast: highContrast,
      brightness: b,
      sunTimes: times,
      dayProgress: progress,
      pathBaseY: pathBaseY,
      pathLift: pathLift,
      constellation: List.unmodifiable(constellation),
      textZones: List.unmodifiable(textZones),
    );
  }

  /// Places each taken dose's star above its mark, at a height of its own
  /// (stable per dose), clear of the header words, the sun and moon, the
  /// day path and the other stars. A star with no clear spot is left out.
  static List<HorizonStar> _constellation({
    required List<HorizonMark> marks,
    required Size size,
    required List<Rect> textZones,
    required List<Rect> bodies,
  }) {
    final taken = [
      for (final mark in marks)
        if (mark.state == HorizonMarkState.taken) mark,
    ]..sort((a, b) => a.minute.compareTo(b.minute));
    const top = 14.0;
    const apart = 18.0;
    final stars = <HorizonStar>[];
    for (final mark in taken) {
      final origin = mark.rect.center;
      // Never down among the marks: the path stays the marks' own.
      final lowest = mark.rect.top - 22;
      final band = lowest - top;
      if (band < 24) continue;
      final h = _hashOf(mark.id);
      final jitter = ((h & 0x1f) / 31 - .5) * 18;
      final x = (origin.dx + jitter).clamp(10.0, size.width - 10).toDouble();
      for (var attempt = 0; attempt < 4; attempt++) {
        final u = ((h >> (5 + attempt * 6)) & 0x3f) / 63;
        final spot = clearOfText(
          Offset(x, top + band * (.08 + .8 * u)),
          starRadius,
          textZones,
          lowest: lowest,
        );
        if (spot == null) continue;
        final blocked =
            bodies.any((r) => r.inflate(starRadius).contains(spot)) ||
            stars.any((s) => (s.home - spot).distance < apart);
        if (blocked) continue;
        stars.add(
          HorizonStar(
            id: mark.id,
            home: spot,
            origin: origin,
            minute: mark.minute,
          ),
        );
        break;
      }
    }
    return stars;
  }

  static int _hashOf(String id) =>
      id.codeUnits.fold<int>(17, (a, c) => (a * 31 + c) & 0x7fffffff);

  /// Bounding box of one tilted capsule.
  static final Size markBounds = () {
    const w = markRadius * 2, l = markLength;
    final c = math.cos(markTilt).abs(), s = math.sin(markTilt).abs();
    return Size((l - w) * s + w, (l - w) * c + w);
  }();

  /// Height of the day path at [x] for a scene [width] wide.
  static double pathY(double x, double width, double baseY, double lift) {
    final inner = math.max(1.0, width - 2 * sideInset);
    final t = ((x - sideInset) / inner).clamp(0.0, 1.0);
    return baseY - math.sin(math.pi * t) * lift;
  }

  /// Point on the day path at share [t] of the day (0 = 00:00, 1 = 24:00).
  Offset pathAt(double t) {
    final x = sideInset + t * math.max(1.0, size.width - 2 * sideInset);
    return Offset(x, pathY(x, size.width, pathBaseY, pathLift));
  }

  /// The first dose still waiting to be recorded, in time order: the mark
  /// the scene points at when the caller names no focus of its own.
  HorizonMark? get nextMark {
    for (final mark in marks) {
      if (mark.state == HorizonMarkState.pending) return mark;
    }
    return null;
  }

  /// Sky colour at vertical position [y] (clamped to the sky).
  Color skyColorAt(double y) {
    final t = (y / horizonY).clamp(0.0, 1.0);
    if (t <= skyStopPositions[1]) {
      return Color.lerp(skyStops[0], skyStops[1], t / skyStopPositions[1])!;
    }
    return Color.lerp(
      skyStops[1],
      skyStops[2],
      (t - skyStopPositions[1]) / (1 - skyStopPositions[1]),
    )!;
  }

  /// Nearest visible mark within [tolerance] of [p], or null.
  HorizonMark? nearestMark(Offset p, {double tolerance = 24}) {
    HorizonMark? best;
    var bestDistance = tolerance;
    for (final mark in marks) {
      if (mark.hidden) continue;
      final d = (mark.rect.center - p).distance;
      if (d <= bestDistance) {
        bestDistance = d;
        best = mark;
      }
    }
    return best;
  }

  /// Where the sun sits at share [t] of its daylight (0 sunrise, 1 sunset).
  Offset sunAtShare(double t) =>
      _onArc(size, horizonY, horizonY * .62, t.clamp(0.0, 1.0));

  /// The clock minute the sun stands at when it is at share [t] of daylight.
  double minuteAtSunShare(double t) =>
      sunTimes.sunrise + t.clamp(0.0, 1.0) * sunTimes.daylight;

  /// Share of daylight whose sun stands at horizontal position [x].
  double sunShareAtX(double x) =>
      ((x / size.width - .12) / .76).clamp(0.0, 1.0);

  /// The visible mark whose time is closest to clock [minute].
  HorizonMark? nearestMarkByMinute(double minute) {
    HorizonMark? best;
    var bestDistance = double.infinity;
    for (final mark in marks) {
      if (mark.hidden) continue;
      final d = (mark.minute - minute).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = mark;
      }
    }
    return best;
  }

  /// Nearest mark by horizontal distance only (scrubbing).
  HorizonMark? nearestMarkByX(double x) {
    HorizonMark? best;
    var bestDistance = double.infinity;
    for (final mark in marks) {
      if (mark.hidden) continue;
      final d = (mark.rect.center.dx - x).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = mark;
      }
    }
    return best;
  }

  static Offset _onArc(Size size, double horizonY, double arc, double t) {
    final x = size.width * (.12 + .76 * t);
    final y = horizonY + 2 - math.sin(math.pi * t) * arc;
    return Offset(x, y);
  }

  static int? _parseMinute(String? time) {
    if (time == null) return null;
    final parts = time.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]), mi = int.tryParse(parts[1]);
    if (h == null || mi == null) return null;
    return (h * 60 + mi).clamp(0, 1439);
  }

  static HorizonMarkState _stateOf(String state) => switch (state) {
    'taken' => HorizonMarkState.taken,
    'skipped' => HorizonMarkState.skipped,
    'missed' => HorizonMarkState.missed,
    _ => HorizonMarkState.pending,
  };

  static HorizonPhase _phaseAt(double m, SunTimes t) {
    if (m < t.sunrise - 45 || m >= t.sunset + 50) return HorizonPhase.night;
    if (m < t.sunrise + 80) return HorizonPhase.dawn;
    if (m < t.sunset - 70) return HorizonPhase.day;
    return HorizonPhase.dusk;
  }

  /// Blend weights of the four keyframe palettes at minute [m].
  static Map<HorizonPhase, double> _weights(double m, SunTimes t) {
    final anchors = <(double, HorizonPhase)>[
      (t.sunrise - 80, HorizonPhase.night),
      (t.sunrise + 10, HorizonPhase.dawn),
      (t.sunrise + 130, HorizonPhase.day),
      (t.sunset - 120, HorizonPhase.day),
      (t.sunset - 5, HorizonPhase.dusk),
      (t.sunset + 85, HorizonPhase.night),
    ];
    if (m <= anchors.first.$1 || m >= anchors.last.$1) {
      return {HorizonPhase.night: 1};
    }
    for (var i = 0; i < anchors.length - 1; i++) {
      final a = anchors[i], c = anchors[i + 1];
      if (m >= a.$1 && m <= c.$1) {
        final u = (m - a.$1) / (c.$1 - a.$1);
        final s = u * u * (3 - 2 * u);
        final out = <HorizonPhase, double>{};
        out[a.$2] = (out[a.$2] ?? 0) + 1 - s;
        out[c.$2] = (out[c.$2] ?? 0) + s;
        return out;
      }
    }
    return {HorizonPhase.night: 1};
  }

  /// Synodic moon phase, 0 new .. 0.5 full .. 1.
  static double moonPhaseOf(DateTime date) {
    final jd =
        DateTime.utc(
              date.year,
              date.month,
              date.day,
              12,
            ).millisecondsSinceEpoch /
            86400000 +
        2440587.5;
    final p = ((jd - 2451550.1) / 29.530588853) % 1;
    return p < 0 ? p + 1 : p;
  }

  // Light skies never go dark (luminance >= .8), dark skies never go bright
  // (luminance <= .03), so ink and white text read without a scrim.
  static const _lightPalette = <HorizonPhase, List<Color>>{
    HorizonPhase.night: [
      Color(0xFFE9E6FB),
      Color(0xFFECE9FB),
      Color(0xFFF2F0FD),
    ],
    HorizonPhase.dawn: [
      Color(0xFFF0E4FB),
      Color(0xFFFBE6EE),
      Color(0xFFFFE6CE),
    ],
    HorizonPhase.day: [Color(0xFFE4EBFE), Color(0xFFEEF2FF), Color(0xFFF8F9FF)],
    HorizonPhase.dusk: [
      Color(0xFFF0E4FB),
      Color(0xFFFCE4EB),
      Color(0xFFFFE5D0),
    ],
  };

  static const _darkPalette = <HorizonPhase, List<Color>>{
    HorizonPhase.night: [
      Color(0xFF0A0A16),
      Color(0xFF120F2E),
      Color(0xFF1E1840),
    ],
    HorizonPhase.dawn: [
      Color(0xFF1A1250),
      Color(0xFF2A2152),
      Color(0xFF3E2842),
    ],
    HorizonPhase.day: [Color(0xFF0F1438), Color(0xFF1A2050), Color(0xFF202A5C)],
    HorizonPhase.dusk: [
      Color(0xFF160F34),
      Color(0xFF2C1B48),
      Color(0xFF3E2842),
    ],
  };
}
