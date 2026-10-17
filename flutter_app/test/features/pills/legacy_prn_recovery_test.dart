import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/adapters/stable_record_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:timezone/data/latest.dart' as tzdata;

const user = '00000000-0000-4000-8000-000000000001';
const profile = '00000000-0000-4000-8000-000000000002';
const pill = '00000000-0000-4000-8000-000000000003';
const pillServer = '00000000-0000-4000-8000-000000000013';
const schedule = '00000000-0000-4000-8000-000000000004';
const issue = '00000000-0000-4000-8000-000000000005';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test('retains the legacy row and confirms a lost create response', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
    final transport = _Transport();
    dio.httpClientAdapter = transport;
    addTearDown(() async {
      dio.close(force: true);
      await db.close();
    });
    final now = DateTime.utc(2026, 10, 7);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: user,
            email: 'owner@test.invalid',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: profile,
        userId: user,
        name: 'Person',
        createdAt: now,
        updatedAt: now,
        serverId: const Value(profile),
        syncStatus: const Value('synced'),
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: pill,
        profileId: profile,
        name: 'PRN',
        isPrn: const Value(true),
        createdAt: now,
        updatedAt: now,
        serverId: const Value(pillServer),
        syncStatus: const Value('synced'),
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: schedule,
        pillId: pill,
        hour: 0,
        minute: 0,
        frequency: 'prn',
        isActive: const Value(false),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.migrationIssuesDao.record(
      MigrationIssuesCompanion.insert(
        id: issue,
        userId: user,
        entityType: 'schedule',
        entityId: schedule,
        issueCode: 'invalid_schedule_frequency_days',
        snapshotJson: jsonEncode({
          'scheduleId': schedule,
          'frequency': 'prn',
          'frequencyDays': null,
          'isPrn': true,
        }),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.doseLogsDao.upsert(
      DoseLogsCompanion.insert(
        id: '00000000-0000-4000-8000-000000000006',
        scheduleId: schedule,
        scheduledAt: now,
        status: 'taken',
        takenAt: Value(now),
        note: const Value('retained fictional history'),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.medicationLedgerDao.upsertOccurrence(
      MedicationOccurrencesCompanion.insert(
        id: '00000000-0000-4000-8000-000000000007',
        userId: user,
        pillId: const Value(pill),
        scheduleId: const Value(schedule),
        occurrenceKey: 'prn:00000000-0000-4000-8000-000000000006',
        source: 'legacy',
        plannedLocalDate: '2026-10-07',
        timeZone: 'UTC',
        scheduleSnapshotJson: '{}',
        provenance: 'legacy_estimated',
        state: const Value('taken'),
        stateVersion: const Value(1),
        createdAt: now,
        updatedAt: now,
      ),
    );
    final repository = ScheduleRepositoryImpl(
      schedulesDao: db.schedulesDao,
      pillsDao: db.pillsDao,
      profilesDao: db.profilesDao,
      ledgerDao: db.medicationLedgerDao,
      migrationIssuesDao: db.migrationIssuesDao,
      pendingOperations: PendingOperationRepository(db),
      dio: dio,
      reconcileProjections: () async {},
    );

    final before = await db.schedulesDao.getById(schedule);
    final beforeDose = await db.doseLogsDao.getById(
      '00000000-0000-4000-8000-000000000006',
    );
    final beforeOccurrence = await db.medicationLedgerDao.getOccurrenceById(
      '00000000-0000-4000-8000-000000000007',
    );
    expect(
      await repository.recoverLegacyPrn(
        localId: schedule,
        timeZone: 'Europe/Bucharest',
      ),
      isA<Ok<Schedule>>(),
    );
    expect(await db.schedulesDao.getById(schedule), before);
    expect(
      (await db.migrationIssuesDao.getById(issue))!.resolutionState,
      'unresolved',
    );

    final operation = (await db.pendingOperationsDao.getForUser(user)).single;
    expect(
      await db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: 'queued',
        to: 'sending',
      ),
      isTrue,
    );
    final result = await V2StableAdapter(db: db, dio: dio).send(operation);
    expect(result.safeErrorCode, 'LEGACY_PRN_RECOVERY_OUTCOME_UNCONFIRMED');
    expect(result.applyReceipt, isNull);
    expect((await db.schedulesDao.getById(schedule))!.isActive, isFalse);
    expect(
      (await db.migrationIssuesDao.getById(issue))!.resolutionState,
      'unresolved',
    );
    expect(
      await db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: 'sending',
        to: 'failedRetryable',
      ),
      isTrue,
    );
    final retry = (await db.pendingOperationsDao.getById(operation.id))!;
    expect(
      await db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: 'failedRetryable',
        to: 'sending',
      ),
      isTrue,
    );
    final retryResult = await V2StableAdapter(db: db, dio: dio).send(retry);
    expect(retryResult.safeErrorCode, isNull);
    expect(
      await PendingOperationRepository(db).commitWithMatchingReceipt(
        operationId: operation.id,
        acknowledgedMutationId: operation.mutationId,
      ),
      isTrue,
    );
    await retryResult.applyReceipt!();
    final recovered = (await db.schedulesDao.getById(schedule))!;
    expect(
      (recovered.id, recovered.serverId, recovered.isActive),
      (schedule, schedule, true),
    );
    expect(
      (recovered.timeZone, recovered.timeZoneStatus),
      ('Europe/Bucharest', 'known'),
    );
    expect(recovered.createdAt, before!.createdAt);
    expect(
      await db.doseLogsDao.getById('00000000-0000-4000-8000-000000000006'),
      beforeDose,
    );
    expect(
      await db.medicationLedgerDao.getOccurrenceById(
        '00000000-0000-4000-8000-000000000007',
      ),
      beforeOccurrence,
    );
    expect(
      (await db.migrationIssuesDao.getById(issue))!.resolutionState,
      'resolved',
    );
    expect(transport.posts, 2);
    expect(transport.postBodies.toSet(), hasLength(1));
  });

  test('recovery conflict never applies the generic server winner', () async {
    final fixture = await _fixture(
      _Transport(postStatus: 409, loseFirstPost: false),
    );
    final queued = await fixture.queue();
    final result = await V2StableAdapter(
      db: fixture.db,
      dio: fixture.dio,
    ).send(queued);

    expect(result.status, StableMutationStatus.conflict);
    expect(result.applyReceipt, isNull);
    expect(
      (await fixture.db.schedulesDao.getById(schedule))!.isActive,
      isFalse,
    );
    expect(
      (await fixture.db.migrationIssuesDao.getById(issue))!.resolutionState,
      'unresolved',
    );
  });

  test('late duplicate PRN prevents receipt application', () async {
    final fixture = await _fixture(_Transport(loseFirstPost: false));
    final queued = await fixture.queue();
    final result = await V2StableAdapter(
      db: fixture.db,
      dio: fixture.dio,
    ).send(queued);
    expect(result.status, StableMutationStatus.acknowledged);
    expect(
      await fixture.db.pendingOperationsDao.transitionState(
        operationId: queued.id,
        from: 'sending',
        to: 'committed',
      ),
      isTrue,
    );
    final now = DateTime.utc(2026, 10, 7);
    await fixture.db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: '00000000-0000-4000-8000-000000000099',
        pillId: pill,
        hour: 0,
        minute: 0,
        frequency: 'prn',
        isActive: const Value(false),
        createdAt: now,
        updatedAt: now,
      ),
    );

    await expectLater(result.applyReceipt!(), throwsA(isA<FormatException>()));
    expect(
      (await fixture.db.schedulesDao.getById(schedule))!.isActive,
      isFalse,
    );
    expect(
      (await fixture.db.migrationIssuesDao.getById(issue))!.resolutionState,
      'unresolved',
    );
  });

  test('repository refuses malformed or occupied server state', () async {
    final bodies = <Object?>[
      {'unexpected': <Object>[]},
      {
        'schedules': [
          {'id': 'different'},
        ],
      },
      {
        'schedules': [
          {..._exactEntity, 'deletedAt': '2026-10-07T01:00:00.000Z'},
        ],
      },
    ];
    for (final body in bodies) {
      final fixture = await _fixture(
        _Transport(loseFirstPost: false, initialGetBody: body),
      );
      expect(
        await fixture.repository.recoverLegacyPrn(
          localId: schedule,
          timeZone: 'Europe/Bucharest',
        ),
        isA<Err<Schedule>>(),
      );
      expect(await fixture.db.pendingOperationsDao.getForUser(user), isEmpty);
    }
  });

  test('repository refuses an unsynced parent without queuing', () async {
    final fixture = await _fixture(_Transport(loseFirstPost: false));
    await (fixture.db.update(fixture.db.pills)
          ..where((row) => row.id.equals(pill)))
        .write(const PillsCompanion(syncStatus: Value('pending')));
    expect(
      await fixture.repository.recoverLegacyPrn(
        localId: schedule,
        timeZone: 'Europe/Bucharest',
      ),
      isA<Err<Schedule>>(),
    );
    expect(await fixture.db.pendingOperationsDao.getForUser(user), isEmpty);
  });

  test('repository refuses aliases and prior stable intent', () async {
    final aliasFixture = await _fixture(_Transport(loseFirstPost: false));
    final now = DateTime.utc(2026, 10, 7);
    await aliasFixture.db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: '00000000-0000-4000-8000-000000000098',
        pillId: pill,
        hour: 1,
        minute: 0,
        frequency: 'daily',
        isActive: const Value(false),
        createdAt: now,
        updatedAt: now,
        serverId: const Value(schedule),
      ),
    );
    expect(
      await aliasFixture.repository.recoverLegacyPrn(
        localId: schedule,
        timeZone: 'Europe/Bucharest',
      ),
      isA<Err<Schedule>>(),
    );
    expect(
      await aliasFixture.db.pendingOperationsDao.getForUser(user),
      isEmpty,
    );

    final historyFixture = await _fixture(_Transport(loseFirstPost: false));
    await PendingOperationRepository(historyFixture.db).record(
      operation: const PendingOperationDraft(
        userId: user,
        operationType: 'schedule.update',
        entityType: 'schedule',
        entityLocalId: schedule,
        parentEntityType: 'pill',
        parentEntityLocalId: pill,
        payload: {
          'action': 'update',
          'data': <String, Object?>{'isActive': false},
        },
      ),
      applyProjection: () async {},
    );
    expect(
      await historyFixture.repository.recoverLegacyPrn(
        localId: schedule,
        timeZone: 'Europe/Bucharest',
      ),
      isA<Err<Schedule>>(),
    );
    expect(
      await historyFixture.db.pendingOperationsDao.getForUser(user),
      hasLength(1),
    );
  });

  test(
    'repository rechecks a changed issue before durable recording',
    () async {
      late AppDatabase db;
      final transport = _Transport(
        loseFirstPost: false,
        onFirstGet: () async {
          await (db.update(
            db.migrationIssues,
          )..where((row) => row.id.equals(issue))).write(
            const MigrationIssuesCompanion(resolutionState: Value('resolved')),
          );
        },
      );
      final fixture = await _fixture(transport);
      db = fixture.db;

      expect(
        await fixture.repository.recoverLegacyPrn(
          localId: schedule,
          timeZone: 'Europe/Bucharest',
        ),
        isA<Err<Schedule>>(),
      );
      expect(await db.pendingOperationsDao.getForUser(user), isEmpty);
    },
  );

  test('mismatched parent receipt leaves retained row inactive', () async {
    final transport = _Transport(
      loseFirstPost: false,
      responseEntity: {
        ..._exactEntity,
        'pillId': '00000000-0000-4000-8000-000000000088',
      },
    );
    final fixture = await _fixture(transport);
    final queued = await fixture.queue();
    final result = await V2StableAdapter(
      db: fixture.db,
      dio: fixture.dio,
    ).send(queued);

    expect(result.status, StableMutationStatus.uncertain);
    expect(result.safeErrorCode, 'LEGACY_PRN_RECOVERY_RECEIPT_MISMATCH');
    expect(result.applyReceipt, isNull);
    expect(
      (await fixture.db.schedulesDao.getById(schedule))!.isActive,
      isFalse,
    );
    expect(
      (await fixture.db.migrationIssuesDao.getById(issue))!.resolutionState,
      'unresolved',
    );
  });
}

