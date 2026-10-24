import 'package:flutter/material.dart';
import 'package:collection/collection.dart' show mergeSort;
import 'package:timezone/timezone.dart' as tz;

import '../../../core/medication/care_day.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/scene/scene_clock.dart';
import '../../../core/medication/routine_definition.dart' show routineDateKey;
import 'as_needed_entry.dart';
import 'count_header.dart';
import 'dose_weight.dart';
import 'entry_identity.dart';
import 'journal_page.dart';
import 'low_stock_notice.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import 'today_layout.dart';

/// The "Dose details" link sits flush with the entry text above it, so it
/// drops the button's own leading padding and keeps a 44 dp touch target.
final ButtonStyle _detailsLinkStyle = TextButton.styleFrom(
  minimumSize: const Size(0, 44),
  padding: const EdgeInsetsDirectional.only(end: 12),
  alignment: AlignmentDirectional.centerStart,
);

/// Daily journal: the day as a readable record of care.
///
/// Doses sit under Morning, Afternoon, Evening and Night as dated sentences
/// ("08:00 · Casey took Magnesium 250 mg", "Planned 20:00 · Casey to take
/// ..."). Each line carries its own action inline; the receipt capsule in the
/// margin is the same one as in the other layouts.
class DailyJournalLayout extends StatefulWidget {
  const DailyJournalLayout({super.key, required this.data});
  final TodayLayoutData data;

  /// The hour that places an entry in the day: when a dose was actually
  /// recorded (in its routine's zone), otherwise the planned time.
  static int? _hourOf(TodayLayoutData data, CareDayEntry entry) {
    final minute = minuteOfEntry(data, entry);
    return minute == null ? null : minute ~/ 60;
  }

  /// The minute of the day that places an entry: when it was recorded, else
  /// when it was planned. Entries in a period read in this order, so a
  /// journal never says 11:05 before 10:51.
  @visibleForTesting
  static int? minuteOfEntry(TodayLayoutData data, CareDayEntry entry) {
    final row = data.rowOf(entry);
    final head = data.headOf(entry);
    if (row.state != 'pending' &&
        head != null &&
        head.actualTimeKnown &&
        head.actualAt != null) {
      try {
        final at = tz.TZDateTime.from(
          head.actualAt!,
          tz.getLocation(row.timeZone),
        );
        return at.hour * 60 + at.minute;
      } on Object {
        final at = head.actualAt!.toLocal();
        return at.hour * 60 + at.minute;
      }
    }
    final planned = row.plannedLocalTime;
    if (planned == null || planned.length < 2) return null;
    final hour = int.tryParse(planned.substring(0, 2));
    if (hour == null) return null;
    final minute = planned.length >= 5
        ? int.tryParse(planned.substring(3, 5)) ?? 0
        : 0;
    return hour * 60 + minute;
  }

  /// Period an entry is filed under, by the recorded time once recorded.
  @visibleForTesting
  static String periodOfEntry(TodayLayoutData data, CareDayEntry entry) =>
      periodOfHour(_hourOf(data, entry));

  /// Period of an hour of the day; no hour reads as morning.
  @visibleForTesting
  static String periodOfHour(int? hour) {
    final h = hour ?? 8;
    if (h >= 5 && h < 12) return 'morning';
    if (h >= 12 && h < 17) return 'afternoon';
    if (h >= 17 && h < 21) return 'evening';
    return 'night';
  }

  @override
  State<DailyJournalLayout> createState() => _DailyJournalLayoutState();
}

