import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/app_motion.dart';
import 'day_part.dart';
import '../../../shared/widgets/clock_text.dart';

/// A pill organiser shaped as a clock: four lidded compartments (Morning,
/// Afternoon, Evening, Night) around a 24-hour ring, with a capsule seated
/// at each dose time. Midnight is at the bottom and noon at the top, so the
/// day runs left to right over the top, as on Today's arc, and night doses
/// wrap round underneath.
///
/// The [focus]ed time is drawn filled and shown in words, in the middle or,
/// at large text, beside the ring. Choosing a new time glides its capsule
/// the short way round; a time added drops into its place. With
/// [onChanged], a capsule can be dragged round the ring in [step]s, with a
/// tick for each, and a screen reader can step the focused time. It has no
/// clock and no loop.
class DoseDial extends StatefulWidget {
  const DoseDial({
    super.key,
    required this.times,
    this.focus = 0,
    this.size = DoseDial.diameter,
    this.trailing,
    this.onChanged,
  });

  final List<TimeOfDay> times;
  final int focus;
  final double size;

  /// Shown after the words, e.g. an edit hint.
  final Widget? trailing;

  /// A time at [index] moved to a new value. Null keeps the dial
  /// display-only.
  final void Function(int index, TimeOfDay time)? onChanged;

  static const diameter = 132.0;
  static const band = 10.0;

  /// Text scale from which the words move beside the ring.
  static const besideFrom = 1.5;

  /// Minutes per drag or screen-reader step: finer is under a finger's
  /// width on a ring this size.
  static const step = 15;

  /// How near a capsule a press must land to pick it up.
  static const reach = 24.0;

  /// The ring's angle for [minute] of the day, clockwise from the right
  /// (screen coordinates): midnight at the bottom, noon at the top.
  static double angleOf(double minute) =>
      math.pi / 2 + minute / 1440 * math.pi * 2;

  /// The minute of the day at [angle], the inverse of [angleOf].
  static double minuteAt(double angle) =>
      ((angle - math.pi / 2) / (math.pi * 2) * 1440) % 1440;

  /// [minute] snapped to the nearest [step], within the day.
  static int snap(double minute) => (minute / step).round() * step % 1440;

  @override
  State<DoseDial> createState() => _DoseDialState();
}

class _DoseDialState extends State<DoseDial> with TickerProviderStateMixin {
  late final AnimationController _glide = AnimationController(
    vsync: this,
    duration: AppMotion.emphasis,
    value: 1,
  );
  late final AnimationController _drop = AnimationController(
    vsync: this,
    duration: AppMotion.standard,
    value: 1,
  );
  late double _from = _focusMinute, _to = _focusMinute;
  int? _dropped, _dragging;

  double get _focusMinute {
    final times = widget.times;
    if (times.isEmpty) return 12 * 60;
    final t = times[widget.focus.clamp(0, times.length - 1)];
    return _minuteOf(t).toDouble();
  }

  double get _shown =>
      _from + (_to - _from) * AppMotion.curve.transform(_glide.value);

  static int _minuteOf(TimeOfDay t) => t.hour * 60 + t.minute;

  @override
  void didUpdateWidget(DoseDial old) {
    super.didUpdateWidget(old);
    final quiet = AppMotion.quiet(context);
    if (widget.times.length == old.times.length + 1 && !quiet) {
      _dropped = widget.times.length - 1;
      _drop.forward(from: 0);
    }
    final target = _focusMinute;
    final added = _dropped != null && _drop.isAnimating;
    if ((target - _to) % 1440 == 0) return;
    // A finger or a newly dropped capsule is already where it should be.
    if (quiet || _dragging != null || added) {
      _from = _to = target;
      _glide.value = 1;
      return;
    }
    // The short way round: 23:00 to 01:00 passes midnight, not noon.
    final from = _shown % 1440;
    var delta = (target - from) % 1440;
    if (delta > 720) delta -= 1440;
    _from = from;
    _to = from + delta;
    _glide.forward(from: 0);
  }

  @override
  void dispose() {
    _glide.dispose();
    _drop.dispose();
    super.dispose();
  }

  Offset _centre() => Offset(widget.size / 2, widget.size / 2);

  /// The capsule under [local], nearest first, the focused one winning ties.
  int? _hit(Offset local) {
    final r = DoseDialPainter.radiusIn(Size.square(widget.size));
    int? best;
    var bestDistance = DoseDial.reach;
    for (var i = 0; i < widget.times.length; i++) {
      final a = DoseDial.angleOf(_minuteOf(widget.times[i]).toDouble());
      final at = _centre() + Offset(math.cos(a), math.sin(a)) * r;
      final d = (at - local).distance;
      if (d < bestDistance || (d == bestDistance && i == widget.focus)) {
        best = i;
        bestDistance = d;
      }
    }
    return best;
  }

  void _move(Offset local) {
    final index = _dragging;
    if (index == null || index >= widget.times.length) return;
    final v = local - _centre();
    if (v.distance < 8) return;
    final minute = DoseDial.snap(DoseDial.minuteAt(math.atan2(v.dy, v.dx)));
    _set(index, minute);
  }

