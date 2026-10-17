import 'dart:math' as math;

import 'package:timezone/timezone.dart' as tz;

import '../medication/routine_definition.dart';

/// One routine version as it applies from [effectiveFrom].
typedef SupplyRoutine = ({
  DateTime effectiveFrom,
  RoutineDefinition definition,
});

/// One day ahead: how many doses the routine plans and how many of them the
/// stock still covers.
class SupplyDay {
  const SupplyDay({
    required this.date,
    required this.planned,
    required this.covered,
  });

  /// The routine's local date, as a UTC midnight.
  final DateTime date;
  final int planned;
  final int covered;

  bool get short => covered < planned;
}

/// How far a medication's stock reaches along its routine.
///
/// Stock counts doses: every taken dose spends one (see the occurrence
/// reducer), whatever the amount per dose. Today counts only the doses still
/// to come, so a dose that is late but not yet recorded is not double
/// counted against tomorrow.
class SupplyForecast {
  const SupplyForecast({
    required this.stock,
    required this.days,
    required this.runsOutOn,
    required this.refillBy,
    required this.horizon,
  });

  /// Stock as counted; never below zero here.
  final int stock;

  /// From today, at most [horizon] days.
  final List<SupplyDay> days;

  /// The first day with a dose the stock cannot cover; null when the stock
  /// lasts past the horizon.
  final DateTime? runsOutOn;

  /// The first day that ends at or under the low-stock threshold, when it
  /// comes before [runsOutOn].
  final DateTime? refillBy;
  final int horizon;

  /// The last day whose planned doses are all covered; null when today
  /// already falls short.
  DateTime? get enoughUntil {
    if (runsOutOn == null) return null;
    final at = days.indexWhere((d) => d.date == runsOutOn);
    for (var i = at - 1; i >= 0; i--) {
      if (days[i].planned > 0) return days[i].date;
    }
    return null;
  }

  bool get lastsPastHorizon => runsOutOn == null;

  /// Today's remaining doses are already more than the stock.
  bool get shortToday => runsOutOn != null && runsOutOn == days.first.date;
}

/// Projects [stock] along the routine [versions] from [now].
///
/// Returns null when there is nothing to project: no routine, or no planned
/// dose in the horizon (as needed only, or a routine that has ended).
SupplyForecast? forecastSupply({
  required int stock,
  int? threshold,
  required List<SupplyRoutine> versions,
  required DateTime now,
  int horizon = 60,
}) {
  if (versions.isEmpty) return null;
  final sorted = [...versions]
    ..sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));
  RoutineDefinition? at(DateTime instant) {
    RoutineDefinition? found;
    for (final v in sorted) {
      if (!v.effectiveFrom.isAfter(instant)) found = v.definition;
    }
    return found;
  }

  final current = at(now) ?? sorted.first.definition;
  tz.TZDateTime local;
  try {
    local = tz.TZDateTime.from(now, tz.getLocation(current.timeZone));
  } on Object {
    local = tz.TZDateTime.from(now, tz.UTC);
  }
  final today = DateTime.utc(local.year, local.month, local.day);
  final nowMinute = local.hour * 60 + local.minute;

  var left = math.max(0, stock);
  final days = <SupplyDay>[];
  DateTime? runsOut;
  DateTime? refill;
  var anyPlanned = false;
  for (var i = 0; i < horizon; i++) {
    final date = DateTime.utc(today.year, today.month, today.day + i);
    // The version in force at the middle of that day decides it.
    final definition = i == 0
        ? current
        : at(date.add(const Duration(hours: 12))) ?? current;
    var planned = 0;
    if (definition.includes(date)) {
      planned = i == 0
          ? definition.times
                .where((t) => t.hour * 60 + t.minute > nowMinute)
                .length
          : definition.times.length;
    }
    if (planned > 0) anyPlanned = true;
    final covered = math.min(planned, left);
    left -= covered;
    days.add(SupplyDay(date: date, planned: planned, covered: covered));
    if (runsOut == null && covered < planned) runsOut = date;
    if (refill == null &&
        runsOut == null &&
        threshold != null &&
        planned > 0 &&
        left <= threshold) {
      refill = date;
    }
  }
  if (!anyPlanned) return null;
  return SupplyForecast(
    stock: math.max(0, stock),
    days: days,
    runsOutOn: runsOut,
    refillBy: refill,
    horizon: horizon,
  );
}
