import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/sync_error_classifier.dart';
import 'package:simpastil/core/sync/sync_recovery_service.dart';
import 'package:simpastil/core/sync/sync_retry_policy.dart';

const _userId = 'user-1';
final _now = DateTime.utc(2026, 10, 14, 8);

void main() {
  late AppDatabase db;
  late SyncRecoveryService service;
  late List<String> calls;
  var sequence = 0;

  setUp(() async {
    sequence = 0;
    calls = [];
    db = AppDatabase.forTesting();
    addTearDown(db.close);
    service = SyncRecoveryService(
      db: db,
      flush: (_) async => calls.add('flush'),
      pull: (_) async {
        calls.add('pull');
        return true;
      },
      write: <T>(_, action) => db.transaction(action),
      now: () => _now,
    );
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: _userId,
        email: 'secret.person@example.invalid',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
  });

  Future<void> profile(
    String id,
    String name, {
    String status = 'synced',
    int revision = 3,
  }) => db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: id,
      userId: _userId,
      name: name,
      createdAt: _now,
      updatedAt: _now,
      serverId: Value(id),
      revision: Value(revision),
      syncStatus: Value(status),
    ),
  );

  Future<void> pill(
    String id,
    String profileId,
    String name, {
    String status = 'synced',
  }) => db.pillsDao.upsert(
    PillsCompanion.insert(
      id: id,
      profileId: profileId,
      name: name,
      createdAt: _now,
      updatedAt: _now,
      serverId: Value(id),
      syncStatus: Value(status),
    ),
  );

  Future<void> schedule(String id, String pillId, {String status = 'synced'}) =>
      db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: id,
          pillId: pillId,
          hour: 8,
          minute: 30,
          frequency: 'daily',
          createdAt: _now,
          updatedAt: _now,
          syncStatus: Value(status),
        ),
      );

  Future<void> op(
    String id,
    String state, {
    String type = 'profile.update',
    String entity = 'profile',
    String? local,
    String? parent,
    String? dependsOn,
    String component = 'stable',
    int attempts = 0,
    String? code,
    Map<String, Object?> extra = const {},
    Map<String, Object?> data = const {'name': 'Mine'},
    DateTime? lastAttemptAt,
  }) => db
      .into(db.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          id: id,
          userId: _userId,
          mutationId: 'm-$id',
          component: component,
          operationType: type,
          contractVersion: 2,
          payloadJson: jsonEncode({
            'action': type.split('.').last,
            'data': data,
            'entityType': entity,
            'entityLocalId': local ?? 'p-$id',
            'parentEntityLocalId': ?parent,
            ...extra,
          }),
          state: Value(state),
          dependsOnOperationId: Value(dependsOn),
          attemptCount: Value(attempts),
          safeErrorCode: Value(code),
          lastAttemptAt: Value(lastAttemptAt),
          createdAt: _now.add(Duration(seconds: sequence++)),
        ),
      );

  Future<PendingOperation> row(String id) async =>
      (await db.pendingOperationsDao.getById(id))!;

  Future<void> issue(
    String id,
    String code,
    String entityId,
    String op, {
    String? deletedAt,
  }) => db.migrationIssuesDao.record(
    MigrationIssuesCompanion.insert(
      id: id,
      userId: _userId,
      entityType: 'profile',
      entityId: entityId,
      issueCode: code,
      snapshotJson: jsonEncode({
        'operationId': op,
        'serverEntity': {'revision': '9', 'deletedAt': ?deletedAt},
      }),
      createdAt: _now,
      updatedAt: _now,
    ),
  );

  group('diagnose', () {
    test('groups unsent changes by item with a reason for each', () async {
      await profile('prof', 'Ana', status: 'pending');
      await pill('pil', 'prof', 'Aspirin');
      await op('blocked', 'blocked', local: 'prof', code: 'SOME_CODE');
      await op('stranded', 'queued', local: 'prof', dependsOn: 'blocked');
      await op(
        'retry',
        'failedRetryable',
        entity: 'pill',
        local: 'pil',
        type: 'pill.update',
        attempts: 2,
        lastAttemptAt: _now,
      );
      await op('wait', 'queued', entity: 'schedule', type: 'schedule.create');
      await op('done', 'committed', local: 'prof');
      await op('gone', 'discarded', local: 'prof');

      final report = await service.diagnose(_userId);

      expect(report.items, hasLength(3));
      final person = report.items.firstWhere(
        (i) => i.kind == RecoveryItemKind.person,
      );
      expect(person.name, 'Ana');
      expect(person.reason, RecoveryReason.blocked);
      expect(person.operations.map((o) => o.reason), [
        RecoveryReason.blocked,
        RecoveryReason.stranded,
      ]);
      expect(person.canRetry, isTrue);
      expect(person.canUseServerVersion, isTrue);
      final medication = report.items.firstWhere(
        (i) => i.kind == RecoveryItemKind.medication,
      );
      expect(medication.reason, RecoveryReason.retrying);
      expect(
        medication.nextAttemptAt,
        SyncRetryPolicy.notBefore(_now, 2),
        reason: 'the next attempt time comes from the backoff ladder',
      );
      expect(medication.canUseServerVersion, isFalse);
      expect(
        report.items
            .firstWhere((i) => i.kind == RecoveryItemKind.schedule)
            .reason,
        RecoveryReason.queued,
      );
      expect(report.counts.blocked, 1);
      expect(report.counts.stranded, 1);
    });

    group('stock effects held behind the opening (R1)', () {
      Future<void> start(String state, {String? code}) => op(
        'start',
        state,
        component: 'medication',
        type: 'inventory.start',
        local: 'pil-x',
        code: code,
        extra: {
          'inventoryCommand': {
            'action': 'start',
            'pillId': 'pil-x',
            'initialStock': 10,
          },
        },
      );
      Future<void> heldDose(String code) => op(
        'dose',
        'queued',
        component: 'medication',
        type: 'medication.command',
        local: 'occ-x',
        code: code,
        extra: {
          'command': {'commandId': 'c-dose', 'occurrenceId': 'occ-x'},
          'localProjection': {'pillId': 'pil-x'},
        },
      );

      test(
        'behind a stuck opening it is stranded, with its own text',
        () async {
          await start('blocked', code: 'MEDICATION_INVENTORY_RESULT_UNCERTAIN');
          await heldDose('INVENTORY_START_PENDING');
          final report = await service.diagnose(_userId);
          final dose = report.items
              .expand((i) => i.operations)
              .firstWhere((o) => o.id == 'dose');
          expect(dose.reason, RecoveryReason.stranded);
          expect(dose.waitingForStart, isTrue);
          expect(report.counts.stranded, 1);
          expect(report.counts.blocked, 1);
          expect(report.counts.needsAttention, 2);
        },
      );

      test(
        'behind an opening still on its way it is ordinary waiting',
        () async {
          await start('queued');
          await heldDose('INVENTORY_START_PENDING');
          final report = await service.diagnose(_userId);
          final dose = report.items
              .expand((i) => i.operations)
              .firstWhere((o) => o.id == 'dose');
          expect(dose.reason, RecoveryReason.queued);
          expect(dose.waitingForStart, isTrue);
          expect(report.counts.stranded, 0);
          expect(report.counts.needsAttention, 0);
        },
      );

      test('an opening waiting for review is stranded itself', () async {
        await op(
          'start',
          'queued',
          component: 'medication',
          type: 'inventory.start',
          local: 'pil-x',
          code: 'INVENTORY_START_WAITS_FOR_REVIEW',
          extra: {
            'inventoryCommand': {'action': 'start', 'pillId': 'pil-x'},
          },
        );
        final report = await service.diagnose(_userId);
        expect(
          report.items.single.operations.single.reason,
          RecoveryReason.stranded,
        );
        expect(report.counts.stranded, 1);
      });

      test(
        'an opening in conflict is a review item to discard or replace',
        () async {
          await start('conflict', code: 'INVENTORY_START_STOCK_UNKNOWN');
          final item = (await service.diagnose(_userId)).items.single;
          expect(item.reason, RecoveryReason.conflict);
          expect(item.canUseServerVersion, isTrue);
          expect(item.canDiscard, isTrue);
          expect(item.needsMedicationReview, isTrue);
        },
      );
    });

    test('is empty when nothing is unsent', () async {
      await op('done', 'committed');
      await op('gone', 'discarded');
      final report = await service.diagnose(_userId);
      expect(report.isEmpty, isTrue);
      expect(report.counts.isSettled, isTrue);
    });

    test('a create with dose history cannot be discarded', () async {
      await profile('prof', 'Ana');
      await pill('pil', 'prof', 'Aspirin', status: 'pending');
      await schedule('sch', 'pil', status: 'pending');
      await db
          .into(db.doseLogs)
          .insert(
            DoseLogsCompanion.insert(
              id: 'dose',
              scheduleId: 'sch',
              scheduledAt: _now,
              status: 'taken',
              createdAt: _now,
              updatedAt: _now,
            ),
          );
      await op(
        'create',
        'blocked',
        entity: 'pill',
        local: 'pil',
        type: 'pill.create',
      );

      final item = (await service.diagnose(_userId)).items.single;

      expect(item.discardBlockedByHistory, isTrue);
      expect(item.canUseServerVersion, isFalse);
      expect(
        (await service.useServerVersion(_userId, item.key)).refusal,
        RecoveryRefusal.hasDoseHistory,
      );
      expect((await row('create')).state, 'blocked');
      expect(calls, isEmpty);
    });

    test('events of discarded commands are not dose history', () async {
      await profile('prof', 'Ana');
      await pill('pil', 'prof', 'Aspirin', status: 'pending');
      await schedule('sch', 'pil', status: 'pending');
      await db
          .into(db.medicationOccurrences)
          .insert(
            MedicationOccurrencesCompanion.insert(
              id: 'occ',
              userId: _userId,
              pillId: const Value('pil'),
              scheduleId: const Value('sch'),
              occurrenceKey: 'k',
              source: 'scheduled',
              plannedLocalDate: '2026-10-14',
              timeZone: 'UTC',
              scheduleSnapshotJson: '{}',
              provenance: 'exact',
              createdAt: _now,
              updatedAt: _now,
            ),
          );
      Future<void> event(String id, String commandId) => db
          .into(db.occurrenceEvents)
          .insert(
            OccurrenceEventsCompanion.insert(
              id: id,
              userId: _userId,
              occurrenceId: 'occ',
              commandId: commandId,
              action: 'take',
              fromState: 'pending',
              toState: 'taken',
              origin: 'native',
              baseVersion: 0,
              resultVersion: 1,
              recordedAt: _now,
            ),
          );
      await event('ev', 'm-gone');
      await op(
        'gone',
        'discarded',
        entity: 'occurrence',
        local: 'occ',
        type: 'medication.command',
        component: 'medication',
      );
      await op(
        'create',
        'blocked',
        entity: 'pill',
        local: 'pil',
        type: 'pill.create',
      );

      var item = (await service.diagnose(_userId)).items.single;
      expect(item.discardBlockedByHistory, isFalse);
      expect(item.canUseServerVersion, isTrue);

      // A committed command's event is real history again.
      await event('ev2', 'm-sent');
      await op(
        'sent',
        'committed',
        entity: 'occurrence',
        local: 'occ',
        type: 'medication.command',
        component: 'medication',
      );
      item = (await service.diagnose(_userId)).items.single;
      expect(item.discardBlockedByHistory, isTrue);
    });

    test('a blocked dose change has no server-version path', () async {
      await op(
        'dose',
        'blocked',
        entity: 'occurrence',
        local: 'occ',
        type: 'medication.command',
        component: 'medication',
        code: 'SOME_CODE',
      );
      final item = (await service.diagnose(_userId)).items.single;
      expect(item.kind, RecoveryItemKind.dose);
      expect(item.canRetry, isTrue);
      expect(item.canUseServerVersion, isFalse);
      expect(
        (await service.useServerVersion(_userId, item.key)).refusal,
        RecoveryRefusal.notDiscardable,
      );
      expect((await row('dose')).state, 'blocked');
    });

    test('a conflict already settled for the server offers Dismiss', () async {
      await profile('prof', 'Ana');
      await op('c', 'conflict', local: 'prof');
      await issue('i', 'stable_revision_conflict_server_wins', 'prof', 'c');

      final item = (await service.diagnose(_userId)).items.single;

      expect(item.reason, RecoveryReason.conflict);
      expect(item.canDismiss, isTrue);
      expect(item.canKeepMine, isTrue);
      expect(item.canUseServerVersion, isFalse);
    });

    test('a ledger conflict can use the server version', () async {
      await op(
        'ledger',
        'conflict',
        entity: 'occurrence',
        local: 'occ',
        type: 'medication.command',
        component: 'medication',
      );
      final item = (await service.diagnose(_userId)).items.single;
      expect(item.needsMedicationReview, isTrue);
      expect(item.canDismiss, isFalse);
      expect(item.canUseServerVersion, isTrue);
      expect(item.hasAction, isTrue);
    });
  });

  group('retryAll', () {
    test('requeues blocked and retrying changes under the same ids, '
        'keeps a frozen body, then flushes before pulling', () async {
      const frozen = {
        'path': '/profiles/p',
        'body': {'mutationId': 'm-b'},
      };
      await op(
        'b',
        'blocked',
        attempts: 3,
        code: 'STABLE_REQUEST_BODY_CHANGED',
        extra: {'frozenRequest': frozen},
      );
      await op(
        'r',
        'failedRetryable',
        attempts: 2,
        lastAttemptAt: _now,
        code: 'X',
      );
      await op('c', 'conflict');
      await op('committed', 'committed');

      final outcome = await service.retryAll(_userId);

      expect(outcome.affected, 2);
      expect(calls, ['flush', 'pull']);
      final blocked = await row('b');
      expect(blocked.state, 'queued');
      expect(blocked.mutationId, 'm-b');
      expect(blocked.attemptCount, 3, reason: 'the retry budget is not reset');
      expect(blocked.safeErrorCode, isNull);
      expect(jsonDecode(blocked.payloadJson)['frozenRequest'], frozen);
      final retry = await row('r');
      expect(retry.state, 'queued');
      expect(retry.attemptCount, 2);
      expect(retry.lastAttemptAt, isNull);
      expect((await row('c')).state, 'conflict');
      expect((await row('committed')).state, 'committed');
    });

    test(
      'an exhausted retry budget is refilled and its issue closed',
      () async {
        await op(
          'e',
          'blocked',
          attempts: SyncRetryPolicy.maxAttempts,
          code: SyncRetryPolicy.retryExhaustedCode,
        );
        await issue('i', SyncRetryPolicy.retryExhaustedIssueCode, 'e', 'e');

        await service.retryAll(_userId);

        expect((await row('e')).attemptCount, 0);
        expect((await row('e')).state, 'queued');
        expect(await db.migrationIssuesDao.getUnresolved(_userId), isEmpty);
      },
    );

    test('evidence that only the review can settle stays blocked', () async {
      await op(
        'review',
        'blocked',
        component: 'medication',
        type: 'medication.command',
        entity: 'occurrence',
        code: 'MEDICATION_BRIDGE_RESULT_UNCERTAIN',
      );
      final outcome = await service.retryAll(_userId);
      expect(outcome.affected, 0);
      expect((await row('review')).state, 'blocked');
    });

    test('a busy sync reports busy instead of throwing', () async {
      final busy = SyncRecoveryService(
        db: db,
        flush: (_) async => throw const SyncBusyException(),
        pull: (_) async => true,
        write: <T>(_, action) => db.transaction(action),
      );
      await op('b', 'blocked', code: 'X');
      final outcome = await busy.retryAll(_userId);
      expect(outcome.busy, isTrue);
      expect((await row('b')).state, 'queued');
    });
  });

  group('useServerVersion', () {
    test('discards the edit, re-parents dependents, resets the row and '
        'the checkpoints, then flushes before pulling', () async {
      await profile('prof', 'Local edit', status: 'pending');
      await op('root', 'committed', local: 'prof', type: 'profile.create');
      await op(
        'edit',
        'conflict',
        local: 'prof',
        dependsOn: 'root',
        code: 'CONFLICT_REVISION',
      );
      await op('child', 'queued', local: 'prof', dependsOn: 'edit');
      // Another item's operation waiting on the dropped edit.
      await op(
        'other',
        'queued',
        entity: 'pill',
        local: 'pil',
        type: 'pill.update',
        parent: 'prof',
        dependsOn: 'edit',
      );
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: _userId,
          component: 'stable',
          contractVersion: 2,
          lastCompletedCursor: const Value('42'),
          lastFullSuccessAt: Value(_now),
        ),
      );
      final key = (await service.diagnose(
        _userId,
      )).items.firstWhere((i) => i.kind == RecoveryItemKind.person).key;

      final outcome = await service.useServerVersion(_userId, key);

      expect(outcome.ok, isTrue);
      expect((await row('edit')).state, 'discarded');
      expect((await row('child')).state, 'discarded');
      expect((await row('other')).state, 'queued');
      expect(
        (await row('other')).dependsOnOperationId,
        'root',
        reason: 're-parented onto the dropped edit\'s own parent',
      );
      expect((await db.profilesDao.getById('prof'))!.syncStatus, 'synced');
      final state = (await db.syncStateDao.getState(_userId, 'stable'))!;
      expect(state.lastCompletedCursor, isNull);
      expect(state.lastFullSuccessAt, isNotNull);
      expect(calls, ['flush', 'pull']);
    });

    test('a discarded create takes only its own dependents with it', () async {
      await profile('prof', 'New person', status: 'pending');
      await pill('pil', 'prof', 'New pill', status: 'pending');
      await schedule('sch', 'pil', status: 'pending');
      await op('p', 'blocked', local: 'prof', type: 'profile.create');
      await op(
        'm',
        'queued',
        entity: 'pill',
        local: 'pil',
        parent: 'prof',
        type: 'pill.create',
        dependsOn: 'p',
      );
      await op(
        'stock',
        'queued',
        entity: 'pill',
        local: 'pil',
        type: 'inventory.set',
        component: 'medication',
        dependsOn: 'm',
      );
      await profile('unrelated', 'Bea', status: 'pending');
      await op('u', 'queued', local: 'unrelated');

      final key = (await service.diagnose(
        _userId,
      )).items.firstWhere((i) => i.name == 'New person').key;
      final outcome = await service.useServerVersion(_userId, key);

      expect(outcome.ok, isTrue);
      for (final id in ['p', 'm', 'stock']) {
        expect((await row(id)).state, 'discarded', reason: id);
      }
      expect((await row('u')).state, 'queued');
      expect((await db.profilesDao.getById('prof'))!.isDeleted, isTrue);
      expect((await db.pillsDao.getById('pil'))!.isDeleted, isTrue);
      expect((await db.schedulesDao.getById('sch'))!.isDeleted, isTrue);
      expect((await db.profilesDao.getById('unrelated'))!.isDeleted, isFalse);
    });

    test('refuses while a change of the item is being sent', () async {
      await profile('prof', 'Ana', status: 'pending');
      await op('s', 'sending', local: 'prof');
      await op('b', 'blocked', local: 'prof');
      final key = (await service.diagnose(_userId)).items.single.key;
      expect(
        (await service.useServerVersion(_userId, key)).refusal,
        RecoveryRefusal.sending,
      );
      expect((await row('b')).state, 'blocked');
    });
  });

  group('useServerVersion needs the server copy', () {
    SyncRecoveryService build({
      Future<bool> Function()? online,
      Future<bool> Function(String)? pull,
      Future<bool> Function()? idle,
    }) => SyncRecoveryService(
      db: db,
      flush: (_) async => calls.add('flush'),
      pull:
          pull ??
          (_) async {
            calls.add('pull');
            return true;
          },
      write: <T>(_, action) => db.transaction(action),
      isOnline: online,
      waitForIdle: idle,
      now: () => _now,
    );

    Future<void> seed() async {
      await profile('prof', 'Local edit', status: 'pending');
      await op('edit', 'conflict', local: 'prof');
      await db.syncStateDao.saveState(
        SyncComponentStatesCompanion.insert(
          userId: _userId,
          component: 'stable',
          contractVersion: 2,
          lastCompletedCursor: const Value('42'),
          lastFullSuccessAt: Value(_now),
        ),
      );
    }

    test(
      'offline: nothing is dropped and the row is not marked synced',
      () async {
        await seed();
        final offline = build(online: () async => false);
        final key = (await offline.diagnose(_userId)).items.single.key;

        final outcome = await offline.useServerVersion(_userId, key);

        expect(outcome.refusal, RecoveryRefusal.offline);
        expect((await row('edit')).state, 'conflict');
        expect((await db.profilesDao.getById('prof'))!.syncStatus, 'pending');
        expect(calls, isEmpty);
      },
    );

    test('a failing pull still leaves the row to be replaced by the next '
        'pull and says the server copy is pending', () async {
      await seed();
      final failing = build(
        pull: (_) async {
          calls.add('pull');
          return false;
        },
      );
      final key = (await failing.diagnose(_userId)).items.single.key;

      final outcome = await failing.useServerVersion(_userId, key);

      expect(outcome.serverCopyPending, isTrue);
      expect(outcome.pulled, isFalse);
      expect((await row('edit')).state, 'discarded');
      // Marked as the server's copy, and the checkpoints replay everything,
      // so the next pull overwrites the stale local values.
      expect((await db.profilesDao.getById('prof'))!.syncStatus, 'synced');
      final state = (await db.syncStateDao.getState(_userId, 'stable'))!;
      expect(state.lastCompletedCursor, isNull);
    });

    test('a run starting right after the drop leaves the replay recorded, '
        'and no pull of ours', () async {
      await seed();
      var checks = 0;
      final racing = build(idle: () async => ++checks == 1);
      final key = (await racing.diagnose(_userId)).items.single.key;

      final outcome = await racing.useServerVersion(_userId, key);

      expect(outcome.serverCopyPending, isTrue);
      expect(calls, isNot(contains('pull')));
      final state = (await db.syncStateDao.getState(_userId, 'stable'))!;
      expect(state.lastCompletedCursor, isNull);
    });
  });

  group('keepMyChange', () {
    test('re-records the edit on the latest revision under a new mutation id, '
        'dropping the frozen body', () async {
      await profile('prof', 'Server name', revision: 4);
      await op(
        'c',
        'conflict',
        local: 'prof',
        attempts: 1,
        data: {'name': 'My name'},
        extra: {
          'frozenRequest': {
            'path': '/x',
            'body': {'baseRevision': '2'},
          },
        },
      );
      await issue('i', 'stable_revision_conflict_server_wins', 'prof', 'c');
      final key = (await service.diagnose(_userId)).items.single.key;

      final outcome = await service.keepMyChange(_userId, key);

      expect(outcome.ok, isTrue);
      final updated = await row('c');
      expect(updated.state, 'queued');
      expect(updated.mutationId, isNot('m-c'));
      expect(updated.attemptCount, 0);
      expect(jsonDecode(updated.payloadJson), isNot(contains('frozenRequest')));
      final local = (await db.profilesDao.getById('prof'))!;
      expect(local.name, 'My name');
      expect(local.revision, 9, reason: 'the revision the server reported');
      expect(local.syncStatus, 'pending');
      expect(await db.migrationIssuesDao.getUnresolved(_userId), isEmpty);
      expect(calls, ['flush', 'pull']);
    });
  });

  group('an item the server deleted', () {
    Future<String> seedDeleted() async {
      // What the adapter leaves after a 404 that carries a tombstone.
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'prof',
          userId: _userId,
          name: 'Ana',
          createdAt: _now,
          updatedAt: _now,
          serverId: const Value('prof'),
          revision: const Value(3),
          syncStatus: const Value('synced'),
          isDeleted: const Value(true),
        ),
      );
      await op('c', 'conflict', local: 'prof', data: {'name': 'My name'});
      await issue(
        'i',
        'stable_revision_conflict_server_wins',
        'prof',
        'c',
        deletedAt: '2026-10-01T00:00:00Z',
      );
      return (await service.diagnose(_userId)).items.single.key;
    }

    test('offers only Use server version, with a plain reason', () async {
      await seedDeleted();
      final item = (await service.diagnose(_userId)).items.single;

      expect(item.serverDeleted, isTrue);
      expect(item.canKeepMine, isFalse);
      expect(item.canDismiss, isFalse);
      expect(item.canUseServerVersion, isTrue);
    });

    test(
      'an ordinary settled conflict still offers Keep and Dismiss',
      () async {
        await profile('prof', 'Ana');
        await op('c', 'conflict', local: 'prof');
        await issue('i', 'stable_revision_conflict_server_wins', 'prof', 'c');
        final item = (await service.diagnose(_userId)).items.single;
        expect(item.serverDeleted, isFalse);
        expect(item.canKeepMine, isTrue);
        expect(item.canDismiss, isTrue);
      },
    );

    test('Keep my change is refused instead of looping back', () async {
      final key = await seedDeleted();

      final outcome = await service.keepMyChange(_userId, key);

      expect(outcome.refusal, RecoveryRefusal.serverDeleted);
      expect((await row('c')).state, 'conflict');
      expect(calls, isEmpty);
    });

    test('Use server version accepts the delete, offline too, and the row '
        'stays deleted', () async {
      final key = await seedDeleted();
      final offline = SyncRecoveryService(
        db: db,
        flush: (_) async => calls.add('flush'),
        pull: (_) async {
          calls.add('pull');
          return false;
        },
        write: <T>(_, action) => db.transaction(action),
        isOnline: () async => false,
        now: () => _now,
      );

      final outcome = await offline.useServerVersion(_userId, key);

      expect(outcome.refusal, isNull);
      expect(outcome.serverCopyPending, isFalse);
      expect((await row('c')).state, 'discarded');
      final local = (await db.profilesDao.getById('prof'))!;
      expect(local.isDeleted, isTrue);
      expect(local.syncStatus, 'synced');
      expect(await db.migrationIssuesDao.getUnresolved(_userId), isEmpty);
    });
  });

  group('dismiss', () {
    test('closes only conflicts already settled for the server', () async {
      await profile('prof', 'Ana');
      await profile('held', 'Bea', status: 'pending');
      await op('settled', 'conflict', local: 'prof');
      await issue(
        'i',
        'stable_revision_conflict_server_wins',
        'prof',
        'settled',
      );
      await op('open', 'conflict', local: 'held');
      await issue('j', 'stable_revision_conflict_server_wins', 'held', 'open');

      final report = await service.diagnose(_userId);
      final settledKey = report.items.firstWhere((i) => i.name == 'Ana').key;
      final openKey = report.items.firstWhere((i) => i.name == 'Bea').key;

      expect((await service.dismiss(_userId, settledKey)).ok, isTrue);
      expect(
        (await service.dismiss(_userId, openKey)).refusal,
        RecoveryRefusal.nothingToDo,
      );
      expect((await row('settled')).state, 'discarded');
      expect((await row('open')).state, 'conflict');
      expect(
        (await db.migrationIssuesDao.getUnresolved(_userId)).map((i) => i.id),
        ['j'],
      );
    });
  });

  group('redownload', () {
    test(
      'flushes first, resets only the pull checkpoints, then pulls',
      () async {
        await op('keep', 'blocked', code: 'X');
        await profile('prof', 'Ana', status: 'pending');
        await db.syncStateDao.saveState(
          SyncComponentStatesCompanion.insert(
            userId: _userId,
            component: 'medication',
            contractVersion: 2,
            lastCompletedCursor: const Value('7'),
            lastFullSuccessAt: Value(_now),
          ),
        );

        final outcome = await service.redownload(_userId);

        expect(outcome.pulled, isTrue);
        expect(calls, ['flush', 'pull']);
        final state = (await db.syncStateDao.getState(_userId, 'medication'))!;
        expect(state.lastCompletedCursor, isNull);
        expect((await row('keep')).state, 'blocked');
        expect((await db.profilesDao.getById('prof'))!.syncStatus, 'pending');
      },
    );
  });

  group('while an automatic sync is running', () {
    SyncRecoveryService withIdle(Future<bool> Function() idle) =>
        SyncRecoveryService(
          db: db,
          flush: (_) async => calls.add('flush'),
          pull: (_) async {
            calls.add('pull');
            return true;
          },
          write: <T>(_, action) => db.transaction(action),
          waitForIdle: idle,
          now: () => _now,
        );

    Future<void> seedCheckpoint() => db.syncStateDao.saveState(
      SyncComponentStatesCompanion.insert(
        userId: _userId,
        component: 'stable',
        contractVersion: 2,
        lastCompletedCursor: const Value('42'),
        lastFullSuccessAt: Value(_now),
      ),
    );

    test('re-download reports busy and leaves checkpoints alone', () async {
      await seedCheckpoint();
      final busy = withIdle(() async => false);

      final outcome = await busy.redownload(_userId);

      expect(outcome.busy, isTrue);
      expect(outcome.pulled, isFalse);
      expect(calls, isEmpty);
      final state = (await db.syncStateDao.getState(_userId, 'stable'))!;
      expect(state.lastCompletedCursor, '42');
    });

    test('a run that starts during the flush stops the checkpoint reset, '
        'and nothing is pulled', () async {
      await seedCheckpoint();
      var checks = 0;
      final busy = withIdle(() async => ++checks == 1);

      final outcome = await busy.redownload(_userId);

      expect(outcome.busy, isTrue);
      expect(outcome.flushed, isTrue);
      expect(calls, ['flush']);
      final state = (await db.syncStateDao.getState(_userId, 'stable'))!;
      expect(state.lastCompletedCursor, '42');
    });

    test('Use server version drops nothing while a run is in flight', () async {
      await profile('prof', 'Local edit', status: 'pending');
      await op('edit', 'conflict', local: 'prof');
      await seedCheckpoint();
      final key = (await service.diagnose(_userId)).items.single.key;
      final busy = withIdle(() async => false);

      final outcome = await busy.useServerVersion(_userId, key);

      expect(outcome.busy, isTrue);
      expect(calls, isEmpty);
      expect((await row('edit')).state, 'conflict');
      expect((await db.profilesDao.getById('prof'))!.syncStatus, 'pending');
      final state = (await db.syncStateDao.getState(_userId, 'stable'))!;
      expect(state.lastCompletedCursor, '42');
    });

    test('Keep my change sends nothing and pulls nothing while busy', () async {
      await profile('prof', 'Server name');
      await op('c', 'conflict', local: 'prof');
      await issue('i', 'stable_revision_conflict_server_wins', 'prof', 'c');
      final key = (await service.diagnose(_userId)).items.single.key;
      final busy = withIdle(() async => false);

      final outcome = await busy.keepMyChange(_userId, key);

      expect(outcome.busy, isTrue);
      expect(outcome.pulled, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('buildDiagnostics', () {
    test('lists counts and codes but no names, notes, e-mail or ids', () async {
      await profile('prof-secret-id', 'Ana Popescu', status: 'pending');
      await pill('pil-secret-id', 'prof-secret-id', 'Warfarin 5mg');
      await op(
        'op-secret-id',
        'blocked',
        local: 'prof-secret-id',
        code: 'STABLE_REQUEST_BODY_CHANGED',
        data: {'name': 'Ana Popescu', 'notes': 'takes with grandma\'s tea'},
      );
      await op('op2', 'failedRetryable', code: 'SYNC_OFFLINE', attempts: 2);
      await issue('i', 'stable_revision_conflict_server_wins', 'x', 'y');

      final text = await service.buildDiagnostics(
        _userId,
        capabilities: const ServerCapabilities(
          medicationLedgerActive: true,
          minimumClientBuild: 1,
          serverRelease: '1.2.3',
          bridgeUndo: true,
        ),
      );

      expect(text, contains('blocked=1'));
      expect(text, contains('retrying=1'));
      expect(text, contains('STABLE_REQUEST_BODY_CHANGED'));
      expect(text, contains('bridge undo yes'));
      expect(text, contains('release 1.2.3'));
      for (final secret in [
        'Ana',
        'Popescu',
        'Warfarin',
        'grandma',
        'secret',
        'example.invalid',
        'op-secret-id',
        'prof-secret-id',
        'Bearer',
        'http',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
    });
  });

  group('recovery actions for every item', () {
    Future<void> dose(
      String id,
      String state, {
      String? dependsOn,
      String? code,
      String component = 'medication',
      Map<String, Object?> extra = const {},
    }) => op(
      id,
      state,
      entity: 'occurrence',
      local: 'occ',
      type: 'medication.command',
      component: component,
      dependsOn: dependsOn,
      code: code,
      extra: extra,
    );

    Future<void> inventory(String id, String state, String pillId) => op(
      id,
      state,
      entity: 'pill',
      local: pillId,
      type: 'inventory.correct',
      component: 'medication',
    );

    test('Try again on a blocked dose requeues it, then flushes before '
        'pulling', () async {
      await dose('d', 'blocked', code: 'MEDICATION_RECONCILIATION_REQUIRED');
      await issue('i', 'bridge_command_unsendable', 'd', 'd');
      final item = (await service.diagnose(_userId)).items.single;
      expect(item.canTryAgain, isTrue);

      final outcome = await service.tryAgain(_userId, item.key);

      expect(outcome.ok, isTrue);
      final after = await row('d');
      expect(after.state, 'queued');
      expect(after.safeErrorCode, isNull);
      expect(calls, ['flush', 'pull']);
      expect(await db.migrationIssuesDao.getUnresolved(_userId), isEmpty);
    });

    test('Discard on a blocked dose drops it with the changes chained to it, '
        'frees unrelated ones and flushes before pulling', () async {
      await dose('d', 'blocked', code: 'SOME_CODE');
      await dose('undo', 'queued', dependsOn: 'd');
      await dose('undo2', 'queued', dependsOn: 'undo');
      await dose('free', 'queued');
      await issue('i', 'bridge_command_unsendable', 'd', 'd');
      final item = (await service.diagnose(_userId)).items.single;
      expect(item.canDiscard, isTrue);
      expect(item.discardCount, 3);

      final outcome = await service.discardItem(_userId, item.key);

      expect(outcome.ok, isTrue);
      expect((await row('d')).state, 'discarded');
      expect((await row('undo')).state, 'discarded');
      expect((await row('undo2')).state, 'discarded');
      expect((await row('free')).state, 'queued');
      expect((await row('free')).dependsOnOperationId, isNull);
      expect(
        (await db.pendingOperationsDao.getReady(_userId)).map((o) => o.id),
        ['free'],
      );
      expect(calls, ['flush', 'pull'], reason: 'flush happens before pull');
      expect(await db.migrationIssuesDao.getUnresolved(_userId), isEmpty);
    });

    group('Discard repairs the occurrence projection', () {
      Future<void> occurrence({required String state, required int version}) =>
          db
              .into(db.medicationOccurrences)
              .insert(
                MedicationOccurrencesCompanion.insert(
                  id: 'occ',
                  userId: _userId,
                  occurrenceKey: 'k',
                  source: 'scheduled',
                  plannedLocalDate: '2026-10-14',
                  timeZone: 'UTC',
                  scheduleSnapshotJson: '{}',
                  provenance: 'exact',
                  state: Value(state),
                  stateVersion: Value(version),
                  createdAt: _now,
                  updatedAt: _now,
                ),
              );

      Future<void> event(
        String id,
        String commandId,
        String from,
        String to,
        int base, {
        String? serverId,
      }) => db
          .into(db.occurrenceEvents)
          .insert(
            OccurrenceEventsCompanion.insert(
              id: id,
              serverId: Value(serverId),
              userId: _userId,
              occurrenceId: 'occ',
              commandId: commandId,
              action: to == 'taken' ? 'take' : 'undo',
              fromState: from,
              toState: to,
              origin: 'native',
              baseVersion: base,
              resultVersion: base + 1,
              recordedAt: _now,
            ),
          );

      Future<MedicationOccurrence> occ() => (db.select(
        db.medicationOccurrences,
      )..where((o) => o.id.equals('occ'))).getSingle();

      test('a discarded first take returns to pending, version 0', () async {
        await occurrence(state: 'taken', version: 1);
        await event('ev', 'm-d', 'pending', 'taken', 0);
        await dose('d', 'blocked', code: 'SOME_CODE');

        await service.discardItem(_userId, 'dose:occ');

        final row = await occ();
        expect(row.state, 'pending');
        expect(row.stateVersion, 0);
        expect(
          await db.medicationLedgerDao.getEventsForOccurrence('occ'),
          hasLength(1),
          reason: 'the event stays: history is append-only',
        );
      });

      test('it returns to the latest server-mapped event', () async {
        await occurrence(state: 'taken', version: 3);
        await event('e1', 'm-old', 'pending', 'taken', 0, serverId: 's1');
        await event('e2', 'm-old2', 'taken', 'pending', 1, serverId: 's2');
        await event('e3', 'm-d', 'pending', 'taken', 2);
        await dose('d', 'blocked', code: 'SOME_CODE');

        await service.discardItem(_userId, 'dose:occ');

        final row = await occ();
        expect(row.state, 'pending');
        expect(row.stateVersion, 2);
      });

      test('a take whose change was discarded by an older build is put back '
          'when the list is built', () async {
        await occurrence(state: 'taken', version: 1);
        await event('ev', 'm-d', 'pending', 'taken', 0);
        await dose('d', 'discarded');

        await service.diagnose(_userId);

        final row = await occ();
        expect(row.state, 'pending');
        expect(row.stateVersion, 0);
        expect(
          await db.medicationLedgerDao.getEventsForOccurrence('occ'),
          hasLength(1),
        );
        // Settled: a second look changes nothing.
        await service.diagnose(_userId);
        expect((await occ()).stateVersion, 0);
      });

      test(
        'a discarded change is reconciled once and not scanned again',
        () async {
          await occurrence(state: 'taken', version: 1);
          await event('ev', 'm-d', 'pending', 'taken', 0);
          await dose('d', 'discarded');

          await service.diagnose(_userId);
          expect((await occ()).stateVersion, 0);
          expect((await row('d')).safeErrorCode, 'DISCARD_RECONCILED');

          // The bounded pass leaves a settled discard alone: put the occurrence
          // back to the wrong state and a second diagnose must not look again.
          await (db.update(
            db.medicationOccurrences,
          )..where((o) => o.id.equals('occ'))).write(
            const MedicationOccurrencesCompanion(
              state: Value('taken'),
              stateVersion: Value(1),
            ),
          );
          await service.diagnose(_userId);
          expect((await occ()).stateVersion, 1);
        },
      );

      test(
        'the reconcile marker keeps the code that explained the discard',
        () async {
          await occurrence(state: 'taken', version: 1);
          await event('ev', 'm-d', 'pending', 'taken', 0);
          await dose(
            'd',
            'discarded',
            code: 'MEDICATION_COMMAND_RESULT_UNCERTAIN',
          );
          await service.diagnose(_userId);

          expect(
            (await row('d')).safeErrorCode,
            'MEDICATION_COMMAND_RESULT_UNCERTAIN__DISCARD_RECONCILED',
          );
          // Marked once: a second pass does not append again.
          await service.diagnose(_userId);
          expect(
            (await row('d')).safeErrorCode,
            'MEDICATION_COMMAND_RESULT_UNCERTAIN__DISCARD_RECONCILED',
          );
        },
      );

      test('a discard held back by another change is looked at again after it '
          'settles', () async {
        await occurrence(state: 'taken', version: 1);
        await event('ev', 'm-d', 'pending', 'taken', 0);
        await dose('d', 'discarded');
        await op(
          'other',
          'queued',
          entity: 'occurrence',
          local: 'occ',
          type: 'medication.command',
          component: 'medication',
          dependsOn: null,
        );

        await service.diagnose(_userId);
        expect((await occ()).stateVersion, 1);
        expect((await row('d')).safeErrorCode, isNot('DISCARD_RECONCILED'));

        await (db.update(db.pendingOperations)
              ..where((o) => o.id.equals('other')))
            .write(const PendingOperationsCompanion(state: Value('committed')));
        await service.diagnose(_userId);
        expect((await occ()).stateVersion, 0);
        expect((await row('d')).safeErrorCode, 'DISCARD_RECONCILED');
      });

      test('a take with a live change behind it is left alone', () async {
        await occurrence(state: 'taken', version: 1);
        await event('ev', 'm-d', 'pending', 'taken', 0);
        await dose('d', 'queued');

        await service.diagnose(_userId);

        expect((await occ()).state, 'taken');
      });

      test('another unsent change on the occurrence leaves it alone', () async {
        await occurrence(state: 'taken', version: 1);
        await event('ev', 'm-d', 'pending', 'taken', 0);
        await dose('d', 'blocked', code: 'SOME_CODE');
        // An unrelated queued change on the same occurrence is released, not
        // dropped, so the occurrence still has unsent work.
        await op(
          'other',
          'queued',
          entity: 'occurrence',
          local: 'occ',
          type: 'medication.command',
          component: 'medication',
          dependsOn: null,
        );

        await service.discardItem(_userId, 'dose:occ');

        expect((await row('other')).state, 'queued');
        final r = await occ();
        expect(r.state, 'taken', reason: 'an unsent change still names it');
        expect(r.stateVersion, 1);
      });
    });

    test('Discard keeps dose history: no event is removed or rewritten, '
        'and the pull is told to replay', () async {
      await dose('d', 'blocked', code: 'SOME_CODE');
      await db
          .into(db.medicationOccurrences)
          .insert(
            MedicationOccurrencesCompanion.insert(
              id: 'occ',
              userId: _userId,
              occurrenceKey: 'k',
              source: 'scheduled',
              plannedLocalDate: '2026-10-14',
              timeZone: 'UTC',
              scheduleSnapshotJson: '{}',
              provenance: 'exact',
              createdAt: _now,
              updatedAt: _now,
            ),
          );
      await db
          .into(db.occurrenceEvents)
          .insert(
            OccurrenceEventsCompanion.insert(
              id: 'ev',
              userId: _userId,
              occurrenceId: 'occ',
              commandId: 'm-d',
              action: 'take',
              fromState: 'pending',
              toState: 'taken',
              origin: 'native',
              baseVersion: 0,
              resultVersion: 1,
              recordedAt: _now,
            ),
          );

      await service.discardItem(_userId, 'dose:occ');

      expect(
        await db.medicationLedgerDao.getEventsForOccurrence('occ'),
        hasLength(1),
        reason: 'recorded history is never rewritten',
      );
      expect((await row('d')).state, 'discarded');
    });

    test(
      'Discard hands the guarded stock row back to the server copy',
      () async {
        await profile('prof', 'Ana');
        await pill('pil', 'prof', 'Aspirin', status: 'pending');
        await inventory('inv', 'blocked', 'pil');

        await service.discardItem(_userId, 'medication:pil');

        expect((await db.pillsDao.getById('pil'))!.syncStatus, 'synced');
        expect((await row('inv')).state, 'discarded');
      },
    );

    test(
      'a stock row another unsent change still names stays guarded',
      () async {
        await profile('prof', 'Ana');
        await pill('pil', 'prof', 'Aspirin', status: 'pending');
        await inventory('inv', 'blocked', 'pil');
        await op(
          'edit',
          'queued',
          entity: 'pill',
          local: 'pil',
          type: 'pill.update',
        );

        await service.discardItem(_userId, 'medication:pil');

        expect((await db.pillsDao.getById('pil'))!.syncStatus, 'pending');
        expect((await row('edit')).state, 'queued');
      },
    );

    test('Discard is refused while the change is being sent', () async {
      await dose('d', 'sending');
      final outcome = await service.discardItem(_userId, 'dose:occ');
      expect(outcome.refusal, RecoveryRefusal.sending);
      expect((await row('d')).state, 'sending');
    });

    test('a ledger conflict: Use server version drops it, frees the queue '
        'and pulls after flushing', () async {
      await dose('c', 'conflict');
      await dose('after', 'queued', dependsOn: 'c');
      final item = (await service.diagnose(_userId)).items.single;
      expect(item.canUseServerVersion, isTrue);
      expect(item.canTryAgain, isTrue);
      expect(item.canDiscard, isTrue);

      final outcome = await service.useServerVersion(_userId, item.key);

      expect(outcome.ok, isTrue);
      expect(outcome.pulled, isTrue);
      expect((await row('c')).state, 'discarded');
      expect((await row('after')).dependsOnOperationId, isNull);
      expect(calls, ['flush', 'pull']);
    });

    test('Use server version on a medication also drops its unsent stock '
        'command, so the item does not come back', () async {
      await profile('prof', 'Ana');
      await pill('pil', 'prof', 'Local name', status: 'pending');
      await inventory('inv', 'conflict', 'pil');
      await op(
        'rename',
        'queued',
        entity: 'pill',
        local: 'pil',
        type: 'pill.update',
        dependsOn: 'inv',
      );

      final outcome = await service.useServerVersion(_userId, 'medication:pil');

      expect(outcome.ok, isTrue);
      expect((await row('rename')).state, 'discarded');
      expect((await row('inv')).state, 'discarded');
      expect((await db.pillsDao.getById('pil'))!.syncStatus, 'synced');
      expect(calls, ['flush', 'pull']);
      final after = await service.diagnose(_userId);
      expect(after.items, isEmpty);
    });

    test('offline, a server-deleted medication with a stock command is '
        'refused before anything is discarded', () async {
      final offline = SyncRecoveryService(
        db: db,
        flush: (_) async => calls.add('flush'),
        pull: (_) async => true,
        write: <T>(_, action) => db.transaction(action),
        isOnline: () async => false,
        now: () => _now,
      );
      await profile('prof', 'Ana');
      await pill('pil', 'prof', 'Local name', status: 'pending');
      await inventory('inv', 'conflict', 'pil');
      await op(
        'rename',
        'conflict',
        entity: 'pill',
        local: 'pil',
        type: 'pill.update',
      );
      await issue(
        'i',
        'stable_revision_conflict_server_wins',
        'pil',
        'rename',
        deletedAt: '2026-10-01T00:00:00Z',
      );

      final outcome = await offline.useServerVersion(_userId, 'medication:pil');

      expect(outcome.refusal, RecoveryRefusal.offline);
      expect((await row('rename')).state, 'conflict');
      expect((await row('inv')).state, 'conflict');
      expect((await db.pillsDao.getById('pil'))!.isDeleted, isFalse);
    });

    test('a ledger conflict: Use server version waits when offline', () async {
      final offline = SyncRecoveryService(
        db: db,
        flush: (_) async => calls.add('flush'),
        pull: (_) async => true,
        write: <T>(_, action) => db.transaction(action),
        isOnline: () async => false,
        now: () => _now,
      );
      await dose('c', 'conflict');
      final outcome = await offline.useServerVersion(_userId, 'dose:occ');
      expect(outcome.refusal, RecoveryRefusal.offline);
      expect((await row('c')).state, 'conflict');
      expect(calls, isEmpty);
    });

    test('a ledger conflict: Try again requeues it', () async {
      await dose('c', 'conflict');
      final outcome = await service.tryAgain(_userId, 'dose:occ');
      expect(outcome.ok, isTrue);
      expect((await row('c')).state, 'queued');
      expect(calls, ['flush', 'pull']);
    });

    test('a ledger conflict: Discard drops it and works offline', () async {
      var pulls = 0;
      final offline = SyncRecoveryService(
        db: db,
        flush: (_) async {},
        pull: (_) async {
          pulls++;
          return false;
        },
        write: <T>(_, action) => db.transaction(action),
        isOnline: () async => false,
        now: () => _now,
      );
      await dose('c', 'conflict');
      final outcome = await offline.discardItem(_userId, 'dose:occ');
      expect(outcome.ok, isTrue);
      expect(outcome.serverCopyPending, isTrue);
      expect(pulls, 1);
      expect((await row('c')).state, 'discarded');
    });

    test('queued changes left behind an already discarded change are '
        'released when the list is built', () async {
      await dose('gone', 'discarded');
      await dose('stuck', 'queued', dependsOn: 'gone');
      expect(
        (await db.pendingOperationsDao.getReady(_userId)).map((o) => o.id),
        isEmpty,
      );

      final report = await service.diagnose(_userId);

      expect((await row('stuck')).dependsOnOperationId, isNull);
      expect(report.items.single.canDiscard, isTrue);
      expect(
        (await db.pendingOperationsDao.getReady(_userId)).map((o) => o.id),
        ['stuck'],
      );
    });

    test('a create with dose history still has Try again', () async {
      await profile('prof', 'Ana');
      await pill('pil', 'prof', 'Aspirin', status: 'pending');
      await schedule('sch', 'pil', status: 'pending');
      await db
          .into(db.doseLogs)
          .insert(
            DoseLogsCompanion.insert(
              id: 'dose',
              scheduleId: 'sch',
              scheduledAt: _now,
              status: 'taken',
              createdAt: _now,
              updatedAt: _now,
            ),
          );
      await op(
        'create',
        'conflict',
        entity: 'pill',
        local: 'pil',
        type: 'pill.create',
      );
      final item = (await service.diagnose(_userId)).items.single;
      expect(item.discardBlockedByHistory, isTrue);
      expect(item.canTryAgain, isTrue);
      expect(item.hasAction, isTrue);
      expect(
        (await service.discardItem(_userId, item.key)).refusal,
        RecoveryRefusal.notDiscardable,
      );
    });

    test('no item the service can emit is left without an action', () async {
      await profile('prof', 'Ana');
      await pill('pil', 'prof', 'Aspirin');
      await schedule('sch', 'pil');
      const states = ['queued', 'failedRetryable', 'blocked', 'conflict'];
      const codes = <String?>[
        null,
        'SOME_CODE',
        'MEDICATION_BRIDGE_RESULT_UNCERTAIN',
        'MEDICATION_RECONCILIATION_REQUIRED',
        'SPLIT_EFFECT_REQUIRES_RECONCILIATION',
        'SPLIT_REVIEW_REQUIRED',
        'SPLIT_RECONCILIATION_RECEIPT_MISMATCH',
        'MEDICATION_BRIDGE_REQUEST_IDENTITY_MISMATCH',
        'BRIDGE_CANNOT_REPRESENT_PENDING_STATE',
        'BRIDGE_UNDO_UNSUPPORTED',
        'STABLE_REQUEST_BODY_CHANGED',
        'SYNC_RETRY_EXHAUSTED',
      ];
      // component, type, entity, local id
      const shapes = <(String, String, String, String)>[
        ('stable', 'profile.create', 'profile', 'prof'),
        ('stable', 'profile.update', 'profile', 'prof'),
        ('stable', 'profile.delete', 'profile', 'prof'),
        ('stable', 'pill.create', 'pill', 'pil'),
        ('stable', 'pill.update', 'pill', 'pil'),
        ('stable', 'pill.delete', 'pill', 'pil'),
        ('stable', 'schedule.create', 'schedule', 'sch'),
        ('stable', 'schedule.update', 'schedule', 'sch'),
        ('stable', 'schedule.repair', 'schedule', 'sch'),
        ('stable', 'thing.update', 'thing', 'x'),
        ('stable', 'thing.create', 'thing', 'x'),
        ('account', 'account.settings', 'settings', 's'),
        ('medication', 'medication.command', 'occurrence', 'occ'),
        ('medication', 'inventory.correct', 'pill', 'pil'),
        ('medication', 'legacy_dose_write', 'dose_log', 'dl'),
        ('medication', 'legacy_stock_write', 'pill', 'pil'),
        ('medicationBridge', 'medication.command', 'occurrence', 'occ'),
      ];
      var checked = 0;
      for (final (component, type, entity, local) in shapes) {
        for (final state in states) {
          for (final code in codes) {
            await db.delete(db.pendingOperations).go();
            await op(
              'x',
              state,
              type: type,
              entity: entity,
              local: local,
              component: component,
              code: code,
            );
            final report = await service.diagnose(_userId);
            for (final item in report.items) {
              checked++;
              expect(
                item.hasAction,
                isTrue,
                reason: '$component $type $state $code',
              );
            }
          }
        }
      }
      expect(checked, greaterThan(500));
    });

    test('countNotes matches the report and repairs nothing', () async {
      await db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: 'note',
          userId: _userId,
          entityType: 'dose_log',
          entityId: 'gone-op',
          issueCode: 'legacy_effect_delivery_uncertain',
          snapshotJson: jsonEncode({'operationId': 'gone-op'}),
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      expect(await service.countNotes(_userId), 1);
      expect(
        await service.countNotes(_userId),
        (await service.diagnose(_userId)).notes.length,
      );
    });

    test('a kept note nothing waits behind can be dismissed', () async {
      await db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: 'note',
          userId: _userId,
          entityType: 'dose_log',
          entityId: 'gone-op',
          issueCode: 'legacy_effect_delivery_uncertain',
          snapshotJson: jsonEncode({'operationId': 'gone-op'}),
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      var report = await service.diagnose(_userId);
      expect(report.items, isEmpty);
      expect(report.notes.single.issueId, 'note');
      expect(report.isEmpty, isFalse);

      expect((await service.dismissNote(_userId, 'note')).ok, isTrue);

      report = await service.diagnose(_userId);
      expect(report.isEmpty, isTrue);
      expect(
        (await service.dismissNote(_userId, 'note')).refusal,
        RecoveryRefusal.nothingToDo,
      );
    });

    test('a kept note tied to stock held for the ledger is a dismissable '
        'note, so the Sync page and this screen agree', () async {
      SharedPreferences.setMockInitialValues({LedgerModeHint.key: false});
      await op(
        'held',
        'queued',
        entity: 'pill',
        local: 'pil',
        type: 'inventory.correct',
        component: 'medication',
        extra: const {
          'inventoryCommand': {'commandId': 'c', 'pillId': 'pil'},
        },
      );
      await issue('i', 'CONFLICT_REVISION', 'held', 'held');
      final report = await service.diagnose(_userId);
      expect(report.items, isEmpty);
      expect(report.notes.map((n) => n.issueId), ['i']);
      expect((await service.dismissNote(_userId, 'i')).ok, isTrue);
      expect((await service.diagnose(_userId)).isEmpty, isTrue);
    });

    test('a local review note about a schedule is a note here too', () async {
      await db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: 'sched-note',
          userId: _userId,
          entityType: 'schedule',
          entityId: 'sched-1',
          issueCode: 'CONFLICT_REVISION',
          snapshotJson: '{}',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
      final report = await service.diagnose(_userId);
      expect(report.notes.map((n) => n.issueId), ['sched-note']);
    });

    test(
      'a review issue still tied to a waiting change is not a note',
      () async {
        await dose('d', 'blocked', code: 'SOME_CODE');
        await issue('i', 'bridge_command_unsendable', 'd', 'd');
        final report = await service.diagnose(_userId);
        expect(report.notes, isEmpty);
      },
    );
  });

  test('discarded operations are not pending anywhere', () async {
    await op('q', 'queued');
    await op('d', 'discarded');
    final unsettled = await db.pendingOperationsDao.getUnsettledForUser(
      _userId,
    );
    expect(unsettled.map((o) => o.id), ['q']);
  });
}
