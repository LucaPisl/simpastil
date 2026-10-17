import '../../core/db/database.dart';
import '../../core/doses/slot_engine.dart';
import '../../core/medication/adherence_calculator.dart';
import '../../core/medication/occurrence_history.dart';
import '../../core/medication/routine_definition.dart' show routineDateKey;
import '../../core/db/daos/medication_ledger_dao.dart';
import '../pills/pill_provider.dart' show PillWithSchedules;

// ── Types ─────────────────────────────────────────────────────────────────────

/// One day's scheduled adherence counts. Skipped and missed doses remain in
/// the due denominator and are also reported as their own outcome. `missed`
/// counts only doses with a recorded miss; a due dose nobody recorded is in
/// `expected` alone.
typedef DayAdherence = ({int taken, int skipped, int missed, int expected});

/// One Monday-started week's adherence counts.
typedef WeekAdherence = ({
  DateTime weekStart,
  int taken,
  int skipped,
  int missed,
  int expected,
});

/// One pill's adherence counts over the 30-day window.
typedef PillAdherence = ({
  String pillId,
  String pillName,
  String? color,
  int taken,
  int skipped,
  int missed,
  int expected,
});

/// Scheduled adherence windows and a separate 30-day PRN usage count.
typedef AdherenceStats = ({
  double? last7Days,
  double? last30Days,
  int prnTaken,
  List<WeekAdherence> weeklyTrend, // 12 entries, oldest first
  List<PillAdherence> perPill, // 30-day window, worst-first
});

/// Taken ÷ all due scheduled occurrences; null when none are due.
double? adherenceRatio(int taken, int skipped, int expected) {
  if (expected <= 0) return null;
  return taken / expected;
}

extension DayAdherenceX on DayAdherence {
  double? get ratio => adherenceRatio(taken, skipped, expected);
}

extension WeekAdherenceX on WeekAdherence {
  double? get ratio => adherenceRatio(taken, skipped, expected);
}

extension PillAdherenceX on PillAdherence {
  double? get ratio => adherenceRatio(taken, skipped, expected);
}

// ── Per-day aggregation ───────────────────────────────────────────────────────

/// Compatibility projection for pre-ledger local data. New history uses the
/// immutable occurrence rows below; reconstructed rows are explicitly marked
/// `legacy_estimated` so mutable schedules cannot masquerade as exact history.
DayAdherence dayAdherenceFor({
  required List<Schedule> schedules,
  required List<DoseLog> logs,
  required DateTime day,
  required DateTime now,
}) {
  final logByKey = {
    for (final l in logs) slotKey(l.scheduleId, l.scheduledAt): l,
  };
  final projected = <AdherenceOccurrence>[];
  for (final slot in expectedSlotsFor(schedules, day, existingLogs: logs)) {
    final log = logByKey[slotKey(slot.schedule.id, slot.scheduledAt)];
    projected.add(
      AdherenceOccurrence(
        id: slotKey(slot.schedule.id, slot.scheduledAt),
        source: 'scheduled',
        expected: true,
        plannedAt: slot.scheduledAt,
        plannedLocalDate: routineDateKey(dateOnly(day)),
        state: log?.status ?? 'pending',
        provenance: 'legacy_estimated',
        pillId: slot.schedule.pillId,
      ),
    );
  }
  return _dayCounts(
    const AdherenceCalculator().calculate(
      now: now,
      occurrences: projected,
      events: const [],
    ),
  );
}

/// Canonical calendar-day counts from synced occurrence rows.
DayAdherence dayAdherenceFromOccurrences({
  required List<MedicationOccurrenceRecord> records,
  required DateTime day,
  required DateTime now,
}) {
  final key = routineDateKey(dateOnly(day));
  final summary = calculateOccurrenceAdherence(
    records: records.where(
      (record) => record.occurrence.plannedLocalDate == key,
    ),
    now: now,
  );
  return _dayCounts(summary);
}

DayAdherence _dayCounts(AdherenceSummary summary) => (
  taken: summary.takenScheduled,
  skipped: summary.skippedScheduled,
  missed: summary.missedScheduled,
  expected: summary.dueScheduled,
);

