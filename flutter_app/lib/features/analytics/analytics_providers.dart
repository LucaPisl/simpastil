import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:drift/drift.dart'
    show OrderingTerm, ComparableExpr, BooleanExpressionOperators;

import '../../core/db/database.dart';
import '../../core/db/daos/medication_ledger_dao.dart';
import '../../core/inventory/pill_stock.dart';
import '../../core/medication/occurrence_history.dart';
import '../../core/medication/routine_definition.dart'
    show parseRoutineDate, routineDateKey;
import '../../core/utils/app_clock.dart';
import '../../core/workspace/workspace_provider.dart';
import '../pills/pill_provider.dart';
import '../profiles/profile_provider.dart';
import 'adherence.dart';
import 'stock_changes.dart';
import 'trend_stats.dart';

// ── calendarMonthProvider ─────────────────────────────────────────────────────

/// Which month the calendar is showing. Always floored to the first of the
/// month, never a future month. Navigation is driven by the calendar's
/// PageController; this provider mirrors the settled month for the header
/// and any other consumer.
class CalendarMonthNotifier extends Notifier<DateTime> {
  @override
  DateTime build() => _currentMonth();

  /// Jumps to [month] (floored to its first day), clamped to the current
  /// month.
  void select(DateTime month) {
    final current = _currentMonth();
    final floored = DateTime(month.year, month.month);
    state = floored.isAfter(current) ? current : floored;
  }

  DateTime _currentMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }
}

final calendarMonthProvider = NotifierProvider<CalendarMonthNotifier, DateTime>(
  CalendarMonthNotifier.new,
);

// ── monthAdherenceProvider ────────────────────────────────────────────────────

/// Adherence per day for one month (the family argument MUST be floored to
/// the first of the month — `DateTime(year, month)`).
///
/// A family rather than a single provider keyed off [calendarMonthProvider]
/// because adjacent PageView pages are visible mid-swipe and each must watch
/// its own month's data. autoDispose releases months the user swiped past.
final monthAdherenceProvider = StreamProvider.autoDispose
    .family<Map<DateTime, DayAdherence>, DateTime>((ref, month) {
      assert(
        month.day == 1 && month.hour == 0 && month.minute == 0,
        'monthAdherenceProvider expects a month-floored DateTime(year, month)',
      );
      final db = ref.watch(databaseProvider);
      final userId = ref.watch(currentUserIdProvider);
      final enabledProfileIds = ref.watch(enabledProfileIdsProvider).toSet();

      final monthEnd = DateTime(month.year, month.month + 1, 0);
      return db.medicationLedgerDao
          .watchForUserLocalDateRange(
            userId,
            routineDateKey(month),
            routineDateKey(monthEnd),
          )
          .map(
            (records) => monthAdherenceFromOccurrences(
              records: _visibleProfileRecords(records, enabledProfileIds),
              month: month,
              now: DateTime.now(),
            ),
          );
    });

// ── adherenceStatsProvider ────────────────────────────────────────────────────

/// The last [trendWindowDays] days of occurrence rows for the people in view,
/// recomputed on every change.
///
/// The window is anchored to today when the stream is built, while `now`
/// inside a consumer's map closure is fresh per emission. Without a rebuild at
/// midnight the two drift apart: a dose logged after midnight would fall
/// outside the watched range and read as missed. Watching [todayProvider]
/// rebuilds the stream for the new day.
Stream<List<MedicationOccurrenceRecord>> _watchRecentRecords(Ref ref) {
  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);
  final enabledProfileIds = ref.watch(enabledProfileIdsProvider).toSet();

  final today = parseRoutineDate(ref.watch(todayProvider));
  final from = DateTime(
    today.year,
    today.month,
    today.day - (trendWindowDays - 1),
  );
  return db.medicationLedgerDao
      .watchForUserLocalDateRange(
        userId,
        routineDateKey(from),
        routineDateKey(DateTime(today.year, today.month, today.day)),
      )
      .map((records) => _visibleProfileRecords(records, enabledProfileIds));
}

/// Window statistics for the stats section, recomputed live from one Drift
/// watch covering the last 84 days (enough for 12 Monday-started weeks
/// whatever today's weekday is).
final adherenceStatsProvider = StreamProvider.autoDispose<AdherenceStats>((
  ref,
) {
  final clock = ref.watch(appClockProvider);
  return _watchRecentRecords(ref).map(
    (records) =>
        computeAdherenceStatsFromOccurrences(records: records, now: clock()),
  );
});

// ── trendStatsProvider ────────────────────────────────────────────────────────

