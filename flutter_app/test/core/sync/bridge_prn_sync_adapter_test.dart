import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/sync/adapters/bridge_prn_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';

class _Dio extends Mock implements Dio {}

Future<
  ({
    CareRecordingFixture f,
    CareRecordingService writer,
    BridgePrnSyncAdapter adapter,
    _Dio dio,
  })
>
_fixture() async {
  final f = await CareRecordingFixture.create(connected: true, legacyStock: 4);
  addTearDown(f.db.close);
  await (f.db.delete(
    f.db.medicationOccurrences,
  )..where((o) => o.id.equals(f.occurrence.id))).go();
  await (f.db.update(
    f.db.profiles,
  )..where((p) => p.id.equals(f.person.id))).write(
    ProfilesCompanion(
      serverId: Value(f.person.id),
      syncStatus: const Value('synced'),
    ),
  );
  await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
    PillsCompanion(
      serverId: Value(f.pill.id),
      isPrn: const Value(true),
      syncStatus: const Value('synced'),
    ),
  );
  await (f.db.update(
    f.db.schedules,
  )..where((s) => s.id.equals(f.occurrence.scheduleId!))).write(
    SchedulesCompanion(
      serverId: Value(f.occurrence.scheduleId),
      frequency: const Value('prn'),
      timeZone: const Value('Europe/Bucharest'),
      timeZoneStatus: const Value('known'),
      syncStatus: const Value('synced'),
    ),
  );
  final c = f.workspace.context;
  final scope = SyncWriteScope(
    access: f.workspace.access,
    capability: NetworkCapability(
      ownerId: c.ownerUserId,
      endpoint: c.endpoint!,
      epoch: c.networkEpoch!,
      generation: c.sessionGeneration!,
    ),
  );
  final dio = _Dio();
  return (
    f: f,
    writer: CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: c,
    ),
    adapter: BridgePrnSyncAdapter(db: f.db, dio: dio, writeScope: scope),
    dio: dio,
  );
}

