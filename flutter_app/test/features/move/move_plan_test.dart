import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/features/move/move_ids.dart';
import 'package:simpastil/features/move/move_plan.dart';
import 'package:timezone/data/latest.dart' as tzdata;

final _now = DateTime.utc(2026, 10, 22, 12);

RoutineDefinition _daily(
  List<RoutineTime> times, {
  String? startDate,
  String? endDate,
}) => RoutineDefinition(
  kind: RoutineKind.daily,
  timeZone: 'Etc/UTC',
  times: times,
  startDate: startDate,
  endDate: endDate,
);

RoutineTime _slot(String id, int hour) =>
    RoutineTime(slotId: id, hour: hour, minute: 0);

LocalRoutine _version(int revision, DateTime from, RoutineDefinition d) =>
    LocalRoutine(
      routineId: 'routine-1',
      revision: revision,
      workspaceId: 'local',
      authorId: 'author',
      pillId: 'pill-1',
      effectiveFromMillis: from.millisecondsSinceEpoch,
      definitionJson: jsonEncode(d.toJson()),
      createdAt: from,
    );

MedicationOccurrence _occurrence(String state) => MedicationOccurrence(
  id: 'occ-1',
  userId: 'local-owner',
  pillId: 'pill-1',
  scheduleId: 'routine-1',
  occurrenceKey: 'key',
  source: 'scheduled',
  plannedLocalDate: '2026-10-20',
  plannedLocalTime: '08:00:00',
  timeZone: 'Etc/UTC',
  plannedAt: DateTime.utc(2026, 10, 20, 8),
  expected: true,
  snapshotVersion: 2,
  scheduleSnapshotJson: '{}',
  provenance: 'local',
  state: state,
  stateVersion: 1,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 20),
);

OccurrenceEvent _event(
  String id,
  String toState,
  int resultVersion, {
  DateTime? actualAt,
  String? note,
  String? amountJson,
  String? recordedByJson,
}) => OccurrenceEvent(
  id: id,
  userId: 'local-owner',
  occurrenceId: 'occ-1',
  commandId: 'cmd-$id',
  action: toState == 'pending' ? 'undo' : 'take',
  fromState: 'pending',
  toState: toState,
  actualAt: actualAt,
  actualTimeKnown: actualAt != null,
  note: note,
  administrationAmountJson: amountJson,
  recordedByJson: recordedByJson,
  origin: 'local',
  baseVersion: resultVersion - 1,
  resultVersion: resultVersion,
  recordedAt: DateTime.utc(2026, 10, 20, 9),
);

