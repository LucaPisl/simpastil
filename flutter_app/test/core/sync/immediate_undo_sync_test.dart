import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import '../../helpers/care_recording_fixture.dart';

class MockDio extends Mock implements Dio {}

const serverOccurrenceId = '30000000-0000-4000-8000-000000000001';
const serverEventId = '30000000-0000-4000-8000-000000000002';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));
  Future<
    ({
      CareRecordingFixture f,
      CareRecordingReceipt take,
      CareRecordingReceipt undo,
      V2MedicationSyncAdapter adapter,
      SyncWriteScope scope,
      MockDio dio,
      List<Map<String, dynamic>> posts,
    })
  >
  fixture() async {
    final f = await CareRecordingFixture.create(
      connected: true,
      legacyStock: 10,
    );
    addTearDown(f.db.close);
    await (f.db.update(
      f.db.medicationOccurrences,
    )..where((r) => r.id.equals(f.occurrence.id))).write(
      const MedicationOccurrencesCompanion(serverId: Value(serverOccurrenceId)),
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
    final undo = await service.commit(await service.prepareUndo(take));
    final dio = MockDio();
    final posts = <Map<String, dynamic>>[];
    when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
      final data = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
      );
      posts.add(data);
      return Response(
        data: {'commandId': data['commandId']},
        requestOptions: RequestOptions(path: '/medication/commands'),
      );
    });
    return (
      f: f,
      take: take,
      undo: undo,
      adapter: V2MedicationSyncAdapter(db: f.db, dio: dio, writeScope: scope),
      scope: scope,
      dio: dio,
      posts: posts,
    );
  }

  Future<PendingOperation> operation(
    CareRecordingFixture f,
    String commandId,
  ) async => (await f.db.pendingOperationsDao.getByMutationId(
    f.workspace.context.ownerUserId,
    commandId,
  ))!;
  Future<void> mapTake(
    CareRecordingFixture f,
    SyncWriteScope scope,
    CareRecordingReceipt take,
  ) => scope.write(
    () => ComponentSyncMerger(f.db, writeScope: scope).merge(
      f.workspace.context.ownerUserId,
      SyncComponent.medication,
      [
        {
          'component': 'medication',
          'payload': {
            'kind': 'occurrenceEvent',
            'id': serverEventId,
            'occurrenceId': serverOccurrenceId,
            'commandId': take.event.commandId,
            'action': 'take',
            'fromState': 'pending',
            'toState': 'taken',
            'reversesEventId': null,
            'rebasesCommandId': null,
            'actualAt': take.event.actualAt!.toUtc().toIso8601String(),
            'actualTimeKnown': true,
            'note': null,
            'origin': 'native',
            'baseVersion': '0',
            'resultVersion': '1',
            'serverSequence': '1',
            'recordedAt': take.event.recordedAt.toUtc().toIso8601String(),
          },
        },
      ],
    ),
  );

  test(
    'pre-ack Undo waits, maps original receipt and sends strict server identity',
    () async {
      final t = await fixture();
      final f = t.f;
      final undo = await operation(f, t.undo.event.commandId);
      expect(
        (await t.adapter.send(undo)).status,
        MedicationMutationStatus.waitingForMapping,
      );
      expect(t.posts, isEmpty);
      expect(
        (await t.adapter.send(
          await operation(f, t.take.event.commandId),
        )).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(t.posts.single.containsKey('reversesEventId'), isFalse);
      expect(
        (await t.adapter.send(undo)).status,
        MedicationMutationStatus.waitingForMapping,
      );
      await mapTake(f, t.scope, t.take);
      expect(
        (await f.db.medicationLedgerDao.getOccurrenceById(
          f.occurrence.id,
        ))!.state,
        'pending',
      );
      expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 10);
      expect(
        (await t.adapter.send(undo)).status,
        MedicationMutationStatus.acknowledged,
      );
      final body = t.posts.last;
      expect(body['occurrenceId'], serverOccurrenceId);
      expect(body['reversesEventId'], serverEventId);
      expect(body.containsKey('targetState'), isFalse);
      final stored = await operation(f, t.undo.event.commandId);
      final payload = jsonDecode(stored.payloadJson) as Map;
      expect((payload['command'] as Map)['reversesEventId'], t.take.event.id);
      expect(
        (payload['resolvedCommand'] as Map)['reversesEventId'],
        serverEventId,
      );
    },
  );

  test(
    'changed mapped server head requires review before Undo dispatch',
    () async {
      final t = await fixture();
      final f = t.f;
      await t.adapter.send(await operation(f, t.take.event.commandId));
      await mapTake(f, t.scope, t.take);
      await f.db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: '30000000-0000-4000-8000-000000000003',
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          commandId: '30000000-0000-4000-8000-000000000004',
          serverId: const Value('30000000-0000-4000-8000-000000000003'),
          action: 'correct',
          fromState: 'taken',
          toState: 'skipped',
          origin: 'native',
          baseVersion: 1,
          resultVersion: 2,
          recordedAt: DateTime.utc(2026, 9, 30, 12),
        ),
      );
      final result = await t.adapter.send(
        await operation(f, t.undo.event.commandId),
      );
      expect(result.status, MedicationMutationStatus.conflict);
      expect(t.posts, hasLength(1));
      expect((await operation(f, t.undo.event.commandId)).state, 'conflict');
    },
  );

  test('timed-out original cannot release its dependent Undo', () async {
    final t = await fixture();
    final f = t.f;
    when(() => t.dio.post<dynamic>(any(), data: any(named: 'data'))).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/medication/commands'),
        type: DioExceptionType.receiveTimeout,
      ),
    );
    expect(
      (await t.adapter.send(await operation(f, t.take.event.commandId))).status,
      MedicationMutationStatus.retryable,
    );
    final undo = await operation(f, t.undo.event.commandId);
    expect(
      (await f.db.pendingOperationsDao.getReady(
        f.workspace.context.ownerUserId,
      )).map((o) => o.id),
      isNot(contains(undo.id)),
    );
    expect(
      (await t.adapter.send(undo)).status,
      MedicationMutationStatus.waitingForMapping,
    );
    verify(
      () => t.dio.post<dynamic>(any(), data: any(named: 'data')),
    ).called(1);
    expect(
      (await f.db.medicationLedgerDao.getOccurrenceById(
        f.occurrence.id,
      ))!.state,
      'pending',
    );
  });

  test(
    'a timed-out Undo retries its frozen request after the remote head advances',
    () async {
      final t = await fixture();
      final f = t.f;
      await t.adapter.send(await operation(f, t.take.event.commandId));
      await mapTake(f, t.scope, t.take);
      when(
        () => t.dio.post<dynamic>(any(), data: any(named: 'data')),
      ).thenAnswer((invocation) async {
        t.posts.add(
          Map<String, dynamic>.from(invocation.namedArguments[#data] as Map),
        );
        throw DioException(
          requestOptions: RequestOptions(path: '/medication/commands'),
          type: DioExceptionType.receiveTimeout,
        );
      });
      expect(
        (await t.adapter.send(
          await operation(f, t.undo.event.commandId),
        )).status,
        MedicationMutationStatus.retryable,
      );
      final firstBody = t.posts.last;
      var undo = await operation(f, t.undo.event.commandId);
      expect(undo.state, 'failedRetryable');
      await f.db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: '30000000-0000-4000-8000-000000000009',
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          commandId: '30000000-0000-4000-8000-000000000008',
          serverId: const Value('30000000-0000-4000-8000-000000000009'),
          action: 'correct',
          fromState: 'taken',
          toState: 'skipped',
          origin: 'native',
          baseVersion: 1,
          resultVersion: 2,
          recordedAt: DateTime.utc(2026, 9, 30, 12),
        ),
      );
      when(
        () => t.dio.post<dynamic>(any(), data: any(named: 'data')),
      ).thenAnswer((invocation) async {
        final data = Map<String, dynamic>.from(
          invocation.namedArguments[#data] as Map,
        );
        t.posts.add(data);
        return Response(
          data: {'commandId': data['commandId']},
          requestOptions: RequestOptions(path: '/medication/commands'),
        );
      });
      undo = await operation(f, t.undo.event.commandId);
      expect(
        (await t.adapter.send(undo)).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(t.posts.last, firstBody);
      expect((await operation(f, t.undo.event.commandId)).attemptCount, 2);
    },
  );
}
