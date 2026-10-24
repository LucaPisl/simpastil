import 'dart:convert';

import '../db/database.dart';
import '../medication/schedule_window.dart';
import '../models/dose_status.dart';

/// Floors [d] to local midnight.
///
/// Used everywhere a "calendar day" is compared so time-of-day and DST
/// offsets never leak into day equality checks.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Key joining a dose log to its synthetic slot.
///
/// Joining only works when the log's [DoseLog.scheduledAt] is the same local
/// instant the engine reconstructs: both sides must be local DateTimes that
/// round-trip storage unchanged.
String slotKey(String scheduleId, DateTime scheduledAt) =>
    '$scheduleId|${scheduledAt.toIso8601String()}';

/// One expected dose occurrence of a schedule on a specific day.
typedef ExpectedSlot = ({Schedule schedule, DateTime scheduledAt});

/// A slot whose identity and intended local date come from the occurrence
/// ledger, never from reconstructing a wall time in the process timezone.
typedef MaterializedSlot = ({
  Schedule schedule,
  MedicationOccurrence occurrence,
});

List<MaterializedSlot> materializedSlotsFor({
  required List<Schedule> schedules,
  required Iterable<MedicationOccurrence> occurrences,
  required DateTime localDay,
}) {
  final date = dateOnly(localDay);
  final key =
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  final scheduleById = {
    for (final schedule in schedules) schedule.id: schedule,
  };
  final slots = <MaterializedSlot>[];
  for (final occurrence in occurrences) {
    if (occurrence.source != 'scheduled' ||
        !occurrence.expected ||
        occurrence.supersededAt != null ||
        occurrence.plannedAt == null ||
        occurrence.plannedLocalDate != key) {
      continue;
    }
    final scheduleId = occurrence.scheduleId;
    final schedule = scheduleId == null ? null : scheduleById[scheduleId];
    if (schedule == null || schedule.isDeleted) continue;
    slots.add((schedule: schedule, occurrence: occurrence));
  }
  slots.sort(
    (a, b) => a.occurrence.plannedAt!.compareTo(b.occurrence.plannedAt!),
  );
  return slots;
}

/// Whether [schedule] produces a dose on [day]: its weekday for weekly and
/// custom schedules, its every-N-days rule for an interval, and its optional
/// start/end date window for any of them.
///
/// Daily schedules always do; weekly/custom schedules match their
/// JSON-encoded ISO weekday list (1 = Mon … 7 = Sun). Malformed or missing
/// lists are treated as never active.
bool isScheduleActiveOn(Schedule schedule, DateTime day) {
  final window = schedule.window;
  if (schedule.frequency == 'interval' || window.isSet) {
    // An interval, or a dated window on any other frequency. A malformed
    // combination is treated as never active, like a malformed weekday list.
    if (!window.isValidFor(schedule.frequency) ||
        !scheduleWindowIncludes(
          schedule.frequency,
          window,
          DateTime.utc(day.year, day.month, day.day),
        )) {
      return false;
    }
    if (schedule.frequency == 'interval') return true;
  }
  if (schedule.frequency == 'daily') return true;
  final days = schedule.frequencyDays;
  if (days == null) return false;
  try {
    final weekdays = (jsonDecode(days) as List).cast<int>();
    return weekdays.contains(day.weekday);
  } catch (_) {
    return false;
  }
}

/// The dose slots that [schedules] are expected to produce on [day].
///
/// Skips inactive/deleted schedules, schedules whose weekday doesn't match,
/// and — at day granularity — schedules created after [day], so no phantom
/// doses appear for pills the user didn't have yet.
///
/// When [existingLogs] is provided and [day] is in the past, any log whose
/// `scheduledAt` doesn't match a schedule-derived slot (e.g. because the
/// schedule's time was later edited) still produces a slot — so historical
/// dose records are never orphaned by a schedule change.
List<ExpectedSlot> expectedSlotsFor(
  List<Schedule> schedules,
  DateTime day, {
  List<DoseLog>? existingLogs,
}) {
  final dayStart = dateOnly(day);
  final scheduleById = {for (final s in schedules) s.id: s};
  final slots = <ExpectedSlot>[];
  final usedKeys = <String>{};

  for (final schedule in schedules) {
    if (!schedule.isActive || schedule.isDeleted) continue;
    if (schedule.frequency == 'prn') continue;
    if (!isScheduleActiveOn(schedule, dayStart)) continue;
    if (dateOnly(schedule.createdAt).isAfter(dayStart)) continue;

    final at = DateTime(
      dayStart.year,
      dayStart.month,
      dayStart.day,
      schedule.hour,
      schedule.minute,
    );
    slots.add((schedule: schedule, scheduledAt: at));
    usedKeys.add(slotKey(schedule.id, at));
  }

  if (existingLogs != null) {
    for (final log in existingLogs) {
      if (log.isDeleted) continue;
      final key = slotKey(log.scheduleId, log.scheduledAt);
      if (usedKeys.contains(key)) continue;
      final schedule = scheduleById[log.scheduleId];
      if (schedule == null) continue;
      if (schedule.frequency == 'prn') continue;
      slots.add((schedule: schedule, scheduledAt: log.scheduledAt));
      usedKeys.add(key);
    }
  }

  return slots;
}

/// Display status for one slot: the log's status when one exists, otherwise
/// pending. A dose becomes missed only when a `miss` was recorded for it (see
/// the auto-miss sweeper); nothing here infers it from the clock.
DoseStatus computeDoseStatus(DoseLog? log) {
  if (log != null) {
    return switch (log.status) {
      'taken' => DoseStatus.taken,
      'skipped' => DoseStatus.skipped,
      'missed' => DoseStatus.missed,
      _ => DoseStatus.pending,
    };
  }
  return DoseStatus.pending;
}
