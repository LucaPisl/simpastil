import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/scene/dose_bead.dart';
import '../dashboard/selected_date_provider.dart';
import 'adherence.dart';
import 'analytics_providers.dart';

// ── CalendarMonthView ─────────────────────────────────────────────────────────

/// Month calendar with one adherence dot per day, swipeable through past
/// months. Page index i = i months before the current month, so the future
/// is unreachable by construction. The PageController is the navigation
/// source of truth; [calendarMonthProvider] mirrors the settled month, and a
/// month chosen elsewhere through the provider is turned to here.
///
/// On a phone a tapped day opens on Today. Give [onDaySelected] to take the tap
/// instead, as the tablet's History does to fill its day pane, and
/// [selectedDay] to mark the day on show.
class CalendarMonthView extends ConsumerStatefulWidget {
  const CalendarMonthView({
    super.key,
    this.selectedDay,
    this.onDaySelected,
    this.leadingTitle = false,
    this.cut,
  });

  /// The day to mark as the one on show, if any.
  final DateTime? selectedDay;

  /// Called with the day tapped, in place of opening it on Today.
  final ValueChanged<DateTime>? onDaySelected;

  /// Sets the month title at the start of the header, with both chevrons at
  /// the end, instead of centering it between them.
  final bool leadingTitle;

  /// The color behind the calendar, which rings each bead; defaults to the
  /// theme's surface.
  final Color? cut;

  @override
  ConsumerState<CalendarMonthView> createState() => _CalendarMonthViewState();
}

class _CalendarMonthViewState extends ConsumerState<CalendarMonthView> {
  /// The tallest a week row grows: past it a wide card gets wider cells, not
  /// taller ones.
  static const _maxRowHeight = 64.0;

  late final PageController _controller;

  /// Tracks the target page of an in-flight animation so that rapid chevron
  /// taps accumulate correctly. [_controller.page] only reflects the current
  /// scroll offset and won't round to the target until the animation is ~50 %
  /// complete; without this field two fast taps would coalesce into one turn.
  int? _animationTarget;

  /// The month this calendar last reported through [calendarMonthProvider], so
  /// a change that is not its own (a day chosen in another month) can be told
  /// from its own swipes and turned to.
  DateTime? _reported;

