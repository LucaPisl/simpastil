import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/dashboard/today_side/week_dots.dart';

final _at = DateTime.utc(2026, 10, 1);

MedicationOccurrence _row(
  String id,
  String date, {
  String state = 'pending',
  bool expected = true,
  String source = 'scheduled',
  DateTime? supersededAt,
}) => MedicationOccurrence(
  id: id,
  userId: 'u',
  scheduleId: 's',
  occurrenceKey: id,
  source: source,
  plannedLocalDate: date,
  plannedLocalTime: '08:00',
  timeZone: 'UTC',
  expected: expected,
  snapshotVersion: 1,
  scheduleSnapshotJson: '{}',
  provenance: 'exact',
  state: state,
  stateVersion: state == 'pending' ? 0 : 1,
  supersededAt: supersededAt,
  createdAt: _at,
  updatedAt: _at,
);

void main() {
  final friday = DateTime(2026, 10, 16);

  test('seven days ending on the selected day, oldest first', () {
    final dots = weekDotsFrom(
      selected: friday,
      today: friday,
      occurrences: const [],
    );
    expect(dots, hasLength(7));
    expect(dots.first.date, DateTime(2026, 10, 10));
    expect(dots.last.date, friday);
    expect(dots.last.selected, isTrue);
    expect(dots.where((d) => d.selected), hasLength(1));
    expect(dots.last.today, isTrue);
    expect(dots.first.today, isFalse);
    expect(dots.every((d) => d.state == WeekDotState.empty), isTrue);
  });

  test('the week crosses a month boundary', () {
    final dots = weekDotsFrom(
      selected: DateTime(2026, 11, 2),
      today: friday,
      occurrences: const [],
    );
    expect(dots.first.date, DateTime(2026, 10, 27));
    expect(dots.map((d) => d.today), everyElement(isFalse));
  });

  test('counts taken and skipped as recorded, pending as waiting', () {
    final dots = weekDotsFrom(
      selected: friday,
      today: friday,
      occurrences: [
        _row('a', '2026-10-16', state: 'taken'),
        _row('b', '2026-10-16'),
        _row('c', '2026-10-15', state: 'skipped'),
        _row('d', '2026-10-14', state: 'taken'),
        _row('e', '2026-10-14', state: 'taken'),
        _row('f', '2026-10-13'),
      ],
    );
    final byDay = {for (final d in dots) d.date.day: d};
    expect(byDay[16]!.recorded, 1);
    expect(byDay[16]!.expected, 2);
    expect(byDay[16]!.pending, 1);
    expect(byDay[16]!.state, WeekDotState.some);
    expect(byDay[15]!.state, WeekDotState.done);
    expect(byDay[14]!.recorded, 2);
    expect(byDay[14]!.state, WeekDotState.done);
    // Planned but nothing recorded stays an empty dot.
    expect(byDay[13]!.state, WeekDotState.empty);
    expect(byDay[13]!.expected, 1);
    expect(byDay[12]!.state, WeekDotState.empty);
  });

  test('an as-needed dose counts as recorded and never as waiting', () {
    final dots = weekDotsFrom(
      selected: friday,
      today: friday,
      occurrences: [
        _row(
          'p1',
          '2026-10-15',
          state: 'taken',
          source: 'prn',
          expected: false,
        ),
        _row('p2', '2026-10-16', source: 'prn', expected: false),
      ],
    );
    final byDay = {for (final d in dots) d.date.day: d};
    expect(byDay[15]!.recorded, 1);
    expect(byDay[15]!.expected, 0);
    expect(byDay[15]!.state, WeekDotState.done);
    // A pending as-needed row was never taken.
    expect(byDay[16]!.recorded, 0);
    expect(byDay[16]!.pending, 0);
    expect(byDay[16]!.state, WeekDotState.empty);
  });

  test('superseded rows and rows outside the week are ignored', () {
    final dots = weekDotsFrom(
      selected: friday,
      today: friday,
      occurrences: [
        _row('old', '2026-10-15', state: 'taken', supersededAt: _at),
        _row('far', '2026-10-01', state: 'taken'),
      ],
    );
    expect(dots.every((d) => d.recorded == 0), isTrue);
  });

  test('selecting an earlier day moves the whole week', () {
    final dots = weekDotsFrom(
      selected: DateTime(2026, 10, 12),
      today: friday,
      occurrences: [_row('a', '2026-10-12', state: 'taken')],
    );
    expect(dots.last.date, DateTime(2026, 10, 12));
    expect(dots.last.selected, isTrue);
    expect(dots.last.today, isFalse);
    expect(dots.last.recorded, 1);
  });

  test('a recorded miss is not recorded and keeps the day from done', () {
    final dots = weekDotsFrom(
      selected: friday,
      today: friday,
      occurrences: [
        _row('a', '2026-10-15', state: 'taken'),
        _row('b', '2026-10-15', state: 'missed'),
        _row('c', '2026-10-14', state: 'missed'),
      ],
    );
    final byDay = {for (final d in dots) d.date.day: d};
    expect(byDay[15]!.recorded, 1);
    expect(byDay[15]!.state, WeekDotState.some);
    expect(byDay[14]!.recorded, 0);
    expect(byDay[14]!.state, WeekDotState.empty);
  });
}