/// Adherence for every day of [month] (only its year and month are read),
/// keyed by date-floored day.
Map<DateTime, DayAdherence> monthAdherence({
  required List<Schedule> schedules,
  required List<DoseLog> logs,
  required DateTime month,
  required DateTime now,
  List<PillWithSchedules> pillsWithSchedules = const [],
  bool prnInStats = false,
}) {
  final logsByDay = <DateTime, List<DoseLog>>{};
  for (final l in logs) {
    (logsByDay[dateOnly(l.scheduledAt)] ??= []).add(l);
  }

  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  return {
    for (var d = 1; d <= daysInMonth; d++)
      DateTime(month.year, month.month, d): dayAdherenceFor(
        schedules: schedules,
        logs: logsByDay[DateTime(month.year, month.month, d)] ?? const [],
        day: DateTime(month.year, month.month, d),
        now: now,
      ),
  };
}

Map<DateTime, DayAdherence> monthAdherenceFromOccurrences({
  required List<MedicationOccurrenceRecord> records,
  required DateTime month,
  required DateTime now,
}) {
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  return {
    for (var day = 1; day <= daysInMonth; day++)
      DateTime(month.year, month.month, day): dayAdherenceFromOccurrences(
        records: records,
        day: DateTime(month.year, month.month, day),
        now: now,
      ),
  };
}

// ── Window statistics ─────────────────────────────────────────────────────────

class _PillAccumulator {
  _PillAccumulator(this.pillName, this.color);
  final String pillName;
  final String? color;
  int taken = 0, skipped = 0, missed = 0, expected = 0;
}

/// Compatibility statistics for local rows predating the occurrence ledger.
/// The calculation is delegated to the same reducer as synced occurrences.
AdherenceStats computeAdherenceStats({
  required List<PillWithSchedules> pillsWithSchedules,
  required List<DoseLog> logs,
  required DateTime now,
  bool prnInStats = false,
}) {
  final today = dateOnly(now);
  final weekStart = DateTime(
    today.year,
    today.month,
    today.day - (today.weekday - 1),
  );
  final firstWeekStart = DateTime(
    weekStart.year,
    weekStart.month,
    weekStart.day - 77,
  );
  final logsByDay = <DateTime, List<DoseLog>>{};
  final logByKey = <String, DoseLog>{};
  for (final log in logs) {
    final day = dateOnly(log.scheduledAt);
    (logsByDay[day] ??= []).add(log);
    logByKey[slotKey(log.scheduleId, log.scheduledAt)] = log;
  }

  final projected = <AdherenceOccurrence>[];
  for (
    var day = firstWeekStart;
    !day.isAfter(today);
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    for (final pws in pillsWithSchedules) {
      if (pws.pill.isPrn) {
        final sentinels = pws.schedules
            .where((schedule) => schedule.frequency == 'prn')
            .toList(growable: false);
        if (sentinels.isEmpty) continue;
        for (final log in logsByDay[day] ?? const <DoseLog>[]) {
          if (log.scheduleId != sentinels.first.id || log.status != 'taken') {
            continue;
          }
          projected.add(
            AdherenceOccurrence(
              id: log.id,
              source: 'prn',
              expected: false,
              plannedAt: null,
              plannedLocalDate: routineDateKey(day),
              state: 'taken',
              provenance: 'legacy_estimated',
              pillId: pws.pill.id,
              pillName: pws.pill.name,
              dosage: pws.pill.dosage,
            ),
          );
        }
        continue;
      }
      for (final slot in expectedSlotsFor(
        pws.schedules,
        day,
        existingLogs: logsByDay[day],
      )) {
        final log = logByKey[slotKey(slot.schedule.id, slot.scheduledAt)];
        projected.add(
          AdherenceOccurrence(
            id: slotKey(slot.schedule.id, slot.scheduledAt),
            source: 'scheduled',
            expected: true,
            plannedAt: slot.scheduledAt,
            plannedLocalDate: routineDateKey(day),
            state: log?.status ?? 'pending',
            provenance: 'legacy_estimated',
            pillId: pws.pill.id,
            pillName: pws.pill.name,
            dosage: pws.pill.dosage,
          ),
        );
      }
    }
  }
  final summary = const AdherenceCalculator().calculate(
    now: now,
    occurrences: projected,
    events: const [],
  );
  return _statsFromSummary(
    summary,
    now,
    pillColors: {
      for (final entry in pillsWithSchedules) entry.pill.id: entry.pill.color,
    },
  );
}

/// Canonical dashboard/calendar/statistics aggregation over immutable synced
/// occurrence rows. PRN counts are kept out of scheduled denominators.
AdherenceStats computeAdherenceStatsFromOccurrences({
  required List<MedicationOccurrenceRecord> records,
  required DateTime now,
}) => _statsFromSummary(
  calculateOccurrenceAdherence(records: records, now: now),
  now,
);

