import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';

class FictionalSharedPreferences extends Mock implements SharedPreferences {}

class FictionalAppearanceStorage implements AppearancePreferenceStorage {
  String? document;
  final Map<String, Object?> legacy = {};
  bool fails = false;
  int writes = 0;
  @override
  Future<String?> readDocument() async => document;
  @override
  Future<Map<String, Object?>> readLegacy() async => Map.of(legacy);
  @override
  Future<bool> writeDocument(String value) async {
    writes++;
    if (fails) return false;
    document = value;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed native write reloads the plugin cache without applying preview values',
    () async {
      final prefs = FictionalSharedPreferences();
      final saved = jsonEncode(
        AppearancePreferences(mode: AppearanceMode.dark).toJson(),
      );
      var cache = saved;
      when(
        () => prefs.getString(SharedAppearancePreferenceStorage.key),
      ).thenAnswer((_) => cache);
      when(
        () => prefs.setString(SharedAppearancePreferenceStorage.key, any()),
      ).thenAnswer((call) async {
        cache = call.positionalArguments[1] as String;
        return false;
      });
      when(() => prefs.reload()).thenAnswer((_) async {
        cache = saved;
      });
      final repo = AppearancePreferencesRepository(
        SharedAppearancePreferenceStorage(
          prefs,
          gate: SerialProjectionEffectsGate(),
        ),
      );
      await repo.load();
      await expectLater(
        repo.save(AppearancePreferences(mode: AppearanceMode.light)),
        throwsA(isA<AppearancePersistenceFailure>()),
      );
      expect((await repo.load()).mode, AppearanceMode.dark);
      expect(cache, saved);
      // Freshness inside the barrier, then persistence reload after failure.
      verify(() => prefs.reload()).called(2);
    },
  );

