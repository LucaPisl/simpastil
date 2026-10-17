import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_preferences_provider.dart';

/// Dart-only, device-local flag: the one-time "hold a card to record" hint on
/// Today has been dismissed. Deliberately not in
/// `BackupInventory.preferenceAllowed` and never part of the native widget
/// contract (`preference_keys.dart`).
const kAsNeededHintDismissedPreferenceKey = 'as_needed_hint_dismissed';

class AsNeededHintNotifier extends Notifier<bool> {
  SharedPreferences? _preferences;

  /// True once the hint is dismissed. Hosts without preferences (some isolated
  /// widget tests) read as dismissed so no unexpected card appears.
  @override
  bool build() {
    try {
      _preferences = ref.watch(sharedPreferencesProvider);
    } on Object {
      _preferences = null;
      return true;
    }
    try {
      return _preferences!.getBool(kAsNeededHintDismissedPreferenceKey) ??
          false;
    } on Object {
      return true;
    }
  }

  /// Hides the hint now; the write is best-effort, so a failed write only
  /// means the hint may show once more after a restart.
  Future<void> dismiss() async {
    if (state) return;
    state = true;
    try {
      await _preferences?.setBool(kAsNeededHintDismissedPreferenceKey, true);
    } on Object {
      // Best effort.
    }
  }
}

final asNeededHintDismissedProvider =
    NotifierProvider<AsNeededHintNotifier, bool>(AsNeededHintNotifier.new);
