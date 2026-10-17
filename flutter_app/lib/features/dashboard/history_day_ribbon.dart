import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/medication/routine_definition.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/layouts/window_size.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/motion/pressable.dart';
import '../../shared/scene/dose_bead.dart';
import 'models/history_entry.dart';

/// One dose on a ribbon day: where it sits on the day (0 is midnight, 1 the
/// next midnight), how it was recorded, and whether its time has [passed].
@immutable
class RibbonDose {
  const RibbonDose({
    required this.at,
    required this.state,
    this.prn = false,
    this.passed = true,
  });
  final double at;
  final String state;
  final bool prn, passed;

  DoseBead get bead => DoseBead.of(state, prn: prn, passed: passed);
}

/// What a day of history looked like, drawn small enough to scan a month.
@immutable
class RibbonDay {
  const RibbonDay({
    required this.date,
    required this.doses,
    this.unseen = false,
  });
  final DateTime date;
  final List<RibbonDose> doses;

  /// The day came before this phone knew the people being viewed, so it has
  /// nothing to say about it: not "nothing planned", just not seen.
  final bool unseen;

  /// Planned doses only: an as-needed dose is never owed.
  int get planned => doses.where((d) => !d.prn).length;
  int get taken => doses.where((d) => !d.prn && d.state == 'taken').length;

  /// Every planned dose of the day was taken.
  bool get complete => planned > 0 && taken == planned;
}

/// The [days] days ending [today] (newest first) with their doses, from
/// [entries] already narrowed to the person being viewed. [today] carries
/// the time of day too: a dose later today has not [RibbonDose.passed].
/// Empty days before [seenFrom] are [RibbonDay.unseen].
List<RibbonDay> historyRibbonDays(
  Iterable<HistoryEntry> entries, {
  required DateTime today,
  required int days,
  DateTime? seenFrom,
}) {
  final byDay = <String, List<RibbonDose>>{};
  final start = DateUtils.dateOnly(today);
  final todayKey = routineDateKey(start);
  final nowAt = (today.hour * 60 + today.minute) / 1440;
  for (final e in entries) {
    final key = e.plannedLocalDate;
    if (key == null) continue;
    final at = _dayFraction(e);
    if (at == null) continue;
    (byDay[key] ??= []).add(
      RibbonDose(
        at: at,
        state: e.recordedState,
        prn: e.source == 'prn',
        passed: key.compareTo(todayKey) < 0 || (key == todayKey && at < nowAt),
      ),
    );
  }
  return [
    for (var i = 0; i < math.max(days, 1); i++)
      () {
        final date = DateTime(start.year, start.month, start.day - i);
        final doses = byDay[routineDateKey(date)] ?? const <RibbonDose>[];
        return RibbonDay(
          date: date,
          doses: [...doses]..sort((a, b) => a.at.compareTo(b.at)),
          unseen:
              doses.isEmpty &&
              seenFrom != null &&
              date.isBefore(DateUtils.dateOnly(seenFrom)),
        );
      }(),
  ];
}

double? _dayFraction(HistoryEntry e) {
  final minute = historyDoseMinute(e);
  return minute == null ? null : minute / 1440;
}

/// The minute of the day a dose belongs at: its planned time, or for an
/// as-needed dose the time it was taken. Null when neither is known.
int? historyDoseMinute(HistoryEntry e) {
  final planned = e.plannedLocalTime;
  if (planned != null) {
    final parts = planned.split(':');
    final h = int.tryParse(parts.first);
    final m = parts.length > 1 ? int.tryParse(parts[1]) : 0;
    if (h != null && m != null) return (h * 60 + m).clamp(0, 1439);
  }
  final taken = e.takenAt?.toLocal();
  if (e.source == 'prn' && taken != null) {
    return taken.hour * 60 + taken.minute;
  }
  return null;
}

/// A strip of recent days, today at the end, each with a short row of dose
/// beads in time order showing how that day's doses went. The tiles never
/// animate on their own; the strip slides to the picked day.
class HistoryDayRibbon extends StatefulWidget {
  const HistoryDayRibbon({
    super.key,
    required this.days,
    required this.selected,
    required this.onSelected,
    this.person,
  });

  /// Newest first.
  final List<RibbonDay> days;
  final DateTime? selected;
  final ValueChanged<DateTime> onSelected;

  /// The person being viewed, for what an unseen day says; null for everyone.
  final String? person;

  @override
  State<HistoryDayRibbon> createState() => _HistoryDayRibbonState();
}

class _HistoryDayRibbonState extends State<HistoryDayRibbon> {
  final _scroll = ScrollController();
  double _extent = 0;
  double _viewport = 0;

  /// Wide windows show whole tiles only: the strip is as wide as it is, so a
  /// tile cut off at the edge looks like a mistake rather than "more".
  bool _wholeTiles = false;

