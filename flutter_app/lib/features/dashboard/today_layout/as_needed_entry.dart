import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/db/database.dart' show OccurrenceEvent;
import '../../../core/medication/care_day.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/pressable.dart';
import 'entry_identity.dart';
import 'today_layout.dart';

/// Whether [entry] is an as-needed row (an as-needed medicine's occurrence),
/// recorded or not. A pending one is the hidden record sentinel: it is never
/// a dose that is due, and no layout may offer it as an action.
bool isAsNeededEntry(CareDayEntry entry) => entry.occurrence.source == 'prn';

/// One recorded as-needed dose with the time it was actually taken.
///
/// The time lives on the head event (`actualAt`, valid only with
/// `actualTimeKnown`), in the zone the occurrence was saved in, exactly as
/// [recordedTimeLabel] reads it. A dose is "unknown time" only when the event
/// says so, never because the row has no planned time.
@immutable
class AsNeededRecord {
  const AsNeededRecord({required this.entry, required this.local});

  final CareDayEntry entry;

  /// When the dose was taken, on the saved zone's clock, or null when the
  /// actual time is genuinely unknown.
  final tz.TZDateTime? local;

  bool get timeKnown => local != null;

  /// Minutes since local midnight, or null when the time is unknown.
  int? get minuteOfDay =>
      local == null ? null : local!.hour * 60 + local!.minute;

  /// The instant, for ordering against scheduled doses.
  DateTime? get at => local?.toUtc();

  /// "12:05" on the phone's clock style, or "Actual time unknown".
  String timeLabel(BuildContext context) => local == null
      ? AppLocalizations.of(context).t08_unknownTime
      : clockAt(context, local!);
}

AsNeededRecord? _recordOf(TodayLayoutData data, CareDayEntry entry) {
  if (!isAsNeededEntry(entry)) return null;
  final row = data.rowOf(entry);
  if (row.state != 'taken') return null;
  final OccurrenceEvent? head = data.headOf(entry);
  tz.TZDateTime? local;
  if (head != null &&
      head.action != 'undo' &&
      head.actualTimeKnown &&
      head.actualAt != null) {
    local = tz.TZDateTime.from(head.actualAt!, tz.getLocation(row.timeZone));
  }
  return AsNeededRecord(entry: entry, local: local);
}

extension AsNeededLayoutData on TodayLayoutData {
  /// The day's scheduled doses: every entry except as-needed rows.
  List<CareDayEntry> get scheduledEntries => [
    for (final e in entries)
      if (!isAsNeededEntry(e)) e,
  ];

  /// Recorded as-needed doses from [asNeeded] and from the day's own entries,
  /// earliest first; doses of unknown time come last in their given order.
  /// Pending as-needed rows are not here, so they can never be shown as
  /// something to do.
  List<AsNeededRecord> get asNeededRecords {
    final seen = <String>{};
    final records = <AsNeededRecord>[];
    for (final e in [...entries, ...asNeeded]) {
      if (!seen.add(e.occurrence.id)) continue;
      final record = _recordOf(this, e);
      if (record != null) records.add(record);
    }
    final order = {for (final (i, r) in records.indexed) r: i};
    records.sort((a, b) {
      final x = a.minuteOfDay, y = b.minuteOfDay;
      if (x == null || y == null) {
        return x == null && y == null
            ? order[a]!.compareTo(order[b]!)
            : (x == null ? 1 : -1);
      }
      final c = x.compareTo(y);
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });
    return records;
  }
}

/// The small "As needed" tag every layout puts beside a recorded as-needed
/// dose, so the word carries the difference and colour never has to.
class AsNeededTag extends StatelessWidget {
  const AsNeededTag({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          AppLocalizations.of(context).t08_asNeeded,
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.onTertiaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// A calm, read-only row for a recorded as-needed dose: medication mark,
/// name, the "As needed" tag, who it was for and the time it was taken. Tapping
/// opens the dose details; recording and undoing live on the ring cards.
class AsNeededRecordTile extends StatelessWidget {
  const AsNeededRecordTile({
    super.key,
    required this.data,
    required this.record,
    this.showPerson = true,
  });

  final TodayLayoutData data;
  final AsNeededRecord record;
  final bool showPerson;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme, text = theme.textTheme;
    final entry = record.entry;
    final time = record.timeLabel(context);
    final person = l.t08_forPerson(entry.person.name);
    return Semantics(
      button: true,
      excludeSemantics: true,
      onTap: data.busy ? null : () => data.onOpenDetails(entry),
      label:
          '${entry.snapshot.pillName}, ${l.t08_asNeeded}, '
          '${showPerson ? '$person, ' : ''}$time',
      child: Pressable(
        radius: BorderRadius.circular(16),
        child: Material(
          color: colors.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .6),
            ),
          ),
          child: InkWell(
            key: ValueKey('as-needed-record-${entry.occurrence.id}'),
            borderRadius: BorderRadius.circular(16),
            onTap: data.busy ? null : () => data.onOpenDetails(entry),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  EntryMedicationMark(entry: entry, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              entry.snapshot.pillName,
                              style: text.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const AsNeededTag(),
                          ],
                        ),
                        if (showPerson)
                          Text(
                            person,
                            style: text.labelLarge?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 104),
                    child: Text(
                      time,
                      key: ValueKey('as-needed-time-${entry.occurrence.id}'),
                      textAlign: TextAlign.end,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
