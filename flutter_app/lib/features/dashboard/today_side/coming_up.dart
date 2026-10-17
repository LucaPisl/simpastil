import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart'
    show MedicationOccurrence, databaseProvider;
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_repository.dart';
import '../../../core/workspace/workspace_provider.dart';

/// How many planned doses the Coming up card lists.
const int comingUpLimit = 3;

/// The next planned dose of one medication, after the day being looked at.
@immutable
class ComingUpDose {
  const ComingUpDose({
    required this.pillId,
    required this.medication,
    required this.personName,
    required this.localDate,
    required this.localTime,
    required this.plannedAt,
    required this.amount,
    this.color,
  });

  final String pillId;
  final String medication;
  final String personName;

  /// The planned local day, `yyyy-MM-dd`.
  final String localDate;

  /// The planned local time, `HH:mm`.
  final String localTime;
  final DateTime plannedAt;
  final MedicationAmount amount;

  /// The medication's own colour as `#RRGGBB`, if it has one.
  final String? color;
}

/// The soonest [limit] doses of [candidates], one per medication.
List<ComingUpDose> soonestDoses(
  Iterable<ComingUpDose> candidates, {
  int limit = comingUpLimit,
}) {
  final first = <String, ComingUpDose>{};
  for (final dose in candidates) {
    final seen = first[dose.pillId];
    if (seen == null || dose.plannedAt.isBefore(seen.plannedAt)) {
      first[dose.pillId] = dose;
    }
  }
  final sorted = first.values.toList()
    ..sort((a, b) {
      final byTime = a.plannedAt.compareTo(b.plannedAt);
      return byTime != 0 ? byTime : a.medication.compareTo(b.medication);
    });
  return sorted.length <= limit ? sorted : sorted.sublist(0, limit);
}

/// The next planned doses after [after] (a `yyyy-MM-dd` day) for the selected
/// person or everyone. Informational and read-only: it creates no occurrence
/// and gives no recording authority.
///
/// A local workspace reads the routine's own calendar; a connected one only
/// lists future occurrences the saved ledger already holds.
final comingUpProvider = FutureProvider.autoDispose
    .family<List<ComingUpDose>, String>((ref, after) async {
      final details = await ref.watch(medicationListProvider.future);
      final database = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await ref.watch(workspaceContextProvider.future);
      final scheduled = [
        for (final detail in details)
          if (!detail.pill.isPrn) detail,
      ];
      final candidates = <ComingUpDose>[];
      if (context.isLocal) {
        final routines = RoutineRepository(
          database: database,
          access: access,
          context: context,
        );
        for (final detail in scheduled) {
          if (detail.routineVersions.isEmpty) continue;
          final next = await routines.nextPlannedForPill(
            pillId: detail.pill.id,
            afterLocalDate: after,
          );
          if (next == null) continue;
          candidates.add(
            ComingUpDose(
              pillId: detail.pill.id,
              medication: detail.review.name,
              personName: detail.person.name,
              localDate: next.planned.localDate,
              localTime: next.planned.localTime,
              plannedAt: next.planned.plannedAt,
              amount: next.amount,
              color: detail.pill.color,
            ),
          );
        }
      } else {
        final byPill = {for (final d in scheduled) d.pill.id: d};
        final date = parseRoutineDate(after);
        final records = await access.withGrant(
          context,
          () => database.medicationLedgerDao.getForUserLocalDateRange(
            context.ownerUserId,
            routineDateKey(DateTime.utc(date.year, date.month, date.day + 1)),
            '9999-12-31',
          ),
        );
        for (final record in records) {
          final MedicationOccurrence row = record.occurrence;
          final detail = byPill[row.pillId];
          final time = row.plannedLocalTime;
          if (detail == null ||
              time == null ||
              row.supersededAt != null ||
              !row.expected ||
              row.state != 'pending' ||
              row.provenance != 'exact' ||
              row.plannedAt == null) {
            continue;
          }
          candidates.add(
            ComingUpDose(
              pillId: detail.pill.id,
              medication: detail.review.name,
              personName: detail.person.name,
              localDate: row.plannedLocalDate,
              localTime: time,
              plannedAt: row.plannedAt!,
              amount: const MedicationAmount.unknown(),
              color: detail.pill.color,
            ),
          );
        }
      }
      return soonestDoses(candidates);
    });
