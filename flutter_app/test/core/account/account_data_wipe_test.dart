import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/account/account_data_wipe.dart';
import 'package:simpastil/core/storage/preference_keys.dart';

import '../../helpers/care_recording_fixture.dart';

const _owner = '10000000-0000-4000-8000-000000000001';

void main() {
  test('removes the account care and nothing for other owners', () async {
    final f = await CareRecordingFixture.create(connected: true);
    final db = f.db;
    expect(await db.select(db.profiles).get(), isNotEmpty);
    expect(await db.select(db.medicationOccurrences).get(), isNotEmpty);

    // A different account id removes nothing.
    await removeAccountData(db, accountUserId: 'someone-else');
    expect(await db.select(db.profiles).get(), isNotEmpty);

    await removeAccountData(db, accountUserId: _owner);
    expect(await db.select(db.profiles).get(), isEmpty);
    expect(await db.select(db.pills).get(), isEmpty);
    expect(await db.select(db.schedules).get(), isEmpty);
    expect(await db.select(db.medicationOccurrences).get(), isEmpty);
    expect(await db.select(db.pendingOperations).get(), isEmpty);
    expect(
      await (db.select(
        db.careWorkspaces,
      )..where((w) => w.ownerUserId.equals(_owner))).get(),
      isEmpty,
    );
  });

  test('removes only this account\'s preference keys', () async {
    SharedPreferences.setMockInitialValues({
      'prn_in_stats_$_owner': true,
      'auto_miss_since_$_owner': 5,
      'current_user_id': _owner,
      'app_theme_mode': 'dark',
      'prn_in_stats_other-user': true,
    });
    final prefs = await SharedPreferences.getInstance();
    await removeAccountPreferences(prefs, accountUserId: _owner);
    expect(prefs.getKeys(), {'app_theme_mode', 'prn_in_stats_other-user'});
  });

  test('removes the refused-setting memory and this account\'s chosen '
      'keys', () async {
    SharedPreferences.setMockInitialValues({
      'account_settings_refused_$_owner': '{}',
      'account_settings_refused_other-user': '{}',
      kChosenSettingKeysKey: [
        'snooze_duration_minutes_$_owner',
        'app_locale',
        'snooze_duration_minutes_other-user',
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    await removeAccountPreferences(prefs, accountUserId: _owner);
    expect(prefs.containsKey('account_settings_refused_$_owner'), isFalse);
    expect(prefs.containsKey('account_settings_refused_other-user'), isTrue);
    expect(prefs.getStringList(kChosenSettingKeysKey), [
      'app_locale',
      'snooze_duration_minutes_other-user',
    ]);
  });

  test('the chosen keys follow the same separator rule, and the account\'s '
      'own list goes with it', () async {
    SharedPreferences.setMockInitialValues({
      'chosen_setting_keys_abc': ['app_locale'],
      'chosen_setting_keys_xabc': ['app_locale'],
      kChosenSettingKeysKey: ['snooze_duration_minutes_abc', 'setting_xabc'],
    });
    final prefs = await SharedPreferences.getInstance();
    await removeAccountPreferences(prefs, accountUserId: 'abc');
    expect(prefs.containsKey(chosenSettingKeysPreferenceKey('abc')), isFalse);
    expect(prefs.getStringList('chosen_setting_keys_xabc'), ['app_locale']);
    expect(prefs.getStringList(kChosenSettingKeysKey), ['setting_xabc']);
  });

  test('a device-wide setting the account chose is left to the next '
      'account, and other choosers are kept', () async {
    SharedPreferences.setMockInitialValues({
      'app_locale': 'ro',
      settingChooserPreferenceKey('app_locale'): _owner,
      settingChooserPreferenceKey('appearance_preferences_v1'): 'other-user',
    });
    final prefs = await SharedPreferences.getInstance();
    await removeAccountPreferences(prefs, accountUserId: _owner);
    expect(prefs.getString('app_locale'), 'ro');
    expect(
      prefs.getString(settingChooserPreferenceKey('app_locale')),
      signedOutSettingChooser,
    );
    expect(
      prefs.getString(settingChooserPreferenceKey('appearance_preferences_v1')),
      'other-user',
    );
    expect(prefs.getKeys().where((k) => prefs.get(k) == _owner), isEmpty);
  });

  test('an empty account id removes nothing', () async {
    final values = <String, Object>{
      'prn_in_stats_': true,
      'current_user_id': '',
      kChosenSettingKeysKey: ['app_locale', 'snooze_duration_minutes_x'],
    };
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    await removeAccountPreferences(prefs, accountUserId: '');
    expect(prefs.getKeys(), values.keys.toSet());
    expect(prefs.getStringList(kChosenSettingKeysKey), [
      'app_locale',
      'snooze_duration_minutes_x',
    ]);
  });

  test('completeAccountDeletion carries on after a failed sign-out', () async {
    SharedPreferences.setMockInitialValues({'x_$_owner': 1});
    final prefs = await SharedPreferences.getInstance();
    final f = await CareRecordingFixture.create(connected: true);
    await completeAccountDeletion(
      signOut: () async => throw StateError('offline'),
      db: f.db,
      prefs: prefs,
      accountUserId: _owner,
    );
    expect(await f.db.select(f.db.profiles).get(), isEmpty);
    expect(prefs.getKeys(), isEmpty);
  });
}
