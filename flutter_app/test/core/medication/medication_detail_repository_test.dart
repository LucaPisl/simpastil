import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_detail_repository.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/care_recording_fixture.dart';

Future<String> medication(ProtectedWorkspaceFixture f) async {
  final setup = SetupRepository(
    database: f.db,
    access: f.access,
    context: f.context,
  );
  var draft = await setup.resumeOrCreateDraft();
  draft = (await setup.savePerson(
    draft.id,
    draft.revision,
    name: 'Fictional Alex',
    avatar: 'A',
  )).draft;
  draft = (await setup.saveMedication(
    draft.id,
    draft.revision,
    const MedicationReview(
      name: 'Fictional medication',
      originalDosage: 'Original 10 mg text',
    ),
  )).draft;
  return draft.medicationId!;
}

MedicationDetailRepository repository(ProtectedWorkspaceFixture f) =>
    MedicationDetailRepository(
      database: f.db,
      access: f.access,
      context: f.context,
    );

Future<LocalRoutine> routine(ProtectedWorkspaceFixture f, String pillId) async {
  final repo = RoutineRepository(
    database: f.db,
    access: f.access,
    context: f.context,
  );
  return repo.saveReviewed(
    await repo.preview(
      pillId: pillId,
      expectedRevision: 0,
      definition: RoutineDefinition(
        kind: RoutineKind.daily,
        timeZone: 'UTC',
        times: [const RoutineTime(slotId: 'morning', hour: 8, minute: 0)],
        amount: const MedicationAmount.unknown(),
      ),
      effectiveFrom: DateTime.utc(2026, 9, 30),
      fromLocalDate: '2026-09-30',
      throughLocalDate: '2026-10-01',
    ),
  );
}

