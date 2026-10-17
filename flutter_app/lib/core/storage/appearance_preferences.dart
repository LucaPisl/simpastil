import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../projections/projection_effects_gate.dart';
import 'portable_preference_writer.dart';

enum AppearanceMode { system, light, dark }

enum AppearanceFontSize {
  defaultSize(1.0),
  large(1.15),
  extraLarge(1.3);

  const AppearanceFontSize(this.multiplier);
  final double multiplier;
}

enum AppearanceColorRole {
  primary,
  onPrimary,
  primaryContainer,
  onPrimaryContainer,
  background,
  text,
  surface,
  surfaceVariant,
  mutedText,
  border,
  secondary,
  onSecondary,
  tertiary,
  onTertiary,
  error,
  onError,
  taken,
  skipped,
  unrecorded,
  activePerson,
  inactivePerson,
}

/// Viewer-only presentation. Empty overrides use the delivered brand theme;
/// contrast and editor recovery controls are rendered independently by the UI.
class AppearancePreferences {
  AppearancePreferences({
    this.mode = AppearanceMode.system,
    this.dynamicColor = false,
    this.fontSize = AppearanceFontSize.defaultSize,
    this.highContrast = false,
    this.reduceMotion = false,
    Map<AppearanceColorRole, int> lightColors = const {},
    Map<AppearanceColorRole, int> darkColors = const {},
  }) : lightColors = _colors(lightColors),
       darkColors = _colors(darkColors);

  final AppearanceMode mode;
  final bool dynamicColor;
  final AppearanceFontSize fontSize;
  final bool highContrast;

  /// Motion collapses to its final frame in this app, as when the phone asks
  /// for reduced motion. The phone's own setting still applies when this is off.
  final bool reduceMotion;
  final Map<AppearanceColorRole, int> lightColors;
  final Map<AppearanceColorRole, int> darkColors;

  static Map<AppearanceColorRole, int> _colors(
    Map<AppearanceColorRole, int> values,
  ) {
    for (final color in values.values) {
      if (color < 0xff000000 || color > 0xffffffff) {
        throw const FormatException(
          'Appearance colors must be opaque ARGB values',
        );
      }
    }
    return Map.unmodifiable(values);
  }

  AppearancePreferences copyWith({
    AppearanceMode? mode,
    bool? dynamicColor,
    AppearanceFontSize? fontSize,
    bool? highContrast,
    bool? reduceMotion,
    Map<AppearanceColorRole, int>? lightColors,
    Map<AppearanceColorRole, int>? darkColors,
  }) => AppearancePreferences(
    mode: mode ?? this.mode,
    dynamicColor: dynamicColor ?? this.dynamicColor,
    fontSize: fontSize ?? this.fontSize,
    highContrast: highContrast ?? this.highContrast,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    lightColors: lightColors ?? this.lightColors,
    darkColors: darkColors ?? this.darkColors,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'mode': mode.name,
    'dynamicColor': dynamicColor,
    'fontSize': fontSize.name,
    'highContrast': highContrast,
    'reduceMotion': reduceMotion,
    'lightColors': {
      for (final role in AppearanceColorRole.values)
        if (lightColors.containsKey(role)) role.name: lightColors[role],
    },
    'darkColors': {
      for (final role in AppearanceColorRole.values)
        if (darkColors.containsKey(role)) role.name: darkColors[role],
    },
  };

