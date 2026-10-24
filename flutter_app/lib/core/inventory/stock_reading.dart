import 'dart:convert';

import '../db/database.dart';
import '../medication/medication_amount.dart';
import '../medication/reviewed_stock.dart';
import 'exact_stock.dart';
import 'pill_stock.dart';
import 'stock_format.dart';
import '../medication/stock_effect.dart' show sameStockUnit;

/// The one stock answer for a medication, read the same way by every screen
/// that shows stock: Today, the Medications list and detail, and the
/// as-needed sheet. Display only; nothing here changes a count.
class StockReading {
  const StockReading({
    required this.value,
    required this.unit,
    required this.fromBalance,
    this.exact,
    this.perUse,
    this.needsRecount = false,
    this.thirdsText,
  });

  /// The exact remaining amount of stock counted in a unit on the account,
  /// null for a plain count and for a local reviewed balance.
  final ExactStock? exact;

  /// The amount one dose takes, in the same unit as [exact], so [whole]
  /// counts doses rather than tablets. Null when the unit is unknown or
  /// differs from the dose's.
  final ExactStock? perUse;

  /// Set when a dose was recorded with an amount the account cannot hold
  /// exactly (a third of a tablet): the count above did not move for it, so it
  /// is only a last known count until the person recounts. Never set from a
  /// reviewed local balance, which keeps such an amount exactly.
  final bool needsRecount;

  /// The reviewed balance written in thirds (`3⅓`) when it is exactly a number
  /// of thirds, which [exact] cannot hold. Null otherwise.
  final String? thirdsText;

  /// The exact remaining amount. Can be negative: a taken dose is never
  /// blocked by stock.
  final double value;

  /// The reviewed balance's unit, for example `tablets`; null for a plain
  /// count.
  final String? unit;

  /// Whether the answer came from the reviewed balance rather than the
  /// medication's stored count.
  final bool fromBalance;

  /// Plain-text amount, for example `12` or `7.5`.
  String get text => exact != null
      ? exact!.toWire()
      : value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

  /// Whole doses left, for the supply forecast and the stock capsule, which
  /// count in whole doses: a half tablet left does not cover another dose.
  int get whole {
    final exact = this.exact;
    final perUse = this.perUse;
    if (exact != null && perUse != null) return exact.dosesFloor(perUse);
    return exact?.floor ?? value.floor();
  }

  /// What an "N left" reading shows: the exact stock in its unit (`27½`)
  /// when the stock is counted in a unit, and whole doses (`12`) for a plain
  /// count. The low-stock and forecast rules keep counting in [whole] doses.
  String leftText(String languageCode) => unit != null && exact != null
      ? formatExactStock(exact!, languageCode: languageCode)
      : thirdsText ?? '$whole';

  /// The amount for people: `12`, `12½` or `7,5` by language.
  String format(String languageCode) => exact != null
      ? formatExactStock(exact!, languageCode: languageCode)
      : thirdsText ?? text;
}

/// Reads [pill]'s stock: the reviewed balance first, because recording keeps
/// it current, then the medication's stored count. Null when neither is
/// tracked, or when the balance cannot be read (an unreadable balance never
/// falls back to a count it has replaced).
StockReading? readStock(
  Pill pill,
  ReviewedStockBalance? balance, {
  MedicationAmount? amountPerUse,
  bool needsRecount = false,
}) {
  if (balance != null) {
    try {
      final quantity = StockQuantity.fromJson(
        Map<String, dynamic>.from(jsonDecode(balance.quantityJson) as Map),
      );
      return StockReading(
        value: quantity.numerator.toDouble() / quantity.denominator.toDouble(),
        unit: quantity.unit,
        fromBalance: true,
        exact: ExactStock.fromRatio(quantity.numerator, quantity.denominator),
        thirdsText: formatThirds(quantity.numerator, quantity.denominator),
      );
    } on Object {
      return null;
    }
  }
  final unit = pill.stockUnit;
  final exact = exactStockOf(pill);
  if (exact == null) return null;
  if (unit == null) {
    return StockReading(
      value: exact.toDouble(),
      unit: null,
      fromBalance: false,
      exact: exact,
      needsRecount: needsRecount,
    );
  }
  final dose = amountPerUse != null && sameStockUnit(amountPerUse.unit, unit)
      ? ExactStock.fromAmount(amountPerUse)
      : null;
  return StockReading(
    value: exact.toDouble(),
    unit: unit,
    fromBalance: false,
    exact: exact,
    perUse: dose,
    needsRecount: needsRecount,
  );
}

/// The amount per use stored on a medication's detail row, or null when the
/// row is missing or its amount is unknown or unreadable.
MedicationAmount? amountOfDetailRow(MedicationDetail? row) {
  if (row == null) return null;
  try {
    final amount = MedicationAmount.fromJson(
      Map<String, Object?>.from(jsonDecode(row.amountJson) as Map),
    );
    return amount.isUnknown ? null : amount;
  } on Object {
    return null;
  }
}
