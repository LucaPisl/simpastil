import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';

void main() {
  test(
    'Romanian names a refill one way, and the account hint reads naturally',
    () {
      final l = AppLocalizationsRo();
      expect(l.th_stockKindRefill, 'Reînnoire');
      expect(l.tm_refillAt(3), contains('reînnoire'));
      expect(l.tt_refillSoon('2'), contains('reînnoit'));
      expect(l.rvu_colorsAccountHint, 'Se sincronizează cu contul tău');
    },
  );
}
