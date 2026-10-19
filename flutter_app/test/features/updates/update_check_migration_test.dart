import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/features/updates/data/github_release_check.dart';
import 'package:simpastil/features/updates/data/update_check_migration.dart';

Future<SharedPreferences> _prefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  test('a fresh install keeps the check unset, so it is off', () async {
    final prefs = await _prefs({});

    await migrateUpdateCheckDefault(prefs);

    expect(prefs.containsKey(updateCheckEnabledKey), isFalse);
    expect(prefs.getBool(updateCheckEnabledKey) == true, isFalse);
    expect(prefs.getBool(updateCheckDefaultMigratedKey), isTrue);
  });

  test('an existing install that never chose keeps the check on', () async {
    final prefs = await _prefs({'app_locale': 'en'});

    await migrateUpdateCheckDefault(prefs);

    expect(prefs.getBool(updateCheckEnabledKey), isTrue);
    expect(prefs.getBool(updateCheckDefaultMigratedKey), isTrue);
  });

  test('an existing install that chose off stays off', () async {
    final prefs = await _prefs({
      'app_locale': 'en',
      updateCheckEnabledKey: false,
    });

    await migrateUpdateCheckDefault(prefs);

    expect(prefs.getBool(updateCheckEnabledKey), isFalse);
    expect(prefs.getBool(updateCheckDefaultMigratedKey), isTrue);
  });

  test('an existing install that chose on stays on', () async {
    final prefs = await _prefs({
      'app_locale': 'en',
      updateCheckEnabledKey: true,
    });

    await migrateUpdateCheckDefault(prefs);

    expect(prefs.getBool(updateCheckEnabledKey), isTrue);
  });

  test('runs only once, so a later choice or later use is respected', () async {
    final prefs = await _prefs({'app_locale': 'en'});
    await migrateUpdateCheckDefault(prefs);
    await prefs.setBool(updateCheckEnabledKey, false);

    await migrateUpdateCheckDefault(prefs);

    expect(prefs.getBool(updateCheckEnabledKey), isFalse);

    // A fresh install that has since stored other preferences must not be
    // mistaken for an old one at its second start.
    final fresh = await _prefs({});
    await migrateUpdateCheckDefault(fresh);
    await fresh.setString('app_locale', 'en');

    await migrateUpdateCheckDefault(fresh);

    expect(fresh.containsKey(updateCheckEnabledKey), isFalse);
  });

  test('an already migrated device is left untouched', () async {
    final prefs = await _prefs({
      'app_locale': 'en',
      updateCheckDefaultMigratedKey: true,
    });

    await migrateUpdateCheckDefault(prefs);

    expect(prefs.containsKey(updateCheckEnabledKey), isFalse);
  });
}
