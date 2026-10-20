import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../shared/motion/app_motion.dart';
import '../../../shared/theme/app_theme.dart';

/// Where a period of the journal sits against the clock.
enum JournalPeriodTime { past, now, future }

/// The hours a journal period covers, as minutes of the day. Night wraps
/// past midnight, so its end is below its start.
({int start, int end}) journalPeriodSpan(String period) => switch (period) {
  'morning' => (start: 5 * 60, end: 12 * 60),
  'afternoon' => (start: 12 * 60, end: 17 * 60),
  'evening' => (start: 17 * 60, end: 21 * 60),
  _ => (start: 21 * 60, end: 5 * 60),
};

/// Places [period] before, at or after [now] on the same day. Night is
/// "now" from 21:00 and also before 05:00, when it is still last night.
JournalPeriodTime journalPeriodTime(String period, DateTime now) {
  const order = ['morning', 'afternoon', 'evening', 'night'];
  final minute = now.hour * 60 + now.minute;
  final current = minute < 5 * 60
      ? 'night'
      : order.firstWhere((p) {
          final span = journalPeriodSpan(p);
          return span.end <= span.start ||
              (minute >= span.start && minute < span.end);
        });
  final at = order.indexOf(period), here = order.indexOf(current);
  if (at == here) return JournalPeriodTime.now;
  // Before dawn every daytime period is still ahead.
  if (minute < 5 * 60) return JournalPeriodTime.future;
  return at < here ? JournalPeriodTime.past : JournalPeriodTime.future;
}

/// Whether a dose state counts as recorded: the person took or skipped it. A
/// recorded miss is the app's own outcome, not something recorded, so it stays
/// out of every "recorded" count (Day sky, This week, the period headers). The
/// period wells draw resolved doses instead, which also include misses.
bool journalDoseRecorded(String state) =>
    state == 'taken' || state == 'skipped';

/// A small round ink well for one period of the journal.
///
/// The ink level is how much of the period is resolved: one band per dose
/// that is no longer pending (taken, skipped or missed), in that dose's
/// outcome colour, with a faint mark on the glass for each dose so the count
/// can be read. A past missed dose therefore stays visibly different from a
/// pending one. The "N of M recorded" text beside a well counts only taken
/// and skipped doses (see [journalDoseRecorded]). Recording a dose raises
/// the ink while its stroke is written below, and the well rocks once; an
/// undo lowers it again as the stroke lifts off. The current period's well
/// is outlined in the primary colour and later ones are dimmed. Nothing
/// moves at rest, and quiet motion shows each change at once.
class JournalInkWell extends StatefulWidget {
  const JournalInkWell({
    super.key,
    required this.states,
    required this.time,
    this.from,
    this.size = 40,
  });

  /// The period's doses in order, by state. Every dose that is not pending
  /// adds ink in its outcome colour, a missed one included.
  final List<String> states;

  /// The same doses as they were a moment ago, when this well first shows.
  /// A period that appears because a dose was just recorded into it starts
  /// from these and fills, as if it had been there all along.
  final List<String>? from;
  final JournalPeriodTime time;
  final double size;

  /// Rises with the ink stroke under a recorded line, and falls with it.
  static const rise = Duration(milliseconds: 760);
  static const fall = Duration(milliseconds: 280);
  static const rock = Duration(milliseconds: 700);

  /// The rock starts as the rising ink lands, not while the well is empty.
  static const rockDelay = Duration(milliseconds: 400);

  @override
  State<JournalInkWell> createState() => _JournalInkWellState();
}

