import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/backup/backup_inventory.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';

Future<(ProviderContainer, SharedPreferences)> _container(
  Map<String, Object> values,
) async {
  SharedPreferences.setMockInitialValues(values);
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
  );
  addTearDown(container.dispose);
  return (container, preferences);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old preferences without the key still load as Focus deck', () async {
    final (container, preferences) = await _container({
      'appearance_preferences_v1':
          '{"version":1,"mode":"dark","dynamicColor":false,'
          '"fontSize":"large","highContrast":false,'
          '"lightColors":{},"darkColors":{}}',
      kAppThemeModeKey: 'dark',
      'prn_in_widget_fictional-user': true,
    });
    expect(container.read(layoutFamilyProvider), LayoutFamily.focusDeck);
    expect(preferences.containsKey(kLayoutFamilyPreferenceKey), isFalse);
  });

  test('unknown or malformed stored values fall back to Focus deck', () async {
    for (final stored in <Object>['carousel', '', 'Timeline', 3, true]) {
      final (container, _) = await _container({
        kLayoutFamilyPreferenceKey: stored,
      });
      expect(
        container.read(layoutFamilyProvider),
        LayoutFamily.focusDeck,
        reason: 'stored $stored',
      );
    }
  });

  test('every family round-trips by name', () async {
    for (final family in LayoutFamily.values) {
      final (container, preferences) = await _container({});
      await container.read(layoutFamilyProvider.notifier).apply(family);
      expect(container.read(layoutFamilyProvider), family);
      expect(preferences.getString(kLayoutFamilyPreferenceKey), family.name);
      final (reloaded, _) = await _container({
        kLayoutFamilyPreferenceKey: family.name,
      });
      expect(reloaded.read(layoutFamilyProvider), family);
    }
  });

  test('applying a layout touches no other key', () async {
    final initial = <String, Object>{
      kAppThemeModeKey: 'light',
      kTodayDosesKey: '[]',
      kSnapshotDayKey: '2026-09-30',
      'prn_in_stats_fictional-user': false,
    };
    final (container, preferences) = await _container(initial);
    await container
        .read(layoutFamilyProvider.notifier)
        .apply(LayoutFamily.timeline);
    for (final entry in initial.entries) {
      expect(preferences.get(entry.key), entry.value, reason: entry.key);
    }
    expect(preferences.getKeys(), {
      ...initial.keys,
      kLayoutFamilyPreferenceKey,
    });
  });

  test('the key is device-local, outside backups and the widget contract', () {
    expect(
      BackupInventory.preferenceAllowed(kLayoutFamilyPreferenceKey),
      isFalse,
    );
    expect([
      kTodayDosesKey,
      kSnapshotDayKey,
      kAppThemeModeKey,
      kActiveUserIdKey,
      kSessionGenerationKey,
      kCurrentUserIdKey,
    ], isNot(contains(kLayoutFamilyPreferenceKey)));
  });

  test(
    'a host without preferences shows Focus deck and refuses to save',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(layoutFamilyProvider), LayoutFamily.focusDeck);
      await expectLater(
        container
            .read(layoutFamilyProvider.notifier)
            .apply(LayoutFamily.timeline),
        throwsA(isA<LayoutFamilyPersistenceFailure>()),
      );
      expect(container.read(layoutFamilyProvider), LayoutFamily.focusDeck);
    },
  );
}