  void _set(int index, int minute) {
    if (_minuteOf(widget.times[index]) == minute) return;
    HapticFeedback.selectionClick();
    widget.onChanged!(
      index,
      TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
  }

  void _stepFocused(int by) {
    final times = widget.times;
    if (times.isEmpty) return;
    final index = widget.focus.clamp(0, times.length - 1);
    final minute = _minuteOf(times[index]);
    // Off-grid times step onto the grid first.
    final base = by > 0
        ? (minute ~/ DoseDial.step) * DoseDial.step
        : ((minute + DoseDial.step - 1) ~/ DoseDial.step) * DoseDial.step;
    _set(index, (base + by * DoseDial.step) % 1440);
  }

  String _stepped(TimeOfDay t, int by) {
    final m = (_minuteOf(t) + by * DoseDial.step) % 1440;
    return clockTime(context, TimeOfDay(hour: m ~/ 60, minute: m % 60));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context), colors = theme.colorScheme;
    final text = theme.textTheme;
    final times = widget.times;
    final focus = times.isEmpty
        ? null
        : widget.focus.clamp(0, times.length - 1);
    final focused = focus == null ? null : times[focus];
    final beside =
        MediaQuery.textScalerOf(context).scale(10) / 10 >=
            DoseDial.besideFrom ||
        MediaQuery.sizeOf(context).height < 640;
    final editable = widget.onChanged != null;

    final words = focused == null
        ? const SizedBox.shrink()
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: beside
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              ClockText(
                clockTime(context, focused),
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                dayPartLabel(l, dayPartOf(focused)),
                style: (beside ? text.bodyLarge : text.labelLarge)?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          );

    // A shade off the card in both themes, so the cells read on white too.
    final compartment = Color.lerp(
      colors.surfaceContainerHighest,
      colors.onSurfaceVariant,
      .1,
    )!;
    Widget ring = SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_glide, _drop]),
        builder: (context, child) => CustomPaint(
          key: const ValueKey('dose-dial'),
          painter: DoseDialPainter(
            minutes: [
              for (var i = 0; i < times.length; i++)
                i == focus ? _shown : _minuteOf(times[i]).toDouble(),
            ],
            focus: focus,
            dropped: _drop.isAnimating ? _dropped : null,
            drop: _drop.value,
            compartment: compartment,
            lit: Color.lerp(compartment, colors.primary, .4)!,
            capsule: colors.primary,
            rest: colors.onSurfaceVariant,
            cut: colors.surface,
            face: colors.surfaceContainerHigh.withValues(alpha: .55),
          ),
          child: child,
        ),
        child: beside ? null : Center(child: words),
      ),
    );
    if (editable) {
      ring = RawGestureDetector(
        gestures: {
          _CapsulePan: GestureRecognizerFactoryWithHandlers<_CapsulePan>(
            () => _CapsulePan(hits: (local) => _hit(local) != null),
            (pan) {
              pan
                // The capsule is the one under the finger when it went
                // down, not where the finger is once the drag is sure.
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = (d) {
                  _dragging = _hit(d.localPosition);
                  final index = _dragging;
                  if (index != null && index != widget.focus) {
                    // Picking up a capsule focuses it where it lies.
                    widget.onChanged!(index, widget.times[index]);
                  }
                }
                ..onUpdate = (d) {
                  _move(d.localPosition);
                }
                ..onEnd = (_) {
                  _dragging = null;
                }
                ..onCancel = () {
                  _dragging = null;
                };
            },
          ),
        },
        child: ring,
      );
    }

    return Semantics(
      container: true,
      label: l.schedules_dialLabel(spokenTimesLabel(context, times)),
      value: editable && focused != null ? clockTime(context, focused) : null,
      increasedValue: editable && focused != null ? _stepped(focused, 1) : null,
      decreasedValue: editable && focused != null
          ? _stepped(focused, -1)
          : null,
      onIncrease: editable && focused != null ? () => _stepFocused(1) : null,
      onDecrease: editable && focused != null ? () => _stepFocused(-1) : null,
      excludeSemantics: true,
      child: beside
          ? Row(
              children: [
                ring,
                const SizedBox(width: 16),
                Expanded(child: words),
                if (widget.trailing != null) widget.trailing!,
              ],
            )
          : SizedBox(
              width: double.infinity,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ring,
                  if (widget.trailing != null)
                    Positioned(right: 0, top: 0, child: widget.trailing!),
                ],
              ),
            ),
    );
  }
}

/// A pan that only starts on a capsule, and claims the finger at the
/// ordinary touch slop so it wins over the sheet scrolling around it. A
/// press elsewhere, or a tap, passes through to the card.
class _CapsulePan extends PanGestureRecognizer {
  _CapsulePan({required this.hits});

  final bool Function(Offset local) hits;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      hits(event.localPosition) && super.isPointerAllowed(event);

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved.abs() >
      computeHitSlop(pointerDeviceKind, gestureSettings);
}