class _DailyJournalLayoutState extends State<DailyJournalLayout> {
  // Each line's state and period at the last build, so a period that
  // appears because a dose was just recorded into it can fill its well from
  // where it was.
  Map<String, (String, String)> _last = const {};

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final last = _last;
    // Scheduled doses and recorded as-needed doses share the periods; a
    // pending as-needed row is in neither, so it is never a line to act on.
    final records = {
      for (final r in data.asNeededRecords) r.entry.occurrence.id: r,
    };
    final all = [
      ...data.scheduledEntries,
      for (final r in records.values) r.entry,
    ];
    _last = {
      for (final e in all)
        e.occurrence.id: (
          data.rowOf(e).state,
          DailyJournalLayout.periodOfEntry(data, e),
        ),
    };
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
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
            key: const ValueKey('journal-select'),
            onPressed: data.busy ? null : data.onSelectDoses,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: text.labelLarge,
            ),
            icon: const Icon(Icons.checklist, size: 19),
            label: Text(l.t10_select),
          );
    final periods = <(String, String)>[
      ('morning', l.jrn_morning),
      ('afternoon', l.jrn_afternoon),
      ('evening', l.jrn_evening),
      ('night', l.jrn_night),
    ];
    var lineIndex = 0;
    return Column(
      key: const ValueKey('journal-layout'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TodayCountHeader(
          count: count,
          select: select,
          overview: todayOverviewButton(context, data),
          stacked: large,
        ),
        if (data.showsKnownOutcomes)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l.t10_knownOutcomes),
          ),
        const SizedBox(height: 8),
        for (final row in data.lowStock)
          Padding(
            key: ValueKey('journal-stock-${row.pillId}'),
            padding: const EdgeInsets.only(top: 12),
            child: lowStockRowFor(row, data.onAddStock, data.onDismissLowStock),
          ),
        for (final (key, title) in periods)
          ...() {
            final entries = [
              for (final e in all)
                if (DailyJournalLayout.periodOfEntry(data, e) == key) e,
            ];
            // A stable sort: entries with no time keep their given order.
            mergeSort<CareDayEntry>(
              entries,
              compare: (a, b) =>
                  (DailyJournalLayout.minuteOfEntry(data, a) ?? 8 * 60)
                      .compareTo(
                        DailyJournalLayout.minuteOfEntry(data, b) ?? 8 * 60,
                      ),
            );
            if (entries.isEmpty) return const <Widget>[];
            return [
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: _PeriodHeader(
                  data: data,
                  period: key,
                  title: title,
                  // As-needed doses are not part of the day's plan, so they
                  // neither fill nor count in the period's well.
                  states: [
                    for (final e in entries)
                      if (!records.containsKey(e.occurrence.id))
                        data.rowOf(e).state,
                  ],
                  // A line that has just moved here was not in this well.
                  from: [
                    for (final e in entries)
                      if (!records.containsKey(e.occurrence.id))
                        switch (last[e.occurrence.id]) {
                          (final state, final at) when at == key => state,
                          (_, _) => 'pending',
                          null => data.rowOf(e).state,
                        },
                  ],
                ),
              ),
              for (final entry in entries)
                // Keyed, so a line that moves to another period when it is
                // recorded keeps its state and writes its ink on arrival.
                StaggeredEntrance(
                  key: ValueKey('journal-entry-${entry.occurrence.id}'),
                  index: lineIndex++,
                  identity: 'journal-${data.day.localDate}',
                  child: switch (records[entry.occurrence.id]) {
                    final record? => _AsNeededJournalLine(
                      data: data,
                      record: record,
                    ),
                    null => _JournalLine(data: data, entry: entry),
                  },
                ),
            ];
          }(),
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