  @override
  void initState() {
    super.initState();
    _controller = PageController(
      initialPage: _monthsBeforeCurrent(ref.read(calendarMonthProvider)),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Snapshotted per build: a calendar left open across midnight shows a stale
  // today-ring (and across a month boundary, a shifted index mapping) until
  // the next rebuild. Accepted — the Logs tab is rebuilt on every visit.
  static DateTime _currentMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  static int _monthsBeforeCurrent(DateTime month) {
    final current = _currentMonth();
    return (current.year - month.year) * 12 + (current.month - month.month);
  }

  static DateTime _monthForIndex(int index) {
    final current = _currentMonth();
    return DateTime(current.year, current.month - index);
  }

  void _animateToIndex(int index) {
    _animationTarget = index;
    _controller
        .animateToPage(
          index,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
        )
        .whenComplete(() {
          // An interrupted animation's future still completes; only the owner
          // of the current target may clear it, or a newer tap's target would
          // be wiped mid-flight.
          if (_animationTarget == index) _animationTarget = null;
        });
  }

  /// The controller's authoritative page, falling back to the provider-derived
  /// index before the first layout. The provider lags the controller during
  /// an in-flight animation, so chevron targets must come from here or rapid
  /// taps coalesce into a single page turn.
  int _currentPageIndex(int providerIndex) =>
      _animationTarget ??
      (_controller.hasClients && _controller.page != null
          ? _controller.page!.round()
          : providerIndex);

  /// Turns to a month chosen outside the calendar: at once when it is far
  /// away, with the usual slide when it is the next one over.
  void _followMonth(DateTime month) {
    if (month == _reported || !_controller.hasClients) return;
    final target = _monthsBeforeCurrent(month);
    final shown = _currentPageIndex(target);
    if (shown == target) return;
    if ((shown - target).abs() > 1) {
      _controller.jumpToPage(target);
    } else {
      _animateToIndex(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(calendarMonthProvider, (_, month) => _followMonth(month));
    final month = ref.watch(calendarMonthProvider);
    final index = _monthsBeforeCurrent(month);
    final isCurrentMonth = index == 0;
    final l = AppLocalizations.of(context);
    final title = Text(
      DateFormat(
        'MMMM yyyy',
        Localizations.localeOf(context).languageCode,
      ).format(month),
      textAlign: widget.leadingTitle ? TextAlign.start : TextAlign.center,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );

    return Column(
      children: [
        Row(
          children: [
            if (widget.leadingTitle)
              Expanded(child: title)
            else
              IconButton(
                tooltip: l.analytics_previousMonth,
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _animateToIndex(_currentPageIndex(index) + 1),
              ),
            if (!widget.leadingTitle) Expanded(child: title),
            if (widget.leadingTitle)
              IconButton(
                tooltip: l.analytics_previousMonth,
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _animateToIndex(_currentPageIndex(index) + 1),
              ),
            IconButton(
              tooltip: l.analytics_nextMonth,
              icon: const Icon(Icons.chevron_right),
              onPressed: isCurrentMonth
                  ? null
                  : () {
                      final target = _currentPageIndex(index) - 1;
                      if (target >= 0) _animateToIndex(target);
                    },
            ),
          ],
        ),
        const _WeekdayHeader(),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            // Cells are square up to a row height a wide card can afford, so
            // a month does not stretch into tall, mostly empty rows.
            final cellWidth = constraints.maxWidth / 7;
            final rowHeight = math.min(cellWidth, _maxRowHeight);
            // The grid is as tall as the month on show needs (four to six
            // rows), so a five-week month leaves no empty row under it. It
            // eases to a new height once the swipe settles on the next month.
            return AnimatedContainer(
              duration: AppMotion.duration(context, milliseconds: 200),
              curve: Curves.easeOutCubic,
              height: rowHeight * monthRows(month),
              child: PageView.builder(
                controller: _controller,
                reverse: true,
                onPageChanged: (i) {
                  _reported = _monthForIndex(i);
                  ref.read(calendarMonthProvider.notifier).select(_reported!);
                },
                itemBuilder: (context, i) => _MonthGrid(
                  month: _monthForIndex(i),
                  rowHeight: rowHeight,
                  selectedDay: widget.selectedDay,
                  onDaySelected: widget.onDaySelected,
                  cut: widget.cut,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ── _WeekdayHeader ────────────────────────────────────────────────────────────

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final weekday = DateFormat.E(Localizations.localeOf(context).toString());
    return Row(
      children: [
        for (var day = 0; day < 7; day++)
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                // A fixed Monday anchors labels to the grid's Monday-first order.
                weekday.format(DateTime.utc(2024, 1, 1 + day)),
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
      ],
    );
  }
}

// ── _MonthGrid ────────────────────────────────────────────────────────────────

/// How many week rows [month] needs, Monday first: four to six.
@visibleForTesting
int monthRows(DateTime month) {
  final leadingBlanks = DateTime(month.year, month.month, 1).weekday - 1;
  final days = DateTime(month.year, month.month + 1, 0).day;
  return ((leadingBlanks + days) / 7).ceil();
}

class _MonthGrid extends ConsumerWidget {
  const _MonthGrid({
    required this.month,
    required this.rowHeight,
    required this.selectedDay,
    required this.onDaySelected,
    required this.cut,
  });

  final DateTime month;

  /// The height of a week row; the same for every month, so a page keeps its
  /// cells while the calendar changes height between months.
  final double rowHeight;
  final DateTime? selectedDay;
  final ValueChanged<DateTime>? onDaySelected;
  final Color? cut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // value collapses loading AND error into "no dots" — deliberate:
    // a calendar page should degrade quietly rather than flash spinners or
    // error text mid-swipe.
    final adherence =
        ref.watch(monthAdherenceProvider(month)).value ?? const {};
    final prn = ref.watch(monthPrnCountsProvider(month)).value ?? const {};
    final today = dateOnly(DateTime.now());
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leadingBlanks = DateTime(month.year, month.month, 1).weekday - 1;

    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisExtent: rowHeight,
      ),
      itemCount: leadingBlanks + daysInMonth,
      itemBuilder: (context, index) {
        if (index < leadingBlanks) return const SizedBox.shrink();
        final day = DateTime(
          month.year,
          month.month,
          index - leadingBlanks + 1,
        );
        return _DayCell(
          day: day,
          adherence: adherence[day],
          prnTaken: prn[day] ?? 0,
          isToday: day == today,
          isFuture: day.isAfter(today),
          isSelected: selectedDay != null && dateOnly(selectedDay!) == day,
          onSelected: onDaySelected,
          cut: cut,
        );
      },
    );
  }
}

// ── _DayCell ──────────────────────────────────────────────────────────────────

class _DayCell extends ConsumerWidget {
  const _DayCell({
    required this.day,
    required this.adherence,
    required this.prnTaken,
    required this.isToday,
    required this.isFuture,
    required this.isSelected,
    required this.onSelected,
    required this.cut,
  });

  final DateTime day;
  final DayAdherence? adherence;

  /// As-needed doses taken this day.
  final int prnTaken;
  final bool isToday;
  final bool isFuture;
  final bool isSelected;
  final ValueChanged<DateTime>? onSelected;
  final Color? cut;

  /// How many as-needed capsules a day shows beside its planned beads.
  static const _prnBeads = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l = AppLocalizations.of(context);
    final ratio = adherence?.ratio;

    final beads = isFuture
        ? const <DoseBead>[]
        : [
            if (adherence != null) ...monthDayBeads(adherence!, today: isToday),
            for (var i = 0; i < math.min(prnTaken, _prnBeads); i++)
              DoseBead.asNeeded,
          ];

    final pct = ratio != null
        ? l.history_adherence('${(ratio * 100).round()}%')
        : '';
    final dayLabel = DateFormat(
      'd MMMM',
      Localizations.localeOf(context).languageCode,
    ).format(day);
    final semanticLabel = isFuture
        ? l.th_calendarDayFuture(dayLabel)
        : pct.isNotEmpty
        ? '$dayLabel, $pct'
        : dayLabel;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    final ground = isSelected ? cs.primaryContainer : cut ?? cs.surface;

    return Semantics(
      label: semanticLabel,
      button: !isFuture,
      selected: isSelected,
      child: InkWell(
        key: ValueKey('day-cell-${day.year}-${day.month}-${day.day}'),
        customBorder: shape,
        onTap: isFuture
            ? null
            : () {
                final onSelected = this.onSelected;
                if (onSelected != null) {
                  onSelected(day);
                  return;
                }
                ref.read(selectedDateProvider.notifier).select(day);
                // Literal path: importing AppPaths would pull app_router.dart
                // into the feature and create an import cycle via the screens.
                context.go('/home');
              },
        child: Container(
          key: isToday ? const ValueKey('day-today-ring') : null,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: isSelected ? cs.primaryContainer : null,
            borderRadius: BorderRadius.circular(12),
            border: isToday ? Border.all(color: cs.primary, width: 1.5) : null,
          ),
          // At large text the number and the dots no longer fit a small cell,
          // so they scale down together instead of overflowing.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${day.day}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isSelected
                        ? cs.onPrimaryContainer
                        : isFuture
                        ? cs.outline
                        : cs.onSurface,
                    fontWeight: isToday || isSelected ? FontWeight.w700 : null,
                  ),
                ),
                const SizedBox(height: 2),
                if (beads.isNotEmpty)
                  CustomPaint(
                    key: ValueKey(
                      'day-dot-${day.year}-${day.month}-${day.day}',
                    ),
                    size: const Size(24, 13),
                    painter: MonthDayPainter(
                      beads: [
                        for (final bead in beads)
                          (bead: bead, color: bead.colorIn(theme)),
                      ],
                      cut: ground,
                    ),
                  )
                else
                  const SizedBox(width: 24, height: 13),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A month day's doses as the same beads History's day tiles use: taken,
/// then skipped, then recorded misses, then the rest (still planned today, not
/// recorded before). A recorded miss is a missed bead on any day, today
/// included; only a dose nobody recorded is a planned or unrecorded ring.
/// A day with more than eight doses keeps its proportions in eight beads.
List<DoseBead> monthDayBeads(DayAdherence day, {required bool today}) {
  final expected = day.expected;
  if (expected <= 0) return const [];
  final shown = expected > 8 ? 8 : expected;
  final taken = (day.taken * shown / expected).round().clamp(0, shown);
  final skipped = (day.skipped * shown / expected).round().clamp(
    0,
    shown - taken,
  );
  final missed = (day.missed * shown / expected).round().clamp(
    0,
    shown - taken - skipped,
  );
  return [
    for (var i = 0; i < taken; i++) DoseBead.taken,
    for (var i = 0; i < skipped; i++) DoseBead.skipped,
    for (var i = 0; i < missed; i++) DoseBead.missed,
    for (var i = taken + skipped + missed; i < shown; i++)
      today ? DoseBead.planned : DoseBead.unrecorded,
  ];
}

class MonthDayPainter extends CustomPainter {
  const MonthDayPainter({required this.beads, required this.cut});
  final List<({DoseBead bead, Color color})> beads;
  final Color cut;

  @override
  void paint(Canvas canvas, Size size) =>
      paintBeadRow(canvas, size, beads, cut: cut, radius: 2.6, gap: 1.8);

  @override
  bool shouldRepaint(MonthDayPainter old) =>
      old.cut != cut || !listEquals(old.beads, beads);
}
