import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_inventory.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/db/daos/import_dao.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/protected_workspace_fixture.dart';

Future<CheckedBackup> checked(
  CareRecordingFixture source, {
  int schema = 10,
}) async => CheckedBackup(
  BackupDocument(
    id: 'fictional-original-backup',
    capturedAt: DateTime.utc(2026, 10, 1),
    sourceSchema: schema,
    scope: BackupScope.full,
    tables: {
      for (final name in BackupInventory.portableTableNamesFor(schema))
        name:
            (await source.db
                    .customSelect(
                      'SELECT ${BackupInventory.portableColumns(name, schema: schema).map((c) => '"$c"').join(',')} FROM "$name"',
                    )
                    .get())
                .map((r) => r.data)
                .toList(),
    },
    preferences: {'app_locale': 'ro'},
  ),
  const BackupFileLocation('fictional-chosen-source', 'Care.simpbak'),
  DateTime.utc(2026, 10, 1),
  passwordProtected: true,
);

Future<String> facts(AppDatabase db) async => jsonEncode({
  for (final table in db.allTables)
    table.actualTableName:
        (await db
                .customSelect(
                  'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
                )
                .get())
            .map((r) => r.data)
            .toList(),
});

ImportService importer(ProtectedWorkspaceFixture target) => ImportService(
  database: target.db,
  access: target.access,
  preferences: target.preferences,
  context: target.context,
);

