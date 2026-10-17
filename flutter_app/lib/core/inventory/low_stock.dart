import 'dart:math' as math;

import 'supply_forecast.dart';

/// A scheduled medication whose stock reaches its low-stock level or runs out
/// within this many days is shown as running low, even before it is at its
/// own low-stock level.
const int lowStockHeadsUpDays = 14;

int _daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// Whole days from the forecast's first day (today) until the routine takes
/// the stock to its low-stock level or through it, whichever comes first.
/// Zero when it already has; null when there is no forecast or neither
/// happens inside its horizon.
///
/// The level can be reached long before the stock runs out, so stock that
/// outlasts the horizon still has a day to refill by.
int? daysUntilLowStock(SupplyForecast? forecast) {
  if (forecast == null) return null;
  final dates = [
    if (forecast.refillBy != null) forecast.refillBy!,
    if (forecast.runsOutOn != null) forecast.runsOutOn!,
  ];
  if (dates.isEmpty) return null;
  final first = dates.reduce((a, b) => a.isBefore(b) ? a : b);
  return math.max(0, _daysBetween(forecast.days.first.date, first));
}

/// The one rule for "running low", shared by every place that says so (the
/// stock card on Today, the blister and the summary on Medications): counted
/// [stock] is at or under its own [threshold], or the routine reaches the
/// level within [lowStockHeadsUpDays] days ([runsLowInDays], when there is a
/// routine to forecast). Used-up stock (zero or less) is a separate, stronger
/// state that callers check first.
bool isLowStock({required int stock, int? threshold, int? runsLowInDays}) =>
    (threshold != null && threshold > 0 && stock <= threshold) ||
    (runsLowInDays != null && runsLowInDays <= lowStockHeadsUpDays);
