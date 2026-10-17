import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/schedules_table.dart';

part 'schedules_dao.g.dart';

@DriftAccessor(tables: [Schedules])
class SchedulesDao extends DatabaseAccessor<AppDatabase>
    with _$SchedulesDaoMixin {
  SchedulesDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  Future<Schedule?> getById(String id) =>
      (select(schedules)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Schedule?> getByServerId(String serverId) => (select(
    schedules,
  )..where((t) => t.serverId.equals(serverId))).getSingleOrNull();

  /// Stable v2 creates may use the local UUID as the server UUID before the
  /// first receipt is mapped. Callers must still preserve any pending row.
  Future<Schedule?> getByMappedOrLocalId(String serverId) async =>
      await getByServerId(serverId) ?? await getById(serverId);

  Future<List<Schedule>> getByPillId(String pillId) =>
      (select(schedules)
            ..where((t) => t.pillId.equals(pillId) & t.isDeleted.equals(false))
            ..orderBy([
              (t) => OrderingTerm.asc(t.hour),
              (t) => OrderingTerm.asc(t.minute),
            ]))
          .get();

  Stream<List<Schedule>> watchByPillId(String pillId) =>
      (select(schedules)
            ..where((t) => t.pillId.equals(pillId) & t.isDeleted.equals(false))
            ..orderBy([
              (t) => OrderingTerm.asc(t.hour),
              (t) => OrderingTerm.asc(t.minute),
            ]))
          .watch();

  Future<List<Schedule>> getActiveSchedules() => (select(
    schedules,
  )..where((t) => t.isActive.equals(true) & t.isDeleted.equals(false))).get();

  // ── Mutations ─────────────────────────────────────────────────────────────

  Future<void> upsert(SchedulesCompanion schedule) =>
      into(schedules).insertOnConflictUpdate(schedule);

  Future<bool> update_(SchedulesCompanion schedule) =>
      update(schedules).replace(schedule);

  Future<int> softDelete(String id) =>
      (update(schedules)..where((t) => t.id.equals(id))).write(
        SchedulesCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('pending'),
          updatedAt: Value(DateTime.now()),
        ),
      );

  // ── Sync helpers ──────────────────────────────────────────────────────────

  Future<List<Schedule>> getPendingSync() =>
      (select(schedules)..where((t) => t.syncStatus.equals('pending'))).get();

  Future<void> markSynced(String id, String serverId, {int? revision}) =>
      (update(schedules)..where((t) => t.id.equals(id))).write(
        SchedulesCompanion(
          serverId: Value(serverId),
          revision: revision == null ? const Value.absent() : Value(revision),
          syncStatus: const Value('synced'),
          lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<int> purgeSyncedTombstones(DateTime before) =>
      (delete(schedules)..where(
            (t) =>
                t.isDeleted.equals(true) &
                t.syncStatus.equals('synced') &
                t.updatedAt.isSmallerOrEqualValue(before) &
                notExistsQuery(
                  select(db.doseLogs)
                    ..where((dose) => dose.scheduleId.equalsExp(t.id)),
                ) &
                notExistsQuery(
                  select(db.medicationOccurrences)..where(
                    (occurrence) => occurrence.scheduleId.equalsExp(t.id),
                  ),
                ),
          ))
          .go();
}
