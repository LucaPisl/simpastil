import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/supply_forecast.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

RoutineDefinition _daily(List<(int, int)> times, {String zone = 'UTC'}) =>
    RoutineDefinition(
      kind: RoutineKind.daily,
      timeZone: zone,
      times: [
        for (final (h, m) in times)
          RoutineTime(slotId: 's$h$m', hour: h, minute: m),
      ],
    );

SupplyRoutine _from(DateTime at, RoutineDefinition d) =>
    (effectiveFrom: at, definition: d);

final _start = DateTime.utc(2026, 9, 1);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('counts only the doses still to come today, then whole days', () {
    // 08:03 on Tue 13 Oct: the 08:00 dose has passed, 20:00 is still ahead.
    final forecast = forecastSupply(
      stock: 9,
      versions: [
        _from(_start, _daily([(8, 0), (20, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 8, 3),
    )!;
    expect(forecast.days.first.planned, 1);
    expect(forecast.days[1].planned, 2);
    // 1 tonight + 4 full days = 9 doses.
    expect(forecast.enoughUntil, DateTime.utc(2026, 10, 17));
    expect(forecast.runsOutOn, DateTime.utc(2026, 10, 18));
    expect(forecast.days[5].covered, 0);
    expect(forecast.lastsPastHorizon, isFalse);
  });

  test('a part-covered day is the day it runs out', () {
    final forecast = forecastSupply(
      stock: 4,
      versions: [
        _from(_start, _daily([(8, 0), (20, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    expect(forecast.enoughUntil, DateTime.utc(2026, 10, 14));
    expect(forecast.runsOutOn, DateTime.utc(2026, 10, 15));

    final odd = forecastSupply(
      stock: 5,
      versions: [
        _from(_start, _daily([(8, 0), (20, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    expect(odd.runsOutOn, DateTime.utc(2026, 10, 15));
    expect(odd.days[2].covered, 1);
    expect(odd.days[2].short, isTrue);
  });

  test('today falls short, or nothing is left', () {
    final short = forecastSupply(
      stock: 1,
      versions: [
        _from(_start, _daily([(8, 0), (20, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    expect(short.runsOutOn, DateTime.utc(2026, 10, 13));
    expect(short.enoughUntil, isNull);

    // Negative stock never blocks a dose; here it reads as none left.
    final none = forecastSupply(
      stock: -2,
      versions: [
        _from(_start, _daily([(8, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    expect(none.stock, 0);
    expect(none.enoughUntil, isNull);
  });

  test('the low-stock day comes before it runs out', () {
    final forecast = forecastSupply(
      stock: 10,
      threshold: 4,
      versions: [
        _from(_start, _daily([(9, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    // After the 6th day's dose, 4 remain.
    expect(forecast.refillBy, DateTime.utc(2026, 10, 18));
    expect(forecast.enoughUntil, DateTime.utc(2026, 10, 22));
  });

  test('weekdays and intervals skip their off days', () {
    final weekdays = forecastSupply(
      stock: 3,
      versions: [
        _from(
          _start,
          RoutineDefinition(
            kind: RoutineKind.weekdays,
            timeZone: 'UTC',
            weekdays: const [1, 3, 5],
            times: [const RoutineTime(slotId: 'a', hour: 9, minute: 0)],
          ),
        ),
      ],
      // Tuesday.
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    // Wed, Fri, Mon covered; Wed 21 is short.
    expect(weekdays.enoughUntil, DateTime.utc(2026, 10, 19));
    expect(weekdays.runsOutOn, DateTime.utc(2026, 10, 21));

    final interval = forecastSupply(
      stock: 2,
      versions: [
        _from(
          _start,
          RoutineDefinition(
            kind: RoutineKind.interval,
            timeZone: 'UTC',
            everyDays: 3,
            anchorDate: '2026-10-13',
            times: [const RoutineTime(slotId: 'a', hour: 9, minute: 0)],
          ),
        ),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    expect(interval.enoughUntil, DateTime.utc(2026, 10, 16));
    expect(interval.runsOutOn, DateTime.utc(2026, 10, 19));
  });

  test('a routine change takes over on its day', () {
    final forecast = forecastSupply(
      stock: 6,
      versions: [
        _from(_start, _daily([(9, 0)])),
        _from(DateTime.utc(2026, 10, 15), _daily([(9, 0), (21, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    expect([for (final d in forecast.days.take(4)) d.planned], [1, 1, 2, 2]);
    // 1 + 1 + 2 + 2 = 6.
    expect(forecast.enoughUntil, DateTime.utc(2026, 10, 16));
  });

  test("today is the routine zone's day", () {
    // 23:30 UTC is already the 14th at 02:30 in Bucharest.
    final forecast = forecastSupply(
      stock: 1,
      versions: [
        _from(_start, _daily([(8, 0)], zone: 'Europe/Bucharest')),
      ],
      now: DateTime.utc(2026, 10, 13, 23, 30),
    )!;
    expect(forecast.days.first.date, DateTime.utc(2026, 10, 14));
    expect(forecast.days.first.planned, 1);
  });

  test('plenty lasts past the horizon; nothing to plan says nothing', () {
    final plenty = forecastSupply(
      stock: 500,
      versions: [
        _from(_start, _daily([(8, 0)])),
      ],
      now: DateTime.utc(2026, 10, 13, 6),
    )!;
    expect(plenty.lastsPastHorizon, isTrue);
    expect(plenty.enoughUntil, isNull);
    expect(plenty.days, hasLength(60));

    expect(
      forecastSupply(
        stock: 5,
        versions: [
          _from(
            _start,
            RoutineDefinition(
              kind: RoutineKind.prn,
              timeZone: 'UTC',
              times: [],
            ),
          ),
        ],
        now: DateTime.utc(2026, 10, 13, 6),
      ),
      isNull,
    );
    expect(
      forecastSupply(stock: 5, versions: [], now: DateTime.utc(2026, 10, 13)),
      isNull,
    );
    final ended = RoutineDefinition(
      kind: RoutineKind.daily,
      timeZone: 'UTC',
      endDate: '2026-10-01',
      times: [const RoutineTime(slotId: 'a', hour: 9, minute: 0)],
    );
    expect(
      forecastSupply(
        stock: 5,
        versions: [_from(_start, ended)],
        now: DateTime.utc(2026, 10, 13),
      ),
      isNull,
    );
  });
}