Future<
  ({
    AppDatabase db,
    Dio dio,
    ScheduleRepositoryImpl repository,
    Future<PendingOperation> Function() queue,
  })
>
_fixture(_Transport transport) async {
  final db = AppDatabase(NativeDatabase.memory());
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
  dio.httpClientAdapter = transport;
  addTearDown(() async {
    dio.close(force: true);
    await db.close();
  });
  final now = DateTime.utc(2026, 10, 7);
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: user,
          email: 'owner@test.invalid',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: profile,
      userId: user,
      name: 'Person',
      createdAt: now,
      updatedAt: now,
      serverId: const Value(profile),
      syncStatus: const Value('synced'),
    ),
  );
  await db.pillsDao.upsert(
    PillsCompanion.insert(
      id: pill,
      profileId: profile,
      name: 'PRN',
      isPrn: const Value(true),
      createdAt: now,
      updatedAt: now,
      serverId: const Value(pillServer),
      syncStatus: const Value('synced'),
    ),
  );
  await db.schedulesDao.upsert(
    SchedulesCompanion.insert(
      id: schedule,
      pillId: pill,
      hour: 0,
      minute: 0,
      frequency: 'prn',
      isActive: const Value(false),
      createdAt: now,
      updatedAt: now,
    ),
  );
  await db.migrationIssuesDao.record(
    MigrationIssuesCompanion.insert(
      id: issue,
      userId: user,
      entityType: 'schedule',
      entityId: schedule,
      issueCode: 'invalid_schedule_frequency_days',
      snapshotJson: jsonEncode({
        'scheduleId': schedule,
        'frequency': 'prn',
        'frequencyDays': null,
        'isPrn': true,
      }),
      createdAt: now,
      updatedAt: now,
    ),
  );
  final repository = ScheduleRepositoryImpl(
    schedulesDao: db.schedulesDao,
    pillsDao: db.pillsDao,
    profilesDao: db.profilesDao,
    ledgerDao: db.medicationLedgerDao,
    migrationIssuesDao: db.migrationIssuesDao,
    pendingOperations: PendingOperationRepository(db),
    dio: dio,
    reconcileProjections: () async {},
  );
  Future<PendingOperation> queue() async {
    expect(
      await repository.recoverLegacyPrn(
        localId: schedule,
        timeZone: 'Europe/Bucharest',
      ),
      isA<Ok<Schedule>>(),
    );
    final operation = (await db.pendingOperationsDao.getForUser(user)).single;
    expect(
      await db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: 'queued',
        to: 'sending',
      ),
      isTrue,
    );
    return (await db.pendingOperationsDao.getById(operation.id))!;
  }

  return (db: db, dio: dio, repository: repository, queue: queue);
}

