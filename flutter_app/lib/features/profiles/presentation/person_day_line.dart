import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/medication/care_day.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/scene/dose_bead.dart';
import '../../../shared/scene/scene_clock.dart';
import '../../../shared/theme/app_theme.dart';
import '../../dashboard/history_day_line.dart';
import '../profile_provider.dart';

/// The minute of the day [entry] belongs at: its planned time, or for an
/// as-needed dose the time it was taken. Null when neither is known.
int? personDoseMinute(CareDayEntry entry) {
  final planned = entry.occurrence.plannedLocalTime;
  if (planned != null) {
    final parts = planned.split(':');
    final h = int.tryParse(parts.first);
    final m = parts.length > 1 ? int.tryParse(parts[1]) : 0;
    if (h != null && m != null) return (h * 60 + m).clamp(0, 1439);
  }
  final actual = entry.head?.actualAt?.toLocal();
  if (entry.occurrence.source == 'prn' && actual != null) {
    return actual.hour * 60 + actual.minute;
  }
  return null;
}

/// A person's doses for [care]'s day in time order, drawn the way History
/// draws a day. [now] decides which planned doses have passed unrecorded.
List<DayLineDose> personLineDoses(
  BuildContext context,
  CareDay care,
  DateTime now,
) {
  final l = AppLocalizations.of(context);
  final nowMinute = now.hour * 60 + now.minute;
  return [
    for (final entry in care.entries)
      if (personDoseMinute(entry) case final minute?)
        () {
          final bead = DoseBead.of(
            entry.occurrence.state,
            prn: entry.occurrence.source == 'prn',
            passed: minute < nowMinute,
          );
          return DayLineDose(
            id: entry.occurrence.id,
            minute: minute,
            bead: bead,
            label: l.people_lineDose(
              TimeOfDay(
                hour: minute ~/ 60,
                minute: minute % 60,
              ).format(context),
              entry.snapshot.pillName,
              doseBeadOutcome(l, bead),
            ),
          );
        }(),
  ]..sort((a, b) => a.minute.compareTo(b.minute));
}

/// How many planned doses [doses] holds and how many of them are taken. An
/// as-needed dose is drawn but never owed.
({int planned, int taken}) personDayCount(Iterable<DayLineDose> doses) {
  var planned = 0, taken = 0;
  for (final d in doses) {
    if (d.bead == DoseBead.asNeeded) continue;
    planned++;
    if (d.bead == DoseBead.taken) taken++;
  }
  return (planned: planned, taken: taken);
}

/// Every planned dose of the day is taken.
bool personDayComplete(Iterable<DayLineDose> doses) {
  final count = personDayCount(doses);
  return count.planned > 0 && count.taken == count.planned;
}

/// A person's day drawn somewhere on the glass: where each of its minutes
/// sits, in global coordinates, and the dots it carries.
@immutable
class PersonDayShape {
  const PersonDayShape({
    required this.at,
    required this.start,
    required this.end,
    required this.dots,
    required this.stroke,
    required this.width,
    required this.radius,
    required this.cut,
  });

  final Offset Function(double minute) at;

  /// The stretch of the day drawn, in minutes.
  final int start, end;
  final List<({double minute, DoseBead bead, Color color})> dots;
  final Color stroke, cut;

  /// Stroke width and dot radius.
  final double width, radius;
}

final personDayLocatorProvider = Provider<PersonDayLocator>((ref) {
  final locator = PersonDayLocator();
  ref.onDispose(locator.dispose);
  return locator;
});

/// Finds each person's ring and line on the glass, so a ring can unroll into
/// a line, and veils a line while that happens.
class PersonDayLocator {
  final _rings = <String, PersonDayShape? Function()>{};
  final _lines = <String, PersonDayShape? Function()>{};
  final _veils = <String, ValueNotifier<double>>{};

  void attachRing(String id, PersonDayShape? Function() resolve) =>
      _rings[id] = resolve;
  void detachRing(String id, PersonDayShape? Function() resolve) {
    if (_rings[id] == resolve) _rings.remove(id);
  }

  void attachLine(String id, PersonDayShape? Function() resolve) =>
      _lines[id] = resolve;
  void detachLine(String id, PersonDayShape? Function() resolve) {
    if (_lines[id] == resolve) _lines.remove(id);
  }

  PersonDayShape? ring(String id) => _rings[id]?.call();
  PersonDayShape? line(String id) => _lines[id]?.call();