  factory AppearancePreferences.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported appearance version');
    }
    T choice<T extends Enum>(List<T> values, Object? name) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      throw const FormatException('Unsupported appearance choice');
    }

    Map<AppearanceColorRole, int> colors(Object? value) {
      if (value is! Map) {
        throw const FormatException('Invalid appearance colors');
      }
      return {
        for (final entry in value.entries)
          choice(AppearanceColorRole.values, entry.key): entry.value is int
              ? entry.value as int
              : throw const FormatException('Invalid appearance color'),
      };
    }

    // reduceMotion arrived after version 1 shipped: a document without it
    // reads as off, and an older app ignores it.
    if (json['dynamicColor'] is! bool ||
        json['highContrast'] is! bool ||
        (json.containsKey('reduceMotion') && json['reduceMotion'] is! bool)) {
      throw const FormatException('Invalid appearance preferences');
    }
    return AppearancePreferences(
      mode: choice(AppearanceMode.values, json['mode']),
      dynamicColor: json['dynamicColor'] as bool,
      fontSize: choice(AppearanceFontSize.values, json['fontSize']),
      highContrast: json['highContrast'] as bool,
      reduceMotion: json['reduceMotion'] as bool? ?? false,
      lightColors: colors(json['lightColors']),
      darkColors: colors(json['darkColors']),
    );
  }

  factory AppearancePreferences.fromLegacy(Map<String, Object?> values) =>
      AppearancePreferences(
        mode: switch (values['app_theme_mode']) {
          'light' => AppearanceMode.light,
          'dark' => AppearanceMode.dark,
          _ => AppearanceMode.system,
        },
        dynamicColor: values['dynamic_color_enabled'] == true,
        fontSize: switch (values['app_font_size']) {
          'large' => AppearanceFontSize.large,
          'extraLarge' => AppearanceFontSize.extraLarge,
          _ => AppearanceFontSize.defaultSize,
        },
        highContrast: values['high_contrast_enabled'] == true,
      );
}

abstract interface class AppearancePreferenceStorage {
  Future<String?> readDocument();
  Future<Map<String, Object?>> readLegacy();
  Future<bool> writeDocument(String value);
}

class SharedAppearancePreferenceStorage implements AppearancePreferenceStorage {
  const SharedAppearancePreferenceStorage(this.preferences, {this.gate});
  static const key = 'appearance_preferences_v1';
  final SharedPreferences preferences;
  final ProjectionEffectsGate? gate;
  @override
  Future<String?> readDocument() async => preferences.getString(key);
  @override
  Future<Map<String, Object?>> readLegacy() async => {
    for (final name in [
      'app_theme_mode',
      'dynamic_color_enabled',
      'app_font_size',
      'high_contrast_enabled',
    ])
      name: preferences.get(name),
  };
  @override
  Future<bool> writeDocument(String value) =>
      PortablePreferenceWriter(preferences, gate: gate).write(key, value);
}

class AppearancePersistenceFailure implements Exception {
  const AppearancePersistenceFailure();
}

/// Apply is one durable document write; preview/cancel are caller-owned drafts.
/// Failed writes leave the last loaded/applied object intact and permit retry.
class AppearancePreferencesRepository {
  AppearancePreferencesRepository(this.storage);
  final AppearancePreferenceStorage storage;
  AppearancePreferences? _applied;
  Future<AppearancePreferences>? _loading;
  Future<void> _writes = Future.value();

  Future<AppearancePreferences> load() {
    if (_applied case final applied?) return Future.value(applied);
    return _loading ??= () async {
      try {
        final document = await storage.readDocument();
        final loaded = document == null
            ? AppearancePreferences.fromLegacy(await storage.readLegacy())
            : AppearancePreferences.fromJson(
                Map<String, Object?>.from(jsonDecode(document) as Map),
              );
        return _applied = loaded;
      } finally {
        _loading = null;
      }
    }();
  }

  Future<void> save(AppearancePreferences reviewed) => _save(reviewed);

  Future<void> _save(AppearancePreferences reviewed, {bool reset = false}) {
    final write = _writes.then((_) async {
      try {
        await load();
      } on Object {
        if (!reset) rethrow;
        // Explicit appearance recovery may replace an unreadable presentation
        // document. It neither clears legacy preferences nor opens care storage.
      }
      final accepted = await storage.writeDocument(
        jsonEncode(reviewed.toJson()),
      );
      if (!accepted) throw const AppearancePersistenceFailure();
      _applied = reviewed;
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  /// Back to the delivered look. Reduced motion is an access need, not a
  /// look, so it stays as it was when the saved document can be read.
  Future<void> reset() async {
    var reduceMotion = false;
    try {
      reduceMotion = (await load()).reduceMotion;
    } on Object {
      // An unreadable document is replaced with plain defaults.
    }
    return _save(
      AppearancePreferences(reduceMotion: reduceMotion),
      reset: true,
    );
  }
}