/// A recorded as-needed dose written into the journal at the time it was
/// taken: "12:05 · Luca took Ibuprofen 400 mg, as needed", with the "As
/// needed" tag. It has no take or undo (the ring card has those) and a quiet
/// margin dot instead of a receipt capsule, because nothing was due.
class _AsNeededJournalLine extends StatelessWidget {
  const _AsNeededJournalLine({required this.data, required this.record});
  final TodayLayoutData data;
  final AsNeededRecord record;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final semantic = theme.extension<AppSemanticColors>()!;
    final entry = record.entry;
    final id = entry.occurrence.id;
    final dosage = entry.snapshot.dosage;
    final medication = dosage?.isNotEmpty == true
        ? '${entry.snapshot.pillName} $dosage'
        : entry.snapshot.pillName;
    final person = entry.person.name;
    final sentence = record.timeKnown
        ? l.jrn_tookAsNeeded(record.timeLabel(context), person, medication)
        : l.jrn_tookAsNeededUnknown(person, medication);
    return Semantics(
      container: true,
      child: Container(
        key: ValueKey('journal-line-$id'),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsetsDirectional.only(start: 12, top: 4),
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(width: 1.5, color: colors.tertiary),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12, top: 3),
              child: EntryMedicationMark(entry: entry, size: 24),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sentence,
                    key: ValueKey('journal-text-$id'),
                    style: text.bodyLarge?.copyWith(
                      height: 1.5,
                      color: semantic.forState('taken'),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AsNeededTag(),
                  ),
                  TextButton(
                    key: ValueKey('journal-details-$id'),
                    style: _detailsLinkStyle,
                    onPressed: data.busy
                        ? null
                        : () {
                            data.onFocus(id);
                            data.onOpenDetails(entry);
                          },
                    child: Text(l.t10_details),
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

class _JournalLine extends StatelessWidget {
  const _JournalLine({required this.data, required this.entry});
  final TodayLayoutData data;
  final CareDayEntry entry;

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
    final late = data.isTakenLateEntry(entry);
    final dosage = entry.snapshot.dosage;
    final medication = dosage?.isNotEmpty == true
        ? '${entry.snapshot.pillName} $dosage'
        : entry.snapshot.pillName;
    final person = entry.person.name;
    final skipped = row.state == 'skipped';
    final known = head != null && head.actualTimeKnown && head.actualAt != null;
    final sentence = pending
        ? l.jrn_planned(plannedTimeLabel(context, row), person, medication)
        : missed
        ? l.jrn_missed(plannedTimeLabel(context, row), person, medication)
        : known
        ? (skipped
              ? l.jrn_skipped
              : late
              ? l.jrn_tookLate
              : l.jrn_took)(
            recordedTimeLabel(context, head, row),
            person,
            medication,
          )
        : (skipped ? l.jrn_skippedUnknown : l.jrn_tookUnknown)(
            person,
            medication,
          );
    final travel = data.travelTimeOf(row);

    final action = doseActions(data, entry, prefix: 'journal');
    void openDetails() {
      data.onFocus(id);
      data.onOpenDetails(entry);
    }

    final sentenceText = Text(
      sentence,
      key: ValueKey('journal-text-$id'),
      style: text.bodyLarge?.copyWith(
        height: 1.5,
        color: pending ? colors.onSurface : semantic.forState(row.state),
        fontWeight: pending ? FontWeight.w400 : FontWeight.w600,
      ),
    );
    final sharing = data.sharingOf(entry);

    // A taken or skipped line stays one sentence, marked as on every other
    // layout, with a text Undo at its end; tapping it opens its details.
    final Widget body = data.showsDone(entry)
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, box) => Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        key: ValueKey('journal-item-$id'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: data.busy ? null : openDetails,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  skipped
                                      ? Icons.remove_circle_outline
                                      : Icons.check_circle,
                                  size: 18,
                                  color: semantic.forState(row.state),
                                ),
                                const SizedBox(width: 8),
                                Expanded(child: sentenceText),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * .45),
                      child: DoseUndoButton(
                        data: data,
                        entry: entry,
                        prefix: 'journal',
                      ),
                    ),
                  ],
                ),
              ),
              if (travel != null) Text(travel, style: text.bodySmall),
              if (sharingNeedsReview(sharing))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: DurableSaveFeedback(
                    label: todaySharingLabel(l, sharing),
                  ),
                ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sentenceText,
              if (travel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(travel, style: text.bodySmall),
                ),
              if (missed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: DurableSaveFeedback(
                    label: todaySharingLabel(l, sharing),
                  ),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ?action,
                  TextButton(
                    key: ValueKey('journal-details-$id'),
                    style: _detailsLinkStyle,
                    onPressed: data.busy ? null : openDetails,
                    child: Text(l.t10_details),
                  ),
                ],
              ),
            ],
          );

    return Semantics(
      container: true,
      liveRegion: !pending,
      child: Container(
        key: ValueKey('journal-line-$id'),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsetsDirectional.only(start: 12, top: 4),
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(
              width: data.focusedId == id ? 3 : 1.5,
              color: data.focusedId == id
                  ? colors.primary
                  : colors.outlineVariant,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12, top: 3),
              child: ReceiptCapsule(
                key: ValueKey('journal-capsule-$id'),
                taken: row.state == 'taken',
                moment: data.momentOf(id),
                claim: data.claimMoment,
                onDone: data.onMomentDone,
              ),
            ),
            Expanded(
              // A zero-length AnimatedSize re-dirties itself mid-layout, so
              // Reduce motion takes the plain swap.
              child: AppMotion.quiet(context)
                  ? ReceiptSwap(receipt: data.swapKeyOf(entry), child: body)
                  : AnimatedSize(
                      duration: AppMotion.standard,
                      curve: AppMotion.curve,
                      alignment: Alignment.topCenter,
                      child: ReceiptSwap(
                        receipt: data.swapKeyOf(entry),
                        child: body,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A period's heading: its ink well, filled as far as the period is
/// recorded, and its name. On today's page the current period's well is
/// outlined.
class _PeriodHeader extends StatelessWidget {
  const _PeriodHeader({
    required this.data,
    required this.period,
    required this.title,
    required this.states,
    required this.from,
  });

  final TodayLayoutData data;
  final String period;
  final String title;
  final List<String> states;
  final List<String> from;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final glyph = MediaQuery.textScalerOf(context).scale(40).clamp(40.0, 52.0);
    final recorded = states.where(journalDoseRecorded).length;
    if (states.isEmpty) {
      // Only as-needed doses here: nothing was planned, so no well or count.
      return Semantics(
        header: true,
        label: title,
        excludeSemantics: true,
        child: Text(
          title,
          key: ValueKey('journal-period-$period'),
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w300,
            letterSpacing: .2,
            height: 1.2,
          ),
        ),
      );
    }
    return Semantics(
      header: true,
      label: l.jrn_periodSummary(title, recorded, states.length),
      excludeSemantics: true,
      child: Row(
        children: [
          SceneClock(
            builder: (context, now) {
              final today = routineDateKey(now);
              // The scene's own clock decides, so the outlined well agrees
              // with the sky above it.
              final time = data.day.localDate == today
                  ? journalPeriodTime(period, now)
                  : data.day.localDate.compareTo(today) < 0
                  ? JournalPeriodTime.past
                  : JournalPeriodTime.future;
              return JournalInkWell(
                key: ValueKey('journal-well-$period'),
                states: states,
                from: from,
                time: time,
                size: glyph,
              );
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              key: ValueKey('journal-period-$period'),
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w300,
                letterSpacing: .2,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
