import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

Future<CareRecordingFixture> _prnFixture() async {
  final f = await CareRecordingFixture.create(connected: true, legacyStock: 4);
  addTearDown(f.db.close);
  await (f.db.update(
    f.db.schedules,
  )..where((s) => s.id.equals(f.occurrence.scheduleId!))).write(
    const SchedulesCompanion(
      frequency: Value('prn'),
      timeZone: Value('Europe/Bucharest'),
      timeZoneStatus: Value('known'),
    ),
  );
  await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
    const PillsCompanion(isPrn: Value(true)),
  );
  // A first as-needed administration has no pre-existing occurrence.
  await (f.db.delete(
    f.db.medicationOccurrences,
  )..where((o) => o.id.equals(f.occurrence.id))).go();
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'connected PRN keeps reviewed Unknown time and exact amount through retry and Undo',
    () async {
      final f = await _prnFixture();
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final intent = await writer.prepareConnectedPrn(
        personId: f.person.id,
        pillId: f.pill.id,
        sentinelId: f.occurrence.scheduleId!,
        reviewedLocalDate: '2026-09-30',
        amount: MedicationAmount.known('1/2', 'tablet'),
        actualAt: null,
        actualTimeKnown: false,
        note: 'Fictional PRN note',
      );
      expect(await f.db.select(f.db.medicationOccurrences).get(), isEmpty);
      final saved = await writer.commit(intent);
      expect((await writer.commit(intent)).event.id, saved.event.id);
      expect(saved.current.id, intent.occurrenceId);
      expect(saved.current.occurrenceKey, 'prn:v1:${intent.occurrenceId}');
      expect(saved.current.expected, isFalse);
      expect(saved.current.plannedAt, isNull);
      expect(saved.current.plannedLocalTime, isNull);
      expect(saved.current.timeZone, 'Europe/Bucharest');
      expect(saved.event.actualAt, isNull);
      expect(saved.event.actualTimeKnown, isFalse);
      expect(saved.amount.quantityText, '1/2');
      expect(saved.sharing, CareSharingOutcome.pending);
      expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 4);
      expect(await f.db.select(f.db.inventoryEvents).get(), isEmpty);
      final undone = await writer.commit(await writer.prepareUndo(saved));
      expect(undone.current.state, 'pending');
      expect(undone.localReversalEventId, saved.event.id);
      expect(
        await f.db.medicationLedgerDao.getOccurrencesForUser(
          f.workspace.context.ownerUserId,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'connected PRN refuses unreviewed actual date and changed sentinel without creating care',
    () async {
      final f = await _prnFixture();
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      Future<PreparedCareIntent> prepare(String date) =>
          writer.prepareConnectedPrn(
            personId: f.person.id,
            pillId: f.pill.id,
            sentinelId: f.occurrence.scheduleId!,
            reviewedLocalDate: date,
            amount: const MedicationAmount.unknown(),
            actualAt: DateTime.utc(2026, 9, 30, 11),
            actualTimeKnown: true,
          );
      await expectLater(
        prepare('2026-10-01'),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      final reviewed = await prepare('2026-09-30');
      await (f.db.update(f.db.schedules)
            ..where((s) => s.id.equals(f.occurrence.scheduleId!)))
          .write(const SchedulesCompanion(isDeleted: Value(true)));
      await expectLater(
        prepare('2026-09-30'),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      await expectLater(
        writer.commit(reviewed),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
      expect(
        await f.db.medicationLedgerDao.getOccurrencesForUser(
          f.workspace.context.ownerUserId,
        ),
        isEmpty,
      );
    },
  );

  test(
    'separate PRN administrations on the same day have separate identities',
    () async {
      final f = await _prnFixture();
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      Future<PreparedCareIntent> prepare() => writer.prepareConnectedPrn(
        personId: f.person.id,
        pillId: f.pill.id,
        sentinelId: f.occurrence.scheduleId!,
        reviewedLocalDate: '2026-09-30',
        amount: const MedicationAmount.unknown(),
        actualAt: null,
        actualTimeKnown: false,
      );
      final first = await writer.commit(await prepare());
      final second = await writer.commit(await prepare());
      expect(second.current.id, isNot(first.current.id));
      expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(2));
      expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 4);
    },
  );
}
