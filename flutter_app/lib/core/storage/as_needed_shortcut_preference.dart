import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_preferences_provider.dart';

/// Dart-only, device-local flag for the floating "As needed" shortcut on the
/// Focus deck. Default on. Deliberately not in
/// `BackupInventory.preferenceAllowed` and never part of the native widget
/// contract (`preference_keys.dart`).
const kAsNeededShortcutPreferenceKey = 'focus_as_needed_shortcut';

class AsNeededShortcutNotifier extends Notifier<bool> {
  SharedPreferences? _preferences;

  /// True while the shortcut is enabled (the default).
  @override
  bool build() {
    try {
      _preferences = ref.watch(sharedPreferencesProvider);
    } on Object {
      _preferences = null;
      return true;
    }
    try {
      return _preferences!.getBool(kAsNeededShortcutPreferenceKey) ?? true;
    } on Object {
      return true;
    }
  }

  /// Applies the choice now; the write is best-effort, so a failed write only
  /// means the previous choice returns after a restart.
  Future<void> setEnabled(bool enabled) async {
    if (state == enabled) return;
    state = enabled;
    try {
      await _preferences?.setBool(kAsNeededShortcutPreferenceKey, enabled);
    } on Object {
      // Best effort.
    }
  }
}

final asNeededShortcutProvider =
    NotifierProvider<AsNeededShortcutNotifier, bool>(
      AsNeededShortcutNotifier.new,
    );
