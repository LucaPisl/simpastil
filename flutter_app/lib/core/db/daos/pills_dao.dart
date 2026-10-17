import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/pills_table.dart';

part 'pills_dao.g.dart';

@DriftAccessor(tables: [Pills])
class PillsDao extends DatabaseAccessor<AppDatabase> with _$PillsDaoMixin {
  PillsDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  Future<Pill?> getById(String id) =>
      (select(pills)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Pill?> getByServerId(String serverId) => (select(
    pills,
  )..where((t) => t.serverId.equals(serverId))).getSingleOrNull();

  /// Stable v2 creates may use the local UUID as the server UUID before the
  /// first receipt is mapped. Callers must still preserve any pending row.
  Future<Pill?> getByMappedOrLocalId(String serverId) async =>
      await getByServerId(serverId) ?? await getById(serverId);

  Future<List<Pill>> getByProfileId(String profileId) =>
      (select(pills)
            ..where(
              (t) => t.profileId.equals(profileId) & t.isDeleted.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .get();

  Stream<List<Pill>> watchByProfileId(String profileId) =>
      (select(pills)
            ..where(
              (t) => t.profileId.equals(profileId) & t.isDeleted.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .watch();

  Stream<List<Pill>> watchByProfileIds(List<String> profileIds) {
    if (profileIds.isEmpty) return Stream.value(const []);

    return (select(pills)
          ..where(
            (t) => t.profileId.isIn(profileIds) & t.isDeleted.equals(false),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  /// Watches pills and schedules together, emitting whenever either table
  /// changes for the requested profile set.
  Stream<List<({Pill pill, List<Schedule> schedules})>>
  watchWithSchedulesByProfileIds(List<String> profileIds) {
    if (profileIds.isEmpty) return Stream.value(const []);
    return _pillsWithSchedulesQuery(
      profileIds,
    ).watch().map(_groupPillsWithSchedules);
  }

  Future<List<({Pill pill, List<Schedule> schedules})>>
  getWithSchedulesByProfileIds(List<String> profileIds) async {
    if (profileIds.isEmpty) return const [];
    return _groupPillsWithSchedules(
      await _pillsWithSchedulesQuery(profileIds).get(),
    );
  }

  Selectable<TypedResult> _pillsWithSchedulesQuery(List<String> profileIds) {
    final schedulesTable = db.schedules;
    final profilesTable = db.profiles;
    final query =
        select(pills).join([
            innerJoin(
              profilesTable,
              profilesTable.id.equalsExp(pills.profileId) &
                  profilesTable.isDeleted.equals(false),
            ),
            leftOuterJoin(
              schedulesTable,
              schedulesTable.pillId.equalsExp(pills.id) &
                  schedulesTable.isDeleted.equals(false) &
                  schedulesTable.frequency.equals('prn').not(),
            ),
          ])
          ..where(
            pills.profileId.isIn(profileIds) & pills.isDeleted.equals(false),
          )
          ..orderBy([
            OrderingTerm.asc(pills.name),
            OrderingTerm.asc(schedulesTable.hour),
            OrderingTerm.asc(schedulesTable.minute),
          ]);

    return query;
  }

  List<({Pill pill, List<Schedule> schedules})> _groupPillsWithSchedules(
    List<TypedResult> rows,
  ) {
    final schedulesTable = db.schedules;
    final grouped = <String, ({Pill pill, List<Schedule> schedules})>{};
    for (final row in rows) {
      final pill = row.readTable(pills);
      final schedule = row.readTableOrNull(schedulesTable);
      final existing = grouped[pill.id];
      if (existing == null) {
        grouped[pill.id] = (
          pill: pill,
          schedules: schedule != null ? [schedule] : <Schedule>[],
        );
        continue;
      }
      if (schedule != null) {
        existing.schedules.add(schedule);
      }
    }
    return grouped.values.toList(growable: false);
  }

  Future<int> countByProfileId(String profileId) async {
    final countExpr = pills.id.count();
    final query = selectOnly(pills)
      ..addColumns([countExpr])
      ..where(
        pills.profileId.equals(profileId) & pills.isDeleted.equals(false),
      );
    final row = await query.getSingle();
    return row.read(countExpr) ?? 0;
  }

  Stream<int> watchCountByProfileId(String profileId) {
    final countExpr = pills.id.count();
    final query = selectOnly(pills)
      ..addColumns([countExpr])
      ..where(
        pills.profileId.equals(profileId) & pills.isDeleted.equals(false),
      );
    return query.watchSingle().map((row) => row.read(countExpr) ?? 0);
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  Future<void> upsert(PillsCompanion pill) =>
      into(pills).insertOnConflictUpdate(pill);

  Future<bool> update_(PillsCompanion pill) => update(pills).replace(pill);

  Future<int> softDelete(String id) =>
      (update(pills)..where((t) => t.id.equals(id))).write(
        PillsCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('pending'),
          updatedAt: Value(DateTime.now()),
        ),
      );

  // ── Sync helpers ──────────────────────────────────────────────────────────

  Future<List<Pill>> getPendingSync() =>
      (select(pills)..where((t) => t.syncStatus.equals('pending'))).get();

  Future<void> markSynced(String id, String serverId, {int? revision}) =>
      (update(pills)..where((t) => t.id.equals(id))).write(
        PillsCompanion(
          serverId: Value(serverId),
          revision: revision == null ? const Value.absent() : Value(revision),
          syncStatus: const Value('synced'),
          lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<int> purgeSyncedTombstones(DateTime before) =>
      (delete(pills)..where(
            (t) =>
                t.isDeleted.equals(true) &
                t.syncStatus.equals('synced') &
                t.updatedAt.isSmallerOrEqualValue(before) &
                notExistsQuery(
                  select(db.schedules)
                    ..where((row) => row.pillId.equalsExp(t.id)),
                ) &
                notExistsQuery(
                  select(db.medicationOccurrences)
                    ..where((row) => row.pillId.equalsExp(t.id)),
                ),
          ))
          .go();

  /// Returns all non-deleted pills for [userId] that share the same
  /// (case-insensitive) [name] — and optionally [dosage] — as the given pill,
  /// excluding [excludeId] itself.
  ///
  /// Used to detect sibling pills (the same medication across profiles) when
  /// opening the edit sheet.
  Future<List<Pill>> getSiblings(
    String excludeId,
    String userId,
    String name, {
    String? dosage,
  }) {
    final profilesTable = db.profiles;
    final nameLower = name.toLowerCase();

    final query =
        select(pills).join([
          innerJoin(profilesTable, profilesTable.id.equalsExp(pills.profileId)),
        ])..where(
          profilesTable.userId.equals(userId) &
              profilesTable.isDeleted.equals(false) &
              pills.id.equals(excludeId).not() &
              pills.isDeleted.equals(false) &
              pills.name.lower().equals(nameLower),
        );

    if (dosage != null) {
      query.where(pills.dosage.equals(dosage));
    }

    return query.map((row) => row.readTable(pills)).get();
  }
}
