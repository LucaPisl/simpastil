import 'package:drift/drift.dart';

import '../database.dart';
import '../tables/users_table.dart';

part 'users_dao.g.dart';

@DriftAccessor(tables: [Users])
class UsersDao extends DatabaseAccessor<AppDatabase> with _$UsersDaoMixin {
  UsersDao(super.db);

  // ── Queries ───────────────────────────────────────────────────────────────

  Future<User?> getById(String id) =>
      (select(users)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<User?> watchById(String id) =>
      (select(users)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<List<User>> getAll() => select(users).get();

  // ── Mutations ─────────────────────────────────────────────────────────────

  Future<void> upsert(UsersCompanion user) =>
      into(users).insertOnConflictUpdate(user);

  Future<bool> update_(UsersCompanion user) => update(users).replace(user);

  /// Atomically advances the persisted generation, including across logout.
  Future<int?> incrementSessionGeneration(String userId) async {
    await customUpdate(
      'UPDATE users SET session_generation = session_generation + 1 WHERE id = ?',
      variables: [Variable<String>(userId)],
      updates: {users},
    );
    return (await getById(userId))?.sessionGeneration;
  }

  Future<int> softDelete(String id) =>
      (update(users)..where((t) => t.id.equals(id))).write(
        UsersCompanion(
          isDeleted: const Value(true),
          syncStatus: const Value('pending'),
          updatedAt: Value(DateTime.now()),
        ),
      );

  // ── Sync helpers ──────────────────────────────────────────────────────────

  Future<List<User>> getPendingSync() =>
      (select(users)..where(
            (t) => t.syncStatus.equals('pending') & t.isDeleted.equals(false),
          ))
          .get();

  Future<List<User>> getConflicts() =>
      (select(users)..where((t) => t.syncStatus.equals('conflict'))).get();

  Future<void> markSynced(String id, String serverId) =>
      (update(users)..where((t) => t.id.equals(id))).write(
        UsersCompanion(
          serverId: Value(serverId),
          syncStatus: const Value('synced'),
          lastSyncAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
}
