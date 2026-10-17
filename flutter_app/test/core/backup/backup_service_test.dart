import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:simpastil/core/backup/backup_codec.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_inventory.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/reviewed_stock.dart';

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/protected_workspace_fixture.dart';

Matcher failure(BackupFailureCode code) =>
    throwsA(isA<BackupFailure>().having((e) => e.code, 'code', code));

class MemoryDestination implements BackupFileAccess {
  Future<void> Function()? onChoose;
  Uint8List? bytes;
  bool cancelled = false, failWrite = false, failRead = false, damage = false;
  bool oversizedRead = false;
  int writes = 0;

  @override
  Future<BackupFileLocation?> chooseSave(String suggestedName) async {
    await onChoose?.call();
    return cancelled
        ? null
        : const BackupFileLocation('chosen', 'Example.simpbak');
  }

  @override
  Future<BackupFileLocation?> chooseOpen() async =>
      const BackupFileLocation('chosen', 'Example.simpbak');
  @override
  Future<void> write(BackupFileLocation location, Uint8List value) async {
    writes++;
    bytes = Uint8List.fromList(value);
    if (failWrite) throw StateError('provider stopped after dispatch');
  }

  @override
  Future<Uint8List> read(BackupFileLocation location) async {
    if (oversizedRead) throw const BackupFailure(BackupFailureCode.tooLarge);
    if (failRead) throw StateError('provider cannot reopen');
    final result = Uint8List.fromList(bytes!);
    if (damage) result[80] ^= 1;
    return result;
  }
}

BackupService service(ProtectedWorkspaceFixture f, MemoryDestination files) =>
    BackupService(
      database: f.db,
      access: f.access,
      preferences: f.preferences,
      files: files,
      clock: () => DateTime.utc(2026, 10, 1, 9),
    );

Future<Map<String, Object?>> databaseFacts(AppDatabase db) async => {
  for (final table in db.allTables)
    table.actualTableName:
        (await db
                .customSelect('SELECT * FROM "${table.actualTableName}"')
                .get())
            .map((row) => row.data)
            .toList(),
};

