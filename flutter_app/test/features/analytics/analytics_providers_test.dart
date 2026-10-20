import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/routine_definition.dart'
    show routineDateKey;
import 'package:simpastil/core/utils/app_clock.dart';
import 'package:simpastil/features/analytics/adherence.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import '../../helpers/held_provider_read.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Schedule _schedule({
  String id = 'sched-1',
  String pillId = 'pill-1',
  int hour = 0,
  DateTime? createdAt,
}) => Schedule(
  id: id,
  pillId: pillId,
  hour: hour,
  minute: 0,
  frequency: 'daily',
  timeZoneStatus: 'legacy_unknown',
  frequencyDays: null,
  isActive: true,
  createdAt: createdAt ?? DateTime(2026, 3, 1),
  updatedAt: createdAt ?? DateTime(2026, 3, 1),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

Pill _pill({String id = 'pill-1'}) => Pill(
  id: id,
  profileId: 'profile-1',
  name: 'Aspirin',
  dosage: null,
  notes: null,
  color: null,
  isPrn: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  revision: 1,
  syncStatus: 'synced',
  isDeleted: false,
);

/// Seeds profile→pill→schedule rows so dose-log foreign keys resolve.
Future<void> _seedSchedule(AppDatabase db, Schedule schedule) async {
  await db.profilesDao.upsert(
    ProfilesCompanion(
      id: const Value('profile-1'),
      userId: const Value('user-1'),
      name: const Value('Alex'),
      createdAt: Value(DateTime(2026)),
      updatedAt: Value(DateTime(2026)),
    ),
  );
  await db.pillsDao.upsert(
    PillsCompanion(
      id: Value(schedule.pillId),
      profileId: const Value('profile-1'),
      name: const Value('Aspirin'),
      createdAt: Value(DateTime(2026)),
      updatedAt: Value(DateTime(2026)),
    ),
  );
  await db.schedulesDao.upsert(
    SchedulesCompanion(
      id: Value(schedule.id),
      pillId: Value(schedule.pillId),
      hour: Value(schedule.hour),
      minute: Value(schedule.minute),
      frequency: Value(schedule.frequency),
      frequencyDays: Value(schedule.frequencyDays),
      isActive: Value(schedule.isActive),
      createdAt: Value(schedule.createdAt),
      updatedAt: Value(schedule.updatedAt),
    ),
  );
}

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

Future<void> _insertOccurrence(
  AppDatabase db, {
  required String id,
  String scheduleId = 'sched-1',
  required DateTime plannedAt,
  String? state = 'taken',
}) async {
  final day = DateTime(plannedAt.year, plannedAt.month, plannedAt.day);
  await db.medicationLedgerDao.upsertOccurrence(
    MedicationOccurrencesCompanion.insert(
      id: id,
      userId: 'user-1',
      pillId: const Value('pill-1'),
      scheduleId: Value(scheduleId),
      occurrenceKey: 'test-occurrence:$id',
      source: 'scheduled',
      scheduleRevision: const Value(1),
      plannedLocalDate: _dateKey(day),
      plannedLocalTime: const Value('00:00:00'),
      timeZone: 'Europe/Bucharest',
      plannedAt: Value(plannedAt),
      expected: const Value(true),
      snapshotVersion: const Value(1),
      scheduleSnapshotJson: jsonEncode({
        'version': 1,
        'pillName': 'Aspirin',
        'dosage': null,
        'frequency': 'daily',
        'frequencyDays': null,
        'hour': 0,
        'minute': 0,
        'timeZone': 'Europe/Bucharest',
        'profileId': 'profile-1',
        'profileName': 'Alex',
      }),
      provenance: 'exact',
      state: Value(state ?? 'pending'),
      stateVersion: Value(state == null || state == 'pending' ? 0 : 1),
      serverSequence: const Value(null),
      supersededAt: const Value(null),
      supersededByOccurrenceId: const Value(null),
      createdAt: plannedAt.toUtc(),
      updatedAt: plannedAt.toUtc(),
    ),
  );
}

ProviderContainer _makeContainer(
  AppDatabase db,
  Schedule schedule, {
  List<Override> extraOverrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      ...extraOverrides,
      databaseProvider.overrideWithValue(db),
      currentUserIdProvider.overrideWithValue('user-1'),
      enabledProfileIdsProvider.overrideWithValue(const ['profile-1']),
      enabledPillsWithSchedulesProvider.overrideWith(
        (ref) => Stream.value(<PillWithSchedules>[
          (pill: _pill(id: schedule.pillId), schedules: [schedule]),
        ]),
      ),
      prnInStatsProvider.overrideWith(_FakePrnInStats.new),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return container;
}

/// Waits for the month provider to emit a value satisfying [predicate].
Future<Map<DateTime, DayAdherence>> _waitForMonth(
  ProviderContainer container,
  DateTime month,
  bool Function(Map<DateTime, DayAdherence>) predicate,
) {
  final completer = Completer<Map<DateTime, DayAdherence>>();
  late final ProviderSubscription<AsyncValue<Map<DateTime, DayAdherence>>> sub;
  sub = container.listen(monthAdherenceProvider(month), (_, next) {
    final value = next.value;
    if (value != null && predicate(value) && !completer.isCompleted) {
      completer.complete(value);
    }
  }, fireImmediately: true);
  addTearDown(sub.close);
  return completer.future.timeout(const Duration(seconds: 5));
}

class _FakePrnInStats extends PrnInStatsNotifier {
  @override
  bool build() => false;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('calendarMonthProvider', () {
    test('builds floored to the first of the current month', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final now = DateTime.now();
      expect(
        container.read(calendarMonthProvider),
        DateTime(now.year, now.month),
      );
    });

    test('select floors to the first of the month', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(calendarMonthProvider.notifier)
          .select(DateTime(2026, 3, 15, 10, 30));
      expect(container.read(calendarMonthProvider), DateTime(2026, 3));
    });

    test('select clamps future months to the current month', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final now = DateTime.now();
      container
          .read(calendarMonthProvider.notifier)
          .select(DateTime(now.year, now.month + 2));
      expect(
        container.read(calendarMonthProvider),
        DateTime(now.year, now.month),
      );
    });
  });

  group('monthAdherenceProvider', () {
    // March 2026 is safely in the past relative to any run of this suite.
    final month = DateTime(2026, 3);

    test('maps a seeded month from immutable occurrence rows', () async {
      final db = AppDatabase.forTesting();
      final schedule = _schedule();
      await _seedSchedule(db, schedule);
      for (var day = 1; day <= 31; day++) {
        await _insertOccurrence(
          db,
          id: 'occ-$day',
          plannedAt: DateTime(2026, 3, day),
          state: day == 10 ? 'taken' : 'pending',
        );
      }
      final container = _makeContainer(db, schedule);

      final map = await _waitForMonth(
        container,
        month,
        (m) => m[DateTime(2026, 3, 10)]?.expected == 1,
      );

      expect(map.length, 31);
      expect(map[DateTime(2026, 3, 10)], (
        taken: 1,
        skipped: 0,
        missed: 0,
        expected: 1,
      ));
      expect(map[DateTime(2026, 3, 11)], (
        taken: 0,
        skipped: 0,
        missed: 0,
        expected: 1,
      ));
    });

    test('live-updates when an occurrence is inserted', () async {
      final db = AppDatabase.forTesting();
      final schedule = _schedule();
      await _seedSchedule(db, schedule);
      await _insertOccurrence(
        db,
        id: 'occ-10',
        plannedAt: DateTime(2026, 3, 10),
        state: 'pending',
      );
      final container = _makeContainer(db, schedule);

      await _waitForMonth(
        container,
        month,
        (m) => m[DateTime(2026, 3, 10)]?.expected == 1,
      );
      await _insertOccurrence(
        db,
        id: 'occ-11',
        plannedAt: DateTime(2026, 3, 11),
      );

      final updated = await _waitForMonth(
        container,
        month,
        (m) => m[DateTime(2026, 3, 11)]!.taken == 1,
      );
      expect(updated[DateTime(2026, 3, 11)], (
        taken: 1,
        skipped: 0,
        missed: 0,
        expected: 1,
      ));
    });
  });

  group('adherenceStatsProvider', () {
    test('emits stats computed from seeded recent logs', () async {
      final db = AppDatabase.forTesting();
      // Two canonical daily occurrences (yesterday taken, today pending).
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day - 1);
      final schedule = _schedule(createdAt: yesterday);
      await _seedSchedule(db, schedule);
      await _insertOccurrence(db, id: 'occ-yesterday', plannedAt: yesterday);
      await _insertOccurrence(
        db,
        id: 'occ-today',
        plannedAt: DateTime(now.year, now.month, now.day),
        state: 'pending',
      );
      final container = _makeContainer(db, schedule);

      final completer = Completer<AdherenceStats>();
      late final ProviderSubscription<AsyncValue<AdherenceStats>> sub;
      sub = container.listen(adherenceStatsProvider, (_, next) {
        final value = next.value;
        if (value != null &&
            value.perPill.isNotEmpty &&
            !completer.isCompleted) {
          completer.complete(value);
        }
      }, fireImmediately: true);
      addTearDown(sub.close);
      final stats = await completer.future.timeout(const Duration(seconds: 5));

      expect(stats.last7Days, closeTo(0.5, 1e-9)); // 1 taken of 2 expected
      expect(stats.weeklyTrend, hasLength(12));
      expect(stats.perPill, hasLength(1));
      expect(stats.perPill.single.pillName, 'Aspirin');
    });

    test('reads the new day once midnight has passed', () async {
      final db = AppDatabase.forTesting();
      final real = DateTime.now();
      final today = DateTime(real.year, real.month, real.day);
      final tomorrow = DateTime(real.year, real.month, real.day + 1);
      var now = DateTime(today.year, today.month, today.day, 23, 30);
      final schedule = _schedule(createdAt: today);
      await _seedSchedule(db, schedule);
      // A dose taken on the day after the one the screen was opened on.
      await _insertOccurrence(db, id: 'occ-tomorrow', plannedAt: tomorrow);
      final container = _makeContainer(
        db,
        schedule,
        extraOverrides: [appClockProvider.overrideWithValue(() => now)],
      );
      final sub = container.listen(adherenceStatsProvider, (_, _) {});
      addTearDown(sub.close);

      final before = await container.readHeld(adherenceStatsProvider);
      expect(before.perPill, isEmpty);

      now = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 0, 0, 5);
      container.read(todayProvider.notifier).state = routineDateKey(now);
      await container.pump();
      final after = await container.readHeld(adherenceStatsProvider);
      expect(after.perPill, hasLength(1));
    });
  });
}
