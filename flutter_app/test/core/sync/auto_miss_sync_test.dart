import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/auto_miss_discard.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _MockDio extends Mock implements Dio {}

const _serverOccurrenceId = '30000000-0000-4000-8000-000000000021';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  late CareRecordingFixture f;
  late SyncWriteScope scope;
  late MedicationRepository repository;
  late String owner;
  late String missId;
  final posts = <Map<String, dynamic>>[];
  Object? Function(RequestOptions) behaviour = (_) => null;

  DioException refusal(RequestOptions options, int status, String code) =>
      DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: options,
          statusCode: status,
          data: {
            'error': {'code': code, 'retryable': false},
          },
        ),
      );

  setUp(() async {
    posts.clear();
    behaviour = (_) => null;
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
    owner = context.ownerUserId;
    scope = SyncWriteScope(
      access: f.workspace.access,
      capability: NetworkCapability(
        ownerId: owner,
        endpoint: context.endpoint!,
        epoch: context.networkEpoch!,
        generation: context.sessionGeneration!,
      ),
    );
    repository = MedicationRepository(
      f.db,
      access: f.workspace.access,
      context: context,
    );
    missId = autoMissCommandId(
      ownerUserId: owner,
      occurrenceKey: f.occurrence.occurrenceKey,
    );
    await repository.apply(
      userId: owner,
      occurrenceId: f.occurrence.id,
      action: MedicationAction.miss,
      actualTimeKnown: false,
      commandIdOverride: missId,
    );
  });

  V2MedicationSyncAdapter adapter() {
    final dio = _MockDio();
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
    return V2MedicationSyncAdapter(db: f.db, dio: dio, writeScope: scope);
  }

  Future<PendingOperation> op() async =>
      (await f.db.pendingOperationsDao.getByMutationId(owner, missId))!;

  Future<MedicationOccurrence> occurrence() async =>
      (await f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id))!;

  test('sends the miss as a plain action and commits it', () async {
    final result = await adapter().send(await op());

    expect(result.status, MedicationMutationStatus.acknowledged);
    expect(posts.single['action'], 'miss');
    expect(posts.single['baseVersion'], '0');
    expect(posts.single['occurrenceId'], _serverOccurrenceId);
    expect(posts.single.containsKey('targetState'), isFalse);
    expect(posts.single['actualAt'], isNull);
    expect(posts.single['actualTimeKnown'], isFalse);
    expect(posts.single.containsKey('origin'), isFalse);
    expect((await op()).state, 'committed');
    expect((await occurrence()).state, 'missed');
  });

  for (final entry in <int, String>{
    409: 'CONFLICT_STALE_UPDATE',
    422: 'MISS_NOT_ALLOWED',
  }.entries) {
    test('${entry.key} drops the miss without a review item', () async {
      behaviour = (options) => refusal(options, entry.key, entry.value);
      await f.db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: owner,
          component: 'medication',
          contractVersion: 3,
          lastCompletedCursor: const Value('5'),
          lastFullSuccessAt: Value(DateTime.now().toUtc()),
          currentState: const Value('idle'),
        ),
      );

      final result = await adapter().send(await op());

      expect(result.status, MedicationMutationStatus.discarded);
      expect(result.safeErrorCode, autoMissNotAppliedCode);
      final row = await op();
      expect(row.state, 'discarded');
      expect(row.safeErrorCode, autoMissNotAppliedCode);
      final restored = await occurrence();
      expect(restored.state, 'pending');
      expect(restored.stateVersion, 0);
      expect(await f.db.select(f.db.migrationIssues).get(), isEmpty);
      final states = await f.db.select(f.db.syncComponentStates).get();
      expect(states.where((state) => state.userId == owner), isNotEmpty);
      expect(
        states
            .where((state) => state.userId == owner)
            .every((state) => state.lastCompletedCursor == null),
        isTrue,
        reason: 'the next pull replays the server record',
      );
    });
  }

  test('a refusal carrying the miss-specific code drops the miss', () async {
    behaviour = (options) => refusal(options, 400, 'MISS_NOT_ALLOWED');

    final result = await adapter().send(await op());

    expect(result.status, MedicationMutationStatus.discarded);
    expect((await op()).state, 'discarded');
    expect((await occurrence()).state, 'pending');
  });

  for (final entry in <int, String>{
    403: 'FORBIDDEN',
    404: 'NOT_FOUND',
    400: 'VALIDATION_ERROR',
  }.entries) {
    test('${entry.key} is not a verdict on the miss and keeps it', () async {
      behaviour = (options) => refusal(options, entry.key, entry.value);

      final result = await adapter().send(await op());

      expect(result.status, MedicationMutationStatus.blocked);
      expect(result.safeErrorCode, entry.value);
      final row = await op();
      expect(row.state, 'blocked');
      expect(row.safeErrorCode, entry.value);
      expect((await occurrence()).state, 'missed');
    });
  }

  for (final status in [408, 429]) {
    test('$status retries the miss with the same command', () async {
      behaviour = (options) => refusal(options, status, 'RATE_LIMITED');

      final result = await adapter().send(await op());

      expect(result.status, MedicationMutationStatus.retryable);
      final row = await op();
      expect(row.state, 'failedRetryable');
      expect(row.mutationId, missId);
      expect((await occurrence()).state, 'missed');
    });
  }

  test('401 keeps the miss and asks for sign-in again', () async {
    behaviour = (options) => refusal(options, 401, 'UNAUTHORIZED');

    await expectLater(adapter().send(await op()), throwsA(isA<DioException>()));

    expect((await op()).state, 'failedRetryable');
    expect((await occurrence()).state, 'missed');
  });

  test('a transient failure keeps the miss for a retry', () async {
    behaviour = (options) => refusal(options, 503, 'UNAVAILABLE');

    final result = await adapter().send(await op());

    expect(result.status, MedicationMutationStatus.retryable);
    expect((await op()).state, 'failedRetryable');
    expect((await occurrence()).state, 'missed');
  });

  test(
    'a discarded miss is never swept again for the same occurrence',
    () async {
      behaviour = (options) => refusal(options, 409, 'CONFLICT_STALE_UPDATE');
      await adapter().send(await op());

      // The same deterministic command replays the discarded one: no second
      // operation, no second miss.
      final replay = await repository.apply(
        userId: owner,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.miss,
        actualTimeKnown: false,
        commandIdOverride: missId,
      );

      expect(replay.commandId, missId);
      expect(
        (await f.db.pendingOperationsDao.getForUser(
          owner,
        )).where((operation) => operation.component == 'medication'),
        hasLength(1),
      );
      expect((await occurrence()).state, 'pending');
    },
  );

  group('through the sync service', () {
    SyncService service({
      required int medicationCommands,
      required bool recordedMiss,
    }) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/capabilities') {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  data: {
                    'apiNamespace': 'v1',
                    'contracts': {
                      'componentSync': 2,
                      'legacySplitReconciliation': 1,
                      'medicationBridgeCommands': 1,
                      'medicationBridgeSync': 1,
                      'fractionalStock': 1,
                      'medicationCommands': medicationCommands,
                    },
                    'medicationLedgerActive': true,
                    if (recordedMiss) 'recordedMiss': true,
                    'minimumClientBuild': 1,
                    'serverRelease': 'fictional',
                  },
                ),
              );
              return;
            }
            if (options.path.endsWith('/medication/commands')) {
              posts.add(Map<String, dynamic>.from(options.data as Map));
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  data: {'commandId': (options.data as Map)['commandId']},
                ),
              );
              return;
            }
            final component = options.path.split('/').last;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                data: {
                  'component': component,
                  'contractVersion': 2,
                  'afterSequence': '0',
                  'throughSequence': '0',
                  'hasMore': false,
                  'nextCursor': null,
                  'items': <Object>[],
                },
              ),
            );
          },
        ),
      );
      return SyncService(
        db: f.db,
        dio: dio,
        isOnline: () async => true,
        writeScope: scope,
      );
    }

    test('a server without recorded misses never receives one', () async {
      await service(
        medicationCommands: 2,
        recordedMiss: false,
      ).flushPending(userId: owner);

      expect(posts, isEmpty);
      final row = await op();
      expect(row.state, 'discarded');
      expect(row.safeErrorCode, autoMissNotAppliedCode);
      expect((await occurrence()).state, 'pending');
      expect(await f.db.select(f.db.migrationIssues).get(), isEmpty);
    });

    test('a server that records misses receives the command', () async {
      await service(
        medicationCommands: 3,
        recordedMiss: true,
      ).flushPending(userId: owner);

      expect(posts.map((p) => p['action']), ['miss']);
      expect((await op()).state, 'committed');
      expect((await occurrence()).state, 'missed');
    });
  });
}
