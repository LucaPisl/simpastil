import '../inventory/exact_stock.dart';
import 'medication_amount.dart';

/// What a dose command does to the medicine's stock.
enum StockEffectKind { none, notTracked, applied, needsReview }

class StockEffectResult {
  StockEffectResult(this.kind, this.delta);

  final StockEffectKind kind;

  /// Zero unless [kind] is [StockEffectKind.applied].
  final ExactStock delta;
}

const _countableUnitCanonical = <String, String>{
  'tablet': 'tablet',
  'tablets': 'tablet',
  'tab': 'tablet',
  'tabs': 'tablet',
  'capsule': 'capsule',
  'capsules': 'capsule',
  'cap': 'capsule',
  'caps': 'capsule',
  'capsula': 'capsule',
  'capsulă': 'capsule',
  'comprimat': 'comprimat',
  'comprimate': 'comprimat',
  'pastila': 'pastilă',
  'pastilă': 'pastilă',
  'pastile': 'pastilă',
};

String? _countableKey(String? unit) {
  if (unit == null) return null;
  var key = unit.trim().toLowerCase();
  if (key.endsWith('.')) key = key.substring(0, key.length - 1);
  return _countableUnitCanonical[key];
}

/// Units that count whole things a person can split. Only stock counted in one
/// of these adopts the amount's unit by itself; anything else (ml, drops, mg)
/// keeps a plain count until a person confirms the unit.
bool isCountableStockUnit(String? unit) => _countableKey(unit) != null;

/// The one spelling a countable unit is stored in (`tablets`, `Tab.` and
/// `tablet` all become `tablet`), so the same unit never exists in two forms.
/// Any other unit is only trimmed. The server twin is `canonicalStockUnit`.
String canonicalStockUnit(String unit) => _countableKey(unit) ?? unit.trim();

/// Whether two units name the same thing: countable units ignore number and
/// case (`tablet` equals `Tablets`); any other unit compares trimmed.
bool sameStockUnit(String? a, String? b) {
  if (a == null || b == null) return false;
  final ka = _countableKey(a);
  final kb = _countableKey(b);
  if (ka != null || kb != null) return ka == kb;
  return a.trim() == b.trim();
}

/// The unit a plain whole-count stock adopts when a build that sends amounts
/// records a dose from it, or null. Mirrors the server's rule exactly: the
/// reviewed amount per use is in a countable unit and the dose names that unit.
String? stockUnitToAdopt({
  required bool tracked,
  required String? stockUnit,
  required bool wholeCount,
  required MedicationAmount? commandAmount,
  required MedicationAmount? amountPerUse,
}) {
  if (!tracked || stockUnit != null || !wholeCount) return null;
  if (commandAmount == null || commandAmount.isUnknown) return null;
  if (amountPerUse == null || amountPerUse.isUnknown) return null;
  if (!isCountableStockUnit(amountPerUse.unit) ||
      !sameStockUnit(commandAmount.unit, amountPerUse.unit)) {
    return null;
  }
  return canonicalStockUnit(amountPerUse.unit!);
}

/// The stock side of one dose command, as a pure function. The server runs the
/// same rules (`server/src/modules/medication/stock-effect.ts`) and both read
/// `contracts/fixtures/fractional-stock-v1.json`.
///
/// A plain count (no unit) keeps the whole-dose rule. Stock counted in a unit
/// subtracts the exact amount taken; an amount that cannot be applied exactly
/// (unknown, another unit, one third) never changes the count and never
/// blocks the dose: the effect is [StockEffectKind.needsReview].
StockEffectResult computeStockEffect({
  required bool tracked,
  required String? stockUnit,
  required MedicationAmount? amountPerUse,
  required MedicationAmount? commandAmount,
  required String action,
  required int transition,
  required ExactStock? referencedDelta,
  required ExactStock linkedNet,
}) {
  final none = StockEffectResult(StockEffectKind.none, ExactStock.zero);
  if (!tracked) {
    return StockEffectResult(StockEffectKind.notTracked, ExactStock.zero);
  }
  if (stockUnit == null) {
    final delta = ExactStock.fromInt(transition);
    return delta.isZero
        ? none
        : StockEffectResult(StockEffectKind.applied, delta);
  }
  if (action == 'undo') {
    if (referencedDelta == null || referencedDelta.isZero) return none;
    return StockEffectResult(StockEffectKind.applied, -referencedDelta);
  }
  if (transition == 0) return none;
  if (transition > 0) {
    // Leaving taken gives back exactly what this dose consumed.
    return linkedNet.isZero
        ? none
        : StockEffectResult(StockEffectKind.applied, -linkedNet);
  }
  final known = commandAmount != null && !commandAmount.isUnknown
      ? commandAmount
      : (amountPerUse != null && !amountPerUse.isUnknown ? amountPerUse : null);
  if (known == null || !sameStockUnit(known.unit, stockUnit)) {
    return StockEffectResult(StockEffectKind.needsReview, ExactStock.zero);
  }
  final scaled = ExactStock.fromAmount(known);
  if (scaled == null) {
    return StockEffectResult(StockEffectKind.needsReview, ExactStock.zero);
  }
  return StockEffectResult(StockEffectKind.applied, -scaled);
}
