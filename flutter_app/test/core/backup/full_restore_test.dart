import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/db/daos/import_dao.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import '../../helpers/protected_restore_fixture.dart';
import 'package:drift/drift.dart' show Value;
import 'package:sqlite3/sqlite3.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_inventory.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/storage/recovery_copy_service.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/care_recording_fixture.dart';

Future<CheckedBackup> fullSource(ProtectedWorkspaceFixture source) async =>
    CheckedBackup(
      (await BackupService(
        database: source.db,
        access: source.access,
        preferences: source.preferences,
        files: const AndroidBackupFileAccess(),
      ).captureFull()).document,
      const BackupFileLocation('fictional', 'Care.simpbak'),
      DateTime.utc(2026, 10, 1),
      passwordProtected: true,
    );

void main() {
  setUp(tz.initializeTimeZones);
  test(
    'unattributed archived dose survives full restore only as exact evidence',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final source = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      final now = DateTime.utc(2026, 10, 1);
      await source.db
          .into(source.db.doseLogs)
          .insert(
            DoseLogsCompanion.insert(
              id: 'unattributed-original',
              scheduleId: 'deleted-schedule',
              scheduledAt: now,
              status: 'taken',
              note: const Value('Fictional original'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      final input = await fullSource(source);
      final service = fixture.service();
      final plan = await service.preview(input, const ImportSelection.full());
      expect(plan.retainedWork, greaterThanOrEqualTo(1));
      await service.apply(plan);
      final target = fixture.workspace;
      expect(await target.db.select(target.db.doseLogs).get(), isEmpty);
      expect(
        await target.db.select(target.db.pendingOperations).get(),
        isEmpty,
      );
      final dao = ImportDao(target.db);
      final receipt = (await dao.receipts(target.context.workspaceId)).single;
      final original = await dao.originalRow(
        receiptId: receipt.id,
        table: 'dose_logs',
        key: '["unattributed-original"]',
      );
      expect(original['schedule_id'], 'deleted-schedule');
      expect(original['note'], 'Fictional original');
      // Re-export retains the evidence after restoration; no live dose is added.
      final recaptured = await fullSource(target);
      expect(recaptured.document.tables['import_evidence'], isNotEmpty);
    },
  );
  test(
    'full review identifies target-only drafts and uncertain work without people',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final target = fixture.workspace;
      await target.db.customStatement(
        'UPDATE setup_drafts SET profile_id=NULL',
      );
      await target.db.customStatement(
        'UPDATE care_workspaces SET selected_profile_id=NULL',
      );
      await target.db.delete(target.db.profiles).go();
      await target.db
          .into(target.db.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              id: 'fictional-target-operation',
              userId: target.context.ownerUserId,
              mutationId: 'fictional-target-mutation',
              component: 'medication',
              operationType: 'take',
              contractVersion: 2,
              payloadJson: '{}',
              state: const Value('sending'),
              createdAt: DateTime.utc(2026, 10, 1),
            ),
          );
      await target.db
          .into(target.db.pendingOperationEffects)
          .insert(
            PendingOperationEffectsCompanion.insert(
              id: 'fictional-target-effect',
              operationId: 'fictional-target-operation',
              ordinal: 0,
              kind: 'dose',
              requestFingerprint: 'fictional',
              state: const Value('sending'),
              attemptedAt: Value(DateTime.utc(2026, 10, 1)),
            ),
          );
      final source = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      final marker = await fixture.files.manifest();
      final plan = await fixture.service().preview(
        await fullSource(source),
        const ImportSelection.full(),
      );
      expect(plan.affectedPeople, isEmpty);
      final replacement = plan.replacedWorkspaces.single;
      expect(replacement.workspaceId, target.context.workspaceId);
      expect(replacement.tableCounts['setup_drafts'], 1);
      expect(replacement.tableCounts['pending_operations'], 1);
      expect(replacement.tableCounts['pending_operation_effects'], 1);
      expect(replacement.operationStates, {'sending': 1});
      expect(replacement.effectStates, {'sending': 1});
      await target.db
          .into(target.db.doseLogs)
          .insert(
            DoseLogsCompanion.insert(
              id: 'fictional-target-orphan-dose',
              scheduleId: 'deleted-original-schedule',
              scheduledAt: DateTime.utc(2026, 10, 1),
              status: 'taken',
              note: const Value('Retained target history'),
              createdAt: DateTime.utc(2026, 10, 1),
              updatedAt: DateTime.utc(2026, 10, 1),
            ),
          );
      final withOrphan = await fixture.service().preview(
        await fullSource(source),
        const ImportSelection.full(),
      );
      expect(withOrphan.affectedPeople, isEmpty);
      expect(withOrphan.unattributedTargetCounts['dose_logs'], 1);
      expect((await fixture.files.manifest()).revision, marker.revision);
      expect(
        (await target.db.select(target.db.pendingOperations).get())
            .single
            .state,
        'sending',
      );
    },
  );
  test('failed protected recovery prevents any replacement', () async {
    final fixture = await ProtectedRestoreFixture.create();
    addTearDown(fixture.close);
    final source = await ProtectedWorkspaceFixture.create();
    addTearDown(source.db.close);
    final input = await fullSource(source),
        service = fixture.service(),
        target = fixture.workspace;
    final plan = await service.preview(input, const ImportSelection.full());
    final marker = await fixture.files.manifest(),
        person = (await target.db.select(target.db.profiles).get()).single;
    final key = await fixture.files.keyStore.read();
    await fixture.files.keyStore.write('controlled-invalid-fixture-key');
    await expectLater(
      service.apply(plan),
      throwsA(
        isA<ImportFailure>().having(
          (e) => e.code,
          'code',
          ImportFailureCode.recoveryUnavailable,
        ),
      ),
    );
    await fixture.files.keyStore.write(key!);
    expect((await fixture.files.manifest()).revision, marker.revision);
    expect((await target.db.select(target.db.profiles).get()).single, person);
    expect(await target.db.select(target.db.importReceipts).get(), isEmpty);
    await target.access.requireCurrent(target.context);
    expect(fixture.resumed, isTrue);
  });
  test(
    'differing current local-author metadata is disclosed and both originals retained',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final source = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      final target = fixture.workspace;
      await source.db.customStatement(
        'UPDATE workspace_authors SET id=?,display_name=? WHERE id=?',
        [
          target.context.authorId,
          'Earlier source label',
          source.context.authorId,
        ],
      );
      await source.db.customStatement(
        'UPDATE care_workspaces SET current_author_id=? WHERE id=?',
        [target.context.authorId, source.context.workspaceId],
      );
      final input = await fullSource(source), service = fixture.service();
      final original =
          (await target.db.select(target.db.workspaceAuthors).get()).single;
      final plan = await service.preview(input, const ImportSelection.full());
      expect(plan.conflicts, 1);
      await service.apply(plan);
      expect(
        (await target.db.select(target.db.workspaceAuthors).get()).singleWhere(
          (a) => a.id == target.context.authorId,
        ),
        original,
      );
      final receipt = (await ImportDao(
        target.db,
      ).receipts(target.context.workspaceId)).single;
      final dao = ImportDao(target.db),
          key = jsonEncode([target.context.authorId]);
      expect(
        (await dao.originalRow(
          receiptId: receipt.id,
          table: 'workspace_authors',
          key: key,
        ))['display_name'],
        'Earlier source label',
      );
      expect(
        (await dao.originalRow(
          receiptId: receipt.id,
          table: 'workspace_authors',
          key: key,
          version: 'current',
        ))['display_name'],
        original.displayName,
      );
    },
  );
  test(
    'an author collision from another connected workspace refuses activation',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final source = await ProtectedWorkspaceFixture.create(
        ownerId: '10000000-0000-4000-8000-000000000009',
      );
      addTearDown(source.db.close);
      final target = fixture.workspace;
      await source.db.customStatement(
        'UPDATE workspace_authors SET id=? WHERE id=?',
        [target.context.authorId, source.context.authorId],
      );
      await source.db.customStatement(
        'UPDATE care_workspaces SET current_author_id=? WHERE id=?',
        [target.context.authorId, source.context.workspaceId],
      );
      final marker = await fixture.files.manifest();
      await expectLater(
        fixture.service().preview(
          await fullSource(source),
          const ImportSelection.full(),
        ),
        throwsA(
          isA<ImportFailure>().having(
            (e) => e.code,
            'code',
            ImportFailureCode.invalidSource,
          ),
        ),
      );
      expect((await fixture.files.manifest()).revision, marker.revision);
      expect(
        (await target.db.select(target.db.profiles).get()).single.name,
        'Fictional previous care',
      );
    },
  );
  test(
    'empty source retains personless draft and pending work without promoting queues',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final source = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      final draft = await SetupRepository(
        database: source.db,
        access: source.access,
        context: source.context,
      ).resumeOrCreateDraft();
      final now = DateTime.utc(2026, 10, 1);
      await source.db
          .into(source.db.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              id: 'fictional-original-operation',
              userId: source.context.ownerUserId,
              mutationId: 'fictional-mutation',
              component: 'medication',
              operationType: 'take',
              contractVersion: 2,
              payloadJson: '{"originalAuthor":"retained"}',
              state: const Value('sending'),
              createdAt: now,
            ),
          );
      await source.db
          .into(source.db.pendingOperationEffects)
          .insert(
            PendingOperationEffectsCompanion.insert(
              id: 'fictional-effect',
              operationId: 'fictional-original-operation',
              ordinal: 0,
              kind: 'dose',
              requestFingerprint: 'original',
              state: const Value('sending'),
              attemptedAt: Value(now),
            ),
          );
      await source.db
          .into(source.db.syncStagingRuns)
          .insert(
            SyncStagingRunsCompanion.insert(
              id: 'fictional-stage',
              userId: source.context.ownerUserId,
              component: 'medication',
              contractVersion: 2,
              afterSequence: '0',
              throughSequence: '1',
              startedAt: now,
            ),
          );
      await source.db
          .into(source.db.syncStagingItems)
          .insert(
            SyncStagingItemsCompanion.insert(
              runId: 'fictional-stage',
              serverSequence: 1,
              entityType: 'occurrence',
              entityId: 'fictional-original',
              payloadJson: '{}',
            ),
          );
      final input = await fullSource(source), service = fixture.service();
      final plan = await service.preview(input, const ImportSelection.full());
      expect(plan.people, isEmpty);
      expect(plan.workspaces.single.rows, greaterThan(0));
      expect(plan.workspaces.single.retainedRows, greaterThanOrEqualTo(4));
      await service.apply(plan);
      final target = fixture.workspace;
      expect(await target.db.select(target.db.profiles).get(), isEmpty);
      expect(
        (await target.db.select(target.db.setupDrafts).get()).single.id,
        draft.id,
      );
      expect(
        (await target.db.select(target.db.setupDrafts).get()).single.authorId,
        target.context.authorId,
      );
      expect(
        await target.db.select(target.db.pendingOperations).get(),
        isEmpty,
      );
      expect(
        await target.db.select(target.db.pendingOperationEffects).get(),
        isEmpty,
      );
      expect(await target.db.select(target.db.syncStagingRuns).get(), isEmpty);
      expect(await target.db.select(target.db.syncStagingItems).get(), isEmpty);
      final receipt = (await ImportDao(
        target.db,
      ).receipts(target.context.workspaceId)).single;
      final original = await ImportDao(target.db).originalRow(
        receiptId: receipt.id,
        table: 'pending_operations',
        key: jsonEncode(['fictional-original-operation']),
      );
      expect(original['user_id'], source.context.ownerUserId);
      expect(original['state'], 'sending');
      expect(original['payload_json'], '{"originalAuthor":"retained"}');
    },
  );
  test(
    'stale full review and failed commit preserve care and resume original runtime',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final source = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      final input = await fullSource(source), target = fixture.workspace;
      await target.preferences.setString('app_locale', 'en');
      final service = fixture.service();
      final plan = await service.preview(input, const ImportSelection.full());
      final person = (await target.db.select(target.db.profiles).get()).single;
      await (target.db.update(target.db.profiles)
            ..where((r) => r.id.equals(person.id)))
          .write(const ProfilesCompanion(name: Value('Later reviewed care')));
      final marker = await fixture.files.manifest();
      await expectLater(
        service.apply(plan),
        throwsA(
          isA<ImportFailure>().having(
            (e) => e.code,
            'code',
            ImportFailureCode.staleTarget,
          ),
        ),
      );
      expect((await fixture.files.manifest()).revision, marker.revision);
      expect(fixture.resumed, isTrue);
      final failing = fixture.service(
        beforeCommit: () async {
          throw StateError('controlled commit interruption');
        },
      );
      await expectLater(
        failing.apply(
          await failing.preview(input, const ImportSelection.full()),
        ),
        throwsA(
          isA<ImportFailure>().having(
            (e) => e.code,
            'code',
            ImportFailureCode.commitFailed,
          ),
        ),
      );
      expect(
        (await target.db.select(target.db.profiles).get()).single.name,
        'Later reviewed care',
      );
      expect(await target.db.select(target.db.importReceipts).get(), isEmpty);
      expect(
        await target.db.select(target.db.deviceRestoreIntents).get(),
        isEmpty,
      );
      await target.access.requireCurrent(target.context);
      expect(
        (await RecoveryCopyService(
          fixture.files,
        ).check(await fixture.files.manifest())).state,
        RecoveryCopyState.checked,
      );
      expect(target.preferences.getString('app_locale'), 'en');
    },
  );
  test(
    'connected full restore retains exact evidence and later authentication cannot activate archived care',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final source = await CareRecordingFixture.create(connected: true);
      addTearDown(source.db.close);
      final originalCare = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      await originalCare.commit(
        await originalCare.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      final input = await fullSource(source.workspace),
          service = fixture.service();
      final plan = await service.preview(input, const ImportSelection.full());
      expect(plan.people.single.outcome, ImportPersonOutcome.locked);
      await service.apply(plan);
      final target = fixture.workspace;
      expect(await target.db.profilesDao.getById(source.person.id), isNull);
      final owner = source.workspace.context.ownerUserId;
      final workspace = await target.access.workspaces.byOwner(owner);
      expect(workspace!.id, source.workspace.context.workspaceId);
      expect(workspace.endpoint, source.workspace.context.endpoint);
      expect(await target.access.contextForOwner(owner), isNull);
      expect(await target.access.currentNetworkCapability(), isNull);
      expect(await target.db.select(target.db.credentialSlots).get(), isEmpty);
      expect(
        await target.db.select(target.db.installationKeySlots).get(),
        isEmpty,
      );
      expect(
        await target.db.select(target.db.workspaceSyncCheckpoints).get(),
        isEmpty,
      );
      expect(
        await target.db.select(target.db.pendingOperations).get(),
        isEmpty,
      );
      final receipt =
          (await target.db.select(target.db.importReceipts).get()).single;
      final retained = ImportDao(target.db);
      for (final table in [
        'profiles',
        'medication_occurrences',
        'occurrence_events',
        'care_event_details',
        'pending_operations',
      ]) {
        expect(input.document.tables[table], isNotEmpty);
        for (final original in input.document.tables[table]!) {
          expect(
            await retained.originalRow(
              receiptId: receipt.id,
              table: table,
              key: jsonEncode([
                for (final c in BackupInventory.primaryKeys[table]!)
                  original[c],
              ]),
            ),
            original,
          );
        }
      }
      final endpoint = workspace.endpoint!;
      final epoch = await target.access.configureEndpoint(endpoint);
      await target.db
          .into(target.db.credentialSlots)
          .insert(
            CredentialSlotsCompanion.insert(
              id: 'fictional-after-restore-slot',
              ownerId: owner,
              endpoint: endpoint,
              state: 'staged',
              createdAt: DateTime.utc(2026, 10, 1),
            ),
          );
      await target.access.authenticate(
        ownerId: owner,
        endpoint: endpoint,
        expectedNetworkEpoch: epoch,
        sessionGeneration: 8,
        credentialId: 'fictional-after-restore-slot',
      );
      final connected = (await target.access.currentContext());
      expect(connected.isLocal, isFalse);
      expect(await target.db.profilesDao.getById(source.person.id), isNull);
      expect(
        await target.db.medicationLedgerDao.getOccurrenceById(
          source.occurrence.id,
        ),
        isNull,
      );
      expect(await target.db.select(target.db.occurrenceEvents).get(), isEmpty);
      await expectLater(
        CareRecordingService(
          database: target.db,
          access: target.access,
          context: connected,
        ).prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 1,
        ),
        throwsA(isA<MedicationCommandBlocked>()),
      );
    },
  );
  test(
    'full preview is read-only; replacement checks recovery and invalidates old access',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final target = fixture.workspace, store = fixture.files;
      final source = await CareRecordingFixture.create();
      addTearDown(source.db.close);
      final originalCare = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      final original = await originalCare.commit(
        await originalCare.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      await originalCare.commit(await originalCare.prepareUndo(original));
      await source.workspace.preferences.setString('app_locale', 'ro');
      final document = (await BackupService(
        database: source.db,
        access: source.workspace.access,
        preferences: source.workspace.preferences,
        files: const AndroidBackupFileAccess(),
      ).captureFull()).document;
      final input = CheckedBackup(
        document,
        const BackupFileLocation('fictional', 'Care.simpbak'),
        DateTime.utc(2026, 10, 1),
        passwordProtected: true,
      );
      await target.preferences.setString('app_locale', 'en');
      var reservationChecks = 0;
      final service = fixture.service(
        syncDirectory: (_) async {
          final contender = fixture.prepared.openEstablished();
          try {
            expect(
              () => contender.execute('BEGIN IMMEDIATE'),
              throwsA(isA<SqliteException>()),
            );
            reservationChecks++;
          } finally {
            contender.close();
          }
        },
      );
      final before = (await target.db.select(target.db.profiles).get()).single;
      final marker = await store.manifest();
      final plan = await service.preview(input, const ImportSelection.full());
      expect((await target.db.select(target.db.profiles).get()).single, before);
      expect((await store.manifest()).revision, marker.revision);
      expect(plan.affectedPeople.single.id, before.id);
      final result = await service.apply(plan);
      expect(fixture.drained, isTrue);
      expect(reservationChecks, greaterThan(0));
      expect(result.recoveryChecked, isTrue);
      expect(result.preferences, ImportPreferenceState.completed);
      expect(
        (await target.db.select(target.db.profiles).get()).single.id,
        source.person.id,
      );
      await expectLater(
        target.access.requireCurrent(target.context),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(
        (await target.access.currentContext()).authorId,
        target.context.authorId,
      );
      expect(
        (await RecoveryCopyService(store).check(await store.manifest())).state,
        RecoveryCopyState.checked,
      );
      expect(target.preferences.getString('app_locale'), 'ro');
      final current = (await target.access.currentContext());
      final care = CareRecordingService(
        database: target.db,
        access: target.access,
        context: current,
        clock: () => DateTime.utc(2026, 9, 30, 10),
      );
      expect(
        (await care.historyForPerson(source.person.id)).map((f) => f.authorId),
        everyElement(source.workspace.context.authorId),
      );
      final taken = await care.commit(
        await care.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 2,
        ),
      );
      expect(taken.authorId, target.context.authorId);
      expect(
        (await care.commit(await care.prepareUndo(taken))).current.state,
        'pending',
      );
      final facts =
          (await target.db.select(target.db.occurrenceEvents).get()).length;
      expect((await service.apply(plan)).alreadyApplied, isTrue);
      expect(
        (await target.db.select(target.db.occurrenceEvents).get()).length,
        facts,
      );
      final reopened = fixture.service(context: current);
      final repeatedPlan = await reopened.preview(
        input,
        const ImportSelection.full(),
      );
      expect(repeatedPlan.alreadyApplied, isTrue);
      final repeated = await reopened.apply(repeatedPlan);
      expect(repeated.alreadyApplied, isTrue);
      expect(repeated.preferences, ImportPreferenceState.completed);
      expect(repeated.projectionsPending, isTrue);
      expect(
        (await target.db.select(target.db.occurrenceEvents).get()).length,
        facts,
      );
    },
  );
}
