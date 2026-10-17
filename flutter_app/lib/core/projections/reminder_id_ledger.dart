import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const reminderIdLedgerKey = 'reminder_id_ledger_v1';

/// Upper bound on remembered ids. Android allows roughly 500 alarms, so this
/// comfortably outlives every id that could still be armed.
const reminderIdLedgerLimit = 2000;

/// A bounded memory of every notification id this device ever armed.
///
/// The plugin lists pending alarms from a SharedPreferences cache, not from
/// AlarmManager, so an alarm whose cache entry was lost is invisible to every
/// diff. The ledger lets the audit cancel such an id by number; cancelling an
/// id that is not armed is a harmless no-op. It holds ids and times only,
/// never copy, payloads or names. Callers read and write it while holding
/// the projection effects gate, after reloading preferences.
class ReminderIdLedger {
  const ReminderIdLedger(this.preferences);
  final SharedPreferences preferences;

  /// Id to the time it was first recorded. A malformed ledger reads as empty:
  /// it is a safety net, and losing it must never block scheduling.
  Map<int, DateTime> read() {
    final raw = preferences.getString(reminderIdLedgerKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      final result = <int, DateTime>{};
      for (final item in decoded) {
        if (item is List &&
            item.length == 2 &&
            item[0] is int &&
            item[1] is int) {
          result[item[0] as int] = DateTime.fromMillisecondsSinceEpoch(
            item[1] as int,
            isUtc: true,
          );
        }
      }
      return result;
    } on FormatException {
      return {};
    }
  }

  /// Records ids not already present. Existing entries keep their original
  /// time. Returns whether anything was written.
  Future<bool> record(Iterable<int> ids, DateTime now) async {
    final entries = read();
    var changed = false;
    for (final id in ids) {
      if (entries.containsKey(id)) continue;
      entries[id] = now.toUtc();
      changed = true;
    }
    if (!changed) return false;
    return _write(entries);
  }

  Future<bool> remove(Iterable<int> ids) async {
    final entries = read();
    var changed = false;
    for (final id in ids) {
      changed = entries.remove(id) != null || changed;
    }
    return !changed || await _write(entries);
  }

  Future<void> clear() async {
    await preferences.remove(reminderIdLedgerKey);
  }

  Future<bool> _write(Map<int, DateTime> entries) {
    final ordered = entries.entries.toList()
      ..sort((a, b) {
        final byTime = a.value.compareTo(b.value);
        return byTime != 0 ? byTime : a.key.compareTo(b.key);
      });
    final kept = ordered.length > reminderIdLedgerLimit
        ? ordered.sublist(ordered.length - reminderIdLedgerLimit)
        : ordered;
    return preferences.setString(
      reminderIdLedgerKey,
      jsonEncode([
        for (final entry in kept)
          [entry.key, entry.value.millisecondsSinceEpoch],
      ]),
    );
  }
}
