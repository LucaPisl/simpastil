import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../storage/preference_keys.dart';
import '../workspace/workspace_context.dart' show WorkspaceAccessFailure;
import 'account_setting_refusals.dart';
import 'account_setting_codec.dart';
import 'local_account_settings.dart';

/// What the server last said about one key.
class SettingMirror {
  const SettingMirror(this.value, this.revision);

  /// Canonical value, or null for a cleared key.
  final Object? value;
  final int revision;
}

/// A local edit waiting to be sent.
class SettingPending {
  const SettingPending(this.value, this.baseRevision, this.ifAbsent);
  final Object? value;
  final int baseRevision;
  final bool ifAbsent;
}

/// The one place account settings are kept in step: it holds the mirror of the
/// server's values and the queue of unsent edits, and it reads and writes the
/// stores the app reads ([LocalAccountSettings]). Sync talks to the server;
/// this class never does.
class SettingsStore {
  SettingsStore({
    required this.db,
    required this.userId,
    required this.local,
    required this.write,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppDatabase db;
  final String userId;
  final LocalAccountSettings local;
  final SettingsWrite write;
  final DateTime Function() _now;

  String get _joinedKey => 'account_settings_joined_$userId';
  String get _noteGroupsKey => 'account_settings_note_groups_$userId';
  String get _refusedKey => accountSettingsRefusedPreferenceKey(userId);
  String get _noteShownKey => 'account_settings_note_shown_$userId';

  Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }

  // ── Mirror and queue ───────────────────────────────────────────────────────

  Future<Map<String, SettingMirror>> mirror() async {
    final rows = await (db.select(
      db.accountSettingValues,
    )..where((r) => r.userId.equals(userId))).get();
    return {
      for (final r in rows)
        r.settingKey: SettingMirror(
          r.valueJson == null ? null : jsonDecode(r.valueJson!),
          r.revision,
        ),
    };
  }

  static const _component = 'accountSettings';

  /// Where the next pull starts: the highest revision of a page already read.
  /// It is kept in the component state row, so a reset of the pull checkpoints
  /// replays the account's settings, and it deliberately ignores revisions this
  /// device wrote itself (others may hold lower ones it has not seen).
  Future<int> pullCursor() async {
    final state = await db.syncStateDao.getState(userId, _component);
    return int.tryParse(state?.lastCompletedCursor ?? '') ?? 0;
  }

  Future<void> savePullCursor(int revision) => write(() async {
    final previous = await db.syncStateDao.getState(userId, _component);
    await db.syncStateDao.saveState(
      SyncComponentStatesCompanion.insert(
        userId: userId,
        component: _component,
        contractVersion: previous?.contractVersion ?? 1,
        lastCompletedCursor: Value('$revision'),
        lastFullSuccessAt: Value(previous?.lastFullSuccessAt),
        currentState: Value(previous?.currentState ?? 'idle'),
        diagnosticMetadataJson: Value(previous?.diagnosticMetadataJson),
      ),
    );
  });

  Future<void> putMirror(
    String key,
    Object? value,
    int revision, {
    DateTime? updatedAt,
  }) => write(
    () => db
        .into(db.accountSettingValues)
        .insertOnConflictUpdate(
          AccountSettingValuesCompanion.insert(
            userId: userId,
            settingKey: key,
            valueJson: Value(
              value == null ? null : AccountSettingCodec.canonicalText(value),
            ),
            revision: revision,
            updatedAt: updatedAt ?? _now().toUtc(),
          ),
        ),
  );

  Future<Map<String, SettingPending>> pending() async {
    final rows = await (db.select(
      db.pendingAccountSettings,
    )..where((r) => r.userId.equals(userId))).get();
    return {
      for (final r in rows)
        r.settingKey: SettingPending(
          r.valueJson == null ? null : jsonDecode(r.valueJson!),
          r.baseRevision,
          r.ifAbsent,
        ),
    };
  }

  Future<void> queue(
    String key,
    Object? value, {
    required int baseRevision,
    bool ifAbsent = false,
  }) => write(
    () => db
        .into(db.pendingAccountSettings)
        .insertOnConflictUpdate(
          PendingAccountSettingsCompanion.insert(
            userId: userId,
            settingKey: key,
            valueJson: Value(
              value == null ? null : AccountSettingCodec.canonicalText(value),
            ),
            baseRevision: baseRevision,
            ifAbsent: Value(ifAbsent),
            queuedAt: _now().toUtc(),
          ),
        ),
  );

  Future<void> clearPending(Iterable<String> keys) => write(
    () => (db.delete(
      db.pendingAccountSettings,
    )..where((r) => r.userId.equals(userId) & r.settingKey.isIn(keys))).go(),
  );

  // ── Refused values ─────────────────────────────────────────────────────────

  /// Values the server refused, per key: a keyed fingerprint of the canonical
  /// text that was refused and the revision of the account's value at that
  /// moment. The same value is not sent again until the value or the account's
  /// value changes, or the refused edit would be retried on every sync.
  ///
  /// The fingerprint is an HMAC under a random per-account key made on this
  /// device ([accountSettingsRefusalKeyPreferenceKey]). The value itself is
  /// never stored. The key sits in the same preferences as the fingerprints,
  /// so it only protects against a leak of the fingerprints alone: someone who
  /// can read the whole preferences file can still test guesses of a short
  /// value. Android backup is off for the app, and the key is removed with the
  /// refusals when the session ends and with the account's preferences.
  ///
  /// Entries an older build wrote are settled on the first read: a plain-text
  /// `value` is turned into its fingerprint, and anything else that cannot be
  /// read (including an unkeyed fingerprint) is dropped. Dropping one only
  /// lets the refused value be sent once more.
  Future<Map<String, ({String fingerprint, int revision})>> refused() async {
    final raw = (await _prefs()).getString(_refusedKey);
    if (raw == null) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map) {
      await _saveRefused(const {});
      return const {};
    }
    final held = <String, ({String fingerprint, int revision})>{};
    var rewrite = false;
    for (final e in decoded.entries) {
      final entry = e.value;
      final key = e.key;
      if (key is! String || entry is! Map || entry['revision'] is! int) {
        rewrite = true;
        continue;
      }
      final revision = entry['revision'] as int;
      if (entry['keyed'] == true && entry['fingerprint'] is String) {
        held[key] = (
          fingerprint: entry['fingerprint'] as String,
          revision: revision,
        );
      } else if (entry['value'] is String) {
        // The first format kept the refused canonical text itself.
        held[key] = (
          fingerprint: await _fingerprintOfText(entry['value'] as String),
          revision: revision,
        );
        rewrite = true;
      } else {
        rewrite = true;
      }
    }
    if (rewrite) await _saveRefused(held);
    return held;
  }

