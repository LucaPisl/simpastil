import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_shape.dart';
import 'package:simpastil/core/storage/preference_keys.dart';

/// The Android widget reads these shared-preference names natively. Renaming
/// one on either side silently blanks the widget, so both sides are pinned.
void main() {
  const kotlinContract =
      'android/app/src/main/kotlin/com/simpastil/simpastil/'
      'WidgetProjectionContract.kt';

  test('the Dart widget keys keep their wire names', () {
    expect(kTodayDosesKey, 'today_doses');
    expect(kSnapshotDayKey, 'snapshot_day');
    expect(kAppThemeModeKey, 'app_theme_mode');
  });

  test('the Kotlin widget contract reads exactly the same names', () {
    final source = File(kotlinContract).readAsStringSync();
    expect(source, contains('const val snapshotKey = "$kTodayDosesKey"'));
    expect(source, contains('const val snapshotDayKey = "$kSnapshotDayKey"'));
    expect(source, contains('const val appThemeModeKey = "$kAppThemeModeKey"'));
  });

  test('the Kotlin widget reads the shape fields and all nine shapes', () {
    final contract = File(kotlinContract).readAsStringSync();
    expect(contract, contains('const val rowShapeField = "shape"'));
    expect(contract, contains('const val rowImprintField = "imprint"'));
    final look = File(
      'android/app/src/main/kotlin/com/simpastil/simpastil/'
      'WidgetMedicationLook.kt',
    ).readAsStringSync();
    for (final shape in MedicationShape.values) {
      expect(look, contains('("${shape.wire}")'));
    }
    expect(
      RegExp(r'\("[a-z]+"\)[,;]').allMatches(look).length,
      MedicationShape.values.length,
    );
  });
}