  test(
    'legacy viewer choices load without writing or changing other preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'dynamic_color_enabled': true,
        'app_font_size': 'extraLarge',
        'high_contrast_enabled': true,
        'fictional_selected_person': 'person-a',
        'fictional_server': 'server-a',
        'fictional_draft': 'saved-draft',
      });
      final prefs = await SharedPreferences.getInstance();
      final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      final repo = AppearancePreferencesRepository(
        SharedAppearancePreferenceStorage(
          prefs,
          gate: SerialProjectionEffectsGate(),
        ),
      );
      final applied = await repo.load();
      expect(applied.mode, AppearanceMode.dark);
      expect(applied.dynamicColor, true);
      expect(applied.fontSize, AppearanceFontSize.extraLarge);
      expect(applied.highContrast, true);
      expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, before);
    },
  );

  test(
    'reviewed light/dark role colors and display choices round-trip as one document',
    () async {
      final storage = FictionalAppearanceStorage();
      final repo = AppearancePreferencesRepository(storage);
      final colors = {
        AppearanceColorRole.primary: 0xff6e66fa,
        AppearanceColorRole.background: 0xffffffff,
      };
      final draft = AppearancePreferences(
        mode: AppearanceMode.light,
        dynamicColor: false,
        fontSize: AppearanceFontSize.large,
        highContrast: true,
        lightColors: colors,
        darkColors: {AppearanceColorRole.surface: 0xff141414},
      );
      colors[AppearanceColorRole.primary] = 0xff000000;
      expect(draft.lightColors[AppearanceColorRole.primary], 0xff6e66fa);
      expect((await repo.load()).lightColors, isEmpty);
      expect(storage.writes, 0);
      await repo.save(draft);
      expect(storage.writes, 1);
      final reopened = await AppearancePreferencesRepository(storage).load();
      expect(jsonEncode(reopened.toJson()), jsonEncode(draft.toJson()));
      expect(reopened.darkColors[AppearanceColorRole.surface], 0xff141414);
    },
  );

  test(
    'failed Apply retains applied values and a retry persists the reviewed draft',
    () async {
      final storage = FictionalAppearanceStorage();
      final repo = AppearancePreferencesRepository(storage);
      final before = await repo.load();
      final draft = AppearancePreferences(
        mode: AppearanceMode.dark,
        lightColors: {AppearanceColorRole.text: 0xff000000},
      );
      storage.fails = true;
      await expectLater(
        repo.save(draft),
        throwsA(isA<AppearancePersistenceFailure>()),
      );
      expect(identical(await repo.load(), before), true);
      expect(storage.document, isNull);
      storage.fails = false;
      await repo.save(draft);
      expect(identical(await repo.load(), draft), true);
      expect(
        (await AppearancePreferencesRepository(storage).load()).mode,
        AppearanceMode.dark,
      );
    },
  );

  test(
    'unsupported or malformed saved appearance is retained for explicit recovery',
    () async {
      final storage = FictionalAppearanceStorage()
        ..document = '{"version":99,"fictional":"retained"}';
      await expectLater(
        AppearancePreferencesRepository(storage).load(),
        throwsA(isA<FormatException>()),
      );
      expect(storage.document, '{"version":99,"fictional":"retained"}');
      expect(storage.writes, 0);
      storage.document = '{broken';
      await expectLater(
        AppearancePreferencesRepository(storage).load(),
        throwsA(isA<FormatException>()),
      );
      expect(storage.document, '{broken');
      expect(storage.writes, 0);
    },
  );

  test(
    'appearance reset changes only its document, preserving care context and legacy choices',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'fictional_selected_person': 'person-a',
        'fictional_server': 'server-a',
        'fictional_draft': 'saved-draft',
      });
      final prefs = await SharedPreferences.getInstance();
      final repo = AppearancePreferencesRepository(
        SharedAppearancePreferenceStorage(
          prefs,
          gate: SerialProjectionEffectsGate(),
        ),
      );
      await repo.save(
        AppearancePreferences(
          mode: AppearanceMode.dark,
          darkColors: {AppearanceColorRole.text: 0xff000000},
        ),
      );
      await repo.reset();
      expect((await repo.load()).mode, AppearanceMode.system);
      expect((await repo.load()).darkColors, isEmpty);
      expect(prefs.getString('fictional_selected_person'), 'person-a');
      expect(prefs.getString('fictional_server'), 'server-a');
      expect(prefs.getString('fictional_draft'), 'saved-draft');
      expect(prefs.getString('app_theme_mode'), 'dark');
      expect(
        (await AppearancePreferencesRepository(
          SharedAppearancePreferenceStorage(
            prefs,
            gate: SerialProjectionEffectsGate(),
          ),
        ).load()).mode,
        AppearanceMode.system,
      );
    },
  );
  test(
    'explicit appearance reset remains available when its saved document is unreadable',
    () async {
      final storage = FictionalAppearanceStorage()..document = '{broken';
      final repo = AppearancePreferencesRepository(storage);
      await expectLater(repo.load(), throwsA(isA<FormatException>()));
      await repo.reset();
      expect((await repo.load()).lightColors, isEmpty);
      expect(
        (await AppearancePreferencesRepository(storage).load()).mode,
        AppearanceMode.system,
      );
    },
  );

  group('reduceMotion', () {
    Map<String, Object?> version1({Object? reduceMotion = _absent}) => {
      'version': 1,
      'mode': 'system',
      'dynamicColor': false,
      'fontSize': 'defaultSize',
      'highContrast': false,
      'lightColors': <String, Object?>{},
      'darkColors': <String, Object?>{},
      if (reduceMotion != _absent) 'reduceMotion': reduceMotion,
    };

    test('is off by default and copyWith changes only that choice', () {
      final base = AppearancePreferences(
        mode: AppearanceMode.dark,
        highContrast: true,
        lightColors: {AppearanceColorRole.primary: 0xff6e66fa},
      );
      expect(base.reduceMotion, isFalse);
      final changed = base.copyWith(reduceMotion: true);
      expect(changed.reduceMotion, isTrue);
      expect(changed.mode, AppearanceMode.dark);
      expect(changed.highContrast, isTrue);
      expect(changed.lightColors, base.lightColors);
      expect(changed.copyWith(mode: AppearanceMode.light).reduceMotion, isTrue);
      expect(changed.copyWith(reduceMotion: false).reduceMotion, isFalse);
    });

    test('round-trips through JSON under the camelCase wire name', () {
      final on = AppearancePreferences(reduceMotion: true);
      expect(on.toJson()['reduceMotion'], true);
      expect(AppearancePreferences.fromJson(on.toJson()).reduceMotion, isTrue);
      final off = AppearancePreferences();
      expect(off.toJson()['reduceMotion'], false);
      expect(
        AppearancePreferences.fromJson(
          jsonDecode(jsonEncode(off.toJson())) as Map<String, Object?>,
        ).reduceMotion,
        isFalse,
      );
    });

    test('a version 1 document without the key loads as off', () {
      final loaded = AppearancePreferences.fromJson(version1());
      expect(loaded.reduceMotion, isFalse);
      expect(loaded.mode, AppearanceMode.system);
    });

    test(
      'a stored version 1 document without the key loads from storage',
      () async {
        final storage = FictionalAppearanceStorage()
          ..document = jsonEncode(version1());
        final loaded = await AppearancePreferencesRepository(storage).load();
        expect(loaded.reduceMotion, isFalse);
        expect(storage.writes, 0);
      },
    );

    test('a value that is not true or false is rejected', () {
      for (final bad in <Object?>['true', 1, 0, null, <Object?>[]]) {
        expect(
          () => AppearancePreferences.fromJson(version1(reduceMotion: bad)),
          throwsA(isA<FormatException>()),
          reason: 'reduceMotion: $bad',
        );
      }
    });

    test(
      'a saved value that is not true or false stays for recovery',
      () async {
        final storage = FictionalAppearanceStorage()
          ..document = jsonEncode(version1(reduceMotion: 'yes'));
        final before = storage.document;
        await expectLater(
          AppearancePreferencesRepository(storage).load(),
          throwsA(isA<FormatException>()),
        );
        expect(storage.document, before);
        expect(storage.writes, 0);
      },
    );

    test('saved choice survives a reopen', () async {
      final storage = FictionalAppearanceStorage();
      await AppearancePreferencesRepository(
        storage,
      ).save(AppearancePreferences(reduceMotion: true));
      expect(
        (await AppearancePreferencesRepository(storage).load()).reduceMotion,
        isTrue,
      );
    });

    test('reset keeps reduced motion and resets the look', () async {
      final storage = FictionalAppearanceStorage();
      final repo = AppearancePreferencesRepository(storage);
      await repo.save(
        AppearancePreferences(
          mode: AppearanceMode.dark,
          dynamicColor: true,
          fontSize: AppearanceFontSize.large,
          highContrast: true,
          reduceMotion: true,
          lightColors: {AppearanceColorRole.primary: 0xff6e66fa},
          darkColors: {AppearanceColorRole.surface: 0xff141414},
        ),
      );
      await repo.reset();
      final after = await AppearancePreferencesRepository(storage).load();
      expect(after.reduceMotion, isTrue);
      expect(after.mode, AppearanceMode.system);
      expect(after.dynamicColor, isFalse);
      expect(after.fontSize, AppearanceFontSize.defaultSize);
      expect(after.highContrast, isFalse);
      expect(after.lightColors, isEmpty);
      expect(after.darkColors, isEmpty);
    });

    test('reset leaves reduced motion off when it was off', () async {
      final storage = FictionalAppearanceStorage();
      final repo = AppearancePreferencesRepository(storage);
      await repo.save(AppearancePreferences(mode: AppearanceMode.dark));
      await repo.reset();
      expect((await repo.load()).reduceMotion, isFalse);
    });

    test(
      'reset of an unreadable document falls back to plain defaults',
      () async {
        final storage = FictionalAppearanceStorage()..document = '{broken';
        final repo = AppearancePreferencesRepository(storage);
        await repo.reset();
        final after = await AppearancePreferencesRepository(storage).load();
        expect(after.reduceMotion, isFalse);
        expect(after.mode, AppearanceMode.system);
      },
    );
  });
}

const Object _absent = Object();
