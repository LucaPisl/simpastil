import 'package:shared_preferences/shared_preferences.dart';

import '../storage/preference_keys.dart';

/// Forgets the account settings the server refused for [userId], and the key
/// their fingerprints were made under. Called when a session ends, by sign-out
/// or by the server, so the next session starts without them.
Future<void> forgetAccountSettingRefusals(
  SharedPreferences prefs,
  String userId,
) async {
  if (userId.isEmpty) return;
  await prefs.remove(accountSettingsRefusedPreferenceKey(userId));
  await prefs.remove(accountSettingsRefusalKeyPreferenceKey(userId));
}
