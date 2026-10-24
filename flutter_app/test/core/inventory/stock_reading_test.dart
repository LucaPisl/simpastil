import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/inventory/stock_reading.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_detail_repository.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/core/medication/reviewed_stock.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

ReviewedStockBalance _balance(String quantity, String unit) =>
    ReviewedStockBalance(
      workspaceId: 'w',
      pillId: 'p',
      authorId: 'a',
      quantityJson: jsonEncode(StockQuantity.parse(quantity, unit).toJson()),
      reviewRevision: 1,
      revision: 1,
      updatedAt: DateTime.utc(2026, 10, 22),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  group('readStock', () {
    Future<Pill> pill(int? stock) async {
      final f = await CareRecordingFixture.create(legacyStock: stock);
      addTearDown(f.db.close);
      return (await f.db.pillsDao.getById(f.pill.id))!;
    }

    test('reads the reviewed balance before the stored count', () async {
      final reading = readStock(await pill(30), _balance('9', 'tablets'))!;
      expect(reading.fromBalance, isTrue);
      expect(reading.text, '9');
      expect(reading.unit, 'tablets');
      expect(reading.whole, 9);
    });

    test('a balance of thirds reads 3⅓, not 3.33', () async {
      final reading = readStock(await pill(30), _balance('10/3', 'tablets'))!;
      expect(reading.format('en'), '3⅓');
      expect(reading.format('ro'), '3⅓');
      expect(reading.leftText('en'), '3⅓');
      expect(reading.whole, 3);
    });

    test('falls back to the stored count without a balance', () async {
      final reading = readStock(await pill(30), null)!;
      expect(reading.fromBalance, isFalse);
      expect(reading.text, '30');
      expect(reading.unit, isNull);
    });

    test('reads an exact part-tablet stock and counts whole doses', () async {
      final base = await pill(30);
      final half = base.copyWith(
        stockQuantity: const Value('7.5'),
        stockUnit: const Value('tablet'),
      );
      final reading = readStock(
        half,
        null,
        amountPerUse: MedicationAmount.known('1/2', 'tablet'),
      )!;
      expect(reading.text, '7.5');
      expect(reading.unit, 'tablet');
      expect(reading.whole, 15);
      expect(readStock(half, null)!.whole, 7);
    });

    test('is null when nothing is tracked', () async {
      expect(readStock(await pill(null), null), isNull);
    });

    test('keeps fractions in the text and whole doses in the count', () async {
      final reading = readStock(await pill(null), _balance('7.5', 'tablets'))!;
      expect(reading.text, '7.5');
      expect(reading.whole, 7);
    });

    test('a negative balance stays negative', () async {
      final reading = readStock(await pill(null), _balance('-2', 'tablets'))!;
      expect(reading.text, '-2');
      expect(reading.whole, -2);
    });
  });

  test(
    'Medications reads the same balance as Today, not the stored count',
    () async {
      final f = await CareRecordingFixture.create(legacyStock: 30);
      addTearDown(f.db.close);
      await ReviewedStockRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).review(
        f.pill.id,
        StockQuantity.parse('9', 'tablets'),
        expectedRevision: 0,
      );
      final detail = await MedicationDetailRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).load(f.pill.id);
      expect(detail.pill.currentStock, 30);
      expect(detail.stock!.text, '9');
      expect(detail.stock!.fromBalance, isTrue);
    },
  );

  group('saving a count on this device', () {
    MedicationDetailRepository details(CareRecordingFixture f) =>
        MedicationDetailRepository(
          database: f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        );

    Future<MedicationCareDetail> save(
      CareRecordingFixture f,
      int count, {
      MedicationAmount? amount,
    }) async {
      final repo = details(f);
      final expected = await repo.load(f.pill.id);
      final review = expected.review;
      return (await repo.updateReviewed(
        expected: expected,
        review: MedicationReview(
          name: review.name,
          packageStrength: review.packageStrength,
          form: review.form,
          notes: review.notes,
          amount: amount ?? review.amount,
          originalDosage: review.originalDosage,
          legacyDosageReviewed: review.legacyDosageReviewed,
        ),
        currentStock: count,
      )).detail;
    }

    Future<void> take(CareRecordingFixture f, String commandId) =>
        MedicationRepository(
          f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        ).apply(
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.take,
          amount: MedicationAmount.known('1', 'tablet'),
          expectedStateVersion: 0,
          expectedPersonId: f.person.id,
          actualTimeKnown: false,
          commandIdOverride: commandId,
        );

    test('starts the balance a taken dose lowers', () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final saved = await save(
        f,
        10,
        amount: MedicationAmount.known('1', 'tablet'),
      );
      expect(saved.stock!.text, '10');
      expect(saved.stock!.unit, 'tablet');
      expect(saved.pill.currentStock, 10);
      await take(f, '20000000-0000-4000-8000-000000000011');
      expect((await details(f).load(f.pill.id)).stock!.text, '9');
    });

    test(
      'adding stock keeps the review, so Undo still puts a dose back',
      () async {
        final f = await CareRecordingFixture.create();
        addTearDown(f.db.close);
        await save(f, 10, amount: MedicationAmount.known('1', 'tablet'));
        final first = (await (f.db.select(
          f.db.reviewedStockBalances,
        )).getSingle());
        await take(f, '20000000-0000-4000-8000-000000000012');
        await save(f, 29);
        final after = await (f.db.select(
          f.db.reviewedStockBalances,
        )).getSingle();
        expect(after.reviewRevision, first.reviewRevision);
        expect((await details(f).load(f.pill.id)).stock!.text, '29');
        final event = (await f.db.medicationLedgerDao.getEventsForOccurrence(
          f.occurrence.id,
        )).single;
        await MedicationRepository(
          f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        ).apply(
          userId: f.workspace.context.ownerUserId,
          occurrenceId: f.occurrence.id,
          action: MedicationAction.undo,
          intendedState: MedicationState.pending,
          reversesEventId: event.id,
          actualTimeKnown: false,
          commandIdOverride: '20000000-0000-4000-8000-000000000013',
        );
        expect((await details(f).load(f.pill.id)).stock!.text, '30');
      },
    );

    test('a new unit starts a new review', () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await save(f, 10, amount: MedicationAmount.known('1', 'tablet'));
      await save(f, 100, amount: MedicationAmount.known('5', 'ml'));
      final row = await (f.db.select(f.db.reviewedStockBalances)).getSingle();
      expect(row.reviewRevision, 2);
      expect((await details(f).load(f.pill.id)).stock!.unit, 'ml');
    });

    test('without a unit, only the stored count is saved', () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final saved = await save(f, 12);
      expect(saved.pill.currentStock, 12);
      expect(await f.db.select(f.db.reviewedStockBalances).get(), isEmpty);
      expect(saved.stock!.text, '12');
    });

    test('an unchanged count writes nothing new', () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      await save(f, 10, amount: MedicationAmount.known('1', 'tablet'));
      final before = await (f.db.select(
        f.db.reviewedStockBalances,
      )).getSingle();
      await save(f, 10);
      final after = await (f.db.select(f.db.reviewedStockBalances)).getSingle();
      expect(after.revision, before.revision);
    });
  });
}
