import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting());
  tearDown(() => db.close());

  // ── Seed helpers ─────────────────────────────────────────────────────────

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

  Future<String> seedProfile(
    String userId, {
    String? id,
    bool isDeleted = false,
  }) async {
    final profileId =
        id ?? 'prof-$userId-${DateTime.now().microsecondsSinceEpoch}';
    await db
        .into(db.profiles)
        .insert(
          ProfilesCompanion.insert(
            id: profileId,
            userId: userId,
            name: 'Profile $profileId',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            isDeleted: Value(isDeleted),
          ),
        );
    return profileId;
  }

  Future<String> seedPill(
    String profileId, {
    required String name,
    String? dosage,
    String? id,
    bool isDeleted = false,
  }) async {
    final pillId = id ?? 'pill-${DateTime.now().microsecondsSinceEpoch}';
    await db
        .into(db.pills)
        .insert(
          PillsCompanion.insert(
            id: pillId,
            profileId: profileId,
            name: name,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            dosage: Value(dosage),
            isDeleted: Value(isDeleted),
          ),
        );
    return pillId;
  }

  // ── Tests ─────────────────────────────────────────────────────────────────

  group('getSiblings', () {
    test('returns sibling with same name (nameOnly mode)', () async {
      await seedUser('u1');
      final p1 = await seedProfile('u1', id: 'p1');
      final p2 = await seedProfile('u1', id: 'p2');
      final pillId = await seedPill(
        p1,
        name: 'Aspirin',
        dosage: '100mg',
        id: 'pill-1',
      );
      await seedPill(p2, name: 'Aspirin', dosage: '200mg', id: 'pill-2');

      final siblings = await db.pillsDao.getSiblings(pillId, 'u1', 'Aspirin');
      expect(siblings.length, 1);
      expect(siblings.first.id, 'pill-2');
    });

    test(
      'returns sibling with same name+dosage (nameAndDosage mode)',
      () async {
        await seedUser('u1');
        final p1 = await seedProfile('u1', id: 'p1');
        final p2 = await seedProfile('u1', id: 'p2');
        final p3 = await seedProfile('u1', id: 'p3');
        final pillId = await seedPill(
          p1,
          name: 'Aspirin',
          dosage: '100mg',
          id: 'pill-1',
        );
        await seedPill(
          p2,
          name: 'Aspirin',
          dosage: '100mg',
          id: 'pill-2',
        ); // match
        await seedPill(
          p3,
          name: 'Aspirin',
          dosage: '200mg',
          id: 'pill-3',
        ); // no match

        final siblings = await db.pillsDao.getSiblings(
          pillId,
          'u1',
          'Aspirin',
          dosage: '100mg',
        );
        expect(siblings.length, 1);
        expect(siblings.first.id, 'pill-2');
      },
    );

    test('is case-insensitive on name', () async {
      await seedUser('u1');
      final p1 = await seedProfile('u1', id: 'p1');
      final p2 = await seedProfile('u1', id: 'p2');
      final pillId = await seedPill(p1, name: 'aspirin', id: 'pill-1');
      await seedPill(p2, name: 'ASPIRIN', id: 'pill-2');

      final siblings = await db.pillsDao.getSiblings(pillId, 'u1', 'aspirin');
      expect(siblings.length, 1);
      expect(siblings.first.id, 'pill-2');
    });

    test('does not return pills from a different user', () async {
      await seedUser('u1');
      await seedUser('u2');
      final p1 = await seedProfile('u1', id: 'p1');
      final p2 = await seedProfile('u2', id: 'p2');
      final pillId = await seedPill(p1, name: 'Aspirin', id: 'pill-1');
      await seedPill(p2, name: 'Aspirin', id: 'pill-other-user');

      final siblings = await db.pillsDao.getSiblings(pillId, 'u1', 'Aspirin');
      expect(siblings, isEmpty);
    });

    test('does not return the pill itself', () async {
      await seedUser('u1');
      final p1 = await seedProfile('u1', id: 'p1');
      final pillId = await seedPill(p1, name: 'Aspirin', id: 'pill-1');

      final siblings = await db.pillsDao.getSiblings(pillId, 'u1', 'Aspirin');
      expect(siblings, isEmpty);
    });

    test('does not return soft-deleted pills', () async {
      await seedUser('u1');
      final p1 = await seedProfile('u1', id: 'p1');
      final p2 = await seedProfile('u1', id: 'p2');
      final pillId = await seedPill(p1, name: 'Aspirin', id: 'pill-1');
      await seedPill(p2, name: 'Aspirin', id: 'pill-deleted', isDeleted: true);

      final siblings = await db.pillsDao.getSiblings(pillId, 'u1', 'Aspirin');
      expect(siblings, isEmpty);
    });

    test('returns empty list when no siblings exist', () async {
      await seedUser('u1');
      final p1 = await seedProfile('u1', id: 'p1');
      final pillId = await seedPill(p1, name: 'Aspirin', id: 'pill-1');

      final siblings = await db.pillsDao.getSiblings(pillId, 'u1', 'Aspirin');
      expect(siblings, isEmpty);
    });

    test('does not return pills from a soft-deleted profile', () async {
      await seedUser('u1');
      final p1 = await seedProfile('u1', id: 'p1');
      final p2 = await seedProfile('u1', id: 'p2', isDeleted: true);
      final pillId = await seedPill(p1, name: 'Aspirin', id: 'pill-1');
      await seedPill(p2, name: 'Aspirin', id: 'pill-deleted-profile');

      final siblings = await db.pillsDao.getSiblings(pillId, 'u1', 'Aspirin');
      expect(siblings, isEmpty);
    });
  });
}
