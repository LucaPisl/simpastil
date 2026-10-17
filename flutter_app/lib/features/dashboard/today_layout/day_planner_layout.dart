import 'package:flutter/material.dart';

import '../../../core/medication/care_day.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/scene/scene_clock.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import 'as_needed_entry.dart';
import 'count_header.dart';
import 'entry_identity.dart';
import 'low_stock_notice.dart';
import 'today_layout.dart';

/// Minutes after midnight of a planned local time ("09:30" or "09:30:00"),
/// or null when the planned time is missing or unreadable. A null result is
/// never plotted on the hour grid; it goes to the "Time unknown" list.
int? plannerMinuteOf(String? plannedLocalTime) {
  if (plannedLocalTime == null) return null;
  final match = RegExp(
    r'^(\d{1,2}):(\d{2})(?::\d{2})?$',
  ).firstMatch(plannedLocalTime.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

/// Text scale at which the hour grid gives way to a plain agenda list.
const double _agendaScale = 1.3;

/// Day planner: the day as an hour-by-hour agenda.
///
/// An hour column runs from morning to night; each dose sits in the hour row
/// of its planned time and shows the exact minute. On the scene day a "now"
/// line falls between the doses before and after it, moving once a minute.
/// A dose whose planned time is not known is never placed on the grid: it is
/// listed apart under "Time unknown". At large text (1.3x and above) the grid
/// becomes a simple agenda grouped by part of day, with the same cards.
///
/// Recording goes only through [TodayLayoutData.onTake] / `onUndo`; the
/// capsule on each card is the shared [ReceiptCapsule].
class DayPlannerLayout extends StatefulWidget {
  const DayPlannerLayout({super.key, required this.data});
  final TodayLayoutData data;

  @override
  State<DayPlannerLayout> createState() => _DayPlannerLayoutState();
}

class _DayPlannerLayoutState extends State<DayPlannerLayout> {
  final Map<String, GlobalKey> _keys = {};
  String? _ownFocus;

  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void didUpdateWidget(DayPlannerLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focused = widget.data.focusedId;
    if (focused == null || focused == oldWidget.data.focusedId) return;
    if (focused == _ownFocus) {
      _ownFocus = null;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[focused]?.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: .2,
        duration: AppMotion.duration(context, milliseconds: 320),
        curve: AppMotion.curve,
      );
    });
  }

  void _focus(String id) {
    _ownFocus = id;
    widget.data.onFocus(id);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final agenda =
        MediaQuery.textScalerOf(context).scale(10) >= 10 * _agendaScale;
    final count = SettleHalo(
      token: data.settleToken,
      claim: data.claimMoment,
      onDone: data.onMomentDone,
      child: Semantics(
        liveRegion: data.allRecorded,
        child: RollingLabel(text: data.countLabel(l), style: text.labelLarge),
      ),
    );
    final select = data.onSelectDoses == null
        ? null
        : TextButton.icon(
            key: const ValueKey('planner-select'),
            onPressed: data.busy ? null : data.onSelectDoses,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: text.labelLarge,
            ),
            icon: const Icon(Icons.checklist, size: 19),
            label: Text(l.t10_select),
          );

    final timed = <(int, CareDayEntry)>[];
    final unknown = <CareDayEntry>[];
    final scheduled = data.scheduledEntries;
    for (final entry in scheduled) {
      final minute = plannerMinuteOf(data.rowOf(entry).plannedLocalTime);
      if (minute == null) {
        unknown.add(entry);
      } else {
        timed.add((minute, entry));
      }
    }
    // A recorded as-needed dose sits in the hour it was actually taken; only
    // one whose actual time is genuinely unknown waits under "Time unknown".
    final records = <String, AsNeededRecord>{};
    for (final record in data.asNeededRecords) {
      records[record.entry.occurrence.id] = record;
      final minute = record.minuteOfDay;
      if (minute == null) {
        unknown.add(record.entry);
      } else {
        timed.add((minute, record.entry));
      }
    }
    // Stable: equal minutes keep the day's planned order.
    final order = {
      for (final (i, e) in [
        ...scheduled,
        ...records.values.map((r) => r.entry),
      ].indexed)
        e: i,
    };
    timed.sort((a, b) {
      final byMinute = a.$1.compareTo(b.$1);
      return byMinute != 0 ? byMinute : order[a.$2]!.compareTo(order[b.$2]!);
    });

    var index = 0;
    Widget card(CareDayEntry entry) {
      final id = entry.occurrence.id;
      final record = records[id];
      return StaggeredEntrance(
        index: index++,
        identity: 'planner-${data.day.localDate}',
        child: KeyedSubtree(
          key: _keyFor(id),
          child: record != null
              ? AsNeededRecordTile(
                  data: data,
                  record: record,
                  showPerson: data.day.people.length != 1,
                )
              : _PlannerCard(
                  data: data,
                  entry: entry,
                  onFocus: () => _focus(id),
                ),
        ),
      );
    }

    return Column(
      key: const ValueKey('planner-layout'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TodayCountHeader(
          count: count,
          select: select,
          overview: todayOverviewButton(context, data),
          stacked: agenda,
        ),
        if (data.day.state == CareDayState.recorded && data.hasExpected)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l.t10_knownOutcomes),
          ),
        const SizedBox(height: 12),
        if (data.lowStock.isNotEmpty) _AllDayRow(data: data, agenda: agenda),
        if (timed.isNotEmpty)
          SceneClock(
            builder: (context, now) {
              index = 0;
              final nowMinute = routineDateKey(now) == data.day.localDate
                  ? plannerNowMinute(now)
                  : null;
              return agenda
                  ? _Agenda(
                      key: const ValueKey('planner-agenda'),
                      timed: timed,
                      now: nowMinute == null ? null : now,
                      card: card,
                    )
                  : _HourGrid(
                      key: const ValueKey('planner-grid'),
                      timed: timed,
                      now: nowMinute == null ? null : now,
                      past:
                          data.day.localDate.compareTo(routineDateKey(now)) < 0,
                      card: card,
                    );
            },
          ),
        if (unknown.isNotEmpty)
          Padding(
            key: const ValueKey('planner-unknown'),
            padding: EdgeInsets.only(top: timed.isEmpty ? 0 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SectionHeading(
                  icon: Icons.help_outline,
                  label: l.t15_timeUnknown,
                ),
                for (final entry in unknown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: card(entry),
                  ),
              ],
            ),
          ),
        if (data.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                data.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
      ],
    );
  }
}

