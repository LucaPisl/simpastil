import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'setup launch lookup is read-only and resumes after person/medication saves',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final setup = SetupRepository(
        database: f.db,
        access: f.access,
        context: f.context,
      );
      expect(await setup.findUnfinishedDraft(), isNull);
      expect(await f.db.select(f.db.setupDrafts).get(), isEmpty);
      final day = CareDayRepository(
        database: f.db,
        access: f.access,
        context: f.context,
      );
      expect(
        (await day.load(localDate: '2026-09-30')).state,
        CareDayState.noPeople,
      );
      var draft = await setup.resumeOrCreateDraft();
      draft = (await setup.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Alex',
        avatar: 'A',
      )).draft;
      expect((await setup.findUnfinishedDraft())!.step, SetupStep.medication);
      expect(
        (await day.load(
          localDate: '2026-09-30',
          personId: draft.personId,
        )).state,
        CareDayState.noMedications,
      );
      draft = (await setup.saveMedication(
        draft.id,
        draft.revision,
        const MedicationReview(name: 'Fictional medicine'),
      )).draft;
      expect(
        (await setup.findUnfinishedDraft())!.medicationId,
        draft.medicationId,
      );
      expect(
        (await day.load(
          localDate: '2026-09-30',
          personId: draft.personId,
        )).state,
        CareDayState.noRoutine,
      );
    },
  );
  test('day observes exact later-due, recorded and undone entries', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    var now = DateTime.utc(2026, 9, 30, 8);
    final day = CareDayRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => now,
    );
    var view = await day.load(localDate: '2026-09-30', personId: f.person.id);
    expect(view.state, CareDayState.laterDue);
    expect(view.remainingCount, 1);
    expect(view.entries.single.occurrence.id, f.occurrence.id);
    now = DateTime.utc(2026, 9, 30, 9, 15);
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => now,
    );
    final receipt = await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    view = await day.load(localDate: '2026-09-30', personId: f.person.id);
    expect(view.state, CareDayState.recorded);
    expect(view.recordedCount, 1);
    expect(view.entries.single.head!.id, receipt.event.id);
    await service.commit(await service.prepareUndo(receipt));
    view = await day.load(localDate: '2026-09-30', personId: f.person.id);
    expect(view.state, CareDayState.pending);
    expect(view.remainingCount, 1);
    expect(view.entries.single.occurrence.id, f.occurrence.id);
    expect(view.entries.single.occurrence.stateVersion, 2);
  });
  test('pending entries show the current name, recorded keep theirs', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    var now = DateTime.utc(2026, 9, 30, 8);
    final day = CareDayRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => now,
    );
    final before = (await day.load(
      localDate: '2026-09-30',
      personId: f.person.id,
    )).entries.single;
    final recordedName = before.snapshot.pillName;
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(name: Value('Renamed')),
    );
    var entry = (await day.load(
      localDate: '2026-09-30',
      personId: f.person.id,
    )).entries.single;
    expect(entry.snapshot.pillName, 'Renamed');
    final stored = (await f.db.medicationLedgerDao.getOccurrenceById(
      f.occurrence.id,
    ))!;
    expect(stored.scheduleSnapshotJson, contains(recordedName));

    now = DateTime.utc(2026, 9, 30, 9, 15);
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => now,
    );
    await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    entry = (await day.load(
      localDate: '2026-09-30',
      personId: f.person.id,
    )).entries.single;
    expect(entry.snapshot.pillName, recordedName);
  });
  test(
    'day off reads the actual next saved dose without future writes',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final saved = await _saveWeekend(f, through: '2026-10-01');
      final before = await f.db.select(f.db.medicationOccurrences).get();
      final day = await CareDayRepository(
        database: f.db,
        access: f.access,
        context: f.context,
        clock: () => _now,
      ).load(localDate: '2026-10-01', personId: saved.personId);
      expect(day.state, CareDayState.dayOff);
      expect(day.entries, isEmpty);
      final next = day.nextDose!;
      expect(next.person.id, saved.personId);
      expect(next.pill.id, saved.pillId);
      expect(next.routineId, saved.routineId);
      expect(next.planned.localDate, '2026-10-03');
      expect(next.planned.localTime, '08:00:00');
      expect(next.planned.timeZone, 'Europe/Bucharest');
      expect(next.planned.plannedAt, DateTime.utc(2026, 10, 3, 5));
      expect(next.amount.quantityText, '1');
      expect(next.amount.unit, 'tablet');
      expect(await f.db.select(f.db.medicationOccurrences).get(), before);
      expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
    },
  );
  test('next dose follows reviewed revisions and the routine end', () async {
    final f = await ProtectedWorkspaceFixture.create();
    addTearDown(f.db.close);
    final saved = await _saveWeekend(f, through: '2026-10-01');
    final repository = RoutineRepository(
      database: f.db,
      access: f.access,
      context: f.context,
      clock: () => _now,
    );
    await repository.saveReviewed(
      await repository.preview(
        pillId: saved.pillId,
        routineId: saved.routineId,
        expectedRevision: 1,
        definition: RoutineDefinition(
          kind: RoutineKind.weekdays,
          timeZone: 'Europe/Bucharest',
          weekdays: [DateTime.sunday],
          times: [const RoutineTime(slotId: 'morning', hour: 10, minute: 0)],
          endDate: '2026-10-04',
        ),
        effectiveFrom: DateTime.utc(2026, 10, 2),
        fromLocalDate: '2026-10-01',
        throughLocalDate: '2026-10-01',
      ),
    );
    final days = CareDayRepository(
      database: f.db,
      access: f.access,
      context: f.context,
      clock: () => _now,
    );
    final next = (await days.load(
      localDate: '2026-10-01',
      personId: saved.personId,
    )).nextDose!;
    expect(next.planned.localDate, '2026-10-04');
    expect(next.planned.localTime, '10:00:00');
    expect(next.amount.isUnknown, isTrue);
    expect(
      (await days.load(
        localDate: '2026-10-05',
        personId: saved.personId,
      )).nextDose,
      isNull,
    );
  });
  test(
    'next dose skips future Taken and returns it after exact Undo',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final saved = await _saveWeekend(f, through: '2026-10-10');
      final rows = await f.db.medicationLedgerDao.getOccurrencesForUser(
        f.context.ownerUserId,
      );
      final first = rows.singleWhere((r) => r.plannedLocalDate == '2026-10-03');
      final service = CareRecordingService(
        database: f.db,
        access: f.access,
        context: f.context,
        clock: () => _now,
      );
      final taken = await service.commit(
        await service.prepare(
          personId: saved.personId,
          occurrenceId: first.id,
          expectedStateVersion: 0,
          action: MedicationAction.take,
          amount: const MedicationAmount.unknown(),
          actualAt: _now,
          actualTimeKnown: true,
        ),
      );
      final days = CareDayRepository(
        database: f.db,
        access: f.access,
        context: f.context,
        clock: () => _now,
      );
      expect(
        (await days.load(
          localDate: '2026-10-01',
          personId: saved.personId,
        )).nextDose!.planned.localDate,
        '2026-10-10',
      );
      await service.commit(await service.prepareUndo(taken));
      expect(
        (await days.load(
          localDate: '2026-10-01',
          personId: saved.personId,
        )).nextDose!.planned.localDate,
        '2026-10-03',
      );
      expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(2));
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
    },
  );
  test('next dose remains person-scoped and rejects a stale grant', () async {
    final f = await ProtectedWorkspaceFixture.create();
    addTearDown(f.db.close);
    await _saveWeekend(f, through: '2026-10-01');
    final setup = SetupRepository(
      database: f.db,
      access: f.access,
      context: f.context,
    );
    var draft = await setup.resumeOrCreateDraft(purpose: SetupPurpose.person);
    draft = (await setup.savePerson(
      draft.id,
      draft.revision,
      name: 'Casey',
      avatar: 'C',
    )).draft;
    final view = await CareDayRepository(
      database: f.db,
      access: f.access,
      context: f.context,
      clock: () => _now,
    ).load(localDate: '2026-10-01', personId: draft.personId);
    expect(view.state, CareDayState.noMedications);
    expect(view.people.single.id, draft.personId);
    expect(view.nextDose, isNull);
    final stale = WorkspaceContext(
      workspaceId: f.context.workspaceId,
      ownerUserId: f.context.ownerUserId,
      authorId: f.context.authorId,
      kind: f.context.kind,
      accessEpoch: f.context.accessEpoch + 1,
    );
    await expectLater(
      CareDayRepository(
        database: f.db,
        access: f.access,
        context: stale,
        clock: () => _now,
      ).load(localDate: '2026-10-01'),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(await f.db.select(f.db.medicationOccurrences).get(), isEmpty);
    expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
    expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
  });
  test(
    'connected next dose uses saved exact care without inventing a repeat',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final before = await f.db.select(f.db.medicationOccurrences).get();
      final queuedBefore = await f.db.select(f.db.pendingOperations).get();
      final days = CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => DateTime.utc(2026, 9, 29),
      );
      final next = (await days.load(
        localDate: '2026-09-29',
        personId: f.person.id,
      )).nextDose!;
      expect(next.person.id, f.person.id);
      expect(next.pill.id, f.pill.id);
      expect(next.routineId, isNull);
      expect(next.planned.plannedAt, f.occurrence.plannedAt);
      expect(next.planned.localDate, '2026-09-30');
      expect(next.amount.isUnknown, isTrue);
      expect(
        (await days.load(
          localDate: '2026-10-01',
          personId: f.person.id,
        )).nextDose,
        isNull,
      );
      expect(await f.db.select(f.db.medicationOccurrences).get(), before);
      expect(await f.db.select(f.db.pendingOperations).get(), queuedBefore);
    },
  );
}

