import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/low_stock.dart';
import 'package:simpastil/core/medication/adherence_calculator.dart';
import 'package:simpastil/core/medication/medication_activity.dart';

// Wednesday 14 October 2026, 21:30 local.
final _now = DateTime(2026, 10, 14, 21, 30);

AdherenceHistoryItem _scheduled(
  String id,
  String date,
  int hour,
  String status, {
  String pill = 'p1',
  bool superseded = false,
  bool expected = true,
}) => AdherenceHistoryItem(
  occurrenceId: id,
  source: 'scheduled',
  expected: expected,
  superseded: superseded,
  isDueScheduled: status != 'pending',
  status: status,
  provenance: 'local',
  plannedAt: DateTime.parse('${date}T${hour.toString().padLeft(2, '0')}:00:00'),
  actualAt: null,
  actualTimeKnown: false,
  note: null,
  pillId: pill,
  pillName: 'Fevarin',
  dosage: null,
  profileId: 'u1',
  plannedLocalDate: date,
);

AdherenceHistoryItem _prn(
  String id,
  String date, {
  DateTime? at,
  String status = 'taken',
  String pill = 'p1',
}) => AdherenceHistoryItem(
  occurrenceId: id,
  source: 'prn',
  expected: false,
  superseded: false,
  isDueScheduled: false,
  status: status,
  provenance: 'local',
  plannedAt: null,
  actualAt: at,
  actualTimeKnown: at != null,
  note: null,
  pillId: pill,
  pillName: 'Fevarin',
  dosage: null,
  profileId: 'u1',
  plannedLocalDate: date,
);

MedicationActivity _derive(List<AdherenceHistoryItem> items) =>
    medicationActivityFrom(items: items, pillId: 'p1', now: _now);

