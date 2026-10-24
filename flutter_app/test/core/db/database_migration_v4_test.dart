import 'package:dio/dio.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/core/db/database.dart';

import '../../fixtures/legacy_v3_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory(setup: seedLegacyV3));
  });

  tearDown(() async => db.close());

  test(
    'v3 migration preserves source state and quarantines uncertain writes',
    () async {
      expect(db.schemaVersion, AppDatabase.supportedSchemaVersion);

      final profile = await db.profilesDao.getById('profile-1');
      final pill = await db.pillsDao.getById('pill-1');
      final user = await db.usersDao.getById('user-1');
      expect(profile?.revision, 1);
      expect(pill?.revision, 1);
      expect(user?.sessionGeneration, 0);

      final sourceLogs = await db.doseLogsDao.getByScheduleId('schedule-1');
      expect(sourceLogs, hasLength(2));
      expect(sourceLogs.every((row) => row.syncStatus == 'pending'), isTrue);

      final occurrences = await db.medicationLedgerDao.getOccurrencesForUser(
        'user-1',
      );
      expect(occurrences, hasLength(2));
      expect(occurrences.map((row) => row.occurrenceKey).toSet(), hasLength(2));
      expect(
        occurrences.every((row) => row.provenance == 'legacy_estimated'),
        isTrue,
      );
      expect(
        await db.medicationLedgerDao.getInventoryBalance('pill-1'),
        ExactStock.fromInt(10),
      );

      final operations = await db.select(db.pendingOperations).get();
      expect(operations, hasLength(3));
      expect(operations.every((row) => row.state == 'blocked'), isTrue);
      final effects = await db.select(db.pendingOperationEffects).get();
      expect(effects, hasLength(3));
      expect(effects.every((row) => row.state == 'uncertain'), isTrue);
      expect(await db.migrationIssuesDao.getUnresolved('user-1'), isNotEmpty);
      expect(
        await SyncService(db: db, dio: Dio()).countPending(userId: 'user-1'),
        0,
      );
      expect(await db.select(db.pendingOperations).get(), operations);
      expect(await db.select(db.pendingOperationEffects).get(), effects);
    },
  );

  test('v3 migration clears duplicate server identities for review', () async {
    await db.close();
    db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          seedLegacyV3(raw);
          raw.execute(
            "UPDATE dose_logs SET server_id = 'duplicate-server-id' "
            "WHERE id IN ('dose-1', 'dose-2')",
          );
        },
      ),
    );

    final logs = await db.doseLogsDao.getByScheduleId('schedule-1');
    expect(logs, hasLength(2));
    expect(
      logs.where((row) => row.serverId == 'duplicate-server-id'),
      hasLength(1),
    );
    expect(
      (await db.migrationIssuesDao.getUnresolved(
        'user-1',
      )).map((issue) => issue.issueCode),
      contains('duplicate_server_identity'),
    );
  });

  test('v3 migration disables an invalid schedule for review', () async {
    await db.close();
    db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          seedLegacyV3(raw);
          raw.execute(
            "UPDATE schedules SET frequency = 'weekly', "
            "frequency_days = 'not-json' WHERE id = 'schedule-1'",
          );
        },
      ),
    );

    expect((await db.schedulesDao.getById('schedule-1'))?.isActive, isFalse);
    expect(await db.doseLogsDao.getByScheduleId('schedule-1'), hasLength(2));
    expect(
      (await db.migrationIssuesDao.getUnresolved(
        'user-1',
      )).map((issue) => issue.issueCode),
      contains('invalid_schedule_frequency_days'),
    );
  });

  test(
    'v3 migration preserves a valid as-needed sentinel and history',
    () async {
      await db.close();
      db = AppDatabase(
        NativeDatabase.memory(
          setup: (raw) {
            seedLegacyV3(raw);
            raw.execute(
              "UPDATE schedules SET frequency = 'prn', frequency_days = NULL "
              "WHERE id = 'schedule-1'",
            );
          },
        ),
      );

      final schedule = await db.schedulesDao.getById('schedule-1');
      expect(schedule?.isActive, isTrue);
      expect(schedule?.frequency, 'prn');
      expect(schedule?.frequencyDays, isNull);
      expect(await db.doseLogsDao.getByScheduleId('schedule-1'), hasLength(2));
      expect(
        await db.medicationLedgerDao.getInventoryBalance('pill-1'),
        ExactStock.fromInt(10),
      );
      final issues = await db.migrationIssuesDao.getUnresolved('user-1');
      expect(
        issues.where(
          (issue) => issue.issueCode == 'invalid_schedule_frequency_days',
        ),
        isEmpty,
      );
      final operations = await db.select(db.pendingOperations).get();
      expect(
        operations.every((operation) => operation.state == 'blocked'),
        isTrue,
      );
      expect(operations, hasLength(3));
    },
  );
}
