import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/inventory/pill_stock.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_detail_repository.dart';
import 'package:simpastil/core/medication/reviewed_stock.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

/// An amount a connected account cannot hold exactly (a third of a tablet)
/// records the dose, leaves the count alone and puts the stock in review: the
/// phone says it needs a recount instead of showing a count it cannot vouch for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  Future<CareRecordingFixture> connected(MedicationAmount reviewed) async {
    SharedPreferences.setMockInitialValues({
      LedgerModeHint.fractionalStockKey: true,
    });
    final f = await CareRecordingFixture.create(
      connected: true,
      legacyStock: 10,
      preferences: await SharedPreferences.getInstance(),
    );
    addTearDown(f.db.close);
    await f.db
        .into(f.db.medicationDetails)
        .insertOnConflictUpdate(
          MedicationDetailsCompanion.insert(
            pillId: f.pill.id,
            amountJson: jsonEncode(reviewed.toJson()),
          ),
        );
    return f;
  }

  CareRecordingService serviceOf(CareRecordingFixture f) =>
      CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );

  MedicationDetailRepository detailsOf(CareRecordingFixture f) =>
      MedicationDetailRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );

  Future<CareRecordingReceipt> take(
    CareRecordingFixture f, [
    CareRecordingService? existing,
  ]) async {
    final service = existing ?? serviceOf(f);
    return service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
  }

  final third = MedicationAmount.known('1/3', 'tablet');

  test(
    'a third of a tablet is recorded and the stock needs a recount',
    () async {
      final f = await connected(third);
      final receipt = await take(f);
      expect(receipt.current.state, 'taken');
      expect(receipt.stock, CareStockOutcome.needsReview);

      final pill = (await f.db.pillsDao.getById(f.pill.id))!;
      expect(pill.stockUnit, 'tablet');
      expect(exactStockOf(pill)!.toWire(), '10');
      expect(
        await f.db.medicationLedgerDao.getInventoryEventsForPill(f.pill.id),
        isEmpty,
      );
      final stock = (await detailsOf(f).load(f.pill.id)).stock!;
      expect(stock.needsRecount, isTrue);
    },
  );

  test('a whole-tablet dose never needs a recount', () async {
    final f = await connected(MedicationAmount.known('1', 'tablet'));
    expect((await take(f)).stock, CareStockOutcome.applied);
    expect((await detailsOf(f).load(f.pill.id)).stock!.needsRecount, isFalse);
  });

  test('undoing the dose does not clear the recount on this phone', () async {
    // The server clears the mark and sends the pill; the phone never does.
    final f = await connected(third);
    final service = serviceOf(f);
    final receipt = await take(f, service);
    await service.commit(await service.prepareUndo(receipt));
    expect((await detailsOf(f).load(f.pill.id)).stock!.needsRecount, isTrue);
    expect((await f.db.pillsDao.getById(f.pill.id))!.stockNeedsRecount, isTrue);
  });

  test('the mark is the pill column a server pull sets and clears', () async {
    final f = await connected(third);
    await take(f);
    expect((await f.db.pillsDao.getById(f.pill.id))!.stockNeedsRecount, isTrue);
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(stockNeedsRecount: Value(false)),
    );
    expect((await detailsOf(f).load(f.pill.id)).stock!.needsRecount, isFalse);
  });

  test('a local workspace is not changed by this', () async {
    SharedPreferences.setMockInitialValues({});
    final f = await CareRecordingFixture.create(legacyStock: 10);
    addTearDown(f.db.close);
    expect((await detailsOf(f).load(f.pill.id)).stock!.needsRecount, isFalse);
  });
}
