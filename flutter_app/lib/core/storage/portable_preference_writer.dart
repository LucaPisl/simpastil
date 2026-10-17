import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../backup/backup_inventory.dart';
import '../projections/projection_effects_gate.dart';

final ProjectionEffectsGate privatePortablePreferenceGate =
    PrivateProjectionEffectsGate(subdirectory: 'preferences');
final portablePreferenceGateProvider = Provider<ProjectionEffectsGate>(
  (_) => privatePortablePreferenceGate,
);

/// Ordinary settings and restore completion share this barrier. Projection
/// effects use a different gate, so an appearance save cannot reacquire it.
class PortablePreferenceWriter {
  PortablePreferenceWriter(this.preferences, {ProjectionEffectsGate? gate})
    : gate = gate ?? privatePortablePreferenceGate;
  final SharedPreferences preferences;
  final ProjectionEffectsGate gate;
  Future<bool> write(String key, Object? value) => _guarded(key, value, false);
  Future<bool> writeIfAbsent(String key, Object? value) =>
      _guarded(key, value, true);
  Future<bool> _guarded(String key, Object? value, bool onlyIfAbsent) =>
      gate.run(() async {
        if (!BackupInventory.preferenceAllowed(key)) {
          throw const FormatException('Unsupported portable preference');
        }
        await preferences.reload();
        if (onlyIfAbsent && preferences.containsKey(key)) return true;
        try {
          final saved = await _write(key, value);
          if (!saved) await preferences.reload();
          return saved;
        } catch (_) {
          await preferences.reload();
          rethrow;
        }
      });
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
