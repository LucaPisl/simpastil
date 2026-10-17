import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/daos/medication_ledger_dao.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/adherence_calculator.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart'
    show localRoutineScheduleId;
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:timezone/data/latest.dart' as tzdata;

// ── Helpers ───────────────────────────────────────────────────────────────────

// A Thursday in the middle of the month, so month and week edges stay clear.
final _now = DateTime(2026, 10, 15, 21);
final _today = DateTime(2026, 10, 15);

String _key(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

DateTime _daysAgo(int days) =>
    DateTime(_today.year, _today.month, _today.day - days);

/// One history item. [status] is what the calculator reports: `taken`,
/// `skipped`, `missed` (a miss recorded in the ledger), `unrecorded` (due and
/// nobody recorded it) or `pending` (not due yet).
AdherenceHistoryItem _item(
  int daysAgo,
  String status, {
  bool prn = false,
  bool superseded = false,
  String? pillId = 'p1',
  String? pillName = 'Fevarin',
  DateTime? actualAt,
}) {
  final day = _daysAgo(daysAgo);
  return AdherenceHistoryItem(
    occurrenceId: 'o-$daysAgo-$status-${prn ? 'prn' : 's'}-${pillId ?? ''}',
    source: prn ? 'prn' : 'scheduled',
    expected: !prn,
    superseded: superseded,
    isDueScheduled: !prn && !superseded && status != 'pending',
    status: status,
    provenance: 'exact',
    plannedAt: prn ? null : DateTime(day.year, day.month, day.day, 8),
    actualAt: actualAt,
    actualTimeKnown: actualAt != null,
    note: null,
    pillId: pillId,
    pillName: pillName,
    dosage: null,
    profileId: 'a',
    plannedLocalDate: _key(day),
  );
}

DayStreak _streak(List<AdherenceHistoryItem> items, {int window = 84}) =>
    computeDayStreak(items, today: _today, windowDays: window);

final _at = DateTime(2026, 10, 15, 12);

/// A scheduled or as-needed occurrence with, when taken, one event at [actual].
MedicationOccurrenceRecord _record(
  String id,
  int daysAgo, {
  String state = 'taken',
  bool prn = false,
  String pillId = 'p1',
  String pillName = 'Fevarin',
  DateTime? actual,
  bool timeKnown = true,
  bool superseded = false,
  String? scheduleId,
}) {
  final day = _daysAgo(daysAgo);
  final occurrence = MedicationOccurrence(
    id: id,
    userId: 'u',
    pillId: pillId,
    scheduleId: scheduleId,
    occurrenceKey: id,
    source: prn ? 'prn' : 'scheduled',
    plannedLocalDate: _key(day),
    plannedLocalTime: prn ? null : '08:00:00',
    timeZone: 'UTC',
    plannedAt: prn ? null : DateTime(day.year, day.month, day.day, 8),
    expected: !prn,
    snapshotVersion: 1,
    scheduleSnapshotJson:
        '{"version":1,"pillName":"$pillName","dosage":null,'
        '"frequency":"daily","frequencyDays":null,"hour":8,"minute":0,'
        '"timeZone":"UTC","profileId":"a","profileName":"Ana"}',
    provenance: 'exact',
    state: state,
    stateVersion: state == 'pending' ? 0 : 1,
    supersededAt: superseded ? _at : null,
    createdAt: _at,
    updatedAt: _at,
  );
  return MedicationOccurrenceRecord(
    occurrence: occurrence,
    events: [
      if (state != 'pending')
        OccurrenceEvent(
          id: 'e-$id',
          userId: 'u',
          occurrenceId: id,
          commandId: 'c-$id',
          action: state == 'taken' ? 'take' : 'skip',
          fromState: 'pending',
          toState: state,
          actualAt: timeKnown ? actual : null,
          actualTimeKnown: timeKnown && actual != null,
          origin: 'native',
          baseVersion: 0,
          resultVersion: 1,
          recordedAt: _at,
        ),
    ],
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// One version of a daily 08:00 UTC routine for pill `p1`, in force from
/// [from]. Its slot id is `morning`.
LocalRoutine _routine({
  String id = 'r1',
  int revision = 1,
  required DateTime from,
  String pillId = 'p1',
  int hour = 8,
}) => LocalRoutine(
  routineId: id,
  revision: revision,
  workspaceId: 'w',
  authorId: 'a',
  pillId: pillId,
  effectiveFromMillis: from.millisecondsSinceEpoch,
  definitionJson: jsonEncode(
    RoutineDefinition(
      kind: RoutineKind.daily,
      timeZone: 'UTC',
      amount: const MedicationAmount.unknown(),
      times: [RoutineTime(slotId: 'morning', hour: hour, minute: 0)],
    ).toJson(),
  ),
  createdAt: from,
);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('computeDayStreak', () {
    test('a recorded miss breaks the streak like an unrecorded dose', () {
      for (final status in ['missed', 'unrecorded']) {
        final streak = _streak([
          _item(0, 'taken'),
          _item(1, 'taken'),
          _item(2, status),
          _item(3, 'taken'),
          _item(4, 'taken'),
          _item(5, 'taken'),
        ]);
        expect(streak, (current: 2, best: 3), reason: status);
      }
    });

    test('a recorded miss today neither counts nor breaks, as unrecorded', () {
      for (final status in ['missed', 'unrecorded']) {
        final streak = _streak([
          _item(0, status),
          _item(1, 'taken'),
          _item(2, 'taken'),
        ]);
        expect(streak, (current: 2, best: 2), reason: status);
      }
    });

    test('a miss taken late no longer breaks the streak', () {
      // Taking it late turns the status to taken.
      final streak = _streak([for (var d = 0; d < 3; d++) _item(d, 'taken')]);
      expect(streak, (current: 3, best: 3));
    });

    test('counts consecutive complete days including today', () {
      final streak = _streak([for (var d = 0; d < 5; d++) _item(d, 'taken')]);
      expect(streak, (current: 5, best: 5));
    });

    test('a day needs every due dose taken, not just one', () {
      final streak = _streak([
        _item(0, 'taken'),
        _item(1, 'taken'),
        _item(1, 'missed', pillId: 'p2'),
        _item(2, 'taken'),
      ]);
      // Yesterday had two doses and one was missed: only today counts.
      expect(streak, (current: 1, best: 1));
    });

    test('today with doses still outstanding neither counts nor breaks', () {
      final streak = _streak([
        _item(0, 'taken'),
        _item(0, 'missed', pillId: 'p2'), // due earlier today, not recorded
        _item(1, 'taken'),
        _item(2, 'taken'),
      ]);
      expect(streak, (current: 2, best: 2));
    });

    test('a dose skipped on purpose is neutral, today or any past day', () {
      // Today was skipped: nothing is asked of it, so yesterday's run stands.
      expect(
        _streak([_item(0, 'skipped'), _item(1, 'taken'), _item(2, 'taken')]),
        (current: 2, best: 2),
      );
      // A skipped day in the middle neither counts nor breaks the run.
      expect(
        _streak([
          _item(0, 'taken'),
          _item(1, 'skipped'),
          _item(2, 'taken'),
          _item(3, 'taken'),
          _item(4, 'taken'),
        ]),
        (current: 4, best: 4),
      );
    });

    test('on a day with two doses, a skipped one leaves the other to take', () {
      final taken = _streak([
        _item(1, 'taken'),
        _item(1, 'skipped', pillId: 'p2'),
        _item(2, 'taken'),
      ]);
      expect(taken, (current: 2, best: 2));
      final missed = _streak([
        _item(1, 'missed'),
        _item(1, 'skipped', pillId: 'p2'),
        _item(2, 'taken'),
      ]);
      expect(missed, (current: 0, best: 1));
    });

    test('a missed day resets the current streak but not the best one', () {
      final streak = _streak([
        for (var d = 0; d <= 2; d++) _item(d, 'taken'),
        _item(3, 'missed'),
        for (var d = 4; d <= 8; d++) _item(d, 'taken'),
      ]);
      expect(streak, (current: 3, best: 5));
    });

    test('days with no scheduled dose are neutral', () {
      // Every other day: nothing is due on days 1 and 3.
      final streak = _streak([
        _item(0, 'taken'),
        _item(2, 'taken'),
        _item(4, 'taken'),
      ]);
      expect(streak, (current: 3, best: 3));
    });

    test('days the history knows nothing about are neutral by themselves', () {
      final streak = _streak([_item(0, 'taken'), _item(6, 'taken')]);
      expect(streak, (current: 2, best: 2));
    });

    test('a day the routine owed a dose with no record breaks the streak', () {
      final history = [
        _item(0, 'taken'),
        _item(1, 'taken'),
        _item(5, 'taken'),
        _item(6, 'taken'),
        _item(7, 'taken'),
      ];
      // Days 2 to 4 have no rows at all; the routine says doses fell due.
      expect(
        computeDayStreak(
          history,
          today: _today,
          unrecordedDays: {for (var d = 2; d <= 4; d++) _key(_daysAgo(d))},
        ),
        (current: 2, best: 3),
      );
      // Without that knowledge the gap is invisible and the run looks whole.
      expect(_streak(history), (current: 5, best: 5));
    });

    test('an unrecorded day breaks it even when other doses were taken', () {
      final streak = computeDayStreak(
        [_item(0, 'taken'), _item(1, 'taken'), _item(2, 'taken')],
        today: _today,
        unrecordedDays: {_key(_daysAgo(1))},
      );
      expect(streak, (current: 1, best: 1));
    });

    test('is zero, not an error, when nothing was ever scheduled', () {
      expect(_streak(const []), (current: 0, best: 0));
    });

    test('as-needed doses are not part of it', () {
      final streak = _streak([
        _item(0, 'taken', prn: true),
        _item(1, 'taken', prn: true),
      ]);
      expect(streak, (current: 0, best: 0));
    });

    test('doses not yet due and superseded doses are ignored', () {
      final streak = _streak([
        _item(0, 'taken'),
        _item(0, 'pending', pillId: 'later'), // 20:00, still ahead
        _item(1, 'taken'),
        _item(1, 'missed', pillId: 'old', superseded: true),
      ]);
      expect(streak, (current: 2, best: 2));
    });

    test('reads only the window', () {
      final items = [for (var d = 0; d < 10; d++) _item(d, 'taken')];
      expect(_streak(items, window: 4), (current: 4, best: 4));
      expect(_streak(items), (current: 10, best: 10));
    });

    test('a streak that stopped growing stays until a dose is missed', () {
      // Yesterday and the day before were complete, today has no dose due yet.
      final streak = _streak([_item(1, 'taken'), _item(2, 'taken')]);
      expect(streak, (current: 2, best: 2));
    });
  });

  group('unrecordedRoutineDays', () {
    final routineStart = DateTime.utc(2026, 10, 1);
    final slot = localRoutineScheduleId('r1', 'morning');

    test('names the due days with no occurrence row, never today', () {
      final days = unrecordedRoutineDays(
        [_routine(from: routineStart)],
        [_record('a', 1, scheduleId: slot), _record('b', 2, scheduleId: slot)],
        now: _now,
      );
      // 1 to 12 October have nothing; the 13th and 14th have rows; today
      // (the 15th) is still open.
      expect(days, {
        for (var d = 1; d <= 12; d++) '2026-10-${d.toString().padLeft(2, '0')}',
      });
    });

    test('any row covers its slot, whatever its state', () {
      final days = unrecordedRoutineDays(
        [_routine(from: routineStart)],
        [
          for (var d = 1; d <= 14; d++)
            _record(
              'r$d',
              15 - d,
              scheduleId: slot,
              state: d.isEven ? 'skipped' : 'pending',
              superseded: d == 3,
            ),
        ],
        now: _now,
      );
      expect(days, isEmpty);
    });

    test('a dose not yet due, or before the routine began, is not owed', () {
      expect(
        unrecordedRoutineDays(
          [_routine(from: DateTime.utc(2026, 10, 14, 9))],
          const [],
          now: _now,
        ),
        // The 14th at 08:00 is before the routine took effect.
        isEmpty,
      );
      expect(
        unrecordedRoutineDays(
          [_routine(from: routineStart, hour: 23)],
          [_record('x', 1, scheduleId: slot)],
          now: DateTime.utc(2026, 10, 3, 12),
        ),
        // Only 1 and 2 October fall due before the 3rd; the 2nd's 23:00 dose
        // is owed and unrecorded, the 1st too.
        {'2026-10-01', '2026-10-02'},
      );
    });

    test('follows the version in force when a routine was changed', () {
      final days = unrecordedRoutineDays(
        [
          _routine(from: routineStart),
          _routine(revision: 2, from: DateTime.utc(2026, 10, 10)),
        ],
        [
          for (var d = 10; d <= 14; d++)
            _record('n$d', 15 - d, scheduleId: slot),
        ],
        now: _now,
      );
      expect(days, {for (var d = 1; d <= 9; d++) '2026-10-0$d'});
    });

    test('reads only the window', () {
      final days = unrecordedRoutineDays(
        [_routine(from: DateTime.utc(2026, 9, 1))],
        const [],
        now: _now,
        windowDays: 3,
      );
      // Three days are the 13th, the 14th and today; today is never listed.
      expect(days, {'2026-10-13', '2026-10-14'});
    });
  });

  group('computeTrendStatsFromOccurrences', () {
    test('counts doses by the local hour they were taken', () {
      final stats = computeTrendStatsFromOccurrences(
        now: _now,
        records: [
          _record('a', 0, actual: DateTime(2026, 10, 15, 8, 5)),
          _record('b', 1, actual: DateTime(2026, 10, 14, 8, 55)),
          _record('c', 2, prn: true, actual: DateTime(2026, 10, 13, 22, 35)),
        ],
      );
      expect(stats.hourlyTaken, hasLength(24));
      expect(stats.hourlyTaken[8], 2);
      expect(stats.hourlyTaken[22], 1);
      expect(stats.hourlyTaken.fold<int>(0, (a, b) => a + b), 3);
    });

    test('leaves out doses with no known time, skips and old doses', () {
      final stats = computeTrendStatsFromOccurrences(
        now: _now,
        records: [
          _record('a', 0, actual: DateTime(2026, 10, 15, 8), timeKnown: false),
          _record('b', 1, state: 'skipped', actual: DateTime(2026, 10, 14, 9)),
          _record('c', 30, actual: DateTime(2026, 9, 15, 10)), // 31 days back
          _record('d', 29, actual: DateTime(2026, 9, 16, 11)), // last day in
          _record('e', 3, actual: DateTime(2026, 10, 12, 12), superseded: true),
        ],
      );
      expect(stats.hourlyTaken[8], 0);
      expect(stats.hourlyTaken[9], 0);
      expect(stats.hourlyTaken[10], 0);
      expect(stats.hourlyTaken[11], 1);
      expect(stats.hourlyTaken[12], 0);
    });

    test('counts as-needed doses per medication, most used first', () {
      final stats = computeTrendStatsFromOccurrences(
        now: _now,
        records: [
          for (var i = 0; i < 3; i++)
            _record(
              'x$i',
              i,
              prn: true,
              pillId: 'pf',
              pillName: 'Pastila ficat',
              actual: DateTime(2026, 10, 15 - i, 22),
            ),
          for (var i = 0; i < 3; i++)
            _record(
              'm$i',
              i + 10,
              prn: true,
              pillId: 'pm',
              pillName: 'Melatonina',
              actual: DateTime(2026, 10, 5 - i, 23),
            ),
          _record(
            'n0',
            4,
            prn: true,
            pillId: 'pa',
            pillName: 'Algocalmin',
            actual: DateTime(2026, 10, 11, 9),
          ),
          // Never taken, undone, superseded or older than 30 days: not counted.
          _record('u0', 1, state: 'pending', prn: true, pillId: 'pu'),
          _record('s0', 1, prn: true, pillId: 'ps', superseded: true),
          _record('o0', 40, prn: true, pillId: 'po'),
          // Scheduled doses are not as-needed doses.
          _record('sch', 1),
        ],
      );
      expect(stats.prnByPill.map((p) => (p.pillName, p.count)), [
        ('Melatonina', 3),
        ('Pastila ficat', 3),
        ('Algocalmin', 1),
      ]);
      expect(stats.prn30Days, 7);
      expect(stats.prn7Days, 4); // three Pastila ficat in 3 days + Algocalmin
    });

    test('carries the day streak and whether anything was due', () {
      final withDoses = computeTrendStatsFromOccurrences(
        now: _now,
        records: [
          _record('a', 0, actual: DateTime(2026, 10, 15, 8)),
          _record('b', 1, actual: DateTime(2026, 10, 14, 8)),
        ],
      );
      expect(withDoses.streak, (current: 2, best: 2));
      expect(withDoses.hasScheduledDoses, isTrue);

      final onlyPrn = computeTrendStatsFromOccurrences(
        now: _now,
        records: [
          _record('p', 0, prn: true, actual: DateTime(2026, 10, 15, 8)),
        ],
      );
      expect(onlyPrn.hasScheduledDoses, isFalse);
      expect(onlyPrn.streak, (current: 0, best: 0));

      // A routine that owed doses with no rows is a scheduled history too.
      final onlyGaps = computeTrendStatsFromOccurrences(
        now: _now,
        records: [],
        unrecordedDays: {'2026-10-12'},
      );
      expect(onlyGaps.hasScheduledDoses, isTrue);
      expect(onlyGaps.streak, (current: 0, best: 0));

      final empty = computeTrendStatsFromOccurrences(now: _now, records: []);
      expect(empty.hasScheduledDoses, isFalse);
      expect(empty.hourlyTaken, everyElement(0));
      expect(empty.prnByPill, isEmpty);
    });
  });

  group('month summary', () {
    final october = DateTime(2026, 10);

    test('counts as-needed doses taken on each day of the month', () {
      final counts = monthPrnCountsFromOccurrences(
        month: october,
        records: [
          _record('a', 0, prn: true, actual: DateTime(2026, 10, 15, 22)),
          _record('b', 0, prn: true, actual: DateTime(2026, 10, 15, 23)),
          _record('c', 2, prn: true, actual: DateTime(2026, 10, 13, 9)),
          _record('d', 20, prn: true, actual: DateTime(2026, 9, 25, 9)),
          _record('e', 1, prn: true, state: 'pending'),
          _record('f', 1, prn: true, superseded: true),
          _record('g', 1), // scheduled
        ],
      );
      expect(counts, {DateTime(2026, 10, 15): 2, DateTime(2026, 10, 13): 1});
    });

    test('adds up the days: recorded counts taken and skipped', () {
      final summary = summarizeMonth(
        {
          DateTime(2026, 10, 1): (taken: 2, skipped: 0, missed: 0, expected: 2),
          // A recorded miss is due but is not something a person recorded.
          DateTime(2026, 10, 2): (taken: 1, skipped: 1, missed: 1, expected: 3),
          DateTime(2026, 10, 3): (taken: 0, skipped: 0, missed: 0, expected: 0),
        },
        {DateTime(2026, 10, 2): 1, DateTime(2026, 10, 3): 2},
      );
      expect(summary, (
        recorded: 4,
        expected: 5,
        taken: 3,
        skipped: 1,
        prnTaken: 3,
      ));
    });

    test('an empty month is all zeros', () {
      expect(summarizeMonth(const {}, const {}), (
        recorded: 0,
        expected: 0,
        taken: 0,
        skipped: 0,
        prnTaken: 0,
      ));
    });
  });
}
