import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_inventory.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/db/daos/import_dao.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:timezone/data/latest.dart' as tz;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/protected_workspace_fixture.dart';

Future<CheckedBackup> sourceFile(ProtectedWorkspaceFixture source) async =>
    CheckedBackup(
      (await BackupService(
        database: source.db,
        access: source.access,
        preferences: source.preferences,
        files: const AndroidBackupFileAccess(),
      ).captureFull()).document,
      const BackupFileLocation('fictional-connected-source', 'Care.simpbak'),
      DateTime.utc(2026, 10, 1),
      passwordProtected: true,
    );

ImportService service(ProtectedWorkspaceFixture target) => ImportService(
  database: target.db,
  access: target.access,
  preferences: target.preferences,
  context: target.context,
);

Future<void> insertRow(
  AppDatabase db,
  String table,
  Map<String, Object?> row,
) => db.customStatement(
  'INSERT INTO "$table" (${row.keys.map((k) => '"$k"').join(',')}) '
  'VALUES (${row.keys.map((_) => '?').join(',')})',
  row.values.toList(),
);

Future<WorkspaceContext> authorizeExisting(
  ProtectedWorkspaceFixture target,
  CheckedBackup source, {
  bool copyCare = true,
}) async {
  final tables = source.document.tables;
  final workspace = tables['care_workspaces']!.singleWhere(
    (w) => w['kind'] == 'connected',
  );
  final owner = workspace['owner_user_id'] as String;
  await insertRow(
    target.db,
    'users',
    tables['users']!.singleWhere((u) => u['id'] == owner),
  );
  await insertRow(target.db, 'care_workspaces', {
    ...workspace,
    'current_author_id': 'fictional-current-connected-author',
    'selected_profile_id': null,
  });
  await target.db
      .into(target.db.workspaceAuthors)
      .insert(
        WorkspaceAuthorsCompanion.insert(
          id: 'fictional-current-connected-author',
          workspaceId: workspace['id'] as String,
          provenance: 'workspace',
          createdAt: DateTime.utc(2026, 10, 1),
        ),
      );
  await target.db
      .into(target.db.workspaceGrants)
      .insert(
        WorkspaceGrantsCompanion.insert(workspaceId: workspace['id'] as String),
      );
  if (copyCare) {
    for (final name in [
      'profiles',
      'pills',
      'schedules',
      'medication_occurrences',
    ]) {
      for (final row in tables[name]!) {
        await insertRow(target.db, name, row);
      }
    }
  }
  final endpoint = workspace['endpoint'] as String;
  final epoch = await target.access.configureEndpoint(endpoint);
  await target.db
      .into(target.db.credentialSlots)
      .insert(
        CredentialSlotsCompanion.insert(
          id: 'fictional-connected-slot',
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
    sessionGeneration: 4,
    credentialId: 'fictional-connected-slot',
  );
  return (await target.access.contextForOwner(owner))!;
}

Future<String> facts(AppDatabase db) async => jsonEncode({
  for (final t in db.allTables)
    t.actualTableName:
        (await db
                .customSelect(
                  'SELECT * FROM "${t.actualTableName}" ORDER BY rowid',
                )
                .get())
            .map((r) => r.data)
            .toList(),
});

void main() {
  setUp(tz.initializeTimeZones);
  test(
    'mixed selection imports local care and retains new connected care locked',
    () async {
      final connected = await CareRecordingFixture.create(connected: true);
      final local = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(connected.db.close);
      addTearDown(local.db.close);
      addTearDown(target.db.close);
      final recording = CareRecordingService(
        database: connected.db,
        access: connected.workspace.access,
        context: connected.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      await recording.commit(
        await recording.prepareTakenNow(
          personId: connected.person.id,
          occurrenceId: connected.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      expect(
        await connected.db.select(connected.db.pendingOperations).get(),
        isNotEmpty,
      );
      // A checked mixed document has independent original containers.
      final connectedInput = await sourceFile(connected.workspace);
      final localInput = await sourceFile(local.workspace);
      final input = CheckedBackup(
        BackupDocument(
          id: 'fictional-mixed-backup',
          capturedAt: DateTime.utc(2026, 10, 1),
          sourceSchema: 11,
          scope: BackupScope.full,
          tables: {
            for (final table in BackupInventory.portableTableNamesFor(11))
              table: [
                for (final row in [
                  ...connectedInput.document.tables[table]!,
                  ...localInput.document.tables[table]!,
                ])
                  {
                    for (final column in BackupInventory.portableColumns(
                      table,
                      schema: 11,
                    ))
                      column: row[column],
                  },
              ],
          },
          preferences: const {'app_locale': 'ro'},
        ),
        connectedInput.location,
        connectedInput.checkedAt,
        passwordProtected: true,
      );
      final before = await facts(target.db);
      final importer = service(target);
      final plan = await importer.preview(
        input,
        ImportSelection.profiles({local.person.id, connected.person.id}),
      );
      expect(await facts(target.db), before);
      expect(
        plan.people.singleWhere((p) => p.id == connected.person.id).outcome,
        ImportPersonOutcome.locked,
      );
      final result = await importer.apply(plan);
      expect(result.alreadyApplied, isFalse);
      expect(
        (await target.db.select(target.db.profiles).get()).single.id,
        local.person.id,
      );
      final restored = await target.access.workspaces.byOwner(
        connected.workspace.context.ownerUserId,
      );
      expect(restored!.id, connected.workspace.context.workspaceId);
      expect(restored.endpoint, connected.workspace.context.endpoint);
      expect(
        restored.currentAuthorId,
        isNot(connected.workspace.context.authorId),
      );
      expect(await target.access.contextForOwner(restored.ownerUserId), isNull);
      expect(
        (await target.db.select(target.db.workspaceGrants).get())
            .singleWhere((g) => g.workspaceId == restored.id)
            .isGranted,
        isFalse,
      );
      final receipt =
          (await target.db.select(target.db.importReceipts).get()).single;
      final retained = await ImportDao(target.db).originalRow(
        receiptId: receipt.id,
        table: 'profiles',
        key: jsonEncode([connected.person.id]),
      );
      expect(retained['user_id'], restored.ownerUserId);
      expect(
        (await target.db.select(target.db.importEvidence).get())
            .singleWhere(
              (r) =>
                  r.entityTable == 'profiles' &&
                  r.entityKey == jsonEncode([connected.person.id]),
            )
            .disposition,
        'quarantined',
      );
      expect(
        await target.db.select(target.db.pendingOperations).get(),
        isEmpty,
      );
      expect(target.preferences.getString('app_locale'), isNull);
      for (final operation
          in await connected.db.select(connected.db.pendingOperations).get()) {
        expect(
          await ImportDao(target.db).originalRow(
            receiptId: receipt.id,
            table: 'pending_operations',
            key: jsonEncode([operation.id]),
          ),
          containsPair('payload_json', operation.payloadJson),
        );
      }
      final count = await facts(target.db);
      final repeat = await importer.preview(
        input,
        ImportSelection.profiles({local.person.id, connected.person.id}),
      );
      expect((await importer.apply(repeat)).alreadyApplied, isTrue);
      expect(await facts(target.db), count);
    },
  );
  test(
    'authorized exact connected partition retains grant and isolates source-only history',
    () async {
      final source = await CareRecordingFixture.create(connected: true);
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final initial = await sourceFile(source.workspace);
      final current = await authorizeExisting(target, initial);
      final grant = (await target.db.select(target.db.workspaceGrants).get())
          .singleWhere((g) => g.workspaceId == current.workspaceId);
      await source.db
          .into(source.db.doseLogs)
          .insert(
            DoseLogsCompanion.insert(
              id: 'fictional-preserved-history',
              scheduleId: source.occurrence.scheduleId!,
              scheduledAt: DateTime.utc(2026, 9, 29, 9),
              status: 'taken',
              createdAt: DateTime.utc(2026, 9, 29, 9),
              updatedAt: DateTime.utc(2026, 9, 29, 9),
            ),
          );
      final importer = service(target);
      final plan = await importer.preview(
        await sourceFile(source.workspace),
        ImportSelection.profiles({source.person.id}),
      );
      expect(plan.people.single.connected, isTrue);
      expect(plan.people.single.outcome, ImportPersonOutcome.unchanged);
      expect(plan.people.single.connectedEvidenceOnly, isTrue);
      expect(plan.people.single.retainedRows, greaterThan(0));
      expect(plan.ownershipTranslations, isEmpty);
      await importer.apply(plan);
      expect(await target.db.select(target.db.doseLogs).get(), isEmpty);
      final receipt =
          (await target.db.select(target.db.importReceipts).get()).single;
      expect(
        (await ImportDao(target.db).originalRow(
          receiptId: receipt.id,
          table: 'dose_logs',
          key: jsonEncode(['fictional-preserved-history']),
        ))['schedule_id'],
        source.occurrence.scheduleId,
      );
      expect(
        (await target.db.select(target.db.workspaceGrants).get()).singleWhere(
          (g) => g.workspaceId == current.workspaceId,
        ),
        grant,
      );
      await target.access.requireCurrent(current);
    },
  );
  test(
    'revocation between connected review and apply refuses the entire import',
    () async {
      final source = await CareRecordingFixture.create(connected: true);
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final input = await sourceFile(source.workspace);
      await authorizeExisting(target, input);
      final importer = service(target);
      final plan = await importer.preview(
        input,
        ImportSelection.profiles({source.person.id}),
      );
      await target.access.revokeNetwork();
      final before = await facts(target.db);
      await expectLater(
        importer.apply(plan),
        throwsA(
          isA<ImportFailure>().having(
            (e) => e.code,
            'code',
            ImportFailureCode.staleAccess,
          ),
        ),
      );
      expect(await facts(target.db), before);
    },
  );
  test(
    'connected divergence retains both versions and keeps the whole current graph',
    () async {
      final source = await CareRecordingFixture.create(connected: true);
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      await authorizeExisting(target, await sourceFile(source.workspace));
      final original = await target.db.profilesDao.getById(source.person.id);
      await (source.db.update(
        source.db.profiles,
      )..where((p) => p.id.equals(source.person.id))).write(
        const ProfilesCompanion(name: Value('Archived different name')),
      );
      final importer = service(target);
      final review = await importer.preview(
        await sourceFile(source.workspace),
        ImportSelection.profiles({source.person.id}),
      );
      expect(review.people.single.outcome, ImportPersonOutcome.needsReview);
      expect(review.conflicts, 1);
      await importer.apply(review);
      expect(await target.db.profilesDao.getById(source.person.id), original);
      expect(await target.db.select(target.db.occurrenceEvents).get(), isEmpty);
      final receipt =
          (await target.db.select(target.db.importReceipts).get()).single;
      for (final version in ['incoming', 'current']) {
        final retained = await ImportDao(target.db).originalRow(
          receiptId: receipt.id,
          table: 'profiles',
          key: jsonEncode([source.person.id]),
          version: version,
        );
        expect(
          retained['name'],
          version == 'incoming' ? 'Archived different name' : original!.name,
        );
      }
    },
  );
  test(
    'locked target is evidence-only and account auth cannot recreate missing profile',
    () async {
      final source = await CareRecordingFixture.create(connected: true);
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final input = await sourceFile(source.workspace);
      final current = await authorizeExisting(target, input, copyCare: false);
      final importer = service(target);
      final missing = await importer.preview(
        input,
        ImportSelection.profiles({source.person.id}),
      );
      expect(missing.people.single.outcome, ImportPersonOutcome.needsReview);
      await importer.apply(missing);
      expect(await target.db.select(target.db.profiles).get(), isEmpty);
      await target.access.requireCurrent(current);
      await target.access.revokeNetwork();
      // Different reviewed selection source produces a separate receipt.
      await (source.db.update(
        source.db.profiles,
      )..where((p) => p.id.equals(source.person.id))).write(
        const ProfilesCompanion(name: Value('Fictional changed original')),
      );
      final locked = await importer.preview(
        await sourceFile(source.workspace),
        ImportSelection.profiles({source.person.id}),
      );
      expect(locked.people.single.outcome, ImportPersonOutcome.locked);
      expect(locked.conflicts, 0);
      await importer.apply(locked);
      expect(await target.db.select(target.db.profiles).get(), isEmpty);
      expect(await target.access.contextForOwner(current.ownerUserId), isNull);
    },
  );
}
