import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

void main() {
  test(
    'all 21 role overrides reach light and dark rendering independently',
    () {
      final light = {
        for (final role in AppearanceColorRole.values)
          role: 0xff203040 + role.index * 0x010203,
      };
      final dark = {
        for (final role in AppearanceColorRole.values)
          role: 0xff607080 + role.index * 0x010203,
      };
      final preferences = AppearancePreferences(
        lightColors: light,
        darkColors: dark,
      );
      expect(AppearanceColorRole.values.length, 21);
      for (final entry in {
        Brightness.light: light,
        Brightness.dark: dark,
      }.entries) {
        final rendered = AppTheme.roleColors(
          AppTheme.appearance(preferences, entry.key),
        );
        expect(
          rendered.map((key, value) => MapEntry(key, value.toARGB32())),
          entry.value,
        );
      }
    },
  );

  test(
    'dynamic colors apply only when enabled; explicit colors take priority with a brand fallback',
    () {
      final dynamic = ColorScheme.fromSeed(seedColor: Colors.orange);
      final preferences = AppearancePreferences(
        dynamicColor: true,
        lightColors: {AppearanceColorRole.primary: 0xff124578},
      );
      final rendered = AppTheme.appearance(
        preferences,
        Brightness.light,
        dynamicScheme: dynamic,
      );
      expect(rendered.colorScheme.primary, const Color(0xff124578));
      expect(rendered.colorScheme.secondary, dynamic.secondary);
      final disabled = AppTheme.appearance(
        preferences.copyWith(dynamicColor: false),
        Brightness.light,
        dynamicScheme: dynamic,
      );
      expect(
        disabled.colorScheme.secondary,
        AppTheme.light().colorScheme.secondary,
      );
      final unavailable = AppTheme.appearance(preferences, Brightness.light);
      expect(
        unavailable.colorScheme.secondary,
        AppTheme.light().colorScheme.secondary,
      );
    },
  );

  test(
    'high contrast renders readable foregrounds without rewriting saved difficult colors',
    () {
      final preferences = AppearancePreferences(
        highContrast: true,
        lightColors: {
          for (final role in AppearanceColorRole.values) role: 0xffffffff,
        },
      );
      final theme = AppTheme.appearance(preferences, Brightness.light);
      expect(
        AppTheme.contrast(
          theme.colorScheme.onSurface,
          theme.scaffoldBackgroundColor,
        ),
        greaterThanOrEqualTo(7),
      );
      expect(
        AppTheme.contrast(
          theme.colorScheme.onPrimary,
          theme.colorScheme.primary,
        ),
        greaterThanOrEqualTo(7),
      );
      expect(
        AppTheme.contrast(
          theme.extension<AppSemanticColors>()!.statusTaken,
          theme.colorScheme.surface,
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(preferences.lightColors[AppearanceColorRole.text], 0xffffffff);
      expect(theme.inputDecorationTheme.enabledBorder!.borderSide.width, 2);
    },
  );
}
