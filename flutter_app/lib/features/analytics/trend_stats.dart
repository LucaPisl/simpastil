import '../../core/db/daos/medication_ledger_dao.dart';
import '../../core/db/database.dart' show LocalRoutine;
import '../../core/medication/adherence_calculator.dart';
import '../../core/medication/occurrence_history.dart';
import '../../core/medication/routine_definition.dart' show routineDateKey;
import '../../core/medication/routine_repository.dart' show plannedRoutineSlots;
import 'adherence.dart';

// Read-only derivations for the History trends: the day streak, when doses
// are recorded through the day, as-needed use per medication, and a month's
// totals. They reduce the same occurrence rows the other statistics use and
// store nothing.

/// How many days the statistics read. Twelve Monday-started weeks need up to
/// 84 days; the streak, the best streak and every window below stay inside it.
const trendWindowDays = 84;

/// Consecutive days with every scheduled dose taken, ending today or the last
/// day a scheduled dose was due, and the longest such run in the window.
typedef DayStreak = ({int current, int best});

/// One medication's as-needed doses taken in a window.
typedef PrnPillCount = ({String pillId, String? pillName, int count});

/// What the trends add to [AdherenceStats].
typedef TrendStats = ({
  DayStreak streak,

  /// Whether any scheduled dose has fallen due in the window. Without one the
  /// streak has nothing to measure and is shown as no data, not as 0.
  bool hasScheduledDoses,

  /// Doses taken per local hour of the day, 24 entries, over the last 30 days.
  List<int> hourlyTaken,

  /// As-needed doses taken in the last 7 and 30 days.
  int prn7Days,
  int prn30Days,

  /// The 30-day as-needed doses per medication, most used first.
  List<PrnPillCount> prnByPill,
});

/// A month's scheduled doses and as-needed doses so far.
typedef MonthSummary = ({
  /// Due scheduled doses that were taken or skipped on purpose.
  int recorded,

  /// Due scheduled doses: everything planned up to now.
  int expected,
  int taken,
  int skipped,
  int prnTaken,
});

DateTime _dayOnly(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime _daysBefore(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day - days);

/// The local days before today, inside the window, on which a scheduled dose
/// of a local routine fell due but has no occurrence row at all.
///
/// A local routine's occurrences are written when a day is looked at or a
/// reminder is prepared, a few weeks ahead. After a long time without either
/// there is nothing in the ledger for those days, so the dose history cannot
/// say that a dose was left unrecorded; the routine can. [routines] are the
/// versions of every routine in view, oldest revision first within each, and
/// [records] the occurrence rows of the window, of which a row of any state
/// (even a superseded one) covers its slot. Read-only: nothing is written.
///
/// Today is not included: its doses are still outstanding, not unrecorded.
Set<String> unrecordedRoutineDays(
  Iterable<LocalRoutine> routines,
  Iterable<MedicationOccurrenceRecord> records, {
  required DateTime now,
  int windowDays = trendWindowDays,
}) {
  final today = _dayOnly(now);
  final from = routineDateKey(_daysBefore(today, windowDays - 1));
  final through = routineDateKey(_daysBefore(today, 1));
  if (from.compareTo(through) > 0) return const {};
  final covered = {
    for (final record in records)
      if (record.occurrence.scheduleId != null)
        '${record.occurrence.scheduleId}/${record.occurrence.plannedLocalDate}',
  };
  final byRoutine = <String, List<LocalRoutine>>{};
  for (final version in routines) {
    byRoutine.putIfAbsent(version.routineId, () => []).add(version);
  }
  final days = <String>{};
  for (final versions in byRoutine.values) {
    versions.sort((a, b) => a.revision.compareTo(b.revision));
    for (final slot in plannedRoutineSlots(versions, from, through)) {
      final due = !slot.entry.plannedAt.isAfter(now);
      if (due &&
          !covered.contains('${slot.scheduleId}/${slot.entry.localDate}')) {
        days.add(slot.entry.localDate);
      }
    }
  }
  return days;
}

/// The day streak over [history] (see [AdherenceSummary.history]).
///
/// Each local day of the window is one of:
///
/// * **complete**: at least one scheduled dose fell due and every one that
///   was not skipped on purpose was taken. Only complete days count toward a
///   streak.
/// * **neutral**: nothing was asked of the day: no scheduled dose fell due,
///   or every one that did was skipped on purpose. It neither counts nor
///   breaks the streak, so a medication taken every other day can keep one
///   going, and choosing to skip a dose does not cost one.
/// * **open**: today, with doses still outstanding. The day is not over, so
///   it neither counts nor breaks the streak.
/// * **broken**: any other day with a due dose not taken: left unrecorded
///   after the day ended, or, for a day in [unrecordedDays], a dose that
///   fell due with no record at all.
///
/// [DayStreak.current] is the run of complete days since the last broken day;
/// [DayStreak.best] is the longest run in the window. As-needed doses never
/// take part. Days before [today] minus [windowDays] are not read, so neither
/// number can exceed the window.
DayStreak computeDayStreak(
  Iterable<AdherenceHistoryItem> history, {
  required DateTime today,
  int windowDays = trendWindowDays,
  Set<String> unrecordedDays = const {},
}) {
  final todayOnly = _dayOnly(today);
  final start = _daysBefore(todayOnly, windowDays - 1);
  final due = <String, int>{};
  final taken = <String, int>{};
  final skipped = <String, int>{};
  for (final item in history) {
    final key = item.plannedLocalDate;
    if (!item.isDueScheduled || key == null) continue;
    due.update(key, (n) => n + 1, ifAbsent: () => 1);
    if (item.status == 'taken') {
      taken.update(key, (n) => n + 1, ifAbsent: () => 1);
    } else if (item.status == 'skipped') {
      skipped.update(key, (n) => n + 1, ifAbsent: () => 1);
    }
  }

  var run = 0, best = 0;
  for (
    var day = start;
    !day.isAfter(todayOnly);
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    final key = routineDateKey(day);
    // What the day asked: its due doses less the ones set aside on purpose,
    // and any that fell due with no record to show it.
    final asked = (due[key] ?? 0) - (skipped[key] ?? 0);
    final unrecorded = unrecordedDays.contains(key);
    if (asked == 0 && !unrecorded) continue;
    if (!unrecorded && (taken[key] ?? 0) == asked) {
      run++;
      if (run > best) best = run;
    } else if (day == todayOnly) {
      continue;
    } else {
      run = 0;
    }
  }
  return (current: run, best: best);
}

/// Doses taken per local hour of the day: 24 counts, hour 0 first.
///
/// Counts every taken, non-superseded dose, scheduled or as needed, whose
/// planned local date is in the last [days] days and whose actual time is
/// known (a dose recorded as "time not known" has no hour).
List<int> hourlyTakenHistogram(
  Iterable<AdherenceHistoryItem> history, {
  required DateTime today,
  int days = 30,
}) {
  final from = routineDateKey(_daysBefore(_dayOnly(today), days - 1));
  final hours = List.filled(24, 0);
  for (final item in history) {
    final key = item.plannedLocalDate;
    final at = item.actualAt;
    if (item.status != 'taken' ||
        item.superseded ||
        key == null ||
        at == null ||
        key.compareTo(from) < 0) {
      continue;
    }
    hours[at.toLocal().hour]++;
  }
  return hours;
}

/// As-needed doses taken in the last [days] days per medication, most used
/// first (ties by name).
List<PrnPillCount> prnTakenByPill(
  Iterable<AdherenceHistoryItem> history, {
  required DateTime today,
  int days = 30,
}) {
  final from = routineDateKey(_daysBefore(_dayOnly(today), days - 1));
  final counts = <String, int>{};
  final names = <String, String?>{};
  for (final item in history) {
    final key = item.plannedLocalDate;
    if (item.source != 'prn' ||
        item.status != 'taken' ||
        item.superseded ||
        key == null ||
        key.compareTo(from) < 0) {
      continue;
    }
    final id = item.pillId ?? 'unknown:${item.pillName ?? ''}';
    counts.update(id, (n) => n + 1, ifAbsent: () => 1);
    names[id] = item.pillName ?? names[id];
  }
  return [
    for (final entry in counts.entries)
      (pillId: entry.key, pillName: names[entry.key], count: entry.value),
  ]..sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0
        ? byCount
        : (a.pillName ?? '').compareTo(b.pillName ?? '');
  });
}

