import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/low_stock.dart';
import 'package:simpastil/core/inventory/supply_forecast.dart';
import 'package:simpastil/core/storage/low_stock_dismissal_preference.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_summary.dart';
import 'package:simpastil/features/dashboard/today_side/stock_overview.dart';

SupplyForecast _forecast({
  required int stock,
  int? runsOutInDays,
  int? refillInDays,
}) {
  final today = DateTime.utc(2026, 10, 16);
  return SupplyForecast(
    stock: stock,
    days: [
      for (var i = 0; i < 60; i++)
        SupplyDay(
          date: DateTime.utc(today.year, today.month, today.day + i),
          planned: 1,
          covered: 1,
        ),
    ],
    runsOutOn: runsOutInDays == null
        ? null
        : DateTime.utc(today.year, today.month, today.day + runsOutInDays),
    refillBy: refillInDays == null
        ? null
        : DateTime.utc(today.year, today.month, today.day + refillInDays),
    horizon: 60,
  );
}

StockInput _scheduled({
  String id = 'p',
  String name = 'Vitamin D',
  int? stock,
  int? threshold,
  SupplyForecast? forecast,
}) => StockInput(
  pillId: id,
  name: name,
  personId: 'me',
  personName: 'Me',
  color: null,
  asNeeded: false,
  currentStock: stock,
  threshold: threshold,
  forecast: forecast,
  asNeededStock: null,
);

StockInput _asNeeded({
  String id = 'a',
  String name = 'Ibuprofen',
  AsNeededStock? stock,
}) => StockInput(
  pillId: id,
  name: name,
  personId: 'me',
  personName: 'Me',
  color: null,
  asNeeded: true,
  currentStock: null,
  threshold: null,
  forecast: null,
  asNeededStock: stock,
);

