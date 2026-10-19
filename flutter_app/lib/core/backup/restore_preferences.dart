import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database.dart';
import '../projections/projection_effects_gate.dart';
import '../projections/restore_projection_retirement.dart';
import 'backup_inventory.dart';
import 'import_service.dart' show canonicalImportJson;
import 'package:crypto/crypto.dart';

enum PreferenceRestoreState { none, pending, needsReview, complete }

Map<String, Object?> portablePreferenceSnapshot(
  SharedPreferences preferences,
) => {
  for (final key in preferences.getKeys().where(
    BackupInventory.preferenceAllowed,
  ))
    key: preferences.get(key),
};

String preferenceRestoreDigest(Map<String, Object?> value) =>
    sha256.convert(utf8.encode(canonicalImportJson(value))).toString();

/// Durable completion of a committed care replacement. A preference failure
/// cannot roll back care or claim that these separate stores committed together.
class RestorePreferencesService {
  RestorePreferencesService({
    required this.database,
    required this.preferences,
    required this.effectsGate,
    this.writePreference,
  });
  final AppDatabase database;
  final SharedPreferences preferences;
  final ProjectionEffectsGate effectsGate;
  final Future<bool> Function(String, Object?)? writePreference;

  /// Called within the same SQLite transaction as care activation and receipt.
  Future<void> stage({
    required String id,
    required String receiptId,
    required String recoveryGeneration,
    required Map<String, Object?> before,
    required Map<String, Object?> after,
    List<RestoreProjectionRetirement> retiredProjections = const [],
  }) async {
    if ([
      ...before.keys,
      ...after.keys,
    ].any((key) => !BackupInventory.preferenceAllowed(key))) {
      throw const FormatException('Unsupported preference intent');
    }
    final keys = {...before.keys, ...after.keys}.toList()..sort();
    final operations = [
      for (final key in keys)
        if (before.containsKey(key) != after.containsKey(key) ||
            canonicalImportJson(before[key]) != canonicalImportJson(after[key]))
          {
            'key': key,
            'beforePresent': before.containsKey(key),
            'before': before[key],
            'afterPresent': after.containsKey(key),
            'after': after[key],
          },
    ];
    await database
        .into(database.deviceRestoreIntents)
        .insert(
          DeviceRestoreIntentsCompanion.insert(
            id: id,
            receiptId: receiptId,
            expectedPreferencesDigest: preferenceRestoreDigest(before),
            operationsJson: jsonEncode(operations),
            completedOperationsJson: '[]',
            recoveryGeneration: recoveryGeneration,
            state: operations.isEmpty ? 'completed' : 'pending',
            retiredProjectionsJson: Value(
              jsonEncode(retiredProjections.map((p) => p.toJson()).toList()),
            ),
            createdAt: DateTime.now().toUtc(),
          ),
        );
  }

  Future<PreferenceRestoreState> reconcile() async {
    if (await (database.select(database.deviceRestoreIntents)
              ..where((r) => r.state.isNotValue('completed'))
              ..limit(1))
            .getSingleOrNull() ==
        null) {
      return PreferenceRestoreState.none;
    }
    return effectsGate.run(() async {
      final intents =
          await (database.select(database.deviceRestoreIntents)
                ..where((r) => r.state.isNotValue('completed'))
                ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
              .get();
      if (intents.isEmpty) return PreferenceRestoreState.none;
      for (final intent in intents) {
        if (intent.state == 'conflict') {
          return PreferenceRestoreState.needsReview;
        }
        try {
          final operations = (jsonDecode(intent.operationsJson) as List)
              .map((r) => Map<String, Object?>.from(r as Map))
              .toList();
          final completed = (jsonDecode(intent.completedOperationsJson) as List)
              .cast<String>()
              .toSet();
          final keys = operations.map((r) => r['key'] as String).toSet();
          if (keys.length != operations.length ||
              !keys.containsAll(completed) ||
              keys.any((key) => !BackupInventory.preferenceAllowed(key))) {
            throw const FormatException();
          }
          Future<bool> currentIsReviewed() async {
            await preferences.reload();
            final reconstructed = portablePreferenceSnapshot(preferences);
            for (final operation in operations) {
              final key = operation['key'] as String;
              final before =
                  operation['beforePresent'] == true &&
                  reconstructed.containsKey(key) &&
                  canonicalImportJson(reconstructed[key]) ==
                      canonicalImportJson(operation['before']);
              final after =
                  operation['afterPresent'] == true &&
                  reconstructed.containsKey(key) &&
                  canonicalImportJson(reconstructed[key]) ==
                      canonicalImportJson(operation['after']);
              final beforeAbsent =
                  operation['beforePresent'] == false &&
                  !reconstructed.containsKey(key);
              final afterAbsent =
                  operation['afterPresent'] == false &&
                  !reconstructed.containsKey(key);
              if (completed.contains(key)
                  ? !(after || afterAbsent)
                  : !(before || beforeAbsent || after || afterAbsent)) {
                return false;
              }
              if (operation['beforePresent'] == true) {
                reconstructed[key] = operation['before'];
              } else {
                reconstructed.remove(key);
              }
            }
            return preferenceRestoreDigest(reconstructed) ==
                intent.expectedPreferencesDigest;
          }

          Future<PreferenceRestoreState> conflict() async {
            await (database.update(
              database.deviceRestoreIntents,
            )..where((r) => r.id.equals(intent.id))).write(
              const DeviceRestoreIntentsCompanion(state: Value('conflict')),
            );
            return PreferenceRestoreState.needsReview;
          }

          if (!await currentIsReviewed()) return await conflict();
          for (final operation in operations) {
            final key = operation['key'] as String;
            if (completed.contains(key)) continue;
            if (!await currentIsReviewed()) return await conflict();
            final desired = operation['afterPresent'] == true
                ? operation['after']
                : null;
            final already =
                operation['afterPresent'] == preferences.containsKey(key) &&
                canonicalImportJson(preferences.get(key)) ==
                    canonicalImportJson(desired);
            if (!already) {
              if (!await (writePreference ?? _write)(key, desired)) {
                await preferences.reload();
                return PreferenceRestoreState.pending;
              }
              await preferences.reload();
              if (operation['afterPresent'] != preferences.containsKey(key) ||
                  canonicalImportJson(preferences.get(key)) !=
                      canonicalImportJson(desired)) {
                return PreferenceRestoreState.pending;
              }
            }
            completed.add(key);
            await (database.update(
              database.deviceRestoreIntents,
            )..where((r) => r.id.equals(intent.id))).write(
              DeviceRestoreIntentsCompanion(
                completedOperationsJson: Value(
                  jsonEncode(completed.toList()..sort()),
                ),
              ),
            );
          }
          if (!await currentIsReviewed()) return await conflict();
          await (database.update(
            database.deviceRestoreIntents,
          )..where((r) => r.id.equals(intent.id))).write(
            const DeviceRestoreIntentsCompanion(state: Value('completed')),
          );
        } catch (_) {
          return PreferenceRestoreState.pending;
        }
      }
      return PreferenceRestoreState.complete;
    });
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
