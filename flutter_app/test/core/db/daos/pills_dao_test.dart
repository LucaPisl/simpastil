import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> seedUser(String id) async {
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: id,
            email: '$id@test.com',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> seedProfile(String id, String userId) async {
    await db
        .into(db.profiles)
        .insert(
          ProfilesCompanion.insert(
            id: id,
            userId: userId,
            name: 'Profile $id',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> seedPill(
    String id,
    String profileId, {
    bool isDeleted = false,
  }) async {
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: id,
        profileId: profileId,
        name: 'Pill $id',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isDeleted: Value(isDeleted),
      ),
    );
  }

  // ── Tests ─────────────────────────────────────────────────────────────────

  group('PillsDao.countByProfileId', () {
    test('returns 0 when profile has no pills', () async {
      await seedUser('u1');
      await seedProfile('p1', 'u1');

      final count = await db.pillsDao.countByProfileId('p1');

      expect(count, 0);
    });

    test('returns count of non-deleted pills only', () async {
      await seedUser('u1');
      await seedProfile('p1', 'u1');
      await seedPill('pill1', 'p1');
      await seedPill('pill2', 'p1');
      await seedPill('pill3', 'p1', isDeleted: true); // should not be counted

      final count = await db.pillsDao.countByProfileId('p1');

      expect(count, 2);
    });

    test('does not count pills belonging to other profiles', () async {
      await seedUser('u1');
      await seedProfile('p1', 'u1');
      await seedProfile('p2', 'u1');
      await seedPill('pill1', 'p1');
      await seedPill('pill2', 'p2');

      final count = await db.pillsDao.countByProfileId('p1');

      expect(count, 1);
    });
  });
}
