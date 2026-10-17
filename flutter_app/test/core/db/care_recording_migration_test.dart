import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'v8 upgrade retains exact routine and recorded facts without inventing historical authors',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simpastil-fictional-v8-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/care.db');
      var db = AppDatabase(NativeDatabase(file));
      final f = await ProtectedWorkspaceFixture.create(database: db);
      final setup = SetupRepository(
        database: db,
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
        const MedicationReview(name: 'Fictional medication'),
      )).draft;
      final routines = RoutineRepository(
        database: db,
        access: f.access,
        context: f.context,
        clock: () => DateTime.utc(2026, 9, 30, 8),
      );
      await routines.saveReviewed(
        await routines.preview(
          pillId: draft.medicationId!,
          expectedRevision: 0,
          definition: RoutineDefinition(
            kind: RoutineKind.daily,
            timeZone: 'Europe/Bucharest',
            times: [const RoutineTime(slotId: 'day', hour: 12, minute: 0)],
          ),
          effectiveFrom: DateTime.utc(2026, 9, 30, 8),
          fromLocalDate: '2026-09-30',
          throughLocalDate: '2026-09-30',
        ),
      );
      final occurrence = (await db.medicationLedgerDao.getOccurrencesForUser(
        f.context.ownerUserId,
      )).single;
      final care = CareRecordingService(
        database: db,
        access: f.access,
        context: f.context,
      );
      final recorded = await care.commit(
        await care.prepareTakenNow(
          personId: draft.personId!,
          occurrenceId: occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      final originalRoutine = (await db.select(db.localRoutines).get()).single;
      final originalOccurrence = (await db.medicationLedgerDao
          .getOccurrenceById(occurrence.id))!;
      await db.customStatement('DROP TABLE device_schedule_reminders');
      await db.customStatement('DROP TABLE device_reminder_settings');
      await db.customStatement('DROP TABLE care_event_details');
      await db.customStatement('DROP TABLE reviewed_stock_balances');
      await db.customStatement('DROP TABLE effect_settlements');
      await db.customStatement(
        'ALTER TABLE schedules DROP COLUMN time_zone_status',
      );
      await db.customStatement('ALTER TABLE schedules DROP COLUMN time_zone');
      await db.customStatement(
        'ALTER TABLE occurrence_events DROP COLUMN administration_amount_json',
      );
      await db.customStatement('PRAGMA user_version=8');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final access = WorkspaceAccessRepository(
        db,
        effectsGate: SerialProjectionEffectsGate(),
      );
      final context = await access.currentContext();
      expect(context.authorId, f.context.authorId);
      expect((await db.select(db.localRoutines).get()).single, originalRoutine);
      expect(
        await db.medicationLedgerDao.getOccurrenceById(occurrence.id),
        originalOccurrence,
      );
      expect(
        (await db.medicationLedgerDao.getEventsForOccurrence(
          occurrence.id,
        )).single,
        recorded.event,
      );
      expect(await db.select(db.careEventDetails).get(), isEmpty);
      final history = await CareRecordingService(
        database: db,
        access: access,
        context: context,
      ).historyForPerson(draft.personId!);
      expect(history.single.authorId, isNull);
      expect(history.single.amount.isUnknown, isTrue);
    },
  );
}
