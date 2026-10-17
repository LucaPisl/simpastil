import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'protected_workspace_fixture.dart';

class CareRecordingFixture {
  const CareRecordingFixture(
    this.workspace,
    this.pill,
    this.person,
    this.occurrence,
  );
  final ProtectedWorkspaceFixture workspace;
  AppDatabase get db => workspace.db;
  final Pill pill;
  final Profile person;
  final MedicationOccurrence occurrence;
  static final planned = DateTime.utc(2026, 9, 30, 9);
  static Future<CareRecordingFixture> create({
    bool connected = false,
    String routineTimeZone = 'UTC',
    int routineHour = 9,
    DateTime? routineEffectiveFrom,
    int? legacyStock,
    MedicationAmount routineAmount = const MedicationAmount.unknown(),
    WorkspaceAccessRepository Function(AppDatabase)? accessFactory,
    SharedPreferences? preferences,
  }) async {
    final f = await ProtectedWorkspaceFixture.create(
      accessFactory: accessFactory,
      ownerId: connected ? '10000000-0000-4000-8000-000000000001' : null,
      preferences: preferences,
    );
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
      const MedicationReview(name: 'Fictional recorded medication'),
    )).draft;
    final pillId = draft.medicationId!;
    final person = (await f.db.profilesDao.getById(draft.personId!))!;
    if (legacyStock != null) {
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(pillId))).write(
        PillsCompanion(currentStock: Value(legacyStock)),
      );
    }
    final pill = (await f.db.pillsDao.getById(pillId))!;
    if (connected) {
      const scheduleId = '10000000-0000-4000-8000-000000000002';
      const occurrenceId = '10000000-0000-4000-8000-000000000003';
      await f.db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: scheduleId,
          pillId: pillId,
          hour: 9,
          minute: 0,
          frequency: 'daily',
          createdAt: planned,
          updatedAt: planned,
        ),
      );
      await f.db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: occurrenceId,
          userId: f.context.ownerUserId,
          pillId: Value(pillId),
          scheduleId: const Value(scheduleId),
          occurrenceKey: 'scheduled:v1:fictional-exact-care',
          source: 'scheduled',
          scheduleRevision: const Value(1),
          plannedLocalDate: '2026-09-30',
          plannedLocalTime: const Value('09:00:00'),
          timeZone: 'UTC',
          plannedAt: Value(planned),
          expected: const Value(true),
          provenance: 'exact',
          scheduleSnapshotJson: jsonEncode(
            ScheduleSnapshotV1(
              pillName: pill.name,
              dosage: pill.dosage,
              frequency: 'daily',
              frequencyDays: null,
              hour: 9,
              minute: 0,
              timeZone: 'UTC',
              profileId: person.id,
              profileName: person.name,
            ).toJson(),
          ),
          createdAt: planned,
          updatedAt: planned,
        ),
      );
    } else {
      final effectiveFrom =
          routineEffectiveFrom ?? DateTime.utc(2026, 9, 30, 8);
      final repo = RoutineRepository(
        database: f.db,
        access: f.access,
        context: f.context,
        clock: () => effectiveFrom,
      );
      final review = await repo.preview(
        pillId: pillId,
        expectedRevision: 0,
        definition: RoutineDefinition(
          kind: RoutineKind.daily,
          timeZone: routineTimeZone,
          amount: routineAmount,
          times: [RoutineTime(slotId: 'morning', hour: routineHour, minute: 0)],
        ),
        effectiveFrom: effectiveFrom,
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-09-30',
      );
      await repo.saveReviewed(review);
    }
    final occurrence = (await f.db.medicationLedgerDao.getOccurrencesForUser(
      f.context.ownerUserId,
    )).single;
    return CareRecordingFixture(f, pill, person, occurrence);
  }
}

/// Test shortcut for what the automatic sweep writes: a `miss` event on a
/// pending occurrence, through the same repository path as any other action.
extension CareRecordingMiss on CareRecordingFixture {
  Future<MedicationCommand> recordMiss({String? occurrenceId}) =>
      MedicationRepository(
        db,
        access: workspace.access,
        context: workspace.context,
      ).apply(
        userId: workspace.context.ownerUserId,
        occurrenceId: occurrenceId ?? occurrence.id,
        action: MedicationAction.miss,
        actualTimeKnown: false,
        expectedStateVersion: 0,
      );
}
