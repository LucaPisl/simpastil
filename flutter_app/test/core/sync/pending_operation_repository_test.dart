import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/legacy_split_checkpoint.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';

void main() {
  late AppDatabase db;
  late PendingOperationRepository repository;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: 'user-1',
            email: 'user@test.com',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
    repository = PendingOperationRepository(db);
  });

  tearDown(() => db.close());

  test(
    'intent and projection roll back together when projection fails',
    () async {
      await expectLater(
        repository.record(
          operation: const PendingOperationDraft(
            userId: 'user-1',
            operationType: 'profile.create',
            entityType: 'profile',
            entityLocalId: 'local-profile',
            payload: {
              'action': 'create',
              'data': {'name': 'Ada'},
            },
          ),
          applyProjection: () async => throw StateError('projection failed'),
        ),
        throwsStateError,
      );
      expect(await db.pendingOperationsDao.getForUser('user-1'), isEmpty);
    },
  );

  test('child operations depend on their parent operation ID', () async {
    await repository.recordAtomically(
      operations: const [
        PendingOperationDraft(
          userId: 'user-1',
          operationType: 'profile.create',
          entityType: 'profile',
          entityLocalId: 'profile-local',
          payload: {
            'action': 'create',
            'data': {'name': 'Ada'},
          },
        ),
        PendingOperationDraft(
          userId: 'user-1',
          operationType: 'pill.create',
          entityType: 'pill',
          entityLocalId: 'pill-local',
          parentEntityType: 'profile',
          parentEntityLocalId: 'profile-local',
          payload: {
            'action': 'create',
            'data': {'name': 'Medication'},
          },
        ),
        PendingOperationDraft(
          userId: 'user-1',
          operationType: 'schedule.create',
          entityType: 'schedule',
          entityLocalId: 'schedule-local',
          parentEntityType: 'pill',
          parentEntityLocalId: 'pill-local',
          payload: {
            'action': 'create',
            'data': {'hour': 8},
          },
        ),
      ],
      applyProjection: () async {},
    );

    final operations = await db.pendingOperationsDao.getForUser('user-1');
    expect(operations, hasLength(3));
    final profileCreate = operations.singleWhere(
      (operation) => operation.operationType == 'profile.create',
    );
    final pillCreate = operations.singleWhere(
      (operation) => operation.operationType == 'pill.create',
    );
    final scheduleCreate = operations.singleWhere(
      (operation) => operation.operationType == 'schedule.create',
    );
    expect(pillCreate.dependsOnOperationId, profileCreate.id);
    expect(scheduleCreate.dependsOnOperationId, pillCreate.id);
  });

  test(
    'replaying a deterministic medication mutation does not reproject',
    () async {
      var projections = 0;
      const draft = PendingOperationDraft(
        userId: 'user-1',
        mutationId: '00000000-0000-5000-8000-000000000001',
        component: 'medication',
        operationType: 'medication.command',
        entityType: 'occurrence',
        entityLocalId: 'occurrence-1',
        payload: {'commandId': '00000000-0000-5000-8000-000000000001'},
        effects: [
          PendingOperationEffectDraft(
            kind: 'dose',
            legacySourceId: 'dose-source-1',
            requestFingerprint: 'fingerprint-1',
          ),
        ],
      );

      final first = await repository.record(
        operation: draft,
        applyProjection: () async {
          projections++;
        },
      );
      final replay = await repository.record(
        operation: draft,
        applyProjection: () async {
          projections++;
        },
      );

      expect(replay.operationId, first.operationId);
      expect(replay.mutationId, first.mutationId);
      expect(projections, 1);
      expect(await db.pendingOperationsDao.getForUser('user-1'), hasLength(1));
      expect(
        await db.pendingOperationsDao.getEffects(first.operationId),
        hasLength(1),
      );
    },
  );

  test('split effects must acknowledge in ordinal order', () async {
    final recorded = await repository.record(
      operation: const PendingOperationDraft(
        userId: 'user-1',
        component: 'medication',
        operationType: 'medication.command',
        entityType: 'occurrence',
        entityLocalId: 'occurrence-1',
        payload: {'commandId': 'command-1'},
        effects: [
          PendingOperationEffectDraft(
            kind: 'dose',
            requestFingerprint: 'dose-fingerprint',
          ),
          PendingOperationEffectDraft(
            kind: 'inventory',
            requestFingerprint: 'inventory-fingerprint',
          ),
        ],
      ),
      applyProjection: () async {},
    );
    final effects = await db.pendingOperationsDao.getEffects(
      recorded.operationId,
    );
    final now = DateTime.now().toUtc();

    expect(
      await db.pendingOperationsDao.markEffectSending(effects[1].id, now),
      isFalse,
    );
    expect(
      await db.pendingOperationsDao.markEffectSending(effects[0].id, now),
      isTrue,
    );
    expect(
      await db.pendingOperationsDao.acknowledgeEffect(
        effectId: effects[0].id,
        safeServerId: 'dose-server-id',
        safeResultFingerprint: 'dose-result',
        acknowledgedAt: now,
      ),
      isTrue,
    );
    expect(
      await db.pendingOperationsDao.markEffectSending(effects[1].id, now),
      isTrue,
    );
    expect(
      await db.pendingOperationsDao.acknowledgeEffect(
        effectId: effects[1].id,
        safeServerId: 'inventory-server-id',
        safeResultFingerprint: 'inventory-result',
        acknowledgedAt: now,
      ),
      isTrue,
    );
    for (final effect in effects) {
      expect(
        await db.pendingOperationsDao.markEffectCheckpointRecorded(
          effectId: effect.id,
          receiptId: 'issue-${effect.ordinal}',
        ),
        isTrue,
      );
    }
    final checkpoint = await LegacySplitCheckpoint.load(
      db,
      recorded.operationId,
    );
    expect(checkpoint?.isReconciliationRecorded, isTrue);
    expect(checkpoint?.hasRetainedProgress, isFalse);
  });

  test(
    'authentication rejection returns an unacknowledged split effect to retry',
    () async {
      final recorded = await repository.record(
        operation: const PendingOperationDraft(
          userId: 'user-1',
          component: 'medication',
          operationType: 'medication.command',
          entityType: 'occurrence',
          entityLocalId: 'occurrence-auth',
          payload: {'commandId': 'command-auth'},
          effects: [
            PendingOperationEffectDraft(
              kind: 'dose',
              requestFingerprint: 'dose-auth-fingerprint',
            ),
          ],
        ),
        applyProjection: () async {},
      );
      final effect = (await db.pendingOperationsDao.getEffects(
        recorded.operationId,
      )).single;
      final now = DateTime.now().toUtc();

      expect(
        await db.pendingOperationsDao.markEffectSending(effect.id, now),
        isTrue,
      );
      expect(
        await db.pendingOperationsDao.markEffectRetryable(effect.id),
        isTrue,
      );

      expect(
        (await db.pendingOperationsDao.getEffects(
          recorded.operationId,
        )).single.state,
        'queued',
      );
      expect(
        (await db.pendingOperationsDao.getById(recorded.operationId))?.state,
        'failedRetryable',
      );
      expect(await db.pendingOperationsDao.getReady('user-1'), hasLength(1));
    },
  );

  test(
    'interrupted sends block for review instead of auto-replaying',
    () async {
      final recorded = await repository.record(
        operation: const PendingOperationDraft(
          userId: 'user-1',
          operationType: 'profile.create',
          entityType: 'profile',
          entityLocalId: 'profile-local',
          payload: {
            'action': 'create',
            'data': {'name': 'Ada'},
          },
        ),
        applyProjection: () async {},
      );
      await repository.claimNext('user-1');

      expect(
        await db.pendingOperationsDao.recoverInterruptedOperations(
          userId: 'user-1',
        ),
        1,
      );
      expect(
        (await db.pendingOperationsDao.getById(recorded.operationId))?.state,
        'blocked',
      );
      expect(await db.migrationIssuesDao.getUnresolved('user-1'), hasLength(1));
    },
  );

  test('a partly recorded batch records the missing drafts only', () async {
    const shared = PendingOperationDraft(
      userId: 'user-1',
      mutationId: '00000000-0000-5000-8000-0000000000aa',
      component: 'medication',
      operationType: 'inventory.correct',
      entityType: 'pill',
      entityLocalId: 'pill-x',
      payload: {'n': 1},
    );
    await repository.recordAtomically(
      operations: const [shared],
      applyProjection: () async {},
    );
    var projections = 0;
    await repository.recordAtomically(
      operations: const [
        PendingOperationDraft(
          userId: 'user-1',
          operationType: 'pill.update',
          entityType: 'pill',
          entityLocalId: 'pill-x',
          payload: {'n': 2},
        ),
        shared,
      ],
      applyProjection: () async => projections++,
    );
    final ops = await db.pendingOperationsDao.getForUser('user-1');
    expect(ops, hasLength(2));
    expect(projections, 1);
  });

  test(
    'a partly recorded batch with a different intent still refuses',
    () async {
      const first = PendingOperationDraft(
        userId: 'user-1',
        mutationId: '00000000-0000-5000-8000-0000000000bb',
        component: 'medication',
        operationType: 'inventory.correct',
        entityType: 'pill',
        entityLocalId: 'pill-x',
        payload: {'n': 1},
      );
      await repository.recordAtomically(
        operations: const [first],
        applyProjection: () async {},
      );
      await expectLater(
        repository.recordAtomically(
          operations: const [
            PendingOperationDraft(
              userId: 'user-1',
              operationType: 'pill.update',
              entityType: 'pill',
              entityLocalId: 'pill-x',
              payload: {'n': 2},
            ),
            PendingOperationDraft(
              userId: 'user-1',
              mutationId: '00000000-0000-5000-8000-0000000000bb',
              component: 'medication',
              operationType: 'inventory.correct',
              entityType: 'pill',
              entityLocalId: 'pill-x',
              payload: {'n': 99},
            ),
          ],
          applyProjection: () async {},
        ),
        throwsStateError,
      );
      expect(await db.pendingOperationsDao.getForUser('user-1'), hasLength(1));
    },
  );
}
