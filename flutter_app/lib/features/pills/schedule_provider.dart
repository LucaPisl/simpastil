import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Variable;

import '../../core/api/api_client.dart';
import '../../core/db/database.dart';
import '../../core/projections/projection_reconciler.dart';
import '../../core/projections/projection_identity.dart';
import '../../core/sync/ledger_mode_hint.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../core/workspace/workspace_context.dart';
import 'schedule_repository.dart';

// ── scheduleListForPillProvider ───────────────────────────────────────────────

/// Live stream of non-deleted schedules for a given pill, ordered by time.
///
/// Used in the expanded pill card to show real-time schedule updates.
final scheduleListForPillProvider = StreamProvider.family<List<Schedule>, String>((
  ref,
  pillId,
) async* {
  final db = ref.watch(databaseProvider);
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  yield* db
      .customSelect(
        'SELECT s.id FROM schedules s JOIN pills p ON p.id=s.pill_id JOIN profiles r ON r.id=p.profile_id WHERE p.id=?',
        variables: [Variable<String>(pillId)],
        readsFrom: {db.schedules, db.pills, db.profiles},
      )
      .watch()
      .asyncMap(
        (_) => access.withGrant(context, () async {
          final pill = await db.pillsDao.getById(pillId);
          if (pill == null || pill.isDeleted) {
            throw const WorkspaceAccessFailure(
              WorkspaceAccessFailureCode.wrongPerson,
            );
          }
          await access.requireCurrent(context, profileId: pill.profileId);
          return db.schedulesDao.getByPillId(pillId);
        }),
      );
});

// ── scheduleWindowsSupportedProvider ──────────────────────────────────────────

/// Whether the connected server last advertised schedule windows
/// (`capabilities.scheduleWindows`). The schedule editor offers "Every few
/// days" and start/end dates only when this is true.
final scheduleWindowsSupportedProvider = FutureProvider<bool>(
  (ref) => LedgerModeHint.readScheduleWindows(),
);

// ── scheduleRepositoryProvider ────────────────────────────────────────────────

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final context = ref.watch(workspaceContextProvider).requireValue;
  final identity = ProjectionIdentity.fromContext(context);
  final reconciler = ref.read(projectionReconcilerProvider);
  return ScheduleRepositoryImpl(
    schedulesDao: db.schedulesDao,
    pillsDao: db.pillsDao,
    profilesDao: db.profilesDao,
    ledgerDao: db.medicationLedgerDao,
    migrationIssuesDao: db.migrationIssuesDao,
    pendingOperations: ref.watch(pendingOperationRepositoryProvider),
    dio: ref.watch(apiClientProvider).dio,
    reconcileProjections: () async {
      await reconciler.reconcile(projectionIdentity: identity);
    },
  );
});
