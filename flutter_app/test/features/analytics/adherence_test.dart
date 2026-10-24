import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/pills/pill_provider.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Schedule _schedule({
  String id = 'sched-1',
  String pillId = 'pill-1',
  int hour = 8,
  int minute = 0,
  String frequency = 'daily',
  String? frequencyDays,
  bool isActive = true,
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
  isDeleted: false,
);

DoseLog _log({
  required String id,
  String scheduleId = 'sched-1',
  required DateTime scheduledAt,
  String status = 'taken',
}) => DoseLog(
  id: id,
  scheduleId: scheduleId,
  scheduledAt: scheduledAt,
  takenAt: status == 'taken' ? scheduledAt : null,
  status: status,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

Pill _pill({
  String id = 'pill-1',
  String name = 'Aspirin',
  String? color,
  bool isPrn = false,
}) => Pill(
  id: id,
  stockNeedsRecount: false,
  profileId: 'profile-1',
  name: name,
  dosage: null,
  notes: null,
  color: color,
  isPrn: isPrn,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('DayAdherence.ratio', () {
    test('taken over all due scheduled occurrences including skipped', () {
      const d = (taken: 2, skipped: 1, missed: 0, expected: 4);
      expect(d.ratio, closeTo(2 / 4, 1e-9));
    });

    test('null when denominator is zero', () {
      const allSkipped = (taken: 0, skipped: 2, missed: 0, expected: 2);
      const nothing = (taken: 0, skipped: 0, missed: 0, expected: 0);
      expect(allSkipped.ratio, 0);
      expect(nothing.ratio, isNull);
    });
  });

  group('dayAdherenceFor', () {
    final day = DateTime(2026, 6, 10);
    final now = DateTime(2026, 6, 11, 12); // day is fully in the past

    test('counts taken, skipped, and expected from slots and logs', () {
      final schedules = [
        _schedule(id: 'a', hour: 8),
        _schedule(id: 'b', hour: 12),
        _schedule(id: 'c', hour: 20),
      ];
      final logs = [
        _log(id: 'l1', scheduleId: 'a', scheduledAt: DateTime(2026, 6, 10, 8)),
        _log(
          id: 'l2',
          scheduleId: 'b',
          scheduledAt: DateTime(2026, 6, 10, 12),
          status: 'skipped',
        ),
      ];
      final result = dayAdherenceFor(
        schedules: schedules,
        logs: logs,
        day: day,
        now: now,
      );
      expect(result, (taken: 1, skipped: 1, missed: 0, expected: 3));
    });

    test('a recorded miss is counted and weighs like an unrecorded dose', () {
      final schedules = [
        _schedule(id: 'a', hour: 8),
        _schedule(id: 'b', hour: 12),
      ];
      final taken = _log(
        id: 'l1',
        scheduleId: 'a',
        scheduledAt: DateTime(2026, 6, 10, 8),
      );
      final withMiss = dayAdherenceFor(
        schedules: schedules,
        logs: [
          taken,
          _log(
            id: 'l2',
            scheduleId: 'b',
            scheduledAt: DateTime(2026, 6, 10, 12),
            status: 'missed',
          ),
        ],
        day: day,
        now: now,
      );
      final unrecorded = dayAdherenceFor(
        schedules: schedules,
        logs: [taken],
        day: day,
        now: now,
      );
      expect(withMiss, (taken: 1, skipped: 0, missed: 1, expected: 2));
      expect(unrecorded, (taken: 1, skipped: 0, missed: 0, expected: 2));
      expect(withMiss.ratio, unrecorded.ratio);
    });

    test('past unlogged doses count as expected but not taken', () {
      final result = dayAdherenceFor(
        schedules: [_schedule()],
        logs: const [],
        day: day,
        now: now,
      );
      expect(result, (taken: 0, skipped: 0, missed: 0, expected: 1));
      expect(result.ratio, 0.0);
    });

    test("today's future slots are excluded from the denominator", () {
      final schedules = [
        _schedule(id: 'a', hour: 8),
        _schedule(id: 'b', hour: 22),
      ];
      final result = dayAdherenceFor(
        schedules: schedules,
        logs: const [],
        day: DateTime(2026, 6, 11),
        now: DateTime(2026, 6, 11, 12), // 22:00 hasn't happened yet
      );
      expect(result, (taken: 0, skipped: 0, missed: 0, expected: 1));
    });

    test('a fully future day has nothing expected', () {
      final result = dayAdherenceFor(
        schedules: [_schedule()],
        logs: const [],
        day: DateTime(2026, 6, 12),
        now: DateTime(2026, 6, 11, 12),
      );
      expect(result, (taken: 0, skipped: 0, missed: 0, expected: 0));
      expect(result.ratio, isNull);
    });

    test('a missed log counts as expected and as missed, not as taken', () {
      final logs = [
        _log(id: 'l1', scheduledAt: DateTime(2026, 6, 10, 8), status: 'missed'),
      ];
      final result = dayAdherenceFor(
        schedules: [_schedule()],
        logs: logs,
        day: day,
        now: now,
      );
      expect(result, (taken: 0, skipped: 0, missed: 1, expected: 1));
      expect(result.ratio, 0.0);
    });
  });

  group('monthAdherence', () {
    test('returns an entry for every day of the month, keyed date-floored', () {
      final map = monthAdherence(
        schedules: [_schedule(createdAt: DateTime(2026, 1, 1))],
        logs: const [],
        month: DateTime(2026, 6),
        now: DateTime(2026, 7, 15), // June fully past
      );
      expect(map.length, 30);
      expect(map.keys.first, DateTime(2026, 6, 1));
      expect(map.keys.last, DateTime(2026, 6, 30));
      expect(map[DateTime(2026, 6, 10)], (
        taken: 0,
        skipped: 0,
        missed: 0,
        expected: 1,
      ));
    });

    test('joins logs onto their own day only', () {
      final map = monthAdherence(
        schedules: [_schedule(createdAt: DateTime(2026, 1, 1))],
        logs: [_log(id: 'l1', scheduledAt: DateTime(2026, 6, 10, 8))],
        month: DateTime(2026, 6),
        now: DateTime(2026, 7, 15),
      );
      expect(map[DateTime(2026, 6, 10)]!.taken, 1);
      expect(map[DateTime(2026, 6, 11)]!.taken, 0);
    });

    test('days before the schedule was created have nothing expected', () {
      final map = monthAdherence(
        schedules: [_schedule(createdAt: DateTime(2026, 6, 15, 14))],
        logs: const [],
        month: DateTime(2026, 6),
        now: DateTime(2026, 7, 15),
      );
      expect(map[DateTime(2026, 6, 14)]!.expected, 0);
      expect(
        map[DateTime(2026, 6, 15)]!.expected,
        1,
      ); // same-day creation shows
    });
  });

  group('computeAdherenceStats', () {
    // Fixed clock: Thursday 2026-06-11 12:00. Week starts Monday 2026-06-08;
    // the 12-week trend therefore spans Mondays 2026-03-23 … 2026-06-08.
    final now = DateTime(2026, 6, 11, 12);

    List<PillWithSchedules> onePill({DateTime? createdAt}) => [
      (
        pill: _pill(),
        schedules: [
          _schedule(hour: 0, createdAt: createdAt ?? DateTime(2026, 6, 1)),
        ],
      ),
    ];

    test('weekly trend has 12 Monday-started buckets, oldest first', () {
      final stats = computeAdherenceStats(
        pillsWithSchedules: onePill(),
        logs: const [],
        now: now,
      );
      expect(stats.weeklyTrend, hasLength(12));
      expect(stats.weeklyTrend.first.weekStart, DateTime(2026, 3, 23));
      expect(stats.weeklyTrend.last.weekStart, DateTime(2026, 6, 8));
    });

    test('7 and 30 day windows count expected and taken doses', () {
      // Daily at 00:00 since June 1 → expected: Jun 1–11 = 11 slots in the
      // 30-day window, Jun 5–11 = 7 slots in the 7-day window.
      final logs = [
        for (var d = 5; d <= 9; d++)
          _log(id: 'l$d', scheduledAt: DateTime(2026, 6, d)),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: onePill(),
        logs: logs,
        now: now,
      );
      expect(stats.last7Days, closeTo(5 / 7, 1e-9));
      expect(stats.last30Days, closeTo(5 / 11, 1e-9));
    });

    test('skipped doses remain in the denominator', () {
      final logs = [
        for (var d = 5; d <= 9; d++)
          _log(id: 'l$d', scheduledAt: DateTime(2026, 6, d)),
        _log(id: 'sk', scheduledAt: DateTime(2026, 6, 10), status: 'skipped'),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: onePill(),
        logs: logs,
        now: now,
      );
      expect(stats.last7Days, closeTo(5 / 7, 1e-9));
    });

    test('recorded misses are counted per week and per pill, ratios as '
        'unrecorded', () {
      final logs = [
        _log(id: 'ok', scheduledAt: DateTime(2026, 6, 8)),
        _log(id: 'miss', scheduledAt: DateTime(2026, 6, 9), status: 'missed'),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: onePill(),
        logs: logs,
        now: now,
      );
      final unrecorded = computeAdherenceStats(
        pillsWithSchedules: onePill(),
        logs: [logs.first],
        now: now,
      );
      expect(stats.weeklyTrend.last.missed, 1);
      expect(unrecorded.weeklyTrend.last.missed, 0);
      expect(stats.perPill.single.missed, 1);
      expect(stats.last7Days, unrecorded.last7Days);
      expect(stats.last30Days, unrecorded.last30Days);
      expect(stats.weeklyTrend.last.ratio, unrecorded.weeklyTrend.last.ratio);
    });

    test('doses land in the right weekly bucket', () {
      final logs = [
        _log(id: 'mon', scheduledAt: DateTime(2026, 6, 8)), // this week
        _log(id: 'sun', scheduledAt: DateTime(2026, 6, 7)), // previous week
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: onePill(),
        logs: logs,
        now: now,
      );
      expect(stats.weeklyTrend.last.taken, 1); // week of Jun 8
      expect(stats.weeklyTrend[10].taken, 1); // week of Jun 1 (contains Jun 7)
    });

    test('per-pill rows are sorted worst-first and empty pills omitted', () {
      final pills = [
        (
          pill: _pill(id: 'good', name: 'Good Pill', color: '#00FF00'),
          schedules: [
            _schedule(
              id: 's-good',
              pillId: 'good',
              hour: 0,
              createdAt: DateTime(2026, 6, 1),
            ),
          ],
        ),
        (
          pill: _pill(id: 'bad', name: 'Bad Pill'),
          schedules: [
            _schedule(
              id: 's-bad',
              pillId: 'bad',
              hour: 0,
              createdAt: DateTime(2026, 6, 1),
            ),
          ],
        ),
        (
          pill: _pill(id: 'unused', name: 'Unused Pill'),
          schedules: [
            _schedule(id: 's-unused', pillId: 'unused', isActive: false),
          ],
        ),
      ];
      final logs = [
        // Good Pill: taken every day Jun 1–11 (11/11).
        for (var d = 1; d <= 11; d++)
          _log(
            id: 'g$d',
            scheduleId: 's-good',
            scheduledAt: DateTime(2026, 6, d),
          ),
        // Bad Pill: taken once (1/11).
        _log(id: 'b1', scheduleId: 's-bad', scheduledAt: DateTime(2026, 6, 1)),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: pills,
        logs: logs,
        now: now,
      );
      expect(stats.perPill, hasLength(2)); // Unused Pill omitted
      expect(stats.perPill.first.pillName, 'Bad Pill');
      expect(stats.perPill.first.color, isNull);
      expect(stats.perPill.last.pillName, 'Good Pill');
      expect(stats.perPill.last.color, '#00FF00');
      expect(stats.perPill.first.ratio, closeTo(1 / 11, 1e-9));
    });

    test('the 30-day window starts exactly 29 days back', () {
      // Schedule created long before the window; logs on the boundary day
      // and the day just outside it.
      final pills = onePill(createdAt: DateTime(2026, 1, 1));
      final logs = [
        _log(id: 'in', scheduledAt: DateTime(2026, 5, 13)),
        _log(id: 'out', scheduledAt: DateTime(2026, 5, 12)),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: pills,
        logs: logs,
        now: now,
      );
      // Expected: May 13 … Jun 11 inclusive = 30 days; only the May 13 log
      // counts as taken.
      final taken = stats.perPill.single.taken;
      final expected = stats.perPill.single.expected;
      expect(expected, 30);
      expect(taken, 1);
    });

    test('equal ratios tie-break alphabetically by pill name', () {
      final pills = [
        for (final name in ['Zeta', 'Alpha'])
          (
            pill: _pill(id: name.toLowerCase(), name: name),
            schedules: [
              _schedule(
                id: 's-${name.toLowerCase()}',
                pillId: name.toLowerCase(),
                hour: 0,
                createdAt: DateTime(2026, 6, 1),
              ),
            ],
          ),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: pills,
        logs: const [],
        now: now,
      );
      expect(stats.perPill.map((p) => p.pillName).toList(), ['Alpha', 'Zeta']);
    });

    test('windows with nothing expected yield null percentages', () {
      final stats = computeAdherenceStats(
        pillsWithSchedules: const [],
        logs: const [],
        now: now,
      );
      expect(stats.last7Days, isNull);
      expect(stats.last30Days, isNull);
      expect(stats.perPill, isEmpty);
      for (final week in stats.weeklyTrend) {
        expect(week.ratio, isNull);
      }
    });

    test('PRN logs are counted separately, not in scheduled adherence', () {
      final pills = [
        (
          pill: _pill(id: 'prn', name: 'Ibuprofen', isPrn: true),
          schedules: [
            _schedule(
              id: 's-prn',
              pillId: 'prn',
              frequency: 'prn',
              hour: 0,
              createdAt: DateTime(2026, 6, 1),
            ),
          ],
        ),
      ];
      final logs = [
        _log(
          id: 'prn-1',
          scheduleId: 's-prn',
          scheduledAt: DateTime(2026, 6, 10, 14, 30),
        ),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: pills,
        logs: logs,
        now: now,
      );
      expect(stats.last7Days, isNull);
      expect(stats.last30Days, isNull);
      expect(stats.perPill, isEmpty);
      expect(stats.prnTaken, 1);
    });

    test('PRN use never changes scheduled adherence, even when opted in', () {
      final pills = [
        (
          pill: _pill(id: 'prn', name: 'Ibuprofen', isPrn: true),
          schedules: [
            _schedule(
              id: 's-prn',
              pillId: 'prn',
              frequency: 'prn',
              hour: 0,
              createdAt: DateTime(2026, 6, 1),
            ),
          ],
        ),
      ];
      final logs = [
        _log(
          id: 'prn-1',
          scheduleId: 's-prn',
          scheduledAt: DateTime(2026, 6, 10, 14, 30),
        ),
      ];
      final stats = computeAdherenceStats(
        pillsWithSchedules: pills,
        logs: logs,
        now: now,
        prnInStats: true,
      );
      expect(stats.last7Days, isNull);
      expect(stats.last30Days, isNull);
      expect(stats.perPill, isEmpty);
      expect(stats.prnTaken, 1);
    });
  });
}
