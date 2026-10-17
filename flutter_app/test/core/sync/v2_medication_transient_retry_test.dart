import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _MockDio extends Mock implements Dio {}

const _serverOccurrenceId = '30000000-0000-4000-8000-000000000011';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  late CareRecordingFixture f;
  late V2MedicationSyncAdapter adapter;
  late _MockDio dio;
  late String commandId;
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
    f = await CareRecordingFixture.create(connected: true, legacyStock: 10);
    addTearDown(f.db.close);
    await (f.db.update(
      f.db.medicationOccurrences,
    )..where((r) => r.id.equals(f.occurrence.id))).write(
      const MedicationOccurrencesCompanion(
        serverId: Value(_serverOccurrenceId),
      ),
    );
    final context = f.workspace.context;
    final scope = SyncWriteScope(
      access: f.workspace.access,
      capability: NetworkCapability(
        ownerId: context.ownerUserId,
        endpoint: context.endpoint!,
        epoch: context.networkEpoch!,
        generation: context.sessionGeneration!,
      ),
    );
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: context,
    );
    final take = await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    commandId = take.event.commandId;
    dio = _MockDio();
    when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
      final data = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
      );
      posts.add(data);
      final options = RequestOptions(path: '/medication/commands');
      final outcome = behaviour(options);
      if (outcome is DioException) throw outcome;
      return Response(
        data: {'commandId': data['commandId']},
        requestOptions: options,
      );
    });
    behaviour = (_) => null;
    adapter = V2MedicationSyncAdapter(db: f.db, dio: dio, writeScope: scope);
  });

  Future<PendingOperation> op() async => (await f.db.pendingOperationsDao
      .getByMutationId(f.workspace.context.ownerUserId, commandId))!;

  Future<void> elapseBackoff() async {
    await (f.db.update(f.db.pendingOperations)).write(
      PendingOperationsCompanion(
        lastAttemptAt: Value(
          DateTime.now().toUtc().subtract(const Duration(days: 1)),
        ),
      ),
    );
  }

  Future<List<PendingOperation>> readyNow() async =>
      (await f.db.pendingOperationsDao.getReady(
        f.workspace.context.ownerUserId,
        honorBackoff: true,
      )).where((operation) => operation.mutationId == commandId).toList();

  Future<MedicationMutationResult> sendReady() async {
    final ready = await readyNow();
    expect(ready, hasLength(1));
    return adapter.send(ready.single);
  }

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
      final second = await sendReady();

      expect(second.status, MedicationMutationStatus.acknowledged);
      expect(posts, hasLength(2));
      expect(posts.last, posts.first);
      expect(posts.last['commandId'], commandId);
      row = await op();
      expect(row.state, 'committed');
      expect(row.attemptCount, 2);
    });
  }

  test('the attempt cap blocks with a review issue', () async {
    behaviour = (options) => failure(options, 500);
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

  test(
    'a crash while sending requeues and replays the frozen command',
    () async {
      behaviour = (options) => failure(options, 500);
      await adapter.send(await op());
      final id = (await op()).id;
      await (f.db.update(f.db.pendingOperations)
            ..where((row) => row.id.equals(id)))
          .write(const PendingOperationsCompanion(state: Value('sending')));

      final recovered = await f.db.pendingOperationsDao
          .recoverInterruptedOperations(
            userId: f.workspace.context.ownerUserId,
          );

      expect(recovered, 1);
      expect((await op()).state, 'queued');
      behaviour = (_) => null;
      await adapter.send(await op());
      expect(posts.last, posts.first);
      expect((await op()).state, 'committed');
    },
  );

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
}
