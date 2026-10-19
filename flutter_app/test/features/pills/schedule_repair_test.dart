import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/adapters/schedules_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';

const _userId = '00000000-0000-4000-8000-000000000001';
const _profileId = '00000000-0000-4000-8000-000000000002';
const _pillId = '00000000-0000-4000-8000-000000000003';
const _scheduleId = '00000000-0000-4000-8000-000000000004';
const _issueId = '00000000-0000-4000-8000-000000000005';
const _pillServerId = '00000000-0000-4000-8000-000000000013';
const _scheduleServerId = '00000000-0000-4000-8000-000000000014';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late Dio dio;
  late _ScheduleRepairAdapter adapter;
  late ScheduleRepositoryImpl repository;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 9, 25);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: _userId,
            email: 'repair@test.invalid',
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
        serverId: const Value(_pillServerId),
        syncStatus: const Value('synced'),
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: _scheduleId,
        pillId: _pillId,
        hour: 8,
        minute: 0,
        frequency: 'daily',
        createdAt: now,
        updatedAt: now,
        serverId: const Value(_scheduleServerId),
        revision: const Value(1),
        syncStatus: const Value('synced'),
      ),
    );
    await db.migrationIssuesDao.record(
      MigrationIssuesCompanion.insert(
        id: _issueId,
        userId: _userId,
        entityType: 'schedule',
        entityId: _scheduleServerId,
        issueCode: 'schedule_timezone_review_required',
        snapshotJson: '{}',
        createdAt: now,
        updatedAt: now,
        serverId: const Value(_issueId),
      ),
    );

    dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
    adapter = _ScheduleRepairAdapter();
    dio.httpClientAdapter = adapter;
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

  Future<Result<Schedule>> repair() => repository.repair(
    localId: _scheduleId,
    issueId: _issueId,
    expectedIssueRevision: 1,
    hour: 9,
    minute: 15,
    frequency: 'custom',
    frequencyDays: const [1, 3],
    isActive: true,
    effectiveFromLocalDate: DateTime(2026, 9, 26),
    timeZone: 'Europe/Bucharest',
  );

  test(
    'sends revisioned repair and keeps the issue until account sync',
    () async {
      final result = await repair();

      expect(result, isA<Ok<Schedule>>());
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(
        request.path,
        '/pills/$_pillServerId/schedules/$_scheduleServerId/repair',
      );
      final body = request.data as Map<String, dynamic>;
      expect(body.keys.toSet(), {
        'mutationId',
        'baseRevision',
        'effectiveFromLocalDate',
        'schedule',
      });
      expect(
        body['mutationId'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(body['baseRevision'], '1');
      expect(body['effectiveFromLocalDate'], '2026-09-26');
      expect(body['schedule'], {
        'hour': 9,
        'minute': 15,
        'frequency': 'custom',
        'frequencyDays': [1, 3],
        'isActive': true,
        'timeZone': 'Europe/Bucharest',
      });
      expect((await db.schedulesDao.getById(_scheduleId))?.hour, 9);
      expect((await db.schedulesDao.getById(_scheduleId))?.revision, 2);
      final issue = await db.migrationIssuesDao.getById(_issueId);
      expect(issue?.revision, 1);
      expect(issue?.resolutionState, 'unresolved');
    },
  );

  test('retries identical repair with the same mutation identity', () async {
    adapter.loseResponse = true;
    expect(await repair(), isA<Err<Schedule>>());
    adapter.loseResponse = false;
    expect(await repair(), isA<Ok<Schedule>>());

    expect(adapter.requests, hasLength(2));
    final first = adapter.requests.first.data as Map<String, dynamic>;
    final second = adapter.requests.last.data as Map<String, dynamic>;
    expect(second['mutationId'], first['mutationId']);
  });

  test(
    'server-shaped routine issue applies verified receipt but keeps review until pull',
    () async {
      await (db.update(
        db.migrationIssues,
      )..where((row) => row.id.equals(_issueId))).write(
        const MigrationIssuesCompanion(entityType: Value('schedules')),
      );
      final beforeIssue = await db.migrationIssuesDao.getById(_issueId);

      expect(await repair(), isA<Ok<Schedule>>());
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.path,
        '/pills/$_pillServerId/schedules/$_scheduleServerId/repair',
      );
      final body = adapter.requests.single.data as Map<String, dynamic>;
      expect(body['baseRevision'], '1');
      expect((body['schedule'] as Map)['timeZone'], 'Europe/Bucharest');
      expect((await db.schedulesDao.getById(_scheduleId))?.revision, 2);
      expect(await db.migrationIssuesDao.getById(_issueId), beforeIssue);
    },
  );

  test('stale issue revision is rejected without sending a request', () async {
    await (db.update(db.migrationIssues)
          ..where((row) => row.id.equals(_issueId)))
        .write(const MigrationIssuesCompanion(revision: Value(2)));

    final result = await repair();

    expect(result, isA<Err<Schedule>>());
    expect((result as Err<Schedule>).error, isA<ConflictError>());
    expect(adapter.requests, isEmpty);
  });

  Future<PendingOperation> rejected({
    String state = 'conflict',
    String code = 'SCHEDULE_TIMEZONE_REVIEW_REQUIRED',
  }) async {
    final recorded = await PendingOperationRepository(db).record(
      operation: const PendingOperationDraft(
        userId: _userId,
        operationType: 'schedule.update',
        entityType: 'schedule',
        entityLocalId: _scheduleId,
        parentEntityType: 'pill',
        parentEntityLocalId: _pillId,
        payload: {
          'action': 'update',
          'data': {
            'hour': 8,
            'minute': 0,
            'frequency': 'daily',
            'frequencyDays': null,
            'isActive': true,
            'timeZone': 'Europe/Bucharest',
          },
        },
      ),
      applyProjection: () async {
        await (db.update(db.schedules)..where((r) => r.id.equals(_scheduleId)))
            .write(const SchedulesCompanion(syncStatus: Value('pending')));
      },
    );
    await db.pendingOperationsDao.transitionState(
      operationId: recorded.operationId,
      from: 'queued',
      to: state,
      safeErrorCode: code,
    );
    return (await db.pendingOperationsDao.getById(recorded.operationId))!;
  }

  test(
    'review converts only a definitively rejected edit and preserves its evidence',
    () async {
      final original = await rejected();
      expect(await repair(), isA<Ok<Schedule>>());
      final saved = (await db.pendingOperationsDao.getById(original.id))!;
      expect(saved.mutationId, original.mutationId);
      expect(saved.state, 'committed');
      expect(saved.operationType, 'schedule.repair');
      final envelope =
          (jsonDecode(saved.payloadJson) as Map)['reviewedRepair'] as Map;
      expect(
        (envelope['originalOperation'] as Map)['payloadJson'],
        original.payloadJson,
      );
      expect(
        (await db.schedulesDao.getById(_scheduleId))?.syncStatus,
        'synced',
      );
      expect(
        (await db.migrationIssuesDao.getById(_issueId))?.resolutionState,
        'unresolved',
      );
      expect(
        (adapter.requests.single.data as Map)['mutationId'],
        original.mutationId,
      );
    },
  );

  for (final state in ['sending', 'blocked', 'queued']) {
    test('$state ordinary edit cannot become a repair', () async {
      final original = await rejected(state: state);
      expect(await repair(), isA<Err<Schedule>>());
      expect(adapter.requests, isEmpty);
      expect(await db.pendingOperationsDao.getById(original.id), original);
    });
  }
  test('generic conflict cannot become a repair', () async {
    await rejected(code: 'CONFLICT_REVISION');
    expect(await repair(), isA<Err<Schedule>>());
    expect(adapter.requests, isEmpty);
  });
  test(
    'process restart replays frozen repair but does not replay ordinary sending edits',
    () async {
      await rejected();
      adapter.loseResponse = true;
      expect(await repair(), isA<Err<Schedule>>());
      final operation = (await db.pendingOperationsDao.getForUser(
        _userId,
      )).single;
      expect(operation.state, 'failedRetryable');
      await db.pendingOperationsDao.transitionState(
        operationId: operation.id,
        from: 'failedRetryable',
        to: 'sending',
      );
      expect(
        await db.pendingOperationsDao.recoverInterruptedOperations(
          userId: _userId,
        ),
        1,
      );
      adapter.loseResponse = false;
      await SchedulesSyncAdapter(
        db,
      ).flush(_userId, V2StableAdapter(db: db, dio: dio));
      expect(
        (await db.pendingOperationsDao.getById(operation.id))?.state,
        'committed',
      );
      expect(adapter.requests.last.data, adapter.requests.first.data);
    },
  );
  test(
    'mismatching receipt never commits or updates the local schedule',
    () async {
      final before = await db.schedulesDao.getById(_scheduleId);
      adapter.wrongReceipt = true;
      expect(await repair(), isA<Err<Schedule>>());
      expect(
        (await db.pendingOperationsDao.getForUser(_userId)).single.state,
        'blocked',
      );
      expect(await db.schedulesDao.getById(_scheduleId), before);
    },
  );
  test(
    'receipt retains a newer edit and advances its base revision atomically',
    () async {
      adapter.beforeResponse = () async {
        await PendingOperationRepository(db).record(
          operation: const PendingOperationDraft(
            userId: _userId,
            operationType: 'schedule.update',
            entityType: 'schedule',
            entityLocalId: _scheduleId,
            parentEntityType: 'pill',
            parentEntityLocalId: _pillId,
            payload: {
              'action': 'update',
              'data': {'hour': 12},
            },
          ),
          applyProjection: () async {
            await (db.update(
              db.schedules,
            )..where((r) => r.id.equals(_scheduleId))).write(
              const SchedulesCompanion(
                hour: Value(12),
                syncStatus: Value('pending'),
              ),
            );
          },
        );
      };
      expect(await repair(), isA<Ok<Schedule>>());
      final schedule = (await db.schedulesDao.getById(_scheduleId))!;
      expect(schedule.hour, 12);
      expect(schedule.revision, 2);
      expect(schedule.syncStatus, 'pending');
    },
  );

  test(
    'protected owner capability authorizes and commits the same durable path',
    () async {
      final f = await ProtectedWorkspaceFixture.create(
        ownerId: _userId,
        database: db,
      );
      repository = ScheduleRepositoryImpl(
        schedulesDao: db.schedulesDao,
        pillsDao: db.pillsDao,
        profilesDao: db.profilesDao,
        ledgerDao: db.medicationLedgerDao,
        migrationIssuesDao: db.migrationIssuesDao,
        pendingOperations: PendingOperationRepository(
          db,
          access: f.access,
          context: f.context,
        ),
        dio: dio,
        reconcileProjections: () async {},
      );
      expect(await repair(), isA<Ok<Schedule>>());
      expect(
        (await db.pendingOperationsDao.getForUser(_userId)).single.state,
        'committed',
      );
    },
  );

  test(
    'a second review cannot replace an unconfirmed frozen request',
    () async {
      adapter.loseResponse = true;
      expect(await repair(), isA<Err<Schedule>>());
      final frozen = (await db.pendingOperationsDao.getForUser(_userId)).single;
      adapter.loseResponse = false;
      final changed = await repository.repair(
        localId: _scheduleId,
        issueId: _issueId,
        expectedIssueRevision: 1,
        hour: 10,
        minute: 15,
        frequency: 'daily',
        frequencyDays: null,
        isActive: true,
        effectiveFromLocalDate: DateTime(2026, 9, 27),
        timeZone: 'Europe/Bucharest',
      );
      expect(changed, isA<Err<Schedule>>());
      expect(adapter.requests, hasLength(1));
      expect(await db.pendingOperationsDao.getById(frozen.id), frozen);
    },
  );

  for (final pending in [false, true]) {
    test(
      'delayed repair receipt never rewinds revision 3 (pending=$pending)',
      () async {
        adapter.beforeResponse = () async {
          await (db.update(
            db.schedules,
          )..where((r) => r.id.equals(_scheduleId))).write(
            SchedulesCompanion(
              revision: const Value(3),
              hour: const Value(14),
              timeZone: const Value('Europe/Bucharest'),
              timeZoneStatus: const Value('known'),
              syncStatus: Value(pending ? 'pending' : 'synced'),
            ),
          );
        };
        expect(await repair(), isA<Ok<Schedule>>());
        final schedule = (await db.schedulesDao.getById(_scheduleId))!;
        expect(schedule.revision, 3);
        expect(schedule.hour, 14);
        expect(schedule.syncStatus, pending ? 'pending' : 'synced');
        expect(
          (await db.pendingOperationsDao.getForUser(_userId)).single.state,
          'committed',
        );
      },
    );
  }

  test(
    'as-needed repair accepts a verified receipt without creating dose effects',
    () async {
      final result = await repository.repair(
        localId: _scheduleId,
        issueId: _issueId,
        expectedIssueRevision: 1,
        hour: 9,
        minute: 0,
        frequency: 'prn',
        frequencyDays: null,
        isActive: false,
        effectiveFromLocalDate: DateTime(2026, 9, 26),
        timeZone: 'Europe/Bucharest',
      );
      expect(result, isA<Ok<Schedule>>());
      final schedule = (await db.schedulesDao.getById(_scheduleId))!;
      expect(schedule.frequency, 'prn');
      expect(schedule.frequencyDays, isNull);
      expect(schedule.isActive, isFalse);
      final operation = (await db.pendingOperationsDao.getForUser(
        _userId,
      )).single;
      expect(operation.state, 'committed');
      expect(await db.pendingOperationsDao.getEffects(operation.id), isEmpty);
      expect(await db.select(db.occurrenceEvents).get(), isEmpty);
    },
  );

  test('server conflict preserves the unresolved repair issue', () async {
    adapter.statusCode = 409;

    final result = await repair();

    expect(result, isA<Err<Schedule>>());
    expect((result as Err<Schedule>).error, isA<ConflictError>());
    final issue = await db.migrationIssuesDao.getById(_issueId);
    expect(issue?.revision, 1);
    expect(issue?.resolutionState, 'unresolved');
  });
}

class _ScheduleRepairAdapter implements HttpClientAdapter {
  int statusCode = 200;
  bool loseResponse = false;
  bool wrongReceipt = false;
  Future<void> Function()? beforeResponse;
  final requests = <({String method, String path, Object? data})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final rawData = options.data;
    requests.add((
      method: options.method,
      path: options.path,
      data: rawData is String ? jsonDecode(rawData) : rawData,
    ));
    await beforeResponse?.call();
    if (loseResponse) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      );
    }
    final request = requests.last.data as Map;
    final body = statusCode == 200
        ? jsonEncode({
            'id': _scheduleServerId,
            'pillId': _pillServerId,
            'revision': '2',
            'deletedAt': null,
            'timeZoneStatus': 'known',
            'materializeFromLocalDate': request['effectiveFromLocalDate'],
            ...request['schedule'] as Map,
            if (wrongReceipt) 'minute': 59,
          })
        : '{"error":{"code":"CONFLICT_REVISION"}}';
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
