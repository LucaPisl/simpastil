import 'dart:convert';

import '../storage/appearance_preferences.dart';

/// Names of the wire keys, identical to `contracts/account-settings-v1.json`,
/// the server zod allowlist and the OpenAPI document.
abstract final class AccountSettingKeys {
  static const snoozeMinutes = 'reminders.snoozeMinutes';
  static const routinePrefix = 'reminders.routine.';
  static const personPrefix = 'reminders.person.';
  static const recordedBy = 'recordedBy';
  static const asNeededInStats = 'asNeeded.inStats';
  static const siblingDetection = 'medications.siblingDetection';
  static const noticesLater = 'today.noticesLater';
  static const appearanceText = 'appearance.text';
  static const appearanceColors = 'appearance.colors';
  static const language = 'language';

  static const fixed = <String>[
    snoozeMinutes,
    recordedBy,
    asNeededInStats,
    siblingDetection,
    noticesLater,
    appearanceText,
    appearanceColors,
    language,
  ];

  static String routine(String scheduleServerId) =>
      '$routinePrefix$scheduleServerId';
  static String person(String profileServerId) =>
      '$personPrefix$profileServerId';

  static bool isRoutine(String key) => key.startsWith(routinePrefix);
  static bool isPerson(String key) => key.startsWith(personPrefix);
  static bool isEntityKey(String key) => isRoutine(key) || isPerson(key);

  /// The part after the family prefix: the record's server id.
  static String entityId(String key) => key.substring(
    isRoutine(key) ? routinePrefix.length : personPrefix.length,
  );

  /// Which group a person recognizes the key by, used by the "came along"
  /// note. The values are l10n selectors, not display text.
  static String groupOf(String key) {
    if (key == snoozeMinutes || isEntityKey(key)) return 'reminders';
    if (key == recordedBy) return 'recordedBy';
    if (key == asNeededInStats || key == siblingDetection) return 'medications';
    if (key == noticesLater) return 'notices';
    if (key == appearanceText) return 'text';
    if (key == appearanceColors) return 'colors';
    if (key == language) return 'language';
    return 'other';
  }
}

const accountSettingMaxValueBytes = 8192;

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _isoDay = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _languageTag = RegExp(r'^[a-z]{2,3}(-[A-Z]{2})?$');

/// The outcome of reading one wire value. A value the client cannot read is
/// ignored by the caller: the local value stays and the pull carries on.
class ParsedSetting {
  const ParsedSetting._(this.ok, this.value);
  const ParsedSetting.valid(Object? value) : this._(true, value);
  static const invalid = ParsedSetting._(false, null);
  final bool ok;

  /// The canonical form: maps with sorted keys, trimmed strings.
  final Object? value;
}

/// Reads and writes the wire form of every account setting. Pure: it knows
/// nothing about where a value is stored on this device.
class AccountSettingCodec {
  const AccountSettingCodec._();

  static bool isKnownKey(String key) {
    if (AccountSettingKeys.fixed.contains(key)) return true;
    if (AccountSettingKeys.isRoutine(key)) {
      return _uuid.hasMatch(
        key.substring(AccountSettingKeys.routinePrefix.length),
      );
    }
    if (AccountSettingKeys.isPerson(key)) {
      return _uuid.hasMatch(
        key.substring(AccountSettingKeys.personPrefix.length),
      );
    }
    return false;
  }

  /// A key and value as the server would read them. A null value is a
  /// cleared key and is valid for every known key.
  static ParsedSetting parse(String key, Object? raw) {
    if (!isKnownKey(key)) return ParsedSetting.invalid;
    if (raw == null) return const ParsedSetting.valid(null);
    try {
      if (utf8.encode(jsonEncode(raw)).length > accountSettingMaxValueBytes) {
        return ParsedSetting.invalid;
      }
    } on Object {
      return ParsedSetting.invalid;
    }
    final value = _parseValue(key, raw);
    return value == null
        ? ParsedSetting.invalid
        : ParsedSetting.valid(value.$1);
  }

