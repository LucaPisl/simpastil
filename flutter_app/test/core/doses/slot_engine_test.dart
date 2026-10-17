import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/doses/slot_engine.dart';
import 'package:simpastil/core/models/dose_status.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Schedule _schedule({
  String id = 'sched-1',
  String pillId = 'pill-1',
  int hour = 8,
  int minute = 0,
  String frequency = 'daily',
  String? frequencyDays,
  bool isActive = true,
  bool isDeleted = false,
  DateTime? createdAt,
}) => Schedule(
  id: id,
  pillId: pillId,
  hour: hour,
  minute: minute,
  frequency: frequency,
  timeZoneStatus: 'legacy_unknown',
  frequencyDays: frequencyDays,
  isActive: isActive,
  createdAt: createdAt ?? DateTime(2026),
  updatedAt: createdAt ?? DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: isDeleted,
);

DoseLog _log({
  String id = 'log-1',
  String scheduleId = 'sched-1',
  required DateTime scheduledAt,
  String status = 'taken',
  DateTime? takenAt,
}) => DoseLog(
  id: id,
  scheduleId: scheduleId,
  scheduledAt: scheduledAt,
  takenAt: takenAt,
  status: status,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('dateOnly', () {
    test('floors to local midnight', () {
      expect(dateOnly(DateTime(2026, 6, 10, 23, 59)), DateTime(2026, 6, 10));
    });
  });

  group('isScheduleActiveOn', () {
    test('daily schedules are active every day', () {
      final s = _schedule();
      expect(isScheduleActiveOn(s, DateTime(2026, 6, 8)), isTrue); // Monday
      expect(isScheduleActiveOn(s, DateTime(2026, 6, 14)), isTrue); // Sunday
    });

    test('weekly schedule matches listed ISO weekdays only', () {
      final s = _schedule(
        frequency: 'weekly',
        frequencyDays: jsonEncode([1, 3]), // Mon, Wed
      );
      expect(isScheduleActiveOn(s, DateTime(2026, 6, 8)), isTrue); // Mon
      expect(isScheduleActiveOn(s, DateTime(2026, 6, 9)), isFalse); // Tue
      expect(isScheduleActiveOn(s, DateTime(2026, 6, 10)), isTrue); // Wed
    });

    test('weekly schedule with null frequencyDays is never active', () {
      final s = _schedule(frequency: 'weekly', frequencyDays: null);
      expect(isScheduleActiveOn(s, DateTime(2026, 6, 8)), isFalse);
    });

    test('malformed frequencyDays JSON is never active', () {
      final s = _schedule(frequency: 'weekly', frequencyDays: 'not-json');
      expect(isScheduleActiveOn(s, DateTime(2026, 6, 8)), isFalse);
    });
  });

  group('expectedSlotsFor', () {
    test('builds one slot per matching schedule at the scheduled time', () {
      final slots = expectedSlotsFor([
        _schedule(hour: 8, minute: 30),
      ], DateTime(2026, 6, 10));
      expect(slots, hasLength(1));
      expect(slots.single.scheduledAt, DateTime(2026, 6, 10, 8, 30));
      expect(slots.single.schedule.id, 'sched-1');
    });

    test('skips inactive and deleted schedules', () {
      final slots = expectedSlotsFor([
        _schedule(id: 'a', isActive: false),
        _schedule(id: 'b', isDeleted: true),
      ], DateTime(2026, 6, 10));
      expect(slots, isEmpty);
    });

    test('skips weekly schedules not active on the day', () {
      final slots = expectedSlotsFor(
        [
          _schedule(frequency: 'weekly', frequencyDays: jsonEncode([1])),
        ],
        DateTime(2026, 6, 9), // Tuesday
      );
      expect(slots, isEmpty);
    });

    test('skips PRN sentinel schedules', () {
      final slots = expectedSlotsFor([
        _schedule(id: 'prn', frequency: 'prn', hour: 0, minute: 0),
      ], DateTime(2026, 6, 10));
      expect(slots, isEmpty);
    });

    test('hides schedules created after the viewed day', () {
      final slots = expectedSlotsFor([
        _schedule(createdAt: DateTime(2026, 6, 11, 9)),
      ], DateTime(2026, 6, 10));
      expect(slots, isEmpty);
    });

    test('shows schedules created later the same day', () {
      final slots = expectedSlotsFor([
        _schedule(hour: 8, createdAt: DateTime(2026, 6, 10, 14)),
      ], DateTime(2026, 6, 10));
      expect(slots, hasLength(1));
      expect(slots.single.scheduledAt, DateTime(2026, 6, 10, 8));
    });

    test('floors the day argument before building slot times', () {
      final slots = expectedSlotsFor([
        _schedule(hour: 8),
      ], DateTime(2026, 6, 10, 23, 59));
      expect(slots.single.scheduledAt, DateTime(2026, 6, 10, 8));
    });
  });

  group('computeDoseStatus', () {
    final at = DateTime(2026, 6, 10, 8);

    test('maps log statuses directly', () {
      expect(
        computeDoseStatus(_log(scheduledAt: at, status: 'taken')),
        DoseStatus.taken,
      );
      expect(
        computeDoseStatus(_log(scheduledAt: at, status: 'skipped')),
        DoseStatus.skipped,
      );
      expect(
        computeDoseStatus(_log(scheduledAt: at, status: 'missed')),
        DoseStatus.missed,
      );
      expect(
        computeDoseStatus(_log(scheduledAt: at, status: 'weird')),
        DoseStatus.pending,
      );
    });

    test('an unlogged dose is pending however late it is', () {
      // Missed is a recorded fact (a `miss` event); the clock alone never
      // turns a dose into one.
      expect(computeDoseStatus(null), DoseStatus.pending);
    });
  });

  group('slotKey', () {
    test('is unique per schedule and time', () {
      final t = DateTime(2026, 6, 10, 8);
      expect(slotKey('a', t), isNot(slotKey('b', t)));
      expect(slotKey('a', t), isNot(slotKey('a', DateTime(2026, 6, 10, 9))));
      expect(slotKey('a', t), slotKey('a', DateTime(2026, 6, 10, 8)));
    });
  });

  group('CR-4: log-driven history reconstruction', () {
    test(
      'schedule time change does not orphan old logs when existingLogs provided',
      () {
        final schedule = _schedule(hour: 9, minute: 0);
        final oldLog = _log(scheduledAt: DateTime(2026, 6, 10, 8, 0));

        final slots = expectedSlotsFor(
          [schedule],
          DateTime(2026, 6, 10),
          existingLogs: [oldLog],
        );

        final times = slots.map((s) => s.scheduledAt).toSet();
        expect(
          times,
          contains(DateTime(2026, 6, 10, 9, 0)),
          reason: 'current schedule time produces a slot',
        );
        expect(
          times,
          contains(DateTime(2026, 6, 10, 8, 0)),
          reason: 'old log time produces a slot even though schedule changed',
        );
      },
    );

    test('deleted logs do not produce phantom slots', () {
      final schedule = _schedule(hour: 9);
      final deletedLog = DoseLog(
        id: 'log-del',
        scheduleId: 'sched-1',
        scheduledAt: DateTime(2026, 6, 10, 8, 0),
        status: 'taken',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        revision: 1,
        syncStatus: 'synced',
        isDeleted: true,
      );

      final slots = expectedSlotsFor(
        [schedule],
        DateTime(2026, 6, 10),
        existingLogs: [deletedLog],
      );
      expect(slots.length, 1, reason: 'only the current schedule slot');
    });

    test('without existingLogs, old log times are not included', () {
      final schedule = _schedule(hour: 9);
      final slots = expectedSlotsFor([schedule], DateTime(2026, 6, 10));
      expect(slots.length, 1);
      expect(slots.first.scheduledAt.hour, 9);
    });
  });
}
