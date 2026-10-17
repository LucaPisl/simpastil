import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';

class MockDio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, Object?>{});
  });

  test('capability absence uses only checkpointed split writes', () {
    expect(
      selectMedicationSyncSteps(
        const CapabilitySnapshot.absent(),
        hasRetainedSplitCheckpoints: true,
      ),
      [MedicationSyncStep.legacySplit],
    );
  });

  test('capability failure selects no write authority', () {
    expect(
      selectMedicationSyncSteps(
        const CapabilitySnapshot.unavailable(),
        hasRetainedSplitCheckpoints: true,
      ),
      isEmpty,
    );
  });

  test('retained split checkpoints reconcile before inactive bridge work', () {
    const capabilities = CapabilitySnapshot.present(
      ServerCapabilities(
        medicationLedgerActive: false,
        minimumClientBuild: 2,
        serverRelease: 'fixture',
      ),
    );
    expect(
      selectMedicationSyncSteps(
        capabilities,
        hasRetainedSplitCheckpoints: true,
      ),
      [
        MedicationSyncStep.permanentReconciliation,
        MedicationSyncStep.inactiveBridge,
      ],
    );
  });

  test('first return after activation reconciles before active v2 work', () {
    const capabilities = CapabilitySnapshot.present(
      ServerCapabilities(
        medicationLedgerActive: true,
        minimumClientBuild: 2,
        serverRelease: 'fixture',
      ),
    );
    expect(
      selectMedicationSyncSteps(
        capabilities,
        hasRetainedSplitCheckpoints: true,
      ),
      [
        MedicationSyncStep.permanentReconciliation,
        MedicationSyncStep.activeLedger,
      ],
    );
  });

  test(
    'gives each retained subeffect a distinct server checkpoint identity',
    () async {
      final db = AppDatabase.forTesting();
      final dio = MockDio();
      const userId = 'user-1';
      const commandId = '00000000-0000-5000-8000-000000000002';
      const serverDoseId = '00000000-0000-5000-8000-000000000003';
      const serverPillId = '00000000-0000-5000-8000-000000000004';
      final now = DateTime.utc(2026, 9, 25);
      addTearDown(db.close);
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: userId,
          email: 'late-reconciliation@example.invalid',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final recorded = await PendingOperationRepository(db).record(
        operation: const PendingOperationDraft(
          userId: userId,
          mutationId: commandId,
          component: 'medication',
          operationType: 'medication.command',
          entityType: 'pill',
          entityLocalId: 'pill-local',
          payload: {
            'command': {'commandId': commandId, 'doseLogId': serverDoseId},
            'inventoryCommand': {
              'commandId': commandId,
              'pillId': serverPillId,
              'initialStock': 5,
            },
          },
          effects: [
            PendingOperationEffectDraft(
              kind: 'dose',
              legacySourceId: serverDoseId,
              requestFingerprint: 'dose-request-fingerprint',
            ),
            PendingOperationEffectDraft(
              kind: 'inventory',
              legacySourceId: serverPillId,
              requestFingerprint: 'inventory-request-fingerprint',
            ),
          ],
        ),
        applyProjection: () async {},
      );
      final effects = await db.pendingOperationsDao.getEffects(
        recorded.operationId,
      );
      expect(effects, hasLength(2));
      for (final effect in effects) {
        expect(
          await db.pendingOperationsDao.markEffectSending(effect.id, now),
          isTrue,
        );
        expect(
          await db.pendingOperationsDao.acknowledgeEffect(
            effectId: effect.id,
            safeServerId: effect.legacySourceId!,
            safeResultFingerprint: 'acknowledged-${effect.kind}-fingerprint',
            acknowledgedAt: now,
          ),
          isTrue,
        );
      }
      final operation = await db.pendingOperationsDao.getById(
        recorded.operationId,
      );
      final postedBodies = <Map<String, Object?>>[];
      when(() => dio.post<dynamic>(any(), data: any(named: 'data'))).thenAnswer(
        (invocation) async {
          final body = invocation.namedArguments[#data] as Map<String, Object?>;
          postedBodies.add(body);
          final path = invocation.positionalArguments.first as String;
          return Response<dynamic>(
            requestOptions: RequestOptions(path: path),
            data: {
              'issue': {'id': body['issueId']},
            },
          );
        },
      );

      final result = await PermanentMedicationReconciliationAdapter(
        db: db,
        dio: dio,
      ).reconcile(operation!);

      expect(result.status, MedicationMutationStatus.blocked);
      expect(postedBodies, hasLength(2));
      expect(
        postedBodies.map((body) => body['commandId']).toSet(),
        hasLength(2),
      );
      expect(
        postedBodies.every((body) => body['commandId'] != commandId),
        isTrue,
      );
      verify(
        () => dio.post<dynamic>(
          '/medication/legacy-split/reconcile',
          data: any(named: 'data'),
        ),
      ).called(2);
    },
  );
}
