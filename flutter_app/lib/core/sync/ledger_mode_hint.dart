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

  /// Whether the server last advertised schedule windows (every N days and
  /// start/end dates). Read by the schedule editor, which has no live
  /// capability answer of its own.
  static const scheduleWindowsKey = 'server_accepts_schedule_windows';

  /// Whether the server last advertised exact fractional stock. Read before
  /// any stock arithmetic or wire field that an older server would refuse.
  static const fractionalStockKey = 'server_accepts_fractional_stock';

  /// Whether the server last advertised that it stores the Recorded-by name.
  /// Read before a dose command is sent, so an older server never receives a
  /// field its strict schema would refuse.
  static const recordedByKey = 'server_accepts_recorded_by';

  /// Whether the server last advertised settings that follow the account. Read
  /// by the settings screens, which have no live capability answer, to decide
  /// whether to say what follows the account and what stays on this device.
  static const accountSettingsKey = 'server_has_account_settings';

  /// Whether the server last advertised change email, export and delete, and
  /// how a changed email is applied (`confirm` or `immediate`). Read by the
  /// account settings, which have no live capability answer of their own.
  static const accountSelfServiceKey = 'server_has_account_self_service';
  static const emailChangeModeKey = 'server_email_change_mode';

  /// The address of the server that last answered without a capability
  /// endpoint at all (an older server, written to by the legacy split
  /// adapter). Kept apart from [key], which a legacy server removes: "never
  /// synced" and "legacy" both read null there, and only the second must
  /// refuse a refill. It holds the address rather than a flag, so pointing the
  /// app at another server leaves that server unknown until it answers.
  static const legacyServerKey = 'server_without_capabilities';

  /// The address of the server the hints above describe: the one configured
  /// when the probe that answered them started. A hint read while another
  /// address is configured is unknown, so a server switch never lends one
  /// server's answer to the next. Hints an earlier build wrote have no address
  /// and keep their old device-wide meaning until the next answer.
  static const answeredServerKey = 'server_capabilities_answered_by';

  /// The configured server address, as `ServerConfigNotifier` saves it.
  static const _serverUrlKey = 'server_url';

  /// The configured server address now, to capture before a capability probe
  /// and hand to [record] with its answer. `null` when none is configured or
  /// the preferences cannot be read.
  static Future<String?> configuredServer() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_serverUrlKey);
    } on Object {
      return null;
    }
  }

  /// Stores what [snapshot] says about [server], the address captured with
  /// [configuredServer] when the probe started. An absent capability endpoint
  /// forgets the hint; an unreachable server leaves the previous answer in
  /// place. An answer from a server that is no longer configured is not
  /// stored at all: it says nothing about the server configured now.
  static Future<void> record(
    CapabilitySnapshot snapshot, {
    required String? server,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final answeredBy = server ?? '';
      if ((prefs.getString(_serverUrlKey) ?? '') != answeredBy) return;
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
          await prefs.setBool(
            scheduleWindowsKey,
            snapshot.capabilities!.scheduleWindows,
          );
          await prefs.setBool(
            fractionalStockKey,
            snapshot.capabilities!.fractionalStock,
          );
          await prefs.setBool(recordedByKey, snapshot.capabilities!.recordedBy);
          await prefs.setBool(
            accountSettingsKey,
            snapshot.capabilities!.accountSettings,
          );
          await prefs.setBool(
            accountSelfServiceKey,
            snapshot.capabilities!.accountSelfService,
          );
          await prefs.setString(
            emailChangeModeKey,
            snapshot.capabilities!.emailChange.name,
          );
          await prefs.remove(legacyServerKey);
          await prefs.setString(answeredServerKey, answeredBy);
        case CapabilityAvailability.absent:
          await prefs.remove(key);
          await prefs.remove(recordedMissKey);
          await prefs.remove(scheduleWindowsKey);
          await prefs.remove(fractionalStockKey);
          await prefs.remove(recordedByKey);
          await prefs.remove(accountSettingsKey);
          await prefs.remove(accountSelfServiceKey);
          await prefs.remove(emailChangeModeKey);
          await prefs.setString(legacyServerKey, answeredBy);
          await prefs.setString(answeredServerKey, answeredBy);
        case CapabilityAvailability.unavailable ||
            CapabilityAvailability.localAccessUnavailable:
          break;
      }
    } on Object {
      // A hint only; the tally falls back to counting the work as pending.
    }
  }

  /// The preferences, when the hints in them describe the server configured
  /// now; `null` when they describe another one (read as unknown).
  static Future<SharedPreferences?> _currentServerHints() async {
    final prefs = await SharedPreferences.getInstance();
    final answered = prefs.get(answeredServerKey);
    if (answered == null) return prefs;
    return answered is String &&
            answered == (prefs.getString(_serverUrlKey) ?? '')
        ? prefs
        : null;
  }

  /// `true` only when the server last advertised recorded misses; unknown
  /// (never synced, unreachable at first run) reads as unsupported.
  static Future<bool> readRecordedMiss() async {
    try {
      return (await _currentServerHints())?.getBool(recordedMissKey) ?? false;
    } on Object {
      return false;
    }
  }

  /// `true` only when the server last advertised schedule windows; unknown
  /// reads as unsupported, so the editor never offers what a server may refuse.
  static Future<bool> readScheduleWindows() async {
    try {
      return (await _currentServerHints())?.getBool(scheduleWindowsKey) ??
          false;
    } on Object {
      return false;
    }
  }

  /// `true` only when the server last advertised exact fractional stock.
  ///
  /// Unknown (never synced, offline at first run, preferences unreadable) reads
  /// as unsupported, the safe side: the app then predicts and sends exactly
  /// what a 1.2.0 server does, never adopts a unit and never sends a field an
  /// old server's strict schema would refuse. A server that does support it
  /// still reads the plain count correctly, so the cost of guessing wrong is
  /// only that the first half tablet waits for the next sync.
  static Future<bool> readFractionalStock() async {
    try {
      return (await _currentServerHints())?.getBool(fractionalStockKey) ??
          false;
    } on Object {
      return false;
    }
  }

  /// `true` only when the server last advertised the Recorded-by name.
  /// Unknown reads as unsupported, so no older server ever sees the field.
  static Future<bool> readRecordedBy() async {
    try {
      return (await _currentServerHints())?.getBool(recordedByKey) ?? false;
    } on Object {
      return false;
    }
  }

  /// `true` only when the server last advertised account settings. Unknown
  /// reads as unsupported, so no label or promise appears against an older
  /// server.
  static Future<bool> readAccountSettings() async {
    try {
      return (await _currentServerHints())?.getBool(accountSettingsKey) ??
          false;
    } on Object {
      return false;
    }
  }

  /// `true` only when the server last advertised change email, export and
  /// delete. Unknown reads as unsupported, so nothing is offered that an older
  /// server would refuse.
  static Future<bool> readAccountSelfService() async {
    try {
      return (await _currentServerHints())?.getBool(accountSelfServiceKey) ??
          false;
    } on Object {
      return false;
    }
  }

  /// How the server last said a changed email is applied.
  static Future<EmailChangeMode> readEmailChangeMode() async {
    try {
      return parseEmailChange(
        (await _currentServerHints())?.getString(emailChangeModeKey),
      );
    } on Object {
      return EmailChangeMode.unknown;
    }
  }

  /// `true` only when the server configured now is the one that last answered
  /// without a capability endpoint. Unknown (never synced, another server
  /// since, or the device-wide flag an earlier build wrote) reads as false.
  static Future<bool> readLegacyServer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.get(legacyServerKey);
      return legacy is String &&
          legacy == (prefs.getString(_serverUrlKey) ?? '');
    } on Object {
      return false;
    }
  }

  /// Whether a refill cannot be taken by the server this device last reached:
  /// one with an inactive ledger, or an older one without capabilities.
  /// Unknown (never synced, unreachable) is not a refusal: the command waits
  /// in the outbox, and the send decides once the server is known.
  static Future<bool> refillRefused() async =>
      await read() == false || await readLegacyServer();

  /// `false` only when the server last reported an inactive ledger.
  static Future<bool?> read() async {
    try {
      return (await _currentServerHints())?.getBool(key);
    } on Object {
      return null;
    }
  }
}
