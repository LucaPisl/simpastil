import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/medication/routine_definition.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/layouts/tab_hand_off.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/scene/dose_bead.dart';
import '../../shared/scene/scene_clock.dart';
import 'history_day_ribbon.dart';
import 'models/history_entry.dart';

/// One dose on History's day line.
@immutable
class DayLineDose {
  const DayLineDose({
    required this.id,
    required this.minute,
    required this.bead,
    required this.label,
    this.occurrenceId,
  });

  /// The dose record's id.
  final String id;

  /// Minute of the day, 0..1439.
  final int minute;
  final DoseBead bead;

  /// "08:00 · Vitamin D for Mira · Taken": shown when its dot is tapped and
  /// read by screen readers.
  final String label;

  /// Opens the dose's story; null when it has none.
  final String? occurrenceId;

  @override
  bool operator ==(Object other) =>
      other is DayLineDose &&
      other.id == id &&
      other.minute == minute &&
      other.bead == bead &&
      other.label == label &&
      other.occurrenceId == occurrenceId;

  @override
  int get hashCode => Object.hash(id, minute, bead, label, occurrenceId);
}

/// The outcome words for a bead. "Not recorded" is never "missed": only a dose
/// with a recorded miss is called missed.
String doseBeadOutcome(AppLocalizations l, DoseBead bead) => switch (bead) {
  DoseBead.taken => l.t08_taken,
  DoseBead.skipped => l.t08_skipped,
  DoseBead.planned => l.t10_planned,
  DoseBead.unrecorded => l.t08_unrecorded,
  DoseBead.missed => l.dashboard_statusMissed,
  DoseBead.asNeeded => l.t08_asNeeded,
};

/// [day]'s doses from [entries], in time order. [now] decides which planned
/// doses have passed without a record.
List<DayLineDose> historyLineDoses(
  BuildContext context,
  Iterable<HistoryEntry> entries, {
  required DateTime day,
  required DateTime now,
}) {
  final l = AppLocalizations.of(context);
  final key = routineDateKey(day);
  final past = DateUtils.dateOnly(day).isBefore(DateUtils.dateOnly(now));
  final today = DateUtils.isSameDay(day, now);
  final nowMinute = now.hour * 60 + now.minute;
  final doses = <DayLineDose>[];
  for (final e in entries) {
    if (e.plannedLocalDate != key) continue;
    final minute = historyDoseMinute(e);
    if (minute == null) continue;
    final bead = DoseBead.of(
      e.recordedState,
      prn: e.source == 'prn',
      passed: past || (today && minute < nowMinute),
    );
    doses.add(
      DayLineDose(
        id: e.doseLogId,
        minute: minute,
        bead: bead,
        occurrenceId: e.occurrenceId,
        label: l.history_lineDose(
          TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context),
          e.pillName,
          e.profileName,
          doseBeadOutcome(l, bead),
        ),
      ),
    );
  }
  return doses..sort((a, b) => a.minute.compareTo(b.minute));
}

/// Doses whose dots would touch share one dot, with a count.
@immutable
class DayLineCluster {
  const DayLineCluster(this.doses);

  final List<DayLineDose> doses;

  /// The first dose's id names the cluster.
  String get key => doses.first.id;

  double get minute =>
      doses.fold<int>(0, (sum, d) => sum + d.minute) / doses.length;

  /// What the shared dot shows: what still needs a look comes first.
  DoseBead get bead {
    for (final bead in const [
      DoseBead.missed,
      DoseBead.unrecorded,
      DoseBead.planned,
      DoseBead.skipped,
      DoseBead.asNeeded,
    ]) {
      if (doses.any((d) => d.bead == bead)) return bead;
    }
    return DoseBead.taken;
  }

  bool holds(String? id) => id != null && doses.any((d) => d.id == id);
}

/// What the line draws for one day at one width: the stretch of the day it
/// spans (minutes) and its dots.
@immutable
class DayLineFrame {
  const DayLineFrame._(this.start, this.end, this.clusters);

