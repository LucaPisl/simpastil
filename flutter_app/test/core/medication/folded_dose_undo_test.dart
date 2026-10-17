import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/reviewed_stock.dart';

import '../../helpers/care_recording_fixture.dart';

// A dose taken while the ledger was inactive (bridge mode) has no inventory
// event on the server; once the pill's opening has committed, the server
// applies the dose's undo as 0. The phone must do the same, and say so.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CareRecordingFixture f;
  late CareRecordingService service;

  setUp(() async {
    f = await CareRecordingFixture.create(connected: true, legacyStock: 8);
    addTearDown(f.db.close);
    service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => DateTime.utc(2026, 9, 30, 9, 15),
    );
  });

  Future<int?> stock() async =>
      (await f.db.pillsDao.getById(f.pill.id))!.currentStock;

  Future<List<InventoryEvent>> inventory() =>
      f.db.medicationLedgerDao.getInventoryEventsForPill(f.pill.id);

  Future<CareRecordingReceipt> take() async => service.commit(
    await service.prepareTakenNow(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: 0,
    ),
  );

  Future<void> markDose({required bool folded}) async {
    final dose = (await inventory()).singleWhere((e) => e.kind == 'dose');
    await f.db.medicationLedgerDao.updateInventoryEvent(
      dose.id,
      InventoryEventsCompanion(
        provenanceJson: Value(
          folded ? '{"foldedIntoOpening":"opening-command"}' : '{}',
        ),
      ),
    );
  }

  test('a normal dose: the undo gives the unit back', () async {
    final taken = await take();
    expect(await stock(), 7);
    final undone = await service.commit(await service.prepareUndo(taken));
    expect(await stock(), 8);
    expect(undone.stock, CareStockOutcome.applied);
    expect(
      (await inventory()).where((e) => e.kind == 'dose_reversal'),
      hasLength(1),
    );
  });

  test('a dose folded into the opening: undo records, stock stays', () async {
    final taken = await take();
    expect(await stock(), 7);
    await markDose(folded: true);

    final undone = await service.commit(await service.prepareUndo(taken));

    expect(undone.current.state, 'pending', reason: 'the undo is recorded');
    expect(await stock(), 7, reason: 'matches the server, which applies 0');
    expect(
      (await inventory()).where((e) => e.kind == 'dose_reversal'),
      isEmpty,
    );
    expect(undone.stock, CareStockOutcome.unchanged);
    // It still syncs, with its own outbox row.
    final op = await f.db.pendingOperationsDao.getByMutationId(
      f.workspace.context.ownerUserId,
      undone.event.commandId,
    );
    expect(op, isNotNull);
  });

  test(
    'a dose with no fold mark (opening not committed) still moves stock',
    () async {
      final taken = await take();
      await markDose(folded: false);
      final undone = await service.commit(await service.prepareUndo(taken));
      expect(await stock(), 8);
      expect(undone.stock, CareStockOutcome.applied);
    },
  );

  test('a dose frozen into a retrying opening is folded too (N2)', () async {
    final taken = await take();
    expect(await stock(), 7);
    final dose = (await inventory()).singleWhere((e) => e.kind == 'dose');
    await f.db.pendingOperationsDao.enqueue(
      PendingOperationsCompanion.insert(
        id: 'op-start',
        userId: f.workspace.context.ownerUserId,
        mutationId: 'start-1',
        component: 'medication',
        operationType: 'inventory.start',
        contractVersion: 2,
        payloadJson: jsonEncode({
          'inventoryCommand': {
            'commandId': 'start-1',
            'action': 'start',
            'pillId': f.pill.id,
            'initialStock': 8,
          },
          'foldedEventIds': [dose.id],
        }),
        state: const Value('failedRetryable'),
        createdAt: DateTime.utc(2026, 9, 30),
      ),
    );
    final undone = await service.commit(await service.prepareUndo(taken));
    expect(await stock(), 7);
    expect(undone.stock, CareStockOutcome.unchanged);
  });
}
