import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_preview.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);
  RoutineDefinition definition({
    RoutineKind kind = RoutineKind.daily,
    String zone = 'UTC',
    List<RoutineTime>? times,
    List<int> weekdays = const [],
    int? everyDays,
    String? anchor,
    String? start,
    String? end,
  }) => RoutineDefinition(
    kind: kind,
    timeZone: zone,
    times: times ?? [const RoutineTime(slotId: 'morning', hour: 9, minute: 0)],
    weekdays: weekdays,
    everyDays: everyDays,
    anchorDate: anchor,
    startDate: start,
    endDate: end,
  );
  List<RoutinePlannedEntry> entries(
    RoutineDefinition d,
    String from,
    String through,
  ) => RoutineEngine().preview(
    definition: d,
    fromLocalDate: from,
    throughLocalDate: through,
  );

  test(
    'daily multi-time uses reviewed zone during travel and inclusive dates',
    () {
      tz.setLocalLocation(tz.getLocation('America/Los_Angeles'));
      final rows = entries(
        definition(
          zone: 'Europe/Bucharest',
          start: '2026-09-30',
          end: '2026-10-01',
          times: [
            const RoutineTime(slotId: 'morning', hour: 9, minute: 0),
            const RoutineTime(slotId: 'evening', hour: 20, minute: 0),
          ],
        ),
        '2026-09-29',
        '2026-10-02',
      );
      expect(rows.length, 4);
      expect(rows.first.plannedAt, DateTime.utc(2026, 9, 30, 6));
      expect(rows.last.localDate, '2026-10-01');
    },
  );
  test(
    'calendar intervals cross month and leap day from the reviewed anchor',
    () {
      final rows = entries(
        definition(
          kind: RoutineKind.interval,
          everyDays: 2,
          anchor: '2024-02-27',
        ),
        '2024-02-26',
        '2024-03-03',
      );
      expect(rows.map((r) => r.localDate), [
        '2024-02-27',
        '2024-02-29',
        '2024-03-02',
      ]);
    },
  );
  test('weekdays are explicit and PRN produces no expected quota', () {
    expect(
      entries(
        definition(kind: RoutineKind.weekdays, weekdays: [1, 5]),
        '2026-09-28',
        '2026-10-04',
      ).map((r) => r.localDate),
      ['2026-09-28', '2026-10-02'],
    );
    expect(
      entries(
        definition(kind: RoutineKind.prn, times: []),
        '2026-09-28',
        '2026-10-04',
      ),
      isEmpty,
    );
  });
  test(
    'reject duplicate times, unstable duplicate slots and invalid weekdays',
    () {
      expect(
        () => definition(
          times: [
            const RoutineTime(slotId: 'a', hour: 9, minute: 0),
            const RoutineTime(slotId: 'b', hour: 9, minute: 0),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => definition(
          times: [
            const RoutineTime(slotId: 'a', hour: 9, minute: 0),
            const RoutineTime(slotId: 'a', hour: 10, minute: 0),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => definition(kind: RoutineKind.weekdays, weekdays: [0, 8]),
        throwsArgumentError,
      );
      expect(
        () => definition(kind: RoutineKind.weekdays, weekdays: [1, 1]),
        throwsArgumentError,
      );
      expect(
        () => definition(start: '2026-10-01', end: '2026-09-30'),
        throwsArgumentError,
      );
    },
  );
  test('DST retains connected gap and overlap rules', () {
    final d = definition(
      zone: 'America/New_York',
      times: [const RoutineTime(slotId: 'night', hour: 2, minute: 30)],
    );
    expect(
      entries(d, '2026-03-08', '2026-03-08').single.plannedAt,
      DateTime.utc(2026, 3, 8, 7),
    );
    final overlap = definition(
      zone: 'America/New_York',
      times: [const RoutineTime(slotId: 'night', hour: 1, minute: 30)],
    );
    expect(
      entries(overlap, '2026-11-01', '2026-11-01').single.plannedAt,
      DateTime.utc(2026, 11, 1, 5, 30),
    );
  });
  test('next dose reaches a long interval without a preview horizon', () {
    final next = RoutineEngine().next(
      definition: definition(
        kind: RoutineKind.interval,
        everyDays: 60,
        anchor: '2026-10-01',
      ),
      fromLocalDate: '2026-10-02',
      notBefore: DateTime.utc(2026, 10, 1),
    )!;
    expect(next.localDate, '2026-11-30');
    expect(next.plannedAt, DateTime.utc(2026, 11, 30, 9));
  });
  test(
    'next dose uses the same DST instant and exclusive revision boundary',
    () {
      final d = definition(
        zone: 'America/New_York',
        times: [const RoutineTime(slotId: 'night', hour: 2, minute: 30)],
      );
      final gap = DateTime.utc(2026, 3, 8, 7);
      expect(
        RoutineEngine()
            .next(
              definition: d,
              fromLocalDate: '2026-03-08',
              notBefore: gap,
              before: gap.add(const Duration(seconds: 1)),
            )!
            .plannedAt,
        entries(d, '2026-03-08', '2026-03-08').single.plannedAt,
      );
      expect(
        RoutineEngine().next(
          definition: d,
          fromLocalDate: '2026-03-08',
          notBefore: gap,
          before: gap,
        ),
        isNull,
      );
    },
  );
}
