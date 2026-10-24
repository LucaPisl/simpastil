import 'dart:convert';

import '../db/database.dart';
import '../inventory/exact_stock.dart';
import '../inventory/pill_stock.dart';
import 'medication_amount.dart';
import 'stock_effect.dart';

/// What one dose command does to a tracked medicine's stock on this phone,
/// predicted with the same rules the server applies (see [computeStockEffect]).
class StockPlan {
  StockPlan({
    required this.delta,
    required this.unit,
    required this.adoptedUnit,
    required this.kind,
  });

  /// The signed change. Zero means no inventory event is written.
  final ExactStock delta;

  /// The unit the stock is counted in after the command, null for a plain
  /// count that keeps the whole-dose rule.
  final String? unit;

  /// Set when this command makes a plain whole count adopt a unit.
  final String? adoptedUnit;

  final StockEffectKind kind;

  /// Whether the pill row has to be written at all.
  bool changesPill(Pill pill) => !delta.isZero || unit != pill.stockUnit;
}

/// The amount per use the person reviewed for [pillId], or null.
Future<MedicationAmount?> reviewedAmountPerUse(
  AppDatabase db,
  String pillId,
) async {
  final row = await (db.select(
    db.medicationDetails,
  )..where((d) => d.pillId.equals(pillId))).getSingleOrNull();
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

/// The amount a new dose command into taken carries when the dose itself names
/// none: a connected scheduled occurrence has no planned amount, so the
/// medication's reviewed amount per use stands in for it (when known). That is
/// what lets the server, which never sees the reviewed details, adopt the unit
/// and subtract the same exact amount this phone does. A known [amount] is
/// returned untouched; recorded history is never rewritten by this.
Future<MedicationAmount> doseAmountOrReviewed(
  AppDatabase db, {
  required String? pillId,
  required MedicationAmount amount,
}) async {
  if (!amount.isUnknown || pillId == null) return amount;
  return await reviewedAmountPerUse(db, pillId) ?? amount;
}

/// Plans the stock change of one dose command on a tracked [pill].
///
/// [transition] is the whole-dose change the occurrence reducer computed
/// (-1 into taken, +1 out of it, 0 otherwise); a plain count uses it as it is,
/// so stock that was never counted in a unit behaves exactly as before.
/// [reversed] is the inventory event an undo reverses.
///
/// A plain whole count adopts the unit of the medicine's reviewed amount per
/// use when that unit counts physical pieces (tablets, capsules) and the dose
/// names it, but only when the server [fractionalStock] contract is known: a
/// server without it (1.2.0) subtracts one whole dose and never adopts a unit,
/// so the phone must predict the same. That is how the first half tablet taken subtracts exactly one
/// half with no confirmation. Any other unit keeps the plain count.
Future<StockPlan> planStockChange({
  required AppDatabase db,
  required Pill pill,
  required String action,
  required int transition,
  required MedicationAmount amount,
  required String occurrenceId,
  InventoryEvent? reversed,
  bool fractionalStock = false,
}) async {
  final current = exactStockOf(pill)!;
  final perUse = await reviewedAmountPerUse(db, pill.id);
  final intoTaken = action != 'undo' && transition < 0;
  final adopted = intoTaken && fractionalStock
      ? stockUnitToAdopt(
          tracked: true,
          stockUnit: pill.stockUnit,
          wholeCount: current.isWhole,
          commandAmount: amount,
          amountPerUse: perUse,
        )
      : null;
  final unit = pill.stockUnit ?? adopted;
  if (unit == null) {
    return StockPlan(
      delta: ExactStock.fromInt(transition),
      unit: null,
      adoptedUnit: null,
      kind: transition == 0 ? StockEffectKind.none : StockEffectKind.applied,
    );
  }
  var linkedNet = ExactStock.zero;
  if (transition > 0 && action != 'undo') {
    final events = await db.medicationLedgerDao.getEventsForOccurrence(
      occurrenceId,
    );
    final ids = {
      for (final e in events) ...{e.id, if (e.serverId != null) e.serverId!},
    };
    final inventory = await db.medicationLedgerDao.getInventoryEventsForPill(
      pill.id,
    );
    linkedNet = sumExact(
      inventory
          .where(
            (e) =>
                e.occurrenceEventId != null &&
                ids.contains(e.occurrenceEventId),
          )
          .map(exactDeltaOf),
    );
  }
  final effect = computeStockEffect(
    tracked: true,
    stockUnit: unit,
    amountPerUse: perUse,
    commandAmount: amount,
    action: action,
    transition: transition,
    referencedDelta: reversed == null ? null : exactDeltaOf(reversed),
    linkedNet: linkedNet,
  );
  return StockPlan(
    delta: effect.delta,
    unit: unit,
    adoptedUnit: adopted,
    kind: effect.kind,
  );
}
