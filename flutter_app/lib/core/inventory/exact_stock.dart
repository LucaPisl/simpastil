import '../medication/medication_amount.dart';

/// An exact stock quantity or stock change: a decimal with at most six
/// fraction digits, held as a [BigInt] scaled by 10^6 so no step goes through
/// a floating-point number. The server keeps the same value in a
/// `numeric(20,6)` and sends it as the canonical string [toWire], so whole
/// values read exactly like the integers older builds know.
///
/// The shared vectors in `contracts/fixtures/fractional-stock-v1.json` pin the
/// same rules for the server.
class ExactStock implements Comparable<ExactStock> {
  const ExactStock._(this.scaled);

  /// The value times 10^6.
  final BigInt scaled;

  static final BigInt _scale = BigInt.from(1000000);
  static final BigInt _limit = BigInt.from(10).pow(14) * _scale;

  static final ExactStock zero = ExactStock._(BigInt.zero);

  /// The one wire spelling: no plus sign, no trailing zeros, no `-0`.
  static final RegExp _canonical = RegExp(
    r'^-?(0|[1-9]\d{0,13})(\.\d{0,5}[1-9])?$',
  );

  factory ExactStock.fromInt(int value) =>
      ExactStock._(BigInt.from(value) * _scale);

  /// Parses the canonical wire spelling, or returns null for anything else.
  static ExactStock? tryParseWire(String text) {
    if (text == '-0' || !_canonical.hasMatch(text)) return null;
    final negative = text.startsWith('-');
    final body = negative ? text.substring(1) : text;
    final parts = body.split('.');
    final fraction = parts.length == 2 ? parts[1].padRight(6, '0') : '000000';
    final scaled = BigInt.parse(parts[0]) * _scale + BigInt.parse(fraction);
    return ExactStock._(negative ? -scaled : scaled);
  }

  /// Parses the wire spelling; a value from the server that is not canonical
  /// is a contract breach, never rounded.
  factory ExactStock.parseWire(String text) {
    final parsed = tryParseWire(text);
    if (parsed == null) throw FormatException('Not a stock quantity', text);
    return parsed;
  }

  /// Reads a count a person typed: `10`, `10,5`, `10.5`, `10 1/2`, `1/2`,
  /// optionally negative. Returns null for anything that is not exactly a
  /// stock quantity (more than six decimals, one third, text).
  static ExactStock? tryParseInput(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    var negative = false;
    if (text.startsWith('-') || text.startsWith('−')) {
      negative = true;
      text = text.substring(1).trim();
    }
    BigInt numerator;
    BigInt denominator;
    final mixed = RegExp(r'^(\d+)\s+(\d+)\s*/\s*(\d+)$').firstMatch(text);
    final fraction = RegExp(r'^(\d+)\s*/\s*(\d+)$').firstMatch(text);
    final decimal = RegExp(r'^(\d+)(?:[.,](\d+))?$').firstMatch(text);
    if (mixed != null) {
      final d = BigInt.parse(mixed.group(3)!);
      numerator =
          BigInt.parse(mixed.group(1)!) * d + BigInt.parse(mixed.group(2)!);
      denominator = d;
    } else if (fraction != null) {
      numerator = BigInt.parse(fraction.group(1)!);
      denominator = BigInt.parse(fraction.group(2)!);
    } else if (decimal != null) {
      final digits = decimal.group(2) ?? '';
      numerator = BigInt.parse('${decimal.group(1)!}$digits');
      denominator = BigInt.from(10).pow(digits.length);
    } else {
      return null;
    }
    return _fromRatio(numerator, denominator, negative: negative);
  }

  /// A positive administration amount as stock, or null when it is unknown or
  /// does not terminate within six decimals (one third).
  static ExactStock? fromAmount(MedicationAmount? amount) {
    if (amount == null || amount.isUnknown) return null;
    final value = _fromRatio(amount.numerator!, amount.denominator!);
    if (value == null || value.scaled <= BigInt.zero) return null;
    return value;
  }

  /// [numerator] / [denominator] when that is exactly a stock quantity (at
  /// most six decimals, in range), else null: a third has no exact decimal.
  static ExactStock? fromRatio(BigInt numerator, BigInt denominator) {
    if (denominator <= BigInt.zero) return null;
    final negative = numerator < BigInt.zero;
    return _fromRatio(
      negative ? -numerator : numerator,
      denominator,
      negative: negative,
    );
  }

  static ExactStock? _fromRatio(
    BigInt numerator,
    BigInt denominator, {
    bool negative = false,
  }) {
    if (denominator <= BigInt.zero) return null;
    final scaled = numerator * _scale;
    if (scaled % denominator != BigInt.zero) return null;
    final value = scaled ~/ denominator;
    if (value >= _limit) return null;
    return ExactStock._(negative ? -value : value);
  }

  /// Whether the sum or difference still fits the stored range.
  bool get inRange => scaled > -_limit && scaled < _limit;

  bool get isWhole => scaled % _scale == BigInt.zero;
  bool get isZero => scaled == BigInt.zero;
  bool get isNegative => scaled < BigInt.zero;

  /// Rounds toward negative infinity: the whole count older readers see.
  int get floor {
    var whole = scaled ~/ _scale;
    if (scaled % _scale != BigInt.zero && scaled < BigInt.zero) {
      whole -= BigInt.one;
    }
    return whole.toInt();
  }

  /// The canonical wire spelling.
  String toWire() {
    if (scaled == BigInt.zero) return '0';
    final negative = scaled < BigInt.zero;
    final magnitude = negative ? -scaled : scaled;
    final whole = (magnitude ~/ _scale).toString();
    final fraction = (magnitude % _scale)
        .toString()
        .padLeft(6, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${negative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
  }

  ExactStock operator +(ExactStock other) =>
      ExactStock._(scaled + other.scaled);
  ExactStock operator -(ExactStock other) =>
      ExactStock._(scaled - other.scaled);
  ExactStock operator -() => ExactStock._(-scaled);

  /// How many whole doses of [dose] fit in this stock (never negative).
  int wholeDoses(ExactStock dose) {
    if (dose.scaled <= BigInt.zero || scaled <= BigInt.zero) return 0;
    return (scaled ~/ dose.scaled).toInt();
  }

  /// The signed number of whole [dose]s this stock covers, rounded down, so a
  /// half dose left reads as none and an overdrawn stock stays negative.
  /// [dose] must be positive.
  int dosesFloor(ExactStock dose) {
    if (dose.scaled <= BigInt.zero) return floor;
    final quotient = scaled ~/ dose.scaled;
    final exactDivision = scaled % dose.scaled == BigInt.zero;
    final rounded = scaled < BigInt.zero && !exactDivision
        ? quotient - BigInt.one
        : quotient;
    return rounded.toInt();
  }

  /// The value as a double, for display-only estimates such as a forecast.
  double toDouble() => scaled.toDouble() / _scale.toDouble();

  @override
  int compareTo(ExactStock other) => scaled.compareTo(other.scaled);

  bool operator <(ExactStock other) => scaled < other.scaled;
  bool operator >(ExactStock other) => scaled > other.scaled;

  @override
  bool operator ==(Object other) =>
      other is ExactStock && other.scaled == scaled;

  @override
  int get hashCode => scaled.hashCode;

  @override
  String toString() => toWire();
}

/// Sums wire or stored values; a value that is not canonical is skipped by the
/// caller, never guessed.
ExactStock sumExact(Iterable<ExactStock> values) =>
    values.fold(ExactStock.zero, (sum, value) => sum + value);
