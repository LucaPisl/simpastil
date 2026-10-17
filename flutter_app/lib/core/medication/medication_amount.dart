/// An exact, reviewed amount. Package strength and stock conversion are separate.
class MedicationAmount {
  const MedicationAmount.unknown()
    : quantityText = null,
      unit = null,
      numerator = null,
      denominator = null;

  MedicationAmount._(this.quantityText, this.unit, BigInt n, BigInt d)
    : numerator = n ~/ n.gcd(d),
      denominator = d ~/ n.gcd(d);

  factory MedicationAmount.known(String quantity, String unit) {
    final text = quantity.trim();
    final explicitUnit = unit.trim();
    if (text.length > 64 || explicitUnit.isEmpty || explicitUnit.length > 80) {
      throw const FormatException(
        'An amount requires a quantity and explicit unit',
      );
    }
    BigInt n;
    BigInt d;
    final fraction = RegExp(r'^(\d+)\s*/\s*(\d+)$').firstMatch(text);
    final decimal = RegExp(r'^(\d+)(?:[.,](\d+))?$').firstMatch(text);
    if (fraction != null) {
      n = BigInt.parse(fraction.group(1)!);
      d = BigInt.parse(fraction.group(2)!);
    } else if (decimal != null) {
      final digits = decimal.group(2) ?? '';
      n = BigInt.parse('${decimal.group(1)!}$digits');
      d = BigInt.from(10).pow(digits.length);
    } else {
      throw const FormatException('Use a positive decimal or fraction');
    }
    if (n <= BigInt.zero || d <= BigInt.zero) {
      throw const FormatException('Use a positive decimal or fraction');
    }
    return MedicationAmount._(text, explicitUnit, n, d);
  }

  /// Reads legacy free text ("1 pastila", "500 mg", "1/2 tablet") as an exact
  /// amount, or returns null when the text is not one plain quantity and unit.
  ///
  /// Anything carrying a second number is never guessed: a range
  /// ("1-2 tablets"), a multiplier ("2x500mg") or a strength beside a count
  /// ("2 tablets 500mg") all mean something a person has to decide, so they
  /// stay unreviewed instead of becoming a wrong dose.
  static MedicationAmount? fromLegacyText(String text) {
    final match = RegExp(
      r'^(\d+\s*/\s*\d+|\d+(?:[.,]\d+)?)\s*(.*)$',
    ).firstMatch(text.trim());
    if (match == null) return null;
    final unit = match.group(2)!.trim();
    if (unit.isEmpty || unit.contains(RegExp(r'\d'))) return null;
    try {
      return MedicationAmount.known(match.group(1)!, unit);
    } on FormatException {
      return null;
    }
  }

  final String? quantityText;
  final String? unit;
  final BigInt? numerator;
  final BigInt? denominator;
  bool get isUnknown => quantityText == null;

  Map<String, Object?> toJson() => {
    'version': 1,
    'state': isUnknown ? 'unknown' : 'known',
    if (!isUnknown) 'quantity': quantityText,
    if (!isUnknown) 'unit': unit,
  };

  factory MedicationAmount.fromJson(Map<String, Object?> value) {
    if (value['version'] != 1) {
      throw const FormatException('Unsupported amount version');
    }
    if (value['state'] == 'unknown' &&
        !value.containsKey('quantity') &&
        !value.containsKey('unit')) {
      return const MedicationAmount.unknown();
    }
    if (value['state'] != 'known' ||
        value['quantity'] is! String ||
        value['unit'] is! String) {
      throw const FormatException('Invalid reviewed amount');
    }
    return MedicationAmount.known(
      value['quantity'] as String,
      value['unit'] as String,
    );
  }
}