/// The organiser ring: four moulded compartments with a seam between them,
/// the focused time's compartment lit, a faint lid face inside, and a
/// capsule seated at each time.
class DoseDialPainter extends CustomPainter {
  DoseDialPainter({
    required this.minutes,
    required this.focus,
    required this.compartment,
    required this.lit,
    required this.capsule,
    required this.rest,
    required this.cut,
    required this.face,
    this.dropped,
    this.drop = 1,
  });

  final List<double> minutes;
  final int? focus;

  /// A capsule just added, dropping into its place as [drop] runs to 1.
  final int? dropped;
  final double drop;
  final Color compartment, lit, capsule, rest, cut, face;

  /// Where one part of the day meets the next, in minutes.
  static const seams = [5 * 60, 12 * 60, 17 * 60, 21 * 60];

  /// The gap left at each seam, in logical pixels along the ring.
  static const seamGap = 3.0;

  /// The ring's centre line radius in a dial of [size].
  static double radiusIn(Size size) =>
      size.shortestSide / 2 - DoseDial.band / 2 - 3;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = radiusIn(size);
    final inner = r - DoseDial.band / 2, outer = r + DoseDial.band / 2;
    final focusMinute = focus == null ? null : minutes[focus!] % 1440;

    canvas.drawCircle(c, inner - 2, Paint()..color = face);
    for (var i = 0; i < seams.length; i++) {
      final from = seams[i].toDouble();
      var to = seams[(i + 1) % seams.length].toDouble();
      if (to <= from) to += 1440;
      final inside =
          focusMinute != null &&
          ((focusMinute >= from && focusMinute < to) ||
              (focusMinute + 1440 >= from && focusMinute + 1440 < to));
      final gap = seamGap / 2 / r;
      final start = DoseDial.angleOf(from) + gap;
      final sweep = DoseDial.angleOf(to) - DoseDial.angleOf(from) - gap * 2;
      // An annular cell; the round-joined outline softens its corners.
      final cell = Path()
        ..arcTo(Rect.fromCircle(center: c, radius: outer), start, sweep, true)
        ..arcTo(
          Rect.fromCircle(center: c, radius: inner),
          start + sweep,
          -sweep,
          false,
        )
        ..close();
      final color = inside ? lit : compartment;
      canvas.drawPath(cell, Paint()..color = color);
      canvas.drawPath(
        cell,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..color = color,
      );
    }
    // Faint hour ticks at midnight, six, noon and eighteen, on the face.
    final tick = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = rest.withValues(alpha: .4);
    for (var h = 0; h < 24; h += 6) {
      final a = DoseDial.angleOf(h * 60.0);
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (inner - 6), c + d * (inner - 10), tick);
    }
    // Capsules: the others first, so the focused one sits on top.
    for (var i = 0; i < minutes.length; i++) {
      if (i != focus) _capsule(canvas, c, r, minutes[i], false, _scale(i));
    }
    if (focus != null) {
      _capsule(canvas, c, r, minutes[focus!], true, _scale(focus!));
    }
  }

  /// A dropped capsule falls in from a little outside the ring, overshoots
  /// and settles.
  double _scale(int i) =>
      i == dropped ? Curves.easeOutBack.transform(drop.clamp(0.0, 1.0)) : 1;

  void _capsule(
    Canvas canvas,
    Offset c,
    double r,
    double minute,
    bool on,
    double scale,
  ) {
    if (scale <= 0) return;
    final a = DoseDial.angleOf(minute);
    final fall = (1 - scale).clamp(0.0, 1.0) * 14;
    final at = c + Offset(math.cos(a), math.sin(a)) * (r + fall);
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(scale);
    // Lying along the ring, like a capsule seated in its compartment.
    canvas.rotate(a + math.pi / 2);
    const w = 20.0, h = 10.0;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      const Radius.circular(h / 2),
    );
    canvas.drawRRect(body.inflate(1.8), Paint()..color = cut);
    if (on) {
      // Two halves, like the app's mark: one solid, one lighter.
      canvas.save();
      canvas.clipRRect(body);
      canvas.drawRect(
        const Rect.fromLTRB(-w / 2, -h / 2, 0, h / 2),
        Paint()..color = capsule,
      );
      canvas.drawRect(
        const Rect.fromLTRB(0, -h / 2, w / 2, h / 2),
        Paint()..color = Color.lerp(capsule, cut, .45)!,
      );
      canvas.restore();
    } else {
      canvas.drawRRect(body, Paint()..color = cut);
      canvas.drawRRect(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = rest,
      );
      canvas.drawLine(
        const Offset(0, -h / 2),
        const Offset(0, h / 2),
        Paint()
          ..strokeWidth = 1
          ..color = rest.withValues(alpha: .6),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DoseDialPainter old) =>
      old.focus != focus ||
      old.compartment != compartment ||
      old.lit != lit ||
      old.capsule != capsule ||
      old.rest != rest ||
      old.cut != cut ||
      old.face != face ||
      old.dropped != dropped ||
      old.drop != drop ||
      !_same(old.minutes, minutes);

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