  /// 1 hides [id]'s line, 0 shows it. Only the unroll sets it.
  ValueNotifier<double> veil(String id) => _veils[id] ??= ValueNotifier(0);

  /// Completes once the latest unroll has landed (at once when none runs).
  Future<void> landed = Future.value();

  void dispose() {
    for (final veil in _veils.values) {
      veil.dispose();
    }
    _veils.clear();
  }
}

/// The shape a held or plucked line takes: held, a triangle peaking under
/// the finger; let go, it rings once in its first mode and settles flat.
@immutable
class StringBend {
  const StringBend({this.at = .5, this.depth = 0, this.ring});

  /// Where across the line (0..1) it is held.
  final double at;

  /// How far it is pulled, in dp; positive is down.
  final double depth;

  /// Null while held; 0..1 through the ring-out once let go.
  final double? ring;

  static const flat = StringBend();
  static const deflect = 6.0, reach = 8.0;
  static const ringOut = Duration(milliseconds: 700);

  /// Rings about three times a second.
  static const hertz = 3.0;

  /// How far the line is displaced at [u] (0..1 across it), in dp.
  double offset(double u) {
    if (depth == 0) return 0;
    final peak = at.clamp(.06, .94);
    final triangle = u < peak ? u / peak : (1 - u) / (1 - peak);
    final t = ring;
    if (t == null) return depth * triangle;
    if (t >= 1) return 0;
    // The pluck's corner smooths into the string's first mode at once,
    // then that mode swings and dies away.
    final shape = lerpDouble(
      triangle,
      math.sin(math.pi * u),
      (t * 7).clamp(0.0, 1.0),
    )!;
    final seconds = t * ringOut.inMilliseconds / 1000;
    return depth *
        shape *
        math.cos(math.pi * 2 * hertz * seconds) *
        math.exp(-3.2 * t) *
        (1 - t);
  }

  @override
  bool operator ==(Object other) =>
      other is StringBend &&
      other.at == at &&
      other.depth == depth &&
      other.ring == ring;

  @override
  int get hashCode => Object.hash(at, depth, ring);
}

/// A person's day as a thin line on their People card, beside the
/// time-of-day chip: a dot at each dose's time, the "now" pin, and the line
/// turns the taken colour once every planned dose is taken.
///
/// * It draws itself once when the card appears.
/// * A dose recorded anywhere fills its dot with a small pop.
/// * Tapping a dot shows its words in a bubble until tapped again or
///   anywhere else.
/// * Pressing and holding arms the line like a string: it follows the
///   finger a few dp and rings out once when let go. It records nothing.
///
/// A screen reader hears one summary ("2 of 3 taken today"). Still at rest:
/// the only repaint is the "now" pin's, once a minute.
class PersonDayLine extends StatefulWidget {
  const PersonDayLine({
    super.key,
    required this.personId,
    required this.care,
    this.locator,
  });

  final String personId;
  final CareDay care;
  final PersonDayLocator? locator;

  static const height = 32.0, lineY = 20.0, radius = 3.6;
  static const draw = Duration(milliseconds: 900);
  static const pop = Duration(milliseconds: 320);
  static const arm = Duration(milliseconds: 300);

  @override
  State<PersonDayLine> createState() => _PersonDayLineState();
}

