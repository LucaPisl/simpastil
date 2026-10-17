import 'package:shared_preferences/shared_preferences.dart';

import 'capabilities_client.dart';

/// The last medication-ledger mode the server reported, remembered so the
/// unsent-change tally can tell stock counts that wait for the server's ledger
/// (bridge mode) from ordinary pending work, even before the next sync.
///
/// Dart-only preference; the widget contract never reads it.
class LedgerModeHint {
  const LedgerModeHint._();

  static const key = 'server_medication_ledger_active';

  /// Whether the server last advertised medication command contract 3
  /// (recorded misses). Read by the automatic-miss sweep, which also runs in
  /// background isolates with no live capability answer.
  static const recordedMissKey = 'server_records_missed_doses';

  /// Stores what [snapshot] says. An absent capability endpoint forgets the
  /// hint; an unreachable server leaves the previous answer in place.
  static Future<void> record(CapabilitySnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      switch (snapshot.availability) {
        case CapabilityAvailability.present:
          await prefs.setBool(
            key,
            snapshot.capabilities!.medicationLedgerActive,
          );
          await prefs.setBool(
            recordedMissKey,
            snapshot.capabilities!.recordedMiss,
          );
        case CapabilityAvailability.absent:
          await prefs.remove(key);
          await prefs.remove(recordedMissKey);
        case CapabilityAvailability.unavailable ||
            CapabilityAvailability.localAccessUnavailable:
          break;
      }
    } on Object {
      // A hint only; the tally falls back to counting the work as pending.
    }
  }

  /// `true` only when the server last advertised recorded misses; unknown
  /// (never synced, unreachable at first run) reads as unsupported.
  static Future<bool> readRecordedMiss() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(recordedMissKey) ??
          false;
    } on Object {
      return false;
    }
  }

  /// `false` only when the server last reported an inactive ledger.
  static Future<bool?> read() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(key);
    } on Object {
      return null;
    }
  }
}
