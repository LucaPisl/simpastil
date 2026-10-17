import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';

void main() {
  late AppDatabase db;
  final now = DateTime.utc(2026, 9, 25, 12);

  setUp(() async {
    db = AppDatabase.forTesting();
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: 'user-1',
        email: 'u@example.test',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() async => db.close());

  Future<void> disableForeignKeys() async {
    await db.customStatement('PRAGMA foreign_keys = OFF');
    final result = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(result.read<int>('foreign_keys'), 0);
  }

  Future<void> stageRun({
    required String id,
    String component = 'medication',
    required bool finalPage,
  }) async {
    await db.syncStateDao.beginRun(
      SyncStagingRunsCompanion.insert(
        id: id,
        userId: 'user-1',
        component: component,
        contractVersion: 2,
        afterSequence: '0',
        throughSequence: '1',
        startedAt: now,
      ),
    );
    await db.syncStateDao.stagePage(
      runId: id,
      items: [
        SyncStagingItemsCompanion.insert(
          runId: id,
          serverSequence: 1,
          entityType: 'profile',
          entityId: 'entity-$id',
          payloadJson: '{}',
        ),
      ],
      nextCursor: 'cursor-$id',
      isFinalPage: finalPage,
    );
  }

  test('pending operations wait for committed dependencies', () async {
    await db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'parent',
        userId: 'user-1',
        mutationId: 'mutation-parent',
        component: 'stable',
        operationType: 'profile-upsert',
        contractVersion: 2,
        payloadJson: '{}',
        createdAt: now,
      ),
    );
    await db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'child',
        userId: 'user-1',
        mutationId: 'mutation-child',
        component: 'stable',
        operationType: 'pill-upsert',
        contractVersion: 2,
        payloadJson: '{}',
        dependsOnOperationId: const Value('parent'),
        createdAt: now,
      ),
    );

    expect(
      (await db.pendingOperationsDao.getReady('user-1')).map((row) => row.id),
      ['parent'],
    );
    expect(
      await db.pendingOperationsDao.transitionState(
        operationId: 'parent',
        from: 'queued',
        to: 'sending',
        attemptedAt: now,
      ),
      isTrue,
    );
    expect(
      await db.pendingOperationsDao.transitionState(
        operationId: 'parent',
        from: 'sending',
        to: 'committed',
      ),
      isTrue,
    );
    expect(
      (await db.pendingOperationsDao.getReady('user-1')).map((row) => row.id),
      ['child'],
    );
  });

  test('interrupted split effects become uncertain and block replay', () async {
    await db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'operation',
        userId: 'user-1',
        mutationId: 'mutation',
        component: 'medication',
        operationType: 'legacy-split',
        contractVersion: 1,
        payloadJson: '{}',
        createdAt: now,
      ),
      effects: [
        PendingOperationEffectsCompanion.insert(
          id: 'effect',
          operationId: 'operation',
          ordinal: 0,
          kind: 'dose',
          requestFingerprint: 'stable-fingerprint',
        ),
      ],
    );

    expect(
      await db.pendingOperationsDao.markEffectSending('effect', now),
      isTrue,
    );
    expect(await db.pendingOperationsDao.recoverInterruptedEffects(), 1);
    expect(
      (await db.pendingOperationsDao.getEffects('operation')).single.state,
      'uncertain',
    );
    expect((await db.pendingOperationsDao.getReady('user-1')), isEmpty);
  });

  test(
    'sync cursor advances only after the final staged page is merged',
    () async {
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: 'user-1',
          component: 'medication',
          contractVersion: 2,
          lastCompletedCursor: const Value('previous-cursor'),
        ),
      );
      await db.syncStateDao.beginRun(
        SyncStagingRunsCompanion.insert(
          id: 'run-1',
          userId: 'user-1',
          component: 'medication',
          contractVersion: 2,
          afterSequence: '0',
          throughSequence: '2',
          startedAt: now,
        ),
      );
      await db.syncStateDao.stagePage(
        runId: 'run-1',
        items: [
          SyncStagingItemsCompanion.insert(
            runId: 'run-1',
            serverSequence: 1,
            entityType: 'occurrence',
            entityId: 'occurrence-1',
            payloadJson: '{}',
          ),
        ],
        nextCursor: 'next-page',
        isFinalPage: false,
      );

      var merged = false;
      await expectLater(
        db.syncStateDao.commitRunAfterMerge(
          runId: 'run-1',
          merge: (_) async {
            merged = true;
          },
          completedAt: now,
        ),
        throwsStateError,
      );
      expect(merged, isFalse);
      expect(
        (await db.syncStateDao.getState(
          'user-1',
          'medication',
        ))?.lastCompletedCursor,
        'previous-cursor',
      );

      await db.syncStateDao.stagePage(
        runId: 'run-1',
        items: [
          SyncStagingItemsCompanion.insert(
            runId: 'run-1',
            serverSequence: 2,
            entityType: 'occurrence',
            entityId: 'occurrence-2',
            payloadJson: '{}',
          ),
        ],
        nextCursor: null,
        isFinalPage: true,
      );
      await db.syncStateDao.commitRunAfterMerge(
        runId: 'run-1',
        merge: (items) async {
          merged = items.length == 2;
        },
        completedAt: now,
      );
      expect(merged, isTrue);
      expect(
        (await db.syncStateDao.getState(
          'user-1',
          'medication',
        ))?.lastFullSuccessAt?.toUtc(),
        now.toUtc(),
      );
    },
  );

  test(
    'discarding sync runs removes only their staged rows when foreign keys are off',
    () async {
      await disableForeignKeys();
      await stageRun(id: 'incomplete-medication', finalPage: false);
      await stageRun(
        id: 'incomplete-stable',
        component: 'stable',
        finalPage: false,
      );
      await stageRun(id: 'complete-medication', finalPage: true);
      await db
          .into(db.syncStagingItems)
          .insert(
            SyncStagingItemsCompanion.insert(
              runId: 'legacy-orphan',
              serverSequence: 99,
              entityType: 'profile',
              entityId: 'legacy-orphan',
              payloadJson: '{}',
            ),
          );

      expect(
        await db.syncStateDao.discardIncompleteRuns('user-1', 'medication'),
        1,
      );

      expect(
        await db.syncStateDao.getStagedItems('incomplete-medication'),
        isEmpty,
      );
      expect(
        (await db.syncStateDao.getStagedItems(
          'incomplete-stable',
        )).single.entityId,
        'entity-incomplete-stable',
      );
      expect(
        (await db.syncStateDao.getStagedItems(
          'complete-medication',
        )).single.entityId,
        'entity-complete-medication',
      );

      expect(await db.syncStateDao.discardRun('complete-medication'), 1);
      expect(
        await db.syncStateDao.getStagedItems('complete-medication'),
        isEmpty,
      );
      expect(
        (await db.syncStateDao.getStagedItems(
          'incomplete-stable',
        )).single.entityId,
        'entity-incomplete-stable',
      );
      expect(await db.select(db.syncStagingRuns).get(), hasLength(1));
      expect(await db.syncStateDao.discardRun('legacy-orphan'), 0);
      expect(
        (await db.syncStateDao.getStagedItems('legacy-orphan')).single.entityId,
        'legacy-orphan',
      );
    },
  );

  test(
    'committing a sync run removes its staged rows but keeps other runs',
    () async {
      await disableForeignKeys();
      await stageRun(id: 'commit-me', finalPage: true);
      await stageRun(id: 'keep-me', component: 'stable', finalPage: true);

      var mergedEntity = '';
      await db.syncStateDao.commitRunAfterMerge(
        runId: 'commit-me',
        merge: (items) async {
          mergedEntity = items.single.entityId;
        },
        completedAt: now,
      );

      expect(mergedEntity, 'entity-commit-me');
      expect(await db.syncStateDao.getStagedItems('commit-me'), isEmpty);
      expect(
        (await db.syncStateDao.getStagedItems('keep-me')).single.entityId,
        'entity-keep-me',
      );
      expect((await db.select(db.syncStagingRuns).get()).map((run) => run.id), [
        'keep-me',
      ]);
    },
  );

  test('a failed sync merge retains its run and staged rows', () async {
    await disableForeignKeys();
    await stageRun(id: 'failed-merge', finalPage: true);

    await expectLater(
      db.syncStateDao.commitRunAfterMerge(
        runId: 'failed-merge',
        merge: (_) async => throw StateError('merge rejected'),
        completedAt: now,
      ),
      throwsStateError,
    );

    expect(await db.select(db.syncStagingRuns).get(), hasLength(1));
    expect(
      (await db.syncStateDao.getStagedItems('failed-merge')).single.entityId,
      'entity-failed-merge',
    );
    expect(await db.syncStateDao.getState('user-1', 'medication'), isNull);
  });

  test(
    'append-only medication events produce the exact inventory balance',
    () async {
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: 'occurrence-1',
          userId: 'user-1',
          occurrenceKey: 'prn:one',
          source: 'prn',
          plannedLocalDate: '2026-09-25',
          timeZone: 'Europe/Bucharest',
          scheduleSnapshotJson: '{}',
          provenance: 'exact',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: 'event-1',
          userId: 'user-1',
          occurrenceId: 'occurrence-1',
          commandId: 'command-1',
          action: 'take',
          fromState: 'pending',
          toState: 'taken',
          origin: 'native',
          baseVersion: 0,
          resultVersion: 1,
          recordedAt: now,
        ),
      );
      await db.medicationLedgerDao.appendInventoryEvent(
        InventoryEventsCompanion.insert(
          id: 'opening',
          userId: 'user-1',
          pillId: 'pill-1',
          commandId: 'opening-command',
          kind: 'opening',
          delta: 5,
          origin: 'legacy_backfill',
          recordedAt: now,
        ),
      );
      await db.medicationLedgerDao.appendInventoryEvent(
        InventoryEventsCompanion.insert(
          id: 'dose',
          userId: 'user-1',
          pillId: 'pill-1',
          commandId: 'command-1',
          kind: 'dose',
          delta: -1,
          occurrenceEventId: const Value('event-1'),
          origin: 'native',
          recordedAt: now,
        ),
      );

      expect(await db.medicationLedgerDao.getInventoryBalance('pill-1'), 4);
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence('occurrence-1'),
        hasLength(1),
      );
    },
  );
}
