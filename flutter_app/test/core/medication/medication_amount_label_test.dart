import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_amount_label.dart';

String label(String q, String u, [String lang = 'en']) =>
    formatMedicationAmount(MedicationAmount.known(q, u), languageCode: lang);

void main() {
  test('uses fraction glyphs and the singular up to one', () {
    expect(label('1/2', 'tablets'), '½ tablet');
    expect(label('1/4', 'tablets'), '¼ tablet');
    expect(label('3/4', 'tablet'), '¾ tablet');
    expect(label('1', 'tablets'), '1 tablet');
    expect(label('1', 'capsules'), '1 capsule');
  });

  test('uses the plural above one', () {
    expect(label('2', 'tablet'), '2 tablets');
    expect(label('3/2', 'capsule'), '1½ capsules');
    expect(label('3/2', 'tablet'), '1½ tablets');
  });

  test('keeps other units exactly as typed', () {
    expect(label('500', 'mg'), '500 mg');
    expect(label('1/2', 'drops'), '½ drops');
    expect(label('1', 'Pumps'), '1 Pumps');
  });

  test('uses third glyphs for exact thirds', () {
    expect(label('1/3', 'tablet'), '⅓ tablet');
    expect(label('2/3', 'tablets'), '⅔ tablet');
    expect(label('4/3', 'tablets'), '1⅓ tablets');
    expect(label('5/3', 'capsule'), '1⅔ capsules');
    expect(label('2/6', 'tablet'), '⅓ tablet');
    expect(label('1/3', 'drops'), '⅓ drops');
  });

  test('keeps the typed text when there is no exact form', () {
    expect(label('1/7', 'tablet'), '1/7 tablet');
    expect(label('0.333333', 'tablet'), '0.333333 tablet');
  });

  test('uses the locale decimal separator and the stored Romanian unit', () {
    expect(label('1.2', 'tablets', 'ro'), '1,2 comprimate');
    expect(label('1', 'comprimat', 'ro'), '1 comprimat');
    expect(label('2', 'comprimate', 'ro'), '2 comprimate');
  });
}