/// Medication that runs low, as an all-day row above the hours the way a
/// calendar shows an all-day event: it belongs to the day, not to an hour.
class _AllDayRow extends StatelessWidget {
  const _AllDayRow({required this.data, required this.agenda});
  final TodayLayoutData data;
  final bool agenda;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final label = Text(
      l.tt_allDay,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final lines = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in data.lowStock)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LowStockLine(
              row: row,
              dense: true,
              onAddStock: data.onAddStock == null
                  ? null
                  : () => data.onAddStock!(row),
            ),
          ),
      ],
    );
    return Padding(
      key: const ValueKey('planner-all-day'),
      padding: const EdgeInsets.only(bottom: 4),
      child: agenda
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: label,
                ),
                lines,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 52,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8, top: 10),
                    child: Align(
                      alignment: AlignmentDirectional.topEnd,
                      child: label,
                    ),
                  ),
                ),
                Expanded(child: lines),
              ],
            ),
    );
  }
}

/// The hour column: one row per hour from morning to night, each holding the
/// doses planned in that hour. Empty hours stay short so the day reads at a
/// glance; the grid stretches to fit what an hour holds rather than letting
/// cards overlap.
class _HourGrid extends StatelessWidget {
  const _HourGrid({
    super.key,
    required this.timed,
    required this.now,
    required this.past,
    required this.card,
  });
  final List<(int, CareDayEntry)> timed;
  final DateTime? now;

  /// The whole day is before today.
  final bool past;
  final Widget Function(CareDayEntry) card;

