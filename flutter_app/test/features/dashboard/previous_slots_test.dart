import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/dashboard/previous_slots.dart';

final _at = DateTime.utc(2026, 10, 1);

MedicationOccurrence _row(
  String id,
  String date, {
  String schedule = 'slot-a',
  String time = '23:00',
  String state = 'pending',
  int version = 0,
  bool expected = true,
  String source = 'scheduled',
  DateTime? supersededAt,
}) => MedicationOccurrence(
  id: id,
  userId: 'u',
  scheduleId: schedule,
  occurrenceKey: id,
  source: source,
  plannedLocalDate: date,
  plannedLocalTime: time,
  timeZone: 'UTC',
  plannedAt: DateTime.utc(
    int.parse(date.substring(0, 4)),
    int.parse(date.substring(5, 7)),
    int.parse(date.substring(8, 10)),
    int.parse(time.substring(0, 2)),
    int.parse(time.substring(3, 5)),
  ),
  expected: expected,
  snapshotVersion: 1,
  scheduleSnapshotJson: '{}',
  provenance: 'exact',
  state: state,
  stateVersion: version,
  supersededAt: supersededAt,
  createdAt: _at,
  updatedAt: _at,
);

OccurrenceEvent _event(
  String id,
  String occurrence,
  int result, {
  String to = 'taken',
  DateTime? actualAt,
  bool known = true,
  String? serverId,
  String? command,
}) => OccurrenceEvent(
  id: id,
  serverId: serverId,
  userId: 'u',
  occurrenceId: occurrence,
  commandId: command ?? 'cmd-$id',
  action: to == 'skipped' ? 'skip' : 'take',
  fromState: 'pending',
  toState: to,
  actualAt: actualAt,
  actualTimeKnown: known && actualAt != null,
  origin: 'native',
  baseVersion: result - 1,
  resultVersion: result,
  recordedAt: _at,
);

