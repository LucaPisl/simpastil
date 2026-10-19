import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