void main() {
  group('stockRowFor scheduled', () {
    test('is not listed without a counted stock', () {
      expect(stockRowFor(_scheduled()), isNull);
    });

    test('plenty of stock that lasts past the horizon is not low', () {
      final row = stockRowFor(
        _scheduled(stock: 90, threshold: 10, forecast: _forecast(stock: 90)),
      )!;
      expect(row.level, StockLevel.ok);
      expect(row.low, isFalse);
      expect(row.left, '90');
      expect(row.runsLowInDays, isNull);
      expect(row.fraction, 1.0);
    });

    test('running out within the heads-up window is low', () {
      final row = stockRowFor(
        _scheduled(
          stock: 12,
          threshold: 5,
          forecast: _forecast(stock: 12, runsOutInDays: 12, refillInDays: 7),
        ),
      )!;
      expect(row.level, StockLevel.low);
      expect(row.runsLowInDays, 7);
      expect(row.low, isTrue);
    });

    test('running out far ahead is not low', () {
      final row = stockRowFor(
        _scheduled(
          stock: 50,
          threshold: 5,
          forecast: _forecast(stock: 50, runsOutInDays: 50, refillInDays: 45),
        ),
      )!;
      expect(row.level, StockLevel.ok);
      expect(row.runsLowInDays, isNull);
    });

    test('exactly the heads-up window is low, one day later is not', () {
      final edge = stockRowFor(
        _scheduled(
          stock: 20,
          forecast: _forecast(stock: 20, runsOutInDays: lowStockHeadsUpDays),
        ),
      )!;
      final past = stockRowFor(
        _scheduled(
          stock: 20,
          forecast: _forecast(
            stock: 20,
            runsOutInDays: lowStockHeadsUpDays + 1,
          ),
        ),
      )!;
      expect(edge.level, StockLevel.low);
      expect(past.level, StockLevel.ok);
    });

    test('at or under its own level is low even without a routine', () {
      final at = stockRowFor(_scheduled(stock: 5, threshold: 5))!;
      final over = stockRowFor(_scheduled(stock: 6, threshold: 5))!;
      expect(at.level, StockLevel.low);
      expect(over.level, StockLevel.ok);
      expect(at.forecast, isNull);
    });

    test('no level set and no routine never reads as low', () {
      expect(stockRowFor(_scheduled(stock: 1))!.level, StockLevel.ok);
    });

    test('nothing left is out', () {
      final row = stockRowFor(
        _scheduled(stock: 0, forecast: _forecast(stock: 0, runsOutInDays: 0)),
      )!;
      expect(row.level, StockLevel.out);
      expect(row.runsLowInDays, 0);
    });
  });

  group('stockRowFor as needed', () {
    test('is not listed when untracked', () {
      expect(stockRowFor(_asNeeded()), isNull);
    });

    test('is low only at or under its own level', () {
      final plenty = stockRowFor(
        _asNeeded(
          stock: const AsNeededStock(
            left: '30',
            unit: 'tablet',
            low: false,
            fraction: 1,
          ),
        ),
      )!;
      final low = stockRowFor(
        _asNeeded(
          stock: const AsNeededStock(
            left: '4',
            unit: 'tablet',
            low: true,
            fraction: 0.2,
          ),
        ),
      )!;
      expect(plenty.level, StockLevel.ok);
      expect(plenty.asNeeded, isTrue);
      expect(plenty.runsLowInDays, isNull);
      expect(plenty.unit, 'tablet');
      expect(low.level, StockLevel.low);
      expect(low.left, '4');
    });

    test('an empty balance is out', () {
      final row = stockRowFor(
        _asNeeded(
          stock: const AsNeededStock(
            left: '0',
            unit: 'tablet',
            low: true,
            fraction: 0,
          ),
        ),
      )!;
      expect(row.level, StockLevel.out);
    });
  });

  group('stockRowsFor and lowStockRows', () {
    test('lists out, then low by soonest, then the rest by name', () {
      final rows = stockRowsFor([
        _scheduled(
          id: 'z',
          name: 'Zinc',
          stock: 90,
          forecast: _forecast(stock: 90),
        ),
        _scheduled(
          id: 'm',
          name: 'Magnesium',
          stock: 9,
          forecast: _forecast(stock: 9, runsOutInDays: 9),
        ),
        _scheduled(
          id: 'i',
          name: 'Iron',
          stock: 4,
          forecast: _forecast(stock: 4, runsOutInDays: 4),
        ),
        _scheduled(id: 'o', name: 'Omega', stock: 0),
        _scheduled(
          id: 'a',
          name: 'Alpha',
          stock: 80,
          forecast: _forecast(stock: 80),
        ),
        _scheduled(id: 'untracked', name: 'Untracked'),
      ]);
      expect(rows.map((r) => r.pillId), ['o', 'i', 'm', 'a', 'z']);
      expect(lowStockRows(rows).map((r) => r.pillId), ['o', 'i', 'm']);
    });

    test('nothing low gives no notices', () {
      final rows = stockRowsFor([
        _scheduled(stock: 90, forecast: _forecast(stock: 90)),
      ]);
      expect(lowStockRows(rows), isEmpty);
      expect(const StockOverview(rows: [], canAddStock: true).low, isEmpty);
    });
  });

  group('lowStockDismissed', () {
    final today = DateTime(2026, 10, 16, 9);

    test('hides a notice put off until tomorrow, today only', () {
      final dismissed = {'p': '2026-10-17'};
      expect(lowStockDismissed(dismissed, 'p', today), isTrue);
      expect(lowStockDismissed(dismissed, 'q', today), isFalse);
      expect(
        lowStockDismissed(dismissed, 'p', DateTime(2026, 10, 17, 0, 1)),
        isFalse,
      );
      expect(
        lowStockDismissed(dismissed, 'p', DateTime(2026, 10, 18)),
        isFalse,
      );
    });

    test('an empty map hides nothing', () {
      expect(lowStockDismissed(const {}, 'p', today), isFalse);
    });
  });
}
