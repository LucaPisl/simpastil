import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/sync_component_state_table.dart';
import '../tables/sync_staging_tables.dart';

part 'sync_state_dao.g.dart';

@DriftAccessor(tables: [SyncComponentStates, SyncStagingRuns, SyncStagingItems])
class SyncStateDao extends DatabaseAccessor<AppDatabase>
    with _$SyncStateDaoMixin {
  SyncStateDao(super.db);

  Future<SyncComponentState?> getState(String userId, String component) =>
      (select(syncComponentStates)..where(
            (row) =>
                row.userId.equals(userId) & row.component.equals(component),
          ))
          .getSingleOrNull();

  /// Forgets where each component's pull stopped, so the next pull replays
  /// the whole server history. Only checkpoints change: the outbox, local rows
  /// and the time of the last complete pull stay as they are, and merges still
  /// skip any row with unsent changes.
  Future<int> resetPullCheckpoints(String userId) => db.transaction(() async {
    final runs = await (select(
      syncStagingRuns,
    )..where((row) => row.userId.equals(userId))).map((r) => r.id).get();
    await _deleteStagedItemsForRuns(runs);
    if (runs.isNotEmpty) {
      await (delete(syncStagingRuns)..where((row) => row.id.isIn(runs))).go();
    }
    return (update(syncComponentStates)..where(
          (row) =>
              row.userId.equals(userId) & row.lastCompletedCursor.isNotNull(),
        ))
        .write(
          const SyncComponentStatesCompanion(lastCompletedCursor: Value(null)),
        );
  });

  Future<void> saveState(SyncComponentStatesCompanion state) =>
      into(syncComponentStates).insertOnConflictUpdate(state);

  Future<void> beginRun(SyncStagingRunsCompanion run) =>
      into(syncStagingRuns).insert(run);

  /// A process can stop between pages. The component checkpoint remains at
  /// the previous completed run, so any unfinished staging rows are safe to
  /// discard before retrying that traversal.
  Future<int> discardIncompleteRuns(String userId, String component) =>
      db.transaction(() async {
        final runIds =
            await (select(syncStagingRuns)..where(
                  (row) =>
                      row.userId.equals(userId) &
                      row.component.equals(component) &
                      row.finalPageReceived.equals(false),
                ))
                .map((row) => row.id)
                .get();
        if (runIds.isEmpty) return 0;

        await _deleteStagedItemsForRuns(runIds);
        return (delete(
          syncStagingRuns,
        )..where((row) => row.id.isIn(runIds))).go();
      });

  Future<void> stagePage({
    required String runId,
    required List<SyncStagingItemsCompanion> items,
    required String? nextCursor,
    required bool isFinalPage,
  }) async {
    await db.transaction(() async {
      final run = await (select(
        syncStagingRuns,
      )..where((row) => row.id.equals(runId))).getSingleOrNull();
      if (run == null || run.finalPageReceived) {
        throw StateError('Sync staging run is missing or already complete.');
      }
      if (items.isNotEmpty) {
        await batch((batch) => batch.insertAll(syncStagingItems, items));
      }
      await (update(
        syncStagingRuns,
      )..where((row) => row.id.equals(runId))).write(
        SyncStagingRunsCompanion(
          nextCursor: Value(nextCursor),
          pageCount: Value(run.pageCount + 1),
          finalPageReceived: Value(isFinalPage),
        ),
      );
    });
  }

  Future<List<SyncStagingItem>> getStagedItems(String runId) =>
      (select(syncStagingItems)
            ..where((row) => row.runId.equals(runId))
            ..orderBy([(row) => OrderingTerm.asc(row.serverSequence)]))
          .get();

  /// Merges and advances the cursor atomically, only after a final page exists.
  Future<void> commitRunAfterMerge({
    required String runId,
    required Future<void> Function(List<SyncStagingItem> items) merge,
    required DateTime completedAt,
    String? diagnosticMetadataJson,
  }) async {
    await db.transaction(() async {
      final run = await (select(
        syncStagingRuns,
      )..where((row) => row.id.equals(runId))).getSingleOrNull();
      if (run == null || !run.finalPageReceived) {
        throw StateError('Cannot commit an incomplete sync traversal.');
      }
      final items = await getStagedItems(runId);
      await merge(items);
      final previous = await getState(run.userId, run.component);
      await into(syncComponentStates).insertOnConflictUpdate(
        SyncComponentStatesCompanion.insert(
          userId: run.userId,
          component: run.component,
          contractVersion: run.contractVersion,
          lastCompletedCursor: Value(run.nextCursor),
          lastFullSuccessAt: Value(completedAt),
          currentState: const Value('idle'),
          diagnosticMetadataJson: Value(
            diagnosticMetadataJson ?? previous?.diagnosticMetadataJson,
          ),
        ),
      );
      await _deleteStagedItemsForRuns([runId]);
      await (delete(
        syncStagingRuns,
      )..where((row) => row.id.equals(runId))).go();
    });
  }

  Future<int> discardRun(String runId) => db.transaction(() async {
    final run = await (select(
      syncStagingRuns,
    )..where((row) => row.id.equals(runId))).getSingleOrNull();
    if (run == null) return 0;

    await _deleteStagedItemsForRuns([runId]);
    return (delete(syncStagingRuns)..where((row) => row.id.equals(runId))).go();
  });

  Future<void> _deleteStagedItemsForRuns(Iterable<String> runIds) async {
    if (runIds.isEmpty) return;
    await (delete(
      syncStagingItems,
    )..where((row) => row.runId.isIn(runIds))).go();
  }
}
