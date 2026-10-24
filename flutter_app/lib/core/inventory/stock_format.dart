import 'exact_stock.dart';

/// Formats an exact stock quantity for display, never rounding a stored value:
/// `12`, `12½`, `¼`, `¾`, `−½`, and otherwise the locale's decimal separator
/// with up to six digits (`0.125`, `0,125` in Romanian).
String formatExactStock(ExactStock value, {String languageCode = 'en'}) {
  final negative = value.isNegative;
  final magnitude = negative ? -value : value;
  final whole = magnitude.scaled ~/ BigInt.from(1000000);
  final rest = magnitude.scaled % BigInt.from(1000000);
  final sign = negative ? '−' : '';
  if (rest == BigInt.zero) return '$sign$whole';
  final glyph = switch (rest.toInt()) {
    500000 => '½',
    250000 => '¼',
    750000 => '¾',
    _ => null,
  };
  if (glyph != null) return '$sign${whole == BigInt.zero ? '' : whole}$glyph';
  final separator = languageCode == 'ro' ? ',' : '.';
  final fraction = rest
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$sign$whole$separator$fraction';
}

/// A balance that is exactly a whole number plus a third or two thirds, as
/// `3⅓`, `⅔` or `−1⅔`. A third has no exact decimal, so the count must be
/// written with a glyph rather than rounded to `3.33`. Null for any other
/// ratio, including whole numbers, which have an exact form.
String? formatThirds(BigInt numerator, BigInt denominator) {
  if (denominator <= BigInt.zero) return null;
  final negative = numerator < BigInt.zero;
  final magnitude = negative ? -numerator : numerator;
  final scaled = magnitude * BigInt.from(3);
  if (scaled % denominator != BigInt.zero) return null;
  final thirds = scaled ~/ denominator;
  final rest = thirds % BigInt.from(3);
  if (rest == BigInt.zero) return null;
  final whole = thirds ~/ BigInt.from(3);
  final glyph = rest == BigInt.one ? '⅓' : '⅔';
  return '${negative ? '−' : ''}${whole == BigInt.zero ? '' : whole}$glyph';
}
