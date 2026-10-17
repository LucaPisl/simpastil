import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart'
    show MedicationOccurrence, databaseProvider;
import '../../../core/medication/care_provider.dart' show CareDayRequest;
import '../../../core/medication/routine_definition.dart';
import '../../../core/utils/app_clock.dart';
import '../../../core/workspace/workspace_provider.dart';

/// How much of one day has been recorded.
enum WeekDotState {
  /// Nothing recorded (a day with no doses, or doses still waiting).
  empty,

  /// Some doses recorded and others still to record.
  some,

  /// Doses recorded and none left waiting.
  done,
}

/// One day of the "This week" strip.
class WeekDot {
  const WeekDot({
    required this.date,
    required this.recorded,
    required this.expected,
    required this.pending,
    required this.selected,
    required this.today,
  });

  /// Device-local calendar day.
  final DateTime date;

  /// Doses recorded that day: taken or skipped, scheduled or as needed.
  final int recorded;

  /// Scheduled doses planned that day.
  final int expected;

  /// Scheduled doses still waiting.
  final int pending;
  final bool selected;
  final bool today;

  WeekDotState get state => recorded == 0
      ? WeekDotState.empty
      : pending > 0
      ? WeekDotState.some
      : WeekDotState.done;
}

/// The seven days ending on [selected], oldest first, with what was
/// recorded on each.
///
/// Read-only: [occurrences] are ledger rows (any person the caller chose);
/// superseded rows and as-needed rows that are still pending (never taken)
/// are ignored. Scheduled rows count as planned only when they were
/// [MedicationOccurrence.expected]. A day nobody has opened has no rows and
/// reads as empty, which is true: nothing is recorded on it.
List<WeekDot> weekDotsFrom({
  required DateTime selected,
  required DateTime today,
  required Iterable<MedicationOccurrence> occurrences,
}) {
  final last = DateTime(selected.year, selected.month, selected.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  final recorded = <String, int>{};
  final expected = <String, int>{};
  final pending = <String, int>{};
  for (final row in occurrences) {
    if (row.supersededAt != null) continue;
    final key = row.plannedLocalDate;
    final done = row.state == 'taken' || row.state == 'skipped';
    if (done) recorded[key] = (recorded[key] ?? 0) + 1;
    if (row.source != 'prn' && row.expected) {
      expected[key] = (expected[key] ?? 0) + 1;
      if (!done) pending[key] = (pending[key] ?? 0) + 1;
    }
  }
  return [
    for (var back = 6; back >= 0; back--)
      () {
        final day = DateTime(last.year, last.month, last.day - back);
        final key = routineDateKey(day);
        return WeekDot(
          date: day,
          recorded: recorded[key] ?? 0,
          expected: expected[key] ?? 0,
          pending: pending[key] ?? 0,
          selected: back == 0,
          today: day == todayDay,
        );
      }(),
  ];
}

/// The week ending on the request's day, for the selected person (or
/// everyone), following the saved ledger live. Never writes.
final weekDotsProvider = StreamProvider.autoDispose
    .family<List<WeekDot>, CareDayRequest>((ref, request) async* {
      final database = ref.watch(databaseProvider);
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      // Which dot is today follows the calendar: the strip is rebuilt at
      // midnight, not left marking yesterday.
      final todayKey = ref.watch(todayProvider);
      final context = await contextFuture;
      final selected = parseRoutineDate(request.localDate);
      final from = routineDateKey(
        DateTime.utc(selected.year, selected.month, selected.day - 6),
      );
      yield* database.medicationLedgerDao
          .watchForUserLocalDateRange(
            context.ownerUserId,
            from,
            request.localDate,
          )
          .asyncMap(
            (_) => access.withGrant(context, () async {
              final records = await database.medicationLedgerDao
                  .getForUserLocalDateRange(
                    context.ownerUserId,
                    from,
                    request.localDate,
                  );
              Set<String>? pillIds;
              if (request.personId != null) {
                pillIds = {
                  for (final pill in await database.pillsDao.getByProfileId(
                    request.personId!,
                  ))
                    pill.id,
                };
              }
              return weekDotsFrom(
                selected: selected,
                today: parseRoutineDate(todayKey),
                occurrences: [
                  for (final record in records)
                    if (pillIds == null ||
                        pillIds.contains(record.occurrence.pillId))
                      record.occurrence,
                ],
              );
            }),
          );
    });