Future<T> nextWhere<T>(
  StreamIterator<T> stream,
  bool Function(T) predicate,
) async {
  while (await stream.moveNext().timeout(const Duration(seconds: 5))) {
    if (predicate(stream.current)) return stream.current;
  }
  throw StateError('Stream ended before the expected protected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'reviewed medication edit preserves actual recorded rows and facts',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final recorder = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      await recorder.commit(
        await recorder.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
          amount: MedicationAmount.known('1/2', 'tablet'),
        ),
      );
      final occurrences = await f.db.select(f.db.medicationOccurrences).get();
      final events = await f.db.select(f.db.occurrenceEvents).get();
      final facts = await f.db.select(f.db.careEventDetails).get();
      final repo = repository(f.workspace);
      final expected = await repo.load(f.pill.id);
      await repo.updateReviewed(
        expected: expected,
        review: MedicationReview(
          name: 'Fictional new name',
          amount: MedicationAmount.known('2', 'tablet'),
          packageStrength: '20 mg',
          originalDosage: expected.review.originalDosage,
        ),
      );
      expect(await f.db.select(f.db.medicationOccurrences).get(), occurrences);
      expect(await f.db.select(f.db.occurrenceEvents).get(), events);
      expect(await f.db.select(f.db.careEventDetails).get(), facts);
      expect(
        (await recorder.historyForPerson(
          f.person.id,
        )).single.amount.quantityText,
        '1/2',
      );
    },
  );

  test(
    'medication viewing follows selected person or Everyone independently of reminder eligibility',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final id = await medication(f);
      final repo = repository(f);
      final initial = await repo.load(id);
      final now = DateTime.now();
      await f.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'fictional-second-person',
          userId: f.context.ownerUserId,
          name: 'Fictional Bea',
          isActive: const Value(false),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await f.db.pillsDao.upsert(
        PillsCompanion.insert(
          id: 'fictional-second-medication',
          profileId: 'fictional-second-person',
          name: 'Fictional second medication',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await f.access.viewPerson(f.context, initial.person.id);
      final list = StreamIterator(repo.watchList());
      addTearDown(list.cancel);
      expect(
        (await nextWhere(list, (rows) => rows.length == 1)).single.pill.id,
        id,
      );
      await f.access.viewPerson(f.context, null, everyone: true);
      expect(
        (await nextWhere(
          list,
          (rows) => rows.length == 2,
        )).map((d) => d.person.id),
        unorderedEquals([initial.person.id, 'fictional-second-person']),
      );
      await f.access.viewPerson(f.context, 'fictional-second-person');
      expect(
        (await nextWhere(
          list,
          (rows) =>
              rows.length == 1 &&
              rows.single.person.id == 'fictional-second-person',
        )).single.pill.id,
        'fictional-second-medication',
      );
      expect(
        (await f.db.profilesDao.getById(initial.person.id))!.isActive,
        true,
      );
      expect(
        (await f.db.profilesDao.getById('fictional-second-person'))!.isActive,
        false,
      );
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
    },
  );

  test(
    'watched detail and list map observe reviewed metadata, person, routines and deletion',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final id = await medication(f);
      final repo = repository(f);
      final details = StreamIterator(repo.watch(id));
      final versions = StreamIterator(repo.watchRoutineVersions());
      addTearDown(details.cancel);
      addTearDown(versions.cancel);
      final initial = await nextWhere(details, (_) => true);
      expect(initial.review.originalDosage, 'Original 10 mg text');
      expect(initial.review.legacyDosageReviewed, false);
      expect(await nextWhere(versions, (_) => true), isEmpty);
      await (f.db.update(
        f.db.medicationDetails,
      )..where((r) => r.pillId.equals(id))).write(
        const MedicationDetailsCompanion(
          packageStrength: Value('20 mg'),
          form: Value('tablet'),
        ),
      );
      expect(
        (await nextWhere(
          details,
          (d) => d.review.packageStrength == '20 mg',
        )).review.form,
        'tablet',
      );
      await (f.db.update(
        f.db.profiles,
      )..where((p) => p.id.equals(initial.person.id))).write(
        const ProfilesCompanion(name: Value('Fictional renamed person')),
      );
      expect(
        (await nextWhere(
          details,
          (d) => d.person.name == 'Fictional renamed person',
        )).pill.id,
        id,
      );
      final saved = await routine(f, id);
      expect(
        (await nextWhere(
          details,
          (d) => d.routineVersions.isNotEmpty,
        )).routineVersions.single,
        saved,
      );
      expect(
        (await nextWhere(
          versions,
          (m) => m[id]?.isNotEmpty == true,
        ))[id]!.single,
        saved,
      );
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(id))).write(
        const PillsCompanion(isDeleted: Value(true)),
      );
      expect(await nextWhere(versions, (m) => m.isEmpty), isEmpty);
      await expectLater(
        details.moveNext(),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
    },
  );

  test(
    'local reviewed edit preserves legacy dosage, stock and immutable routine versions without queueing',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final id = await medication(f);
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(id))).write(
        const PillsCompanion(currentStock: Value(9), color: Value('#123456')),
      );
      final savedRoutine = await routine(f, id);
      final repo = repository(f);
      final expected = await repo.load(id);
      final save = await repo.updateReviewed(
        expected: expected,
        review: MedicationReview(
          name: 'Fictional reviewed medicine',
          packageStrength: '20 mg',
          form: 'tablet',
          notes: 'Fictional note',
          amount: MedicationAmount.known('1/2', 'tablet'),
          originalDosage: expected.review.originalDosage,
        ),
      );
      expect(save.detail.pill.name, 'Fictional reviewed medicine');
      expect(save.detail.pill.currentStock, 9);
      expect(save.detail.pill.color, '#123456');
      expect(save.detail.pill.dosage, 'Original 10 mg text');
      expect(save.detail.review.amount.quantityText, '1/2');
      expect(save.detail.review.legacyDosageReviewed, false);
      expect(save.detail.routineVersions.single, savedRoutine);
      expect(save.sharing, SetupSharingState.localOnly);
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
      expect(await f.db.select(f.db.inventoryEvents).get(), isEmpty);
    },
  );

  test('local reviewed edit writes a chosen colour without queueing', () async {
    final f = await ProtectedWorkspaceFixture.create();
    addTearDown(f.db.close);
    final id = await medication(f);
    final repo = repository(f);
    final expected = await repo.load(id);
    final save = await repo.updateReviewed(
      expected: expected,
      review: expected.review,
      color: '#64B5F6',
    );
    expect(save.detail.pill.color, '#64B5F6');
    expect((await f.db.pillsDao.getById(id))!.color, '#64B5F6');
    expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
  });

  test('stale metadata or parent preimage refuses the entire edit', () async {
    final f = await ProtectedWorkspaceFixture.create();
    addTearDown(f.db.close);
    final id = await medication(f);
    final repo = repository(f);
    final expected = await repo.load(id);
    await (f.db.update(
      f.db.medicationDetails,
    )..where((r) => r.pillId.equals(id))).write(
      const MedicationDetailsCompanion(form: Value('Fictional changed form')),
    );
    await expectLater(
      repo.updateReviewed(
        expected: expected,
        review: const MedicationReview(
          name: 'Should not save',
          originalDosage: 'Original 10 mg text',
        ),
      ),
      throwsA(isA<MedicationDetailConflict>()),
    );
    expect((await f.db.pillsDao.getById(id))!.name, 'Fictional medication');
    final afterMetadata = await repo.load(id);
    await (f.db.update(
      f.db.profiles,
    )..where((p) => p.id.equals(expected.person.id))).write(
      const ProfilesCompanion(name: Value('Different person preimage')),
    );
    await expectLater(
      repo.updateReviewed(
        expected: afterMetadata,
        review: const MedicationReview(
          name: 'Should not save',
          originalDosage: 'Original 10 mg text',
        ),
      ),
      throwsA(isA<MedicationDetailConflict>()),
    );
    expect((await f.db.pillsDao.getById(id))!.name, 'Fictional medication');
  });

  test(
    'metadata write failure rolls back the name and connected queue together',
    () async {
      final f = await ProtectedWorkspaceFixture.create(
        ownerId: 'fictional-connected',
      );
      addTearDown(f.db.close);
      final id = await medication(f);
      final repo = repository(f);
      final expected = await repo.load(id);
      final before = await f.db.select(f.db.pendingOperations).get();
      await f.db.customStatement(
        "CREATE TRIGGER fictional_metadata_failure BEFORE UPDATE ON medication_details BEGIN SELECT RAISE(ABORT, 'fictional failure'); END",
      );
      await expectLater(
        repo.updateReviewed(
          expected: expected,
          review: const MedicationReview(
            name: 'Should roll back',
            packageStrength: '20 mg',
            originalDosage: 'Original 10 mg text',
          ),
        ),
        throwsA(anything),
      );
      expect(await f.db.pillsDao.getById(id), expected.pill);
      expect(await f.db.select(f.db.pendingOperations).get(), before);
      expect((await repo.load(id)).review.packageStrength, isNull);
    },
  );

  test(
    'a connected review queues the medicine fields and its reviewed details',
    () async {
      final f = await ProtectedWorkspaceFixture.create(
        ownerId: 'fictional-connected',
      );
      addTearDown(f.db.close);
      final id = await medication(f);
      final repo = repository(f);
      final expected = await repo.load(id);
      final save = await repo.updateReviewed(
        expected: expected,
        review: MedicationReview(
          name: 'Fictional renamed',
          notes: 'Fictional note',
          packageStrength: '20 mg',
          form: 'tablet',
          amount: MedicationAmount.known('2', 'tablet'),
          originalDosage: expected.review.originalDosage,
        ),
      );
      expect(save.sharing, SetupSharingState.pending);
      expect(save.reviewedDetailsLocalOnly, false);
      final queued = (await f.db.select(f.db.pendingOperations).get())
          .where((r) => r.operationType == 'pill.update')
          .single;
      final payload = jsonDecode(queued.payloadJson) as Map;
      final wire = payload['data'] as Map;
      expect(wire['name'], 'Fictional renamed');
      expect(wire['dosage'], 'Original 10 mg text');
      expect(wire['packageStrength'], '20 mg');
      expect(wire['form'], 'tablet');
      expect(wire['amountPerUse'], {
        'version': 1,
        'state': 'known',
        'quantity': '2',
        'unit': 'tablet',
      });
      expect(wire['legacyDosageReviewed'], false);
      expect(
        wire.keys,
        unorderedEquals([
          'name',
          'dosage',
          'notes',
          'color',
          'lowStockThreshold',
          'isPrn',
          'amountPerUse',
          'packageStrength',
          'form',
          'legacyDosageReviewed',
        ]),
      );
      // A review that touches nothing but the details is still a change the
      // account has to hear about, and the medicine is unsent until it does.
      await repo.updateReviewed(
        expected: save.detail,
        review: MedicationReview(
          name: save.detail.review.name,
          notes: save.detail.review.notes,
          packageStrength: '30 mg',
          form: save.detail.review.form,
          amount: save.detail.review.amount,
          originalDosage: save.detail.review.originalDosage,
        ),
      );
      final updates = (await f.db.select(f.db.pendingOperations).get())
          .where((r) => r.operationType == 'pill.update')
          .toList();
      expect(updates, hasLength(2));
      expect(
        (jsonDecode(updates.last.payloadJson) as Map)['data']
            as Map<String, Object?>,
        containsPair('packageStrength', '30 mg'),
      );
      expect((await f.db.pillsDao.getById(id))?.syncStatus, 'pending');
    },
  );

  test(
    'revoked captured grant refuses watching and saving retained care',
    () async {
      final f = await ProtectedWorkspaceFixture.create(
        ownerId: 'fictional-connected',
      );
      addTearDown(f.db.close);
      final id = await medication(f);
      final repo = repository(f);
      final detail = await repo.load(id);
      final watched = StreamIterator(repo.watch(id));
      addTearDown(watched.cancel);
      await nextWhere(watched, (_) => true);
      await f.access.revokeNetwork();
      await expectLater(
        watched.moveNext(),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      await expectLater(
        repo.updateReviewed(
          expected: detail,
          review: const MedicationReview(
            name: 'Should not save',
            originalDosage: 'Original 10 mg text',
          ),
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(await f.db.pillsDao.getById(id), detail.pill);
    },
  );
}
