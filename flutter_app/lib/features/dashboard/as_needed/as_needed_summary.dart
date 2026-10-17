import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/reviewed_stock.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../history_entry_mapper.dart';

/// One recorded as-needed dose, as the recent-doses list and the stats read it.
class AsNeededDose {
  const AsNeededDose({
    required this.occurrenceId,
    required this.pillId,
    required this.day,
    required this.takenAt,
    required this.amount,
    required this.note,
  });
  final String occurrenceId;
  final String pillId;

  /// The device-local calendar day the dose belongs to: the day of its time
  /// when known, otherwise the day it was recorded for.
  final DateTime day;

  /// Null when the person did not know when it was taken.
  final DateTime? takenAt;
  final MedicationAmount amount;
  final String? note;
}

/// Remaining stock for display. Never a command: recording a dose is allowed
/// at any level, including below zero.
class AsNeededStock {
  const AsNeededStock({
    required this.left,
    required this.unit,
    required this.low,
    required this.fraction,
  });

  /// Plain-text count, for example `12` or `7.5`.
  final String left;
  final String? unit;
  final bool low;

  /// 0..1 fill for a bar; null when no low-stock level is set to scale by.
  final double? fraction;
}

class AsNeededSummary {
  const AsNeededSummary({
    required this.pillId,
    required this.doses,
    required this.today,
    required this.stock,
  });
  const AsNeededSummary.empty(this.pillId)
    : doses = const [],
      today = null,
      stock = null;
  final String pillId;

  /// Doses of the last 7 days (today included), newest first.
  final List<AsNeededDose> doses;
  final DateTime? today;
  final AsNeededStock? stock;

  List<AsNeededDose> get todayDoses => [
    for (final d in doses)
      if (today != null && d.day == today) d,
  ];
  int get todayCount => todayDoses.length;
  int get weekCount => doses.length;

  /// The latest dose with a known time, today or earlier.
  DateTime? get lastTakenAt {
    DateTime? best;
    for (final d in doses) {
      final at = d.takenAt;
      if (at != null && (best == null || at.isAfter(best))) best = at;
    }
    return best;
  }

  /// The latest known time among today's doses.
  DateTime? get lastTakenToday {
    DateTime? best;
    for (final d in todayDoses) {
      final at = d.takenAt;
      if (at != null && (best == null || at.isAfter(best))) best = at;
    }
    return best;
  }
}

/// Live as-needed summaries of every as-needed medication, keyed by pill id.
final asNeededSummariesProvider =
    StreamProvider.autoDispose<Map<String, AsNeededSummary>>((ref) async* {
      final database = ref.watch(databaseProvider);
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await contextFuture;

      Future<Map<String, AsNeededSummary>> load() async {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final from = routineDateKey(
          DateTime(today.year, today.month, today.day - 8),
        );
        final through = routineDateKey(
          DateTime(today.year, today.month, today.day + 1),
        );
        return access.withGrant(context, () async {
          final records = await database.medicationLedgerDao
              .getForUserLocalDateRange(context.ownerUserId, from, through);
          final details = await (database.select(
            database.careEventDetails,
          )..where((d) => d.workspaceId.equals(context.workspaceId))).get();
          final detailsByEvent = {for (final d in details) d.eventId: d};
          final pills =
              await (database.select(database.pills)..where(
                    (p) => p.isPrn.equals(true) & p.isDeleted.equals(false),
                  ))
                  .get();
          final balances = await (database.select(
            database.reviewedStockBalances,
          )..where((b) => b.workspaceId.equals(context.workspaceId))).get();
          final balanceByPill = {for (final b in balances) b.pillId: b};

          final byPill = <String, List<AsNeededDose>>{};
          for (final record in records) {
            final occurrence = record.occurrence;
            final pillId = occurrence.pillId;
            if (pillId == null || occurrence.source != 'prn') continue;
            final entry = historyEntryFromOccurrenceRecord(
              record,
              now: now,
              detailsByEvent: detailsByEvent,
              pillNamesById: const {},
            );
            if (entry.recordedState != 'taken') continue;
            final at = entry.takenAt?.toLocal();
            final DateTime day;
            if (at != null) {
              day = DateTime(at.year, at.month, at.day);
            } else {
              final planned = parseRoutineDate(occurrence.plannedLocalDate);
              day = DateTime(planned.year, planned.month, planned.day);
            }
            final age = today.difference(day).inDays;
            if (age < 0 || age > 6) continue;
            byPill
                .putIfAbsent(pillId, () => [])
                .add(
                  AsNeededDose(
                    occurrenceId: occurrence.id,
                    pillId: pillId,
                    day: day,
                    takenAt: at,
                    amount: entry.amount,
                    note: entry.note,
                  ),
                );
          }
          int newestFirst(AsNeededDose a, AsNeededDose b) {
            final byDay = b.day.compareTo(a.day);
            if (byDay != 0) return byDay;
            final x = a.takenAt;
            final y = b.takenAt;
            if (x == null && y == null) return 0;
            if (x == null) return 1;
            if (y == null) return -1;
            return y.compareTo(x);
          }

          return {
            for (final pill in pills)
              pill.id: AsNeededSummary(
                pillId: pill.id,
                // A pill without doses has no list yet: sort a fresh copy, never
                // the shared const one, or one idle pill fails every card.
                doses: [...?byPill[pill.id]]..sort(newestFirst),
                today: today,
                stock: _stockOf(pill, balanceByPill[pill.id]),
              ),
          };
        });
      }

      yield* database
          .customSelect(
            // Drift shares identical SQL streams; keep this one distinct.
            'SELECT 1 AS as_needed_summary_changes',
            readsFrom: {
              database.pills,
              database.medicationOccurrences,
              database.occurrenceEvents,
              database.careEventDetails,
              database.reviewedStockBalances,
            },
          )
          .watch()
          .asyncMap((_) => load());
    });

AsNeededStock? _stockOf(Pill pill, ReviewedStockBalance? balance) {
  final threshold = pill.lowStockThreshold;
  if (balance != null) {
    try {
      final quantity = StockQuantity.fromJson(
        Map<String, dynamic>.from(jsonDecode(balance.quantityJson) as Map),
      );
      final value =
          quantity.numerator.toDouble() / quantity.denominator.toDouble();
      return _stock(value, quantity.unit, threshold);
    } on Object {
      return null;
    }
  }
  final left = pill.currentStock;
  if (left == null) return null;
  return _stock(left.toDouble(), null, threshold);
}

AsNeededStock _stock(double value, String? unit, int? threshold) {
  final text = value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  final scale = threshold != null && threshold > 0 ? threshold * 4.0 : null;
  return AsNeededStock(
    left: text,
    unit: unit,
    low: threshold != null && threshold > 0 && value <= threshold,
    fraction: scale == null ? null : (value / scale).clamp(0.0, 1.0),
  );
}