void main() {
  setUp(tz.initializeTimeZones);
  test(
    'one conflicting person keeps the author required by another imported person',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final service = importer(target);
      await service.apply(
        await service.preview(
          await checked(source),
          ImportSelection.profiles({source.person.id}),
        ),
      );
      // Reproduce an older target with person A but no still-unused author.
      // No current target author is removed.
      await target.db.customStatement('DELETE FROM local_routines');
      await target.db.customStatement('DELETE FROM medication_occurrences');
      await target.db.customStatement(
        'DELETE FROM workspace_authors WHERE id=?',
        [source.workspace.context.authorId],
      );
      await (source.db.update(
        source.db.profiles,
      )..where((r) => r.id.equals(source.person.id))).write(
        const ProfilesCompanion(name: Value('Conflicting incoming A')),
      );
      final setup = SetupRepository(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
      );
      var draft = await setup.resumeOrCreateDraft(purpose: SetupPurpose.person);
      draft = (await setup.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional B',
        avatar: 'B',
      )).draft;
      draft = (await setup.saveMedication(
        draft.id,
        draft.revision,
        const MedicationReview(name: 'Fictional B medication'),
      )).draft;
      final originalCare = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      // Existing accepted local-v2 snapshot copied for a deliberately distinct B
      // fixture; its exact source author is recorded by the real care service.
      final sourceOccurrence = source.occurrence;
      final snapshot =
          jsonDecode(sourceOccurrence.scheduleSnapshotJson)
              as Map<String, dynamic>;
      snapshot['profileId'] = draft.personId;
      snapshot['profileName'] = 'Fictional B';
      snapshot['pillName'] = 'Fictional B medication';
      await source.db
          .into(source.db.medicationOccurrences)
          .insert(
            MedicationOccurrencesCompanion.insert(
              id: 'fictional-b-occurrence',
              userId: source.workspace.context.ownerUserId,
              pillId: Value(draft.medicationId!),
              occurrenceKey: 'fictional-b-identity',
              source: 'prn',
              plannedLocalDate: '2026-09-30',
              timeZone: 'UTC',
              snapshotVersion: const Value(2),
              scheduleSnapshotJson: jsonEncode(snapshot),
              provenance: 'exact',
              createdAt: DateTime.utc(2026, 9, 30),
              updatedAt: DateTime.utc(2026, 9, 30),
            ),
          );
      await originalCare.commit(
        await originalCare.prepareTakenNow(
          personId: draft.personId!,
          occurrenceId: 'fictional-b-occurrence',
          expectedStateVersion: 0,
        ),
      );
      final review = await service.preview(
        await checked(source),
        ImportSelection.profiles({source.person.id, draft.personId!}),
      );
      expect(
        review.people.firstWhere((p) => p.id == source.person.id).outcome,
        ImportPersonOutcome.needsReview,
      );
      expect(
        review.people.firstWhere((p) => p.id == draft.personId).outcome,
        ImportPersonOutcome.added,
      );
      await service.apply(review);
      expect(
        (await target.db.select(target.db.workspaceAuthors).get()).map(
          (a) => a.id,
        ),
        contains(source.workspace.context.authorId),
      );
      final audit = await CareRecordingService(
        database: target.db,
        access: target.access,
        context: target.context,
      ).historyForPerson(draft.personId!);
      expect(audit.single.authorId, source.workspace.context.authorId);
      expect(
        (await target.db.profilesDao.getById(source.person.id))!.name,
        source.person.name,
      );
    },
  );
  test(
    'moved captured history does not interrupt Today when both people are imported',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final care = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      await care.commit(
        await care.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      await source.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'fictional-current-person-b',
          userId: source.workspace.context.ownerUserId,
          name: 'Fictional current B',
          createdAt: DateTime.utc(2026, 9, 30),
          updatedAt: DateTime.utc(2026, 9, 30),
        ),
      );
      await (source.db.update(
        source.db.pills,
      )..where((p) => p.id.equals(source.pill.id))).write(
        const PillsCompanion(profileId: Value('fictional-current-person-b')),
      );
      // The original guard still refuses an arbitrary live parent mismatch.
      await expectLater(
        CareDayRepository(
          database: source.db,
          access: source.workspace.access,
          context: source.workspace.context,
          clock: () => DateTime.utc(2026, 9, 30, 10),
        ).load(localDate: '2026-09-30'),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      final service = importer(target);
      final review = await service.preview(
        await checked(source),
        ImportSelection.profiles({
          source.person.id,
          'fictional-current-person-b',
        }),
      );
      expect(
        review.people
            .firstWhere((p) => p.id == source.person.id)
            .detachedHistoryRows,
        1,
      );
      await service.apply(review);
      final day = await CareDayRepository(
        database: target.db,
        access: target.access,
        context: target.context,
        clock: () => DateTime.utc(2026, 9, 30, 10),
      ).load(localDate: '2026-09-30');
      expect(
        day.people.map((p) => p.id),
        containsAll([source.person.id, 'fictional-current-person-b']),
      );
      expect(
        day.entries.where((e) => e.occurrence.id == source.occurrence.id),
        isEmpty,
      );
      final detail = await OccurrenceDetailRepository(
        database: target.db,
        access: target.access,
        context: target.context,
      ).load(source.occurrence.id);
      expect(detail.personId, source.person.id);
      expect(detail.canRecord, isFalse);
      expect(detail.canUndo, isFalse);
    },
  );

  test(
    'a moved medication retains the captured person history read-only',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final care = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      final taken = await care.commit(
        await care.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      // Retained legacy stock fact linked to the actual captured care event.
      await source.db
          .into(source.db.inventoryEvents)
          .insert(
            InventoryEventsCompanion.insert(
              id: 'fictional-linked-stock-fact',
              userId: source.workspace.context.ownerUserId,
              pillId: source.pill.id,
              commandId: taken.event.commandId,
              kind: 'dose',
              delta: '-1',
              occurrenceEventId: Value(taken.event.id),
              origin: 'legacy_handoff',
              recordedAt: taken.event.recordedAt,
            ),
          );
      await source.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'fictional-current-person-b',
          userId: source.workspace.context.ownerUserId,
          name: 'Fictional current B',
          createdAt: DateTime.utc(2026, 9, 30),
          updatedAt: DateTime.utc(2026, 9, 30),
        ),
      );
      await (source.db.update(
        source.db.pills,
      )..where((p) => p.id.equals(source.pill.id))).write(
        const PillsCompanion(profileId: Value('fictional-current-person-b')),
      );
      final service = importer(target);
      await service.apply(
        await service.preview(
          await checked(source),
          ImportSelection.profiles({source.person.id}),
        ),
      );
      final detail = await OccurrenceDetailRepository(
        database: target.db,
        access: target.access,
        context: target.context,
      ).load(source.occurrence.id);
      expect(detail.personId, source.person.id);
      expect(detail.personName, source.person.name);
      expect(detail.head!.event.id, taken.event.id);
      expect(detail.head!.authorId, source.workspace.context.authorId);
      expect(detail.canRecord, isFalse);
      expect(detail.canUndo, isFalse);
      expect(await target.db.pillsDao.getById(source.pill.id), isNull);
      expect(
        await target.db.profilesDao.getById('fictional-current-person-b'),
        isNull,
      );
      final receipt = (await ImportDao(
        target.db,
      ).receipts(target.context.workspaceId)).single;
      final stock = await ImportDao(target.db).originalRow(
        receiptId: receipt.id,
        table: 'inventory_events',
        key: jsonEncode(['fictional-linked-stock-fact']),
      );
      expect(stock['occurrence_event_id'], taken.event.id);
      expect(stock['user_id'], source.workspace.context.ownerUserId);
      expect(stock['delta'], '-1');
      expect(await target.db.select(target.db.inventoryEvents).get(), isEmpty);
    },
  );
  test(
    'a schema 20 backup with integer deltas and no stock columns imports as text',
    () async {
      final source = await CareRecordingFixture.create(legacyStock: 5);
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final care = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      final taken = await care.commit(
        await care.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      await source.db
          .into(source.db.inventoryEvents)
          .insert(
            InventoryEventsCompanion.insert(
              id: 'fictional-schema20-stock-fact',
              userId: source.workspace.context.ownerUserId,
              pillId: source.pill.id,
              commandId: taken.event.commandId,
              kind: 'dose',
              delta: '-1',
              occurrenceEventId: Value(taken.event.id),
              origin: 'legacy_handoff',
              recordedAt: taken.event.recordedAt,
            ),
          );
      final live = await checked(source, schema: 20);
      // What a 1.1 phone wrote: an integer delta, and pills with no exact
      // stock columns at all.
      final json = live.document.toJson();
      final tables = json['tables'] as Map<String, dynamic>;
      for (final row in tables['inventory_events'] as List) {
        (row as Map<String, dynamic>)['delta'] = -1;
      }
      for (final row in tables['pills'] as List) {
        expect((row as Map).containsKey('stock_quantity'), isFalse);
        expect(row.containsKey('stock_unit'), isFalse);
      }
      final document = BackupDocument.fromJson(json);
      final old = CheckedBackup(
        document,
        live.location,
        live.checkedAt,
        passwordProtected: true,
      );
      final deltas = (document.tables['inventory_events'] as List)
          .map((r) => (r as Map)['delta'])
          .toSet();
      expect(deltas, {'-1'});
      final service = importer(target);
      await service.apply(
        await service.preview(
          old,
          ImportSelection.profiles({source.person.id}),
        ),
      );
      final receipt = (await ImportDao(
        target.db,
      ).receipts(target.context.workspaceId)).single;
      final stock = await ImportDao(target.db).originalRow(
        receiptId: receipt.id,
        table: 'inventory_events',
        key: jsonEncode(['fictional-schema20-stock-fact']),
      );
      expect(stock['delta'], '-1');
    },
  );
  test(
    'import receipts and preserved evidence have protected schema storage',
    () async {
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      expect(db.schemaVersion, 25);
      final tables =
          (await db
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type='table'",
                  )
                  .get())
              .map((row) => row.read<String>('name'))
              .toSet();
      expect(
        tables,
        containsAll([
          'import_receipts',
          'import_evidence',
          'import_conflicts',
          'device_restore_intents',
          'effect_settlements',
        ]),
      );
    },
  );

  test(
    'preview changes nothing; same names retain distinct stable identities and retry adds nothing',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await CareRecordingFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final input = await checked(source), service = importer(target.workspace);
      final before = await facts(target.db);
      final plan = await service.preview(
        input,
        ImportSelection.profiles({source.person.id}),
      );
      expect(await facts(target.db), before);
      expect(plan.people.single.id, source.person.id);
      expect(plan.people.single.name, target.person.name);
      expect(plan.additions, greaterThan(0));
      expect(plan.people.single.outcome, ImportPersonOutcome.added);
      expect(
        plan.ownershipTranslations.single.sourceOwnerId,
        source.workspace.context.ownerUserId,
      );
      expect(
        plan.ownershipTranslations.single.targetOwnerId,
        target.workspace.context.ownerUserId,
      );
      expect(() => plan.people.clear(), throwsUnsupportedError);
      expect(() => plan.ownershipTranslations.clear(), throwsUnsupportedError);
      expect(plan.preservation.exactOriginalsRetained, isTrue);
      expect(plan.preservation.historicalAuthorshipRetained, isTrue);
      expect(plan.preservation.pendingWorkIsolated, isTrue);
      expect(plan.preservation.targetAuthorPreserved, isTrue);
      expect(plan.preservation.targetPreferencesPreserved, isTrue);
      await service.apply(plan);
      expect(
        (await target.db.select(target.db.profiles).get()).map((p) => p.id),
        unorderedEquals([source.person.id, target.person.id]),
      );
      expect(
        (await target.workspace.access.currentContext()).authorId,
        target.workspace.context.authorId,
      );
      expect(target.workspace.preferences.getString('app_locale'), isNull);
      final applied = await facts(target.db);
      final repeated = await service.preview(
        input,
        ImportSelection.profiles({source.person.id}),
      );
      expect((await service.apply(repeated)).alreadyApplied, isTrue);
      expect(await facts(target.db), applied);
    },
  );

  test(
    'future imported routine retains occurrences; historical author survives new recording and Undo',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final originalCare = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      final old = await originalCare.commit(
        await originalCare.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      await originalCare.commit(await originalCare.prepareUndo(old));
      await RoutineRepository(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 8),
      ).ensureMaterialized(
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-10-01',
      );
      final originalIds =
          (await source.db.select(source.db.medicationOccurrences).get())
              .map((r) => r.id)
              .toSet();
      final input = await checked(source), service = importer(target);
      await service.apply(
        await service.preview(
          input,
          ImportSelection.profiles({source.person.id}),
        ),
      );
      final routines = RoutineRepository(
        database: target.db,
        access: target.access,
        context: target.context,
        clock: () => DateTime.utc(2026, 9, 30, 8),
      );
      await routines.ensureMaterialized(
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-10-01',
      );
      expect(
        (await target.db.select(target.db.medicationOccurrences).get()).map(
          (r) => r.id,
        ),
        unorderedEquals(originalIds),
      );
      final care = CareRecordingService(
        database: target.db,
        access: target.access,
        context: target.context,
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
      final undone = await care.commit(await care.prepareUndo(taken));
      expect(undone.current.state, 'pending');
      expect(
        (await care.historyForPerson(source.person.id)).map((f) => f.authorId),
        [
          source.workspace.context.authorId,
          source.workspace.context.authorId,
          target.context.authorId,
          target.context.authorId,
        ],
      );
      final receipt = (await ImportDao(
        target.db,
      ).receipts(target.context.workspaceId)).single;
      final original = await ImportDao(target.db).originalRow(
        receiptId: receipt.id,
        table: 'medication_occurrences',
        key: jsonEncode([source.occurrence.id]),
      );
      expect(
        original['schedule_snapshot_json'],
        source.occurrence.scheduleSnapshotJson,
      );
      expect(original['user_id'], source.workspace.context.ownerUserId);
    },
  );

  test(
    'selected import review exposes read-only local versus incoming dose states',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final service = importer(target);
      final selection = ImportSelection.profiles({source.person.id});
      await service.apply(
        await service.preview(await checked(source), selection),
      );

      final localCare = CareRecordingService(
        database: target.db,
        access: target.access,
        context: target.context,
      );
      await localCare.commit(
        await localCare.prepare(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
          action: MedicationAction.skip,
          amount: const MedicationAmount.unknown(),
          actualAt: null,
          actualTimeKnown: false,
        ),
      );
      final importedCare = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9, 10),
      );
      await importedCare.commit(
        await importedCare.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );

      final plan = await service.preview(await checked(source), selection);
      expect(plan.conflicts, greaterThan(0));
      expect(plan.doseConflicts, hasLength(1));
      final conflict = plan.doseConflicts.single;
      expect(conflict.local.personName, 'Fictional Alex');
      expect(conflict.local.medicationName, 'Fictional recorded medication');
      expect(conflict.local.localDate, '2026-09-30');
      expect(conflict.local.localTime, '09:00:00');
      expect(conflict.local.state, ImportDoseState.skipped);
      expect(conflict.imported.personName, 'Fictional Alex');
      expect(conflict.imported.medicationName, 'Fictional recorded medication');
      expect(conflict.imported.localDate, '2026-09-30');
      expect(conflict.imported.localTime, '09:00:00');
      expect(conflict.imported.state, ImportDoseState.taken);
      expect(
        (await target.db.medicationLedgerDao.getOccurrenceById(
          source.occurrence.id,
        ))!.state,
        'skipped',
      );
    },
  );

  test(
    'divergent same identity preserves existing care and retains incoming dependent graph',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final service = importer(target);
      final selection = ImportSelection.profiles({source.person.id});
      await service.apply(
        await service.preview(await checked(source), selection),
      );
      await (source.db.update(
        source.db.profiles,
      )..where((r) => r.id.equals(source.person.id))).write(
        const ProfilesCompanion(name: Value('Incoming competing name')),
      );
      await (source.db.update(source.db.pills)
            ..where((r) => r.id.equals(source.pill.id)))
          .write(const PillsCompanion(notes: Value('Incoming competing care')));
      final currentPerson = await target.db.profilesDao.getById(
        source.person.id,
      );
      final currentPill = await target.db.pillsDao.getById(source.pill.id);
      final plan = await service.preview(await checked(source), selection);
      // A v14 schedule carries the reviewed zone status as an additional
      // conflict dimension; the profile and pill conflicts remain required.
      expect(plan.conflicts, greaterThanOrEqualTo(2));
      expect(plan.additions, 0);
      await service.apply(plan);
      expect(
        await target.db.profilesDao.getById(source.person.id),
        currentPerson,
      );
      expect(await target.db.pillsDao.getById(source.pill.id), currentPill);
      expect(
        await target.db.select(target.db.importConflicts).get(),
        hasLength(greaterThanOrEqualTo(2)),
      );
      expect(
        (await target.db.select(target.db.importEvidence).get()).where(
          (r) => r.disposition == 'conflict' && r.version == 'incoming',
        ),
        isNotEmpty,
      );
    },
  );

  for (final (schema, kept) in [(20, 'oval'), (19, null)]) {
    test(
      'a schema $schema backup ${kept == null ? 'without' : 'with'} a pill shape imports '
      'the shape as ${kept ?? 'unset'}',
      () async {
        final source = await CareRecordingFixture.create();
        final target = await ProtectedWorkspaceFixture.create();
        addTearDown(source.db.close);
        addTearDown(target.db.close);
        await (source.db.update(source.db.pills)
              ..where((p) => p.id.equals(source.pill.id)))
            .write(const PillsCompanion(shape: Value('oval')));
        final input = await checked(source, schema: schema);
        expect(
          input.document.tables['pills']!.single.containsKey('shape'),
          schema >= 20,
        );
        final service = importer(target);
        await service.apply(
          await service.preview(
            input,
            ImportSelection.profiles({source.person.id}),
          ),
        );
        final imported = await target.db.pillsDao.getById(source.pill.id);
        expect(imported, isNotNull);
        expect(imported!.shape, kept);
      },
    );
  }

  for (final sourceSchema in [12, 13, 14]) {
    test(
      'schema$sourceSchema imported bridge staging remains evidence without live authority',
      () async {
        final source = await CareRecordingFixture.create();
        final target = await ProtectedWorkspaceFixture.create();
        addTearDown(source.db.close);
        addTearDown(target.db.close);
        final now = DateTime.utc(2026, 9, 30);
        await source.db
            .into(source.db.pendingOperations)
            .insert(
              PendingOperationsCompanion.insert(
                id: 'original-operation',
                userId: source.workspace.context.ownerUserId,
                mutationId: 'original-mutation',
                component: 'medicationBridge',
                operationType: 'legacyBatch',
                contractVersion: 1,
                payloadJson: '{"original":true}',
                state: const Value('sending'),
                createdAt: now,
              ),
            );
        await source.db
            .into(source.db.pendingOperationEffects)
            .insert(
              PendingOperationEffectsCompanion.insert(
                id: 'original-effect',
                operationId: 'original-operation',
                ordinal: 0,
                kind: 'inventory',
                legacySourceId: Value(source.pill.id),
                requestFingerprint: 'original-request',
                state: const Value('uncertain'),
                attemptedAt: Value(now),
              ),
            );
        await source.db
            .into(source.db.syncStagingRuns)
            .insert(
              SyncStagingRunsCompanion.insert(
                id: 'original-stage',
                userId: source.workspace.context.ownerUserId,
                component: 'medicationBridge',
                contractVersion: sourceSchema == 12
                    ? 3
                    : sourceSchema == 13
                    ? 4
                    : 5,
                afterSequence: '0',
                throughSequence: '4',
                nextCursor: const Value('original-untrusted-cursor'),
                startedAt: now,
              ),
            );
        await source.db
            .into(source.db.syncStagingItems)
            .insert(
              SyncStagingItemsCompanion.insert(
                runId: 'original-stage',
                serverSequence: 4,
                entityType: 'profile',
                entityId: source.person.id,
                payloadJson: '{"original":"unmerged"}',
              ),
            );
        final input = await checked(source, schema: sourceSchema);
        expect(input.document.sourceSchema, sourceSchema);
        expect(
          input
              .document
              .tables['sync_staging_runs']!
              .single['contract_version'],
          sourceSchema == 12
              ? 3
              : sourceSchema == 13
              ? 4
              : 5,
        );
        final service = importer(target);
        await service.apply(
          await service.preview(
            input,
            ImportSelection.profiles({source.person.id}),
          ),
        );
        final before = await facts(target.db);
        await target.db.pendingOperationsDao.recoverInterruptedOperations();
        await target.db.pendingOperationsDao.recoverInterruptedEffects();
        await target.db.syncStateDao.discardRun('original-stage');
        expect(
          await target.db.select(target.db.pendingOperations).get(),
          isEmpty,
        );
        expect(
          await target.db.select(target.db.pendingOperationEffects).get(),
          isEmpty,
        );
        expect(
          await target.db.select(target.db.syncStagingRuns).get(),
          isEmpty,
        );
        expect(await facts(target.db), before);
        expect(
          (await target.db.select(target.db.importEvidence).get()).map(
            (r) => r.entityTable,
          ),
          containsAll([
            'pending_operations',
            'pending_operation_effects',
            'sync_staging_runs',
            'sync_staging_items',
          ]),
        );
      },
    );
  }

  test(
    'changed target and failed commit preserve the exact existing collection',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await CareRecordingFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final input = await checked(source), service = importer(target.workspace);
      final selection = ImportSelection.profiles({source.person.id});
      final stale = await service.preview(input, selection);
      await (target.db.update(target.db.profiles)
            ..where((r) => r.id.equals(target.person.id)))
          .write(const ProfilesCompanion(name: Value('Later target edit')));
      final changed = await facts(target.db);
      await expectLater(
        service.apply(stale),
        throwsA(
          isA<ImportFailure>().having(
            (f) => f.code,
            'code',
            ImportFailureCode.staleTarget,
          ),
        ),
      );
      expect(await facts(target.db), changed);
      final failing = ImportService(
        database: target.db,
        access: target.workspace.access,
        preferences: target.workspace.preferences,
        context: target.workspace.context,
        beforeCommit: () async =>
            throw StateError('fictional interrupted write'),
      );
      await expectLater(
        failing.apply(await failing.preview(input, selection)),
        throwsA(
          isA<ImportFailure>().having(
            (f) => f.code,
            'code',
            ImportFailureCode.commitFailed,
          ),
        ),
      );
      expect(await facts(target.db), changed);
      final revoked = await service.preview(input, selection);
      await target.db.customStatement(
        'UPDATE workspace_grants SET epoch=epoch+1',
      );
      final locked = await facts(target.db);
      await expectLater(
        service.apply(revoked),
        throwsA(
          isA<ImportFailure>().having(
            (f) => f.code,
            'code',
            ImportFailureCode.staleAccess,
          ),
        ),
      );
      expect(await facts(target.db), locked);
    },
  );

  test(
    'proven deleted-parent uncertainty is retained without inventing a person or live dose',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final now = DateTime.utc(2026, 9, 29);
      await source.db
          .into(source.db.doseLogs)
          .insert(
            DoseLogsCompanion.insert(
              id: 'original-orphan-dose',
              scheduleId: 'deleted-original-schedule',
              scheduledAt: now,
              status: 'taken',
              note: const Value('Original known legacy text'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await source.db
          .into(source.db.migrationIssues)
          .insert(
            MigrationIssuesCompanion.insert(
              id: 'original-orphan-proof',
              userId: source.workspace.context.ownerUserId,
              entityType: 'dose_log',
              entityId: 'original-orphan-dose',
              issueCode: 'original_parent_deleted',
              snapshotJson: '{"original":"uncertain person"}',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final service = importer(target);
      await service.apply(
        await service.preview(
          await checked(source),
          ImportSelection.profiles({source.person.id}),
        ),
      );
      final receipt = (await ImportDao(
        target.db,
      ).receipts(target.context.workspaceId)).single;
      final original = await ImportDao(target.db).originalRow(
        receiptId: receipt.id,
        table: 'dose_logs',
        key: '["original-orphan-dose"]',
      );
      expect(original['note'], 'Original known legacy text');
      expect(original['schedule_id'], 'deleted-original-schedule');
      expect(await target.db.select(target.db.doseLogs).get(), isEmpty);
    },
  );
}
