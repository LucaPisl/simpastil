import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/sync/adapters/bridge_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/legacy_split_checkpoint.dart';
import 'package:simpastil/core/sync/sync_service.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

import '../../helpers/care_recording_fixture.dart';

class _Dio extends Mock implements Dio {}

Future<
  ({
    CareRecordingFixture fixture,
    BridgeMedicationSyncAdapter adapter,
    _Dio dio,
    PendingOperation operation,
  })
>
_fixture() async {
  final fixture = await CareRecordingFixture.create(
    connected: true,
    legacyStock: 4,
  );
  addTearDown(fixture.db.close);
  await (fixture.db.update(
    fixture.db.profiles,
  )..where((row) => row.id.equals(fixture.person.id))).write(
    ProfilesCompanion(
      serverId: Value(fixture.person.id),
      syncStatus: const Value('synced'),
    ),
  );
  await (fixture.db.update(
    fixture.db.pills,
  )..where((row) => row.id.equals(fixture.pill.id))).write(
    PillsCompanion(
      serverId: Value(fixture.pill.id),
      syncStatus: const Value('synced'),
    ),
  );
  await (fixture.db.update(
    fixture.db.schedules,
  )..where((row) => row.id.equals(fixture.occurrence.scheduleId!))).write(
    SchedulesCompanion(
      serverId: Value(fixture.occurrence.scheduleId),
      syncStatus: const Value('synced'),
    ),
  );
  await (fixture.db.update(
    fixture.db.medicationOccurrences,
  )..where((row) => row.id.equals(fixture.occurrence.id))).write(
    MedicationOccurrencesCompanion(serverId: Value(fixture.occurrence.id)),
  );
  final context = fixture.workspace.context;
  final writer = CareRecordingService(
    database: fixture.db,
    access: fixture.workspace.access,
    context: context,
    clock: () => DateTime.utc(2026, 9, 30, 9, 5),
  );
  final receipt = await writer.commit(
    await writer.prepareTakenNow(
      personId: fixture.person.id,
      occurrenceId: fixture.occurrence.id,
      expectedStateVersion: 0,
      amount: const MedicationAmount.unknown(),
      note: 'Fictional note',
    ),
  );
  final operation = (await fixture.db.pendingOperationsDao.getByMutationId(
    context.ownerUserId,
    receipt.event.commandId,
  ))!;
  final dio = _Dio();
  final adapter = BridgeMedicationSyncAdapter(
    db: fixture.db,
    dio: dio,
    writeScope: SyncWriteScope(
      access: fixture.workspace.access,
      capability: NetworkCapability(
        ownerId: context.ownerUserId,
        endpoint: context.endpoint!,
        epoch: context.networkEpoch!,
        generation: context.sessionGeneration!,
      ),
    ),
  );
  return (fixture: fixture, adapter: adapter, dio: dio, operation: operation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(<String, Object?>{}));

  test('500 retry reuses the request frozen before the first send', () async {
    final x = await _fixture();
    final requests = <Map<String, dynamic>>[];
    when(
      () => x.dio.post<dynamic>(
        '/medication/bridge/commands',
        data: any(named: 'data'),
      ),
    ).thenAnswer((invocation) async {
      final request = Map<String, dynamic>.from(
        invocation.namedArguments[#data] as Map,
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

    expect(
      (await x.adapter.send(x.operation)).status,
      MedicationMutationStatus.retryable,
    );
    final retry = (await x.fixture.db.pendingOperationsDao.getById(
      x.operation.id,
    ))!;
    expect(retry.state, 'failedRetryable');
    expect(
      jsonDecode(retry.payloadJson)['medicationBridgeRequest'],
      requests.single,
    );
    expect(
      (await x.adapter.send(retry)).status,
      MedicationMutationStatus.acknowledged,
    );
    expect(requests, hasLength(2));
    expect(requests[1], requests[0]);
  });

  test(
    'an attempted legacy operation without a frozen request remains blocked',
    () async {
      final x = await _fixture();
      await (x.fixture.db.update(
        x.fixture.db.pendingOperations,
      )..where((row) => row.id.equals(x.operation.id))).write(
        PendingOperationsCompanion(
          state: const Value('failedRetryable'),
          attemptCount: const Value(1),
          lastAttemptAt: Value(DateTime.utc(2026, 9, 30, 10)),
          safeErrorCode: const Value('MEDICATION_BRIDGE_REJECTED'),
        ),
      );
      final attempted = (await x.fixture.db.pendingOperationsDao.getById(
        x.operation.id,
      ))!;

      final result = await x.adapter.send(attempted);

      expect(result.status, MedicationMutationStatus.uncertain);
      expect(
        result.safeErrorCode,
        'MEDICATION_BRIDGE_REQUEST_EVIDENCE_REQUIRED',
      );
      final retained = (await x.fixture.db.pendingOperationsDao.getById(
        x.operation.id,
      ))!;
      expect(retained.state, 'blocked');
      expect(
        jsonDecode(retained.payloadJson).containsKey('medicationBridgeRequest'),
        isFalse,
      );
      verifyNever(() => x.dio.post<dynamic>(any(), data: any(named: 'data')));
    },
  );

  test(
    'captures an old atomic bridge attempt as ambiguous effect evidence',
    () async {
      final x = await _fixture();
      final attemptedAt = DateTime.utc(2026, 9, 30, 10);
      final beforeEffects = await x.fixture.db.pendingOperationsDao.getEffects(
        x.operation.id,
      );
      final beforeInventory = await x.fixture.db
          .select(x.fixture.db.inventoryEvents)
          .get();
      expect(beforeEffects.map((effect) => effect.kind), ['dose', 'inventory']);
      final legacyPayload = Map<String, dynamic>.from(
        jsonDecode(x.operation.payloadJson) as Map,
      )..remove('eventId');
      await (x.fixture.db.update(
        x.fixture.db.pendingOperations,
      )..where((row) => row.id.equals(x.operation.id))).write(
        PendingOperationsCompanion(
          payloadJson: Value(jsonEncode(legacyPayload)),
          state: const Value('blocked'),
          attemptCount: const Value(1),
          lastAttemptAt: Value(attemptedAt),
          safeErrorCode: const Value('MEDICATION_BRIDGE_REJECTED'),
        ),
      );
      final attempted = (await x.fixture.db.pendingOperationsDao.getById(
        x.operation.id,
      ))!;

      expect(
        await x.adapter.captureUnfrozenAttemptForReview(attempted),
        isTrue,
      );

      final captured = await x.fixture.db.pendingOperationsDao.getEffects(
        attempted.id,
      );
      expect(captured.map((effect) => effect.state), everyElement('uncertain'));
      expect(
        captured.map((effect) => effect.attemptedAt!.toUtc()),
        everyElement(attemptedAt),
      );
      expect(
        captured.map((effect) => effect.requestFingerprint),
        beforeEffects.map((effect) => effect.requestFingerprint),
      );
      expect(
        (await x.fixture.db.pendingOperationsDao.getById(
          attempted.id,
        ))!.safeErrorCode,
        'MEDICATION_BRIDGE_REQUEST_EVIDENCE_REQUIRED',
      );
      expect(
        (await LegacySplitCheckpoint.load(
          x.fixture.db,
          attempted.id,
        ))!.hasRetainedProgress,
        isTrue,
      );
      expect(
        await x.fixture.db.select(x.fixture.db.inventoryEvents).get(),
        beforeInventory,
      );
      verifyNever(() => x.dio.post<dynamic>(any(), data: any(named: 'data')));
    },
  );

  // A legacy split stopped as uncertain is persisted blocked with its own code;
  // the reconciliation step finds it by its checkpoint, not by that code.
  for (final blockedCode in const [
    'MEDICATION_BRIDGE_REJECTED',
    'SPLIT_EFFECT_REQUIRES_RECONCILIATION',
  ]) {
    test(
      'flush captures and records an old attempt without replaying care ($blockedCode)',
      () async {
        final x = await _fixture();
        final attemptedAt = DateTime.utc(2026, 9, 30, 10);
        final legacyPayload = Map<String, dynamic>.from(
          jsonDecode(x.operation.payloadJson) as Map,
        )..remove('eventId');
        await (x.fixture.db.update(
          x.fixture.db.pendingOperations,
        )..where((row) => row.id.equals(x.operation.id))).write(
          PendingOperationsCompanion(
            payloadJson: Value(jsonEncode(legacyPayload)),
            state: const Value('blocked'),
            attemptCount: const Value(1),
            lastAttemptAt: Value(attemptedAt),
            safeErrorCode: Value(blockedCode),
          ),
        );
        await (x.fixture.db.delete(
          x.fixture.db.pendingOperations,
        )..where((row) => row.component.isNotValue('medication'))).go();
        final beforeEffects = await x.fixture.db.pendingOperationsDao
            .getEffects(x.operation.id);
        final beforeOccurrence = await x.fixture.db.medicationLedgerDao
            .getOccurrenceById(x.fixture.occurrence.id);
        final beforeEvents = await x.fixture.db.medicationLedgerDao
            .getEventsForOccurrence(x.fixture.occurrence.id);
        final beforeDoseLogs = await x.fixture.db
            .select(x.fixture.db.doseLogs)
            .get();
        final beforeInventory = await x.fixture.db
            .select(x.fixture.db.inventoryEvents)
            .get();
        final beforePill = await x.fixture.db.pillsDao.getById(
          x.fixture.pill.id,
        );
        when(() => x.dio.get<Map<String, dynamic>>('/capabilities')).thenAnswer(
          (_) async => Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(path: '/capabilities'),
            data: {
              'apiNamespace': 'v1',
              'contracts': {
                'componentSync': 2,
                'legacySplitReconciliation': 1,
                'medicationBridgeCommands': 1,
                'medicationBridgeSync': 1,
                'medicationCommands': 2,
                'medicationBridgePrnCommands': 1,
                'medicationBridgePrnSync': 5,
              },
              'medicationLedgerActive': false,
              'minimumClientBuild': 1,
              'serverRelease': 'fictional-test',
            },
          ),
        );
        when(
          () => x.dio.post<dynamic>(
            '/medication/legacy-split/reconcile',
            data: any(named: 'data'),
          ),
        ).thenAnswer((invocation) async {
          final request = invocation.namedArguments[#data] as Map;
          return Response<dynamic>(
            requestOptions: RequestOptions(
              path: '/medication/legacy-split/reconcile',
            ),
            data: {
              'issue': {'id': request['issueId']},
            },
          );
        });
        final service = SyncService(
          db: x.fixture.db,
          dio: x.dio,
          isOnline: () async => true,
          writeScope: x.adapter.writeScope,
        );

        await service.flushPending(
          userId: x.fixture.workspace.context.ownerUserId,
        );

        final afterEffects = await x.fixture.db.pendingOperationsDao.getEffects(
          x.operation.id,
        );
        expect(
          afterEffects.map((effect) => effect.requestFingerprint),
          beforeEffects.map((effect) => effect.requestFingerprint),
        );
        expect(
          afterEffects.map((effect) => effect.safeResultFingerprint),
          everyElement(startsWith('reconciliation-recorded:')),
        );
        expect(
          afterEffects.map((effect) => effect.state),
          everyElement('uncertain'),
        );
        expect(
          await x.fixture.db.medicationLedgerDao.getOccurrenceById(
            x.fixture.occurrence.id,
          ),
          beforeOccurrence,
        );
        expect(
          await x.fixture.db.medicationLedgerDao.getEventsForOccurrence(
            x.fixture.occurrence.id,
          ),
          beforeEvents,
        );
        expect(
          await x.fixture.db.select(x.fixture.db.doseLogs).get(),
          beforeDoseLogs,
        );
        expect(
          await x.fixture.db.select(x.fixture.db.inventoryEvents).get(),
          beforeInventory,
        );
        expect(
          await x.fixture.db.pillsDao.getById(x.fixture.pill.id),
          beforePill,
        );
        verify(
          () => x.dio.post<dynamic>(
            '/medication/legacy-split/reconcile',
            data: any(named: 'data'),
          ),
        ).called(beforeEffects.length);
        verifyNever(
          () => x.dio.post<dynamic>(
            '/medication/bridge/commands',
            data: any(named: 'data'),
          ),
        );
      },
    );
  }

  test(
    'does not capture unattempted, malformed, PRN, or stable work',
    () async {
      final fresh = await _fixture();
      expect(
        await fresh.adapter.captureUnfrozenAttemptForReview(fresh.operation),
        isFalse,
      );

      Future<PendingOperation> markAttempted(
        ({
          CareRecordingFixture fixture,
          BridgeMedicationSyncAdapter adapter,
          _Dio dio,
          PendingOperation operation,
        })
        x,
      ) async {
        await (x.fixture.db.update(
          x.fixture.db.pendingOperations,
        )..where((row) => row.id.equals(x.operation.id))).write(
          PendingOperationsCompanion(
            state: const Value('blocked'),
            attemptCount: const Value(1),
            lastAttemptAt: Value(DateTime.utc(2026, 9, 30, 10)),
          ),
        );
        return (await x.fixture.db.pendingOperationsDao.getById(
          x.operation.id,
        ))!;
      }

      final malformed = await _fixture();
      var attempted = await markAttempted(malformed);
      final malformedPayload = Map<String, dynamic>.from(
        jsonDecode(attempted.payloadJson) as Map,
      )..remove('localProjection');
      await (malformed.fixture.db.update(
        malformed.fixture.db.pendingOperations,
      )..where((row) => row.id.equals(attempted.id))).write(
        PendingOperationsCompanion(
          payloadJson: Value(jsonEncode(malformedPayload)),
        ),
      );
      attempted = (await malformed.fixture.db.pendingOperationsDao.getById(
        attempted.id,
      ))!;
      expect(
        await malformed.adapter.captureUnfrozenAttemptForReview(attempted),
        isFalse,
      );

      final mismatchedEffect = await _fixture();
      attempted = await markAttempted(mismatchedEffect);
      await (mismatchedEffect.fixture.db.update(
            mismatchedEffect.fixture.db.pendingOperationEffects,
          )..where(
            (row) =>
                row.operationId.equals(attempted.id) & row.kind.equals('dose'),
          ))
          .write(
            const PendingOperationEffectsCompanion(
              legacySourceId: Value('unrelated-dose-source'),
            ),
          );
      expect(
        await mismatchedEffect.adapter.captureUnfrozenAttemptForReview(
          attempted,
        ),
        isFalse,
      );

      final prn = await _fixture();
      attempted = await markAttempted(prn);
      await (prn.fixture.db.update(
        prn.fixture.db.medicationOccurrences,
      )..where((row) => row.id.equals(prn.fixture.occurrence.id))).write(
        const MedicationOccurrencesCompanion(
          source: Value('prn'),
          expected: Value(false),
          plannedAt: Value(null),
        ),
      );
      expect(
        await prn.adapter.captureUnfrozenAttemptForReview(attempted),
        isFalse,
      );

      final stable = await _fixture();
      attempted = await markAttempted(stable);
      await (stable.fixture.db.update(stable.fixture.db.pendingOperations)
            ..where((row) => row.id.equals(attempted.id)))
          .write(const PendingOperationsCompanion(component: Value('stable')));
      attempted = (await stable.fixture.db.pendingOperationsDao.getById(
        attempted.id,
      ))!;
      expect(
        await stable.adapter.captureUnfrozenAttemptForReview(attempted),
        isFalse,
      );
    },
  );
}
