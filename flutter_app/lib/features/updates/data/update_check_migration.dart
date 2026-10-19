import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/app_logger.dart';
import 'github_release_check.dart';

/// Dart-only and deliberately not in `BackupInventory.preferenceAllowed`: set
/// once the default of [updateCheckEnabledKey] has been settled on this
/// device. A restore must not carry it, or it could settle the question again
/// on a device where it was already answered.
const updateCheckDefaultMigratedKey = 'update_check_default_migrated_v1';

/// Before this migration a missing [updateCheckEnabledKey] meant "on". It now
/// means "off", so an install that predates the change and never touched the
/// switch would silently go quiet. This keeps such an install on, once, and
/// leaves a fresh install off.
///
/// An existing install is recognised by holding any preference besides this
/// migration's own marker. Every earlier release writes preferences as soon as
/// it is used, and a fresh install holds none when this runs, because it runs
/// first in app start-up, before anything else can write one. An install that
/// was opened but never used holds nothing and counts as fresh, which is
/// harmless: it has never contacted anyone and has no data to lose.
///
/// Idempotent: the marker is written last, so a failed write is retried at
/// the next start, and a person who later switches the check off stays off.
/// Never throws.
Future<void> migrateUpdateCheckDefault(SharedPreferences prefs) async {
  try {
    if (prefs.getBool(updateCheckDefaultMigratedKey) == true) return;
    final existingInstall = prefs.getKeys().any(
      (key) => key != updateCheckDefaultMigratedKey,
    );
    if (existingInstall && !prefs.containsKey(updateCheckEnabledKey)) {
      if (!await prefs.setBool(updateCheckEnabledKey, true)) return;
    }
    await prefs.setBool(updateCheckDefaultMigratedKey, true);
  } on Object catch (error) {
    AppLogger.warning(
      'Startup',
      'Update check default not settled: ${error.runtimeType}',
    );
  }
}
