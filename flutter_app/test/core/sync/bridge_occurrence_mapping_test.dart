import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/sync/adapters/bridge_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/component_sync_pull_adapter.dart';
import 'package:simpastil/core/sync/sync_coordinator.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../../helpers/care_recording_fixture.dart';

class _Dio extends Mock implements Dio {}

const _personId = '20000000-0000-4000-8000-000000000001';
const _pillId = '20000000-0000-4000-8000-000000000002';
const _scheduleId = '20000000-0000-4000-8000-000000000003';
const _occurrenceId = '20000000-0000-4000-8000-000000000004';

Future<
  ({
    CareRecordingFixture care,
    SyncWriteScope scope,
    PendingOperation operation,
    Map<String, dynamic> change,
  })
>
_fixture({
  bool localScheduleKey = false,
  bool legacyPayload = false,
  DateTime? actualAt,
}) async {
  final care = await CareRecordingFixture.create(
    connected: true,
    legacyStock: 4,
  );
  final db = care.db;
  addTearDown(db.close);
  await (db.update(db.profiles)..where((r) => r.id.equals(care.person.id)))
      .write(const ProfilesCompanion(serverId: Value(_personId)));
  await (db.update(db.pills)..where((r) => r.id.equals(care.pill.id))).write(
    const PillsCompanion(serverId: Value(_pillId)),
  );
  await (db.update(db.schedules)
        ..where((r) => r.id.equals(care.occurrence.scheduleId!)))
      .write(const SchedulesCompanion(serverId: Value(_scheduleId)));
  final plan = OccurrenceMaterializer()
      .materialize(
        source: ScheduledOccurrenceSource(
          userId: care.workspace.context.ownerUserId,
          id: localScheduleKey ? care.occurrence.scheduleId! : _scheduleId,
          scheduleRevision: '1',
          pillId: care.pill.id,
          pillName: care.pill.name,
          dosage: care.pill.dosage,
          frequency: 'daily',
          frequencyDays: null,
          hour: 9,
          minute: 0,
          timeZone: 'UTC',
          profileId: care.person.id,
          profileName: care.person.name,
        ),
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-09-30',
      )
      .single;
  await (db.update(
    db.medicationOccurrences,
  )..where((r) => r.id.equals(care.occurrence.id))).write(
    MedicationOccurrencesCompanion(
      occurrenceKey: Value(plan.occurrenceKey),
      plannedLocalTime: Value(plan.plannedLocalTime),
      scheduleSnapshotJson: Value(jsonEncode(plan.scheduleSnapshot.toJson())),
    ),
  );
  final context = care.workspace.context;
  final writer = CareRecordingService(
    database: db,
    access: care.workspace.access,
    context: context,
    clock: () => actualAt ?? DateTime.utc(2026, 9, 30, 9, 5),
  );
  final receipt = await writer.commit(
    await writer.prepareTakenNow(
      personId: care.person.id,
      occurrenceId: care.occurrence.id,
      expectedStateVersion: 0,
      amount: const MedicationAmount.unknown(),
      note: 'Fictional retained recording',
    ),
  );
  var operation = (await db.pendingOperationsDao.getByMutationId(
    context.ownerUserId,
    receipt.event.commandId,
  ))!;
  if (legacyPayload) {
    final payload = jsonDecode(operation.payloadJson) as Map<String, dynamic>;
    payload.remove('eventId');
    payload.remove('administrationAmount');
    await (db.update(
      db.pendingOperations,
    )..where((r) => r.id.equals(operation.id))).write(
      PendingOperationsCompanion(payloadJson: Value(jsonEncode(payload))),
    );
    operation = (await db.pendingOperationsDao.getById(operation.id))!;
  }
  final scope = SyncWriteScope(
    access: care.workspace.access,
    capability: NetworkCapability(
      ownerId: context.ownerUserId,
      endpoint: context.endpoint!,
      epoch: context.networkEpoch!,
      generation: context.sessionGeneration!,
    ),
  );
  final payload = <String, dynamic>{
    'kind': 'medicationOccurrence',
    'id': _occurrenceId,
    'pillId': _pillId,
    'scheduleId': _scheduleId,
    'occurrenceKey': plan.occurrenceKey,
    'source': 'scheduled',
    'scheduleRevision': '1',
    'plannedLocalDate': plan.plannedLocalDate,
    'plannedLocalTime': plan.plannedLocalTime,
    'timeZone': plan.timeZone,
    'plannedAt': plan.plannedAt.toIso8601String(),
    'expected': true,
    'snapshotVersion': 1,
    'scheduleSnapshot': {
      ...plan.scheduleSnapshot.toJson(),
      'profileId': _personId,
    },
    'provenance': 'exact',
    'stateVersion': '0',
    'supersededAt': null,
    'supersededByOccurrenceId': null,
  };
  return (
    care: care,
    scope: scope,
    operation: operation,
    change: {
      'schemaVersion': 2,
      'component': 'medicationBridge',
      'entityType': 'medication_occurrence',
      'entityId': _occurrenceId,
      'operation': 'upsert',
      'sourceIdentity': {
        'sourceKind': 'occurrence',
        'sourceId': _occurrenceId,
        'sourceRevision': '1',
      },
      'payload': payload,
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    tz_data.initializeTimeZones();
    registerFallbackValue(<String, Object?>{});
  });

  test(
    'inactive bridge uploads native care with a migrated local schedule key',
    () async {
      final x = await _fixture(localScheduleKey: true);
      final db = x.care.db;
      final before = (await db.medicationLedgerDao.getOccurrenceById(
        x.care.occurrence.id,
      ))!;
      expect(before.serverId, isNull);
      final events = await db.select(db.occurrenceEvents).get();
      final doses = await db.select(db.doseLogs).get();
      final effects = await db.select(db.pendingOperationEffects).get();
      final pills = await db.select(db.pills).get();
      final requests = <Map<String, dynamic>>[];
      final dio = _Dio();
      when(
        () => dio.post<dynamic>(
          '/medication/bridge/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final request = Map<String, dynamic>.from(
          i.namedArguments[#data] as Map,
        );
        requests.add(request);
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: {'commandId': request['commandId']},
        );
      });
      expect(
        (await BridgeMedicationSyncAdapter(
          db: db,
          dio: dio,
          writeScope: x.scope,
        ).send(x.operation)).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(requests.single['pillId'], _pillId);
      expect(requests.single['scheduleId'], _scheduleId);
      expect(
        requests.single['scheduledAt'],
        before.plannedAt!.toUtc().toIso8601String(),
      );
      expect(
        requests.single['takenAt'],
        DateTime.utc(2026, 9, 30, 9, 5).toIso8601String(),
      );
      expect(await db.medicationLedgerDao.getOccurrenceById(before.id), before);
      expect(await db.select(db.occurrenceEvents).get(), events);
      expect(await db.select(db.doseLogs).get(), doses);
      expect(await db.select(db.pendingOperationEffects).get(), effects);
      expect(await db.select(db.pills).get(), pills);
      expect(
        (await db.pendingOperationsDao.getById(x.operation.id))!.state,
        'committed',
      );
    },
  );

  test(
    'record before first plan pull gains only its canonical mapping and uploads',
    () async {
      final x = await _fixture();
      final db = x.care.db;
      final before = (await db.medicationLedgerDao.getOccurrenceById(
        x.care.occurrence.id,
      ))!;
      final events = await db.select(db.occurrenceEvents).get();
      final effects = await db.select(db.pendingOperationEffects).get();
      final doses = await db.select(db.doseLogs).get();
      final pills = await db.select(db.pills).get();
      final dio = _Dio();
      final requests = <Map<String, dynamic>>[];
      when(
        () => dio.post<dynamic>(
          '/medication/bridge/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final request = Map<String, dynamic>.from(
          i.namedArguments[#data] as Map,
        );
        requests.add(request);
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: {'commandId': request['commandId']},
        );
      });
      final adapter = BridgeMedicationSyncAdapter(
        db: db,
        dio: dio,
        writeScope: x.scope,
      );
      expect(requests, isEmpty);
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: before.userId,
          component: 'medicationBridge',
          contractVersion: 5,
          lastCompletedCursor: const Value('1'),
          lastFullSuccessAt: Value(DateTime.now().toUtc()),
        ),
      );
      final checkpoints = <String>[];
      Future<SyncRunResult> pull() async {
        final transport = _Dio();
        when(
          () => transport.get<Map<String, dynamic>>(
            '/sync/medication-bridge',
            queryParameters: any(named: 'queryParameters'),
          ),
        ).thenAnswer((i) async {
          final query = i.namedArguments[#queryParameters] as Map;
          final after = query['afterSequence'] as String? ?? '0';
          checkpoints.add(after);
          return Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(path: '/fictional'),
            data: {
              'component': 'medicationBridge',
              'contractVersion': 5,
              'afterSequence': after,
              'throughSequence': '1',
              'hasMore': false,
              'nextCursor': null,
              'items': after == '0'
                  ? [
                      {'serverSequence': '1', 'change': x.change},
                    ]
                  : [],
            },
          );
        });
        return SyncCoordinator(db, writeScope: x.scope).run(
          userId: before.userId,
          stages: [
            SyncStage(
              id: 'medicationBridge',
              component: SyncComponent.medicationBridge,
              contractVersion: 5,
              run: () async {
                await ComponentSyncPullAdapter(
                  db: db,
                  dio: transport,
                  writeScope: x.scope,
                ).pull(
                  userId: before.userId,
                  component: SyncComponent.medicationBridge,
                  contractVersion: 5,
                  projectionRevision: 'recorded-occurrence-link-v1',
                  merge: (component, changes) =>
                      ComponentSyncMerger(db, writeScope: x.scope).merge(
                        before.userId,
                        component,
                        changes,
                        contractVersion: 5,
                      ),
                );
                return const SyncComponentOutcome.succeeded();
              },
            ),
          ],
        );
      }

      expect((await pull()).status, SyncRunStatus.succeeded);
      expect(
        await db.medicationLedgerDao.getOccurrenceById(before.id),
        before.copyWith(serverId: const Value(_occurrenceId)),
      );
      expect(await db.select(db.occurrenceEvents).get(), events);
      expect(await db.select(db.pendingOperationEffects).get(), effects);
      expect(await db.select(db.doseLogs).get(), doses);
      expect(await db.select(db.pills).get(), pills);
      expect(
        await db.pendingOperationsDao.getById(x.operation.id),
        x.operation,
      );
      expect((await pull()).status, SyncRunStatus.succeeded);
      expect(checkpoints, ['0', '1']);
      expect(
        (await adapter.send(x.operation)).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(
        requests.single['takenAt'],
        DateTime.utc(2026, 9, 30, 9, 5).toIso8601String(),
      );
      expect(
        (await db.pendingOperationsDao.getById(x.operation.id))!.state,
        'committed',
      );
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(
          before.id,
        ))!.stateVersion,
        1,
      );
    },
  );

  for (final olderFormat in [false, true]) {
    test(
      'unmapped ${olderFormat ? 'older' : 'current'} native recording preserves fractional actual time',
      () async {
        final actualAt = DateTime.utc(2026, 9, 30, 9, 5, 0, 123, 456);
        final x = await _fixture(
          localScheduleKey: true,
          legacyPayload: olderFormat,
          actualAt: actualAt,
        );
        final db = x.care.db;
        final events = await db.select(db.occurrenceEvents).get();
        final doses = await db.select(db.doseLogs).get();
        final requests = <Map<String, dynamic>>[];
        final dio = _Dio();
        when(
          () => dio.post<dynamic>(
            '/medication/bridge/commands',
            data: any(named: 'data'),
          ),
        ).thenAnswer((i) async {
          final request = Map<String, dynamic>.from(
            i.namedArguments[#data] as Map,
          );
          requests.add(request);
          return Response<dynamic>(
            requestOptions: RequestOptions(path: '/fictional'),
            data: {'commandId': request['commandId']},
          );
        });
        expect(
          (await BridgeMedicationSyncAdapter(
            db: db,
            dio: dio,
            writeScope: x.scope,
          ).send(x.operation)).status,
          MedicationMutationStatus.acknowledged,
        );
        expect(requests.single['commandId'], x.operation.mutationId);
        expect(requests.single['takenAt'], actualAt.toIso8601String());
        expect(await db.select(db.occurrenceEvents).get(), events);
        expect(await db.select(db.doseLogs).get(), doses);
        final stored =
            jsonDecode(
                  (await db.pendingOperationsDao.getById(
                    x.operation.id,
                  ))!.payloadJson,
                )
                as Map;
        expect(stored.containsKey('eventId'), !olderFormat);
      },
    );
  }

  for (final mismatch in [
    'event identity',
    'recorded intent',
    'fractional intent',
    'dose time',
    'person mapping',
  ]) {
    test(
      'unmapped native recording refuses $mismatch without changing care',
      () async {
        final x = await _fixture(localScheduleKey: true);
        final db = x.care.db;
        final payload =
            jsonDecode(x.operation.payloadJson) as Map<String, dynamic>;
        switch (mismatch) {
          case 'event identity':
            payload['eventId'] = '30000000-0000-4000-8000-000000000001';
          case 'recorded intent':
            (payload['command'] as Map)['actualAt'] = DateTime.utc(
              2026,
              9,
              30,
              10,
            ).toIso8601String();
          case 'fractional intent':
            (payload['command'] as Map)['actualAt'] = DateTime.utc(
              2026,
              9,
              30,
              9,
              5,
              0,
              500,
            ).toIso8601String();
          case 'dose time':
            final doseId =
                (payload['localProjection'] as Map)['legacyDoseSourceId']
                    as String;
            await (db.update(
              db.doseLogs,
            )..where((r) => r.id.equals(doseId))).write(
              DoseLogsCompanion(
                scheduledAt: Value(DateTime.utc(2026, 9, 30, 10)),
              ),
            );
          case 'person mapping':
            await (db.update(db.profiles)
                  ..where((r) => r.id.equals(x.care.person.id)))
                .write(const ProfilesCompanion(serverId: Value(null)));
        }
        await (db.update(
          db.pendingOperations,
        )..where((r) => r.id.equals(x.operation.id))).write(
          PendingOperationsCompanion(payloadJson: Value(jsonEncode(payload))),
        );
        final operation = (await db.pendingOperationsDao.getById(
          x.operation.id,
        ))!;
        final beforeOccurrence = await db.medicationLedgerDao.getOccurrenceById(
          x.care.occurrence.id,
        );
        final beforeEvents = await db.select(db.occurrenceEvents).get();
        final beforeDoses = await db.select(db.doseLogs).get();
        final beforeEffects = await db.select(db.pendingOperationEffects).get();
        final dio = _Dio();
        final result = await BridgeMedicationSyncAdapter(
          db: db,
          dio: dio,
          writeScope: x.scope,
        ).send(operation);
        expect(result.status, MedicationMutationStatus.blocked);
        expect(
          result.safeErrorCode,
          'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
        );
        verifyNever(() => dio.post<dynamic>(any(), data: any(named: 'data')));
        expect(
          await db.medicationLedgerDao.getOccurrenceById(x.care.occurrence.id),
          beforeOccurrence,
        );
        expect(await db.select(db.occurrenceEvents).get(), beforeEvents);
        expect(await db.select(db.doseLogs).get(), beforeDoses);
        expect(
          await db.select(db.pendingOperationEffects).get(),
          beforeEffects,
        );
        // The refusal is durable: a queued operation that can never be sent
        // would otherwise be re-evaluated forever with no visible state.
        expect(
          await db.pendingOperationsDao.getById(operation.id),
          operation.copyWith(
            state: 'blocked',
            safeErrorCode: const Value(
              'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
            ),
          ),
        );
      },
    );
  }

  test(
    'unmapped take retries its frozen intent after a later local Undo',
    () async {
      final x = await _fixture(localScheduleKey: true);
      final db = x.care.db;
      final requests = <Map<String, dynamic>>[];
      final dio = _Dio();
      when(
        () => dio.post<dynamic>(
          '/medication/bridge/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        final request = Map<String, dynamic>.from(
          i.namedArguments[#data] as Map,
        );
        requests.add(request);
        if (requests.length == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: '/fictional'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/fictional'),
              statusCode: 500,
            ),
          );
        }
        return Response<dynamic>(
          requestOptions: RequestOptions(path: '/fictional'),
          data: {'commandId': request['commandId']},
        );
      });
      final adapter = BridgeMedicationSyncAdapter(
        db: db,
        dio: dio,
        writeScope: x.scope,
      );
      expect(
        (await adapter.send(x.operation)).status,
        MedicationMutationStatus.retryable,
      );
      final writer = CareRecordingService(
        database: db,
        access: x.care.workspace.access,
        context: x.care.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9, 10),
      );
      await writer.commit(
        await writer.prepareUndoForEntry(
          personId: x.care.person.id,
          occurrenceId: x.care.occurrence.id,
          expectedStateVersion: 1,
          headEventId:
              (jsonDecode(x.operation.payloadJson) as Map)['eventId'] as String,
        ),
      );
      final before = (await db.medicationLedgerDao.getOccurrenceById(
        x.care.occurrence.id,
      ))!;
      final events = await db.select(db.occurrenceEvents).get();
      final doses = await db.select(db.doseLogs).get();
      final retry = (await db.pendingOperationsDao.getById(x.operation.id))!;
      expect(
        (await adapter.send(retry)).status,
        MedicationMutationStatus.acknowledged,
      );
      expect(requests, hasLength(2));
      expect(requests.last, requests.first);
      expect(requests.last['status'], 'taken');
      expect(before.state, 'pending');
      expect(await db.medicationLedgerDao.getOccurrenceById(before.id), before);
      expect(await db.select(db.occurrenceEvents).get(), events);
      expect(await db.select(db.doseLogs).get(), doses);
    },
  );

  for (final mismatch in ['frozen body', 'dose mapping']) {
    test('uncertain unmapped recording refuses a changed $mismatch', () async {
      final x = await _fixture(localScheduleKey: true);
      final db = x.care.db;
      final dio = _Dio();
      var posts = 0;
      when(
        () => dio.post<dynamic>(
          '/medication/bridge/commands',
          data: any(named: 'data'),
        ),
      ).thenAnswer((i) async {
        posts++;
        throw DioException(
          requestOptions: RequestOptions(path: '/fictional'),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: '/fictional'),
            statusCode: 500,
          ),
        );
      });
      final adapter = BridgeMedicationSyncAdapter(
        db: db,
        dio: dio,
        writeScope: x.scope,
      );
      expect(
        (await adapter.send(x.operation)).status,
        MedicationMutationStatus.retryable,
      );
      var retry = (await db.pendingOperationsDao.getById(x.operation.id))!;
      final payload = jsonDecode(retry.payloadJson) as Map<String, dynamic>;
      if (mismatch == 'frozen body') {
        (payload['medicationBridgeRequest'] as Map)['note'] = 'Altered request';
        await (db.update(
          db.pendingOperations,
        )..where((r) => r.id.equals(retry.id))).write(
          PendingOperationsCompanion(payloadJson: Value(jsonEncode(payload))),
        );
        retry = (await db.pendingOperationsDao.getById(retry.id))!;
      } else {
        final doseId =
            (payload['localProjection'] as Map)['legacyDoseSourceId'] as String;
        await (db.update(db.doseLogs)..where((r) => r.id.equals(doseId))).write(
          const DoseLogsCompanion(
            serverId: Value('30000000-0000-4000-8000-000000000002'),
          ),
        );
      }
      final doses = await db.select(db.doseLogs).get();
      final events = await db.select(db.occurrenceEvents).get();
      expect(
        (await adapter.send(retry)).safeErrorCode,
        'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
      );
      expect(posts, 1);
      expect(
        await db.pendingOperationsDao.getById(retry.id),
        retry.copyWith(
          state: 'blocked',
          safeErrorCode: const Value(
            'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
          ),
        ),
      );
      expect(await db.select(db.doseLogs).get(), doses);
      expect(await db.select(db.occurrenceEvents).get(), events);
    });
  }

  test(
    'mapping preserves an already recorded Undo head and all pending care',
    () async {
      final x = await _fixture();
      final db = x.care.db;
      final writer = CareRecordingService(
        database: db,
        access: x.care.workspace.access,
        context: x.care.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9, 6),
      );
      final take = (await db.medicationLedgerDao.getEventsForOccurrence(
        x.care.occurrence.id,
      )).single;
      await writer.commit(
        await writer.prepareUndoForEntry(
          personId: x.care.person.id,
          occurrenceId: x.care.occurrence.id,
          expectedStateVersion: 1,
          headEventId: take.id,
        ),
      );
      final before = (await db.medicationLedgerDao.getOccurrenceById(
        x.care.occurrence.id,
      ))!;
      expect(before.stateVersion, 2);
      expect(before.state, 'pending');
      final events = await db.select(db.occurrenceEvents).get();
      final operations = await db.select(db.pendingOperations).get();
      final effects = await db.select(db.pendingOperationEffects).get();
      final doses = await db.select(db.doseLogs).get();
      final pills = await db.select(db.pills).get();
      await x.scope.write(
        () => ComponentSyncMerger(db, writeScope: x.scope).merge(
          before.userId,
          SyncComponent.medicationBridge,
          [x.change],
          contractVersion: 4,
        ),
      );
      expect(
        await db.medicationLedgerDao.getOccurrenceById(before.id),
        before.copyWith(serverId: const Value(_occurrenceId)),
      );
      expect(await db.select(db.occurrenceEvents).get(), events);
      expect(await db.select(db.pendingOperations).get(), operations);
      expect(await db.select(db.pendingOperationEffects).get(), effects);
      expect(await db.select(db.doseLogs).get(), doses);
      expect(await db.select(db.pills).get(), pills);
    },
  );

  for (final mismatch in [
    'time',
    'instant',
    'revision',
    'snapshot days',
    'snapshot owner',
    'unmapped schedule',
    'unmapped pill',
    'unmapped person',
    'existing mapping',
    'remote care head',
    'local v2',
    'local v2 key',
    'superseded',
    'server key collision',
    'primary ID collision',
    'pill alias',
    'schedule alias',
    'person alias',
    'foreign owner',
  ]) {
    test('recorded plan cannot gain a mapping with $mismatch', () async {
      final x = await _fixture();
      final db = x.care.db;
      final item = x.change['payload'] as Map<String, dynamic>;
      final snapshot = item['scheduleSnapshot'] as Map<String, dynamic>;
      switch (mismatch) {
        case 'time':
          item['plannedLocalTime'] = '10:00:00';
        case 'instant':
          item['plannedAt'] = '2026-09-30T10:00:00Z';
        case 'revision':
          item['scheduleRevision'] = '2';
        case 'snapshot days':
          snapshot['frequencyDays'] = [1];
        case 'snapshot owner':
          snapshot['profileId'] = 'missing-person';
        case 'unmapped schedule':
          await (db.update(db.schedules)
                ..where((r) => r.id.equals(x.care.occurrence.scheduleId!)))
              .write(const SchedulesCompanion(serverId: Value(null)));
        case 'unmapped pill':
          await (db.update(db.pills)..where((r) => r.id.equals(x.care.pill.id)))
              .write(const PillsCompanion(serverId: Value(null)));
        case 'unmapped person':
          await (db.update(db.profiles)
                ..where((r) => r.id.equals(x.care.person.id)))
              .write(const ProfilesCompanion(serverId: Value(null)));
        case 'existing mapping':
          await (db.update(
            db.medicationOccurrences,
          )..where((r) => r.id.equals(x.care.occurrence.id))).write(
            const MedicationOccurrencesCompanion(
              serverId: Value('different-occurrence'),
            ),
          );
        case 'local v2':
          await (db.update(
            db.medicationOccurrences,
          )..where((r) => r.id.equals(x.care.occurrence.id))).write(
            const MedicationOccurrencesCompanion(snapshotVersion: Value(2)),
          );
        case 'local v2 key':
          item['occurrenceKey'] = 'scheduled:local:v2:fictional';
          await (db.update(
            db.medicationOccurrences,
          )..where((r) => r.id.equals(x.care.occurrence.id))).write(
            MedicationOccurrencesCompanion(
              occurrenceKey: Value(item['occurrenceKey'] as String),
            ),
          );
        case 'superseded':
          item['supersededAt'] = '2026-09-30T10:00:00Z';
        case 'server key collision':
          final row = (await db.medicationLedgerDao.getOccurrenceById(
            x.care.occurrence.id,
          ))!;
          await db
              .into(db.medicationOccurrences)
              .insert(
                row.copyWith(
                  id: 'fictional-collision',
                  serverId: const Value(_occurrenceId),
                  occurrenceKey: 'different-canonical-key',
                ),
              );
        case 'remote care head':
          item['stateVersion'] = '1';
          (x.change['sourceIdentity']
                  as Map<String, dynamic>)['sourceRevision'] =
              '2';
        case 'primary ID collision':
          final row = (await db.medicationLedgerDao.getOccurrenceById(
            x.care.occurrence.id,
          ))!;
          await db
              .into(db.medicationOccurrences)
              .insert(
                row.copyWith(
                  id: _occurrenceId,
                  occurrenceKey: 'different-canonical-key',
                ),
              );
        case 'pill alias':
          final row = (await db.pillsDao.getById(x.care.pill.id))!;
          await db
              .into(db.pills)
              .insert(row.copyWith(id: _pillId, serverId: const Value(null)));
        case 'schedule alias':
          final row = (await db.schedulesDao.getById(
            x.care.occurrence.scheduleId!,
          ))!;
          await db
              .into(db.schedules)
              .insert(
                row.copyWith(id: _scheduleId, serverId: const Value(null)),
              );
        case 'person alias':
          final row = (await db.profilesDao.getById(x.care.person.id))!;
          await db
              .into(db.profiles)
              .insert(row.copyWith(id: _personId, serverId: const Value(null)));
        case 'foreign owner':
          final row = (await db.medicationLedgerDao.getOccurrenceById(
            x.care.occurrence.id,
          ))!;
          final owner = (await db.usersDao.getById(row.userId))!;
          await db
              .into(db.users)
              .insert(
                owner.copyWith(
                  id: 'foreign-owner',
                  email: 'other@example.invalid',
                ),
              );
          await (db.update(
            db.medicationOccurrences,
          )..where((r) => r.id.equals(row.id))).write(
            const MedicationOccurrencesCompanion(
              userId: Value('foreign-owner'),
              serverId: Value(_occurrenceId),
            ),
          );
      }
      final before = await db.select(db.medicationOccurrences).get();
      final events = await db.select(db.occurrenceEvents).get();
      final operations = await db.select(db.pendingOperations).get();
      await expectLater(
        x.scope.write(
          () => ComponentSyncMerger(db, writeScope: x.scope).merge(
            x.care.workspace.context.ownerUserId,
            SyncComponent.medicationBridge,
            [x.change],
            contractVersion: 5,
          ),
        ),
        throwsA(anyOf(isA<WorkspaceAccessFailure>(), isA<FormatException>())),
      );
      expect(await db.select(db.medicationOccurrences).get(), before);
      expect(await db.select(db.occurrenceEvents).get(), events);
      expect(await db.select(db.pendingOperations).get(), operations);
    });
  }
}