final _now = DateTime.utc(2026, 10, 1, 3);

Future<({String personId, String pillId, String routineId})> _saveWeekend(
  ProtectedWorkspaceFixture f, {
  required String through,
}) async {
  final setup = SetupRepository(
    database: f.db,
    access: f.access,
    context: f.context,
  );
  var draft = await setup.resumeOrCreateDraft();
  draft = (await setup.savePerson(
    draft.id,
    draft.revision,
    name: 'Jamie',
    avatar: 'J',
  )).draft;
  draft = (await setup.saveMedication(
    draft.id,
    draft.revision,
    const MedicationReview(name: 'Example weekend'),
  )).draft;
  final repository = RoutineRepository(
    database: f.db,
    access: f.access,
    context: f.context,
    clock: () => _now,
  );
  final preview = await repository.preview(
    pillId: draft.medicationId!,
    expectedRevision: 0,
    definition: RoutineDefinition(
      kind: RoutineKind.weekdays,
      timeZone: 'Europe/Bucharest',
      weekdays: [DateTime.saturday],
      times: [const RoutineTime(slotId: 'morning', hour: 8, minute: 0)],
      amount: MedicationAmount.known('1', 'tablet'),
    ),
    effectiveFrom: _now,
    fromLocalDate: '2026-10-01',
    throughLocalDate: through,
  );
  await repository.saveReviewed(preview);
  return (
    personId: draft.personId!,
    pillId: draft.medicationId!,
    routineId: preview.routineId,
  );
}
