import 'package:drift/drift.dart';

import '../db/database.dart';
import 'exact_stock.dart';

/// The exact stock of a medicine: the stored decimal when it is counted in a
/// unit, else its plain whole count. Null when stock is not tracked.
ExactStock? exactStockOf(Pill pill) {
  final quantity = pill.stockQuantity;
  if (quantity != null) {
    final parsed = ExactStock.tryParseWire(quantity);
    if (parsed != null) return parsed;
  }
  final count = pill.currentStock;
  return count == null ? null : ExactStock.fromInt(count);
}

/// An inventory event's exact signed change. An unreadable stored value counts
/// as no change rather than breaking every screen that sums a ledger.
ExactStock exactDeltaOf(InventoryEvent event) =>
    ExactStock.tryParseWire(event.delta) ?? ExactStock.zero;

/// The pill columns that hold [stock]. [unit] is the unit it is counted in, or
/// null for a plain count (which keeps no exact column, so it stays
/// byte-identical to what an older build wrote). The integer mirror is the
/// floor, the whole count older readers see.
PillsCompanion pillStockColumns(ExactStock stock, {String? unit}) =>
    PillsCompanion(
      currentStock: Value(stock.floor),
      stockQuantity: Value(unit == null ? null : stock.toWire()),
      stockUnit: Value(unit),
    );

/// The stock columns a pill row from the server carries. `stockUnit` and
/// `stockQuantity` are sent only for stock counted in a unit, so their absence
/// is a plain count: the unit is cleared and `currentStock` is the integer.
/// A unit with an unreadable quantity falls back to the integer mirror and
/// keeps no exact value rather than inventing one.
PillsCompanion wirePillStock(Map<String, dynamic> item) {
  final unit = item['stockUnit'];
  final quantity = item['stockQuantity'];
  final exact = unit is String && quantity is String
      ? ExactStock.tryParseWire(quantity)
      : null;
  if (exact != null) return pillStockColumns(exact, unit: unit as String);
  final current = item['currentStock'];
  return PillsCompanion(
    currentStock: Value(current is int ? current : null),
    stockQuantity: const Value(null),
    stockUnit: const Value(null),
  );
}

/// The signed change of an inventory event from the server: the exact
/// `quantityDelta` when it is sent (stock counted in a unit), else the integer
/// `delta`. The two always agree on a whole change; neither means the payload
/// is malformed.
String wireInventoryDelta(Map<String, dynamic> item) {
  final quantity = item['quantityDelta'];
  if (quantity is String) {
    final parsed = ExactStock.tryParseWire(quantity);
    if (parsed != null) return parsed.toWire();
  }
  final delta = item['delta'];
  if (delta is int) return delta.toString();
  throw const FormatException('Inventory event change is invalid.');
}
