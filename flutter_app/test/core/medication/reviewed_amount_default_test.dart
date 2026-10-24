import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/inventory/pill_stock.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

/// A connected scheduled dose names no amount, so the reviewed amount per use
/// stands in for it on new take commands: the server then sees the tablet unit
/// and both sides subtract the same half tablet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  Future<CareRecordingFixture> connected({
    required bool fractionalStock,
    MedicationAmount? reviewed,
  }) async {
    SharedPreferences.setMockInitialValues({
      LedgerModeHint.fractionalStockKey: fractionalStock,
    });
    final prefs = await SharedPreferences.getInstance();
    final f = await CareRecordingFixture.create(
      connected: true,
      legacyStock: 30,
      preferences: prefs,
    );
    addTearDown(f.db.close);
    if (reviewed != null) {
      await f.db
          .into(f.db.medicationDetails)
          .insertOnConflictUpdate(
            MedicationDetailsCompanion.insert(
              pillId: f.pill.id,
              amountJson: jsonEncode(reviewed.toJson()),
            ),
          );
    }
    return f;
  }

  CareRecordingService serviceOf(CareRecordingFixture f) =>
      CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );

  Future<Pill> pillOf(CareRecordingFixture f) async =>
      (await f.db.pillsDao.getById(f.pill.id))!;

  final half = MedicationAmount.known('1/2', 'tablets');

  test(
    'take with an unknown amount sends the reviewed amount and counts 0.5',
    () async {
      final f = await connected(fractionalStock: true, reviewed: half);
      final service = serviceOf(f);
      final intent = await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      );
      expect(intent.amount.quantityText, '1/2');
      expect(intent.amount.unit, 'tablets');
      final saved = await service.commit(intent);
      expect(saved.current.state, 'taken');
      final recorded = (await service.historyForPerson(f.person.id)).first;
      expect(recorded.amount.quantityText, '1/2');
      expect(recorded.amount.unit, 'tablets');
      final pill = await pillOf(f);
      expect(pill.stockUnit, 'tablet');
      expect(exactStockOf(pill)!.toWire(), '29.5');
    },
  );

  test(
    'an older server keeps the whole-dose rule and adopts no unit',
    () async {
      final f = await connected(fractionalStock: false, reviewed: half);
      final service = serviceOf(f);
      final intent = await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      );
      await service.commit(intent);
      final pill = await pillOf(f);
      expect(pill.stockUnit, isNull);
      expect(exactStockOf(pill)!.toWire(), '29');
    },
  );

  test('no reviewed amount keeps today\'s behaviour', () async {
    final f = await connected(fractionalStock: true);
    final service = serviceOf(f);
    final intent = await service.prepareTakenNow(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: 0,
    );
    expect(intent.amount.isUnknown, isTrue);
    await service.commit(intent);
    final pill = await pillOf(f);
    expect(pill.stockUnit, isNull);
    expect(exactStockOf(pill)!.toWire(), '29');
  });

  test('a skip carries no amount', () async {
    final f = await connected(fractionalStock: true, reviewed: half);
    final intent = await serviceOf(f).prepare(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: 0,
      action: MedicationAction.skip,
      amount: const MedicationAmount.unknown(),
      actualAt: null,
      actualTimeKnown: false,
    );
    expect(intent.amount.isUnknown, isTrue);
  });

  test(
    'Today and Dose details show the reviewed amount and 29.5 left',
    () async {
      final f = await connected(fractionalStock: true, reviewed: half);
      final day = await CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 8),
      ).load(localDate: '2026-09-30', personId: f.person.id);
      expect(day.entries.single.plannedAmount.quantityText, '1/2');
      final detail = await OccurrenceDetailRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).load(f.occurrence.id);
      expect(detail.plannedAmount.quantityText, '1/2');
      expect(detail.exactAfterTaking!.toWire(), '29.5');
    },
  );

  test('without a reviewed amount the display stays Not specified', () async {
    final f = await connected(fractionalStock: true);
    final detail = await OccurrenceDetailRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    ).load(f.occurrence.id);
    expect(detail.plannedAmount.isUnknown, isTrue);
    expect(detail.exactAfterTaking, isNull);
  });

  test('a recorded dose keeps what it was recorded with', () async {
    final f = await connected(fractionalStock: true);
    final service = serviceOf(f);
    await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    await f.db
        .into(f.db.medicationDetails)
        .insertOnConflictUpdate(
          MedicationDetailsCompanion.insert(
            pillId: f.pill.id,
            amountJson: jsonEncode(half.toJson()),
          ),
        );
    final detail = await OccurrenceDetailRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    ).load(f.occurrence.id);
    expect(detail.plannedAmount.isUnknown, isTrue);
    expect(detail.head!.amount.isUnknown, isTrue);
  });

  test('a taken dose on Today shows the amount it was recorded with', () async {
    final f = await connected(fractionalStock: true, reviewed: half);
    final service = serviceOf(f);
    await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    final day = await CareDayRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => DateTime.utc(2026, 9, 30, 8),
    ).load(localDate: '2026-09-30', personId: f.person.id);
    final entry = day.entries.single;
    expect(entry.occurrence.state, 'taken');
    expect(entry.plannedAmount.quantityText, '1/2');
    expect(entry.plannedAmount.unit, 'tablets');
  });

  test('a taken dose recorded without an amount stays unknown', () async {
    final f = await connected(fractionalStock: true);
    final service = serviceOf(f);
    await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      ),
    );
    final day = await CareDayRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => DateTime.utc(2026, 9, 30, 8),
    ).load(localDate: '2026-09-30', personId: f.person.id);
    expect(day.entries.single.plannedAmount.isUnknown, isTrue);
  });
}
