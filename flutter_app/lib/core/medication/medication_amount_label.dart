import '../inventory/exact_stock.dart';
import '../inventory/stock_format.dart';
import 'medication_amount.dart';
import 'unit_names.dart';

/// A reviewed amount in words, the same on every screen: `½ tablet`,
/// `1 tablet`, `2 tablets`, `1½ tablets`, `500 mg`.
///
/// The quantity uses the glyphs of [formatExactStock] (½ ¼ ¾ and the locale's
/// decimal separator). A third has no exact six-decimal form, so exact thirds
/// (`1/3`, `2/3`, `4/3`) get the glyphs ⅓ ⅔ (`1⅓`) from the fraction itself;
/// any other amount without an exact form keeps the text it was typed with.
/// The units the app knows (tablet, capsule, comprimat, pastilă) are named in
/// [languageCode] with the singular for an amount of one or less and the
/// plural above it (Romanian `1 comprimat`, `3 comprimate`, `20 de
/// comprimate`; English when the language has no translation); any other unit
/// is shown exactly as it was stored.
String formatMedicationAmount(
  MedicationAmount amount, {
  String languageCode = 'en',
}) {
  final text = amount.quantityText;
  final unit = amount.unit;
  if (text == null || unit == null) return '';
  final scaledDividend = amount.numerator! * BigInt.from(1000000);
  final exact = scaledDividend % amount.denominator! == BigInt.zero
      ? ExactStock.tryParseWire(_wire(scaledDividend ~/ amount.denominator!))
      : null;
  final quantity = exact == null
      ? _thirds(amount) ?? text
      : formatExactStock(exact, languageCode: languageCode);
  return '$quantity ${_unitFor(unit, amount, languageCode)}';
}

String _wire(BigInt scaled) {
  final whole = scaled ~/ BigInt.from(1000000);
  final rest = (scaled % BigInt.from(1000000)).toString().padLeft(6, '0');
  final fraction = rest.replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}

String _unitFor(String unit, MedicationAmount amount, String languageCode) {
  final count = unitCountFor(
    amount.numerator!.toDouble() / amount.denominator!.toDouble(),
  );
  return medicationUnitName(
        localizationsForLanguage(languageCode),
        unit,
        count,
      ) ??
      unit;
}

/// The amount as whole + ⅓/⅔ when it is exactly a number of thirds (and not a
/// whole number, which has an exact form), else null.
String? _thirds(MedicationAmount amount) {
  final scaled = amount.numerator! * BigInt.from(3);
  if (scaled % amount.denominator! != BigInt.zero) return null;
  final thirds = scaled ~/ amount.denominator!;
  final whole = thirds ~/ BigInt.from(3);
  final glyph = thirds % BigInt.from(3) == BigInt.one ? '⅓' : '⅔';
  return '${whole == BigInt.zero ? '' : whole}$glyph';
}