/// The trend statistics at [now] over synced occurrence rows. [records] should
/// cover the last [trendWindowDays] days.
///
/// [unrecordedDays] are the days a local routine owed a dose that has no row
/// (see [unrecordedRoutineDays]); they break the streak.
TrendStats computeTrendStatsFromOccurrences({
  required List<MedicationOccurrenceRecord> records,
  required DateTime now,
  Set<String> unrecordedDays = const {},
}) {
  final summary = calculateOccurrenceAdherence(records: records, now: now);
  final today = _dayOnly(now);
  final byPill = prnTakenByPill(summary.history, today: today);
  final from7 = routineDateKey(_daysBefore(today, 6));
  var prn7 = 0;
  for (final item in summary.history) {
    final key = item.plannedLocalDate;
    if (item.source == 'prn' &&
        item.status == 'taken' &&
        !item.superseded &&
        key != null &&
        key.compareTo(from7) >= 0) {
      prn7++;
    }
  }
  return (
    streak: computeDayStreak(
      summary.history,
      today: today,
      unrecordedDays: unrecordedDays,
    ),
    hasScheduledDoses:
        unrecordedDays.isNotEmpty ||
        summary.history.any((item) => item.isDueScheduled),
    hourlyTaken: hourlyTakenHistogram(summary.history, today: today),
    prn7Days: prn7,
    prn30Days: byPill.fold<int>(0, (sum, pill) => sum + pill.count),
    prnByPill: byPill,
  );
}

/// As-needed doses taken per day of [month] (only its year and month are
/// read), keyed by date-floored day. Days without one are absent.
Map<DateTime, int> monthPrnCountsFromOccurrences({
  required List<MedicationOccurrenceRecord> records,
  required DateTime month,
}) {
  final counts = <DateTime, int>{};
  for (final record in records) {
    final occurrence = record.occurrence;
    final key = occurrence.plannedLocalDate;
    if (occurrence.source != 'prn' ||
        occurrence.state != 'taken' ||
        occurrence.supersededAt != null) {
      continue;
    }
    final date = DateTime.tryParse(key);
    if (date == null || date.year != month.year || date.month != month.month) {
      continue;
    }
    counts.update(
      DateTime(date.year, date.month, date.day),
      (n) => n + 1,
      ifAbsent: () => 1,
    );
  }
  return counts;
}

/// Totals over a month's per-day scheduled counts and as-needed counts.
MonthSummary summarizeMonth(
  Map<DateTime, DayAdherence> days,
  Map<DateTime, int> prnByDay,
) {
  var taken = 0, skipped = 0, expected = 0;
  for (final day in days.values) {
    taken += day.taken;
    skipped += day.skipped;
    expected += day.expected;
  }
  return (
    recorded: taken + skipped,
    expected: expected,
    taken: taken,
    skipped: skipped,
    prnTaken: prnByDay.values.fold<int>(0, (sum, n) => sum + n),
  );
}
