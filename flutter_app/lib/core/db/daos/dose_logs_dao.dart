import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/dose_logs_table.dart';
import '../../../features/dashboard/models/history_entry.dart';

part 'dose_logs_dao.g.dart';

@DriftAccessor(tables: [DoseLogs])
class DoseLogsDao extends DatabaseAccessor<AppDatabase>
    with _$DoseLogsDaoMixin {
  DoseLogsDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  Future<DoseLog?> getById(String id) =>
      (select(doseLogs)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<DoseLog?> getByServerId(String serverId) => (select(
    doseLogs,
  )..where((t) => t.serverId.equals(serverId))).getSingleOrNull();

  Future<DoseLog?> getByScheduledSlot(
    String scheduleId,
    DateTime scheduledAt,
  ) =>
      (select(doseLogs)
            ..where(
              (t) =>
                  t.scheduleId.equals(scheduleId) &
                  t.scheduledAt.equals(scheduledAt) &
                  t.isDeleted.equals(false),
            )
            ..limit(1))
          .getSingleOrNull();

  Future<List<DoseLog>> getByScheduleId(String scheduleId) =>
      (select(doseLogs)
            ..where(
              (t) =>
                  t.scheduleId.equals(scheduleId) & t.isDeleted.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.scheduledAt)]))
          .get();

  Stream<List<DoseLog>> watchByScheduleId(String scheduleId) =>
      (select(doseLogs)
            ..where(
              (t) =>
                  t.scheduleId.equals(scheduleId) & t.isDeleted.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.scheduledAt)]))
          .watch();

  /// Returns dose logs for a given date range, ordered chronologically.
  Future<List<DoseLog>> getForDateRange(DateTime from, DateTime to) =>
      (select(doseLogs)
            ..where(
              (t) =>
                  t.scheduledAt.isBiggerOrEqualValue(from) &
                  t.scheduledAt.isSmallerOrEqualValue(to) &
                  t.isDeleted.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.scheduledAt)]))
          .get();

  Stream<List<DoseLog>> watchForDateRange(DateTime from, DateTime to) =>
      (select(doseLogs)
            ..where(
              (t) =>
                  t.scheduledAt.isBiggerOrEqualValue(from) &
                  t.scheduledAt.isSmallerOrEqualValue(to) &
                  t.isDeleted.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.scheduledAt)]))
          .watch();

  Stream<List<DoseLog>> watchForOwnerDateRange(
    String ownerId,
    DateTime from,
    DateTime to,
  ) => _ownerDateRangeQuery(ownerId, from, to).watch();

  Future<List<DoseLog>> getForOwnerDateRange(
    String ownerId,
    DateTime from,
    DateTime to,
  ) => _ownerDateRangeQuery(ownerId, from, to).get();

  Selectable<DoseLog> _ownerDateRangeQuery(
    String ownerId,
    DateTime from,
    DateTime to,
  ) {
    final schedulesTable = db.schedules;
    final pillsTable = db.pills;
    final profilesTable = db.profiles;
    final query =
        select(doseLogs).join([
            innerJoin(
              schedulesTable,
              schedulesTable.id.equalsExp(doseLogs.scheduleId),
            ),
            innerJoin(
              pillsTable,
              pillsTable.id.equalsExp(schedulesTable.pillId),
            ),
            innerJoin(
              profilesTable,
              profilesTable.id.equalsExp(pillsTable.profileId),
            ),
          ])
          ..where(
            profilesTable.userId.equals(ownerId) &
                doseLogs.scheduledAt.isBiggerOrEqualValue(from) &
                doseLogs.scheduledAt.isSmallerOrEqualValue(to) &
                doseLogs.isDeleted.equals(false),
          )
          ..orderBy([OrderingTerm.asc(doseLogs.scheduledAt)]);
    return query.map((row) => row.readTable(doseLogs));
  }

  /// Returns dose log entries with pill name, dosage, and profile name resolved
  /// via joins: dose_logs → schedules → pills → profiles.
  /// Ordered by scheduledAt ASC.
  Future<List<HistoryEntry>> getHistoryEntriesForDateRange(
    DateTime from,
    DateTime to, {
    String? profileId,
  }) {
    final schedulesTable = db.schedules;
    final pillsTable = db.pills;
    final profilesTable = db.profiles;

    final query =
        select(doseLogs).join([
            innerJoin(
              schedulesTable,
              schedulesTable.id.equalsExp(doseLogs.scheduleId),
            ),
            innerJoin(
              pillsTable,
              pillsTable.id.equalsExp(schedulesTable.pillId),
            ),
            innerJoin(
              profilesTable,
              profilesTable.id.equalsExp(pillsTable.profileId),
            ),
          ])
          ..where(
            doseLogs.scheduledAt.isBiggerOrEqualValue(from) &
                doseLogs.scheduledAt.isSmallerOrEqualValue(to) &
                doseLogs.isDeleted.equals(false) &
                pillsTable.isDeleted.equals(false) &
                profilesTable.isDeleted.equals(false) &
                (profileId != null
                    ? profilesTable.id.equals(profileId)
                    : const Constant(true)),
          )
          ..orderBy([OrderingTerm.asc(doseLogs.scheduledAt)]);

    return query.get().then(
      (rows) => rows.map((row) {
        final log = row.readTable(doseLogs);
        final pill = row.readTable(pillsTable);
        final profile = row.readTable(profilesTable);
        return HistoryEntry(
          doseLogId: log.id,
          pillName: pill.name,
          dosage: pill.dosage,
          scheduledAt: log.scheduledAt,
          takenAt: log.takenAt,
          status: log.status,
          note: log.note,
          profileName: profile.name,
          scheduleId: log.scheduleId,
          provenance: 'legacy_estimated',
          actualTimeKnown: log.takenAt != null,
        );
      }).toList(),
    );
  }

  /// Streams dose log entries with pill name, dosage, and profile name resolved
  /// via joins: dose_logs → schedules → pills → profiles.
  /// Ordered by scheduledAt ASC; caller can reverse for newest-first display.
  Stream<List<HistoryEntry>> watchHistoryEntriesForDateRange(
    DateTime from,
    DateTime to,
  ) {
    final schedulesTable = db.schedules;
    final pillsTable = db.pills;
    final profilesTable = db.profiles;

    final query =
        select(doseLogs).join([
            innerJoin(
              schedulesTable,
              schedulesTable.id.equalsExp(doseLogs.scheduleId),
            ),
            innerJoin(
              pillsTable,
              pillsTable.id.equalsExp(schedulesTable.pillId),
            ),
            innerJoin(
              profilesTable,
              profilesTable.id.equalsExp(pillsTable.profileId),
            ),
          ])
          ..where(
            doseLogs.scheduledAt.isBiggerOrEqualValue(from) &
                doseLogs.scheduledAt.isSmallerOrEqualValue(to) &
                doseLogs.isDeleted.equals(false) &
                pillsTable.isDeleted.equals(false) &
                profilesTable.isDeleted.equals(false),
          )
          ..orderBy([OrderingTerm.asc(doseLogs.scheduledAt)]);

    return query.watch().map(
      (rows) => rows.map((row) {
        final log = row.readTable(doseLogs);
        final pill = row.readTable(pillsTable);
        final profile = row.readTable(profilesTable);
        return HistoryEntry(
          doseLogId: log.id,
          pillName: pill.name,
          dosage: pill.dosage,
          scheduledAt: log.scheduledAt,
          takenAt: log.takenAt,
          status: log.status,
          note: log.note,
          profileName: profile.name,
          scheduleId: log.scheduleId,
          provenance: 'legacy_estimated',
          actualTimeKnown: log.takenAt != null,
        );
      }).toList(),
    );
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  Future<void> upsert(DoseLogsCompanion log) =>
      into(doseLogs).insertOnConflictUpdate(log);

  Future<bool> update_(DoseLogsCompanion log) => update(doseLogs).replace(log);

  Future<int> softDelete(String id) =>
      (update(doseLogs)..where((t) => t.id.equals(id))).write(
        DoseLogsCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('pending'),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Permanently removes a row. Only used to clean up pull-created ghost
  /// rows (id == serverId) once the original local row claims that serverId.
  Future<int> deleteById(String id) =>
      (delete(doseLogs)..where((t) => t.id.equals(id))).go();

  // ── Sync helpers ──────────────────────────────────────────────────────────

  Future<List<DoseLog>> getPendingSync() =>
      (select(doseLogs)..where(
            (t) =>
                t.syncStatus.equals('pending') |
                // All conflict rows re-flush: rows that never reached the
                // server retry their POST; rows that hit a duplicate 409
                // resolve via PATCH onto the server's existing row.
                t.syncStatus.equals('conflict'),
          ))
          .get();

  Future<void> markSynced(String id, String serverId, {int? revision}) =>
      (update(doseLogs)..where((t) => t.id.equals(id))).write(
        DoseLogsCompanion(
          serverId: Value(serverId),
          revision: revision == null ? const Value.absent() : Value(revision),
          syncStatus: const Value('synced'),
          lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<void> markConflict(String id) =>
      (update(doseLogs)..where((t) => t.id.equals(id))).write(
        const DoseLogsCompanion(syncStatus: Value('conflict')),
      );

  Future<int> purgeSyncedTombstones(DateTime before) =>
      (delete(doseLogs)..where(
            (t) =>
                t.isDeleted.equals(true) &
                t.syncStatus.equals('synced') &
                t.updatedAt.isSmallerOrEqualValue(before),
          ))
          .go();
}
