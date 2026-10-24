import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/daos/medication_ledger_dao.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/dashboard/history_entry_mapper.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'past unrecorded and Undo history expose the factual pending state',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final initial = historyEntryFromOccurrenceRecord(
        MedicationOccurrenceRecord(occurrence: f.occurrence, events: const []),
        now: DateTime.utc(2026, 10, 1),
      );
      expect(initial.recordedState, 'pending');
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final saved = await writer.commit(
        await writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      await writer.commit(await writer.prepareUndo(saved));
      final undone = historyEntryFromOccurrenceRecord(
        MedicationOccurrenceRecord(
          occurrence: (await f.db.medicationLedgerDao.getOccurrenceById(
            f.occurrence.id,
          ))!,
          events: await f.db.medicationLedgerDao.getEventsForOccurrence(
            f.occurrence.id,
          ),
        ),
        now: DateTime.utc(2026, 10, 1),
      );
      expect(undone.recordedState, 'pending');
      expect(undone.auditEvents, hasLength(2));
    },
  );

  test(
    'a pending dose shows the current name, a recorded one keeps its own',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final now = DateTime.utc(2026, 10, 1);
      final recordedName = historyEntryFromOccurrenceRecord(
        MedicationOccurrenceRecord(occurrence: f.occurrence, events: const []),
        now: now,
      ).pillName;
      final names = {f.pill.id: 'Renamed'};
      expect(
        historyEntryFromOccurrenceRecord(
          MedicationOccurrenceRecord(
            occurrence: f.occurrence,
            events: const [],
          ),
          now: now,
          pillNamesById: names,
        ).pillName,
        'Renamed',
      );
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      await writer.commit(
        await writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      final taken = historyEntryFromOccurrenceRecord(
        MedicationOccurrenceRecord(
          occurrence: (await f.db.medicationLedgerDao.getOccurrenceById(
            f.occurrence.id,
          ))!,
          events: await f.db.medicationLedgerDao.getEventsForOccurrence(
            f.occurrence.id,
          ),
        ),
        now: now,
        pillNamesById: names,
      );
      expect(taken.pillName, recordedName);
    },
  );

  test(
    'a row knows its medication and the amount the routine planned',
    () async {
      final f = await CareRecordingFixture.create(
        routineAmount: MedicationAmount.known('1/2', 'tablet'),
      );
      addTearDown(f.db.close);
      final entry = historyEntryFromOccurrenceRecord(
        MedicationOccurrenceRecord(occurrence: f.occurrence, events: const []),
        now: DateTime.utc(2026, 10, 1),
        pillColorsById: {f.pill.id: '#3366CC'},
      );
      expect(entry.pillId, f.pill.id);
      expect(entry.pillColor, '#3366CC');
      expect(entry.plannedAmount.quantityText, '1/2');
      expect(entry.plannedAmount.unit, 'tablet');
      // Nothing recorded yet: the recorded amount stays unknown.
      expect(entry.amount.isUnknown, isTrue);
    },
  );
}
