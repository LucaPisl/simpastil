import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/inventory/stock_reading.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:simpastil/core/medication/expiry.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_amount_label.dart';
import 'package:simpastil/core/medication/unit_names.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_summary.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/today_layout/low_stock_notice.dart';
import 'package:simpastil/features/dashboard/today_side/stock_overview.dart';
import 'package:simpastil/features/pills/presentation/medication_detail_sections.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';

StockRow _row(
  String id, {
  StockLevel level = StockLevel.ok,
  ExpiryState expiry = ExpiryState.none,
  String? unit,
  String left = '5',
}) => StockRow(
  pillId: id,
  name: 'Med $id',
  personId: 'p',
  personName: 'Pat',
  color: null,
  asNeeded: false,
  left: left,
  unit: unit,
  fraction: .2,
  level: level,
  runsLowInDays: 2,
  forecast: null,
  expiry: expiry,
);

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ro = lookupAppLocalizations(const Locale('ro'));
  String label(String q, String u, String lang) =>
      formatMedicationAmount(MedicationAmount.known(q, u), languageCode: lang);

  group('unit names', () {
    test('Romanian takes one, few and "de"', () {
      expect(label('1', 'tablet', 'ro'), '1 comprimat');
      expect(label('3', 'tablet', 'ro'), '3 comprimate');
      expect(label('20', 'tablet', 'ro'), '20 de comprimate');
      expect(label('1', 'capsule', 'ro'), '1 capsulă');
      expect(label('2', 'capsule', 'ro'), '2 capsule');
      expect(label('25', 'capsule', 'ro'), '25 de capsule');
    });

    test('English and an unknown language fall back to English', () {
      expect(label('2', 'tablet', 'en'), '2 tablets');
      expect(label('2', 'tablet', 'fr'), '2 tablets');
      expect(localizationsForLanguage('xx').localeName, 'en');
    });

    test('a Romanian word typed in English still reads as the same unit', () {
      expect(label('2', 'comprimat', 'en'), '2 tablets');
    });

    test('units without a word are not named', () {
      expect(medicationUnitName(en, 'ml', 2), isNull);
    });

    test('the refill notice names the unit in the right number', () {
      expect(
        lowStockDetail(ro, _row('a', unit: 'tablet', left: '1')),
        contains('1 comprimat'),
      );
      expect(
        lowStockDetail(ro, _row('a', unit: 'tablet', left: '3')),
        contains('3 comprimate'),
      );
      expect(
        lowStockDetail(ro, _row('a', unit: 'tablet', left: '20')),
        contains('20 de comprimate'),
      );
      expect(
        lowStockDetail(en, _row('a', unit: 'tablet', left: '5')),
        contains('5 tablets'),
      );
    });
  });

  group('wording', () {
    test('English every-N days is one or other', () {
      expect(en.t09_everyN(1), isNot(contains('1 days')));
      expect(en.t09_everyN(3), contains('3'));
    });

    test('Romanian refill reminder agrees with the count', () {
      expect(ro.tm_refillAt(1), contains('rămâne o unitate'));
      expect(ro.tm_refillAt(3), contains('rămân 3 unități'));
      expect(ro.tm_refillAt(20), contains('rămân 20 de unități'));
    });

    test('a part of a sachet and of a tablet agree in gender', () {
      expect(ro.rvm_partOfUnit('sachet'), 'O parte dintr-un plic');
      expect(ro.rvm_partOfUnit('tablet'), 'O parte dintr-un comprimat');
      expect(en.rvm_partOfUnit('sachet'), contains('sachet'));
    });

    test('Romanian shapes agree with "Forma {shape}"', () {
      expect(ro.mf_shapeRound, 'rotundă');
      expect(ro.mf_shapeOval, 'ovală');
      expect(ro.mx_sectionLimitsHint, isNot(contains('Ești întrebat')));
    });
  });

  group('stock and expiry headings', () {
    test('a medication both low and expiring is in both lists', () {
      final both = _row(
        'a',
        level: StockLevel.low,
        expiry: const ExpiryState(ExpiryPhase.soon, 10),
      );
      final split = splitStockNotices([both, _row('b')]);
      expect(split.low.map((r) => r.pillId), ['a']);
      expect(split.expiring.map((r) => r.pillId), ['a']);
    });

    test('the heading says expired when an expired one is included', () {
      final soon = _row('a', expiry: const ExpiryState(ExpiryPhase.soon, 5));
      final gone = _row(
        'b',
        expiry: const ExpiryState(ExpiryPhase.expired, -2),
      );
      expect(expiryNoticeHeading(en, [soon]), 'Expires soon');
      expect(expiryNoticeHeading(en, [soon, gone]), 'Expired or expiring soon');
      expect(
        expiryNoticeHeading(ro, [soon, gone]),
        'Expirate sau care expiră curând',
      );
    });
  });

  group('as-needed stock', () {
    test('thirds are written as glyphs, with the Romanian comma', () {
      const reading = StockReading(
        value: 3.3333,
        unit: 'tablet',
        fromBalance: true,
        thirdsText: '3⅓',
      );
      final exact = StockReading(
        value: 3,
        unit: 'tablet',
        fromBalance: true,
        exact: ExactStock.parseWire('3.5'),
      );
      expect(asNeededStockOf(exact, 5, languageCode: 'ro').left, '3½');
      expect(asNeededStockOf(reading, 5).left, '3⅓');
      final plain = StockReading(value: 2.5, unit: null, fromBalance: false);
      expect(asNeededStockOf(plain, 5, languageCode: 'ro').left, contains(','));
    });
  });

  group('details need review', () {
    test('blank original text does not count', () {
      expect(dosageNeedsReview(const MedicationReview(name: 'X')), isFalse);
      expect(
        dosageNeedsReview(
          const MedicationReview(name: 'X', originalDosage: '   '),
        ),
        isFalse,
      );
      expect(
        dosageNeedsReview(
          const MedicationReview(name: 'X', originalDosage: '1 pill'),
        ),
        isTrue,
      );
    });
  });

  group('jump row', () {
    test('Next only for an upcoming entry with nothing upcoming before it', () {
      expect(
        jumpRowKind(targetUpcoming: true, earlierUpcoming: false),
        JumpRowKind.next,
      );
      expect(
        jumpRowKind(targetUpcoming: true, earlierUpcoming: true),
        JumpRowKind.later,
      );
      expect(
        jumpRowKind(targetUpcoming: false, earlierUpcoming: true),
        JumpRowKind.plain,
      );
    });
  });
}
