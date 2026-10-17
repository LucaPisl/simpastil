import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/low_stock.dart';
import 'package:simpastil/core/inventory/supply_forecast.dart';
import 'package:simpastil/core/medication/medication_activity.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/features/dashboard/today_side/stock_overview.dart';
import 'package:simpastil/features/pills/presentation/medication_blister.dart';
import 'package:timezone/data/latest.dart' as tzdata;

SupplyForecast _forecast({
  required int stock,
  int? runsOutInDays,
  int? refillInDays,
  bool pastHorizon = false,
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
    horizon: pastHorizon ? 0 : 60,
  );
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('daysUntilLowStock', () {
    test('is null without a forecast or when the stock outlasts it', () {
      expect(daysUntilLowStock(null), isNull);
      expect(
        daysUntilLowStock(_forecast(stock: 500, pastHorizon: true)),
        isNull,
      );
      expect(daysUntilLowStock(_forecast(stock: 500)), isNull);
    });

    test('takes the earlier of the refill day and the run-out day', () {
      expect(
        daysUntilLowStock(
          _forecast(stock: 20, runsOutInDays: 20, refillInDays: 9),
        ),
        9,
      );
      expect(daysUntilLowStock(_forecast(stock: 20, runsOutInDays: 11)), 11);
    });

    test('still names the refill day when the stock outlasts the horizon', () {
      // 200 tablets at one a day last far beyond 60 days, but the level of
      // 190 is reached after ten doses.
      final forecast = forecastSupply(
        stock: 200,
        threshold: 190,
        versions: [
          (
            effectiveFrom: DateTime.utc(2026),
            definition: RoutineDefinition(
              kind: RoutineKind.daily,
              timeZone: 'UTC',
              times: [const RoutineTime(slotId: 'a', hour: 9, minute: 0)],
            ),
          ),
        ],
        now: DateTime.utc(2026, 10, 16, 8),
      )!;
      expect(forecast.lastsPastHorizon, isTrue);
      expect(forecast.refillBy, DateTime.utc(2026, 10, 25));
      expect(daysUntilLowStock(forecast), 9);

      // So Today's stock row, like Medications, calls it low.
      final row = stockRowFor(
        StockInput(
          pillId: 'p',
          name: 'Fictional',
          personId: 'me',
          personName: 'Me',
          color: null,
          asNeeded: false,
          currentStock: 200,
          threshold: 190,
          forecast: forecast,
          asNeededStock: null,
        ),
      )!;
      expect(row.level, StockLevel.low);
      expect(row.runsLowInDays, 9);
    });
  });

  group('isLowStock', () {
    test('is low at or under its own level', () {
      expect(isLowStock(stock: 5, threshold: 5), isTrue);
      expect(isLowStock(stock: 6, threshold: 5), isFalse);
      expect(isLowStock(stock: 1), isFalse);
      expect(isLowStock(stock: 1, threshold: 0), isFalse);
    });

    test('is low when the routine reaches the level within two weeks', () {
      expect(isLowStock(stock: 40, runsLowInDays: 0), isTrue);
      expect(isLowStock(stock: 40, runsLowInDays: lowStockHeadsUpDays), isTrue);
      expect(
        isLowStock(stock: 40, runsLowInDays: lowStockHeadsUpDays + 1),
        isFalse,
      );
    });
  });

  // Today's stock card, the Medications blister and the Medications summary
  // all read the same facts; they must never give different answers.
  group('every surface agrees', () {
    const stocks = [0, 3, 6, 20, 150];
    const thresholds = <int?>[null, 5];
    final forecasts = <SupplyForecast?>[
      null,
      _forecast(stock: 20, runsOutInDays: 6),
      _forecast(stock: 20, runsOutInDays: 14),
      _forecast(stock: 20, runsOutInDays: 15),
      _forecast(stock: 20, runsOutInDays: 40, refillInDays: 12),
      _forecast(stock: 150, pastHorizon: true),
    ];

    for (final stock in stocks) {
      for (final threshold in thresholds) {
        for (final forecast in forecasts) {
          test('stock $stock, level $threshold, '
              'forecast ${daysUntilLowStock(forecast)}', () {
            final days = daysUntilLowStock(forecast);
            final row = stockRowFor(
              StockInput(
                pillId: 'p',
                name: 'Fictional',
                personId: 'me',
                personName: 'Me',
                color: null,
                asNeeded: false,
                currentStock: stock,
                threshold: threshold,
                forecast: forecast,
                asNeededStock: null,
              ),
            )!;
            final pocket = blisterStateOf(
              stock,
              threshold,
              runsLowInDays: days,
            );
            final summary = summarizeMedications([
              (
                name: 'Fictional',
                asNeeded: false,
                stock: stock,
                threshold: threshold,
                runsLowInDays: days,
              ),
            ]);
            expect(pocket == BlisterState.refill, row.level == StockLevel.low);
            expect(pocket == BlisterState.empty, row.level == StockLevel.out);
            expect(summary.status, switch (row.level) {
              StockLevel.ok => StockStatus.fine,
              StockLevel.low => StockStatus.soon,
              StockLevel.out => StockStatus.out,
            });
          });
        }
      }
    }
  });
}