  @override
  Widget build(BuildContext context) {
    final nowMinute = plannerNowMinute(now);
    // Only hours that hold a dose, or the present hour, get a row; runs of
    // empty hours between them collapse into one slim "quiet hours" divider.
    final hours = <int>{
      for (final (minute, _) in timed) minute ~/ 60,
      ?(nowMinute == null ? null : nowMinute ~/ 60),
    }.toList()..sort();
    final rows = <Widget>[];
    for (var i = 0; i < hours.length; i++) {
      final hour = hours[i];
      if (i > 0 && hour - hours[i - 1] > 1) {
        rows.add(_QuietHours(from: hours[i - 1] + 1, to: hour));
      }
      rows.add(
        _HourRow(
          hour: hour,
          last: i == hours.length - 1,
          elapsed: past || nowMinute != null && (hour + 1) * 60 <= nowMinute,
          children: [
            ..._withNow(
              [
                for (final (minute, entry) in timed)
                  if (minute ~/ 60 == hour) (minute, card(entry)),
              ],
              nowMinute != null && nowMinute ~/ 60 == hour ? now : null,
              nowMinute,
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// Minutes after midnight of [now] on the device's local clock, or null when
/// there is no now. A UTC instant is converted to local time first.
@visibleForTesting
int? plannerNowMinute(DateTime? now) {
  if (now == null) return null;
  final local = now.isUtc ? now.toLocal() : now;
  return local.hour * 60 + local.minute;
}

/// A slim divider standing for a run of empty hours, `from` inclusive to
/// `to` exclusive.
class _QuietHours extends StatelessWidget {
  const _QuietHours({required this.from, required this.to});
  final int from, to;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final start = clockHour(context, from), end = clockHour(context, to);
    final label = l.lay_quietHours(start, end);
    // The hours are one range: when the line wraps it breaks before the
    // range, never inside it.
    final range = '$start – $end';
    final shown = label.replaceFirst(range, range.replaceAll(' ', '\u00A0'));
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Padding(
        key: ValueKey('planner-quiet-$from'),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const SizedBox(width: 52),
            Icon(Icons.bedtime_outlined, size: 14, color: colors.outline),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                shown,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Divider(
                height: 1,
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Places the now line between the items before and after it.
List<Widget> _withNow(
  List<(int, Widget)> items,
  DateTime? now,
  int? nowMinute,
) {
  if (now == null || nowMinute == null) return [for (final i in items) i.$2];
  final at = items.indexWhere((i) => i.$1 > nowMinute);
  final widgets = [for (final i in items) i.$2];
  widgets.insert(
    at < 0 ? widgets.length : at,
    _NowLine(key: const ValueKey('planner-now'), now: now),
  );
  return widgets;
}

class _HourRow extends StatelessWidget {
  const _HourRow({
    required this.hour,
    required this.last,
    required this.elapsed,
    required this.children,
  });
  final int hour;
  final bool last, elapsed;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final empty = children.isEmpty;
    final label = Text(
      clockHour(context, hour),
      style: theme.textTheme.labelMedium?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        fontWeight: empty ? FontWeight.w500 : FontWeight.w700,
        color: empty || elapsed ? colors.onSurfaceVariant : colors.onSurface,
      ),
    );
    return KeyedSubtree(
      key: ValueKey('planner-hour-$hour'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Align(
                alignment: AlignmentDirectional.topEnd,
                child: Transform.translate(
                  offset: const Offset(0, -7),
                  child: label,
                ),
              ),
            ),
          ),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: BorderDirectional(
                  top: BorderSide(
                    color: colors.outlineVariant.withValues(
                      alpha: empty ? .45 : .8,
                    ),
                  ),
                  start: BorderSide(
                    color: elapsed
                        ? colors.primary.withValues(alpha: .55)
                        : colors.outlineVariant.withValues(alpha: .6),
                    width: elapsed ? 2 : 1,
                  ),
                ),
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: 10,
                  top: empty ? 0 : 8,
                  bottom: empty ? 0 : (last ? 2 : 4),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: empty ? 30 : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final child in children)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: child,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Large-text agenda: no grid, the doses grouped by part of the day under
/// plain headings, with the now line in its place.
class _Agenda extends StatelessWidget {
  const _Agenda({
    super.key,
    required this.timed,
    required this.now,
    required this.card,
  });
  final List<(int, CareDayEntry)> timed;
  final DateTime? now;
  final Widget Function(CareDayEntry) card;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final nowMinute = plannerNowMinute(now);
    String partOf(int minute) {
      final hour = minute ~/ 60;
      if (hour < 5 || hour >= 21) return l.r07_night;
      if (hour < 12) return l.r07_morning;
      if (hour < 17) return l.r07_afternoon;
      return l.r07_evening;
    }

    final children = <Widget>[];
    String? part;
    var nowPlaced = nowMinute == null;
    for (final (minute, entry) in timed) {
      if (!nowPlaced && minute > nowMinute!) {
        children.add(_nowItem());
        nowPlaced = true;
      }
      final next = partOf(minute);
      if (next != part) {
        part = next;
        children.add(
          Padding(
            padding: EdgeInsets.only(top: children.isEmpty ? 0 : 10),
            child: _SectionHeading(icon: Icons.schedule, label: next),
          ),
        );
      }
      children.add(
        Padding(padding: const EdgeInsets.only(bottom: 10), child: card(entry)),
      );
    }
    if (!nowPlaced) children.add(_nowItem());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _nowItem() => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: _NowLine(key: const ValueKey('planner-now'), now: now!),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Now, 12:14" on a thin accent line with a dot at its start.
class _NowLine extends StatelessWidget {
  const _NowLine({super.key, required this.now});
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final time = TimeOfDay.fromDateTime(now).format(context);
    return Row(
      children: [
        ExcludeSemantics(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: primary,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.surface, width: 1.5),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          l.lay_now(time),
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ExcludeSemantics(
            child: Container(height: 2, color: primary.withValues(alpha: .6)),
          ),
        ),
      ],
    );
  }
}

class _PlannerCard extends StatelessWidget {
  const _PlannerCard({
    required this.data,
    required this.entry,
    required this.onFocus,
  });
  final TodayLayoutData data;
  final CareDayEntry entry;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final id = entry.occurrence.id;
    final row = data.rowOf(entry);
    final head = data.headOf(entry);
    final pending = row.state == 'pending';
    final missed = row.state == 'missed';
    final saving = data.isSaving(entry);
    final known = plannerMinuteOf(row.plannedLocalTime) != null;
    final time = known ? plannedTimeLabel(context, row) : l.t15_timeUnknown;
    final state = data.stateLabel(l, entry);
    final travel = data.travelTimeOf(row);
    final focused = data.focusedId == id;

    final status = CareTransition(
      child: Row(
        key: ValueKey('${row.state}/${row.stateVersion}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pending
                ? Icons.radio_button_unchecked
                : row.state == 'taken'
                ? Icons.check_circle
                : missed
                ? Icons.error_outline_rounded
                : Icons.remove_circle_outline,
            size: 16,
            color: semantic.forState(row.state),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              !pending && !missed && head != null
                  ? '$state · ${recordedTimeLabel(context, head, row)}'
                  : state,
              key: ValueKey('planner-state-$id'),
              style: text.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: semantic.forState(row.state),
              ),
            ),
          ),
        ],
      ),
    );

    final heading = Semantics(
      button: true,
      selected: focused,
      liveRegion: !pending,
      label: l.lay_itemLabel(time, entry.snapshot.pillName, state),
      excludeSemantics: true,
      child: Pressable(
        key: ValueKey('planner-item-$id'),
        radius: BorderRadius.circular(16),
        onTap: onFocus,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: ReceiptCapsule(
                  key: ValueKey('planner-capsule-$id'),
                  taken: row.state == 'taken',
                  moment: data.momentOf(id),
                  claim: data.claimMoment,
                  onDone: data.onMomentDone,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      time,
                      style: text.labelLarge?.copyWith(
                        color: known ? colors.primary : colors.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    EntryMedicationName(
                      entry: entry,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (data.day.people.length != 1)
                      EntryPersonLine(
                        entry: entry,
                        label: l.t08_forPerson(entry.person.name),
                        style: text.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        plannedAmountLabel(l, entry),
                        style: text.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (travel != null) Text(travel, style: text.bodySmall),
                    const SizedBox(height: 6),
                    status,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Widget? action;
    if (pending || missed) {
      action = SavingPressable(
        saving: saving,
        radius: BorderRadius.circular(14),
        child: FilledButton.icon(
          key: ValueKey('planner-take-$id'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: (pending ? data.canTake(entry) : data.canTakeLate(entry))
              ? () => data.onTake(entry)
              : null,
          icon: const Icon(Icons.check_circle_outline),
          label: Text(
            saving
                ? l.sc_saving
                : missed
                ? l.dose_takeLateNow
                : l.t08_takenNow,
          ),
        ),
      );
    } else if (head != null && head.action != 'undo') {
      action = SavingPressable(
        saving: saving,
        radius: BorderRadius.circular(14),
        child: OutlinedButton.icon(
          key: ValueKey('planner-undo-$id'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: data.canUndo(entry) ? () => data.onUndo(entry) : null,
          icon: const Icon(Icons.undo),
          label: Text(saving ? l.sc_saving : l.t08_undo),
        ),
      );
    }

    // A missed dose can be taken late or withdrawn; the rest of the row
    // actions stay where they are for every other state.
    if (missed && action != null) {
      action = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          action,
          const SizedBox(height: 8),
          SavingPressable(
            saving: saving,
            radius: BorderRadius.circular(14),
            child: OutlinedButton.icon(
              key: ValueKey('planner-undo-$id'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: data.canUndo(entry) ? () => data.onUndo(entry) : null,
              icon: const Icon(Icons.undo),
              label: Text(saving ? l.sc_saving : l.t08_undo),
            ),
          ),
        ],
      );
    }

    return AnimatedContainer(
      duration: AppMotion.duration(context),
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: row.state == 'taken'
            ? Color.alphaBlend(
                colors.primaryContainer.withValues(alpha: .35),
                colors.surface,
              )
            : colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: focused
              ? colors.primary.withValues(alpha: .6)
              : colors.outlineVariant.withValues(alpha: .55),
          width: focused ? 1.5 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heading,
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!pending)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DurableSaveFeedback(
                        label: todaySharingLabel(l, data.sharingOf(entry)),
                      ),
                    ),
                  if (action != null) action,
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: ValueKey('planner-details-$id'),
                      onPressed: data.busy
                          ? null
                          : () => data.onOpenDetails(entry),
                      icon: const Icon(Icons.more_horiz),
                      label: Text(l.t10_details),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
