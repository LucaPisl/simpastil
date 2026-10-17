import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/l10n/app_localizations_ro.dart';

void main() {
  test('English backup people counts pluralise', () {
    final l = AppLocalizationsEn();
    expect(l.t15_retainedPeopleCount(1), '1 retained person');
    expect(l.t15_retainedPeopleCount(3), '3 retained people');
    expect(l.t15_selectedPeopleCount(1), '1 person selected');
    expect(l.t15_selectedPeopleCount(2), '2 people selected');
  });

  test('Romanian backup people counts use one, few and other forms', () {
    final l = AppLocalizationsRo();
    expect(l.t15_retainedPeopleCount(1), '1 persoană păstrată');
    expect(l.t15_retainedPeopleCount(3), '3 persoane păstrate');
    expect(l.t15_retainedPeopleCount(20), '20 de persoane păstrate');
    expect(l.t15_selectedPeopleCount(1), '1 persoană selectată');
    expect(l.t15_selectedPeopleCount(2), '2 persoane selectate');
    expect(l.t15_selectedPeopleCount(25), '25 de persoane selectate');
  });
}
