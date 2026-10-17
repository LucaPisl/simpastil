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
