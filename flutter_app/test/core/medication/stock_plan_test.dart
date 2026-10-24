import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/core/inventory/pill_stock.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/stock_effect.dart';
import 'package:simpastil/core/medication/stock_plan.dart';

const _userId = 'user-1';
const _profileId = '00000000-0000-4000-8000-000000000001';
const _pillId = '00000000-0000-4000-8000-000000000002';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 10, 1);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: _userId,
            email: 'user@test.com',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profileId,
        userId: _userId,
        name: 'Ada',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pillId,
        profileId: _profileId,
        name: 'Medication',
        currentStock: const Value(10),
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() => db.close());

  Future<void> reviewAmount(String quantity, String unit) => db
      .into(db.medicationDetails)
      .insert(
        MedicationDetailsCompanion.insert(
          pillId: _pillId,
          amountJson: jsonEncode(
            MedicationAmount.known(quantity, unit).toJson(),
          ),
        ),
      );

  Future<Pill> pill() async => (await db.pillsDao.getById(_pillId))!;

  Future<StockPlan> plan(String quantity, String unit) async => planStockChange(
    db: db,
    pill: await pill(),
    action: 'take',
    transition: -1,
    amount: MedicationAmount.known(quantity, unit),
    occurrenceId: 'occurrence-1',
    fractionalStock: true,
  );

  test('a whole count with no reviewed amount keeps the plain rule', () async {
    final result = await plan('1/2', 'tablet');
    expect(result.unit, isNull);
    expect(result.delta, ExactStock.fromInt(-1));
  });

  test(
    'half a tablet adopts the tablet unit and subtracts exactly one half',
    () async {
      await reviewAmount('1/2', 'tablet');
      final result = await plan('1/2', 'tablet');
      expect(result.adoptedUnit, 'tablet');
      expect(result.unit, 'tablet');
      expect(result.delta.toWire(), '-0.5');
      expect(result.kind, StockEffectKind.applied);
    },
  );

  test('a second half tablet takes the same exact half (idempotent)', () async {
    await reviewAmount('1/2', 'tablet');
    expect((await plan('1/2', 'tablet')).adoptedUnit, 'tablet');
    final current = await pill();
    await db
        .update(db.pills)
        .replace(
          current.copyWith(
            currentStock: const Value(9),
            stockQuantity: const Value('9.5'),
            stockUnit: const Value('tablet'),
          ),
        );
    final second = await plan('1/2', 'tablet');
    expect(second.adoptedUnit, isNull);
    expect(second.unit, 'tablet');
    expect(second.delta.toWire(), '-0.5');
    final stored = await pill();
    expect(exactStockOf(stored)!.toWire(), '9.5');
    expect(stored.currentStock, 9);
  });

  test(
    'millilitres never adopt: the count stays plain until confirmed',
    () async {
      await reviewAmount('5', 'ml');
      final result = await plan('5', 'ml');
      expect(result.adoptedUnit, isNull);
      expect(result.unit, isNull);
      expect(result.delta, ExactStock.fromInt(-1));
    },
  );

  test('an untaken dose puts back exactly what it took', () async {
    await reviewAmount('1/2', 'tablet');
    final current = await pill();
    await db
        .update(db.pills)
        .replace(
          current.copyWith(
            currentStock: const Value(9),
            stockQuantity: const Value('9.5'),
            stockUnit: const Value('tablet'),
          ),
        );
    final result = await planStockChange(
      db: db,
      pill: await pill(),
      action: 'correct',
      transition: 1,
      amount: MedicationAmount.known('1/2', 'tablet'),
      occurrenceId: 'occurrence-1',
      fractionalStock: true,
    );
    expect(result.unit, 'tablet');
    expect(result.delta.isNegative, isFalse);
  });

  test(
    'without the server capability the plain whole dose is subtracted',
    () async {
      await reviewAmount('1/2', 'tablet');
      final result = await planStockChange(
        db: db,
        pill: await pill(),
        action: 'take',
        transition: -1,
        amount: MedicationAmount.known('1/2', 'tablet'),
        occurrenceId: 'occurrence-1',
      );
      expect(result.unit, isNull);
      expect(result.adoptedUnit, isNull);
      expect(result.delta, ExactStock.fromInt(-1));
    },
  );
}