AdherenceStats _statsFromSummary(
  AdherenceSummary summary,
  DateTime now, {
  Map<String, String?> pillColors = const {},
}) {
  final today = dateOnly(now);
  final thisWeekStart = DateTime(
    today.year,
    today.month,
    today.day - (today.weekday - 1),
  );
  final firstWeekStart = DateTime(
    thisWeekStart.year,
    thisWeekStart.month,
    thisWeekStart.day - 7 * 11,
  );
  final sevenDayStart = DateTime(today.year, today.month, today.day - 6);
  final thirtyDayStart = DateTime(today.year, today.month, today.day - 29);
  var taken7 = 0, skipped7 = 0, expected7 = 0;
  var taken30 = 0, skipped30 = 0, expected30 = 0;
  final weekTaken = List.filled(12, 0);
  final weekSkipped = List.filled(12, 0);
  final weekMissed = List.filled(12, 0);
  final weekExpected = List.filled(12, 0);
  final pillAccumulators = <String, _PillAccumulator>{};
  var prnTaken30 = 0;
  final weekIndexByDate = <String, int>{};
  var dayCounter = 0;
  for (
    var day = firstWeekStart;
    !day.isAfter(today);
    day = DateTime(day.year, day.month, day.day + 1), dayCounter++
  ) {
    weekIndexByDate[routineDateKey(day)] = dayCounter ~/ 7;
  }

  for (final item in summary.history) {
    if (item.source == 'prn' &&
        item.status == 'taken' &&
        item.plannedLocalDate != null &&
        !_parseDateKey(item.plannedLocalDate!).isBefore(thirtyDayStart)) {
      prnTaken30++;
    }
    if (!item.isDueScheduled || item.plannedLocalDate == null) continue;
    final localDate = _parseDateKey(item.plannedLocalDate!);
    final weekIndex = weekIndexByDate[routineDateKey(localDate)];
    if (weekIndex == null) continue;
    final isTaken = item.status == 'taken';
    final isSkipped = item.status == 'skipped';
    final isMissed = item.status == 'missed';
    weekExpected[weekIndex]++;
    if (isTaken) weekTaken[weekIndex]++;
    if (isSkipped) weekSkipped[weekIndex]++;
    if (isMissed) weekMissed[weekIndex]++;

    if (!localDate.isBefore(sevenDayStart)) {
      expected7++;
      if (isTaken) taken7++;
      if (isSkipped) skipped7++;
    }
    if (!localDate.isBefore(thirtyDayStart)) {
      expected30++;
      if (isTaken) taken30++;
      if (isSkipped) skipped30++;
      final id = item.pillId ?? 'unknown:${item.pillName ?? ''}';
      final acc = pillAccumulators.putIfAbsent(
        id,
        () => _PillAccumulator(item.pillName ?? 'Unknown', pillColors[id]),
      );
      acc.expected++;
      if (isTaken) acc.taken++;
      if (isSkipped) acc.skipped++;
      if (isMissed) acc.missed++;
    }
  }

  final weeklyTrend = [
    for (var i = 0; i < 12; i++)
      (
        weekStart: DateTime(
          firstWeekStart.year,
          firstWeekStart.month,
          firstWeekStart.day + 7 * i,
        ),
        taken: weekTaken[i],
        skipped: weekSkipped[i],
        missed: weekMissed[i],
        expected: weekExpected[i],
      ),
  ];

  final perPill =
      <PillAdherence>[
        for (final entry in pillAccumulators.entries)
          if (adherenceRatio(
                entry.value.taken,
                entry.value.skipped,
                entry.value.expected,
              ) !=
              null)
            (
              pillId: entry.key,
              pillName: entry.value.pillName,
              color: entry.value.color,
              taken: entry.value.taken,
              skipped: entry.value.skipped,
              missed: entry.value.missed,
              expected: entry.value.expected,
            ),
      ]..sort((a, b) {
        final byRatio = a.ratio!.compareTo(b.ratio!);
        return byRatio != 0 ? byRatio : a.pillName.compareTo(b.pillName);
      });

  return (
    last7Days: adherenceRatio(taken7, skipped7, expected7),
    last30Days: adherenceRatio(taken30, skipped30, expected30),
    prnTaken: prnTaken30,
    weeklyTrend: weeklyTrend,
    perPill: perPill,
  );
}

DateTime _parseDateKey(String value) {
  final parts = value.split('-').map(int.parse).toList(growable: false);
  return DateTime(parts[0], parts[1], parts[2]);
}
