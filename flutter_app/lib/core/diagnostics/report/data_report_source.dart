import '../../db/database.dart';
import 'diagnostic_report.dart';
import 'platform_report_sources.dart';

/// Counts what is stored, to be shown only as rough sizes. Names, doses and
/// times are never selected: every query returns a single number.
///
/// [reminders] says how many reminders Android is holding; it is a parameter
/// so tests do not need the notification plugin.
Future<ReportData?> readDataFacts(
  AppDatabase database, {
  Future<int?> Function() reminders = readScheduledReminderCount,
}) async {
  Future<int?> count(String table, {bool live = true}) async {
    try {
      final rows = await database
          .customSelect(
            'SELECT COUNT(*) AS c FROM $table'
            '${live ? ' WHERE is_deleted = 0' : ''}',
          )
          .get();
      return rows.single.read<int>('c');
    } on Object {
      return null;
    }
  }

  final profiles = await count('profiles');
  final medicines = await count('pills');
  // A database that cannot even count its profiles and medicines cannot be
  // read at all; saying "unavailable" is more useful than a row of zeros.
  if (profiles == null && medicines == null) return null;

  // Doses live in two places: the older local log and the append-only
  // occurrence events. Together they say whether any history exists.
  final logged = await count('dose_logs');
  final events = await count('occurrence_events', live: false);
  return ReportData(
    profiles: profiles,
    medicines: medicines,
    schedules: await count('schedules'),
    doseRecords: logged == null && events == null
        ? null
        : (logged ?? 0) + (events ?? 0),
    scheduledReminders: await reminders(),
  );
}
