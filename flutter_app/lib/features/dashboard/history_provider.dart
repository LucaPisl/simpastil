import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/db/database.dart';
import '../../core/medication/current_name_display.dart';
import '../../core/workspace/workspace_provider.dart';
import 'models/history_entry.dart';
import 'history_entry_mapper.dart';

/// Holds the number of days of history to load. Increment by 30 to load more.
final historyWindowDaysProvider = StateProvider<int>((ref) => 30);

/// Streams dose log entries with pill, dosage, and profile context for the
/// current history window, newest-first.
/// Re-subscribes automatically whenever [historyWindowDaysProvider] changes.
final historyLogsProvider = StreamProvider<List<HistoryEntry>>((ref) async* {
  final days = ref.watch(historyWindowDaysProvider);
  final db = ref.watch(databaseProvider);
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final from = DateTime(today.year, today.month, today.day - (days - 1));

  final context = await contextFuture;
  yield* db.medicationLedgerDao
      .watchForUserLocalDateRange(
        context.ownerUserId,
        _historyDateKey(from),
        _historyDateKey(today),
      )
      .asyncMap(
        (_) => access.withGrant(context, () async {
          final records = await db.medicationLedgerDao.getForUserLocalDateRange(
            context.ownerUserId,
            _historyDateKey(from),
            _historyDateKey(today),
          );
          final details = await (db.select(
            db.careEventDetails,
          )..where((d) => d.workspaceId.equals(context.workspaceId))).get();
          final detailsByEvent = {
            for (final detail in details) detail.eventId: detail,
          };
          final pillNames = <String, String>{};
          for (final record in records) {
            final pillId = record.occurrence.pillId;
            if (pillId == null ||
                !showsCurrentName(record.occurrence.state) ||
                pillNames.containsKey(pillId)) {
              continue;
            }
            final pill = await db.pillsDao.getById(pillId);
            if (pill != null && !pill.isDeleted) pillNames[pillId] = pill.name;
          }
          final entries =
              records
                  .map(
                    (record) => historyEntryFromOccurrenceRecord(
                      record,
                      now: DateTime.now(),
                      detailsByEvent: detailsByEvent,
                      pillNamesById: pillNames,
                    ),
                  )
                  .where(shouldListInHistory)
                  .toList()
                ..sort((a, b) {
                  final aAt = a.recordedAt ?? a.takenAt ?? a.scheduledAt;
                  final bAt = b.recordedAt ?? b.takenAt ?? b.scheduledAt;
                  if (aAt == null) return bAt == null ? 0 : 1;
                  if (bAt == null) return -1;
                  return bAt.compareTo(aAt);
                });
          return entries;
        }),
      );
});

/// Whether [entry] belongs in the History lists.
///
/// An as-needed occurrence is only a dose once it has been taken: one that is
/// back to pending (undone, or never recorded) was never due, so it is not
/// listed. Its events stay in the ledger and in the dose's correction trail.
bool shouldListInHistory(HistoryEntry entry) {
  if (entry.source == 'prn' && entry.occurrenceState == 'pending') {
    return false;
  }
  return entry.status != 'pending' || entry.auditEvents.isNotEmpty;
}

String _historyDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
