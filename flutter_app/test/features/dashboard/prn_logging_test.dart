import 'package:drift/drift.dart' show Value;
import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/doses/slot_engine.dart';

void main() {
  late AppDatabase db;

  const userId = 'user-1';
  const profileId = 'profile-1';
  const prnPillId = 'pill-prn';
  const regularPillId = 'pill-regular';
  const prnSentinelId = 'schedule-prn-sentinel';
  const regularScheduleId = 'schedule-regular';

  setUp(() async {
    db = AppDatabase.forTesting();

    final now = DateTime.utc(2026, 6, 16, 7, 0);
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

    // Regular pill with a daily schedule
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: regularPillId,
        profileId: profileId,
        name: 'Aspirin',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: regularScheduleId,
        pillId: regularPillId,
        hour: 8,
        minute: 0,
        frequency: 'daily',
        createdAt: now,
        updatedAt: now,
      ),
    );

    // PRN pill with a sentinel schedule (frequency='prn')
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: prnPillId,
        profileId: profileId,
        name: 'Ibuprofen PRN',
        isPrn: const Value(true),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: prnSentinelId,
        pillId: prnPillId,
        hour: 0,
        minute: 0,
        frequency: 'prn',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() async => db.close());

  group('PRN logging path', () {
    test(
      'watchWithSchedulesByProfileIds includes PRN pill but excludes sentinel',
      () async {
        final results = await db.pillsDao.watchWithSchedulesByProfileIds([
          profileId,
        ]).first;

        // Both pills should be returned
        expect(results.length, 2);

        final regular = results.firstWhere((r) => r.pill.id == regularPillId);
        expect(regular.schedules.length, 1);
        expect(regular.schedules.first.frequency, 'daily');

        // PRN pill is present but its sentinel is filtered from the JOIN
        final prn = results.firstWhere((r) => r.pill.id == prnPillId);
        expect(prn.pill.isPrn, isTrue);
        expect(prn.schedules, isEmpty);
      },
    );

    test('PRN sentinel is fetchable via schedulesDao.getByPillId', () async {
      final schedules = await db.schedulesDao.getByPillId(prnPillId);

      expect(schedules.length, 1);
      expect(schedules.first.id, prnSentinelId);
      expect(schedules.first.frequency, 'prn');
    });

    test('expectedSlotsFor skips PRN sentinel schedules', () {
      final sentinel = Schedule(
        id: prnSentinelId,
        pillId: prnPillId,
        hour: 0,
        minute: 0,
        frequency: 'prn',
        frequencyDays: null,
        timeZone: null,
        timeZoneStatus: 'legacy_unknown',
        isActive: true,
        createdAt: DateTime.utc(2026, 6, 16),
        updatedAt: DateTime.utc(2026, 6, 16),
        serverId: null,
        revision: 1,
        syncStatus: 'synced',
        lastSyncAt: null,
        isDeleted: false,
      );

      final slots = expectedSlotsFor([sentinel], DateTime(2026, 6, 16));
      expect(slots, isEmpty);
    });

    test('PRN dose can be logged against the sentinel schedule', () async {
      final now = DateTime.utc(2026, 6, 16, 14, 30);

      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'prn-log-1',
          scheduleId: prnSentinelId,
          scheduledAt: now,
          status: 'taken',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final dayStart = DateTime.utc(2026, 6, 16);
      final dayEnd = DateTime.utc(2026, 6, 16, 23, 59, 59, 999);
      final logs = await db.doseLogsDao.getForDateRange(dayStart, dayEnd);

      final prnLog = logs.firstWhereOrNull(
        (l) => l.scheduleId == prnSentinelId,
      );
      expect(prnLog, isNotNull);
      expect(prnLog!.id, 'prn-log-1');
      expect(prnLog.status, 'taken');
    });

    test('multiple PRN doses can be logged on the same day', () async {
      final dose1Time = DateTime.utc(2026, 6, 16, 10, 0);
      final dose2Time = DateTime.utc(2026, 6, 16, 16, 0);

      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'prn-log-1',
          scheduleId: prnSentinelId,
          scheduledAt: dose1Time,
          status: 'taken',
          createdAt: dose1Time,
          updatedAt: dose1Time,
        ),
      );
      await db.doseLogsDao.upsert(
        DoseLogsCompanion.insert(
          id: 'prn-log-2',
          scheduleId: prnSentinelId,
          scheduledAt: dose2Time,
          status: 'taken',
          createdAt: dose2Time,
          updatedAt: dose2Time,
        ),
      );

      final dayStart = DateTime.utc(2026, 6, 16);
      final dayEnd = DateTime.utc(2026, 6, 16, 23, 59, 59, 999);
      final logs = await db.doseLogsDao.getForDateRange(dayStart, dayEnd);
      final prnLogs = logs.where((l) => l.scheduleId == prnSentinelId).toList();

      expect(prnLogs.length, 2);
      expect(prnLogs.every((l) => l.status == 'taken'), isTrue);
    });

    test(
      'full PRN dashboard path: pill appears, sentinel found, dose count correct',
      () async {
        // Simulate the prnDashboardProvider logic:
        // 1. Get pills via watchWithSchedulesByProfileIds
        final results = await db.pillsDao.watchWithSchedulesByProfileIds([
          profileId,
        ]).first;

        final prnPills = results.where((r) => r.pill.isPrn).toList();
        expect(prnPills.length, 1);

        // 2. For each PRN pill, fetch sentinel via schedulesDao
        final pws = prnPills.first;
        final schedules = await db.schedulesDao.getByPillId(pws.pill.id);
        final sentinel = schedules.firstWhereOrNull(
          (s) => s.frequency == 'prn',
        );
        expect(sentinel, isNotNull, reason: 'PRN sentinel must be fetchable');
        expect(sentinel!.id, prnSentinelId);

        // 3. Log two doses
        for (var i = 0; i < 2; i++) {
          final at = DateTime.utc(2026, 6, 16, 10 + i * 4, 0);
          await db.doseLogsDao.upsert(
            DoseLogsCompanion.insert(
              id: 'prn-log-$i',
              scheduleId: sentinel.id,
              scheduledAt: at,
              status: 'taken',
              createdAt: at,
              updatedAt: at,
            ),
          );
        }

        // 4. Count today's PRN doses (mirrors prnDashboardProvider logic)
        final dayStart = DateTime.utc(2026, 6, 16);
        final dayEnd = DateTime.utc(2026, 6, 16, 23, 59, 59, 999);
        final logs = await db.doseLogsDao.getForDateRange(dayStart, dayEnd);
        final todayCount = logs
            .where((l) => l.scheduleId == sentinel.id && l.status == 'taken')
            .length;
        expect(todayCount, 2);
      },
    );
  });
}
