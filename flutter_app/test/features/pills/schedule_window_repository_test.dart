import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/medication/schedule_window.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const _userId = '00000000-0000-4000-8000-000000000001';
const _profileId = '00000000-0000-4000-8000-000000000002';
const _pillId = '00000000-0000-4000-8000-000000000003';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Bucharest'));
  });

  late AppDatabase db;
  late Dio dio;
  late ScheduleRepositoryImpl repository;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 9, 25);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: _userId,
            email: 'window@test.invalid',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profileId,
        userId: _userId,
        name: 'Ada',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pillId,
        profileId: _profileId,
        name: 'Medication',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
      ),
    );
    dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
    repository = ScheduleRepositoryImpl(
      schedulesDao: db.schedulesDao,
      pillsDao: db.pillsDao,
      profilesDao: db.profilesDao,
      ledgerDao: db.medicationLedgerDao,
      migrationIssuesDao: db.migrationIssuesDao,
      pendingOperations: PendingOperationRepository(db),
      dio: dio,
      reconcileProjections: () async {},
    );
  });

  tearDown(() async {
    dio.close(force: true);
    await db.close();
  });

  Future<Map<String, dynamic>> lastData(String type) async {
    final ops = await db.pendingOperationsDao.getForUser(_userId);
    final op = ops.where((o) => o.operationType == type).last;
    return (jsonDecode(op.payloadJson) as Map<String, dynamic>)['data']
        as Map<String, dynamic>;
  }

  test(
    'a schedule without a window sends exactly the payload it always did',
    () async {
      final result = await repository.create(
        pillId: _pillId,
        hour: 8,
        minute: 0,
        frequency: 'daily',
      );
      expect(result, isA<Ok<Schedule>>());
      final data = await lastData('schedule.create');
      expect(data.keys.toSet(), {
        'hour',
        'minute',
        'frequency',
        'frequencyDays',
        'isActive',
        'timeZone',
      });
      final row = (result as Ok<Schedule>).value;
      expect(row.everyDays, isNull);
      expect(row.anchorDate, isNull);
      expect(row.startDate, isNull);
      expect(row.endDate, isNull);
    },
  );

  test(
    'an interval with dates sends all four keys and keeps days null',
    () async {
      final result = await repository.create(
        pillId: _pillId,
        hour: 9,
        minute: 30,
        frequency: 'interval',
        window: const ScheduleWindow(
          everyDays: 3,
          anchorDate: '2026-10-01',
          endDate: '2026-12-31',
        ),
      );
      final row = (result as Ok<Schedule>).value;
      expect(row.frequency, 'interval');
      expect(row.frequencyDays, isNull);
      expect(row.everyDays, 3);
      expect(row.endDate, '2026-12-31');
      final data = await lastData('schedule.create');
      expect(data['frequency'], 'interval');
      expect(data['frequencyDays'], isNull);
      expect(data['everyDays'], 3);
      expect(data['anchorDate'], '2026-10-01');
      expect(data['startDate'], isNull);
      expect(data['endDate'], '2026-12-31');
      expect(data.containsKey('startDate'), isTrue);
      final occurrences = await db.select(db.medicationOccurrences).get();
      expect(occurrences, isNotEmpty);
      expect(occurrences.every((o) => o.snapshotVersion == 3), isTrue);
    },
  );

  test('an update sends explicit nulls to clear a window', () async {
    final created = await repository.create(
      pillId: _pillId,
      hour: 9,
      minute: 0,
      frequency: 'daily',
      window: const ScheduleWindow(
        startDate: '2026-10-01',
        endDate: '2026-12-31',
      ),
    );
    final id = (created as Ok<Schedule>).value.id;
    final cleared = await repository.update(
      id,
      hour: 9,
      minute: 0,
      frequency: 'daily',
      isActive: true,
    );
    expect(cleared, isA<Ok<Schedule>>());
    final data = await lastData('schedule.update');
    expect(data['startDate'], isNull);
    expect(data['endDate'], isNull);
    expect(data.containsKey('startDate'), isTrue);
    expect(data.containsKey('endDate'), isTrue);
    expect((cleared as Ok<Schedule>).value.startDate, isNull);
  });

  test('an update of a plain schedule stays a plain payload', () async {
    final created = await repository.create(
      pillId: _pillId,
      hour: 9,
      minute: 0,
      frequency: 'daily',
    );
    await repository.update(
      (created as Ok<Schedule>).value.id,
      hour: 10,
      minute: 0,
      frequency: 'daily',
      isActive: true,
    );
    final data = await lastData('schedule.update');
    expect(data.containsKey('everyDays'), isFalse);
    expect(data.containsKey('startDate'), isFalse);
  });

  test('invalid shapes are refused before anything is stored', () async {
    for (final (frequency, days, window) in [
      ('interval', null, const ScheduleWindow()),
      (
        'interval',
        [1, 2],
        const ScheduleWindow(everyDays: 2, anchorDate: '2026-10-01'),
      ),
      (
        'daily',
        null,
        const ScheduleWindow(everyDays: 2, anchorDate: '2026-10-01'),
      ),
      (
        'daily',
        null,
        const ScheduleWindow(startDate: '2026-10-05', endDate: '2026-10-01'),
      ),
      ('prn', null, const ScheduleWindow(startDate: '2026-10-01')),
    ]) {
      final result = await repository.create(
        pillId: _pillId,
        hour: 9,
        minute: 0,
        frequency: frequency,
        frequencyDays: days,
        window: window,
      );
      expect(result, isA<Err<Schedule>>(), reason: '$frequency $window');
    }
    expect(await db.schedulesDao.getByPillId(_pillId), isEmpty);
  });

  test('create takes the given zone and refuses an unknown one', () async {
    final created = await repository.create(
      pillId: _pillId,
      hour: 9,
      minute: 0,
      frequency: 'daily',
      timeZone: 'America/New_York',
    );
    expect((created as Ok<Schedule>).value.timeZone, 'America/New_York');
    expect((await lastData('schedule.create'))['timeZone'], 'America/New_York');

    final bad = await repository.create(
      pillId: _pillId,
      hour: 9,
      minute: 0,
      frequency: 'daily',
      timeZone: 'Not/AZone',
    );
    expect(bad, isA<Err<Schedule>>());
    expect((bad as Err<Schedule>).error, isA<ConflictError>());
    expect(await db.schedulesDao.getByPillId(_pillId), hasLength(1));

    final local = await repository.create(
      pillId: _pillId,
      hour: 9,
      minute: 0,
      frequency: 'daily',
    );
    expect((local as Ok<Schedule>).value.timeZone, 'Europe/Bucharest');
  });
}