Future<void> populateRemainingInventory(CareRecordingFixture care) async {
  final f = care.workspace, db = care.db;
  final now = DateTime.utc(2026, 9, 30);
  final schedule = (await db.select(db.schedules).get()).first;
  await db
      .into(db.doseLogs)
      .insert(
        DoseLogsCompanion.insert(
          id: 'retained-legacy-dose',
          scheduleId: schedule.id,
          scheduledAt: now,
          status: 'taken',
          note: const Value('Original legacy evidence'),
          createdAt: now,
          updatedAt: now,
        ),
      );
  await (db.update(db.pills)..where((p) => p.id.equals(care.pill.id))).write(
    const PillsCompanion(
      dosage: Value('Original unreviewed dosage text'),
      currentStock: Value(10),
    ),
  );
  final stocks = ReviewedStockRepository(
    database: db,
    access: f.access,
    context: f.context,
  );
  await stocks.review(
    care.pill.id,
    StockQuantity.parse('10', 'tablet'),
    expectedRevision: 0,
  );
  final medication = MedicationRepository(
    db,
    access: f.access,
    context: f.context,
  );
  await medication.apply(
    userId: f.context.ownerUserId,
    occurrenceId: care.occurrence.id,
    action: MedicationAction.take,
    amount: MedicationAmount.known('1/2', 'tablet'),
    actualTimeKnown: false,
    commandIdOverride: '30000000-0000-4000-8000-000000000001',
  );
  final event = (await db.medicationLedgerDao.getEventsForOccurrence(
    care.occurrence.id,
  )).single;
  await medication.apply(
    userId: f.context.ownerUserId,
    occurrenceId: care.occurrence.id,
    action: MedicationAction.undo,
    intendedState: MedicationState.pending,
    reversesEventId: event.id,
    actualTimeKnown: false,
    commandIdOverride: '30000000-0000-4000-8000-000000000002',
  );
  await db
      .into(db.migrationIssues)
      .insert(
        MigrationIssuesCompanion.insert(
          id: 'retained-legacy-review',
          userId: f.context.ownerUserId,
          entityType: 'dose_log',
          entityId: 'retained-legacy-dose',
          issueCode: 'original_unresolved',
          snapshotJson: '{"incompleteOriginal":',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await db
      .into(db.inventoryEvents)
      .insert(
        InventoryEventsCompanion.insert(
          id: 'retained-legacy-stock',
          userId: f.context.ownerUserId,
          pillId: care.pill.id,
          commandId: 'original-legacy-stock-command',
          kind: 'opening',
          delta: 10,
          origin: 'legacy_backfill',
          provenanceJson: const Value('{"originalCount":10}'),
          recordedAt: now,
        ),
      );
  await db
      .into(db.devicePersonReminders)
      .insertOnConflictUpdate(
        DevicePersonRemindersCompanion.insert(
          profileId: care.person.id,
          enabled: const Value(true),
        ),
      );
  await db
      .into(db.deviceScheduleReminders)
      .insert(
        DeviceScheduleRemindersCompanion.insert(
          workspaceId: f.context.workspaceId,
          scheduleId: schedule.id,
          followUpMinutesJson: const Value('[15,30]'),
        ),
      );
  await db
      .into(db.workspaceAuthors)
      .insert(
        WorkspaceAuthorsCompanion.insert(
          id: 'historical-imported-author',
          workspaceId: f.context.workspaceId,
          displayName: const Value('Original imported author'),
          provenance: 'imported',
          createdAt: now,
        ),
      );
  await db
      .into(db.refreshTokens)
      .insert(
        RefreshTokensCompanion.insert(
          id: 'excluded-session',
          userId: f.context.ownerUserId,
          familyId: 'excluded-family',
          expiresAt: now,
          createdAt: now,
        ),
      );
  await db
      .into(db.installationKeySlots)
      .insert(
        InstallationKeySlotsCompanion.insert(
          id: 'excluded-installation-slot',
          endpoint: 'https://fictional-workspace.test/care',
          state: 'staged',
          createdAt: now,
        ),
      );
  await db
      .into(db.syncComponentStates)
      .insert(
        SyncComponentStatesCompanion.insert(
          userId: f.context.ownerUserId,
          component: 'stable',
          contractVersion: 1,
          lastCompletedCursor: const Value('excluded-live-cursor'),
        ),
      );
  await db
      .into(db.workspaceSyncCheckpoints)
      .insert(
        WorkspaceSyncCheckpointsCompanion.insert(
          workspaceId: f.context.workspaceId,
          profileId: care.person.id,
          channel: 'legacy',
          cursor: 'excluded-live-checkpoint',
          completedAt: now,
        ),
      );
  await ProtectedWorkspaceFixture.create(
    database: db,
    preferences: f.preferences,
    ownerId: 'connected-inventory-owner',
  );
  await db
      .into(db.importReceipts)
      .insert(
        ImportReceiptsCompanion.insert(
          id: 'retained-import-receipt',
          workspaceId: f.context.workspaceId,
          sourceDigest: 'original-import-digest',
          sourceDocumentId: 'original-backup',
          sourceCapturedAt: now,
          mode: 'selected',
          selectedProfileIdsJson: '[]',
          identityMapJson: '{}',
          appliedAt: now,
        ),
      );
  await db
      .into(db.importEvidence)
      .insert(
        ImportEvidenceCompanion.insert(
          receiptId: 'retained-import-receipt',
          entityTable: 'profiles',
          entityKey: '["original-person"]',
          version: 'incoming',
          ordinal: 0,
          sourceDigest: 'original-row-digest',
          payloadBase64: 'e30=',
          disposition: 'conflict',
        ),
      );
  await db
      .into(db.importConflicts)
      .insert(
        ImportConflictsCompanion.insert(
          id: 'retained-import-conflict',
          receiptId: 'retained-import-receipt',
          workspaceId: f.context.workspaceId,
          entityTable: 'profiles',
          entityKey: '["original-person"]',
          currentDigest: 'current-row-digest',
          incomingDigest: 'original-row-digest',
          createdAt: now,
        ),
      );
  await db
      .into(db.deviceRestoreIntents)
      .insert(
        DeviceRestoreIntentsCompanion.insert(
          id: 'private-restore-intent',
          receiptId: 'retained-import-receipt',
          expectedPreferencesDigest: 'private-preferences-digest',
          operationsJson: '{}',
          completedOperationsJson: '[]',
          recoveryGeneration: 'private-device-recovery',
          state: 'pending',
          createdAt: now,
        ),
      );
}

void main() {
  setUpAll(tz.initializeTimeZones);
  test(
    'selected-file check is read-only and remains bound to the actual chosen file',
    () async {
      final care = await CareRecordingFixture.create();
      final f = care.workspace;
      addTearDown(f.db.close);
      final files = MemoryDestination();
      final backups = service(f, files);
      final captured = await backups.captureFull();
      final before = await databaseFacts(f.db);
      files.bytes = await const BackupCodec().encode(
        captured.document,
        password: 'Example backup password',
      );
      final source = (await backups.selectSource())!;
      expect(source.passwordProtected, isTrue);
      await expectLater(
        backups.checkSource(source, password: 'Wrong password'),
        failure(BackupFailureCode.passwordOrIntegrity),
      );
      final checked = await backups.checkSource(
        source,
        password: 'Example backup password',
      );
      expect(checked.document.toJson(), captured.document.toJson());
      expect(checked.checkedAt, DateTime.utc(2026, 10, 1, 9));
      files.bytes![80] ^= 1;
      await expectLater(
        backups.checkSource(source, password: 'Example backup password'),
        failure(BackupFailureCode.sourceChanged),
      );
      expect(await databaseFacts(f.db), before);
    },
  );

  test(
    'oversized stored care refuses capture without changing original rows',
    () async {
      final care = await CareRecordingFixture.create();
      final f = care.workspace;
      addTearDown(f.db.close);
      await (f.db.update(
        f.db.pills,
      )..where((p) => p.id.equals(care.pill.id))).write(
        PillsCompanion(notes: Value('x' * (maximumBackupStringBytes + 1))),
      );
      final before = await databaseFacts(f.db);
      await expectLater(
        service(f, MemoryDestination()).captureFull(),
        failure(BackupFailureCode.tooLarge),
      );
      expect(await databaseFacts(f.db), before);
    },
  );

  test(
    'inventory classifies every real table, field and portable primary key',
    () async {
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      expect(db.schemaVersion, 18);
      expect(
        db.allTables.map((t) => t.actualTableName).toSet(),
        BackupInventory.sourceColumns.keys.toSet(),
      );
      for (final table in db.allTables) {
        expect(
          table.$columns.map((c) => c.$name).toSet(),
          BackupInventory.sourceColumns[table.actualTableName]!.toSet(),
          reason: table.actualTableName,
        );
        if (!BackupInventory.excludedTables.contains(table.actualTableName)) {
          expect(
            table.$primaryKey.map((c) => c.$name).toSet(),
            BackupInventory.primaryKeys[table.actualTableName]!.toSet(),
            reason: table.actualTableName,
          );
        }
      }
    },
  );

  test(
    'full capture retains routine, draft, preferences and uncertain authored work without authority',
    () async {
      final care = await CareRecordingFixture.create();
      final f = care.workspace;
      addTearDown(f.db.close);
      await f.preferences.setString('app_locale', 'ro');
      await f.preferences.setInt(
        'snooze_duration_minutes_${f.context.ownerUserId}',
        20,
      );
      await f.preferences.setString('access_token', 'must never enter backup');
      await f.db
          .into(f.db.deviceReminderSettings)
          .insert(
            DeviceReminderSettingsCompanion.insert(
              workspaceId: f.context.workspaceId,
              fullDetails: const Value(false),
              readinessEpoch: const Value(4),
              testJson: const Value(
                '{"oldPhoneDelivery":"must not become readiness"}',
              ),
            ),
          );
      await f.db
          .into(f.db.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              id: 'retained-operation',
              userId: f.context.ownerUserId,
              mutationId: 'old-mutation',
              component: 'medicationBridge',
              operationType: 'bridge',
              contractVersion: 1,
              payloadJson: '{"originalAuthor":"${f.context.authorId}"}',
              state: const Value('sending'),
              attemptCount: const Value(2),
              createdAt: DateTime.utc(2026, 9, 30),
            ),
          );
      await f.db
          .into(f.db.pendingOperationEffects)
          .insert(
            PendingOperationEffectsCompanion.insert(
              id: 'retained-uncertainty',
              operationId: 'retained-operation',
              ordinal: 0,
              kind: 'dose',
              requestFingerprint: 'original-fingerprint',
              state: const Value('uncertain'),
              attemptedAt: Value(DateTime.utc(2026, 9, 30)),
            ),
          );
      await f.db
          .into(f.db.syncStagingRuns)
          .insert(
            SyncStagingRunsCompanion.insert(
              id: 'retained-stage',
              userId: f.context.ownerUserId,
              component: 'medicationBridge',
              contractVersion: 3,
              afterSequence: '3',
              throughSequence: '7',
              nextCursor: const Value('factual-old-cursor'),
              startedAt: DateTime.utc(2026, 9, 30),
            ),
          );
      await f.db
          .into(f.db.syncStagingItems)
          .insert(
            SyncStagingItemsCompanion.insert(
              runId: 'retained-stage',
              serverSequence: 4,
              entityType: 'profile',
              entityId: care.person.id,
              payloadJson: '{"name":"Unmerged original"}',
            ),
          );
      await populateRemainingInventory(care);
      expect(await f.db.select(f.db.effectSettlements).get(), isEmpty);
      final before = await databaseFacts(f.db);
      for (final table in f.db.allTables) {
        if (table.actualTableName == 'effect_settlements') continue;
        expect(
          before[table.actualTableName] as List,
          isNotEmpty,
          reason: table.actualTableName,
        );
      }
      final snapshot = await service(f, MemoryDestination()).captureFull();
      final doc = snapshot.document;
      expect(doc.sourceSchema, 18);
      expect(doc.tables, isNot(contains('person_first_seen')));
      expect(doc.tables['sync_staging_runs']!.single['contract_version'], 3);
      expect(
        doc.tables.keys.toSet(),
        BackupInventory.portableTableNames.toSet(),
      );
      expect(doc.tables['profiles']!.single['id'], care.person.id);
      expect(
        doc.tables['local_routines']!.single['author_id'],
        f.context.authorId,
      );
      expect(doc.tables['setup_drafts'], isNotEmpty);
      expect(doc.tables['pending_operations']!.single['state'], 'sending');
      expect(
        doc.tables['pending_operation_effects']!.single['state'],
        'uncertain',
      );
      expect(
        doc.tables['sync_staging_runs']!.single['next_cursor'],
        'factual-old-cursor',
      );
      expect(doc.tables['schedules']!.single['time_zone'], isNull);
      expect(
        doc.tables['schedules']!.single['time_zone_status'],
        'legacy_unknown',
      );
      expect(
        doc.tables['sync_staging_items']!.single['payload_json'],
        '{"name":"Unmerged original"}',
      );
      expect(doc.preferences['app_locale'], 'ro');
      expect(
        doc.preferences['snooze_duration_minutes_${f.context.ownerUserId}'],
        20,
      );
      expect(
        doc.preferences['selected_workspace_id'],
        ((before['workspace_device_states'] as List).single
            as Map)['selected_workspace_id'],
      );
      expect(doc.preferences, isNot(contains('access_token')));
      // Settlement dispositions are local review authority and remain out of
      // portable backups even though the v14 database stores them.
      expect(doc.tables, isNot(contains('effect_settlements')));
      for (final row in doc.tables['users']!) {
        expect(row, isNot(contains('session_generation')));
      }
      expect(
        doc.tables['device_reminder_settings']!.single.keys,
        unorderedEquals(['workspace_id', 'full_details']),
      );
      for (final name in BackupInventory.portableTableNames) {
        final projected = (before[name] as List)
            .map(
              (raw) => {
                for (final column in BackupInventory.portableColumns(name))
                  column: (raw as Map)[column],
              },
            )
            .toList();
        expect(doc.tables[name], unorderedEquals(projected), reason: name);
      }
      expect(await databaseFacts(f.db), before);
    },
  );

  test(
    'locked retained workspace prevents a full backup before capture',
    () async {
      final local = await ProtectedWorkspaceFixture.create();
      addTearDown(local.db.close);
      final connected = await ProtectedWorkspaceFixture.create(
        database: local.db,
        preferences: local.preferences,
        ownerId: 'connected-owner',
      );
      await connected.access.revokeNetwork();
      await expectLater(
        service(local, MemoryDestination()).captureFull(),
        failure(BackupFailureCode.fullBackupUnavailable),
      );
    },
  );

  test(
    'proven deleted-parent evidence survives; ambiguous or unproven ownership refuses',
    () async {
      final care = await CareRecordingFixture.create();
      final f = care.workspace;
      addTearDown(f.db.close);
      // The real occurrence proves this deleted pill's original owner. A join
      // that only walks present parents would silently drop its details.
      await f.db.customStatement('PRAGMA foreign_keys=OFF');
      await f.db.customStatement('DELETE FROM pills WHERE id=?', [
        care.pill.id,
      ]);
      final snapshot = await service(f, MemoryDestination()).captureFull();
      expect(
        snapshot.document.tables['medication_details']!.single['pill_id'],
        care.pill.id,
      );
      await f.db.customStatement('DELETE FROM local_routines');
      await f.db.customStatement('DELETE FROM medication_occurrences');
      await f.db.customStatement('DELETE FROM setup_drafts');
      await expectLater(
        service(f, MemoryDestination()).captureFull(),
        failure(BackupFailureCode.ownershipUnproven),
      );
    },
  );

  test(
    'destination cancellation and revoked picker return dispatch no care bytes',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final files = MemoryDestination()..cancelled = true;
      final backups = service(f, files);
      final snapshot = await backups.captureFull();
      expect(
        (await backups.save(snapshot, allowClear: true)).status,
        BackupSaveStatus.cancelled,
      );
      expect(files.writes, 0);
      files.cancelled = false;
      // A same-workspace epoch change invalidates the captured access.
      files.onChoose = () async {
        await f.db.customStatement('UPDATE workspace_grants SET epoch=epoch+1');
      };
      await expectLater(
        backups.save(snapshot, allowClear: true),
        failure(BackupFailureCode.staleAccess),
      );
      expect(files.writes, 0);
    },
  );

  test(
    'Saved and Checked reflect exact destination reopening; partial write is reported',
    () async {
      final care = await CareRecordingFixture.create();
      final f = care.workspace;
      addTearDown(f.db.close);
      final files = MemoryDestination();
      final backups = service(f, files);
      final snapshot = await backups.captureFull();
      final before = await databaseFacts(f.db);
      final checked = await backups.save(
        snapshot,
        password: 'Example backup password',
      );
      expect(checked.status, BackupSaveStatus.savedChecked);
      expect(
        (await const BackupCodec().decode(
          files.bytes!,
          password: 'Example backup password',
        )).toJson(),
        snapshot.document.toJson(),
      );
      files.failRead = true;
      expect(
        (await backups.save(snapshot, allowClear: true)).status,
        BackupSaveStatus.savedUnchecked,
      );
      files.failRead = false;
      files.oversizedRead = true;
      expect(
        (await backups.save(snapshot, allowClear: true)).status,
        BackupSaveStatus.savedCheckFailed,
      );
      files.oversizedRead = false;
      files.damage = true;
      expect(
        (await backups.save(snapshot, allowClear: true)).status,
        BackupSaveStatus.savedCheckFailed,
      );
      files.damage = false;
      files.failWrite = true;
      expect(
        (await backups.save(snapshot, allowClear: true)).status,
        BackupSaveStatus.saveFailedMayBePartial,
      );
      expect(await databaseFacts(f.db), before);
    },
  );
}
