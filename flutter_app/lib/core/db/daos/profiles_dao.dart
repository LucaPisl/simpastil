import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/profiles_table.dart';

part 'profiles_dao.g.dart';

@DriftAccessor(tables: [Profiles])
class ProfilesDao extends DatabaseAccessor<AppDatabase>
    with _$ProfilesDaoMixin {
  ProfilesDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  Future<Profile?> getById(String id) =>
      (select(profiles)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Profile?> getByServerId(String serverId) => (select(
    profiles,
  )..where((t) => t.serverId.equals(serverId))).getSingleOrNull();

  /// Stable v2 creates may use the local UUID as the server UUID before the
  /// first receipt is mapped. Callers must still preserve any pending row.
  Future<Profile?> getByMappedOrLocalId(String serverId) async =>
      await getByServerId(serverId) ?? await getById(serverId);

  Future<List<Profile>> getByUserId(String userId) =>
      (select(profiles)
            ..where((t) => t.userId.equals(userId) & t.isDeleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Stream<List<Profile>> watchByUserId(String userId) =>
      (select(profiles)
            ..where((t) => t.userId.equals(userId) & t.isDeleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.name)]))
          .watch();

  Future<List<Profile>> getActiveByUserId(String userId) =>
      (select(profiles)..where(
            (t) =>
                t.userId.equals(userId) &
                t.isActive.equals(true) &
                t.isDeleted.equals(false),
          ))
          .get();

  // ── Mutations ─────────────────────────────────────────────────────────────

  Future<void> upsert(ProfilesCompanion profile) =>
      into(profiles).insertOnConflictUpdate(profile);

  Future<bool> update_(ProfilesCompanion profile) =>
      update(profiles).replace(profile);

  Future<void> setActive(String id, bool isActive) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          isActive: Value(isActive),
          updatedAt: Value(DateTime.now()),
          syncStatus: const Value('pending'),
        ),
      );

  Future<int> softDelete(String id) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('pending'),
          updatedAt: Value(DateTime.now()),
        ),
      );

  // ── Sync helpers ──────────────────────────────────────────────────────────

  Future<List<Profile>> getPendingSync() =>
      (select(profiles)..where((t) => t.syncStatus.equals('pending'))).get();

  Future<void> markSynced(String id, String serverId, {int? revision}) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          serverId: Value(serverId),
          revision: revision == null ? const Value.absent() : Value(revision),
          syncStatus: const Value('synced'),
          lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<int> purgeSyncedTombstones(DateTime before) =>
      (delete(profiles)..where(
            (t) =>
                t.isDeleted.equals(true) &
                t.syncStatus.equals('synced') &
                t.updatedAt.isSmallerOrEqualValue(before) &
                notExistsQuery(
                  select(db.pills)
                    ..where((row) => row.profileId.equalsExp(t.id)),
                ),
          ))
          .go();
}
