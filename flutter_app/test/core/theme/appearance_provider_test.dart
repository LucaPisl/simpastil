import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import '../../helpers/held_provider_read.dart';

class _Storage implements AppearancePreferenceStorage {
  String? document;
  Completer<bool>? write;
  final started = Completer<void>();
  @override
  Future<String?> readDocument() async => document;
  @override
  Future<Map<String, Object?>> readLegacy() async => {
    'app_theme_mode': 'light',
  };
  @override
  Future<bool> writeDocument(String value) async {
    if (!started.isCompleted) started.complete();
    final accepted = await (write?.future ?? Future.value(true));
    if (accepted) document = value;
    return accepted;
  }
}

void main() {
  test(
    'pending and failed Apply retain the rendered appearance; retry survives optional effect failure',
    () async {
      final storage = _Storage()..write = Completer<bool>();
      var refreshes = 0;
      final container = ProviderContainer(
        overrides: [
          appearanceRepositoryProvider.overrideWithValue(
            AppearancePreferencesRepository(storage),
          ),
          appearanceProjectionRefreshProvider.overrideWithValue(() async {
            refreshes++;
            throw StateError('optional native effect unavailable');
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.readHeld(appearanceNotifierProvider);
      final reviewed = AppearancePreferences(
        mode: AppearanceMode.dark,
        fontSize: AppearanceFontSize.extraLarge,
      );
      final save = container
          .read(appearanceNotifierProvider.notifier)
          .apply(reviewed);
      final failed = expectLater(
        save,
        throwsA(isA<AppearancePersistenceFailure>()),
      );
      await storage.started.future;
      expect(
        container.read(appearanceNotifierProvider).requireValue.mode,
        AppearanceMode.light,
      );
      expect(container.read(fontSizeMultiplierProvider), 1);
      storage.write!.complete(false);
      await failed;
      expect(
        container.read(appearanceNotifierProvider).requireValue.mode,
        AppearanceMode.light,
      );
      expect(refreshes, 0);
      storage.write = null;
      await container.read(appearanceNotifierProvider.notifier).apply(reviewed);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(appearanceNotifierProvider).requireValue.mode,
        AppearanceMode.dark,
      );
      expect(container.read(fontSizeMultiplierProvider), 1.3);
      expect(refreshes, 1);
      expect(
        (await AppearancePreferencesRepository(storage).load()).mode,
        AppearanceMode.dark,
      );
    },
  );

  test(
    'compatibility controls serialize through the one document without losing other choices',
    () async {
      final storage = _Storage();
      final container = ProviderContainer(
        overrides: [
          appearanceRepositoryProvider.overrideWithValue(
            AppearancePreferencesRepository(storage),
          ),
          appearanceProjectionRefreshProvider.overrideWithValue(() async {}),
        ],
      );
      addTearDown(container.dispose);
      await container.readHeld(appearanceNotifierProvider);
      await Future.wait([
        container
            .read(themeModeNotifierProvider.notifier)
            .setThemeMode(AppThemeMode.dark),
        container
            .read(fontSizeNotifierProvider.notifier)
            .setFontSize(AppFontSize.large),
        container.read(highContrastNotifierProvider.notifier).setEnabled(true),
      ]);
      final reopened = await AppearancePreferencesRepository(storage).load();
      expect(reopened.mode, AppearanceMode.dark);
      expect(reopened.fontSize, AppearanceFontSize.large);
      expect(reopened.highContrast, true);
    },
  );
}