class _JournalInkWellState extends State<JournalInkWell>
    with TickerProviderStateMixin {
  late final _level = AnimationController(
    vsync: this,
    value: _fullness(widget.from ?? widget.states),
  );
  late final _rock = AnimationController(
    vsync: this,
    duration: JournalInkWell.rockDelay + JournalInkWell.rock,
  );

  double get _tilt {
    final total = _rock.duration!.inMicroseconds;
    final delay = JournalInkWell.rockDelay.inMicroseconds;
    return JournalInkWellPainter.tiltAt(
      (_rock.value * total - delay) / (total - delay),
    );
  }

  // The resolved outcomes (anything but pending) painted as bands. While an undo lowers the ink,
  // the band on its way out stays until the level has passed it.
  late List<String> _bands = _resolved(widget.from ?? widget.states);
  bool _started = false;

  static List<String> _resolved(List<String> states) => [
    for (final s in states)
      if (s != 'pending') s,
  ];

  static double _fullness(List<String> states) =>
      states.isEmpty ? 0 : _resolved(states).length / states.length;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final from = widget.from;
    if (from != null) _follow(from, widget.states);
  }

  @override
  void didUpdateWidget(JournalInkWell old) {
    super.didUpdateWidget(old);
    _follow(old.states, widget.states);
  }

  void _follow(List<String> was, List<String> now) {
    final before = _resolved(was), after = _resolved(now);
    final target = _fullness(now);
    if (target == _level.value && listEquals(_bands, after)) return;
    if (AppMotion.quiet(context)) {
      _bands = after;
      _level.value = target;
      return;
    }
    final rising = target >= _level.value;
    _bands = after.length >= before.length
        ? after
        : [...after, ...before.skip(after.length)];
    _level
        .animateTo(
          target,
          duration: rising ? JournalInkWell.rise : JournalInkWell.fall,
          curve: Curves.easeInOutCubic,
        )
        .whenCompleteOrCancel(() {
          if (mounted) setState(() => _bands = _resolved(widget.states));
        });
    if (after.length > before.length) _rock.forward(from: 0);
  }

  @override
  void dispose() {
    _level.dispose();
    _rock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final now = widget.time == JournalPeriodTime.now;
    return ExcludeSemantics(
      child: AnimatedOpacity(
        opacity: widget.time == JournalPeriodTime.future ? .5 : 1,
        duration: AppMotion.duration(context, milliseconds: 600),
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([_level, _rock]),
            builder: (context, _) => CustomPaint(
              size: Size.square(widget.size),
              painter: JournalInkWellPainter(
                level: _level.value,
                marks: widget.states.length,
                bands: [for (final s in _bands) semantic.forState(s)],
                tilt: _tilt,
                glass: Color.alphaBlend(
                  cs.onSurface.withValues(alpha: .06),
                  cs.surface,
                ),
                edge: now ? cs.primary : cs.outline,
                edgeWidth: now ? 2 : 1.3,
                shine: Colors.white.withValues(
                  alpha: theme.brightness == Brightness.dark ? .28 : .85,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class JournalInkWellPainter extends CustomPainter {
  const JournalInkWellPainter({
    required this.level,
    required this.marks,
    required this.bands,
    required this.tilt,
    required this.glass,
    required this.edge,
    required this.edgeWidth,
    required this.shine,
  });

  /// How full the well is, 0..1.
  final double level;

  /// How many doses the period holds: one mark on the glass between each.
  final int marks;

  /// The colour of each recorded dose's band, bottom first.
  final List<Color> bands;

  /// How far the well leans while it rocks, in radians.
  final double tilt;
  final Color glass, edge, shine;
  final double edgeWidth;

  /// The rock after a dose is recorded: one lean and a smaller lean back,
  /// settling by the end. [t] runs 0..1.
  static double tiltAt(double t) => t <= 0 || t >= 1
      ? 0
      : .11 * math.sin(2 * math.pi * 1.5 * t) * math.pow(1 - t, 1.6);

  /// The well's glass: a squat pot with a flat base, straight sides and
  /// sloping shoulders up to a short neck.
  @visibleForTesting
  static Path potFor(double s) {
    final cx = s / 2;
    const left = .12, right = .88, bottom = .88, shoulder = .5, neck = .13;
    const top = .3, foot = .07;
    return Path()
      ..moveTo(s * (left + foot), s * bottom)
      ..lineTo(s * (right - foot), s * bottom)
      ..quadraticBezierTo(s * right, s * bottom, s * right, s * (bottom - foot))
      ..lineTo(s * right, s * (shoulder + .06))
      ..cubicTo(
        s * right,
        s * (shoulder - .06),
        cx + s * (neck + .12),
        s * (shoulder - .1),
        cx + s * neck,
        s * (shoulder - .12),
      )
      ..lineTo(cx + s * neck, s * top)
      ..lineTo(cx - s * neck, s * top)
      ..lineTo(cx - s * neck, s * (shoulder - .12))
      ..cubicTo(
        cx - s * (neck + .12),
        s * (shoulder - .1),
        s * left,
        s * (shoulder - .06),
        s * left,
        s * (shoulder + .06),
      )
      ..lineTo(s * left, s * (bottom - foot))
      ..quadraticBezierTo(s * left, s * bottom, s * (left + foot), s * bottom)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final pot = potFor(s);
    final lip = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(s / 2, s * .3),
        width: s * .36,
        height: s * .08,
      ),
      Radius.circular(s * .03),
    );

    canvas.save();
    // Rock about the middle of the base the well stands on.
    final foot = Offset(s / 2, s * .88);
    canvas.translate(foot.dx, foot.dy);
    canvas.rotate(tilt);
    canvas.translate(-foot.dx, -foot.dy);

    canvas.drawPath(pot, Paint()..color = glass);

    // The ink rises up the straight sides, from just above the base to
    // just under the shoulders, so its height is the share recorded.
    final floor = s * .85;
    final brim = s * .55;
    double heightOf(double f) => lerpDouble(floor, brim, f)!;
    final surface = heightOf(level.clamp(0.0, 1.0));
    if (level > 0 && bands.isNotEmpty && marks > 0) {
      canvas.save();
      canvas.clipPath(pot);
      // The ink lags the glass, so its surface stays nearer level.
      canvas.translate(s / 2, surface);
      canvas.rotate(-tilt * .8);
      canvas.translate(-s / 2, -surface);
      // Each band runs down to the base, painted from the top one down, so
      // no seam of glass shows between two bands.
      for (var i = bands.length - 1; i >= 0; i--) {
        final top = math.max(heightOf((i + 1) / marks), surface);
        canvas.drawRect(
          Rect.fromLTRB(-s * .2, top, s * 1.2, s * 1.2),
          Paint()..color = bands[i],
        );
      }
      // A lighter meniscus where the ink meets the air.
      canvas.drawLine(
        Offset(-s * .2, surface + .6),
        Offset(s * 1.2, surface + .6),
        Paint()
          ..strokeWidth = 1.2
          ..color = Color.lerp(bands.last, Colors.white, .4)!,
      );
      canvas.restore();
    }

    // One mark on the glass between each dose, on the right; light where
    // the ink covers it.
    final tick = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var k = 1; k < marks; k++) {
      final y = heightOf(k / marks);
      tick.color = y > surface + 1 && level > 0
          ? Colors.white.withValues(alpha: .6)
          : edge.withValues(alpha: edge.a * .7);
      canvas.drawLine(Offset(s * .8, y), Offset(s * .7, y), tick);
    }

    // A highlight down the left side of the glass.
    canvas.drawLine(
      Offset(s * .21, s * .6),
      Offset(s * .21, s * .76),
      Paint()
        ..strokeWidth = s * .05
        ..strokeCap = StrokeCap.round
        ..color = shine,
    );

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = edgeWidth
      ..strokeJoin = StrokeJoin.round
      ..color = edge;
    canvas.drawPath(pot, line);
    canvas.drawRRect(lip, Paint()..color = glass);
    canvas.drawRRect(lip, line);
    canvas.restore();
  }

  @override
  bool shouldRepaint(JournalInkWellPainter old) =>
      old.level != level ||
      old.marks != marks ||
      !listEquals(old.bands, bands) ||
      old.tilt != tilt ||
      old.glass != glass ||
      old.edge != edge ||
      old.edgeWidth != edgeWidth ||
      old.shine != shine;
}

/// A handwritten stroke under a journal line that has been recorded.
///
/// It writes itself, left to right with a pen tip, when the line turns from
/// planned to taken while on screen; a skipped line gets a lighter dashed
/// stroke. Undo lifts the ink back off. Lines that were already recorded
/// show their stroke at rest. Each line's stroke has its own hand, seeded by
/// [seed].
class InkSignature extends StatefulWidget {
  const InkSignature({
    super.key,
    required this.state,
    required this.seed,
    this.height = 12,
  });

  /// The line's state: 'pending', 'taken', 'skipped' or another recorded
  /// state.
  final String state;
  final String seed;
  final double height;

  @override
  State<InkSignature> createState() => _InkSignatureState();
}

class _InkSignatureState extends State<InkSignature>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 760),
    reverseDuration: const Duration(milliseconds: 280),
    value: widget.state == 'pending' ? 0 : 1,
  );
  // The state the ink was last written for; kept while an undo erases it.
  late String _shown = widget.state;

  @override
  void didUpdateWidget(InkSignature old) {
    super.didUpdateWidget(old);
    if (old.state == widget.state) return;
    final quiet = AppMotion.quiet(context);
    if (widget.state == 'pending') {
      if (quiet) {
        _ink.value = 0;
      } else {
        _ink.reverse();
      }
    } else {
      _shown = widget.state;
      if (quiet) {
        _ink.value = 1;
      } else {
        _ink.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _ink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return ExcludeSemantics(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _ink,
          builder: (context, _) => _ink.value == 0
              ? const SizedBox.shrink()
              : CustomPaint(
                  painter: InkSignaturePainter(
                    progress: Curves.easeInOutCubic.transform(_ink.value),
                    color: semantic.forState(_shown),
                    dashed: _shown != 'taken',
                    seed: inkSeed(widget.seed),
                    writing:
                        _ink.isAnimating &&
                        _ink.status == AnimationStatus.forward,
                  ),
                ),
        ),
      ),
    );
  }
}

