import 'dart:ui' show Locale;

import '../../l10n/app_localizations.dart';
import 'stock_effect.dart' show canonicalStockUnit, isCountableStockUnit;

/// The count a unit name agrees with, for a quantity shown to a person.
///
/// One or less (`½`, `1`) is singular; anything above is plural. A fractional
/// amount above one (`1½`) takes its whole part, but never below two, so it
/// reads "1½ tablets", not "1½ tablet". An empty or unreadable quantity gets
/// the plural, as a unit with no number in front of it usually is.
int unitCountFor(double? quantity) {
  if (quantity == null || quantity.isNaN || quantity.isInfinite) return 2;
  final value = quantity.abs();
  if (value == 0) return 0; // "0 tablets", not "0 tablet"
  if (value <= 1) return 1;
  final whole = value.floor();
  return whole < 2 ? 2 : whole;
}

/// The name of [unit] in the app's language for [count] (`tablet`,
/// `tablets`; Romanian `comprimat`, `comprimate`, `de comprimate`), or null
/// when [unit] is not one the app has a word for (it is then shown as it was
/// stored).
String? medicationUnitName(AppLocalizations l, String unit, int count) {
  if (!isCountableStockUnit(unit)) return null;
  final word = l.rvu_unitName(switch (canonicalStockUnit(unit)) {
    'tablet' => 'tablet',
    'capsule' => 'capsule',
    'comprimat' => 'comprimat',
    'pastilă' => 'pill',
    _ => 'other',
  }, count);
  return word.isEmpty ? null : word;
}

const _formKeys = <String, String>{
  'syrup': 'syrup',
  'sirop': 'syrup',
  'drops': 'drops',
  'drop': 'drops',
  'picături': 'drops',
  'picaturi': 'drops',
  'cream': 'cream',
  'cremă': 'cream',
  'crema': 'cream',
  'ointment': 'ointment',
  'unguent': 'ointment',
  'gel': 'gel',
  'spray': 'spray',
  'injection': 'injection',
  'injecție': 'injection',
  'injectie': 'injection',
  'patch': 'patch',
  'plasture': 'patch',
  'powder': 'powder',
  'pulbere': 'powder',
  'suppository': 'suppository',
  'supozitor': 'suppository',
};

/// A medication's form (free text, stored as typed: "Tablet", "Syrup") in
/// the app's language ("comprimat" for a tablet in Romanian). A form the app
/// has no word for is shown as it was written.
String medicationFormName(AppLocalizations l, String form) {
  final trimmed = form.trim();
  final key = _formKeys[trimmed.toLowerCase()];
  if (key != null) return l.rv3_formName(key);
  final unitWord = medicationUnitName(l, trimmed, 1);
  if (unitWord == null) return trimmed;
  // Every other form name is capitalised, so a tablet or capsule is too.
  return unitWord[0].toUpperCase() + unitWord.substring(1);
}

/// The localizations for [languageCode], English when the app has none for it
/// (a notification in a language the app is not translated into).
AppLocalizations localizationsForLanguage(String languageCode) {
  try {
    return lookupAppLocalizations(Locale(languageCode));
  } on Object {
    return lookupAppLocalizations(const Locale('en'));
  }
}

/// What a unit text field shows for a stored [unit]: the app's word for a unit
/// it knows (Romanian `comprimat` for a stored `tablet`), else the unit as
/// stored.
String unitFieldText(AppLocalizations l, String? unit) {
  if (unit == null) return '';
  return medicationUnitName(l, unit, 1) ?? unit;
}

/// The unit to store for what a unit text field now says. Text that is still
/// the app's word for [original] (any number) gives [original] back unchanged,
/// so a localized prefill never rewrites `tablet` into `comprimat`; anything
/// the person typed is stored as typed (trimmed).
String unitFromFieldText(AppLocalizations l, String text, String? original) {
  final trimmed = text.trim();
  if (original != null && isCountableStockUnit(original)) {
    final lower = trimmed.toLowerCase();
    for (final count in const [1, 2, 5, 20]) {
      final word = medicationUnitName(l, original, count);
      if (word != null && word.toLowerCase() == lower) return original;
    }
  }
  return trimmed;
}