class _PersonDayLineState extends State<PersonDayLine>
    with TickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: PersonDayLine.draw,
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: PersonDayLine.pop,
    value: 1,
  );
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: StringBend.ringOut,
  );
  final _bend = ValueNotifier<StringBend>(StringBend.flat);
  final _link = LayerLink();
  final _bubble = OverlayPortalController();

  /// Doses whose dot pops while [_pop] runs.
  Set<String> _popped = const {};
  String? _selected;
  double _reach = 0;

  /// The line as last laid out, for [_onGlass].
  ({DayLineFrame frame, double width, bool complete, Color line, Color cut})?
  _laid;

  @override
  void initState() {
    super.initState();
    widget.locator?.attachLine(widget.personId, _onGlass);
    // A line arriving from an unrolling ring is already whole.
    if ((widget.locator?.veil(widget.personId).value ?? 0) > 0) {
      _draw.value = 1;
    }
    _ring.addListener(() {
      final bend = _bend.value;
      _bend.value = _ring.isCompleted
          ? StringBend.flat
          : StringBend(at: bend.at, depth: bend.depth, ring: _ring.value);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.quiet(context)) {
      _draw.value = 1;
    } else if (_draw.value == 0 && !_draw.isAnimating) {
      _draw.forward();
    }
  }

  @override
  void didUpdateWidget(PersonDayLine old) {
    super.didUpdateWidget(old);
    if (old.locator != widget.locator || old.personId != widget.personId) {
      old.locator?.detachLine(old.personId, _onGlass);
      widget.locator?.attachLine(widget.personId, _onGlass);
    }
    if (identical(old.care, widget.care) || AppMotion.quiet(context)) return;
    final now = DateTime.now();
    final before = {
      for (final d in personLineDoses(context, old.care, now)) d.id: d.bead,
    };
    final recorded = {
      for (final d in personLineDoses(context, widget.care, now))
        if (before.containsKey(d.id) &&
            before[d.id] != d.bead &&
            (d.bead == DoseBead.taken || d.bead == DoseBead.skipped))
          d.id,
    };
    if (recorded.isEmpty) return;
    _popped = recorded;
    _pop.forward(from: 0);
  }

  @override
  void dispose() {
    widget.locator?.detachLine(widget.personId, _onGlass);
    _draw.dispose();
    _pop.dispose();
    _ring.dispose();
    _bend.dispose();
    super.dispose();
  }

  PersonDayShape? _onGlass() {
    final laid = _laid;
    final box = context.findRenderObject();
    if (laid == null || box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    final theme = Theme.of(context);
    final frame = laid.frame;
    final origin = box.localToGlobal(Offset.zero);
    Offset at(double minute) =>
        origin +
        Offset(
          DayLineFrame.x(
            minute,
            frame.start,
            frame.end,
            laid.width,
          ).clamp(0.0, laid.width),
          PersonDayLine.lineY,
        );
    return PersonDayShape(
      at: at,
      start: frame.start,
      end: frame.end,
      dots: [
        for (final c in frame.clusters)
          (minute: c.minute, bead: c.bead, color: c.bead.colorIn(theme)),
      ],
      stroke: laid.line,
      width: laid.complete ? 2 : 1.3,
      radius: PersonDayLine.radius,
      cut: laid.cut,
    );
  }

  void _toggle(String key) {
    HapticFeedback.selectionClick();
    // The label may hang left of the line, over the time-of-day chip, but
    // never past the line's right end: that is where the next card starts.
    final box = context.findRenderObject();
    _reach = box is RenderBox && box.attached
        ? math.max(0, box.localToGlobal(Offset.zero).dx - _Bubble.margin)
        : 0;
    setState(() => _selected = _selected == key ? null : key);
    _selected == null ? _bubble.hide() : _bubble.show();
  }

  void _dismiss() {
    if (_selected == null) return;
    setState(() => _selected = null);
    _bubble.hide();
  }

  void _hold(Offset local, double width, {double drag = 0}) {
    _ring.stop();
    _bend.value = StringBend(
      at: width <= 0 ? .5 : (local.dx / width).clamp(0.0, 1.0),
      depth: (StringBend.deflect + drag * .5).clamp(
        -StringBend.reach,
        StringBend.reach,
      ),
    );
  }

  void _letGo() {
    if (_bend.value.ring != null || _bend.value.depth == 0) return;
    if (AppMotion.quiet(context)) {
      _bend.value = StringBend.flat;
      return;
    }
    HapticFeedback.lightImpact();
    _ring.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final count = personDayCount(
      personLineDoses(context, widget.care, DateTime.now()),
    );
    final line = SceneClock(builder: _line);
    final veil = widget.locator?.veil(widget.personId);
    return Semantics(
      container: true,
      label: l.people_dayProgress('${count.planned}', '${count.taken}'),
      child: ExcludeSemantics(
        child: veil == null
            ? line
            : ValueListenableBuilder<double>(
                valueListenable: veil,
                builder: (context, hidden, child) =>
                    Opacity(opacity: 1 - hidden, child: child),
                child: line,
              ),
      ),
    );
  }

  Widget _line(BuildContext context, DateTime now) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final semantic = theme.extension<AppSemanticColors>();
    final doses = personLineDoses(context, widget.care, now);
    final complete = personDayComplete(doses);
    final nowMinute = now.hour * 60 + now.minute;
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = bounds.maxWidth;
        final frame = DayLineFrame.of(
          doses,
          width: width,
          now: nowMinute,
          touch: PersonDayLine.radius * 2 + 3,
        );
        final lineColor = complete
            ? semantic?.statusTaken ?? colors.primary
            : colors.onSurfaceVariant.withValues(alpha: .45);
        final cut = colors.surface;
        _laid = (
          frame: frame,
          width: width,
          complete: complete,
          line: lineColor,
          cut: cut,
        );
        final xs = [
          for (final c in frame.clusters)
            DayLineFrame.x(c.minute, frame.start, frame.end, width),
        ];
        final selected = frame.clusters
            .where((c) => c.key == _selected)
            .firstOrNull;
        final selectedX = selected == null
            ? 0.0
            : xs[frame.clusters.indexOf(selected)];
        final countStyle = theme.textTheme.labelSmall!.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: colors.onSurface,
        );
        return TapRegion(
          groupId: this,
          onTapOutside: (_) => _dismiss(),
          child: CompositedTransformTarget(
            link: _link,
            child: OverlayPortal(
              controller: _bubble,
              overlayChildBuilder: (context) => selected == null
                  ? const SizedBox.shrink()
                  : _Bubble(
                      group: this,
                      link: _link,
                      x: selectedX,
                      width: width,
                      reach: _reach,
                      cluster: selected,
                    ),
              child: RawGestureDetector(
                gestures: {
                  LongPressGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        LongPressGestureRecognizer
                      >(
                        () => LongPressGestureRecognizer(
                          duration: PersonDayLine.arm,
                          debugOwner: this,
                        ),
                        (recognizer) => recognizer
                          ..onLongPressStart = (details) {
                            HapticFeedback.selectionClick();
                            _hold(details.localPosition, width);
                          }
                          ..onLongPressMoveUpdate = (details) {
                            _hold(
                              details.localPosition,
                              width,
                              drag: details.offsetFromOrigin.dy,
                            );
                          }
                          ..onLongPressEnd = (_) {
                            _letGo();
                          }
                          ..onLongPressCancel = _letGo,
                      ),
                },
                child: SizedBox(
                  height: PersonDayLine.height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: const ValueKey('person-day-line'),
                            painter: PersonLinePainter(
                              frame: frame,
                              now: nowMinute,
                              draw: _draw,
                              pop: _pop,
                              popped: _popped,
                              bend: _bend,
                              selected: _selected,
                              line: lineColor,
                              complete: complete,
                              cut: cut,
                              accent: colors.primary,
                              beadColor: (bead) => bead.colorIn(theme),
                              countStyle: countStyle,
                              textDirection: Directionality.of(context),
                            ),
                          ),
                        ),
                      ),
                      for (var i = 0; i < frame.clusters.length; i++)
                        Positioned(
                          // A dot's touch area reaches halfway to its
                          // neighbours, so close dots never steal each
                          // other's taps.
                          left: math.max(
                            xs[i] - 20,
                            i == 0 ? 0 : (xs[i - 1] + xs[i]) / 2,
                          ),
                          width: math.max(
                            math.min(
                                  xs[i] + 20,
                                  i == xs.length - 1
                                      ? width
                                      : (xs[i] + xs[i + 1]) / 2,
                                ) -
                                math.max(
                                  xs[i] - 20,
                                  i == 0 ? 0 : (xs[i - 1] + xs[i]) / 2,
                                ),
                            1,
                          ),
                          top: PersonDayLine.lineY - 18,
                          height: 36,
                          child: GestureDetector(
                            key: ValueKey(
                              'person-line-dot-${frame.clusters[i].key}',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _toggle(frame.clusters[i].key),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The words behind a tapped dot, hung under it. It never dismisses itself.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.group,
    required this.link,
    required this.x,
    required this.width,
    required this.reach,
    required this.cluster,
  });

  final Object group;
  final LayerLink link;
  final double x, width;

  /// How far left of the line's start the label may go.
  final double reach;
  final DayLineCluster cluster;

  /// The gap kept between the label and the screen's left edge.
  static const margin = 20.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final cut = colors.surfaceContainerHigh;
    return CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      offset: const Offset(0, PersonDayLine.lineY + 12),
      child: CustomSingleChildLayout(
        delegate: _BubbleLayout(x: x, width: width, reach: reach),
        child: TapRegion(
          groupId: group,
          child: Material(
            key: ValueKey('person-line-label-${cluster.key}'),
            color: cut,
            elevation: 3,
            shadowColor: colors.shadow.withValues(alpha: .3),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final dose in cluster.doses)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CustomPaint(
                            size: const Size(12, 12),
                            painter: _BeadPainter(
                              dose.bead,
                              dose.bead.colorIn(theme),
                              cut,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              dose.label,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Centres the label under its dot, held between [reach] left of the line's
/// start and the line's right end.
class _BubbleLayout extends SingleChildLayoutDelegate {
  const _BubbleLayout({
    required this.x,
    required this.width,
    required this.reach,
  });

  final double x, width, reach;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: math.max(120, math.min(300, width + reach)));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final left = -reach, right = width - child.width;
    return Offset(
      right < left ? left : (x - child.width / 2).clamp(left, right),
      0,
    );
  }

  @override
  bool shouldRelayout(_BubbleLayout old) =>
      old.x != x || old.width != width || old.reach != reach;
}

class _BeadPainter extends CustomPainter {
  const _BeadPainter(this.bead, this.color, this.cut);
  final DoseBead bead;
  final Color color, cut;

  @override
  void paint(Canvas canvas, Size size) => paintDoseBead(
    canvas,
    size.center(Offset.zero),
    size.shortestSide / 2 - 1.4,
    bead,
    color: color,
    cut: cut,
  );

  @override
  bool shouldRepaint(_BeadPainter old) =>
      old.bead != bead || old.color != color || old.cut != cut;
}

/// Paints a person's day line. Repaints from [draw], [pop] and [bend]
/// without a rebuild; at rest ([draw] 1, [pop] 1, [bend] flat) it is a
/// still drawing.
class PersonLinePainter extends CustomPainter {
  PersonLinePainter({
    required this.frame,
    required this.now,
    required this.draw,
    required this.pop,
    required this.popped,
    required this.bend,
    required this.selected,
    required this.line,
    required this.complete,
    required this.cut,
    required this.accent,
    required this.beadColor,
    required this.countStyle,
    this.textDirection = TextDirection.ltr,
  }) : super(repaint: Listenable.merge([draw, pop, bend]));

  final DayLineFrame frame;

  /// The minute of "now".
  final int now;
  final Animation<double> draw, pop;
  final Set<String> popped;
  final ValueListenable<StringBend> bend;
  final String? selected;
  final Color line, cut, accent;
  final bool complete;
  final Color Function(DoseBead bead) beadColor;
  final TextStyle countStyle;
  final TextDirection textDirection;

  final Map<String, TextPainter> _text = {};

  /// A dot's size through its pop: a quick swell past full, then settle.
  static double popScale(double t) =>
      t >= 1 ? 1 : 1 + .55 * math.sin(math.pi * t) * math.pow(1 - t, .6);

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final sweep = Curves.easeInOutCubic.transform(draw.value) * width;
    final shape = bend.value;
    double yAt(double x) =>
        PersonDayLine.lineY + shape.offset((x / width).clamp(0.0, 1.0));

    if (sweep > 0) {
      final path = Path()..moveTo(0, yAt(0));
      const steps = 40;
      for (var i = 1; i <= steps; i++) {
        final x = sweep * i / steps;
        path.lineTo(x, yAt(x));
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = complete ? 2 : 1.3
          ..color = line,
      );
    }

    final pinX = DayLineFrame.x(now.toDouble(), frame.start, frame.end, width);
    final pinShown = ((sweep - pinX) / 24).clamp(0.0, 1.0);
    if (pinShown > 0) {
      paintNowPin(
        canvas,
        Offset(pinX, yAt(pinX)),
        color: accent.withValues(alpha: accent.a * pinShown),
      );
    }

    const r = PersonDayLine.radius;
    for (final c in frame.clusters) {
      final x = DayLineFrame.x(c.minute, frame.start, frame.end, width);
      // Each dot pops in as the line reaches it.
      final reached = ((sweep - x) / 28 + 1).clamp(0.0, 1.0);
      if (reached <= 0) continue;
      var grow = Curves.easeOutBack.transform(reached);
      if (c.doses.any((d) => popped.contains(d.id))) {
        grow *= popScale(pop.value);
      }
      final at = Offset(x, yAt(x));
      if (c.key == selected) {
        canvas.drawCircle(
          at,
          r + 3.4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = accent,
        );
      }
      final bead = c.bead;
      paintDoseBead(
        canvas,
        at,
        r * grow,
        bead,
        color: beadColor(bead),
        cut: cut,
      );
      if (c.doses.length < 2 || reached < 1) continue;
      final text = _text['${c.doses.length}'] ??= TextPainter(
        text: TextSpan(text: '${c.doses.length}', style: countStyle),
        textDirection: textDirection,
      )..layout();
      text.paint(canvas, Offset(at.dx + r * .6, at.dy - r - text.height + 1));
    }
  }

  @override
  bool shouldRepaint(PersonLinePainter old) =>
      old.frame.start != frame.start ||
      old.frame.end != frame.end ||
      !listEquals(
        [for (final c in old.frame.clusters) ...c.doses],
        [for (final c in frame.clusters) ...c.doses],
      ) ||
      old.frame.clusters.length != frame.clusters.length ||
      old.now != now ||
      old.draw != draw ||
      old.pop != pop ||
      !setEquals(old.popped, popped) ||
      old.bend != bend ||
      old.selected != selected ||
      old.line != line ||
      old.complete != complete ||
      old.cut != cut ||
      old.accent != accent ||
      old.countStyle != countStyle;
}

/// A person's day wrapped as a ring around their avatar on the compact
/// People rows. It opens at the top, where the day starts and ends; dots sit
/// at each dose's time and a small "now" tick points out of it. A screen
/// reader hears one summary. Still at rest but for the minute tick.
class PersonDayRing extends StatefulWidget {
  const PersonDayRing({
    super.key,
    required this.personId,
    required this.care,
    required this.child,
    this.avatar = 40,
    this.locator,
  });

  final String personId;
  final CareDay care;

  /// The avatar the ring goes round, [avatar] across.
  final Widget child;
  final double avatar;
  final PersonDayLocator? locator;

  /// Space between the avatar and the ring, and the dot radius.
  static const gap = 4.0, radius = 2.6;

  /// The opening at the top, in radians.
  static const opening = .46;

  double get ringRadius => avatar / 2 + gap;
  double get extent => extentFor(avatar);

  /// The square a ring round an [avatar] this wide takes.
  static double extentFor(double avatar) =>
      (avatar / 2 + gap + radius + 1.4) * 2;

  @override
  State<PersonDayRing> createState() => _PersonDayRingState();
}

class _PersonDayRingState extends State<PersonDayRing> {
  ({DayLineFrame frame, Color stroke, double width, Color cut})? _laid;

  @override
  void initState() {
    super.initState();
    widget.locator?.attachRing(widget.personId, _onGlass);
  }

  @override
  void didUpdateWidget(PersonDayRing old) {
    super.didUpdateWidget(old);
    if (old.locator != widget.locator || old.personId != widget.personId) {
      old.locator?.detachRing(old.personId, _onGlass);
      widget.locator?.attachRing(widget.personId, _onGlass);
    }
  }

  @override
  void dispose() {
    widget.locator?.detachRing(widget.personId, _onGlass);
    super.dispose();
  }

  PersonDayShape? _onGlass() {
    final laid = _laid;
    final box = context.findRenderObject();
    if (laid == null || box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    final theme = Theme.of(context);
    final center = box.localToGlobal(box.size.center(Offset.zero));
    final frame = laid.frame;
    final r = widget.ringRadius;
    return PersonDayShape(
      at: (minute) => center + RingDayPainter.pointAt(frame, minute, r),
      start: frame.start,
      end: frame.end,
      dots: [
        for (final c in frame.clusters)
          (minute: c.minute, bead: c.bead, color: c.bead.colorIn(theme)),
      ],
      stroke: laid.stroke,
      width: laid.width,
      radius: PersonDayRing.radius,
      cut: laid.cut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final count = personDayCount(
      personLineDoses(context, widget.care, DateTime.now()),
    );
    final face = SizedBox.square(dimension: widget.avatar, child: widget.child);
    if (count.planned == 0) {
      return SizedBox.square(
        dimension: widget.extent,
        child: Center(child: face),
      );
    }
    return Semantics(
      container: true,
      label: l.people_dayProgress('${count.planned}', '${count.taken}'),
      child: ExcludeSemantics(
        child: SceneClock(
          builder: (context, now) {
            final theme = Theme.of(context), colors = theme.colorScheme;
            final semantic = theme.extension<AppSemanticColors>();
            final doses = personLineDoses(context, widget.care, now);
            final complete = personDayComplete(doses);
            final r = widget.ringRadius;
            final nowMinute = now.hour * 60 + now.minute;
            final frame = DayLineFrame.of(
              doses,
              width: RingDayPainter.arcLength(r),
              now: nowMinute,
              touch: PersonDayRing.radius * 2 + 1.5,
            );
            final stroke = complete
                ? semantic?.statusTaken ?? colors.primary
                : colors.onSurfaceVariant.withValues(alpha: .42);
            final cut = colors.surfaceContainerLow;
            _laid = (
              frame: frame,
              stroke: stroke,
              width: complete ? 1.8 : 1.2,
              cut: cut,
            );
            return SizedBox.square(
              dimension: widget.extent,
              child: CustomPaint(
                key: ValueKey('person-day-ring-${widget.personId}'),
                foregroundPainter: RingDayPainter(
                  frame: frame,
                  radius: r,
                  now: nowMinute,
                  stroke: stroke,
                  width: complete ? 1.8 : 1.2,
                  cut: cut,
                  accent: colors.primary,
                  beadColor: (bead) => bead.colorIn(theme),
                ),
                child: Center(child: face),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Paints [frame] wrapped as a ring of [radius] round the centre.
class RingDayPainter extends CustomPainter {
  RingDayPainter({
    required this.frame,
    required this.radius,
    required this.now,
    required this.stroke,
    required this.width,
    required this.cut,
    required this.accent,
    required this.beadColor,
  });

  final DayLineFrame frame;
  final double radius, width;
  final int now;
  final Color stroke, cut, accent;
  final Color Function(DoseBead bead) beadColor;

  /// The ring's length once unrolled.
  static double arcLength(double radius) =>
      radius * (math.pi * 2 - PersonDayRing.opening);

  /// The angle of [minute], clockwise from the top opening. The opening
  /// keeps the end dots whole, so the ring needs no padding of its own.
  static double angleOf(DayLineFrame frame, double minute, double radius) {
    final u = ((minute - frame.start) / (frame.end - frame.start)).clamp(
      0.0,
      1.0,
    );
    return -math.pi / 2 +
        PersonDayRing.opening / 2 +
        u * (math.pi * 2 - PersonDayRing.opening);
  }

  /// Where [minute] sits on the ring, from its centre.
  static Offset pointAt(DayLineFrame frame, double minute, double radius) {
    final a = angleOf(frame, minute, radius);
    return Offset(math.cos(a), math.sin(a)) * radius;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const start = -math.pi / 2 + PersonDayRing.opening / 2;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: radius),
      start,
      math.pi * 2 - PersonDayRing.opening,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width
        ..color = stroke,
    );
    // "Now" is a short tick pointing out of the ring, with a dot at its tip.
    final a = angleOf(frame, now.toDouble(), radius);
    final dir = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(
      c + dir * (radius - 2),
      c + dir * (radius + 4.5),
      Paint()
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..color = accent,
    );
    canvas.drawCircle(c + dir * (radius + 4.5), 1.8, Paint()..color = accent);
    for (final cluster in frame.clusters) {
      final bead = cluster.bead;
      paintDoseBead(
        canvas,
        c + pointAt(frame, cluster.minute, radius),
        PersonDayRing.radius,
        bead,
        color: beadColor(bead),
        cut: cut,
      );
    }
  }

  @override
  bool shouldRepaint(RingDayPainter old) =>
      old.frame.start != frame.start ||
      old.frame.end != frame.end ||
      !listEquals(
        [for (final c in old.frame.clusters) ...c.doses],
        [for (final c in frame.clusters) ...c.doses],
      ) ||
      old.radius != radius ||
      old.now != now ||
      old.stroke != stroke ||
      old.width != width ||
      old.cut != cut ||
      old.accent != accent;
}

/// Plays a person's ring unrolling into their day line when they become the
/// one in focus on People: every minute of the day travels from its place on
/// the ring to its place on the line, so the circle opens at the top and
/// lays itself straight. Quiet mode just swaps. Nothing runs at rest.
class PersonUnrollHost extends ConsumerStatefulWidget {
  const PersonUnrollHost({super.key, required this.child});

  final Widget child;

  static const flight = Duration(milliseconds: 520);

  @override
  ConsumerState<PersonUnrollHost> createState() => _PersonUnrollHostState();
}

class _PersonUnrollHostState extends ConsumerState<PersonUnrollHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flight = AnimationController(
    vsync: this,
    duration: PersonUnrollHost.flight,
  );
  late final PersonDayLocator _locator;
  ({String id, PersonDayShape ring, PersonDayShape line, Offset origin})?
  _route;
  String? _arriving;
  Completer<void>? _landing;

  @override
  void initState() {
    super.initState();
    _locator = ref.read(personDayLocatorProvider);
    _flight.addListener(() {
      final id = _arriving;
      if (id != null) _locator.veil(id).value = 1 - fadeOutAt(_flight.value);
    });
    _flight.addStatusListener((status) {
      if (status == AnimationStatus.completed) _land();
    });
  }

  /// How far the drawn line has faded at flight time [t].
  static double fadeOutAt(double t) => ((t - .72) / .28).clamp(0.0, 1.0);

  void _land() {
    final id = _arriving;
    if (id != null) _locator.veil(id).value = 0;
    _arriving = null;
    _landing?.complete();
    _landing = null;
    if (mounted && _route != null) setState(() => _route = null);
  }

  void _start(String id) {
    _flight.stop();
    _land();
    if (AppMotion.quiet(context)) return;
    // The rows are still laid out where they were: read the ring before it
    // goes.
    final ring = _locator.ring(id);
    if (ring == null) return;
    final landing = _landing = Completer<void>();
    _locator.landed = landing.future;
    _arriving = id;
    _locator.veil(id).value = 1;
    _seek(id, ring, landing, frames: 8);
  }

  /// Finds [id]'s line once it is laid out, waiting a few [frames] for a
  /// card that is still settling, then flies to it.
  void _seek(
    String id,
    PersonDayShape ring,
    Completer<void> landing, {
    required int frames,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_landing, landing)) return;
      final line = mounted ? _locator.line(id) : null;
      final box = mounted ? context.findRenderObject() : null;
      if (line == null && mounted && frames > 0) {
        WidgetsBinding.instance.scheduleFrame();
        _seek(id, ring, landing, frames: frames - 1);
        return;
      }
      if (line == null || box is! RenderBox || !box.hasSize) {
        _land();
        return;
      }
      setState(
        () => _route = (
          id: id,
          ring: ring,
          line: line,
          origin: box.localToGlobal(Offset.zero),
        ),
      );
      _flight.forward(from: 0);
    });
  }

  @override
  void dispose() {
    final id = _arriving;
    if (id != null) _locator.veil(id).value = 0;
    _landing?.complete();
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedProfileIdProvider, (previous, next) {
      final from = previous?.asData?.value;
      final to = next.asData?.value;
      if (previous?.asData == null || to == null || from == to) return;
      _start(to);
    });
    final route = _route;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (route != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                key: const ValueKey('person-unroll'),
                painter: UnrollPainter(
                  flight: _flight,
                  ring: route.ring,
                  line: route.line,
                  origin: route.origin,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Draws a ring opening into a line: each minute of the day moves from the
/// ring to the line, the stroke and dots growing to the line's size.
class UnrollPainter extends CustomPainter {
  UnrollPainter({
    required this.flight,
    required this.ring,
    required this.line,
    required this.origin,
  }) : super(repaint: flight);

  final Animation<double> flight;
  final PersonDayShape ring, line;

  /// The painter's own top-left in global coordinates.
  final Offset origin;

  static const samples = 64;

  @override
  void paint(Canvas canvas, Size size) {
    final t = flight.value;
    final k = Curves.easeInOutCubic.transform(t);
    final shown = 1 - _PersonUnrollHostState.fadeOutAt(t);
    if (shown <= 0) return;
    Offset morph(double minute) =>
        Offset.lerp(ring.at(minute), line.at(minute), k)! - origin;
    final from = line.start.toDouble(), to = line.end.toDouble();
    final path = Path();
    for (var i = 0; i <= samples; i++) {
      final p = morph(from + (to - from) * i / samples);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    final stroke = Color.lerp(ring.stroke, line.stroke, k)!;
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = lerpDouble(ring.width, line.width, k)!
        ..color = stroke.withValues(alpha: stroke.a * shown),
    );
    final r = lerpDouble(ring.radius, line.radius, k)!;
    final cut = Color.lerp(ring.cut, line.cut, k)!;
    for (final dot in line.dots) {
      paintDoseBead(
        canvas,
        morph(dot.minute),
        r,
        dot.bead,
        color: dot.color.withValues(alpha: dot.color.a * shown),
        cut: cut.withValues(alpha: cut.a * shown),
      );
    }
  }

  @override
  bool shouldRepaint(UnrollPainter old) =>
      old.ring != ring ||
      old.line != line ||
      old.origin != origin ||
      old.flight != flight;
}
