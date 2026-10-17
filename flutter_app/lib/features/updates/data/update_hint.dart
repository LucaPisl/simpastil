import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/sync/capabilities_client.dart';

/// Every release page lives under this prefix; anything else is ignored.
const releaseUrlPrefix = 'https://github.com/LucaPisl/simpastil/releases/';

bool isValidReleaseUrl(String value) =>
    value.length <= 256 &&
    !value.contains(RegExp(r'\s')) &&
    value.startsWith(releaseUrlPrefix);

/// The newest release this device has heard about, and who told it: the
/// signed-in server (`server`) or a direct GitHub check (`github`).
///
/// Dart-only, device-local preferences: not part of the widget contract in
/// `preference_keys.dart` and not in the backup allowlist.
class UpdateHint {
  const UpdateHint._();

  static const latestBuildKey = 'update_latest_build';
  static const releaseUrlKey = 'update_release_url';
  static const sourceKey = 'update_source';
  static const sourceServer = 'server';
  static const sourceGitHub = 'github';

  /// Bumped after every write so the update status can reread the hint. Static
  /// and per isolate: a background isolate that writes it tells nobody, and
  /// the next foreground read sees the value anyway.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// A server that reports a release stores it; a reachable server that does
  /// not (older server, check switched off, no check yet) clears it. An
  /// unreachable server leaves the previous answer in place.
  static Future<void> recordFromServer(CapabilitySnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // A blocked app gets the "update required" state alone, never this card.
      if (snapshot.blockedStableCode == clientUpgradeRequiredCode) {
        await _clear(prefs);
        changes.value++;
        return;
      }
      switch (snapshot.availability) {
        case CapabilityAvailability.present:
          final build = snapshot.capabilities!.latestClientBuild;
          final url = snapshot.capabilities!.latestReleaseUrl;
          if (build != null && url != null) {
            await _store(prefs, build, url, sourceServer);
          } else {
            await _clear(prefs);
          }
        case CapabilityAvailability.absent:
          await _clear(prefs);
        case CapabilityAvailability.unavailable ||
            CapabilityAvailability.localAccessUnavailable:
          break;
      }
    } on Object {
      // A hint only.
    }
    changes.value++;
  }

  static Future<void> recordFromGitHub(int build, String url) async {
    if (build <= 0 || !isValidReleaseUrl(url)) return;
    try {
      await _store(
        await SharedPreferences.getInstance(),
        build,
        url,
        sourceGitHub,
      );
    } on Object {
      // A hint only.
    }
    changes.value++;
  }

  static Future<void> clear() async {
    try {
      await _clear(await SharedPreferences.getInstance());
    } on Object {
      // A hint only.
    }
    changes.value++;
  }

  static Future<void> _store(
    SharedPreferences prefs,
    int build,
    String url,
    String source,
  ) async {
    await prefs.setInt(latestBuildKey, build);
    await prefs.setString(releaseUrlKey, url);
    await prefs.setString(sourceKey, source);
  }

  static Future<void> _clear(SharedPreferences prefs) async {
    await prefs.remove(latestBuildKey);
    await prefs.remove(releaseUrlKey);
    await prefs.remove(sourceKey);
  }
}
