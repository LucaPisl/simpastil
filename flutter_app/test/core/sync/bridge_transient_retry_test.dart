import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/sync/adapters/bridge_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _Dio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  late CareRecordingFixture f;
  late BridgeMedicationSyncAdapter adapter;
  late String commandId;
  late CareRecordingService service;
  late CareRecordingReceipt take;
  final posts = <Map<String, dynamic>>[];
  Object? Function(RequestOptions) behaviour = (_) => null;

  DioException failure(
    RequestOptions options,
    int? status, {
    Map<String, Object?>? error,
    Map<String, String> headers = const {},
  }) => DioException(
    requestOptions: options,
    type: status == null
        ? DioExceptionType.receiveTimeout
        : DioExceptionType.badResponse,
    response: status == null
        ? null
        : Response(
            requestOptions: options,
            statusCode: status,
            headers: Headers.fromMap({
              for (final e in headers.entries) e.key: [e.value],
            }),
            data: error == null ? null : {'error': error},
          ),
  );

  setUp(() async {
    posts.clear();
    behaviour = (_) => null;
    f = await CareRecordingFixture.create(connected: true, legacyStock: 4);
    addTearDown(f.db.close);
    await (f.db.update(
      f.db.profiles,
    )..where((r) => r.id.equals(f.person.id))).write(
      ProfilesCompanion(
        serverId: Value(f.person.id),
        syncStatus: const Value('synced'),
      ),
    );
    await (f.db.update(f.db.pills)..where((r) => r.id.equals(f.pill.id))).write(
      PillsCompanion(
        serverId: Value(f.pill.id),
        syncStatus: const Value('synced'),
      ),
    );
    await (f.db.update(
      f.db.schedules,
    )..where((r) => r.id.equals(f.occurrence.scheduleId!))).write(
      SchedulesCompanion(
        serverId: Value(f.occurrence.scheduleId),
        syncStatus: const Value('synced'),
      ),
    );
    await (f.db.update(
      f.db.medicationOccurrences,
    )..where((r) => r.id.equals(f.occurrence.id))).write(
      MedicationOccurrencesCompanion(serverId: Value(f.occurrence.id)),
    );
    final context = f.workspace.context;
    final dio = _Dio();
    when(
      () => dio.post<dynamic>(
        '/medication/bridge/commands',
        data: any(named: 'data'),
      ),
    ).thenAnswer((invocation) async {
      final request = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
      );
      posts.add(request);
      final options = RequestOptions(path: '/medication/bridge/commands');
      final outcome = behaviour(options);
      if (outcome is DioException) throw outcome;
      return Response<dynamic>(
        requestOptions: options,
        data: {'commandId': request['commandId'], 'pillRevision': '2'},
      );
    });
    adapter = BridgeMedicationSyncAdapter(
      db: f.db,
      dio: dio,
      bridgeUndo: true,
      writeScope: SyncWriteScope(
        access: f.workspace.access,
        capability: NetworkCapability(
          ownerId: context.ownerUserId,
          endpoint: context.endpoint!,
          epoch: context.networkEpoch!,
          generation: context.sessionGeneration!,
        ),
      ),
    );
    service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: context,
    );
    take = await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    commandId = take.event.commandId;
  });

  Future<PendingOperation> op() async => (await f.db.pendingOperationsDao
      .getByMutationId(f.workspace.context.ownerUserId, commandId))!;

  Future<void> elapseBackoff() => f.db
      .update(f.db.pendingOperations)
      .write(
        PendingOperationsCompanion(
          lastAttemptAt: Value(
            DateTime.now().toUtc().subtract(const Duration(days: 1)),
          ),
        ),
      );

  Future<List<PendingOperation>> readyNow() async =>
      (await f.db.pendingOperationsDao.getReady(
        f.workspace.context.ownerUserId,
        honorBackoff: true,
      )).where((operation) => operation.mutationId == commandId).toList();

  for (final entry in <String, int?>{
    'timeout without a response': null,
    '500': 500,
    '408': 408,
    '429': 429,
  }.entries) {
    test('${entry.key} retries with the identical command', () async {
      behaviour = (options) => failure(options, entry.value);
      final result = await adapter.send(await op());

      expect(result.status, MedicationMutationStatus.retryable);
      var row = await op();
      expect(row.state, 'failedRetryable');
      expect(row.attemptCount, 1);
      expect(await readyNow(), isEmpty, reason: 'inside the backoff window');

      behaviour = (_) => null;
      await elapseBackoff();
      final ready = await readyNow();
      expect(ready, hasLength(1));
      final second = await adapter.send(ready.single);

      expect(second.status, MedicationMutationStatus.acknowledged);
      expect(posts, hasLength(2));
      expect(posts.last, posts.first);
      row = await op();
      expect(row.state, 'committed');
      expect(row.attemptCount, 2);
    });
  }

  test('Retry-After is honored beyond the ladder step', () async {
    behaviour = (options) =>
        failure(options, 429, headers: {'retry-after': '7200'});
    await adapter.send(await op());
    final row = await op();
    expect(row.state, 'failedRetryable');
    final notBefore = row.lastAttemptAt!.add(const Duration(seconds: 30));
    expect(
      notBefore.isAfter(DateTime.now().add(const Duration(hours: 1))),
      isTrue,
    );
  });

  test('the attempt cap blocks with a review issue', () async {
    behaviour = (options) => failure(options, 500);
    await adapter.send(await op());
    await (f.db.update(
      f.db.pendingOperations,
    )).write(const PendingOperationsCompanion(attemptCount: Value(7)));
    await adapter.send(await op());

    final row = await op();
    expect(row.state, 'blocked');
    expect(row.safeErrorCode, 'SYNC_RETRY_EXHAUSTED');
    expect(
      (await f.db.select(f.db.migrationIssues).get()).map((i) => i.issueCode),
      contains('sync_retry_exhausted'),
    );
  });

  test('"awaiting reconciliation" 409 is blocked, not a conflict', () async {
    behaviour = (options) => failure(
      options,
      409,
      error: {
        'code': 'CONFLICT_REVISION',
        'message': 'Bridge command is awaiting reconciliation',
      },
    );

    final result = await adapter.send(await op());

    expect(result.status, MedicationMutationStatus.blocked);
    expect(result.safeErrorCode, 'SPLIT_RECONCILIATION_REQUIRED');
    expect((await op()).state, 'blocked');
  });

  test('any other 409 stays a conflict', () async {
    behaviour = (options) =>
        failure(options, 409, error: {'code': 'CONFLICT_REVISION'});
    final result = await adapter.send(await op());
    expect(result.status, MedicationMutationStatus.conflict);
    expect((await op()).state, 'conflict');
  });

  test('a crash while sending requeues a frozen bridge command', () async {
    behaviour = (options) => failure(options, 500);
    await adapter.send(await op());
    final id = (await op()).id;
    await (f.db.update(f.db.pendingOperations)
          ..where((row) => row.id.equals(id)))
        .write(const PendingOperationsCompanion(state: Value('sending')));

    final recovered = await f.db.pendingOperationsDao
        .recoverInterruptedOperations(userId: f.workspace.context.ownerUserId);

    expect(recovered, 1);
    expect((await op()).state, 'queued');
    behaviour = (_) => null;
    await adapter.send(await op());
    expect(posts.last, posts.first);
    expect((await op()).state, 'committed');
  });

  test('a crash while sending an undo requeues and replays it once', () async {
    await adapter.send(await op());
    expect((await op()).state, 'committed');
    final undo = await service.commit(await service.prepareUndo(take));
    final owner = f.workspace.context.ownerUserId;
    Future<PendingOperation> undoOp() async => (await f.db.pendingOperationsDao
        .getByMutationId(owner, undo.event.commandId))!;
    posts.clear();
    behaviour = (options) => failure(options, 500);
    await adapter.send(await undoOp());
    final id = (await undoOp()).id;
    // The process dies after the next claim, before any response.
    await (f.db.update(f.db.pendingOperations)
          ..where((row) => row.id.equals(id)))
        .write(const PendingOperationsCompanion(state: Value('sending')));

    expect(
      await f.db.pendingOperationsDao.recoverInterruptedOperations(
        userId: owner,
      ),
      1,
    );
    expect((await undoOp()).state, 'queued');
    behaviour = (_) => null;
    await adapter.send(await undoOp());

    expect(posts, hasLength(2));
    expect(posts.last, posts.first, reason: 'the replay is byte-identical');
    expect(posts.last['status'], 'pending');
    expect(posts.last['commandId'], undo.event.commandId);
    expect((await undoOp()).state, 'committed');
  });

  test(
    'a crashed bridge command without a frozen body stays blocked',
    () async {
      final id = (await op()).id;
      await (f.db.update(
        f.db.pendingOperations,
      )..where((row) => row.id.equals(id))).write(
        PendingOperationsCompanion(
          state: const Value('sending'),
          attemptCount: const Value(1),
          lastAttemptAt: Value(DateTime.now().toUtc()),
        ),
      );
      await f.db.pendingOperationsDao.recoverInterruptedOperations(
        userId: f.workspace.context.ownerUserId,
      );
      // Nothing proves what the server saw, so the next send blocks for review
      // and never posts.
      final result = await adapter.send(await op());
      expect(
        result.safeErrorCode,
        'MEDICATION_BRIDGE_REQUEST_EVIDENCE_REQUIRED',
      );
      expect((await op()).state, 'blocked');
      expect(posts, isEmpty);
    },
  );

  test(
    'Sync now makes retrying changes eligible without resetting attempts',
    () async {
      behaviour = (options) => failure(options, 500);
      await adapter.send(await op());
      expect(await readyNow(), isEmpty);

      final owner = f.workspace.context.ownerUserId;
      expect(await f.db.pendingOperationsDao.makeRetriesEligibleNow(owner), 1);

      final ready = await readyNow();
      expect(ready, hasLength(1));
      expect(ready.single.attemptCount, 1);
      expect(ready.single.state, 'failedRetryable');
    },
  );
}