  /// The fingerprint [refused] keeps for [value].
  Future<String> refusalFingerprint(Object? value) =>
      _fingerprintOfText(AccountSettingCodec.canonicalText(value));

  Future<String> _fingerprintOfText(String text) async => Hmac(
    sha256,
    utf8.encode(await _refusalKey()),
  ).convert(utf8.encode(text)).toString();

  /// Keys being made, per preference key: two first fingerprints at once share
  /// one, so neither is made under a key the other then replaces.
  static final _makingKeys = <String, Future<String>>{};

  /// This account's random fingerprint key, made on first use.
  Future<String> _refusalKey() async {
    final saltKey = accountSettingsRefusalKeyPreferenceKey(userId);
    final held = (await _prefs()).getString(saltKey);
    if (held != null && held.isNotEmpty) return held;
    return _makingKeys[saltKey] ??= _makeRefusalKey(saltKey).whenComplete(() {
      // A block, not an arrow: returning the removed future would make this
      // one wait for itself.
      _makingKeys.remove(saltKey);
    });
  }

  /// Creates the key only if it is still absent, then reads it back, so a
  /// key another isolate saved first is the one used.
  Future<String> _makeRefusalKey(String saltKey) async {
    var prefs = await _prefs();
    final held = prefs.getString(saltKey);
    if (held != null && held.isNotEmpty) return held;
    final random = Random.secure();
    final made = base64Url.encode([
      for (var i = 0; i < 32; i++) random.nextInt(256),
    ]);
    await prefs.setString(saltKey, made);
    prefs = await _prefs();
    final saved = prefs.getString(saltKey);
    return saved == null || saved.isEmpty ? made : saved;
  }

  /// Remembers that the server refused [value] for [key].
  ///
  /// A sync that started before the session ended can reach this after the
  /// sign-out forgot this account's refusals. The write runs under [write],
  /// which rechecks the session owner and generation before and after it
  /// (outside a protected scope it is a plain transaction). When the session
  /// ended around the write, what it saved is forgotten again, so the memory
  /// is not recreated for a signed-out account.
  Future<void> markRefused(String key, Object? value, int revision) async {
    try {
      await write(() async {
        final held = {...await refused()};
        held[key] = (
          fingerprint: await refusalFingerprint(value),
          revision: revision,
        );
        await _saveRefused(held);
      });
    } on WorkspaceAccessFailure {
      await forgetAccountSettingRefusals(await _prefs(), userId);
      rethrow;
    }
  }

  /// Forgets the refusals of [keys]: the value moved on, so the next choice is
  /// a new edit, even if it is the refused value again.
  Future<void> forgetRefused(Iterable<String> keys) async {
    final held = {...await refused()};
    var changed = false;
    for (final key in keys) {
      changed = held.remove(key) != null || changed;
    }
    if (changed) await _saveRefused(held);
  }

