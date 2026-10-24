import 'dart:ui' show PlatformDispatcher;

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../core/inventory/stock_reading.dart';
import '../../../core/l10n/locale_provider.dart';
import '../../../core/inventory/stock_format.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/prn_limits.dart';
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
    this.recordedAt,
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

  /// When the dose was written down; stands in for the time of a dose whose
  /// time is not known.
  final DateTime? recordedAt;

  /// The instant this dose counts at for the limits: its time when known,
  /// otherwise the moment it was recorded.
  DateTime? get countedAt => takenAt ?? recordedAt?.toLocal();
}

/// Remaining stock for display. Never a command: recording a dose is allowed
/// at any level, including below zero.
class AsNeededStock {
  const AsNeededStock({
    required this.value,
    required this.left,
    required this.unit,
    required this.low,
    required this.fraction,
  });

  /// The exact remaining amount, negative when more was taken than counted.
  final double value;

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
    this.maxPer24h,
    this.minGapMinutes,
  });
  const AsNeededSummary.empty(this.pillId)
    : doses = const [],
      today = null,
      stock = null,
      maxPer24h = null,
      minGapMinutes = null;
  final String pillId;

  /// The limits the person set on the medicine, if any.
  final int? maxPer24h;
  final int? minGapMinutes;

  bool get hasLimit => maxPer24h != null || minGapMinutes != null;

  /// Where one more dose at [at] stands against the limits.
  PrnLimitState limitAt(DateTime at) => evaluatePrnLimit(
    maxPer24h: maxPer24h,
    minGapMinutes: minGapMinutes,
    doses: [
      for (final d in doses)
        if (d.countedAt != null) PrnLimitDose(d.countedAt!),
    ],
    at: at,
  );

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

  /// Whole days the stock lasts at the pace of the last 7 days. Null with
  /// fewer than 3 doses to judge by, with nothing left, or when a dose's
  /// amount cannot be counted against the stock (unknown, or another unit):
  /// the line is left out rather than guessed.
  int? get daysAtRecentPace {
    final stock = this.stock;
    if (stock == null || stock.value <= 0 || doses.length < 3) return null;
    var used = 0.0;
    for (final dose in doses) {
      final unit = stock.unit;
      // A plain count counts doses, so every dose spends one.
      if (unit == null) {
        used += 1;
        continue;
      }
      final amount = dose.amount;
      if (amount.isUnknown || amount.unit != unit) return null;
      used += amount.numerator!.toDouble() / amount.denominator!.toDouble();
    }
    if (used <= 0) return null;
    return (stock.value / (used / 7)).floor();
  }

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
      final languageCode =
          ref.watch(localeOverrideProvider)?.languageCode ??
          PlatformDispatcher.instance.locale.languageCode;
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
                    recordedAt: entry.recordedAt,
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
                stock: _stockOf(pill, balanceByPill[pill.id], languageCode),
                maxPer24h: pill.prnMaxPer24h,
                minGapMinutes: pill.prnMinGapMinutes,
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

AsNeededStock? _stockOf(
  Pill pill,
  ReviewedStockBalance? balance,
  String languageCode,
) {
  final reading = readStock(pill, balance);
  return reading == null
      ? null
      : asNeededStockOf(
          reading,
          pill.lowStockThreshold,
          languageCode: languageCode,
        );
}

/// The as-needed card's view of [reading]: low at or under [threshold], and a
/// bar scaled to four times that level. The count is written in
/// [languageCode]: thirds as `3⅓`, never `3.33`, and the decimal comma in
/// Romanian.
AsNeededStock asNeededStockOf(
  StockReading reading,
  int? threshold, {
  String languageCode = 'en',
}) {
  final value = reading.value;
  final scale = threshold != null && threshold > 0 ? threshold * 4.0 : null;
  return AsNeededStock(
    value: value,
    left: reading.unit != null && reading.exact != null
        ? formatExactStock(reading.exact!, languageCode: languageCode)
        : reading.thirdsText ??
              (languageCode == 'ro'
                  ? reading.text.replaceAll('.', ',')
                  : reading.text),
    unit: reading.unit,
    low: threshold != null && threshold > 0 && value <= threshold,
    fraction: scale == null ? null : (value / scale).clamp(0.0, 1.0),
  );
}