String _amount(String quantity, String unit) =>
    jsonEncode(MedicationAmount.known(quantity, unit).toJson());

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('moveShapeFor', () {
    test('keeps daily and weekday routines in the shapes old servers read', () {
      expect(
        moveShapeFor(_daily([_slot('a', 8)])),
        const MoveShape(frequency: 'daily'),
      );
      RoutineDefinition weekdays(List<int> days) => RoutineDefinition(
        kind: RoutineKind.weekdays,
        timeZone: 'Etc/UTC',
        times: [_slot('a', 8)],
        weekdays: days,
      );
      expect(
        moveShapeFor(weekdays([1, 2, 3, 4, 5, 6, 7])),
        const MoveShape(frequency: 'daily'),
      );
      expect(
        moveShapeFor(weekdays([3])),
        const MoveShape(frequency: 'weekly', frequencyDays: [3]),
      );
      final custom = moveShapeFor(weekdays([5, 1]));
      expect(custom.frequency, 'custom');
      expect(custom.frequencyDays, [1, 5]);
      expect(custom.needsWindows, isFalse);
    });

    test('an every-day interval becomes daily from its first day', () {
      final shape = moveShapeFor(
        RoutineDefinition(
          kind: RoutineKind.interval,
          timeZone: 'Etc/UTC',
          times: [_slot('a', 8)],
          everyDays: 1,
          anchorDate: '2026-11-03',
          startDate: '2026-11-01',
        ),
      );
      expect(
        shape,
        const MoveShape(frequency: 'daily', startDate: '2026-11-03'),
      );
    });

    test('a longer interval and a date window need schedule windows', () {
      final shape = moveShapeFor(
        RoutineDefinition(
          kind: RoutineKind.interval,
          timeZone: 'Etc/UTC',
          times: [_slot('a', 8)],
          everyDays: 3,
          anchorDate: '2026-10-01',
          endDate: '2026-12-31',
        ),
      );
      expect(shape.frequency, 'interval');
      expect(shape.everyDays, 3);
      expect(shape.anchorDate, '2026-10-01');
      expect(shape.endDate, '2026-12-31');
      expect(shape.needsWindows, isTrue);
    });

    test('an as-needed routine has no schedule', () {
      expect(
        () => moveShapeFor(
          RoutineDefinition(
            kind: RoutineKind.prn,
            timeZone: 'Etc/UTC',
            times: const [],
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('moveSchedulesFor', () {
    test('a routine in force since the past adds no start date', () {
      final schedules = moveSchedulesFor('pill-1', [
        _version(1, DateTime.utc(2026, 10, 1), _daily([_slot('a', 8)])),
      ], _now);
      expect(schedules, hasLength(1));
      final schedule = schedules.single;
      expect(schedule.revision, isNull);
      expect(schedule.isActive, isTrue);
      expect(schedule.shape, const MoveShape(frequency: 'daily'));
      expect(schedule.shape.needsWindows, isFalse);
    });

    test('a later version takes over on the first dose after it starts', () {
      final schedules = moveSchedulesFor('pill-1', [
        _version(1, DateTime.utc(2026, 10, 1), _daily([_slot('a', 8)])),
        _version(2, DateTime.utc(2026, 10, 25, 10), _daily([_slot('a', 9)])),
      ], _now);
      expect(schedules, hasLength(2));
      final now = schedules[0];
      final later = schedules[1];
      // The 08:00 dose on the 25th comes before the change at 10:00.
      expect(now.revision, isNull);
      expect(now.shape.endDate, '2026-10-25');
      expect(now.isActive, isTrue);
      // The 09:00 dose on the 25th is already past the change.
      expect(later.revision, 2);
      expect(later.hour, 9);
      expect(later.shape.startDate, '2026-10-26');
      expect(later.isActive, isTrue);
      expect(now.covers('2026-10-25'), isTrue);
      expect(now.covers('2026-10-26'), isFalse);
      expect(later.covers('2026-10-25'), isFalse);
    });

    test('a slot only older versions had keeps an inactive schedule', () {
      final schedules = moveSchedulesFor('pill-1', [
        _version(
          1,
          DateTime.utc(2026, 9, 1),
          _daily([_slot('a', 8), _slot('b', 20)]),
        ),
        _version(2, DateTime.utc(2026, 10, 1), _daily([_slot('a', 8)])),
      ], _now);
      expect(schedules.map((s) => (s.slotId, s.isActive, s.revision)), [
        ('a', true, null),
        ('b', false, null),
      ]);
      expect(schedules[1].hour, 20);
      expect(schedules[1].shape.needsWindows, isFalse);
    });

    test('an ended routine stays for its history without dates', () {
      final schedule = moveSchedulesFor('pill-1', [
        _version(
          1,
          DateTime.utc(2026, 10, 1),
          _daily([_slot('a', 8)], endDate: '2026-10-20'),
        ),
      ], _now).single;
      expect(schedule.isActive, isFalse);
      expect(schedule.shape, const MoveShape(frequency: 'daily'));
    });

    test('a routine that starts later keeps its own start date', () {
      final schedule = moveSchedulesFor('pill-1', [
        _version(
          1,
          DateTime.utc(2026, 10, 1),
          _daily([_slot('a', 8)], startDate: '2026-11-01'),
        ),
      ], _now).single;
      expect(schedule.isActive, isTrue);
      expect(schedule.shape.startDate, '2026-11-01');
      expect(schedule.shape.needsWindows, isTrue);
    });
  });

  group('moveFinalState', () {
    test('a dose nobody recorded copies as not recorded', () {
      expect(moveFinalState(_occurrence('pending'), const [], const {}), null);
    });

    test('a take copies the entry that put the dose there', () {
      final taken = DateTime.utc(2026, 10, 20, 8, 15);
      final state = moveFinalState(_occurrence('taken'), [
        _event('e1', 'taken', 1, amountJson: _amount('1', 'tablet')),
        _event('e2', 'pending', 2),
        _event(
          'e3',
          'taken',
          3,
          actualAt: taken,
          note: 'with food',
          amountJson: _amount('2', 'tablet'),
        ),
      ], const {})!;
      expect(state.action, MedicationAction.take);
      expect(state.actualAt, taken);
      expect(state.actualTimeKnown, isTrue);
      expect(state.note, 'with food');
      expect(state.amount.quantityText, '2');
    });

    test('a copied dose keeps its original author, never the mover', () {
      CareEventDetail details(String? name) => CareEventDetail(
        eventId: 'e1',
        workspaceId: 'ws',
        commandId: 'cmd-e1',
        authorId: 'author-1',
        authorName: name,
        amountJson: _amount('1', 'tablet'),
        commandJson: '{}',
        requestFingerprint: 'fp',
        stockOutcome: 'notTracked',
      );
      final events = [_event('e1', 'taken', 1)];
      // This phone's own record names the author.
      expect(
        moveFinalState(_occurrence('taken'), events, {
          'e1': details('Mama'),
        })!.authorName,
        'Mama',
      );
      // A name pulled from the account is kept when no local record exists.
      expect(
        moveFinalState(_occurrence('taken'), [
          _event(
            'e1',
            'taken',
            1,
            recordedByJson: '{"version":1,"name":"Tata"}',
          ),
        ], const {})!.authorName,
        'Tata',
      );
      // Nobody named: the copy names nobody (it is never stamped later).
      expect(
        moveFinalState(_occurrence('taken'), events, const {})!.authorName,
        isNull,
      );
      expect(
        moveFinalState(_occurrence('taken'), events, {
          'e1': details(null),
        })!.authorName,
        isNull,
      );
    });

    test('a miss carries no time, note or amount', () {
      final state = moveFinalState(_occurrence('missed'), [
        _event(
          'e1',
          'missed',
          1,
          actualAt: DateTime.utc(2026, 10, 20, 9),
          note: 'n',
          amountJson: _amount('1', 'tablet'),
        ),
      ], const {})!;
      expect(state.action, MedicationAction.miss);
      expect(state.actualAt, isNull);
      expect(state.actualTimeKnown, isFalse);
      expect(state.note, isNull);
      expect(state.amount.isUnknown, isTrue);
    });

    test('a skip keeps its note but not an amount', () {
      final state = moveFinalState(_occurrence('skipped'), [
        _event(
          'e1',
          'skipped',
          1,
          note: 'felt sick',
          amountJson: _amount('1', 'tablet'),
        ),
      ], const {})!;
      expect(state.action, MedicationAction.skip);
      expect(state.note, 'felt sick');
      expect(state.amount.isUnknown, isTrue);
    });
  });

  group('MoveIds', () {
    test('are stable for one account and differ between accounts', () {
      const a = MoveIds('owner-a');
      const b = MoveIds('owner-b');
      expect(a.person('p1'), a.person('p1'));
      expect(a.person('p1'), isNot(b.person('p1')));
      expect(a.person('p1'), isNot(a.medication('p1')));
      expect(a.schedule('r', 's'), isNot(a.schedule('r', 's', revision: 2)));
      expect(a.occurrence('o'), isNot(a.command('o')));
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(a.person('p1')),
        isTrue,
      );
    });
  });
}