  int? get _selectedIndex {
    final selected = widget.selected;
    if (selected == null) return null;
    final i = widget.days.indexWhere(
      (d) => DateUtils.isSameDay(d.date, selected),
    );
    return i < 0 ? null : i;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(jump: true));
  }

  @override
  void didUpdateWidget(HistoryDayRibbon old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the picked day toward the middle of the strip.
  void _reveal({bool jump = false}) {
    final index = _selectedIndex;
    if (!mounted || index == null || !_scroll.hasClients) return;
    final position = _scroll.position;
    var target = index * _extent - (_viewport - _extent) / 2;
    // Rest on a whole tile, so the strip never settles with one cut off.
    if (_wholeTiles) target = (target / _extent).round() * _extent;
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (jump || AppMotion.quiet(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // The header above carries the full date at any size; the strip stays a
    // strip, so its own type stops growing at 1.5x.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.5,
      child: Builder(
        builder: (context) {
          final scaler = MediaQuery.textScalerOf(context);
          final tile = scaler.scale(16) * 3.5 + 6;
          final height = scaler.scale(12) * 1.4 + scaler.scale(19) * 1.3 + 50;
          final wide = WindowClass.of(context).showsRail;
          return LayoutBuilder(
            builder: (context, bounds) {
              _viewport = bounds.maxWidth;
              // On wide windows the tiles stretch a little so a whole number
              // of them fills the strip exactly.
              _wholeTiles = wide && bounds.maxWidth.isFinite;
              final fitted = _wholeTiles
                  ? bounds.maxWidth /
                        math.max(1, (bounds.maxWidth / tile).floor())
                  : tile;
              _extent = fitted;
              final strip = ListView.builder(
                key: const ValueKey('history-day-ribbon'),
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                reverse: true,
                itemExtent: fitted,
                physics: _wholeTiles
                    ? _TileSnapPhysics(
                        extent: fitted,
                        parent: const ClampingScrollPhysics(),
                      )
                    : null,
                itemCount: widget.days.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: _RibbonDayTile(
                    day: widget.days[i],
                    person: widget.person,
                    today: i == 0,
                    selected: i == _selectedIndex,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.onSelected(widget.days[i].date);
                    },
                  ),
                ),
              );
              return SizedBox(
                height: height,
                // Older days fade out at the far edge: time keeps going. Whole
                // tiles need no fade, and one would hide a day.
                child: _wholeTiles
                    ? strip
                    : ShaderMask(
                        shaderCallback: (rect) => const LinearGradient(
                          colors: [Color(0x00000000), Color(0xFF000000)],
                          stops: [0, .1],
                        ).createShader(rect),
                        blendMode: BlendMode.dstIn,
                        child: strip,
                      ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Lets a swipe settle only on a whole tile, whatever speed it ends at.
class _TileSnapPhysics extends ScrollPhysics {
  const _TileSnapPhysics({required this.extent, super.parent});

  final double extent;

  @override
  _TileSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _TileSnapPhysics(extent: extent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final inertia = super.createBallisticSimulation(position, velocity);
    // Past the ends the parent brings the strip back itself.
    if (position.outOfRange) return inertia;
    final tolerance = toleranceFor(position);
    final landing = inertia?.x(double.infinity) ?? position.pixels;
    final target = ((landing / extent).round() * extent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }
}

class _RibbonDayTile extends StatelessWidget {
  const _RibbonDayTile({
    required this.day,
    required this.person,
    required this.today,
    required this.selected,
    required this.onTap,
  });

  final RibbonDay day;
  final String? person;
  final bool today, selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme;
    final locale = Localizations.localeOf(context).toString();
    final ink = selected ? colors.onPrimary : colors.onSurface;
    // An unseen day is only an outline: the phone can't fill it in.
    final faint = day.unseen && !selected;
    final date = DateFormat.MMMMEEEEd(locale).format(day.date);
    final who = person;
    return Semantics(
      button: true,
      selected: selected,
      label: day.unseen
          ? (who == null
                ? l.history_ribbonDayUnseenAll(date)
                : l.history_ribbonDayUnseen(date, who))
          : day.planned == 0
          ? l.history_ribbonDayEmpty(date)
          : l.history_ribbonDay(date, day.taken, day.planned),
      excludeSemantics: true,
      child: Pressable(
        radius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          key: ValueKey('history-ribbon-${routineDateKey(day.date)}'),
          duration: AppMotion.duration(context, milliseconds: 280),
          curve: AppMotion.curve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: selected
                ? colors.primary
                : faint
                ? colors.surfaceContainerHighest.withValues(alpha: 0)
                : colors.surfaceContainerHighest.withValues(alpha: .55),
            border: Border.all(
              color: today && !selected
                  ? colors.primary.withValues(alpha: .7)
                  : faint
                  ? colors.outlineVariant.withValues(alpha: .7)
                  : Colors.transparent,
              width: faint ? 1 : 1.4,
            ),
            boxShadow: [
              if (selected)
                BoxShadow(
                  color: colors.primary.withValues(alpha: .32),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: Column(
            children: [
              Text(
                DateFormat.E(locale).format(day.date),
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 12,
                  color: ink.withValues(
                    alpha: selected
                        ? .86
                        : faint
                        ? .4
                        : .66,
                  ),
                ),
              ),
              Text(
                '${day.date.day}',
                maxLines: 1,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  color: today && !selected
                      ? colors.primary
                      : faint
                      ? ink.withValues(alpha: .42)
                      : ink,
                ),
              ),
              const Spacer(),
              SizedBox(
                height: 22,
                width: double.infinity,
                child: CustomPaint(
                  painter: RibbonDayPainter(
                    beads: [
                      for (final dose in day.doses)
                        (bead: dose.bead, color: dose.bead.colorIn(theme)),
                    ],
                    // On the picked tile the beads sit in a small well of the
                    // page, so their outcome colours read as they do
                    // everywhere else instead of against the violet.
                    cut: colors.surface,
                    tray: selected,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A day's doses as a short row of beads in time order: no arc, no line.
class RibbonDayPainter extends CustomPainter {
  RibbonDayPainter({required this.beads, required this.cut, this.tray = false});

  final List<({DoseBead bead, Color color})> beads;
  final Color cut;
  final bool tray;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(2, 0);
    paintBeadRow(
      canvas,
      Size(size.width - 4, size.height),
      beads,
      cut: cut,
      tray: tray,
    );
  }

  @override
  bool shouldRepaint(RibbonDayPainter old) =>
      old.cut != cut || old.tray != tray || !listEquals(old.beads, beads);
}