/// The day streak, when doses are recorded through the day and as-needed use
/// per medication, over the same 84 days as [adherenceStatsProvider].
///
/// In a local workspace the streak also reads each routine's own calendar
/// (inside the workspace grant, read-only), so a day on which a dose fell due
/// but no occurrence was ever written still breaks it.
final trendStatsProvider = StreamProvider.autoDispose<TrendStats>((ref) {
  final clock = ref.watch(appClockProvider);
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final enabledProfileIds = ref.watch(enabledProfileIdsProvider).toSet();
  return _watchRecentRecords(ref).asyncMap((records) async {
    final now = clock();
    final context = await contextFuture;
    final unrecorded = context.isLocal
        ? await access.withGrant(context, () async {
            final versions =
                await (db.select(db.localRoutines)
                      ..where((r) => r.workspaceId.equals(context.workspaceId))
                      ..orderBy([(r) => OrderingTerm.asc(r.revision)]))
                    .get();
            final shown = <String, bool>{};
            final inView = <LocalRoutine>[];
            for (final version in versions) {
              final visible = shown[version.pillId] ??= await () async {
                final pill = await db.pillsDao.getById(version.pillId);
                return pill != null &&
                    !pill.isDeleted &&
                    enabledProfileIds.contains(pill.profileId);
              }();
              if (visible) inView.add(version);
            }
            return unrecordedRoutineDays(inView, records, now: now);
          })
        : const <String>{};
    return computeTrendStatsFromOccurrences(
      records: records,
      now: now,
      unrecordedDays: unrecorded,
    );
  });
});

// ── monthPrnCountsProvider ────────────────────────────────────────────────────

/// As-needed doses taken per day of one month (the family argument MUST be
/// floored to the first of the month, like [monthAdherenceProvider]).
final monthPrnCountsProvider = StreamProvider.autoDispose
    .family<Map<DateTime, int>, DateTime>((ref, month) {
      assert(
        month.day == 1 && month.hour == 0 && month.minute == 0,
        'monthPrnCountsProvider expects a month-floored DateTime(year, month)',
      );
      final db = ref.watch(databaseProvider);
      final userId = ref.watch(currentUserIdProvider);
      final enabledProfileIds = ref.watch(enabledProfileIdsProvider).toSet();
      final monthEnd = DateTime(month.year, month.month + 1, 0);
      return db.medicationLedgerDao
          .watchForUserLocalDateRange(
            userId,
            routineDateKey(month),
            routineDateKey(monthEnd),
          )
          .map(
            (records) => monthPrnCountsFromOccurrences(
              records: _visibleProfileRecords(records, enabledProfileIds),
              month: month,
            ),
          );
    });

// ── pillColorsProvider ────────────────────────────────────────────────────────

/// Each shown medication's color (a hex string, or null when it has none) by
/// medication id, for the bars and rows that name a medication. The occurrence
/// history does not carry colors; this reads them from the medications
/// themselves, so a medication that is gone has no entry.
final pillColorsProvider = Provider.autoDispose<Map<String, String?>>((ref) {
  final pills = ref.watch(enabledPillsWithSchedulesProvider).value ?? const [];
  return {for (final entry in pills) entry.pill.id: entry.pill.color};
});

// ── dayStockChangesProvider ───────────────────────────────────────────────────

/// The stock changes recorded on one day, for every person in view, newest
/// first. The family argument is the local day as `yyyy-MM-dd`.
///
/// Read from the inventory ledger inside the workspace grant, like the dose
/// records beside it; nothing is written.
final dayStockChangesProvider = StreamProvider.autoDispose
    .family<List<StockChange>, String>((ref, dayKey) async* {
      final day = DateTime.parse(dayKey);
      final next = DateTime(day.year, day.month, day.day + 1);
      final db = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final enabledProfileIds = ref.watch(enabledProfileIdsProvider).toSet();
      final context = await ref.watch(workspaceContextProvider.future);

      final query = db.select(db.inventoryEvents)
        ..where(
          (e) =>
              e.userId.equals(context.ownerUserId) &
              e.recordedAt.isBiggerOrEqualValue(day) &
              e.recordedAt.isSmallerThanValue(next),
        )
        ..orderBy([(e) => OrderingTerm.asc(e.recordedAt)]);
      yield* query.watch().asyncMap(
        (onDay) => access.withGrant(context, () async {
          if (onDay.isEmpty) return const <StockChange>[];
          final pills = <String, StockPill>{};
          for (final pillId in {for (final e in onDay) e.pillId}) {
            final pill = await db.pillsDao.getById(pillId);
            if (pill == null ||
                pill.isDeleted ||
                !enabledProfileIds.contains(pill.profileId)) {
              continue;
            }
            pills[pillId] = (
              name: pill.name,
              color: pill.color,
              profileId: pill.profileId,
              currentStock: exactStockOf(pill),
            );
          }
          final ledger = [
            for (final pillId in pills.keys)
              ...await db.medicationLedgerDao.getInventoryEventsForPill(pillId),
          ];
          return stockChangesForDay(day: day, events: ledger, pills: pills);
        }),
      );
    });

List<MedicationOccurrenceRecord> _visibleProfileRecords(
  List<MedicationOccurrenceRecord> records,
  Set<String> enabledProfileIds,
) => records
    .where((record) {
      final snapshot = decodeOccurrenceSnapshot(
        record.occurrence.scheduleSnapshotJson,
      );
      final profileId = snapshot?['profileId'];
      return profileId is String && enabledProfileIds.contains(profileId);
    })
    .toList(growable: false);
