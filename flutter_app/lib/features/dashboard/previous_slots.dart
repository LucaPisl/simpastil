import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/daos/medication_ledger_dao.dart' show headEventsAt;
import '../../core/db/database.dart'
    show MedicationOccurrence, OccurrenceEvent, databaseProvider;
import '../../core/workspace/workspace_provider.dart';

/// How many earlier occurrences of the same slot Dose details lists.
const int previousSlotLimit = 6;

/// One earlier occurrence of the same planned slot, with what was recorded.
@immutable
class PreviousSlot {
  const PreviousSlot({
    required this.occurrenceId,
    required this.localDate,
    required this.plannedLocalTime,
    required this.state,
    required this.actualAt,
  });

  final String occurrenceId;

  /// The planned local day, `yyyy-MM-dd`.
  final String localDate;

  /// The planned local time, `HH:mm`, or null.
  final String? plannedLocalTime;

  /// `taken`, `skipped`, `missed` or `pending` (never recorded).
  final String state;

  /// When it was taken, when the person said when; otherwise null. Only
  /// meaningful for a taken dose.
  final DateTime? actualAt;

  bool get taken => state == 'taken';
}

/// The earlier occurrences of [current]'s slot that Dose details lists:
/// the same schedule slot, planned before [current], due (expected), not
/// superseded and not itself, the last [limit] of them, oldest first.
///
/// [sameSchedule] is every occurrence of [current]'s schedule, in any order.
List<MedicationOccurrence> previousSlotOccurrences({
  required MedicationOccurrence current,
  required Iterable<MedicationOccurrence> sameSchedule,
  int limit = previousSlotLimit,
}) {
  final scheduleId = current.scheduleId;
  if (scheduleId == null || current.source == 'prn') return const [];
  int order(MedicationOccurrence a, MedicationOccurrence b) {
    final byDay = a.plannedLocalDate.compareTo(b.plannedLocalDate);
    if (byDay != 0) return byDay;
    final at = a.plannedAt, bt = b.plannedAt;
    if (at != null && bt != null) {
      final byTime = at.compareTo(bt);
      if (byTime != 0) return byTime;
    }
    return a.id.compareTo(b.id);
  }

  final earlier = [
    for (final row in sameSchedule)
      if (row.id != current.id &&
          row.scheduleId == scheduleId &&
          row.source != 'prn' &&
          row.expected &&
          row.supersededAt == null &&
          order(row, current) < 0)
        row,
  ]..sort(order);
  return earlier.length <= limit
      ? earlier
      : earlier.sublist(earlier.length - limit);
}

/// What was recorded for each of [occurrences], read from the occurrence
/// itself and the event that holds its current version.
///
/// A taken dose carries the time it was taken when it was recorded with
/// one. Pure: no database access.
List<PreviousSlot> previousSlotsFrom({
  required Iterable<MedicationOccurrence> occurrences,
  required Map<String, List<OccurrenceEvent>> eventsOf,
  Set<String> discardedCommandIds = const {},
}) {
  return [
    for (final row in occurrences)
      () {
        final head = headEventsAt(
          eventsOf[row.id] ?? const <OccurrenceEvent>[],
          row.stateVersion,
          discardedCommandIds: discardedCommandIds,
        ).singleOrNull;
        return PreviousSlot(
          occurrenceId: row.id,
          localDate: row.plannedLocalDate,
          plannedLocalTime: row.plannedLocalTime,
          state: row.state,
          actualAt:
              row.state == 'taken' &&
                  head != null &&
                  head.actualTimeKnown &&
                  head.actualAt != null
              ? head.actualAt
              : null,
        );
      }(),
  ];
}

/// Earlier occurrences of the slot [occurrenceId] belongs to, oldest first.
/// Read-only: it follows the saved ledger and never writes.
final previousSlotsProvider = StreamProvider.autoDispose
    .family<List<PreviousSlot>, String>((ref, occurrenceId) async* {
      final database = ref.watch(databaseProvider);
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await contextFuture;
      final dao = database.medicationLedgerDao;
      Future<List<PreviousSlot>> load() => access.withGrant(context, () async {
        final current = await dao.getOccurrenceById(occurrenceId);
        if (current == null ||
            current.userId != context.ownerUserId ||
            current.scheduleId == null) {
          return const <PreviousSlot>[];
        }
        final earlier = previousSlotOccurrences(
          current: current,
          sameSchedule: await dao.getOccurrencesForSchedule(
            current.scheduleId!,
          ),
        );
        return previousSlotsFrom(
          occurrences: earlier,
          eventsOf: {
            for (final row in earlier)
              row.id: await dao.getEventsForOccurrence(row.id),
          },
          discardedCommandIds: await dao.discardedCommandIds(
            context.ownerUserId,
          ),
        );
      });
      yield* database
          .customSelect(
            // Drift shares identical SQL streams; keep this one distinct.
            'SELECT 1 AS previous_slots_changes',
            readsFrom: {
              database.medicationOccurrences,
              database.occurrenceEvents,
            },
          )
          .watch()
          .asyncMap((_) => load());
    });
