import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/reviewed_stock.dart';
import 'dart:convert';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';

const takeId = '20000000-0000-4000-8000-000000000001';
const undoId = '20000000-0000-4000-8000-000000000002';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  MedicationRepository repository(CareRecordingFixture f) =>
      MedicationRepository(
        f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
  test(
    'actual local care records durably and never enters a network queue',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await repository(f).apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.take,
        actualTimeKnown: true,
        actualAt: DateTime.utc(2026, 9, 30, 9, 15),
        commandIdOverride: takeId,
      );
      expect(
        (await f.db.medicationLedgerDao.getOccurrenceById(
          f.occurrence.id,
        ))!.state,
        'taken',
      );
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
      expect(
        (await f.db.medicationLedgerDao.getEventsForOccurrence(
          f.occurrence.id,
        )).length,
        1,
      );
    },
  );
  test(
    'actual local Undo references its unacknowledged local event and preserves that event',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      const eventId = '20000000-0000-4000-8000-000000000003';
      await f.db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: eventId,
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          commandId: takeId,
          action: 'take',
          fromState: 'pending',
          toState: 'taken',
          origin: 'native',
          baseVersion: 0,
          resultVersion: 1,
          actualAt: Value(DateTime.utc(2026, 9, 30, 9, 15)),
          actualTimeKnown: const Value(true),
          recordedAt: DateTime.utc(2026, 9, 30, 9, 15),
        ),
      );
      await (f.db.update(
        f.db.medicationOccurrences,
      )..where((r) => r.id.equals(f.occurrence.id))).write(
        const MedicationOccurrencesCompanion(
          state: Value('taken'),
          stateVersion: Value(1),
        ),
      );
      await repository(f).apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: eventId,
        actualTimeKnown: false,
        commandIdOverride: undoId,
      );
      final events = await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      );
      expect(events.length, 2);
      expect(events.singleWhere((e) => e.id == eventId).action, 'take');
      expect(
        (await f.db.medicationLedgerDao.getOccurrenceById(
          f.occurrence.id,
        ))!.state,
        'pending',
      );
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
    },
  );
  test(
    'connected immediate Undo depends on the original unacknowledged command',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final repo = repository(f);
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.take,
        actualTimeKnown: false,
        commandIdOverride: takeId,
      );
      final event = (await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      )).single;
      final original = (await f.db.pendingOperationsDao.getByMutationId(
        f.workspace.context.ownerUserId,
        takeId,
      ))!;
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: event.id,
        actualTimeKnown: false,
        commandIdOverride: undoId,
      );
      final undo = (await f.db.pendingOperationsDao.getByMutationId(
        f.workspace.context.ownerUserId,
        undoId,
      ))!;
      expect(undo.dependsOnOperationId, original.id);
      expect(undo.state, 'queued');
      expect(
        (await f.db.medicationLedgerDao.getOccurrenceById(
          f.occurrence.id,
        ))!.state,
        'pending',
      );
    },
  );
  test(
    'local fraction stock and Undo apply once; original whole-number stock stays unlabeled',
    () async {
      final f = await CareRecordingFixture.create(legacyStock: 10);
      addTearDown(f.db.close);
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
      final repo = repository(f);
      Future<void> take() async {
        await repo.apply(
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.take,
          amount: MedicationAmount.known('1/2', 'tablet'),
          expectedStateVersion: 0,
          expectedPersonId: f.person.id,
          actualTimeKnown: false,
          commandIdOverride: takeId,
        );
      }

      await take();
      await take();
      final afterTake = StockQuantity.fromJson(
        jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
      );
      expect(afterTake.numerator, BigInt.from(19));
      expect(afterTake.denominator, BigInt.two);
      expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 10);
      final event = (await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      )).single;
      Future<void> undo() async {
        await repo.apply(
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.undo,
          intendedState: MedicationState.pending,
          reversesEventId: event.id,
          expectedStateVersion: 1,
          expectedPersonId: f.person.id,
          actualTimeKnown: false,
          commandIdOverride: undoId,
        );
      }

      await undo();
      await undo();
      final finalQuantity = StockQuantity.fromJson(
        jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
      );
      expect(finalQuantity.numerator, BigInt.from(10));
      expect(finalQuantity.denominator, BigInt.one);
      final details = await f.db.select(f.db.careEventDetails).get();
      expect(details.length, 2);
      expect(
        details.every((d) => d.authorId == f.workspace.context.authorId),
        isTrue,
      );
      expect(
        (await f.db.medicationLedgerDao.getEventsForOccurrence(
          f.occurrence.id,
        )).length,
        2,
      );
    },
  );
  test(
    'known negative physical stock does not block care and is exactly undone',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final stocks = ReviewedStockRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      await stocks.review(
        f.pill.id,
        StockQuantity.parse('0', 'tablet'),
        expectedRevision: 0,
      );
      final repo = repository(f);
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.take,
        amount: MedicationAmount.known('1', 'tablet'),
        actualTimeKnown: false,
        commandIdOverride: takeId,
      );
      expect(
        StockQuantity.fromJson(
          jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
        ).numerator,
        -BigInt.one,
      );
      final event = (await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      )).single;
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: event.id,
        actualTimeKnown: false,
        commandIdOverride: undoId,
      );
      expect(
        StockQuantity.fromJson(
          jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
        ).numerator,
        BigInt.zero,
      );
    },
  );
  test(
    'unreviewed or mismatched stock units remain unchanged while care records Unknown time',
    () async {
      final f = await CareRecordingFixture.create(legacyStock: 2);
      addTearDown(f.db.close);
      final stocks = ReviewedStockRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      await stocks.review(
        f.pill.id,
        StockQuantity.parse('2', 'bottle'),
        expectedRevision: 0,
      );
      await repository(f).apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.take,
        amount: MedicationAmount.known('2.5', 'mL'),
        actualTimeKnown: false,
        commandIdOverride: takeId,
      );
      final event = (await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      )).single;
      expect(event.actualAt, isNull);
      expect(event.actualTimeKnown, isFalse);
      final detail = (await f.db.select(f.db.careEventDetails).get()).single;
      expect(detail.stockOutcome, 'needsReview');
      expect(detail.authorId, f.workspace.context.authorId);
      expect(
        StockQuantity.fromJson(
          jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
        ).numerator,
        BigInt.two,
      );
      expect((await f.db.pillsDao.getById(f.pill.id))!.currentStock, 2);
    },
  );
  test(
    'Undo after a new physical stock review preserves that reviewed measurement',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
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
      final repo = repository(f);
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.take,
        amount: MedicationAmount.known('1/2', 'tablet'),
        actualTimeKnown: false,
        commandIdOverride: takeId,
      );
      await stocks.review(
        f.pill.id,
        StockQuantity.parse('13', 'tablet'),
        expectedRevision: (await stocks.load(f.pill.id))!.revision,
      );
      final event = (await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      )).single;
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: event.id,
        actualTimeKnown: false,
        commandIdOverride: undoId,
      );
      expect(
        (await f.db.medicationLedgerDao.getOccurrenceById(
          f.occurrence.id,
        ))!.state,
        'pending',
      );
      expect(
        StockQuantity.fromJson(
          jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
        ).numerator,
        BigInt.from(13),
      );
      expect(
        (await f.db.select(f.db.careEventDetails).get())
            .singleWhere((d) => d.commandId == undoId)
            .stockOutcome,
        'needsReview',
      );
    },
  );
  test(
    'reused intent ID with different facts and stale displayed version cannot record again',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final repo = repository(f);
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.take,
        actualTimeKnown: false,
        expectedStateVersion: 0,
        commandIdOverride: takeId,
      );
      await expectLater(
        repo.apply(
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.skip,
          actualTimeKnown: false,
          expectedStateVersion: 0,
          commandIdOverride: takeId,
        ),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      await expectLater(
        repo.apply(
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.take,
          actualTimeKnown: false,
          expectedStateVersion: 0,
          commandIdOverride: undoId,
        ),
        throwsA(isA<MedicationCommandBlocked>()),
      );
      expect(
        (await f.db.medicationLedgerDao.getEventsForOccurrence(
          f.occurrence.id,
        )).length,
        1,
      );
    },
  );

  test(
    'local device replay after Undo returns original durable receipt without taking again',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await f.db
          .into(f.db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: f.person.id,
              enabled: const Value(true),
            ),
          );
      final repo = repository(f);
      final projection = reminderProjectionId(
        userId: f.workspace.context.ownerUserId,
        sessionGeneration: f.workspace.context.accessEpoch,
        workspaceId: f.workspace.context.workspaceId,
        grantEpoch: f.workspace.context.accessEpoch,
        occurrenceId: f.occurrence.id,
        kind: 'widget',
        stateVersion: 0,
      );
      Future<MedicationCommand> deviceTake() => repo.applyDeviceAction(
        occurrenceId: f.occurrence.id,
        projectionId: projection,
        kind: 'widget',
        action: MedicationAction.take,
        deliveredStateVersion: 0,
        now: DateTime.utc(2026, 9, 30, 9, 15),
      );
      final original = await deviceTake();
      final head = (await f.db.medicationLedgerDao.getEventsForOccurrence(
        f.occurrence.id,
      )).single;
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: head.id,
        actualTimeKnown: false,
        commandIdOverride: undoId,
      );
      expect((await deviceTake()).commandId, original.commandId);
      expect(
        (await f.db.medicationLedgerDao.getOccurrenceById(
          f.occurrence.id,
        ))!.state,
        'pending',
      );
      expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(2));
    },
  );

  test(
    'a widget or reminder tap from before an automatic miss cannot record the dose',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await f.db
          .into(f.db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: f.person.id,
              enabled: const Value(true),
            ),
          );
      final repo = repository(f);
      final projection = reminderProjectionId(
        userId: f.workspace.context.ownerUserId,
        sessionGeneration: f.workspace.context.accessEpoch,
        workspaceId: f.workspace.context.workspaceId,
        grantEpoch: f.workspace.context.accessEpoch,
        occurrenceId: f.occurrence.id,
        kind: 'widget',
        stateVersion: 0,
      );
      await repo.apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.miss,
        actualTimeKnown: false,
        commandIdOverride: autoMissCommandId(
          ownerUserId: f.workspace.context.ownerUserId,
          occurrenceKey: f.occurrence.occurrenceKey,
        ),
      );

      for (final action in [MedicationAction.take, MedicationAction.skip]) {
        await expectLater(
          repo.applyDeviceAction(
            occurrenceId: f.occurrence.id,
            projectionId: projection,
            kind: 'widget',
            action: action,
            deliveredStateVersion: 0,
            now: DateTime.utc(2026, 9, 30, 9, 40),
          ),
          throwsA(
            isA<MedicationCommandBlocked>().having(
              (e) => e.code,
              'code',
              'device_occurrence_unavailable',
            ),
          ),
        );
      }
      final row = (await f.db.medicationLedgerDao.getOccurrenceById(
        f.occurrence.id,
      ))!;
      expect(row.state, 'missed');
      expect(row.stateVersion, 1);
      expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(1));
    },
  );
}
