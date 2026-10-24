import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../db/database.dart';
import '../medication/routine_definition.dart' show routineDateKey;
import '../projections/projection_effects_gate.dart';
import '../storage/appearance_preferences.dart';
import '../storage/low_stock_dismissal_preference.dart';
import '../storage/portable_preference_writer.dart';
import '../storage/preference_keys.dart';
import '../storage/recorded_by_preference.dart';
import 'account_setting_codec.dart';

/// Runs a database write the way the caller needs it (inside the protected
/// write scope when there is one).
typedef SettingsWrite = Future<T> Function<T>(Future<T> Function() action);

const accountSnoozeDefaultMinutes = 15;
const _siblingDefault = 'nameAndDosage';

/// Reads and writes the stores the app already reads its account settings
/// from: preferences, the appearance document and the reminder tables. The
/// account sync keeps those stores up to date, so no reader of a setting needs
/// to know the setting follows the account.
class LocalAccountSettings {
  LocalAccountSettings({
    required this.db,
    required this.userId,
    required this.write,
    SharedPreferences? preferences,
    ProjectionEffectsGate? gate,
    DateTime Function()? now,
  }) : _preferences = preferences,
       _gate = gate ?? privatePortablePreferenceGate,
       _now = now ?? DateTime.now;

  final AppDatabase db;
  final String userId;
  final SettingsWrite write;
  final SharedPreferences? _preferences;
  final ProjectionEffectsGate _gate;
  final DateTime Function() _now;