  /// The line runs from 06:00 to 22:00, widened to an hour either side of
  /// the first and last dose and to keep [now] on it; a dot closer than
  /// [touch] to the one before joins it.
  factory DayLineFrame.of(
    List<DayLineDose> doses, {
    required double width,
    int? now,
    double touch = 15,
  }) {
    var start = 360, end = 1320;
    if (doses.isNotEmpty) {
      start = math.min(start, doses.first.minute - 60);
      end = math.max(end, doses.last.minute + 60);
    }
    if (now != null) {
      start = math.min(start, now - 30);
      end = math.max(end, now + 30);
    }
    start = ((start / 60).floor() * 60).clamp(0, 1380);
    end = ((end / 60).ceil() * 60).clamp(start + 60, 1440);
    final clusters = <DayLineCluster>[];
    var group = <DayLineDose>[];
    for (final dose in doses) {
      if (group.isNotEmpty &&
          x(dose.minute.toDouble(), start, end, width) -
                  x(group.first.minute.toDouble(), start, end, width) >=
              touch) {
        clusters.add(DayLineCluster(group));
        group = [];
      }
      group.add(dose);
    }
    if (group.isNotEmpty) clusters.add(DayLineCluster(group));
    return DayLineFrame._(start, end, clusters);
  }

  final int start, end;
  final List<DayLineCluster> clusters;

  /// The line keeps clear of the ends by [pad], so edge dots stay whole.
  static const pad = 12.0;

  static double x(double minute, num start, num end, double width) =>
      pad + (minute - start) / (end - start) * (width - pad * 2);
}

/// The chosen day as a thin line across History's header: a dot at each
/// dose's time, the "now" pin when the day is today, and faint ticks at
/// 06:00, 12:00 and 18:00.
///
/// * Changing day: the old dots slide off along the line the way time moved
///   ([direction] -1 into the past), the new ones thread on from the other
///   side, then the line sways once (not when days change quickly).
/// * Pulling to refresh: the line sags under [pull] and springs back.
/// * Tapping a dot shows its label under the line; the label opens the
///   dose's story. Screen readers open a lone dose's story directly.
///
/// * Arriving from Today: [locator] lets the shell find the line and veil
///   it while Today's arc lays itself down onto it.
///
/// Still at rest: the only repaint is the "now" pin's, once a minute.
class HistoryDayLine extends StatefulWidget {
  const HistoryDayLine({
    super.key,
    required this.day,
    required this.doses,
    required this.onOpen,
    this.direction = 1,
    this.pull,
    this.locator,
  });

  final DateTime day;

  /// [day]'s doses in time order ([historyLineDoses]).
  final List<DayLineDose> doses;

  /// Opens a dose's story by its occurrence id.
  final ValueChanged<String> onOpen;
  final int direction;
  final ValueListenable<double>? pull;
  final HandOffLineLocator? locator;

  static const lineY = 22.0;

  @override
  State<HistoryDayLine> createState() => _HistoryDayLineState();
}