void main() {
  group('last 14 days', () {
    test('is fourteen days, oldest first, ending today', () {
      final a = _derive(const []);
      expect(a.days, hasLength(14));
      expect(a.days.first.date, DateTime(2026, 10, 1));
      expect(a.days.last.date, DateTime(2026, 10, 14));
      expect(a.days.every((d) => d.state == ActivityDayState.none), isTrue);
      expect(a.hasAnyRecord, isFalse);
      expect(a.takenDays, 0);
      expect(a.dueDays, 0);
    });

    test('marks taken, skipped and not recorded days of one dose a day', () {
      final a = _derive([
        _scheduled('a', '2026-10-14', 8, 'taken'),
        _scheduled('b', '2026-10-13', 8, 'skipped'),
        _scheduled('c', '2026-10-12', 8, 'unrecorded'),
        _scheduled('d', '2026-10-11', 8, 'taken'),
      ]);
      ActivityDayState at(int i) => a.days[i].state;
      expect(at(13), ActivityDayState.taken);
      expect(at(12), ActivityDayState.skipped);
      expect(at(11), ActivityDayState.notRecorded);
      expect(at(10), ActivityDayState.taken);
      expect(at(9), ActivityDayState.none);
      expect(a.takenDays, 2);
      expect(a.dueDays, 4);
      expect(a.hasAnyRecord, isTrue);
    });

    test('a day with taken and unrecorded doses is partial', () {
      final a = _derive([
        _scheduled('a', '2026-10-13', 8, 'taken'),
        _scheduled('b', '2026-10-13', 20, 'unrecorded'),
        _scheduled('c', '2026-10-12', 8, 'taken'),
        _scheduled('d', '2026-10-12', 20, 'skipped'),
      ]);
      expect(a.days[12].state, ActivityDayState.partial);
      expect(a.days[12].taken, 1);
      expect(a.days[12].notRecorded, 1);
      expect(a.days[11].state, ActivityDayState.partial);
      expect(a.takenDays, 0);
      expect(a.dueDays, 2);
    });

    test('a recorded miss is missed, not unrecorded', () {
      final a = _derive([
        _scheduled('a', '2026-10-13', 8, 'missed'),
        _scheduled('b', '2026-10-12', 8, 'missed'),
        _scheduled('c', '2026-10-12', 20, 'unrecorded'),
        _scheduled('d', '2026-10-11', 8, 'missed'),
        _scheduled('e', '2026-10-11', 20, 'taken'),
      ]);
      expect(a.days[12].state, ActivityDayState.missed);
      expect(a.days[12].missed, 1);
      expect(a.days[12].notRecorded, 0);
      // Missed and the rest not recorded still reads as missed.
      expect(a.days[11].state, ActivityDayState.missed);
      expect(a.days[11].missed, 1);
      expect(a.days[11].notRecorded, 1);
      expect(a.days[10].state, ActivityDayState.partial);
      expect(a.dueDays, 3);
      expect(a.takenDays, 0);
      expect(a.recent.first.occurrenceId, 'a');
      expect(a.recent.first.status, 'missed');
    });

    test('reads the statuses the adherence calculator produces', () {
      // Built through the calculator so the two cannot drift apart on
      // status names again.
      AdherenceOccurrence occurrence(String id, String state, int day) =>
          AdherenceOccurrence(
            id: id,
            source: 'scheduled',
            expected: true,
            plannedAt: DateTime(2026, 10, day, 8),
            state: state,
            provenance: 'local',
            pillId: 'p1',
            pillName: 'Fevarin',
            profileId: 'u1',
            plannedLocalDate: '2026-10-$day',
          );
      final summary = const AdherenceCalculator().calculate(
        now: _now,
        occurrences: [
          occurrence('rec-miss', 'missed', 13),
          occurrence('no-record', 'pending', 13),
          occurrence('took', 'taken', 11),
        ],
        events: const [],
      );
      final a = _derive(summary.history);
      expect(a.days[12].missed, 1);
      expect(a.days[12].notRecorded, 1);
      expect(a.days[12].state, ActivityDayState.missed);
      expect(
        {for (final r in a.recent) r.occurrenceId: r.status},
        {'rec-miss': 'missed', 'no-record': 'unrecorded', 'took': 'taken'},
      );
    });

    test('doses later today leave today upcoming, not missing', () {
      final a = _derive([
        _scheduled('a', '2026-10-14', 23, 'pending'),
        _scheduled('b', '2026-10-13', 23, 'taken'),
      ]);
      expect(a.days.last.state, ActivityDayState.upcoming);
      expect(a.dueDays, 1);
      final mixed = _derive([
        _scheduled('a', '2026-10-14', 8, 'taken'),
        _scheduled('b', '2026-10-14', 23, 'pending'),
      ]);
      expect(mixed.days.last.state, ActivityDayState.taken);
    });

    test('ignores superseded doses, other medications and old days', () {
      final a = _derive([
        _scheduled('a', '2026-10-13', 8, 'unrecorded', superseded: true),
        _scheduled('b', '2026-10-13', 8, 'taken', pill: 'other'),
        _scheduled('c', '2026-09-01', 8, 'taken'),
      ]);
      expect(a.days[12].state, ActivityDayState.none);
      expect(a.takenDays, 0);
      // The old dose is still a record of this medication, just not in the 14.
      expect(a.hasAnyRecord, isTrue);
    });

    test('counts as-needed doses per day by when they were taken', () {
      final a = _derive([
        _prn('a', '2026-10-14', at: DateTime(2026, 10, 14, 7)),
        _prn('b', '2026-10-14', at: DateTime(2026, 10, 14, 15)),
        _prn('c', '2026-10-12', at: null),
        // Taken just after midnight: it belongs to the day it was taken.
        _prn('d', '2026-10-10', at: DateTime(2026, 10, 11, 0, 20)),
        _prn('e', '2026-10-13', status: 'pending'),
      ]);
      expect(a.days.last.asNeeded, 2);
      expect(a.days[11].asNeeded, 1);
      expect(a.days[10].asNeeded, 1);
      expect(a.days[9].asNeeded, 0);
      expect(a.days[11].state, ActivityDayState.none);
      expect(a.asNeededTotal, 4);
    });
  });

  group('recent', () {
    test('lists the latest past doses newest first, up to the limit', () {
      final a = medicationActivityFrom(
        items: [
          for (var d = 1; d <= 8; d++)
            _scheduled(
              's$d',
              '2026-10-0$d',
              8,
              d.isEven ? 'taken' : 'unrecorded',
            ),
          _scheduled('later', '2026-10-14', 23, 'pending'),
        ],
        pillId: 'p1',
        now: _now,
        recentLimit: 3,
      );
      expect(a.recent.map((r) => r.occurrenceId), ['s8', 's7', 's6']);
      expect(a.recent.map((r) => r.status), ['taken', 'unrecorded', 'taken']);
      expect(a.recent.every((r) => !r.asNeeded), isTrue);
      expect(a.recent.first.at, DateTime.parse('2026-10-08T08:00:00'));
    });

    test('mixes as-needed doses in by the time they were taken', () {
      final a = _derive([
        _scheduled('s', '2026-10-13', 8, 'taken'),
        _prn('p', '2026-10-13', at: DateTime(2026, 10, 13, 12, 5)),
        _prn('q', '2026-10-13'),
      ]);
      expect(a.recent.map((r) => r.occurrenceId), ['p', 's', 'q']);
      expect(a.recent.first.asNeeded, isTrue);
      expect(a.recent.first.timeKnown, isTrue);
      expect(a.recent.last.timeKnown, isFalse);
    });

    test('is empty when nothing was recorded', () {
      expect(_derive(const []).recent, isEmpty);
    });
  });

  group('list summary', () {
    StockEntry entry(
      String name, {
      bool asNeeded = false,
      int? stock,
      int? threshold,
      int? runsLowInDays,
    }) => (
      name: name,
      asNeeded: asNeeded,
      stock: stock,
      threshold: threshold,
      runsLowInDays: runsLowInDays,
    );

    test('counts scheduled and as-needed medications', () {
      final s = summarizeMedications([
        entry('A'),
        entry('B', asNeeded: true),
        entry('C', asNeeded: true),
      ]);
      expect(s.scheduled, 1);
      expect(s.asNeeded, 2);
      expect(s.status, StockStatus.untracked);
    });

    test('stock is fine when nothing runs low inside the heads-up days', () {
      final s = summarizeMedications([
        entry('A', stock: 150, threshold: 14, runsLowInDays: 200),
        entry('B', stock: 10),
      ]);
      expect(s.status, StockStatus.fine);
      expect(s.attention, isEmpty);
    });

    test('runs low soon when the forecast or the reminder level says so', () {
      final byForecast = summarizeMedications([
        entry('A', stock: 20, runsLowInDays: 6),
      ]);
      expect(byForecast.status, StockStatus.soon);
      expect(byForecast.attention, ['A']);
      final byLevel = summarizeMedications([
        entry('A', stock: 9, threshold: 10),
      ]);
      expect(byLevel.status, StockStatus.soon);
    });

    test('uses the same low-stock rule as Today: day 14 is low, 15 is not', () {
      final onTheLine = summarizeMedications([
        entry('A', stock: 20, runsLowInDays: lowStockHeadsUpDays),
      ]);
      expect(onTheLine.status, StockStatus.soon);
      final past = summarizeMedications([
        entry('A', stock: 20, runsLowInDays: lowStockHeadsUpDays + 1),
      ]);
      expect(past.status, StockStatus.fine);
    });

    test('out beats soon and lists the used-up medicine first', () {
      final s = summarizeMedications([
        entry('A', stock: 3, threshold: 5),
        entry('B', stock: 0),
        entry('C', stock: -2),
      ]);
      expect(s.status, StockStatus.out);
      expect(s.attention, ['B', 'C', 'A']);
    });
  });

  group('stock after saving', () {
    test('reads the typed count against the stored one', () {
      final a = stockAfterSaving(typed: '150', stored: 100, threshold: 14);
      expect(a.stock, 150);
      expect(a.changedBy, 50);
      expect(a.low, isFalse);
    });

    test('flags a low or used-up count', () {
      expect(
        stockAfterSaving(typed: '14', stored: 100, threshold: 14).low,
        isTrue,
      );
      expect(
        stockAfterSaving(typed: '0', stored: 100, threshold: null).low,
        isTrue,
      );
    });

    test('an empty or invalid field has no count', () {
      for (final typed in ['', '  ', 'abc', '1.5']) {
        final a = stockAfterSaving(typed: typed, stored: 10, threshold: 2);
        expect(a.stock, isNull, reason: typed);
        expect(a.changedBy, 0);
        expect(a.low, isFalse);
      }
    });

    test('a first count counts as no change', () {
      final a = stockAfterSaving(typed: '30', stored: null, threshold: null);
      expect(a.stock, 30);
      expect(a.changedBy, 0);
    });
  });
}