  Future<SharedPreferences> _prefs() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    // A background isolate may hold a snapshot older than the app's last save.
    await prefs.reload();
    return prefs;
  }

  Future<void> _portable(SharedPreferences prefs, String key, Object? value) =>
      PortablePreferenceWriter(
        prefs,
        gate: _gate,
        announce: false,
      ).write(key, value);

  String get _snoozeKey => 'snooze_duration_minutes_$userId';
  String get _siblingKey => 'sibling_detection_mode_$userId';
  static const _localeKey = 'app_locale';

  /// The value of every key this device can name right now, in the canonical
  /// form of the wire. Fixed keys always carry their effective value, defaults
  /// included, so a comparison with the account is always like for like.
  /// Per-record keys appear only for records that have a server id and a stored
  /// choice. To seed the account use [readExplicit], never this.
  Future<Map<String, Object?>> readAll() async {
    final prefs = await _prefs();
    final out = <String, Object?>{};
    final snooze = prefs.getInt(_snoozeKey) ?? accountSnoozeDefaultMinutes;
    out[AccountSettingKeys.snoozeMinutes] = snooze.clamp(1, 240);

    final setting = RecordedBySetting.read(prefs, userId);
    final custom = setting.customName.trim();
    out[AccountSettingKeys.recordedBy] = {
      'mode': setting.mode.name,
      'version': 1,
      if (setting.mode == RecordedByMode.custom && custom.isNotEmpty)
        'customName': custom.length > 60 ? custom.substring(0, 60) : custom,
    };
    out[AccountSettingKeys.asNeededInStats] =
        prefs.getBool(prnInStatsPreferenceKey(userId)) ?? false;
    final sibling = prefs.getString(_siblingKey);
    out[AccountSettingKeys.siblingDetection] =
        const ['nameAndDosage', 'nameOnly', 'perPill'].contains(sibling)
        ? sibling
        : _siblingDefault;
    out[AccountSettingKeys.noticesLater] = await _readNotices(prefs);

    final appearance = await _loadAppearance(prefs);
    out[AccountSettingKeys.appearanceText] = {
      'fontSize': appearance.fontSize.name,
      'highContrast': appearance.highContrast,
      'reduceMotion': appearance.reduceMotion,
    };
    out[AccountSettingKeys.appearanceColors] = {
      'dark': _colorsOf(appearance.darkColors),
      'light': _colorsOf(appearance.lightColors),
    };
    final code = prefs.getString(_localeKey);
    out[AccountSettingKeys.language] = code == null || code.isEmpty
        ? 'system'
        : code;

    out.addAll(await _readRoutines());
    out.addAll(await _readPeople());
    return out;
  }

  /// Only the settings the user actually chose on this device: a stored value
  /// that differs from the app's default. What the account has never held is
  /// seeded from these alone, so a device still on its defaults can never
  /// overwrite the choices of a customised one (they would reach it as the
  /// account's values).
  Future<Map<String, Object?>> readExplicit() async {
    final all = await readAll();
    final prefs = await _prefs();
    bool stored(String key) => prefs.containsKey(key);
    // Set through a settings control here, so even the default is a choice.
    final chosenKeys =
        prefs.getStringList(chosenSettingKeysPreferenceKey(userId)) ?? const [];
    bool chosen(String key) => chosenKeys.contains(key);
    // A device-wide value another account chose, or that is still waiting
    // for the next sign-in, is not this account's choice. Without a record
    // (stored by an older build) it counts as before.
    bool mine(String key) {
      final chooser = prefs.getString(settingChooserPreferenceKey(key));
      return chooser == null || chooser == userId;
    }

    final out = <String, Object?>{};
    for (final entry in all.entries) {
      final key = entry.key;
      final value = entry.value;
      final explicit = switch (key) {
        // A stored value equal to the default is not a choice: older builds
        // (and the Reminders page) wrote the defaults just by being opened.
        AccountSettingKeys.snoozeMinutes =>
          stored(_snoozeKey) &&
              (value != accountSnoozeDefaultMinutes || chosen(_snoozeKey)),
        AccountSettingKeys.recordedBy =>
          (stored(recordedByModePreferenceKey(userId)) ||
                  stored(recordedByNamePreferenceKey(userId))) &&
              value is Map &&
              (value['mode'] != RecordedByMode.primaryProfile.name ||
                  value.containsKey('customName') ||
                  chosen(recordedByModePreferenceKey(userId)) ||
                  chosen(recordedByNamePreferenceKey(userId))),
        AccountSettingKeys.asNeededInStats =>
          stored(prnInStatsPreferenceKey(userId)) &&
              (value == true || chosen(prnInStatsPreferenceKey(userId))),
        AccountSettingKeys.siblingDetection =>
          stored(_siblingKey) &&
              (value != _siblingDefault || chosen(_siblingKey)),
        AccountSettingKeys.noticesLater => value is List && value.isNotEmpty,
        AccountSettingKeys.appearanceText =>
          mine(SharedAppearancePreferenceStorage.key) &&
              value is Map &&
              (value['fontSize'] != AppearanceFontSize.defaultSize.name ||
                  value['highContrast'] == true ||
                  value['reduceMotion'] == true),
        AccountSettingKeys.appearanceColors =>
          mine(SharedAppearancePreferenceStorage.key) &&
              value is Map &&
              ((value['dark'] as Map).isNotEmpty ||
                  (value['light'] as Map).isNotEmpty),
        AccountSettingKeys.language =>
          mine(_localeKey) && (value != 'system' || chosen(_localeKey)),
        _ => true, // per-record keys exist only for a stored choice
      };
      if (explicit) out[key] = value;
    }
    return out;
  }

  Map<String, int> _colorsOf(Map<AppearanceColorRole, int> colors) {
    final names = colors.keys.map((r) => r.name).toList()..sort();
    return {
      for (final name in names)
        name: colors[AppearanceColorRole.values.byName(name)]!,
    };
  }

  Future<AppearancePreferences> _loadAppearance(SharedPreferences prefs) async {
    try {
      return await AppearancePreferencesRepository(
        SharedAppearancePreferenceStorage(prefs, gate: _gate),
      ).load();
    } on Object {
      return AppearancePreferences();
    }
  }

  // ── Notices put off with "Later" ───────────────────────────────────────────

  Future<Map<String, String>> _pillServerIds() async {
    final rows = await db
        .customSelect(
          'SELECT p.id AS id, p.server_id AS server_id FROM pills p '
          'JOIN profiles f ON f.id = p.profile_id '
          'WHERE f.user_id = ?1 AND p.server_id IS NOT NULL',
          variables: [Variable<String>(userId)],
          readsFrom: {db.pills, db.profiles},
        )
        .get();
    return {
      for (final row in rows)
        row.read<String>('id'): row.read<String>('server_id'),
    };
  }

  Future<List<Map<String, Object?>>> _readNotices(
    SharedPreferences prefs,
  ) async {
    final today = routineDateKey(_now());
    final serverIds = await _pillServerIds();
    final out = <Map<String, Object?>>[];
    for (final entry
        in prefs.getStringList(kLowStockDismissedPreferenceKey) ??
            const <String>[]) {
      final at = entry.lastIndexOf('|');
      if (at <= 0) continue;
      final until = entry.substring(at + 1);
      final serverId = serverIds[entry.substring(0, at)];
      if (serverId == null || until.compareTo(today) <= 0) continue;
      out.add({'medicationId': serverId, 'until': until});
    }
    out.sort(
      (a, b) =>
          (a['medicationId'] as String).compareTo(b['medicationId'] as String),
    );
    return out;
  }

  // ── Per-record reminders ───────────────────────────────────────────────────

  Future<String?> _workspaceId() async {
    final row = await (db.select(
      db.careWorkspaces,
    )..where((w) => w.ownerUserId.equals(userId))).getSingleOrNull();
    return row?.id;
  }

  Future<Map<String, Object?>> _readRoutines() async {
    final workspaceId = await _workspaceId();
    if (workspaceId == null) return const {};
    final rows = await db
        .customSelect(
          'SELECT s.server_id AS server_id, r.enabled AS enabled, '
          'r.follow_up_minutes_json AS follow_ups '
          'FROM device_schedule_reminders r '
          'JOIN schedules s ON s.id = r.schedule_id '
          'WHERE r.workspace_id = ?1 AND s.server_id IS NOT NULL '
          'AND s.is_deleted = 0',
          variables: [Variable<String>(workspaceId)],
          readsFrom: {db.deviceScheduleReminders, db.schedules},
        )
        .get();
    final out = <String, Object?>{};
    for (final row in rows) {
      final minutes = <int>[];
      try {
        for (final m in jsonDecode(row.read<String>('follow_ups')) as List) {
          if (m is int && m >= 1 && m <= 720) minutes.add(m);
        }
      } on Object {
        // An unreadable list reads as none.
      }
      minutes.sort();
      out[AccountSettingKeys.routine(row.read<String>('server_id'))] = {
        'enabled': row.read<bool>('enabled'),
        'followUpMinutes': minutes.take(6).toList(),
      };
    }
    return out;
  }

  Future<Map<String, Object?>> _readPeople() async {
    final rows = await db
        .customSelect(
          'SELECT p.server_id AS server_id, r.enabled AS enabled '
          'FROM device_person_reminders r '
          'JOIN profiles p ON p.id = r.profile_id '
          'WHERE p.user_id = ?1 AND p.server_id IS NOT NULL '
          'AND p.is_deleted = 0',
          variables: [Variable<String>(userId)],
          readsFrom: {db.devicePersonReminders, db.profiles},
        )
        .get();
    return {
      for (final row in rows)
        AccountSettingKeys.person(row.read<String>('server_id')): {
          'enabled': row.read<bool>('enabled'),
        },
    };
  }

  // ── Comparing ──────────────────────────────────────────────────────────────

  /// What [readAll] would return for [key] once [serverValue] has been applied
  /// here. A value this device cannot show (an unsupported language, a notice
  /// for a medication it does not have, one that has passed) reads as its
  /// nearest local form, so such a value never looks like a local edit.
  Future<Object?> comparable(String key, Object? serverValue) async {
    if (serverValue == null) return null;
    if (key == AccountSettingKeys.language) {
      final code = _supportedCode(serverValue as String);
      return code ?? 'system';
    }
    if (key == AccountSettingKeys.noticesLater) {
      final today = routineDateKey(_now());
      final known = (await _pillServerIds()).values.toSet();
      final kept = <Map<Object?, Object?>>[
        for (final n in serverValue as List)
          if (known.contains((n as Map)['medicationId']) &&
              (n['until'] as String).compareTo(today) > 0)
            n,
      ];
      return kept..sort(
        (a, b) => (a['medicationId'] as String).compareTo(
          b['medicationId'] as String,
        ),
      );
    }
    if (key == AccountSettingKeys.recordedBy) {
      final value = Map<String, Object?>.from(serverValue as Map);
      if (value['mode'] != 'custom') value.remove('customName');
      return value;
    }
    return serverValue;
  }

  /// The value to send for [key] when this device's [local] value replaces
  /// [accountValue]: notices for medications this device does not know about
  /// are the account's to keep.
  Future<Object?> forSend(
    String key,
    Object? local,
    Object? accountValue,
  ) async {
    if (key != AccountSettingKeys.noticesLater || accountValue is! List) {
      return local;
    }
    final today = routineDateKey(_now());
    final known = (await _pillServerIds()).values.toSet();
    final merged = <Map<String, Object?>>[
      for (final n in local as List) Map<String, Object?>.from(n as Map),
      for (final n in accountValue)
        if (!known.contains((n as Map)['medicationId']) &&
            (n['until'] as String).compareTo(today) > 0)
          Map<String, Object?>.from(n),
    ];
    return merged.length > 500 ? merged.sublist(0, 500) : merged;
  }

  String? _supportedCode(String tag) {
    if (tag == 'system') return null;
    final code = tag.split('-').first;
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == code) return code;
    }
    return null;
  }

  // ── Applying ───────────────────────────────────────────────────────────────

  /// Writes [value] (canonical, or null for a cleared key) into the store the
  /// app reads. Returns false when the record the key names does not exist on
  /// this device yet; the caller tries again on a later pull.
  Future<bool> apply(String key, Object? value) async {
    final prefs = await _prefs();
    switch (key) {
      case AccountSettingKeys.snoozeMinutes:
        await _portable(prefs, _snoozeKey, value);
      case AccountSettingKeys.recordedBy:
        await _applyRecordedBy(prefs, value as Map?);
      case AccountSettingKeys.asNeededInStats:
        await _portable(prefs, prnInStatsPreferenceKey(userId), value);
      case AccountSettingKeys.siblingDetection:
        await _portable(prefs, _siblingKey, value);
      case AccountSettingKeys.noticesLater:
        await _applyNotices(prefs, value as List?);
      case AccountSettingKeys.appearanceText:
        await _applyAppearanceText(prefs, value as Map?);
      case AccountSettingKeys.appearanceColors:
        await _applyAppearanceColors(prefs, value as Map?);
      case AccountSettingKeys.language:
        final code = value == null ? null : _supportedCode(value as String);
        await _portable(prefs, _localeKey, code);
      default:
        if (AccountSettingKeys.isRoutine(key)) {
          return _applyRoutine(AccountSettingKeys.entityId(key), value as Map?);
        }
        if (AccountSettingKeys.isPerson(key)) {
          return _applyPerson(AccountSettingKeys.entityId(key), value as Map?);
        }
        throw ArgumentError.value(key, 'key', 'Unknown account setting');
    }
    return true;
  }

  Future<void> _applyRecordedBy(SharedPreferences prefs, Map? value) async {
    // Not portable by design (the custom name is personal), so written direct.
    final modeKey = recordedByModePreferenceKey(userId);
    final nameKey = recordedByNamePreferenceKey(userId);
    if (value == null) {
      await prefs.remove(modeKey);
      await prefs.remove(nameKey);
      return;
    }
    await prefs.setString(modeKey, value['mode'] as String);
    final name = value['customName'];
    if (name is String) await prefs.setString(nameKey, name);
  }

  Future<void> _applyNotices(SharedPreferences prefs, List? value) async {
    final today = routineDateKey(_now());
    final serverIds = await _pillServerIds();
    final localIds = {for (final e in serverIds.entries) e.value: e.key};
    final entries = <String>[];
    // Notices for medications that exist only on this device stay as they are.
    for (final entry
        in prefs.getStringList(kLowStockDismissedPreferenceKey) ??
            const <String>[]) {
      final at = entry.lastIndexOf('|');
      if (at <= 0) continue;
      if (!serverIds.containsKey(entry.substring(0, at)) &&
          entry.substring(at + 1).compareTo(today) > 0) {
        entries.add(entry);
      }
    }
    for (final n in value ?? const <Object?>[]) {
      final local = localIds[(n as Map)['medicationId']];
      final until = n['until'] as String;
      if (local != null && until.compareTo(today) > 0) {
        entries.add('$local|$until');
      }
    }
    await prefs.setStringList(kLowStockDismissedPreferenceKey, entries);
  }

  Future<void> _saveAppearance(
    SharedPreferences prefs,
    AppearancePreferences Function(AppearancePreferences current) change,
  ) async {
    final repository = AppearancePreferencesRepository(
      SharedAppearancePreferenceStorage(prefs, gate: _gate),
    );
    AppearancePreferences current;
    try {
      current = await repository.load();
    } on Object {
      current = AppearancePreferences();
    }
    await repository.save(change(current));
  }

  Future<void> _applyAppearanceText(SharedPreferences prefs, Map? value) =>
      _saveAppearance(
        prefs,
        (current) => current.copyWith(
          fontSize: value == null
              ? AppearanceFontSize.defaultSize
              : AppearanceFontSize.values.byName(value['fontSize'] as String),
          highContrast: value?['highContrast'] as bool? ?? false,
          reduceMotion: value?['reduceMotion'] as bool? ?? false,
        ),
      );

  Map<AppearanceColorRole, int> _rolesOf(Object? map) => {
    if (map is Map)
      for (final e in map.entries)
        AppearanceColorRole.values.byName(e.key as String): e.value as int,
  };

  Future<void> _applyAppearanceColors(SharedPreferences prefs, Map? value) =>
      _saveAppearance(
        prefs,
        (current) => current.copyWith(
          lightColors: _rolesOf(value?['light']),
          darkColors: _rolesOf(value?['dark']),
        ),
      );

  Future<bool> _applyRoutine(String serverId, Map? value) async {
    final workspaceId = await _workspaceId();
    if (workspaceId == null) return false;
    final schedule =
        await (db.select(db.schedules)..where(
              (s) => s.serverId.equals(serverId) & s.isDeleted.equals(false),
            ))
            .getSingleOrNull();
    if (schedule == null) return false;
    await write(() async {
      if (value == null) {
        await (db.delete(db.deviceScheduleReminders)..where(
              (r) =>
                  r.workspaceId.equals(workspaceId) &
                  r.scheduleId.equals(schedule.id),
            ))
            .go();
        return;
      }
      await db
          .into(db.deviceScheduleReminders)
          .insertOnConflictUpdate(
            DeviceScheduleRemindersCompanion.insert(
              workspaceId: workspaceId,
              scheduleId: schedule.id,
              enabled: Value(value['enabled'] as bool),
              followUpMinutesJson: Value(jsonEncode(value['followUpMinutes'])),
            ),
          );
    });
    return true;
  }

  Future<bool> _applyPerson(String serverId, Map? value) async {
    final person =
        await (db.select(db.profiles)..where(
              (p) =>
                  p.serverId.equals(serverId) &
                  p.userId.equals(userId) &
                  p.isDeleted.equals(false),
            ))
            .getSingleOrNull();
    if (person == null) return false;
    await write(() async {
      if (value == null) {
        await (db.delete(
          db.devicePersonReminders,
        )..where((r) => r.profileId.equals(person.id))).go();
        return;
      }
      await db
          .into(db.devicePersonReminders)
          .insertOnConflictUpdate(
            DevicePersonRemindersCompanion.insert(
              profileId: person.id,
              enabled: Value(value['enabled'] as bool),
            ),
          );
    });
    return true;
  }
}
