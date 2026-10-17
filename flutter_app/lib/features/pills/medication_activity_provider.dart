import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/medication/medication_activity.dart';
import '../../core/medication/occurrence_history.dart';
import '../../core/medication/routine_definition.dart';
import '../../core/utils/app_clock.dart';
import '../../core/workspace/workspace_provider.dart';

/// How far back a medication's recent list looks. The day marks use the
/// last 14 of these.
const medicationActivityLookbackDays = 30;

/// A medication's last days and latest doses, read from the dose ledger
/// (occurrences and their events) and refreshed when it changes. Read-only:
/// it never writes.
final medicationActivityProvider = StreamProvider.autoDispose
    .family<MedicationActivity, String>((ref, pillId) async* {
      final db = ref.watch(databaseProvider);
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await contextFuture;
      // The windows are anchored to today, so the read starts over at midnight.
      final clock = ref.watch(appClockProvider);
      final todayKey = ref.watch(todayProvider);
      final todayDate = parseRoutineDate(todayKey);
      final today = DateTime(todayDate.year, todayDate.month, todayDate.day);
      final from = routineDateKey(
        DateTime(
          today.year,
          today.month,
          today.day - (medicationActivityLookbackDays - 1),
        ),
      );
      final through = routineDateKey(today);
      yield* db.medicationLedgerDao
          .watchForUserLocalDateRange(context.ownerUserId, from, through)
          .asyncMap(
            (_) => access.withGrant(context, () async {
              final records = await db.medicationLedgerDao
                  .getForUserLocalDateRange(context.ownerUserId, from, through);
              final at = clock();
              final summary = calculateOccurrenceAdherence(
                records: records.where((r) => r.occurrence.pillId == pillId),
                now: at,
              );
              return medicationActivityFrom(
                items: summary.history,
                pillId: pillId,
                now: at,
              );
            }),
          );
    });