/// A stable hash of [id] (FNV-1a), so a line keeps its hand across runs.
int inkSeed(String id) {
  var hash = 0x811c9dc5;
  for (final unit in id.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

class InkSignaturePainter extends CustomPainter {
  const InkSignaturePainter({
    required this.progress,
    required this.color,
    required this.dashed,
    required this.seed,
    this.writing = false,
  });

  final double progress;
  final Color color;
  final bool dashed;
  final int seed;
  final bool writing;

  /// The stroke for a line of [width]: a few loose humps that settle, then
  /// a small rising flourish. The same [seed] always gives the same hand.
  @visibleForTesting
  static Path strokeFor(Size size, int seed, {bool dashed = false}) {
    final random = math.Random(seed);
    final length = math.min(
      size.width * (.36 + random.nextDouble() * .14),
      200.0,
    );
    final h = size.height;
    if (dashed) {
      // A skipped line gets a loose, nearly level stroke.
      return Path()
        ..moveTo(0, h * .55)
        ..quadraticBezierTo(
          length * .5,
          h * (.4 + random.nextDouble() * .3),
          length,
          h * .5,
        );
    }
    // One confident swoosh: in low from the left, a slight belly, then a
    // quick flick up and back, the way a pen leaves the page.
    final belly = .78 + random.nextDouble() * .16;
    final lean = .35 + random.nextDouble() * .25;
    final flick = 8 + random.nextDouble() * 6;
    return Path()
      ..moveTo(0, h * .42)
      ..cubicTo(
        length * .2,
        h * belly,
        length * (.55 + lean * .2),
        h * belly,
        length,
        h * .52,
      )
      ..quadraticBezierTo(
        length + flick,
        h * .3,
        length + flick * .45,
        h * .02,
      );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final path = strokeFor(size, seed, dashed: dashed);
    final metric = path.computeMetrics().first;
    final drawn = metric.length * progress;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    if (dashed) {
      paint.strokeWidth = 1.4;
      paint.color = color.withValues(alpha: .8);
      for (var at = 0.0; at < drawn; at += 9) {
        canvas.drawPath(metric.extractPath(at, math.min(at + 5, drawn)), paint);
      }
      return;
    }
    // A pen presses in the middle of a stroke and lifts at both ends.
    const pieces = 28;
    final step = metric.length / pieces;
    for (var i = 0; i < pieces; i++) {
      final from = i * step;
      if (from >= drawn) break;
      final t = (i + .5) / pieces;
      paint.strokeWidth = .9 + 2.1 * math.sin(math.pi * math.min(t * 1.15, 1));
      canvas.drawPath(
        metric.extractPath(from, math.min(from + step + .6, drawn)),
        paint,
      );
    }
    if (writing && progress < 1) {
      final tip = metric.getTangentForOffset(drawn)?.position;
      if (tip != null) {
        canvas.drawCircle(tip, 2.6, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(InkSignaturePainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.dashed != dashed ||
      old.seed != seed ||
      old.writing != writing;
}
