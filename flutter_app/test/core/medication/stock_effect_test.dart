import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/stock_effect.dart';

/// The shared vectors the server test reads too, so both sides agree on the
/// exact-stock rules.
void main() {
  final fixture =
      jsonDecode(
            File(
              '../contracts/fixtures/fractional-stock-v1.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;

  MedicationAmount? amountOf(Object? json) {
    if (json == null) return null;
    try {
      return MedicationAmount.fromJson((json as Map).cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  test('canonical quantities round-trip and everything else is rejected', () {
    final quantities = fixture['canonicalQuantities'] as Map<String, Object?>;
    for (final text in (quantities['valid'] as List).cast<String>()) {
      expect(ExactStock.tryParseWire(text)?.toWire(), text, reason: text);
    }
    for (final text in (quantities['invalid'] as List).cast<String>()) {
      expect(ExactStock.tryParseWire(text), isNull, reason: text);
    }
  });

  test('amounts scale exactly or not at all', () {
    for (final row in (fixture['amounts'] as List).cast<Map>()) {
      final scaled = ExactStock.fromAmount(amountOf(row['amount']));
      expect(scaled?.toWire(), row['scaled'], reason: '${row['amount']}');
    }
  });

  test('countable units match the server list', () {
    final units = fixture['countableUnits'] as Map<String, Object?>;
    for (final unit in (units['yes'] as List).cast<String>()) {
      expect(isCountableStockUnit(unit), isTrue, reason: unit);
    }
    for (final unit in (units['no'] as List).cast<String>()) {
      expect(isCountableStockUnit(unit), isFalse, reason: unit);
    }
  });

  test('unit spellings compare and canonicalise like the server', () {
    final spellings = fixture['unitSpellings'] as Map<String, Object?>;
    for (final pair in (spellings['same'] as List).cast<List>()) {
      expect(sameStockUnit(pair[0] as String, pair[1] as String), isTrue);
      expect(sameStockUnit(pair[1] as String, pair[0] as String), isTrue);
    }
    for (final pair in (spellings['different'] as List).cast<List>()) {
      expect(sameStockUnit(pair[0] as String, pair[1] as String), isFalse);
    }
    (spellings['canonical'] as Map).forEach((from, to) {
      expect(canonicalStockUnit(from as String), to, reason: from);
    });
    expect(sameStockUnit(null, 'tablet'), isFalse);
  });

  test('adopting a unit writes its canonical spelling', () {
    expect(
      stockUnitToAdopt(
        tracked: true,
        stockUnit: null,
        wholeCount: true,
        commandAmount: MedicationAmount.known('1', 'Tablet'),
        amountPerUse: MedicationAmount.known('1', 'Tablets'),
      ),
      'tablet',
    );
  });

  for (final vector in (fixture['effects'] as List).cast<Map>()) {
    test('effect: ${vector['name']}', () {
      final referenced = vector['referencedDelta'] as String?;
      final result = computeStockEffect(
        tracked: vector['tracked'] as bool,
        stockUnit: vector['stockUnit'] as String?,
        amountPerUse: amountOf(vector['amountPerUse']),
        commandAmount: amountOf(vector['commandAmount']),
        action: vector['action'] as String,
        transition: vector['transition'] as int,
        referencedDelta: referenced == null
            ? null
            : ExactStock.parseWire(referenced),
        linkedNet: ExactStock.parseWire(vector['linkedNet'] as String),
      );
      final expected = vector['expect'] as Map;
      final kind = switch (expected['kind']) {
        'applied' => StockEffectKind.applied,
        'none' => StockEffectKind.none,
        'not_tracked' => StockEffectKind.notTracked,
        _ => StockEffectKind.needsReview,
      };
      expect(result.kind, kind);
      if (kind == StockEffectKind.applied) {
        expect(result.delta.toWire(), expected['delta']);
      }
    });
  }

  test('ExactStock arithmetic, floor and input parsing', () {
    final half = ExactStock.tryParseInput('1/2')!;
    expect((ExactStock.fromInt(1) - half).toWire(), '0.5');
    expect((-half).floor, -1);
    expect(ExactStock.tryParseInput('10,5')!.toWire(), '10.5');
    expect(ExactStock.tryParseInput('10 1/2')!.toWire(), '10.5');
    expect(ExactStock.tryParseInput('1/3'), isNull);
    expect(ExactStock.tryParseInput('0.1234567'), isNull);
    expect(ExactStock.tryParseInput('abc'), isNull);
    expect(ExactStock.tryParseInput('-1/2')!.toWire(), '-0.5');
    expect(ExactStock.tryParseInput('10.5')!.wholeDoses(half), 21);
  });
}