class _HistoryDayLineState extends State<HistoryDayLine>
    with TickerProviderStateMixin {
  late final AnimationController _change = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
    value: 1,
  );
  late final AnimationController _sway = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    value: 1,
  );

  /// The day sliding off, while [_change] runs.
  List<DayLineDose>? _previous;
  DateTime? _previousDay;
  DateTime? _lastChange;
  bool _swayAfter = false;
  String? _selected;

  /// The line as last laid out, for [_onGlass].
  ({DayLineFrame frame, double width, int? now, Color line, Color pin})? _laid;

  @override
  void initState() {
    super.initState();
    widget.locator?.attach(_onGlass);
    _change.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      setState(() => _previous = _previousDay = null);
      if (_swayAfter) _sway.forward(from: 0);
    });
  }

  /// Where the line stands on the glass right now, or null when it is not
  /// laid out.
  HandOffLine? _onGlass() {
    final laid = _laid;
    final box = context.findRenderObject();
    if (laid == null || box is! RenderBox || !box.attached || !box.hasSize) {
      return null;
    }
    final frame = laid.frame;
    final origin = box.localToGlobal(Offset.zero);
    return HandOffLine(
      at: (minute) =>
          origin +
          Offset(
            DayLineFrame.x(
              minute,
              frame.start,
              frame.end,
              laid.width,
            ).clamp(0.0, laid.width),
            HistoryDayLine.lineY,
          ),
      color: laid.line,
      pin: laid.pin,
      now: laid.now,
    );
  }

  @override
  void didUpdateWidget(HistoryDayLine old) {
    super.didUpdateWidget(old);
    if (old.locator != widget.locator) {
      old.locator?.detach(_onGlass);
      widget.locator?.attach(_onGlass);
    }
    if (!DateUtils.isSameDay(old.day, widget.day)) {
      _selected = null;
      final at = DateTime.now();
      final last = _lastChange;
      _lastChange = at;
      _sway.value = 1;
      if (AppMotion.quiet(context)) {
        _previous = _previousDay = null;
        _change.value = 1;
        return;
      }
      _previous = old.doses;
      _previousDay = old.day;
      // Running through a week by fast swipes does not wobble the line.
      _swayAfter =
          last == null ||
          at.difference(last) > const Duration(milliseconds: 600);
      _change.forward(from: 0);
    } else if (_selected != null &&
        !widget.doses.any((d) => d.id == _selected)) {
      _selected = null;
    }
  }

  @override
  void dispose() {
    widget.locator?.detach(_onGlass);
    _change.dispose();
    _sway.dispose();
    super.dispose();
  }

  void _toggle(String key) {
    HapticFeedback.selectionClick();
    setState(() => _selected = _selected == key ? null : key);
  }

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.isSameDay(widget.day, DateTime.now());
    final previousToday =
        _previousDay != null &&
        DateUtils.isSameDay(_previousDay, DateTime.now());
    final line = !today && !previousToday
        ? _line(context, null)
        : SceneClock(builder: _line);
    final veil = widget.locator?.veil;
    if (veil == null) return line;
    return ValueListenableBuilder<double>(
      valueListenable: veil,
      builder: (context, hidden, child) =>
          Opacity(opacity: 1 - hidden, child: child),
      child: line,
    );
  }

  Widget _line(BuildContext context, DateTime? now) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final today = DateUtils.isSameDay(widget.day, DateTime.now());
    int? minuteOf(DateTime? t) => t == null ? null : t.hour * 60 + t.minute;
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = bounds.maxWidth;
        final frame = DayLineFrame.of(
          widget.doses,
          width: width,
          now: today ? minuteOf(now) : null,
        );
        final lineColor = colors.onSurfaceVariant.withValues(alpha: .45);
        _laid = (
          frame: frame,
          width: width,
          now: today ? minuteOf(now) : null,
          line: lineColor,
          pin: colors.primary,
        );
        final previous = _previous;
        final selected = frame.clusters
            .where((c) => c.key == _selected)
            .firstOrNull;
        final line = MediaQuery.withClampedTextScaling(
          // The line stays a line; its hour labels stop growing at 1.4x.
          maxScaleFactor: 1.4,
          child: Builder(
            builder: (context) {
              final scaler = MediaQuery.textScalerOf(context);
              final tickStyle = theme.textTheme.labelSmall!.copyWith(
                fontSize: 11,
                color: colors.onSurfaceVariant,
              );
              final height =
                  HistoryDayLine.lineY + 11 + scaler.scale(11) * 1.45;
              final xs = [
                for (final c in frame.clusters)
                  DayLineFrame.x(c.minute, frame.start, frame.end, width),
              ];
              return SizedBox(
                height: height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: const ValueKey('history-day-line'),
                            painter: DayLinePainter(
                              frame: frame,
                              previous: previous == null
                                  ? null
                                  : DayLineFrame.of(
                                      previous,
                                      width: width,
                                      now:
                                          _previousDay != null &&
                                              DateUtils.isSameDay(
                                                _previousDay,
                                                DateTime.now(),
                                              )
                                          ? minuteOf(now)
                                          : null,
                                    ),
                              change: _change,
                              sway: _sway,
                              pull: widget.pull,
                              direction: widget.direction,
                              now: today ? minuteOf(now) : null,
                              selected: _selected,
                              line: lineColor,
                              cut: theme.scaffoldBackgroundColor,
                              accent: colors.primary,
                              beadColor: (bead) => bead.colorIn(theme),
                              ticks: [
                                for (final h in const [6, 12, 18])
                                  (
                                    minute: h * 60,
                                    label: TimeOfDay(
                                      hour: h,
                                      minute: 0,
                                    ).format(context),
                                  ),
                              ],
                              tickStyle: tickStyle,
                              countStyle: tickStyle.copyWith(
                                fontWeight: FontWeight.w700,
                                color: colors.onSurface,
                              ),
                              textDirection: Directionality.of(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                    for (var i = 0; i < frame.clusters.length; i++)
                      _target(
                        context,
                        frame.clusters[i],
                        // A dot's touch area reaches halfway to its
                        // neighbours, so close dots never steal each other's
                        // taps.
                        left: math.max(
                          xs[i] - 20,
                          i == 0 ? 0 : (xs[i - 1] + xs[i]) / 2,
                        ),
                        right: math.min(
                          xs[i] + 20,
                          i == xs.length - 1 ? width : (xs[i] + xs[i + 1]) / 2,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            line,
            AnimatedSize(
              duration: AppMotion.duration(context, milliseconds: 160),
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: selected == null
                  ? const SizedBox(width: double.infinity)
                  : _Label(
                      key: ValueKey('history-line-label-${selected.key}'),
                      cluster: selected,
                      onOpen: widget.onOpen,
                      cut: colors.surfaceContainerHigh,
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _target(
    BuildContext context,
    DayLineCluster cluster, {
    required double left,
    required double right,
  }) {
    final l = AppLocalizations.of(context);
    final lone = cluster.doses.length == 1 ? cluster.doses.single : null;
    final minute = cluster.doses.first.minute;
    final open = lone?.occurrenceId;
    return Positioned(
      left: left,
      width: math.max(right - left, 1),
      top: HistoryDayLine.lineY - 20,
      height: 40,
      child: Semantics(
        container: true,
        button: true,
        selected: _selected == cluster.key,
        label:
            lone?.label ??
            l.history_lineCluster(
              cluster.doses.length,
              TimeOfDay(
                hour: minute ~/ 60,
                minute: minute % 60,
              ).format(context),
            ),
        hint: open == null ? null : l.t10_details,
        onTap: open == null
            ? () => _toggle(cluster.key)
            : () => widget.onOpen(open),
        child: GestureDetector(
          key: ValueKey('history-line-dot-${cluster.key}'),
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggle(cluster.key),
        ),
      ),
    );
  }
}

/// The words behind a tapped dot, one row per dose; a row opens that dose's
/// story. It stays until the dot is tapped again or the day changes.
class _Label extends StatelessWidget {
  const _Label({
    super.key,
    required this.cluster,
    required this.onOpen,
    required this.cut,
  });

  final DayLineCluster cluster;
  final ValueChanged<String> onOpen;
  final Color cut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Material(
        color: cut,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final dose in cluster.doses)
              InkWell(
                key: ValueKey('history-line-open-${dose.id}'),
                onTap: dose.occurrenceId == null
                    ? null
                    : () => onOpen(dose.occurrenceId!),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      CustomPaint(
                        size: const Size(12, 12),
                        painter: _BeadPainter(
                          dose.bead,
                          dose.bead.colorIn(theme),
                          cut,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          dose.label,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (dose.occurrenceId != null)
                        const Icon(Icons.chevron_right, size: 20),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
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

/// The day line under History's title once the header has scrolled away: one
/// pixel, small dots, and the dot of the record at the top of the list
/// ([highlight], a dose id) lit, so you can see where in the day you are.
class HistoryDockedLine extends StatelessWidget {
  const HistoryDockedLine({
    super.key,
    required this.day,
    required this.doses,
    required this.highlight,
    required this.summary,
  });

  final DateTime day;
  final List<DayLineDose> doses;
  final ValueListenable<String?> highlight;

  /// One sentence for screen readers: the dots are not separate stops here.
  final String summary;

  static const height = 18.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    Widget line(BuildContext context, DateTime? now) => LayoutBuilder(
      builder: (context, bounds) => ValueListenableBuilder<String?>(
        valueListenable: highlight,
        builder: (context, lit, _) => CustomPaint(
          size: Size(bounds.maxWidth, height),
          painter: DayLinePainter(
            frame: DayLineFrame.of(
              doses,
              width: bounds.maxWidth,
              now: now == null ? null : now.hour * 60 + now.minute,
              touch: 9,
            ),
            compact: true,
            now: now == null ? null : now.hour * 60 + now.minute,
            selected: lit,
            line: colors.onSurfaceVariant.withValues(alpha: .5),
            cut: theme.scaffoldBackgroundColor,
            accent: colors.primary,
            beadColor: (bead) => bead.colorIn(theme),
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      label: summary,
      child: SizedBox(
        height: height,
        child: DateUtils.isSameDay(day, DateTime.now())
            ? SceneClock(builder: line)
            : line(context, null),
      ),
    );
  }
}

/// Paints a [DayLineFrame]: the line, its ticks, the dots and the "now" pin.
///
/// Repaints from [change], [sway] and [pull] without a rebuild. At rest
/// ([change] 1, [sway] 1, [pull] 0) it is a still drawing.
class DayLinePainter extends CustomPainter {
  DayLinePainter({
    required this.frame,
    this.previous,
    this.change = const AlwaysStoppedAnimation(1),
    this.sway = const AlwaysStoppedAnimation(1),
    this.pull,
    this.direction = 1,
    this.now,
    this.selected,
    this.compact = false,
    required this.line,
    required this.cut,
    required this.accent,
    required this.beadColor,
    this.ticks = const [],
    this.tickStyle,
    this.countStyle,
    this.textDirection = TextDirection.ltr,
  }) : super(repaint: Listenable.merge([change, sway, pull]));

  final DayLineFrame frame;

  /// The day sliding off while [change] runs.
  final DayLineFrame? previous;
  final Animation<double> change, sway;
  final ValueListenable<double>? pull;
  final int direction;

  /// The minute of "now" when the day is today.
  final int? now;

  /// A dose id: its dot is ringed.
  final String? selected;

  /// The docked form: one pixel, small dots, no ticks or counts.
  final bool compact;
  final Color line, cut, accent;
  final Color Function(DoseBead bead) beadColor;
  final List<({int minute, String label})> ticks;
  final TextStyle? tickStyle, countStyle;
  final TextDirection textDirection;

  final Map<String, TextPainter> _text = {};

  TextPainter _label(String text, TextStyle style) =>
      _text[text] ??= TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: textDirection,
      )..layout();

  /// One damped sway, starting and ending flat: a downward bow in dp.
  static double swayAt(double t) =>
      3.5 * math.exp(-4.5 * t) * math.sin(math.pi * 2 * 2.2 * t) * (1 - t);

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final y0 = compact ? size.height / 2 : HistoryDayLine.lineY;
    final r = compact ? 2.8 : 4.5;
    final t = change.value;
    final before = t < 1 ? previous : null;
    final settle = before == null ? 1.0 : Curves.easeInOutCubic.transform(t);
    final start = lerpDouble(
      before?.start ?? frame.start,
      frame.start,
      settle,
    )!;
    final end = lerpDouble(before?.end ?? frame.end, frame.end, settle)!;
    final bow = compact
        ? 0.0
        : (pull?.value ?? 0) * 10 + swayAt(sway.value.clamp(0.0, 1.0));
    double yAt(double x) {
      final u = (x / width).clamp(0.0, 1.0);
      return y0 + bow * 4 * u * (1 - u);
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, -12, width, size.height + 24));
    canvas.drawPath(
      Path()
        ..moveTo(0, y0)
        ..quadraticBezierTo(width / 2, y0 + bow * 2, width, y0),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = compact ? 1 : 1.3
        ..color = line,
    );
    if (!compact) {
      for (final tick in ticks) {
        if (tick.minute <= start || tick.minute >= end) continue;
        final x = DayLineFrame.x(tick.minute.toDouble(), start, end, width);
        final y = yAt(x);
        canvas.drawLine(
          Offset(x, y + 3),
          Offset(x, y + 7),
          Paint()
            ..strokeWidth = 1
            ..color = line,
        );
        final style = tickStyle;
        if (style == null) continue;
        final text = _label(tick.label, style);
        final left = (x - text.width / 2).clamp(0.0, width - text.width);
        text.paint(canvas, Offset(left, y0 + 9));
      }
    }
    final pin = now;
    if (pin != null) {
      final x = DayLineFrame.x(pin.toDouble(), start, end, width);
      paintNowPin(
        canvas,
        Offset(x, yAt(x)),
        color: accent,
        stem: compact ? 5 : 9,
        r: compact ? 1.8 : 2.6,
      );
    }
    if (before != null) {
      final away = Curves.easeInCubic.transform((t / .55).clamp(0.0, 1.0));
      if (away < 1) {
        for (final c in before.clusters) {
          final x =
              DayLineFrame.x(c.minute, before.start, before.end, width) -
              direction * width * away;
          _dot(canvas, Offset(x, yAt(x)), r, c, false);
        }
      }
    }
    final n = frame.clusters.length;
    for (var i = 0; i < n; i++) {
      final c = frame.clusters[i];
      // The dot furthest from the side they arrive from threads on first.
      final order = direction < 0 ? n - 1 - i : i;
      final arrive = before == null
          ? 1.0
          : Curves.easeOutCubic.transform(
              ((t - .2 - math.min(order * .045, .25)) / .5).clamp(0.0, 1.0),
            );
      final x =
          DayLineFrame.x(c.minute, frame.start, frame.end, width) +
          direction * width * (1 - arrive);
      _dot(canvas, Offset(x, yAt(x)), r, c, c.holds(selected));
    }
    canvas.restore();
  }

  void _dot(Canvas canvas, Offset at, double r, DayLineCluster c, bool lit) {
    if (lit) {
      canvas.drawCircle(
        at,
        r + (compact ? 2.6 : 3.4),
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
      lit && compact ? r + 1 : r,
      bead,
      color: beadColor(bead),
      cut: cut,
    );
    final style = countStyle;
    if (compact || style == null || c.doses.length < 2) return;
    final text = _label('${c.doses.length}', style);
    text.paint(canvas, Offset(at.dx + r * .6, at.dy - r - text.height + 1));
  }

  @override
  bool shouldRepaint(DayLinePainter old) =>
      old.frame.start != frame.start ||
      old.frame.end != frame.end ||
      !listEquals(
        [for (final c in old.frame.clusters) ...c.doses],
        [for (final c in frame.clusters) ...c.doses],
      ) ||
      old.frame.clusters.length != frame.clusters.length ||
      old.previous != previous ||
      old.change != change ||
      old.sway != sway ||
      old.pull != pull ||
      old.direction != direction ||
      old.now != now ||
      old.selected != selected ||
      old.compact != compact ||
      old.line != line ||
      old.cut != cut ||
      old.accent != accent ||
      old.tickStyle != tickStyle ||
      !listEquals(old.ticks, ticks);
}