  Future<void> _saveRefused(
    Map<String, ({String fingerprint, int revision})> held,
  ) async {
    final prefs = await _prefs();
    if (held.isEmpty) {
      await prefs.remove(_refusedKey);
      return;
    }
    await prefs.setString(
      _refusedKey,
      jsonEncode({
        for (final e in held.entries)
          e.key: {
            'fingerprint': e.value.fingerprint,
            'keyed': true,
            'revision': e.value.revision,
          },
      }),
    );
  }

  // ── Joining the account ────────────────────────────────────────────────────

  /// Whether this device has sent its first snapshot. Until it has, edits are
  /// not queued: the snapshot carries them.
  Future<bool> isJoined() async =>
      (await _prefs()).getBool(_joinedKey) ?? false;

  Future<void> markJoined() async => (await _prefs()).setBool(_joinedKey, true);

  // ── The one-time note ──────────────────────────────────────────────────────

  /// Remembers which setting groups the account replaced on this device.
  Future<void> addNoteGroups(Set<String> groups) async {
    if (groups.isEmpty) return;
    final prefs = await _prefs();
    if (prefs.getBool(_noteShownKey) ?? false) return;
    final merged = {...?prefs.getStringList(_noteGroupsKey), ...groups}.toList()
      ..sort();
    await prefs.setStringList(_noteGroupsKey, merged);
  }

  /// The groups to name in the note, or empty when there is nothing to say or
  /// it has been shown.
  Future<List<String>> pendingNote() async {
    final prefs = await _prefs();
    if (prefs.getBool(_noteShownKey) ?? false) return const [];
    return prefs.getStringList(_noteGroupsKey) ?? const [];
  }

  Future<void> dismissNote() async {
    final prefs = await _prefs();
    await prefs.setBool(_noteShownKey, true);
    await prefs.remove(_noteGroupsKey);
  }

  // ── Local edits ────────────────────────────────────────────────────────────

  /// Writes [value] here and, once this device has joined the account, queues
  /// it to be sent against the revision this device last saw. An invalid value
  /// throws and changes nothing.
  Future<void> writeSetting(String key, Object? value) async {
    final parsed = AccountSettingCodec.parse(key, value);
    if (!parsed.ok || parsed.value == null) {
      throw ArgumentError.value(value, key, 'Not a valid account setting');
    }
    await local.apply(key, parsed.value);
    await queueLocalChanges(only: {key});
  }

  /// Compares what this device holds with what the server last said and queues
  /// every difference as an edit. It is the catch-all for anything that wrote a
  /// local store directly: the settings screens, and a backup restore, whose
  /// values therefore travel as ordinary edits against the current revision, so
  /// the account's value still wins a conflict.
  ///
  /// Returns the keys queued. Does nothing before this device has joined.
  Future<Set<String>> queueLocalChanges({Set<String>? only}) async {
    if (!await isJoined()) return const {};
    final held = await mirror();
    final waiting = await pending();
    final queued = <String>{};
    final all = await local.readAll();
    final explicit = (await local.readExplicit()).keys.toSet();
    final turnedDownByKey = await refused();
    for (final entry in all.entries) {
      final key = entry.key;
      if (only != null && !only.contains(key)) continue;
      final current = entry.value;
      final queuedEdit = waiting[key];
      if (queuedEdit != null) {
        // A newer edit replaces an unsent one; the base stays the one the first
        // edit was made against, so a changed account value still wins.
        if (!queuedEdit.ifAbsent &&
            AccountSettingCodec.canonicalText(queuedEdit.value) !=
                AccountSettingCodec.canonicalText(current)) {
          await queue(key, current, baseRevision: queuedEdit.baseRevision);
          queued.add(key);
        }
        continue;
      }
      final known = held[key];
      final turnedDown = turnedDownByKey[key];
      if (turnedDown != null) {
        if (turnedDown.fingerprint == await refusalFingerprint(current) &&
            turnedDown.revision == (known?.revision ?? 0)) {
          continue;
        }
        // The value or the account moved on since the refusal. Forget it, so
        // coming back to the refused value later is a new edit, not a repeat.
        await forgetRefused([key]);
      }
      if (known == null) {
        // The account never held it: fill it in, never overwrite. A default
        // nobody chose is not a value to fill in.
        if (!explicit.contains(key)) continue;
        await queue(key, current, baseRevision: 0, ifAbsent: true);
        queued.add(key);
        continue;
      }
      if (known.value == null) continue;
      final accountForm = await local.comparable(key, known.value);
      if (AccountSettingCodec.canonicalText(accountForm) ==
          AccountSettingCodec.canonicalText(current)) {
        continue;
      }
      await queue(
        key,
        await local.forSend(key, current, known.value),
        baseRevision: known.revision,
      );
      queued.add(key);
    }
    return queued;
  }
}
