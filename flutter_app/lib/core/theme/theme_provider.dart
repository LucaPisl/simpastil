import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/appearance_preferences.dart';
import '../storage/shared_preferences_provider.dart';
import '../storage/portable_preference_writer.dart';
import '../widget/widget_snapshot.dart';

final appearanceRepositoryProvider = Provider<AppearancePreferencesRepository>(
  (ref) => AppearancePreferencesRepository(
    SharedAppearancePreferenceStorage(
      ref.watch(sharedPreferencesProvider),
      gate: ref.watch(portablePreferenceGateProvider),
    ),
  ),
);

/// An optional projection refresh cannot turn a durable appearance save into
/// an apparent failure. Widgets resolve the same saved appearance document.
final appearanceProjectionRefreshProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => publishWidgetSnapshot(),
);

class AppearanceNotifier extends AsyncNotifier<AppearancePreferences> {
  Future<void> _changes = Future.value();

  @override
  Future<AppearancePreferences> build() =>
      ref.watch(appearanceRepositoryProvider).load();

  Future<void> apply(AppearancePreferences reviewed) =>
      _publish((repository) => repository.save(reviewed));

  Future<void> reset() => _publish((repository) => repository.reset());

  Future<void> change(
    AppearancePreferences Function(AppearancePreferences applied) update,
  ) => _publish((repository) async {
    await repository.save(update(await repository.load()));
  });

  Future<void> _publish(
    Future<void> Function(AppearancePreferencesRepository repository) write,
  ) {
    final repository = ref.read(appearanceRepositoryProvider);
    final refresh = ref.read(appearanceProjectionRefreshProvider);
    final operation = _changes.then((_) async {
      await write(repository);
      state = AsyncData(await repository.load());
      unawaited(Future<void>.sync(refresh).catchError((Object _) {}));
    });
    _changes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}

final appearanceNotifierProvider =
    AsyncNotifierProvider<AppearanceNotifier, AppearancePreferences>(
      AppearanceNotifier.new,
    );

// Existing presentation clients retain their APIs, but all durable writes and
// reads now use the one versioned document. No legacy key is a second authority.
enum AppThemeMode { system, light, dark }

class ThemeModeNotifier extends AsyncNotifier<AppThemeMode> {
  @override
  Future<AppThemeMode> build() async => AppThemeMode.values.byName(
    (await ref.watch(appearanceNotifierProvider.future)).mode.name,
  );
  Future<void> setThemeMode(AppThemeMode mode) => ref
      .read(appearanceNotifierProvider.notifier)
      .change(
        (applied) =>
            applied.copyWith(mode: AppearanceMode.values.byName(mode.name)),
      );
}

final themeModeNotifierProvider =
    AsyncNotifierProvider<ThemeModeNotifier, AppThemeMode>(
      ThemeModeNotifier.new,
    );
final flutterThemeModeProvider = Provider<ThemeMode>(
  (ref) => ThemeMode.values.byName(
    (ref.watch(appearanceNotifierProvider).valueOrNull?.mode ??
            AppearanceMode.system)
        .name,
  ),
);

class DynamicColorNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      (await ref.watch(appearanceNotifierProvider.future)).dynamicColor;
  Future<void> setEnabled(bool enabled) => ref
      .read(appearanceNotifierProvider.notifier)
      .change((applied) => applied.copyWith(dynamicColor: enabled));
}

final dynamicColorNotifierProvider =
    AsyncNotifierProvider<DynamicColorNotifier, bool>(DynamicColorNotifier.new);

/// Whether this app was asked to reduce motion. The phone's own setting is
/// applied separately and still counts when this is off.
final reduceMotionProvider = Provider<bool>(
  (ref) =>
      ref.watch(appearanceNotifierProvider).valueOrNull?.reduceMotion ?? false,
);

final dynamicColorEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(appearanceNotifierProvider).valueOrNull?.dynamicColor ?? false,
);

enum AppFontSize {
  defaultSize(1.0, 'Default'),
  large(1.15, 'Large'),
  extraLarge(1.3, 'Extra Large');

  const AppFontSize(this.multiplier, this.label);
  final double multiplier;
  final String label;
}

class FontSizeNotifier extends AsyncNotifier<AppFontSize> {
  @override
  Future<AppFontSize> build() async => AppFontSize.values.byName(
    (await ref.watch(appearanceNotifierProvider.future)).fontSize.name,
  );
  Future<void> setFontSize(AppFontSize size) => ref
      .read(appearanceNotifierProvider.notifier)
      .change(
        (applied) => applied.copyWith(
          fontSize: AppearanceFontSize.values.byName(size.name),
        ),
      );
}

final fontSizeNotifierProvider =
    AsyncNotifierProvider<FontSizeNotifier, AppFontSize>(FontSizeNotifier.new);
final fontSizeMultiplierProvider = Provider<double>(
  (ref) =>
      ref.watch(appearanceNotifierProvider).valueOrNull?.fontSize.multiplier ??
      1,
);

class HighContrastNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      (await ref.watch(appearanceNotifierProvider.future)).highContrast;
  Future<void> setEnabled(bool enabled) => ref
      .read(appearanceNotifierProvider.notifier)
      .change((applied) => applied.copyWith(highContrast: enabled));
}

final highContrastNotifierProvider =
    AsyncNotifierProvider<HighContrastNotifier, bool>(HighContrastNotifier.new);
final highContrastEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(appearanceNotifierProvider).valueOrNull?.highContrast ?? false,
);