class _Transport implements HttpClientAdapter {
  _Transport({
    this.postStatus = 201,
    this.loseFirstPost = true,
    this.initialGetBody,
    this.onFirstGet,
    this.responseEntity,
  });
  final int postStatus;
  final bool loseFirstPost;
  final Object? initialGetBody;
  final Future<void> Function()? onFirstGet;
  final Map<String, Object?>? responseEntity;
  int gets = 0;
  int posts = 0;
  final postBodies = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      gets++;
      if (gets == 1) await onFirstGet?.call();
    }
    final body = options.method == 'GET'
        ? (posts == 0
              ? initialGetBody ?? {'schedules': <Object>[]}
              : {
                  'schedules': [responseEntity ?? _entity],
                })
        : responseEntity ?? _entity;
    if (options.method == 'POST') {
      posts++;
      postBodies.add(jsonEncode(options.data));
    }
    if (options.method == 'POST' && posts == 1 && loseFirstPost) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'fictional lost response',
      );
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      options.method == 'POST' ? postStatus : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  Map<String, Object?> get _entity => {
    'id': schedule,
    'pillId': pillServer,
    'hour': 0,
    'minute': 0,
    'frequency': 'prn',
    'frequencyDays': null,
    'isActive': true,
    'timeZone': 'Europe/Bucharest',
    'timeZoneStatus': 'known',
    'revision': '1',
    'deletedAt': null,
    'createdAt': '2026-10-07T00:00:00.000Z',
    'updatedAt': '2026-10-07T00:00:00.000Z',
  };
  @override
  void close({bool force = false}) {}
}

const _exactEntity = <String, Object?>{
  'id': schedule,
  'pillId': pillServer,
  'hour': 0,
  'minute': 0,
  'frequency': 'prn',
  'frequencyDays': null,
  'isActive': true,
  'timeZone': 'Europe/Bucharest',
  'timeZoneStatus': 'known',
  'revision': '1',
  'deletedAt': null,
};
