import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_preferences_provider.dart';

/// How Today is arranged. Focus deck is the default and the fallback.
///
/// Stored by [LayoutFamily.name]; never reorder-dependent. New families are
/// added at the end and an unknown stored name reads as [focusDeck], so an
/// older build that meets a newer value still opens normally.
enum LayoutFamily {
  focusDeck,
  timeline,
  peopleLanes,
  dayPlanner,
  actionInbox,
  dailyJournal;

  static LayoutFamily parse(Object? stored) {
    for (final family in values) {
      if (family.name == stored) return family;
    }
    return focusDeck;
  }
}

/// Dart-only, device-local preference. It is deliberately not in
/// `BackupInventory.preferenceAllowed`, so backups and restores neither carry
/// nor clear it, and it is never part of the native widget contract
/// (`preference_keys.dart`). It is separate from the versioned appearance
/// document, so appearance upgrades and resets cannot change the layout.
const kLayoutFamilyPreferenceKey = 'today_layout_family';

class LayoutFamilyPersistenceFailure implements Exception {
  const LayoutFamilyPersistenceFailure();
}

class LayoutFamilyNotifier extends Notifier<LayoutFamily> {
  SharedPreferences? _preferences;

  @override
  LayoutFamily build() {
    try {
      _preferences = ref.watch(sharedPreferencesProvider);
    } on Object {
      // Hosts without preferences (some isolated widget tests) use the default.
      _preferences = null;
      return LayoutFamily.focusDeck;
    }
    final Object? stored;
    try {
      stored = _preferences!.get(kLayoutFamilyPreferenceKey);
    } on Object {
      return LayoutFamily.focusDeck;
    }
    return LayoutFamily.parse(stored);
  }

  /// One durable write; the visible layout changes only after it succeeds.
  Future<void> apply(LayoutFamily family) async {
    final preferences = _preferences;
    if (preferences == null) throw const LayoutFamilyPersistenceFailure();
    final saved = await preferences.setString(
      kLayoutFamilyPreferenceKey,
      family.name,
    );
    if (!saved) throw const LayoutFamilyPersistenceFailure();
    state = family;
  }
}

final layoutFamilyProvider =
    NotifierProvider<LayoutFamilyNotifier, LayoutFamily>(
      LayoutFamilyNotifier.new,
    );
