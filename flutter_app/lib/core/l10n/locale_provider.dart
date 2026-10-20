import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../projections/projection_reconciler.dart';
import '../session/session_generation_repository.dart';
import '../storage/portable_preference_writer.dart';

class LocaleNotifier extends AsyncNotifier<Locale?> {
  static const _key = 'app_locale';

  @override
  Future<Locale?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_key);
    if (code == null) return null;
    return Locale(code);
  }

  Future<void> setLocale(Locale? locale) async {
    final prefs = await SharedPreferences.getInstance();
    await PortablePreferenceWriter(
      prefs,
      gate: ref.read(portablePreferenceGateProvider),
    ).write(_key, locale?.languageCode);
    state = AsyncData(locale);
    final identity = await ref
        .read(sessionGenerationRepositoryProvider)
        .currentIdentity();
    if (identity != null) {
      await ref
          .read(projectionReconcilerProvider)
          .reconcile(identity: identity, locale: locale);
    }
  }
}

final localeNotifierProvider = AsyncNotifierProvider<LocaleNotifier, Locale?>(
  LocaleNotifier.new,
);

final localeOverrideProvider = Provider<Locale?>((ref) {
  return ref.watch(localeNotifierProvider).value;
});
