import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';

void main() {
  late AppDatabase db;

  const userId = 'user-1';
  const profileId = 'profile-1';
  const pillId = 'pill-1';
  const scheduleId = 'schedule-1';
  final scheduledAt = DateTime.utc(2026, 3, 29, 8, 0);
  final otherScheduledAt = DateTime.utc(2026, 3, 29, 9, 0);

  setUp(() async {
    db = AppDatabase.forTesting();

    final now = DateTime.utc(2026, 3, 29, 7, 0);
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: userId,
        email: 'user@example.com',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: profileId,
        userId: userId,
        name: 'Test Profile',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: pillId,
        profileId: profileId,
        name: 'Aspirin',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: scheduleId,
        pillId: pillId,
        hour: 8,
        minute: 0,
        frequency: 'daily',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('DoseLogsDao.getByScheduledSlot', () {
    test('returns null when no row matches the scheduled slot', () async {
      final result = await db.doseLogsDao.getByScheduledSlot(
        scheduleId,
        scheduledAt,
      );

      expect(result, isNull);
    });

    test('returns the exact matching row', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'log-1',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: scheduledAt,
          updatedAt: scheduledAt,
        ),
      );

      final result = await db.doseLogsDao.getByScheduledSlot(
        scheduleId,
        scheduledAt,
      );

      expect(result, isNotNull);
      expect(result!.id, 'log-1');
      expect(result.scheduleId, scheduleId);
      expect(result.scheduledAt.toUtc(), scheduledAt);
    });

    test('returns null for a different scheduledAt', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'log-1',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: scheduledAt,
          updatedAt: scheduledAt,
        ),
      );

      final result = await db.doseLogsDao.getByScheduledSlot(
        scheduleId,
        otherScheduledAt,
      );

      expect(result, isNull);
    });

    test('getByScheduledSlot ignores soft-deleted rows', () async {
      // Insert a soft-deleted row for the same slot.
      await db.doseLogsDao.upsert(
        DoseLogsCompanion(
          id: const Value('log-deleted'),
          scheduleId: const Value(scheduleId),
          scheduledAt: Value(scheduledAt),
          takenAt: const Value.absent(),
          status: const Value('skipped'),
          createdAt: Value(scheduledAt),
          updatedAt: Value(scheduledAt),
          serverId: const Value.absent(),
          syncStatus: const Value('pending'),
          lastSyncAt: const Value.absent(),
          isDeleted: const Value(true),
        ),
      );

      // Insert a live row for the same slot (simulates re-mark after resetToPending).
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'log-live',
          scheduleId: scheduleId,
          scheduledAt: scheduledAt,
          status: 'taken',
          createdAt: scheduledAt,
          updatedAt: scheduledAt,
        ),
      );

      // Must return the live row, not throw StateError.
      final result = await db.doseLogsDao.getByScheduledSlot(
        scheduleId,
        scheduledAt,
      );

      expect(result, isNotNull);
      expect(result!.id, 'log-live');
      expect(result.isDeleted, isFalse);
    });
  });

  group('DoseLogsDao.getPendingSync', () {
    test('includes conflict rows even when serverId is set', () async {
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'log-conflict-1',
          scheduleId: scheduleId,
          scheduledAt: DateTime.utc(2026, 6, 11, 8, 0),
          status: 'taken',
          createdAt: DateTime.utc(2026, 6, 11, 8, 0),
          updatedAt: DateTime.utc(2026, 6, 11, 8, 0),
        ),
      );
      await db.doseLogsDao.markSynced('log-conflict-1', 'srv-log-1');
      await db.doseLogsDao.markConflict('log-conflict-1');

      final pending = await db.doseLogsDao.getPendingSync();
      expect(pending.map((l) => l.id), contains('log-conflict-1'));
    });
  });
}