  /// The value, or null when it is not valid. Wrapped in a record so a valid
  /// `false` is not confused with invalid.
  static (Object?,)? _parseValue(String key, Object raw) {
    if (key == AccountSettingKeys.snoozeMinutes) {
      return raw is int && raw >= 1 && raw <= 240 ? (raw,) : null;
    }
    if (AccountSettingKeys.isRoutine(key)) return _routine(raw);
    if (AccountSettingKeys.isPerson(key)) {
      if (raw is Map &&
          _only(raw, const {'enabled'}) &&
          raw['enabled'] is bool) {
        return ({'enabled': raw['enabled']},);
      }
      return null;
    }
    return switch (key) {
      AccountSettingKeys.recordedBy => _recordedBy(raw),
      AccountSettingKeys.asNeededInStats => raw is bool ? (raw,) : null,
      AccountSettingKeys.siblingDetection =>
        raw is String &&
                const ['nameAndDosage', 'nameOnly', 'perPill'].contains(raw)
            ? (raw,)
            : null,
      AccountSettingKeys.noticesLater => _noticesLater(raw),
      AccountSettingKeys.appearanceText => _appearanceText(raw),
      AccountSettingKeys.appearanceColors => _appearanceColors(raw),
      AccountSettingKeys.language =>
        raw is String && (raw == 'system' || _languageTag.hasMatch(raw))
            ? (raw,)
            : null,
      _ => null,
    };
  }

  static bool _only(Map map, Set<String> allowed) =>
      map.keys.every((k) => k is String && allowed.contains(k));

  static (Object?,)? _routine(Object raw) {
    if (raw is! Map ||
        !_only(raw, const {'enabled', 'followUpMinutes'}) ||
        raw['enabled'] is! bool) {
      return null;
    }
    final minutes = raw['followUpMinutes'];
    if (minutes is! List ||
        minutes.length > 6 ||
        minutes.any((m) => m is! int || m < 1 || m > 720)) {
      return null;
    }
    return (
      {'enabled': raw['enabled'], 'followUpMinutes': List<int>.from(minutes)},
    );
  }

  static (Object?,)? _recordedBy(Object raw) {
    if (raw is! Map ||
        !_only(raw, const {'version', 'mode', 'customName'}) ||
        raw['version'] != 1 ||
        !const [
          'primaryProfile',
          'custom',
          'personTakingIt',
        ].contains(raw['mode'])) {
      return null;
    }
    final out = <String, Object?>{'mode': raw['mode'], 'version': 1};
    if (raw.containsKey('customName')) {
      final name = raw['customName'];
      if (name is! String) return null;
      final trimmed = name.trim();
      if (trimmed.isEmpty || trimmed.length > 60) return null;
      out['customName'] = trimmed;
    }
    return (out,);
  }

  static (Object?,)? _noticesLater(Object raw) {
    if (raw is! List || raw.length > 500) return null;
    final out = <Map<String, Object?>>[];
    for (final item in raw) {
      if (item is! Map ||
          !_only(item, const {'medicationId', 'until'}) ||
          item['medicationId'] is! String ||
          !_uuid.hasMatch(item['medicationId'] as String) ||
          item['until'] is! String ||
          !_isoDay.hasMatch(item['until'] as String)) {
        return null;
      }
      out.add({'medicationId': item['medicationId'], 'until': item['until']});
    }
    return (out,);
  }

  static (Object?,)? _appearanceText(Object raw) {
    if (raw is! Map ||
        !_only(raw, const {'fontSize', 'highContrast', 'reduceMotion'}) ||
        !const [
          'defaultSize',
          'large',
          'extraLarge',
        ].contains(raw['fontSize']) ||
        raw['highContrast'] is! bool ||
        raw['reduceMotion'] is! bool) {
      return null;
    }
    return (
      {
        'fontSize': raw['fontSize'],
        'highContrast': raw['highContrast'],
        'reduceMotion': raw['reduceMotion'],
      },
    );
  }

  static Map<String, int>? _colorMap(Object? raw) {
    if (raw is! Map) return null;
    final roles = {for (final r in AppearanceColorRole.values) r.name};
    final out = <String, int>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (entry.key is! String ||
          !roles.contains(entry.key) ||
          value is! int ||
          value < 0xff000000 ||
          value > 0xffffffff) {
        return null;
      }
      out[entry.key as String] = value;
    }
    return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  static (Object?,)? _appearanceColors(Object raw) {
    if (raw is! Map || !_only(raw, const {'light', 'dark'})) return null;
    final light = _colorMap(raw['light']);
    final dark = _colorMap(raw['dark']);
    if (light == null || dark == null) return null;
    return ({'dark': dark, 'light': light},);
  }

  /// A stable text form of a canonical value, for comparing two values.
  static String canonicalText(Object? value) => jsonEncode(_sorted(value));

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k as String).toList()..sort();
      return {for (final k in keys) k: _sorted(value[k])};
    }
    if (value is List) return [for (final v in value) _sorted(v)];
    return value;
  }
}
