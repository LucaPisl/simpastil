import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/core/inventory/stock_format.dart';

void main() {
  String f(String wire, [String lang = 'en']) =>
      formatExactStock(ExactStock.parseWire(wire), languageCode: lang);

  test('whole and common fractions', () {
    expect(f('12'), '12');
    expect(f('12.5'), '12½');
    expect(f('0.25'), '¼');
    expect(f('0.75'), '¾');
    expect(f('-0.5'), '−½');
    expect(f('-3'), '−3');
  });

  test('other values are shown exactly with the locale separator', () {
    expect(f('0.125'), '0.125');
    expect(f('0.125', 'ro'), '0,125');
    expect(f('2.000001'), '2.000001');
  });

  test('thirds are written with a glyph, never rounded to 3.33', () {
    String? t(int n, int d) => formatThirds(BigInt.from(n), BigInt.from(d));
    expect(t(10, 3), '3⅓');
    expect(t(2, 3), '⅔');
    expect(t(-5, 3), '−1⅔');
    expect(t(3, 1), isNull);
    expect(t(1, 2), isNull);
    expect(t(7, 4), isNull);
  });
}
