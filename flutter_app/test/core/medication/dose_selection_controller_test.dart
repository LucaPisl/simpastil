import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/dose_selection_controller.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'one-person selection keeps exact IDs and reports partial durable saves',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final routines = RoutineRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 8),
      );
      final old = (await routines.loadForPill(f.pill.id)).single;
      final preview = await routines.preview(
        pillId: f.pill.id,
        routineId: old.routineId,
        expectedRevision: 1,
        definition: RoutineDefinition(
          kind: RoutineKind.daily,
          timeZone: 'UTC',
          times: [
            const RoutineTime(slotId: 'morning', hour: 9, minute: 0),
            const RoutineTime(slotId: 'later', hour: 10, minute: 0),
          ],
        ),
        effectiveFrom: DateTime.utc(2026, 9, 30, 8),
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-09-30',
      );
      await routines.saveReviewed(preview);
      final rows = (await f.db.medicationLedgerDao.getOccurrencesForUser(
        f.workspace.context.ownerUserId,
      )).where((r) => r.supersededAt == null).toList();
      expect(rows, hasLength(2));
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final batch = DoseSelectionController(
        service: service,
        personId: f.person.id,
        localDate: '2026-09-30',
      );
      for (final row in rows.reversed) {
        batch.select(
          await service.prepareTakenNow(
            personId: f.person.id,
            occurrenceId: row.id,
            expectedStateVersion: 0,
          ),
        );
      }
      final originalIds = batch.selectedIds;
      await (f.db.update(f.db.medicationOccurrences)
            ..where((r) => r.id.equals(rows.first.id)))
          .write(const MedicationOccurrencesCompanion(stateVersion: Value(1)));
      final first = await batch.commit(reviewedLocalDate: '2026-09-30');
      expect(first.saved.keys, [rows.last.id]);
      expect(first.failed.keys, [rows.first.id]);
      expect(batch.selectedIds, originalIds);
      final retry = await batch.commit(reviewedLocalDate: '2026-09-30');
      expect(
        retry.saved[rows.last.id]!.event.id,
        first.saved[rows.last.id]!.event.id,
      );
      expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(1));
      await expectLater(
        batch.commit(reviewedLocalDate: '2026-10-01'),
        throwsArgumentError,
      );
    },
  );
  test('a real tomorrow entry cannot join today review', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    await RoutineRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    ).ensureMaterialized(
      fromLocalDate: '2026-10-01',
      throughLocalDate: '2026-10-01',
    );
    final tomorrow = (await f.db.medicationLedgerDao.getOccurrencesForUser(
      f.workspace.context.ownerUserId,
    )).singleWhere((r) => r.plannedLocalDate == '2026-10-01');
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );
    final intent = await service.prepareTakenNow(
      personId: f.person.id,
      occurrenceId: tomorrow.id,
      expectedStateVersion: 0,
    );
    final today = DoseSelectionController(
      service: service,
      personId: f.person.id,
      localDate: '2026-09-30',
    );
    expect(() => today.select(intent), throwsArgumentError);
    expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
  });
}
