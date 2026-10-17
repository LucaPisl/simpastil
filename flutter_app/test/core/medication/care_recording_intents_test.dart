import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/reviewed_stock.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/features/dashboard/history_entry_mapper.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';

CareRecordingService writer(CareRecordingFixture f) => CareRecordingService(
  database: f.db,
  access: f.workspace.access,
  context: f.workspace.context,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  for (final overlapping in [true, false]) {
    test(
      overlapping
          ? 'overlapping retries commit one exact action and stock effect'
          : 'two consecutive Take and Undo cycles preserve stock and history',
      () async {
        final f = await CareRecordingFixture.create(
          routineAmount: MedicationAmount.known('1', 'tablet'),
        );
        addTearDown(f.db.close);
        final service = writer(f);
        final stocks = ReviewedStockRepository(
          database: f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        );
        await stocks.review(
          f.pill.id,
          StockQuantity.parse('10', 'tablet'),
          expectedRevision: 0,
        );
        Future<PreparedCareIntent> take(int version) => service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: version,
          amount: MedicationAmount.known('1', 'tablet'),
        );
        if (overlapping) {
          final intent = await take(0);
          final receipts = await Future.wait([
            service.commit(intent),
            service.commit(intent),
          ]);
          expect(receipts.first.event.id, receipts.last.event.id);
          expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(1));
        } else {
          for (var i = 0; i < 2; i++) {
            final saved = await service.commit(await take(i * 2));
            await service.commit(await service.prepareUndo(saved));
          }
          expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(4));
          expect(
            (await f.db.medicationLedgerDao.getOccurrenceById(
              f.occurrence.id,
            ))!.state,
            'pending',
          );
        }
        expect(
          StockQuantity.fromJson(
            jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
          ).numerator,
          BigInt.from(overlapping ? 9 : 10),
        );
      },
    );
  }

  test(
    'prepared action refuses a replacement at the same clock slot',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final service = writer(f);
      final intent = await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      );
      final routines = RoutineRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 8),
      );
      final old = (await routines.loadForPill(f.pill.id)).single;
      await routines.saveReviewed(
        await routines.preview(
          pillId: f.pill.id,
          routineId: old.routineId,
          expectedRevision: 1,
          definition: RoutineDefinition(
            kind: RoutineKind.daily,
            timeZone: 'UTC',
            amount: MedicationAmount.known('2', 'tablet'),
            times: [const RoutineTime(slotId: 'morning', hour: 9, minute: 0)],
          ),
          effectiveFrom: DateTime.utc(2026, 9, 30, 8),
          fromLocalDate: '2026-09-30',
          throughLocalDate: '2026-09-30',
        ),
      );
      await expectLater(
        service.commit(intent),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
      expect(
        (await f.db.medicationLedgerDao.getOccurrencesForUser(
          f.workspace.context.ownerUserId,
        )).singleWhere((r) => r.supersededAt == null).id,
        isNot(f.occurrence.id),
      );
    },
  );

  test('Undo of a Skip correction displays the restored Taken facts', () async {
    final f = await CareRecordingFixture.create(
      routineAmount: MedicationAmount.known('1', 'tablet'),
    );
    addTearDown(f.db.close);
    final service = writer(f);
    final taken = await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    final skipped = await service.commit(
      await service.prepare(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 1,
        action: MedicationAction.correct,
        targetState: MedicationState.skipped,
        amount: const MedicationAmount.unknown(),
        actualAt: null,
        actualTimeKnown: false,
      ),
    );
    await service.commit(await service.prepareUndo(skipped));
    final day = await CareDayRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    ).load(localDate: '2026-09-30', personId: f.person.id);
    expect(day.entries.single.occurrence.state, 'taken');
    final record = (await f.db.medicationLedgerDao.getForUserLocalDateRange(
      f.workspace.context.ownerUserId,
      '2026-09-30',
      '2026-09-30',
    )).single;
    final shown = historyEntryFromOccurrenceRecord(record, now: DateTime.now());
    expect(shown.status, 'taken');
    expect(shown.takenAt!.isAtSameMomentAs(taken.event.actualAt!), isTrue);
  });
}