void main() {
  group('previousSlotOccurrences', () {
    final current = _row('now', '2026-10-16');

    test('lists the same slot before the current one, oldest first', () {
      final rows = previousSlotOccurrences(
        current: current,
        sameSchedule: [
          _row('d15', '2026-10-15'),
          _row('now', '2026-10-16'),
          _row('d13', '2026-10-13'),
          _row('d14', '2026-10-14'),
          _row('later', '2026-10-17'),
        ],
      );
      expect(rows.map((r) => r.id), ['d13', 'd14', 'd15']);
    });

    test('keeps only the last six', () {
      final rows = previousSlotOccurrences(
        current: current,
        sameSchedule: [
          for (var day = 1; day <= 12; day++)
            _row('d$day', '2026-10-${day.toString().padLeft(2, '0')}'),
        ],
      );
      expect(rows.map((r) => r.id), ['d7', 'd8', 'd9', 'd10', 'd11', 'd12']);
    });

    test('honours a smaller limit', () {
      final rows = previousSlotOccurrences(
        current: current,
        sameSchedule: [_row('d14', '2026-10-14'), _row('d15', '2026-10-15')],
        limit: 1,
      );
      expect(rows.map((r) => r.id), ['d15']);
    });

    test('leaves out other slots, superseded, not due and as-needed rows', () {
      final rows = previousSlotOccurrences(
        current: current,
        sameSchedule: [
          _row('other', '2026-10-15', schedule: 'slot-b'),
          _row('old', '2026-10-14', supersededAt: _at),
          _row('extra', '2026-10-13', expected: false),
          _row('prn', '2026-10-12', source: 'prn', expected: false),
          _row('keep', '2026-10-11'),
        ],
      );
      expect(rows.map((r) => r.id), ['keep']);
    });

    test('a slot earlier the same day still counts as previous', () {
      final noon = _row('noon', '2026-10-16', time: '12:00');
      final rows = previousSlotOccurrences(
        current: current,
        sameSchedule: [noon, current],
      );
      // Same schedule id on the same day is an earlier time of that slot.
      expect(rows.map((r) => r.id), ['noon']);
    });

    test('is empty without a schedule or for an as-needed dose', () {
      final loose = MedicationOccurrence(
        id: 'loose',
        userId: 'u',
        occurrenceKey: 'loose',
        source: 'legacy',
        plannedLocalDate: '2026-10-16',
        timeZone: 'UTC',
        expected: true,
        snapshotVersion: 1,
        scheduleSnapshotJson: '{}',
        provenance: 'exact',
        state: 'pending',
        stateVersion: 0,
        createdAt: _at,
        updatedAt: _at,
      );
      expect(
        previousSlotOccurrences(
          current: loose,
          sameSchedule: [_row('d15', '2026-10-15')],
        ),
        isEmpty,
      );
      expect(
        previousSlotOccurrences(
          current: _row('p', '2026-10-16', source: 'prn', expected: false),
          sameSchedule: [_row('d15', '2026-10-15')],
        ),
        isEmpty,
      );
    });
  });

  group('previousSlotsFrom', () {
    test('reads the state and the time a taken dose was taken', () {
      final taken = _row('d15', '2026-10-15', state: 'taken', version: 1);
      final skipped = _row('d14', '2026-10-14', state: 'skipped', version: 1);
      final open = _row('d13', '2026-10-13');
      final slots = previousSlotsFrom(
        occurrences: [open, skipped, taken],
        eventsOf: {
          'd15': [
            _event(
              'e1',
              'd15',
              1,
              actualAt: DateTime.utc(2026, 10, 15, 23, 20),
            ),
          ],
          'd14': [_event('e2', 'd14', 1, to: 'skipped')],
        },
      );
      expect(slots.map((s) => s.occurrenceId), ['d13', 'd14', 'd15']);
      expect(slots.map((s) => s.state), ['pending', 'skipped', 'taken']);
      expect(slots[0].actualAt, isNull);
      expect(slots[1].actualAt, isNull);
      expect(slots[2].actualAt, DateTime.utc(2026, 10, 15, 23, 20));
      expect(slots[2].taken, isTrue);
      expect(slots[0].localDate, '2026-10-13');
      expect(slots[0].plannedLocalTime, '23:00');
    });

    test('a taken dose recorded without a time has no time', () {
      final taken = _row('d15', '2026-10-15', state: 'taken', version: 1);
      final slots = previousSlotsFrom(
        occurrences: [taken],
        eventsOf: {
          'd15': [
            _event(
              'e1',
              'd15',
              1,
              actualAt: DateTime.utc(2026, 10, 15, 23),
              known: false,
            ),
          ],
        },
      );
      expect(slots.single.state, 'taken');
      expect(slots.single.actualAt, isNull);
    });

    test('an undone dose reads as not recorded and keeps no time', () {
      final undone = _row('d15', '2026-10-15', version: 2);
      final slots = previousSlotsFrom(
        occurrences: [undone],
        eventsOf: {
          'd15': [
            _event('e1', 'd15', 1, actualAt: DateTime.utc(2026, 10, 15, 23)),
            _event('e2', 'd15', 2, to: 'pending'),
          ],
        },
      );
      expect(slots.single.state, 'pending');
      expect(slots.single.actualAt, isNull);
    });

    test('a discarded unsent event does not compete for the head', () {
      final taken = _row('d15', '2026-10-15', state: 'taken', version: 1);
      final slots = previousSlotsFrom(
        occurrences: [taken],
        eventsOf: {
          'd15': [
            _event(
              'e1',
              'd15',
              1,
              actualAt: DateTime.utc(2026, 10, 15, 22),
              command: 'gone',
            ),
            _event(
              'e2',
              'd15',
              1,
              actualAt: DateTime.utc(2026, 10, 15, 23),
              serverId: 's2',
              command: 'kept',
            ),
          ],
        },
        discardedCommandIds: {'gone'},
      );
      expect(slots.single.actualAt, DateTime.utc(2026, 10, 15, 23));
    });

    test('two competing heads give no time instead of a wrong one', () {
      final taken = _row('d15', '2026-10-15', state: 'taken', version: 1);
      final slots = previousSlotsFrom(
        occurrences: [taken],
        eventsOf: {
          'd15': [
            _event('e1', 'd15', 1, actualAt: DateTime.utc(2026, 10, 15, 22)),
            _event('e2', 'd15', 1, actualAt: DateTime.utc(2026, 10, 15, 23)),
          ],
        },
      );
      expect(slots.single.state, 'taken');
      expect(slots.single.actualAt, isNull);
    });

    test('a row with no events at all still lists its state', () {
      final slots = previousSlotsFrom(
        occurrences: [_row('d15', '2026-10-15', state: 'taken', version: 1)],
        eventsOf: const {},
      );
      expect(slots.single.state, 'taken');
      expect(slots.single.actualAt, isNull);
    });
  });
}
