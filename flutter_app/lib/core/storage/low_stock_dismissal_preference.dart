import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../medication/routine_definition.dart' show routineDateKey;
import 'shared_preferences_provider.dart';

/// Dart-only, device-local list of low-stock notices put off with "Later" on
/// Today, one `pillId|yyyy-MM-dd` entry each, the date being the first day the
/// notice shows again. Deliberately not in `BackupInventory.preferenceAllowed`
/// and never part of the native widget contract (`preference_keys.dart`).
const kLowStockDismissedPreferenceKey = 'today_low_stock_dismissed';

/// Whether [dismissed] hides [pillId]'s notice on [now]'s day.
bool lowStockDismissed(
  Map<String, String> dismissed,
  String pillId,
  DateTime now,
) {
  final until = dismissed[pillId];
  return until != null && until.compareTo(routineDateKey(now)) > 0;
}

/// The medications whose low-stock notice is hidden today, mapped to the
/// first day it comes back. "Later" hides a notice until tomorrow; nothing
/// else about the medication or its stock changes.
class LowStockDismissals extends Notifier<Map<String, String>> {
  SharedPreferences? _preferences;

  @override
  Map<String, String> build() {
    try {
      _preferences = ref.watch(sharedPreferencesProvider);
    } on Object {
      _preferences = null;
      return const {};
    }
    final stored = <String, String>{};
    try {
      for (final entry
          in _preferences!.getStringList(kLowStockDismissedPreferenceKey) ??
              const <String>[]) {
        final at = entry.lastIndexOf('|');
        if (at <= 0) continue;
        stored[entry.substring(0, at)] = entry.substring(at + 1);
      }
    } on Object {
      return const {};
    }
    return Map.unmodifiable(stored);
  }

  /// Whether [pillId]'s notice is hidden today.
  bool isHidden(String pillId, {DateTime? now}) =>
      lowStockDismissed(state, pillId, now ?? DateTime.now());

  /// Hides [pillId]'s notice until tomorrow. The write is best-effort: when
  /// it fails the notice is hidden for this run and returns after a restart.
  Future<void> dismiss(String pillId, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final today = routineDateKey(at);
    final tomorrow = routineDateKey(DateTime(at.year, at.month, at.day + 1));
    final next = <String, String>{
      for (final e in state.entries)
        if (e.value.compareTo(today) > 0) e.key: e.value,
      pillId: tomorrow,
    };
    state = Map.unmodifiable(next);
    try {
      await _preferences?.setStringList(kLowStockDismissedPreferenceKey, [
        for (final e in next.entries) '${e.key}|${e.value}',
      ]);
    } on Object {
      // Best effort.
    }
  }
}

final lowStockDismissalsProvider =
    NotifierProvider<LowStockDismissals, Map<String, String>>(
      LowStockDismissals.new,
    );
