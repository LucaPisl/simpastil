import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';

import '../../helpers/protected_workspace_fixture.dart';

SetupRepository _repository(
  ProtectedWorkspaceFixture fixture, {
  Future<void> Function()? effect,
}) => SetupRepository(
  database: fixture.db,
  access: fixture.access,
  context: fixture.context,
  afterCareSave: effect,
);

Future<Profile> _person(ProtectedWorkspaceFixture f, String name) async =>
    (await ProfileRepositoryImpl(
              dao: f.db.profilesDao,
              pendingOperations: PendingOperationRepository(
                f.db,
                access: f.access,
                context: f.context,
              ),
              userId: f.context.ownerUserId,
              access: f.access,
              context: f.context,
              reconcileProjections: () async {},
            ).create(name, 'A')
            as Ok<Profile>)
        .value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an onboarding draft parked at the start step is not an unfinished setup',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      addTearDown(fixture.db.close);
      final repository = _repository(fixture);
      var draft = await repository.resumeOrCreateDraft();
      expect(draft.step, SetupStep.start);
      expect(await repository.findUnfinishedDraft(), isNull);
      draft = await repository.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.person,
      );
      expect((await repository.findUnfinishedDraft())?.id, draft.id);
      // Backing out to the start step drops it from the unfinished list again,
      // so a connected account sees its welcome rather than a stale draft.
      draft = await repository.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.start,
      );
      expect(await repository.findUnfinishedDraft(), isNull);
      final resumed = await repository.resumeOrCreateDraft();
      expect(resumed.id, draft.id);
    },
  );

  test(
    'setup resumes through durable steps with one person and medication, and defers optional work',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-setup-fictional-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/care.db';
      var db = AppDatabase(NativeDatabase(File(path)));
      final initial = await ProtectedWorkspaceFixture.create(database: db);
      final identity = initial.context;
      var repository = _repository(initial);
      Future<SetupRepository> restart() async {
        await db.close();
        db = AppDatabase(NativeDatabase(File(path)));
        final access = WorkspaceAccessRepository(
          db,
          effectsGate: SerialProjectionEffectsGate(),
        );
        final context = await access.currentContext();
        expect(context.authorId, identity.authorId);
        return SetupRepository(database: db, access: access, context: context);
      }

      addTearDown(() => db.close());
      var draft = await repository.resumeOrCreateDraft();
      repository = await restart();
      draft = await repository.resume(draft.id);
      expect(draft.step, SetupStep.start);
      draft = await repository.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.person,
      );
      draft = await repository.saveDraft(
        draft.id,
        draft.revision,
        const SetupReview(personName: 'Fictional Alex'),
      );
      repository = await restart();
      draft = await repository.resume(draft.id);
      expect(draft.review.personName, 'Fictional Alex');
      final person = await repository.savePerson(
        draft.id,
        draft.revision,
        name: draft.review.personName,
        avatar: draft.review.avatar,
      );
      repository = await restart();
      draft = await repository.resume(draft.id);
      expect(draft.personId, person.savedId);
      expect(draft.step, SetupStep.medication);
      const review = MedicationReview(
        name: 'Fictional medicine',
        packageStrength: '20 mg',
        form: 'tablet',
      );
      draft = await repository.saveDraft(
        draft.id,
        draft.revision,
        SetupReview(personName: draft.review.personName, medication: review),
      );
      repository = await restart();
      draft = await repository.resume(draft.id);
      expect(draft.review.medication.packageStrength, '20 mg');
      final saved = await repository.saveMedication(
        draft.id,
        draft.revision,
        draft.review.medication,
      );
      repository = await restart();
      draft = await repository.resume(draft.id);
      expect(draft.medicationId, saved.savedId);
      expect(draft.step, SetupStep.routine);
      expect(await db.schedulesDao.getByPillId(saved.savedId), isEmpty);
      expect(await db.select(db.inventoryEvents).get(), isEmpty);
      expect(
        await db.pendingOperationsDao.getForUser(identity.ownerUserId),
        isEmpty,
      );
      draft = await repository.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.reminders,
      );
      repository = await restart();
      draft = await repository.resume(draft.id);
      expect(draft.step, SetupStep.reminders);
      draft = await repository.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.ready,
      );
      repository = await restart();
      draft = await repository.resume(draft.id);
      expect(draft.step, SetupStep.ready);
      await repository.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.complete,
      );
      repository = await restart();
      expect((await repository.resumeOrCreateDraft()).step, SetupStep.complete);
      expect(
        await db.profilesDao.getByUserId(identity.ownerUserId),
        hasLength(1),
      );
      expect(await db.select(db.pills).get(), hasLength(1));
    },
  );

  test(
    'completed onboarding restarts after its deleted person without deleting care',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final repo = _repository(f);
      var draft = await repo.resumeOrCreateDraft();
      draft = await repo.advanceOrSkip(
        draft.id,
        draft.revision,
        SetupStep.person,
      );
      final person = await repo.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Alex',
        avatar: 'A',
      );
      final medication = await repo.saveMedication(
        person.draft.id,
        person.draft.revision,
        const MedicationReview(name: 'Fictional protected medicine'),
      );
      final ready = await repo.advanceOrSkip(
        medication.draft.id,
        medication.draft.revision,
        SetupStep.ready,
      );
      await repo.advanceOrSkip(ready.id, ready.revision, SetupStep.complete);

      await ProfileRepositoryImpl(
        dao: f.db.profilesDao,
        pendingOperations: PendingOperationRepository(
          f.db,
          access: f.access,
          context: f.context,
        ),
        userId: f.context.ownerUserId,
        access: f.access,
        context: f.context,
        reconcileProjections: () async {},
      ).delete(person.savedId);

      final restarted = await repo.resumeOrCreateDraft();

      expect(restarted.id, draft.id);
      expect(restarted.step, SetupStep.start);
      expect(restarted.personId, isNull);
      expect(restarted.medicationId, isNull);
      expect(restarted.review.personName, isEmpty);
      expect(restarted.review.medication.name, isEmpty);
      expect(restarted.revision, greaterThan(draft.revision));
      expect(
        (await f.db.profilesDao.getById(person.savedId))?.isDeleted,
        isTrue,
      );
      expect(
        (await f.db.pillsDao.getById(medication.savedId))?.isDeleted,
        isFalse,
      );
      expect(
        await (f.db.select(f.db.medicationDetails)
              ..where((row) => row.pillId.equals(medication.savedId)))
            .getSingleOrNull(),
        isNotNull,
      );
    },
  );

  test(
    'onboarding turns device reminders on for the person it saves',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final repository = _repository(f);
      final draft = await repository.resumeOrCreateDraft();
      final saved = await repository.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Alex',
        avatar: 'A',
      );
      final row = await (f.db.select(
        f.db.devicePersonReminders,
      )..where((r) => r.profileId.equals(saved.savedId))).getSingle();
      expect(row.enabled, isTrue);
    },
  );

  test('additional-person setup resumes its same saved person', () async {
    final f = await ProtectedWorkspaceFixture.create();
    addTearDown(f.db.close);
    final repository = _repository(f);
    final draft = await repository.resumeOrCreateDraft(
      purpose: SetupPurpose.person,
    );
    final saved = await repository.savePerson(
      draft.id,
      draft.revision,
      name: 'Fictional Robin',
      avatar: 'R',
    );
    final resumed = await _repository(
      f,
    ).resumeOrCreateDraft(purpose: SetupPurpose.person);
    expect(resumed.id, draft.id);
    expect(resumed.personId, saved.savedId);
    expect(resumed.step, SetupStep.medication);
    expect(
      await f.db.profilesDao.getByUserId(f.context.ownerUserId),
      hasLength(1),
    );
  });

  test(
    'person-only completion preserves care and allows a second person',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final repository = _repository(f);
      final draft = await repository.resumeOrCreateDraft(
        purpose: SetupPurpose.person,
      );
      final saved = await repository.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Alex',
        avatar: 'A',
      );
      final done = await repository.advanceOrSkip(
        draft.id,
        saved.draft.revision,
        SetupStep.complete,
      );
      expect(done.personId, saved.savedId);
      final next = await repository.resumeOrCreateDraft(
        purpose: SetupPurpose.person,
      );
      expect(next.id, isNot(draft.id));
      expect(next.personId, isNull);
      await repository.savePerson(
        next.id,
        next.revision,
        name: 'Fictional Robin',
        avatar: 'R',
      );
      expect(
        await f.db.profilesDao.getByUserId(f.context.ownerUserId),
        hasLength(2),
      );
    },
  );

  test('viewing another person does not retarget a medication draft', () async {
    final f = await ProtectedWorkspaceFixture.create();
    addTearDown(f.db.close);
    final alex = await _person(f, 'Fictional Alex');
    final robin = await _person(f, 'Fictional Robin');
    final repo = _repository(f);
    final draft = await repo.resumeOrCreateDraft(
      fixedPersonId: alex.id,
      purpose: SetupPurpose.medication,
    );
    await f.access.viewPerson(f.context, robin.id);
    final saved = await repo.saveMedication(
      draft.id,
      draft.revision,
      const MedicationReview(name: 'Fictional medicine'),
    );
    expect((await f.db.pillsDao.getById(saved.savedId))!.profileId, alex.id);
    expect((await repo.resume(saved.draft.id)).personId, alex.id);
  });

  test(
    'failed medication metadata write preserves the draft and retries once',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final person = await _person(f, 'Fictional Alex');
      final repo = _repository(f);
      var draft = await repo.resumeOrCreateDraft(
        fixedPersonId: person.id,
        purpose: SetupPurpose.medication,
      );
      const review = MedicationReview(name: 'Fictional medicine');
      draft = await repo.saveDraft(
        draft.id,
        draft.revision,
        SetupReview(personName: person.name, avatar: 'A', medication: review),
      );
      await f.db.customStatement(
        "CREATE TRIGGER fictional_metadata_failure BEFORE INSERT ON medication_details BEGIN SELECT RAISE(ABORT, 'fictional failure'); END",
      );
      await expectLater(
        repo.saveMedication(draft.id, draft.revision, review),
        throwsA(isA<Object>()),
      );
      expect(await f.db.select(f.db.pills).get(), isEmpty);
      expect((await repo.resume(draft.id)).revision, draft.revision);
      expect((await repo.resume(draft.id)).review.medication.name, review.name);
      await f.db.customStatement('DROP TRIGGER fictional_metadata_failure');
      final saved = await repo.saveMedication(draft.id, draft.revision, review);
      final replay = await repo.saveMedication(
        draft.id,
        draft.revision,
        review,
      );
      expect(replay.savedId, saved.savedId);
      expect(await f.db.select(f.db.pills).get(), hasLength(1));
      await expectLater(
        repo.saveMedication(
          draft.id,
          draft.revision,
          const MedicationReview(name: 'Different review'),
        ),
        throwsA(isA<SetupConflict>()),
      );
      expect((await f.db.pillsDao.getById(saved.savedId))!.name, review.name);
    },
  );

  test(
    'optional post-commit failure reports saved care and preserves it',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final person = await _person(f, 'Fictional Alex');
      final repo = _repository(
        f,
        effect: () async {
          expect(await f.db.select(f.db.pills).get(), hasLength(1));
          throw StateError('Fictional optional platform failure');
        },
      );
      final draft = await repo.resumeOrCreateDraft(
        fixedPersonId: person.id,
        purpose: SetupPurpose.medication,
      );
      final result = await repo.saveMedication(
        draft.id,
        draft.revision,
        const MedicationReview(name: 'Fictional medicine'),
      );
      expect(result.effects, SetupEffectState.unavailable);
      expect(result.sharing, SetupSharingState.localOnly);
      expect((await repo.resume(draft.id)).medicationId, result.savedId);
    },
  );

  test(
    'legacy dosage stays original and unreviewed, separate from package and exact amount',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final person = await _person(f, 'Fictional Alex');
      final repo = _repository(f);
      final draft = await repo.resumeOrCreateDraft(
        fixedPersonId: person.id,
        purpose: SetupPurpose.medication,
      );
      final result = await repo.saveMedication(
        draft.id,
        draft.revision,
        MedicationReview(
          name: 'Fictional medicine',
          packageStrength: '20 mg',
          form: 'tablet',
          originalDosage: 'Half after lunch (old wording)',
          amount: MedicationAmount.known('1/2', 'tablet'),
        ),
      );
      final restored = await repo.medicationReview(result.savedId);
      expect(restored.originalDosage, 'Half after lunch (old wording)');
      expect(restored.legacyDosageReviewed, isFalse);
      expect(restored.packageStrength, '20 mg');
      expect(restored.amount.numerator, BigInt.one);
      expect(restored.amount.denominator, BigInt.two);
      expect(
        (await f.db.pillsDao.getById(result.savedId))!.currentStock,
        isNull,
      );
    },
  );

  test(
    'resume refuses a saved medication moved to a different person',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final alex = await _person(f, 'Fictional Alex');
      final robin = await _person(f, 'Fictional Robin');
      final repo = _repository(f);
      final draft = await repo.resumeOrCreateDraft(
        fixedPersonId: alex.id,
        purpose: SetupPurpose.medication,
      );
      final result = await repo.saveMedication(
        draft.id,
        draft.revision,
        const MedicationReview(name: 'Fictional medicine'),
      );
      await (f.db.update(f.db.pills)..where((r) => r.id.equals(result.savedId)))
          .write(PillsCompanion(profileId: Value(robin.id)));
      await expectLater(
        repo.resume(draft.id),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(
        (await f.db.select(f.db.setupDrafts).get()).single.medicationId,
        result.savedId,
      );
    },
  );

  test(
    'connected medication carries its reviewed details in the create payload',
    () async {
      final f = await ProtectedWorkspaceFixture.create(
        ownerId: 'fictional-connected',
      );
      addTearDown(f.db.close);
      final person = await _person(f, 'Fictional Alex');
      final repo = _repository(f);
      final draft = await repo.resumeOrCreateDraft(
        fixedPersonId: person.id,
        purpose: SetupPurpose.medication,
      );
      final result = await repo.saveMedication(
        draft.id,
        draft.revision,
        const MedicationReview(
          name: 'Fictional medicine',
          packageStrength: '20 mg',
        ),
      );
      expect(result.sharing, SetupSharingState.pending);
      final queue = await f.db.pendingOperationsDao.getForUser(
        f.context.ownerUserId,
      );
      expect(
        queue.where((r) => r.operationType == 'pill.create'),
        hasLength(1),
      );
      expect(
        queue.where(
          (r) =>
              r.operationType.startsWith('inventory.') ||
              r.operationType == 'schedule.create',
        ),
        isEmpty,
      );
      // The reviewed details belong to the account, so they are queued with the
      // medicine. Leaving them out of the request against a server that cannot
      // store them is the adapter's job, not the queue's.
      final data =
          (jsonDecode(
                    queue
                        .singleWhere((r) => r.operationType == 'pill.create')
                        .payloadJson,
                  )
                  as Map)['data']
              as Map;
      expect(data['packageStrength'], '20 mg');
      expect(data['form'], isNull);
      expect(data['amountPerUse'], isNull);
      expect(data['legacyDosageReviewed'], isFalse);
    },
  );
}
