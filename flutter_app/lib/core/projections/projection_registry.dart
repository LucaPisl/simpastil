import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'projection_identity.dart';

const notificationProjectionRegistryKey = 'notification_projection_registry_v1';

/// All native notification kinds share this registry and their ID space.
/// Callers reload preferences, read, perform effects and persist while holding
/// ProjectionEffectsGate. An unreadable/future registry never becomes empty.
class ProjectionRegistry {
  const ProjectionRegistry(this.preferences);
  final SharedPreferences preferences;
  static const reminderKinds = {'reminder', 'snooze'};

  Map<int, Map<String, Object?>> read() {
    final raw = preferences.getString(notificationProjectionRegistryKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Invalid projection registry');
    }
    final result = <int, Map<String, Object?>>{};
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Invalid projection registry');
      }
      _validate(entry);
      final id = entry['id'] as int;
      if (result.containsKey(id)) {
        throw const FormatException('Ambiguous projection ownership');
      }
      result[id] = Map<String, Object?>.from(entry);
    }
    return result;
  }

  Future<void> persist(Map<int, Map<String, Object?>> entries) async {
    for (final entry in entries.entries) {
      _validate(entry.value);
      if (entry.key != entry.value['id']) {
        throw const FormatException('Invalid projection identity');
      }
    }
    if (!await preferences.setString(
      notificationProjectionRegistryKey,
      jsonEncode(entries.values.toList()),
    )) {
      throw StateError('Could not persist projection registry');
    }
  }

  static void _validate(Map<String, Object?> entry) {
    final kind = entry['kind'];
    final version = entry['version'];
    if (entry['id'] is! int ||
        (entry['id'] as int) < 0 ||
        (entry['id'] as int) > 0x3fffffff ||
        entry['projectionId'] is! String ||
        (entry['projectionId'] as String).isEmpty ||
        entry['userId'] is! String ||
        (entry['userId'] as String).isEmpty ||
        entry['sessionGeneration'] is! int ||
        !const {'reminder', 'snooze', 'lowStock', 'readiness'}.contains(kind) ||
        (reminderKinds.contains(kind) && entry['occurrenceId'] is! String) ||
        (kind == 'lowStock' && entry['pillId'] is! String) ||
        (kind == 'readiness' &&
            (version != 2 ||
                entry['testId'] is! String ||
                (entry['testId'] as String).isEmpty)) ||
        (version != null &&
            (version != 2 ||
                ProjectionIdentity.fromJson(entry) == null ||
                entry['sessionGeneration'] != entry['grantEpoch'])) ||
        (kind == 'lowStock' && version != 2)) {
      throw const FormatException('Unsupported projection registry entry');
    }
  }

  static bool isReminder(Object? value) =>
      value is Map && reminderKinds.contains(value['kind']);
}
