import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'v7 upgrade and process restart preserve an optional routine review and saved medication',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-fictional-v7-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/care.db');
      var db = AppDatabase(NativeDatabase(file));
      final f = await ProtectedWorkspaceFixture.create(database: db);
      var repo = SetupRepository(
        database: db,
        access: f.access,
        context: f.context,
      );
      var draft = await repo.resumeOrCreateDraft();
      draft = (await repo.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Robin',
        avatar: 'R',
      )).draft;
      draft = (await repo.saveMedication(
        draft.id,
        draft.revision,
        const MedicationReview(name: 'Fictional saved medication'),
      )).draft;
      final routine = RoutineDefinition(
        kind: RoutineKind.interval,
        timeZone: 'Europe/Bucharest',
        everyDays: 2,
        anchorDate: '2026-09-30',
        times: [const RoutineTime(slotId: 'morning', hour: 9, minute: 0)],
      );
      draft = await repo.saveDraft(
        draft.id,
        draft.revision,
        SetupReview(
          personName: draft.review.personName,
          avatar: draft.review.avatar,
          medication: draft.review.medication,
          routine: routine,
          routineEffectiveFrom: DateTime.utc(2026, 9, 30, 8),
        ),
      );
      expect(AppDatabase.supportedSchemaVersion, 18);
      await db.customStatement('DROP TABLE device_restore_intents');
      await db.customStatement('DROP TABLE import_conflicts');
      await db.customStatement('DROP TABLE import_evidence');
      await db.customStatement('DROP TABLE import_receipts');
      await db.customStatement('DROP TABLE device_schedule_reminders');
      await db.customStatement('DROP TABLE device_reminder_settings');
      await db.customStatement('DROP TABLE care_event_details');
      await db.customStatement('DROP TABLE reviewed_stock_balances');
      await db.customStatement('DROP TABLE local_routines');
      await db.customStatement('DROP TABLE effect_settlements');
      await db.customStatement(
        'ALTER TABLE schedules DROP COLUMN time_zone_status',
      );
      await db.customStatement('ALTER TABLE schedules DROP COLUMN time_zone');
      await db.customStatement(
        'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
      );
      await db.customStatement('PRAGMA user_version=7');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      addTearDown(() => db.close());
      final access = WorkspaceAccessRepository(
        db,
        effectsGate: SerialProjectionEffectsGate(),
      );
      final context = await access.currentContext();
      expect(context.authorId, f.context.authorId);
      repo = SetupRepository(database: db, access: access, context: context);
      final resumed = await repo.resume(draft.id);
      expect(resumed.review.routine!.toJson(), routine.toJson());
      expect(resumed.review.routineEffectiveFrom, DateTime.utc(2026, 9, 30, 8));
      expect(resumed.medicationId, draft.medicationId);
      expect(await db.select(db.localRoutines).get(), isEmpty);
      await repo.advanceOrSkip(resumed.id, resumed.revision, SetupStep.ready);
      expect(
        (await db.pillsDao.getById(draft.medicationId!))!.name,
        'Fictional saved medication',
      );
    },
  );
}