Future<CareRecordingReceipt> _record(
  CareRecordingFixture f,
  CareRecordingService writer,
) async => writer.commit(
  await writer.prepareConnectedPrn(
    personId: f.person.id,
    pillId: f.pill.id,
    sentinelId: f.occurrence.scheduleId!,
    reviewedLocalDate: '2026-09-30',
    amount: MedicationAmount.known('1/2', 'tablet'),
    actualAt: null,
    actualTimeKnown: false,
    note: 'Fictional note',
  ),
);
Map<String, Object?> _receipt(Map<String, dynamic> request) => {
  'commandId': request['commandId'],
  'occurrenceId': request['occurrenceId'],
  'occurrenceKey': request['occurrenceKey'],
  'eventId': request['eventId'],
  'action': request['operation'],
  'state': request['operation'] == 'take' ? 'taken' : 'pending',
  'stateVersion': request['operation'] == 'take' ? '1' : '2',
  'amount': request['amount'],
  'inventoryEventId': null,
  'inventoryDelta': null,
  'recordedAt': '2026-09-30T12:00:00.000Z',
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    tzdata.initializeTimeZones();
    registerFallbackValue(<String, Object?>{});
  });
  test(
    'first administration and exact Undo share without a planned time or stock conversion',
    () async {
      final x = await _fixture();
      final care = await _record(x.f, x.writer);
      final undo = await x.writer.commit(await x.writer.prepareUndo(care));
      final requests = <Map<String, dynamic>>[];
      when(
        () => x.dio.post<dynamic>(
          '/medication/bridge/prn/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final r = Map<String, dynamic>.from(i.namedArguments[#data] as Map);
        requests.add(r);
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: _receipt(r),
        );
      });
      final op = (await x.f.db.pendingOperationsDao.getByMutationId(
        x.f.workspace.context.ownerUserId,
        care.event.commandId,
      ))!;
      final undoOp = (await x.f.db.pendingOperationsDao.getByMutationId(
        op.userId,
        undo.event.commandId,
      ))!;
      expect(undoOp.dependsOnOperationId, op.id);
      expect(
        (await x.adapter.send(op)).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(requests.single['actualAt'], isNull);
      expect(requests.single['actualTimeKnown'], false);
      expect(requests.single['amount'], {
        'version': 1,
        'state': 'known',
        'quantity': '1/2',
        'unit': 'tablet',
      });
      expect(requests.single.containsKey('scheduledAt'), false);
      final readyUndo = (await x.f.db.pendingOperationsDao.getById(undoOp.id))!;
      expect(
        (await x.adapter.send(readyUndo)).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(requests.last['reversesEventId'], care.event.id);
      expect((await x.f.db.pillsDao.getById(x.f.pill.id))!.currentStock, 4);
      expect(await x.f.db.select(x.f.db.inventoryEvents).get(), isEmpty);
    },
  );
  test(
    'on an active ledger the receipt carries the stock move and its pill revision',
    () async {
      final x = await _fixture();
      final care = await _record(x.f, x.writer);
      final before = (await x.f.db.pillsDao.getById(x.f.pill.id))!;
      when(
        () => x.dio.post<dynamic>(
          '/medication/bridge/prn/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final r = Map<String, dynamic>.from(i.namedArguments[#data] as Map);
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: {
            ..._receipt(r),
            'inventoryEventId': '00000000-0000-4000-8000-0000000000aa',
            'inventoryDelta': -1,
            'currentStock': 3,
            'pillRevision': '${before.revision + 1}',
            'inventoryTracked': true,
          },
        );
      });
      final op = (await x.f.db.pendingOperationsDao.getByMutationId(
        x.f.workspace.context.ownerUserId,
        care.event.commandId,
      ))!;
      expect(
        (await x.adapter.send(op, ledgerActive: true)).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(
        (await x.f.db.pendingOperationsDao.getById(op.id))!.state,
        'committed',
      );
      expect(
        (await x.f.db.medicationLedgerDao.getOccurrenceById(
          care.event.occurrenceId,
        ))!.serverId,
        care.event.occurrenceId,
      );
      expect(
        (await x.f.db.pillsDao.getById(x.f.pill.id))!.revision,
        before.revision + 1,
      );
    },
  );

  test(
    'a stock-moving receipt is refused off the active ledger, and an active one must state tracking',
    () async {
      for (final (ledgerActive, extra) in [
        (
          false,
          <String, Object?>{
            'inventoryEventId': '00000000-0000-4000-8000-0000000000aa',
            'inventoryDelta': -1,
          },
        ),
        (true, <String, Object?>{}),
      ]) {
        final x = await _fixture();
        final care = await _record(x.f, x.writer);
        when(
          () => x.dio.post<dynamic>(
            '/medication/bridge/prn/commands',
            data: any(named: 'data'),
          ),
        ).thenAnswer((i) async {
          final r = Map<String, dynamic>.from(i.namedArguments[#data] as Map);
          return Response<dynamic>(
            requestOptions: RequestOptions(path: '/fictional'),
            data: {..._receipt(r), ...extra},
          );
        });
        final op = (await x.f.db.pendingOperationsDao.getByMutationId(
          x.f.workspace.context.ownerUserId,
          care.event.commandId,
        ))!;
        final result = await x.adapter.send(op, ledgerActive: ledgerActive);
        expect(result.safeErrorCode, 'PRN_RECEIPT_IDENTITY_MISMATCH');
        expect(
          (await x.f.db.pendingOperationsDao.getById(op.id))!.state,
          'blocked',
        );
      }
    },
  );

  test('missing PRN parents fail closed before transport', () async {
    final x = await _fixture();
    final care = await _record(x.f, x.writer);
    final op = (await x.f.db.pendingOperationsDao.getByMutationId(
      x.f.workspace.context.ownerUserId,
      care.event.commandId,
    ))!;
    await (x.f.db.update(x.f.db.medicationOccurrences)
          ..where((o) => o.id.equals(care.current.id)))
        .write(const MedicationOccurrencesCompanion(pillId: Value(null)));
    expect((await x.adapter.send(op)).safeErrorCode, 'PRN_IDENTITY_UNPROVEN');
    verifyNever(() => x.dio.post<dynamic>(any(), data: any(named: 'data')));
  });
  test('offline Undo must retain the exact take dependency', () async {
    final x = await _fixture();
    final care = await _record(x.f, x.writer);
    final undo = await x.writer.commit(await x.writer.prepareUndo(care));
    final takeOp = (await x.f.db.pendingOperationsDao.getByMutationId(
      x.f.workspace.context.ownerUserId,
      care.event.commandId,
    ))!;
    final undoOp = (await x.f.db.pendingOperationsDao.getByMutationId(
      takeOp.userId,
      undo.event.commandId,
    ))!;
    await (x.f.db.update(
      x.f.db.pendingOperations,
    )..where((o) => o.id.equals(undoOp.id))).write(
      const PendingOperationsCompanion(dependsOnOperationId: Value(null)),
    );
    expect(
      (await x.adapter.send(takeOp)).safeErrorCode,
      'PRN_CAUSAL_CHAIN_UNPROVEN',
    );
    verifyNever(() => x.dio.post<dynamic>(any(), data: any(named: 'data')));
  });
  test('stale or competing PRN heads are not transported', () async {
    final x = await _fixture();
    final care = await _record(x.f, x.writer);
    final op = (await x.f.db.pendingOperationsDao.getByMutationId(
      x.f.workspace.context.ownerUserId,
      care.event.commandId,
    ))!;
    await x.f.db.medicationLedgerDao.appendOccurrenceEvent(
      OccurrenceEventsCompanion.insert(
        id: '10000000-0000-4000-8000-000000000091',
        userId: op.userId,
        occurrenceId: care.current.id,
        commandId: '10000000-0000-4000-8000-000000000092',
        action: 'skip',
        fromState: 'taken',
        toState: 'skipped',
        origin: 'native',
        baseVersion: 1,
        resultVersion: 2,
        recordedAt: DateTime.utc(2026, 9, 30, 13),
      ),
    );
    await (x.f.db.update(
      x.f.db.medicationOccurrences,
    )..where((o) => o.id.equals(care.current.id))).write(
      const MedicationOccurrencesCompanion(
        state: Value('skipped'),
        stateVersion: Value(2),
      ),
    );
    expect(
      (await x.adapter.send(op)).safeErrorCode,
      'PRN_CAUSAL_CHAIN_UNPROVEN',
    );
    verifyNever(() => x.dio.post<dynamic>(any(), data: any(named: 'data')));
  });
  test(
    'lost response replays the frozen exact request and a mismatched receipt preserves care',
    () async {
      final x = await _fixture();
      final care = await _record(x.f, x.writer);
      final requests = <Map<String, dynamic>>[];
      when(
        () => x.dio.post<dynamic>(
          '/medication/bridge/prn/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final r = Map<String, dynamic>.from(i.namedArguments[#data] as Map);
        requests.add(r);
        if (requests.length == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: '/fictional'),
            type: DioExceptionType.receiveTimeout,
          );
        }
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: {
            ..._receipt(r),
            'eventId': '10000000-0000-4000-8000-000000000099',
          },
        );
      });
      final op = (await x.f.db.pendingOperationsDao.getByMutationId(
        x.f.workspace.context.ownerUserId,
        care.event.commandId,
      ))!;
      expect(
        (await x.adapter.send(op)).status,
        MedicationMutationStatus.retryable,
      );
      final retry = (await x.f.db.pendingOperationsDao.getById(op.id))!;
      expect(
        jsonDecode(retry.payloadJson)['phase1PrnRequest'],
        requests.single,
      );
      expect(
        (await x.adapter.send(retry)).status,
        MedicationMutationStatus.uncertain,
      );
      expect(requests[1], requests[0]);
      expect(
        (await x.f.db.pendingOperationsDao.getById(op.id))!.state,
        'blocked',
      );
      expect(
        (await x.f.db.medicationLedgerDao.getOccurrenceById(
          care.current.id,
        ))!.state,
        'taken',
      );
      expect(await x.f.db.select(x.f.db.occurrenceEvents).get(), hasLength(1));
    },
  );
  test('malformed retained PRN request is blocked without transport', () async {
    final x = await _fixture();
    final care = await _record(x.f, x.writer);
    when(
      () => x.dio.post<dynamic>(
        '/medication/bridge/prn/commands',
        data: any(named: 'data'),
      ),
    ).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/fictional'),
        type: DioExceptionType.receiveTimeout,
      ),
    );
    final operation = (await x.f.db.pendingOperationsDao.getByMutationId(
      x.f.workspace.context.ownerUserId,
      care.event.commandId,
    ))!;
    await x.adapter.send(operation);
    final retry = (await x.f.db.pendingOperationsDao.getById(operation.id))!;
    final payload = Map<String, dynamic>.from(
      jsonDecode(retry.payloadJson) as Map,
    )..['phase1PrnRequest'] = 'malformed';
    await (x.f.db.update(
      x.f.db.pendingOperations,
    )..where((row) => row.id.equals(retry.id))).write(
      PendingOperationsCompanion(payloadJson: Value(jsonEncode(payload))),
    );
    clearInteractions(x.dio);

    final result = await x.adapter.send(
      (await x.f.db.pendingOperationsDao.getById(retry.id))!,
    );

    expect(result.status, MedicationMutationStatus.blocked);
    expect(result.safeErrorCode, 'PRN_REQUEST_IDENTITY_MISMATCH');
    expect(
      (await x.f.db.pendingOperationsDao.getById(retry.id))!.state,
      'blocked',
    );
    verifyNever(() => x.dio.post<dynamic>(any(), data: any(named: 'data')));
  });
  test(
    'retained PRN retries cannot rewrite actual time, amount, or note evidence',
    () async {
      final mutations = <void Function(Map<String, dynamic>)>[
        (payload) {
          final request = payload['phase1PrnRequest'] as Map;
          final command = payload['command'] as Map;
          request['actualAt'] = '2026-09-30T10:00:00.000Z';
          request['actualTimeKnown'] = true;
          command['actualAt'] = '2026-09-30T10:00:00.000Z';
          command['actualTimeKnown'] = true;
        },
        (payload) {
          final changed = {
            'version': 1,
            'state': 'known',
            'quantity': '2',
            'unit': 'tablet',
          };
          (payload['phase1PrnRequest'] as Map)['amount'] = changed;
          payload['administrationAmount'] = changed;
        },
        (payload) {
          (payload['phase1PrnRequest'] as Map)['note'] = 'Changed';
          (payload['command'] as Map)['note'] = 'Changed';
        },
      ];
      for (final mutate in mutations) {
        final x = await _fixture();
        final care = await _record(x.f, x.writer);
        when(
          () => x.dio.post<dynamic>(
            '/medication/bridge/prn/commands',
            data: any(named: 'data'),
          ),
        ).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: '/fictional'),
            type: DioExceptionType.receiveTimeout,
          ),
        );
        final operation = (await x.f.db.pendingOperationsDao.getByMutationId(
          x.f.workspace.context.ownerUserId,
          care.event.commandId,
        ))!;
        await x.adapter.send(operation);
        final retry = (await x.f.db.pendingOperationsDao.getById(
          operation.id,
        ))!;
        final payload = Map<String, dynamic>.from(
          jsonDecode(retry.payloadJson) as Map,
        );
        mutate(payload);
        await (x.f.db.update(
          x.f.db.pendingOperations,
        )..where((row) => row.id.equals(retry.id))).write(
          PendingOperationsCompanion(payloadJson: Value(jsonEncode(payload))),
        );
        clearInteractions(x.dio);

        final result = await x.adapter.send(
          (await x.f.db.pendingOperationsDao.getById(retry.id))!,
        );

        expect(result.status, MedicationMutationStatus.blocked);
        expect(result.safeErrorCode, 'PRN_REQUEST_IDENTITY_MISMATCH');
        verifyNever(() => x.dio.post<dynamic>(any(), data: any(named: 'data')));
      }
    },
  );
  test(
    'bridge v5 pulls exact PRN amount and unknown time without inventing an author; v4 refuses',
    () async {
      final x = await _fixture();
      const occurrenceId = '10000000-0000-4000-8000-000000000080';
      const eventId = '10000000-0000-4000-8000-000000000081';
      const commandId = '10000000-0000-4000-8000-000000000082';
      final occurrence = {
        'schemaVersion': 2,
        'component': 'medicationBridge',
        'entityType': 'medication_occurrence',
        'entityId': occurrenceId,
        'operation': 'upsert',
        'sourceIdentity': {
          'sourceKind': 'occurrence',
          'sourceId': occurrenceId,
          'sourceRevision': '2',
        },
        'payload': {
          'kind': 'medicationOccurrence',
          'id': occurrenceId,
          'pillId': x.f.pill.id,
          'scheduleId': x.f.occurrence.scheduleId,
          'occurrenceKey': 'prn:v1:$occurrenceId',
          'source': 'prn',
          'provenance': 'exact',
          'scheduleRevision': '1',
          'plannedLocalDate': '2026-09-30',
          'plannedLocalTime': null,
          'plannedAt': null,
          'timeZone': 'Europe/Bucharest',
          'expected': false,
          'snapshotVersion': 1,
          'scheduleSnapshot': {
            'version': 1,
            'pillName': 'Fictional medication',
            'dosage': null,
            'frequency': 'prn',
            'frequencyDays': null,
            'hour': null,
            'minute': null,
            'timeZone': 'Europe/Bucharest',
            'profileId': x.f.person.id,
            'profileName': 'Fictional Alex',
          },
          'stateVersion': '1',
          'supersededAt': null,
          'supersededByOccurrenceId': null,
        },
      };
      final event = {
        'schemaVersion': 2,
        'component': 'medicationBridge',
        'entityType': 'occurrence_event',
        'entityId': eventId,
        'operation': 'upsert',
        'sourceIdentity': {
          'sourceKind': 'occurrence_event',
          'sourceId': eventId,
          'sourceRevision': '3',
        },
        'payload': {
          'kind': 'occurrenceEvent',
          'id': eventId,
          'occurrenceId': occurrenceId,
          'commandId': commandId,
          'action': 'take',
          'fromState': 'pending',
          'toState': 'taken',
          'baseVersion': '0',
          'resultVersion': '1',
          'actualAt': null,
          'actualTimeKnown': false,
          'administrationAmount': {
            'version': 1,
            'state': 'known',
            'quantity': '1/2',
            'unit': 'tablet',
          },
          'note': null,
          'origin': 'native',
          'serverSequence': '3',
          'recordedAt': '2026-09-30T12:00:00.000Z',
          'reversesEventId': null,
          'rebasesCommandId': null,
        },
      };
      final merger = ComponentSyncMerger(
        x.f.db,
        writeScope: x.adapter.writeScope,
      );
      await expectLater(
        merger.merge(
          x.f.workspace.context.ownerUserId,
          SyncComponent.medicationBridge,
          [occurrence, event],
          contractVersion: 4,
        ),
        throwsA(isA<FormatException>()),
      );
      await x.adapter.writeScope.write(
        () => merger.merge(
          x.f.workspace.context.ownerUserId,
          SyncComponent.medicationBridge,
          [occurrence, event],
          contractVersion: 5,
        ),
      );
      final saved = (await x.f.db.medicationLedgerDao.getOccurrenceById(
        occurrenceId,
      ))!;
      expect(saved.state, 'taken');
      expect(saved.plannedAt, isNull);
      final facts = (await x.writer.historyForPerson(x.f.person.id)).single;
      expect(facts.amount.quantityText, '1/2');
      expect(facts.event.actualAt, isNull);
      expect(facts.event.actualTimeKnown, false);
      expect(facts.authorId, isNull);
      expect(await x.f.db.select(x.f.db.careEventDetails).get(), isEmpty);
      final eventPayload = Map<String, dynamic>.from(event['payload'] as Map);
      for (final changed in [
        {...eventPayload, 'note': 'different immutable note'},
        {...eventPayload, 'action': 'skip', 'toState': 'skipped'},
        {
          ...eventPayload,
          'administrationAmount': {
            'version': 1,
            'state': 'known',
            'quantity': '2',
            'unit': 'tablet',
          },
        },
      ]) {
        await expectLater(
          x.adapter.writeScope.write(
            () => merger.merge(
              x.f.workspace.context.ownerUserId,
              SyncComponent.medicationBridge,
              [
                {...event, 'payload': changed},
              ],
              contractVersion: 5,
            ),
          ),
          throwsFormatException,
        );
      }
      final invalidSnapshot = Map<String, dynamic>.from(
        occurrence['payload'] as Map,
      );
      invalidSnapshot['scheduleSnapshot'] = {
        ...invalidSnapshot['scheduleSnapshot'] as Map,
        'frequency': 'daily',
        'hour': 13,
      };
      await expectLater(
        x.adapter.writeScope.write(
          () => merger.merge(
            x.f.workspace.context.ownerUserId,
            SyncComponent.medicationBridge,
            [
              {...occurrence, 'payload': invalidSnapshot},
            ],
            contractVersion: 5,
          ),
        ),
        throwsFormatException,
      );
      final after = (await x.f.db.medicationLedgerDao.getEventsForOccurrence(
        occurrenceId,
      )).single;
      expect(after.note, isNull);
      expect(jsonDecode(after.administrationAmountJson!)['quantity'], '1/2');
    },
  );

  test(
    'a dose with a sub-second known time is sent, not blocked as a request mismatch',
    () async {
      final x = await _fixture();
      final care = await x.writer.commit(
        await x.writer.prepareConnectedPrn(
          personId: x.f.person.id,
          pillId: x.f.pill.id,
          sentinelId: x.f.occurrence.scheduleId!,
          reviewedLocalDate: '2026-09-30',
          amount: const MedicationAmount.unknown(),
          actualAt: DateTime.utc(2026, 9, 30, 10, 15, 30, 123, 456),
          actualTimeKnown: true,
        ),
      );
      final requests = <Map<String, dynamic>>[];
      when(
        () => x.dio.post<dynamic>(
          '/medication/bridge/prn/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final r = Map<String, dynamic>.from(i.namedArguments[#data] as Map);
        requests.add(r);
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: _receipt(r),
        );
      });
      final op = (await x.f.db.pendingOperationsDao.getByMutationId(
        x.f.workspace.context.ownerUserId,
        care.event.commandId,
      ))!;
      final result = await x.adapter.send(op);
      expect(result.safeErrorCode, isNull);
      expect(result.status, MedicationMutationStatus.acknowledged);
      expect(requests.single['actualAt'], '2026-09-30T10:15:30.123456Z');
      expect(requests.single['actualTimeKnown'], true);
    },
  );

  test(
    'the bridge pull of our own sent PRN dose is not an immutable-fact change when its time has sub-second precision',
    () async {
      final x = await _fixture();
      final care = await x.writer.commit(
        await x.writer.prepareConnectedPrn(
          personId: x.f.person.id,
          pillId: x.f.pill.id,
          sentinelId: x.f.occurrence.scheduleId!,
          reviewedLocalDate: '2026-09-30',
          amount: const MedicationAmount.unknown(),
          actualAt: DateTime.utc(2026, 9, 30, 10, 15, 30, 123, 456),
          actualTimeKnown: true,
        ),
      );
      when(
        () => x.dio.post<dynamic>(
          '/medication/bridge/prn/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final r = Map<String, dynamic>.from(i.namedArguments[#data] as Map);
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: _receipt(r),
        );
      });
      final owner = x.f.workspace.context.ownerUserId;
      final op = (await x.f.db.pendingOperationsDao.getByMutationId(
        owner,
        care.event.commandId,
      ))!;
      expect(
        (await x.adapter.send(op)).status,
        MedicationMutationStatus.acknowledged,
      );
      final occ = care.current;
      Map<String, Object?> change(
        String type,
        String id,
        Map<String, Object?> payload,
      ) => {
        'schemaVersion': 2,
        'component': 'medicationBridge',
        'entityType': type,
        'entityId': id,
        'operation': 'upsert',
        'sourceIdentity': {
          'sourceKind': type == 'medication_occurrence'
              ? 'occurrence'
              : 'occurrence_event',
          'sourceId': id,
          'sourceRevision': type == 'medication_occurrence' ? '2' : '3',
        },
        'payload': payload,
      };
      final merger = ComponentSyncMerger(
        x.f.db,
        writeScope: x.adapter.writeScope,
      );
      await x.adapter.writeScope.write(
        () => merger.merge(owner, SyncComponent.medicationBridge, [
          change('medication_occurrence', occ.id, {
            'kind': 'medicationOccurrence',
            'id': occ.id,
            'pillId': x.f.pill.id,
            'scheduleId': occ.scheduleId,
            'occurrenceKey': occ.occurrenceKey,
            'source': 'prn',
            'provenance': 'exact',
            'scheduleRevision': occ.scheduleRevision.toString(),
            'plannedLocalDate': occ.plannedLocalDate,
            'plannedLocalTime': null,
            'plannedAt': null,
            'timeZone': occ.timeZone,
            'expected': false,
            'snapshotVersion': 1,
            'scheduleSnapshot': jsonDecode(occ.scheduleSnapshotJson),
            'stateVersion': '1',
            'supersededAt': null,
            'supersededByOccurrenceId': null,
          }),
          change('occurrence_event', care.event.id, {
            'kind': 'occurrenceEvent',
            'id': care.event.id,
            'occurrenceId': occ.id,
            'commandId': care.event.commandId,
            'action': 'take',
            'fromState': 'pending',
            'toState': 'taken',
            'baseVersion': '0',
            'resultVersion': '1',
            'actualAt': '2026-09-30T10:15:30.123Z',
            'actualTimeKnown': true,
            'administrationAmount': {'version': 1, 'state': 'unknown'},
            'note': null,
            'origin': 'native',
            'serverSequence': '3',
            'recordedAt': '2026-09-30T12:00:00.000Z',
            'reversesEventId': null,
            'rebasesCommandId': null,
          }),
        ], contractVersion: 5),
      );
      final saved = (await x.f.db.medicationLedgerDao.getEventsForOccurrence(
        occ.id,
      )).single;
      expect(saved.id, care.event.id);
      expect(saved.serverId, care.event.id);
      // The server only knows when it received the command (here, much later
      // than the device recorded it). Pulling our own event back must keep
      // the device's recording time for "Recorded in Simpastil".
      final deviceRecordedAt = saved.recordedAt;
      await x.adapter.writeScope.write(
        () => merger.merge(owner, SyncComponent.medicationBridge, [
          change('occurrence_event', care.event.id, {
            'kind': 'occurrenceEvent',
            'id': care.event.id,
            'occurrenceId': occ.id,
            'commandId': care.event.commandId,
            'action': 'take',
            'fromState': 'pending',
            'toState': 'taken',
            'baseVersion': '0',
            'resultVersion': '1',
            'actualAt': '2026-09-30T10:15:30.123Z',
            'actualTimeKnown': true,
            'administrationAmount': {'version': 1, 'state': 'unknown'},
            'note': null,
            'origin': 'native',
            'serverSequence': '3',
            'recordedAt': deviceRecordedAt
                .add(const Duration(minutes: 13))
                .toUtc()
                .toIso8601String(),
            'reversesEventId': null,
            'rebasesCommandId': null,
          }),
        ], contractVersion: 5),
      );
      final pulled = (await x.f.db.medicationLedgerDao.getEventsForOccurrence(
        occ.id,
      )).single;
      expect(pulled.recordedAt, deviceRecordedAt);
    },
  );
}
