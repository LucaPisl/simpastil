import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../backup/backup_inventory.dart';
import '../projections/projection_effects_gate.dart';
import 'preference_keys.dart';

final ProjectionEffectsGate privatePortablePreferenceGate =
    PrivateProjectionEffectsGate(subdirectory: 'preferences');
final portablePreferenceGateProvider = Provider<ProjectionEffectsGate>(
  (_) => privatePortablePreferenceGate,
);

final StreamController<String> _portableWrites =
    StreamController<String>.broadcast();

/// The key of every saved setting a person changed on this device. Auto sync
/// listens so a settings edit goes out within seconds, like a dose.
Stream<String> get portablePreferenceWrites => _portableWrites.stream;

/// Settings that follow the account but are deliberately not part of a backup
/// (the recorded-by name is personal; the low-stock "Later" list is a daily
/// convenience). They are written, and announced, like any other setting.
bool accountOnlyPreference(String key) =>
    key == 'today_low_stock_dismissed' ||
    RegExp(r'^recorded_by_(mode|name)_[a-zA-Z0-9_:-]{1,128}$').hasMatch(key);

/// Ordinary settings and restore completion share this barrier. Projection
/// effects use a different gate, so an appearance save cannot reacquire it.
class PortablePreferenceWriter {
  PortablePreferenceWriter(
    this.preferences, {
    ProjectionEffectsGate? gate,
    this.announce = true,
  }) : gate = gate ?? privatePortablePreferenceGate;
  final SharedPreferences preferences;
  final ProjectionEffectsGate gate;

  /// False for writes that apply the account's own values, which must not
  /// start another send.
  final bool announce;
  Future<bool> write(String key, Object? value) => _guarded(key, value, false);
  Future<bool> writeIfAbsent(String key, Object? value) =>
      _guarded(key, value, true);
  Future<bool> _guarded(String key, Object? value, bool onlyIfAbsent) =>
      gate.run(() async {
        if (!BackupInventory.preferenceAllowed(key) &&
            !accountOnlyPreference(key)) {
          throw const FormatException('Unsupported portable preference');
        }
        await preferences.reload();
        if (onlyIfAbsent && preferences.containsKey(key)) return true;
        try {
          final saved = await _write(key, value);
          if (!saved) {
            await preferences.reload();
          } else if (announce) {
            await _markChosen(key);
            _portableWrites.add(key);
          } else {
            await _markChooser(key);
          }
          return saved;
        } catch (_) {
          await preferences.reload();
          rethrow;
        }
      });

  /// Remembers that the signed-in person set [key] here, so a value equal to
  /// the default still counts as their choice. With nobody signed in there is
  /// no account to send a choice to, so nothing is remembered.
  ///
  /// A device-wide setting also records whose choice it now holds, so it is
  /// never taken as another account's choice; one made with nobody signed in
  /// is adopted by the next account to sign in
  /// ([claimSignedOutSettingChoices]).
  Future<void> _markChosen(String key) async {
    await _markChooser(key);
    final userId = preferences.getString(kCurrentUserIdKey);
    if (userId == null || userId.isEmpty) return;
    final listKey = chosenSettingKeysPreferenceKey(userId);
    final chosen = preferences.getStringList(listKey) ?? const [];
    if (chosen.contains(key)) return;
    await preferences.setStringList(listKey, [...chosen, key]);
  }

  /// Records whose value a device-wide setting now holds: the signed-in
  /// person's (their choice, or their account's value applied here), or
  /// nobody's yet.
  Future<void> _markChooser(String key) async {
    if (!deviceWideAccountSettingPreferenceKeys.contains(key)) return;
    final userId = preferences.getString(kCurrentUserIdKey);
    await preferences.setString(
      settingChooserPreferenceKey(key),
      userId == null || userId.isEmpty ? signedOutSettingChooser : userId,
    );
  }

  Future<bool> _write(String key, Object? value) => switch (value) {
    null => preferences.remove(key),
    bool v => preferences.setBool(key, v),
    int v => preferences.setInt(key, v),
    double v => preferences.setDouble(key, v),
    String v => preferences.setString(key, v),
    List v => preferences.setStringList(key, v.cast<String>()),
    _ => throw const FormatException('Unsupported preference value'),
  };
}

/// Gives [userId], who has just signed in, the device-wide settings chosen
/// while nobody was signed in: they count as this account's choice, even a
/// default (the language picked on the sign-in screen). Each is adopted once,
/// by the first account to sign in after the choice.
Future<void> claimSignedOutSettingChoices(
  SharedPreferences preferences,
  String userId,
) async {
  if (userId.isEmpty) return;
  for (final key in deviceWideAccountSettingPreferenceKeys) {
    final chooserKey = settingChooserPreferenceKey(key);
    if (preferences.getString(chooserKey) != signedOutSettingChooser) continue;
    await preferences.setString(chooserKey, userId);
    final listKey = chosenSettingKeysPreferenceKey(userId);
    final chosen = preferences.getStringList(listKey) ?? const [];
    if (!chosen.contains(key)) {
      await preferences.setStringList(listKey, [...chosen, key]);
    }
  }
}
