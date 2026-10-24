/// Shared widget contract keys. Keep these in sync with the Kotlin
/// WidgetProjectionContract and contracts/fixtures/projection-command-ids-v1.json;
/// test/core/projections/projection_command_id_test.dart pins the Dart contract.
const kTodayDosesKey = 'today_doses';
const kSnapshotDayKey = 'snapshot_day';
const kAppThemeModeKey = 'app_theme_mode';
const kActiveUserIdKey = 'active_user_id';
const kSessionGenerationKey = 'session_generation';

/// Flutter auth's legacy mirror is checked alongside the authoritative
/// owner/generation pair before a background action writes medication state.
const kCurrentUserIdKey = 'current_user_id';

/// These two settings are Dart-only and must not become native widget keys.
String prnInStatsPreferenceKey(String userId) => 'prn_in_stats_$userId';
String prnInWidgetPreferenceKey(String userId) => 'prn_in_widget_$userId';

/// Automatic miss recording. The first two are portable (backup allowlisted);
/// the widget never reads them.
String autoMissEnabledPreferenceKey(String userId) =>
    'auto_miss_enabled_$userId';
String autoMissDelayPreferenceKey(String userId) =>
    'auto_miss_delay_minutes_$userId';

/// How long a dose may be overdue before it is recorded as missed, for someone
/// who has not chosen a delay. The sweep and the reminder settings screen both
/// read this, so a device that has never been to that screen records misses on
/// the same schedule the screen would show.
const autoMissDefaultDelayMinutes = 60;

/// Dart-only and deliberately not in `BackupInventory.preferenceAllowed`: the
/// epoch milliseconds from which the sweep may record misses. A restore must
/// never carry it, so a restored device starts looking back from "now".
String autoMissSincePreferenceKey(String userId) => 'auto_miss_since_$userId';

/// Dart-only and deliberately not in `BackupInventory.preferenceAllowed`: set
/// when the "Reminders are off on this device" card on Today was closed. It is
/// about this device, so a restore must not carry it to another one.
String remindersOffNoticeDismissedPreferenceKey(String userId) =>
    'reminders_off_notice_dismissed_$userId';

/// Whether this device shows this account's reminders at all (default on).
/// Dart-only and per device: deliberately not in
/// `BackupInventory.preferenceAllowed`, so a backup never switches reminders
/// off on the device it is restored to, and never account-synced, so one
/// phone can stay silent while another keeps the alarms. Today and the
/// widget are unaffected.
String remindOnThisDevicePreferenceKey(String userId) =>
    'remind_on_this_device_$userId';

/// Dart-only and deliberately not in `BackupInventory.preferenceAllowed`: the
/// account settings the server refused, kept per key as a keyed fingerprint
/// (HMAC-SHA256 under [accountSettingsRefusalKeyPreferenceKey]) of the refused
/// value, never the value itself, and the account revision at the time.
/// Cleared when the session ends, on sign-out, and with the account's other
/// preferences.
String accountSettingsRefusedPreferenceKey(String userId) =>
    'account_settings_refused_$userId';

/// Dart-only and deliberately not in `BackupInventory.preferenceAllowed`: the
/// random key, made on this device, under which
/// [accountSettingsRefusedPreferenceKey] fingerprints refused values. It is
/// stored in the same preferences as the fingerprints, so it only protects
/// against a leak of the fingerprints alone (for example a log line or a
/// support excerpt): anyone who can read the whole preferences file has the key
/// too and can test guesses. The app sets `android:allowBackup="false"`, so
/// neither leaves the device through Android backup. Cleared together with the
/// refusals, and with the account's other preferences.
String accountSettingsRefusalKeyPreferenceKey(String userId) =>
    'account_settings_refusal_key_$userId';

/// Dart-only and deliberately not in `BackupInventory.preferenceAllowed`: the
/// preference keys a person signed in as [userId] set through a settings
/// control on this device. A stored value equal to the default is a real
/// choice only when its key is here; older builds stored defaults without
/// anyone choosing them. Kept per account, so a device-wide setting such as
/// the language one account chose is not sent as another account's choice.
String chosenSettingKeysPreferenceKey(String userId) =>
    'chosen_setting_keys_$userId';

/// Account settings this device keeps once for every account (the language
/// and the appearance document). Whose choice the stored value is cannot be
/// read from the value, so [settingChooserPreferenceKey] records it.
const deviceWideAccountSettingPreferenceKeys = {
  'app_locale',
  'appearance_preferences_v1',
};

/// Dart-only and deliberately not in `BackupInventory.preferenceAllowed`: the
/// account whose choice the device-wide [preferenceKey] holds, set whenever it
/// is written. A value one account chose is never seeded into another account
/// signed in on the same phone. [signedOutSettingChooser] marks a choice made
/// with nobody signed in; the next account to sign in adopts it. Absent for a
/// value an older build stored: that value counts as before (a non-default
/// value is a choice).
String settingChooserPreferenceKey(String preferenceKey) =>
    'setting_chooser_$preferenceKey';

/// [settingChooserPreferenceKey] for a choice made with nobody signed in.
const signedOutSettingChooser = '';

/// The device-wide list an earlier build of this release kept instead of
/// [chosenSettingKeysPreferenceKey]. It is no longer read, because it cannot
/// tell whose choice a device-wide key was; the account wipe still trims it.
const kChosenSettingKeysKey = 'chosen_setting_keys';
