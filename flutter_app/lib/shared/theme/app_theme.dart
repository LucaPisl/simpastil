import 'package:flutter/material.dart';
import 'focus_tokens.dart';
import '../../core/storage/appearance_preferences.dart';

/// Semantic colors for domain-specific elements.
/// Access via: `Theme.of(context).extension<AppSemanticColors>()!`
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.statusTaken,
    required this.statusMissed,
    required this.statusSkipped,
    required this.statusUnrecorded,
    required this.statusWarning,
    required this.profileActive,
    required this.profileInactive,
  });

  final Color statusTaken;
  final Color statusMissed;
  final Color statusSkipped;
  final Color statusUnrecorded;

  /// Something to look at soon, not yet a fault: stock running low, a
  /// medication that needs attention. Readable as text on a plain surface.
  final Color statusWarning;
  final Color profileActive;
  final Color profileInactive;

  Color forState(String state) => switch (state) {
    'taken' => statusTaken,
    'skipped' => statusSkipped,
    'missed' => statusMissed,
    _ => statusUnrecorded,
  };

  @override
  AppSemanticColors copyWith({
    Color? statusTaken,
    Color? statusMissed,
    Color? statusSkipped,
    Color? statusUnrecorded,
    Color? statusWarning,
    Color? profileActive,
    Color? profileInactive,
  }) {
    return AppSemanticColors(
      statusTaken: statusTaken ?? this.statusTaken,
      statusMissed: statusMissed ?? this.statusMissed,
      statusSkipped: statusSkipped ?? this.statusSkipped,
      statusUnrecorded: statusUnrecorded ?? this.statusUnrecorded,
      statusWarning: statusWarning ?? this.statusWarning,
      profileActive: profileActive ?? this.profileActive,
      profileInactive: profileInactive ?? this.profileInactive,
    );
  }

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      statusTaken: Color.lerp(statusTaken, other.statusTaken, t)!,
      statusMissed: Color.lerp(statusMissed, other.statusMissed, t)!,
      statusSkipped: Color.lerp(statusSkipped, other.statusSkipped, t)!,
      statusUnrecorded: Color.lerp(
        statusUnrecorded,
        other.statusUnrecorded,
        t,
      )!,
      statusWarning: Color.lerp(statusWarning, other.statusWarning, t)!,
      profileActive: Color.lerp(profileActive, other.profileActive, t)!,
      profileInactive: Color.lerp(profileInactive, other.profileInactive, t)!,
    );
  }

  static const light = AppSemanticColors(
    statusTaken: Color(0xFF2E7D32),
    statusMissed: Color(0xFFC62828),
    statusSkipped: Color(0xFF757575),
    statusUnrecorded: Color(0xFF55515F),
    statusWarning: Color(0xFF8A5A00),
    profileActive: Color(0xFF00695C),
    profileInactive: Color(0xFF9E9E9E),
  );

  static const dark = AppSemanticColors(
    statusTaken: Color(0xFF81C784),
    statusMissed: Color(0xFFEF9A9A),
    statusUnrecorded: Color(0xFFCEC9D7),
    statusSkipped: Color(0xFFBDBDBD), // was 9E9E9E — contrast 5.7:1
    statusWarning: Color(0xFFE6B566),
    profileActive: Color(0xFF4DB6AC),
    profileInactive: Color(0xFF9E9E9E), // was 616161 — contrast 4.6:1
  );

  static const lightHighContrast = AppSemanticColors(
    statusTaken: Color(0xFF1B5E20),
    statusMissed: Color(0xFFB71C1C),
    statusSkipped: Color(0xFF424242),
    statusUnrecorded: Color(0xFF141414),
    statusWarning: Color(0xFF6B4500),
    profileActive: Color(0xFF004D40),
    profileInactive: Color(0xFF616161),
  );

  static const darkHighContrast = AppSemanticColors(
    statusTaken: Color(0xFFA5D6A7),
    statusMissed: Color(0xFFFFCDD2),
    statusSkipped: Color(0xFFE0E0E0),
    statusUnrecorded: Color(0xFFF5F3FA),
    statusWarning: Color(0xFFFFD699),
    profileActive: Color(0xFF80CBC4),
    profileInactive: Color(0xFFBDBDBD),
  );
}

/// Simpastil brand palette.
abstract class AppColors {
  static const seedPrimary = FocusTokens.violet;
  static const seedSecondary = FocusTokens.lavender;
  static const seedTertiary = FocusTokens.sage;
}

/// Application theme — Material 3 with custom colour seeds and text hierarchy.
abstract class AppTheme {
  /// Resolve one viewer theme. Explicit role overrides remain separate for
  /// light/dark and take precedence over optional device colors.
  static ThemeData appearance(
    AppearancePreferences preferences,
    Brightness brightness, {
    ColorScheme? dynamicScheme,
  }) {
    final original = preferences.dynamicColor && dynamicScheme != null
        ? fromDynamic(
            dynamicScheme: dynamicScheme,
            brightness: brightness,
            highContrast: preferences.highContrast,
          )
        : (brightness == Brightness.light
              ? light(highContrast: preferences.highContrast)
              : dark(highContrast: preferences.highContrast));
    final overrides = brightness == Brightness.light
        ? preferences.lightColors
        : preferences.darkColors;
    Color choose(AppearanceColorRole role, Color original) =>
        overrides.containsKey(role) ? Color(overrides[role]!) : original;
    final b = original.colorScheme;
    final background = choose(
      AppearanceColorRole.background,
      original.scaffoldBackgroundColor,
    );
    var colors = b.copyWith(
      primary: choose(AppearanceColorRole.primary, b.primary),
      onPrimary: choose(AppearanceColorRole.onPrimary, b.onPrimary),
      primaryContainer: choose(
        AppearanceColorRole.primaryContainer,
        b.primaryContainer,
      ),
      onPrimaryContainer: choose(
        AppearanceColorRole.onPrimaryContainer,
        b.onPrimaryContainer,
      ),
      surface: choose(AppearanceColorRole.surface, b.surface),
      onSurface: choose(AppearanceColorRole.text, b.onSurface),
      onSurfaceVariant: choose(
        AppearanceColorRole.mutedText,
        b.onSurfaceVariant,
      ),
      surfaceContainerLow: choose(
        AppearanceColorRole.surfaceVariant,
        b.surfaceContainerLow,
      ),
      surfaceContainer: choose(
        AppearanceColorRole.surfaceVariant,
        b.surfaceContainer,
      ),
      surfaceContainerHigh: choose(
        AppearanceColorRole.surfaceVariant,
        b.surfaceContainerHigh,
      ),
      surfaceContainerHighest: choose(
        AppearanceColorRole.surfaceVariant,
        b.surfaceContainerHighest,
      ),
      outline: choose(AppearanceColorRole.border, b.outline),
      outlineVariant: choose(AppearanceColorRole.border, b.outlineVariant),
      secondary: choose(AppearanceColorRole.secondary, b.secondary),
      onSecondary: choose(AppearanceColorRole.onSecondary, b.onSecondary),
      tertiary: choose(AppearanceColorRole.tertiary, b.tertiary),
      onTertiary: choose(AppearanceColorRole.onTertiary, b.onTertiary),
      error: choose(AppearanceColorRole.error, b.error),
      onError: choose(AppearanceColorRole.onError, b.onError),
    );
    final baseSemantic = original.extension<AppSemanticColors>()!;
    var semantic = baseSemantic.copyWith(
      statusTaken: choose(AppearanceColorRole.taken, baseSemantic.statusTaken),
      statusSkipped: choose(
        AppearanceColorRole.skipped,
        baseSemantic.statusSkipped,
      ),
      statusUnrecorded: choose(
        AppearanceColorRole.unrecorded,
        baseSemantic.statusUnrecorded,
      ),
      profileActive: choose(AppearanceColorRole.activePerson, colors.primary),
      profileInactive: choose(
        AppearanceColorRole.inactivePerson,
        baseSemantic.profileInactive,
      ),
    );
    if (preferences.highContrast) {
      final surfaces = [background, colors.surface, colors.surfaceContainerLow];
      colors = colors.copyWith(
        onSurface: readable(colors.onSurface, surfaces),
        onSurfaceVariant: readable(colors.onSurfaceVariant, surfaces),
        onPrimary: readable(colors.onPrimary, [colors.primary]),
        onPrimaryContainer: readable(colors.onPrimaryContainer, [
          colors.primaryContainer,
        ]),
        onSecondary: readable(colors.onSecondary, [colors.secondary]),
        onTertiary: readable(colors.onTertiary, [colors.tertiary]),
        onError: readable(colors.onError, [colors.error]),
        outline: readable(colors.outline, surfaces, minimum: 3),
        outlineVariant: readable(colors.outlineVariant, surfaces, minimum: 3),
      );
      semantic = semantic.copyWith(
        statusTaken: readable(semantic.statusTaken, surfaces, minimum: 4.5),
        statusSkipped: readable(semantic.statusSkipped, surfaces, minimum: 4.5),
        statusUnrecorded: readable(
          semantic.statusUnrecorded,
          surfaces,
          minimum: 4.5,
        ),
        statusWarning: readable(semantic.statusWarning, surfaces, minimum: 4.5),
        profileActive: readable(semantic.profileActive, surfaces, minimum: 4.5),
        profileInactive: readable(
          semantic.profileInactive,
          surfaces,
          minimum: 4.5,
        ),
      );
    }
    return _buildFromScheme(
      colors,
      brightness,
      highContrast: preferences.highContrast,
      background: background,
      semanticColors: semantic,
    );
  }

  static double contrast(Color a, Color b) {
    final x = a.computeLuminance(), y = b.computeLuminance();
    return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
  }

  static Color readable(
    Color preferred,
    List<Color> backgrounds, {
    double minimum = 7,
  }) {
    double worst(Color color) => backgrounds
        .map((b) => contrast(color, b))
        .reduce((a, b) => a < b ? a : b);
    if (worst(preferred) >= minimum) return preferred;
    return worst(Colors.black) >= worst(Colors.white)
        ? Colors.black
        : Colors.white;
  }

  static Map<AppearanceColorRole, Color> roleColors(ThemeData theme) {
    final c = theme.colorScheme, s = theme.extension<AppSemanticColors>()!;
    return {
      AppearanceColorRole.primary: c.primary,
      AppearanceColorRole.onPrimary: c.onPrimary,
      AppearanceColorRole.primaryContainer: c.primaryContainer,
      AppearanceColorRole.onPrimaryContainer: c.onPrimaryContainer,
      AppearanceColorRole.background: theme.scaffoldBackgroundColor,
      AppearanceColorRole.text: c.onSurface,
      AppearanceColorRole.surface: c.surface,
      AppearanceColorRole.surfaceVariant: c.surfaceContainerLow,
      AppearanceColorRole.mutedText: c.onSurfaceVariant,
      AppearanceColorRole.border: c.outline,
      AppearanceColorRole.secondary: c.secondary,
      AppearanceColorRole.onSecondary: c.onSecondary,
      AppearanceColorRole.tertiary: c.tertiary,
      AppearanceColorRole.onTertiary: c.onTertiary,
      AppearanceColorRole.error: c.error,
      AppearanceColorRole.onError: c.onError,
      AppearanceColorRole.taken: s.statusTaken,
      AppearanceColorRole.skipped: s.statusSkipped,
      AppearanceColorRole.unrecorded: s.statusUnrecorded,
      AppearanceColorRole.activePerson: s.profileActive,
      AppearanceColorRole.inactivePerson: s.profileInactive,
    };
  }

  static ThemeData light({bool highContrast = false}) =>
      _build(Brightness.light, highContrast: highContrast);

  static ThemeData dark({bool highContrast = false}) =>
      _build(Brightness.dark, highContrast: highContrast);

  static ThemeData fromDynamic({
    required ColorScheme dynamicScheme,
    required Brightness brightness,
    bool highContrast = false,
  }) {
    return _buildFromScheme(
      dynamicScheme,
      brightness,
      highContrast: highContrast,
    );
  }

  static ThemeData _build(Brightness brightness, {bool highContrast = false}) {
    final dark = brightness == Brightness.dark;
    final base =
        ColorScheme.fromSeed(
          seedColor: FocusTokens.violet,
          brightness: brightness,
          contrastLevel: highContrast ? 1 : 0,
        ).copyWith(
          // A slightly deeper tone gives small action text AA contrast; the
          // capsule and brand seed retain the approved #6E66FA anchor.
          primary: dark
              ? const Color(0xFFBBB5FF)
              : highContrast
              ? const Color(0xFF4F46C5)
              : const Color(0xFF685FEA),
          onPrimary: dark ? FocusTokens.ink : Colors.white,
          primaryContainer: dark
              ? const Color(0xFF34304F)
              : const Color(0xFFEEEDFF),
          onPrimaryContainer: dark ? const Color(0xFFE9E6FF) : FocusTokens.ink,
          surface: dark ? FocusTokens.ink : FocusTokens.white,
          onSurface: dark ? const Color(0xFFF5F3FA) : FocusTokens.ink,
          onSurfaceVariant: dark
              ? const Color(0xFFCEC9D7)
              : const Color(0xFF55515F),
          surfaceContainerLow: dark
              ? const Color(0xFF201F25)
              : const Color(0xFFF7F6FB),
          surfaceContainerHighest: dark
              ? const Color(0xFF35333C)
              : const Color(0xFFF0EFF5),
          secondary: dark ? FocusTokens.lavender : const Color(0xFF615E81),
          tertiary: dark ? const Color(0xFFAEC9B7) : const Color(0xFF4B6956),
          tertiaryContainer: dark
              ? const Color(0xFF2C4034)
              : const Color(0xFFE1ECE4),
          onTertiaryContainer: dark
              ? const Color(0xFFE1ECE4)
              : const Color(0xFF243F2C),
        );

    return _buildFromScheme(base, brightness, highContrast: highContrast);
  }

  static ThemeData _buildFromScheme(
    ColorScheme base,
    Brightness brightness, {
    bool highContrast = false,
    Color? background,
    AppSemanticColors? semanticColors,
  }) {
    final text = _textTheme(base, highContrast: highContrast);
    final borderWidth = highContrast ? 2.0 : 1.0;

    return ThemeData(
      useMaterial3: true,
      colorScheme: base,
      scaffoldBackgroundColor: background ?? base.surface,
      canvasColor: background ?? base.surface,
      textTheme: text,
      extensions: [
        semanticColors ??
            (highContrast
                ? (brightness == Brightness.light
                      ? AppSemanticColors.lightHighContrast
                      : AppSemanticColors.darkHighContrast)
                : (brightness == Brightness.light
                      ? AppSemanticColors.light
                      : AppSemanticColors.dark)),
      ],

      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: background ?? base.surface,
        foregroundColor: base.onSurface,
        titleTextStyle: text.titleLarge,
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: base.outlineVariant, width: borderWidth),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: text.labelLarge,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          side: highContrast ? BorderSide(color: base.outline, width: 2) : null,
          textStyle: text.labelLarge,
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: base.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: base.outline.withValues(alpha: highContrast ? 0.8 : 0.4),
            width: borderWidth,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: base.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: base.error, width: borderWidth),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: base.error, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        hintStyle: text.bodyLarge?.copyWith(color: base.onSurfaceVariant),
      ),

      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: background ?? base.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: base.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return text.labelSmall?.copyWith(
              color: base.onSurface,
              fontWeight: FontWeight.w700,
            );
          }
          return text.labelSmall?.copyWith(color: base.onSurfaceVariant);
        }),
      ),

      // The side rail that replaces the bottom bar on tablets: the bar's
      // surface and indicator, so the two read as one navigation.
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background ?? base.surface,
        elevation: 0,
        indicatorColor: base.primaryContainer,
        indicatorShape: const StadiumBorder(),
        labelType: NavigationRailLabelType.all,
        useIndicator: true,
        selectedIconTheme: IconThemeData(
          size: 24,
          color: base.onPrimaryContainer,
        ),
        unselectedIconTheme: IconThemeData(
          size: 24,
          color: base.onSurfaceVariant,
        ),
        selectedLabelTextStyle: text.labelMedium?.copyWith(
          color: base.onSurface,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: text.labelMedium?.copyWith(
          color: base.onSurfaceVariant,
        ),
      ),

      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        // Choice/filter chips must read as tappable options in every theme:
        // an outlined surface when off, a tinted fill with a firm border
        // and full-strength ink when selected. Only a truly disabled chip
        // looks muted.
        backgroundColor: base.surface,
        selectedColor: base.primaryContainer,
        disabledColor: base.onSurface.withValues(alpha: 0.06),
        side: WidgetStateBorderSide.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return BorderSide(color: base.outlineVariant);
          }
          return BorderSide(
            color: states.contains(WidgetState.selected)
                ? base.primary
                : base.outline,
            width: states.contains(WidgetState.selected) ? 1.5 : 1,
          );
        }),
        // The colour must be a WidgetStateColor: RawChip resolves the
        // style's own colour per state and ignores a state-aware TextStyle.
        labelStyle: (text.labelLarge ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w600,
          color: WidgetStateColor.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return base.onSurface.withValues(alpha: 0.5);
            }
            return states.contains(WidgetState.selected)
                ? base.onPrimaryContainer
                : base.onSurface;
          }),
        ),
      ),

      timePickerTheme: TimePickerThemeData(
        dayPeriodColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? base.primaryContainer
              : Colors.transparent,
        ),
        dayPeriodTextColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? base.onPrimaryContainer
              : base.onSurfaceVariant,
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      dividerTheme: DividerThemeData(
        color: base.outlineVariant,
        thickness: borderWidth,
        space: 1,
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme, {bool highContrast = false}) {
    final bodyColor = highContrast ? scheme.onSurface : scheme.onSurface;
    final mutedColor = highContrast
        ? scheme.onSurface
        : scheme.onSurfaceVariant;

    FontWeight bump(FontWeight base) {
      if (!highContrast) return base;
      const weights = [
        FontWeight.w100,
        FontWeight.w200,
        FontWeight.w300,
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
        FontWeight.w800,
        FontWeight.w900,
      ];
      final idx = weights.indexOf(base);
      return weights[(idx + 1).clamp(0, weights.length - 1)];
    }

    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 57,
        fontWeight: bump(FontWeight.w400),
        color: bodyColor,
        letterSpacing: -0.25,
        height: 1.12,
      ),
      displayMedium: TextStyle(
        fontSize: 45,
        fontWeight: bump(FontWeight.w400),
        color: bodyColor,
        height: 1.16,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: bump(FontWeight.w400),
        color: bodyColor,
        height: 1.22,
      ),
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: bump(FontWeight.w600),
        color: bodyColor,
        height: 1.25,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: bump(FontWeight.w600),
        color: bodyColor,
        height: 1.29,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: bump(FontWeight.w600),
        color: bodyColor,
        height: 1.33,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: bump(FontWeight.w600),
        color: bodyColor,
        height: 1.27,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: bump(FontWeight.w600),
        color: bodyColor,
        letterSpacing: 0.15,
        height: 1.50,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: bump(FontWeight.w600),
        color: bodyColor,
        letterSpacing: 0.1,
        height: 1.43,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: bump(FontWeight.w400),
        color: bodyColor,
        letterSpacing: 0.5,
        height: 1.50,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: bump(FontWeight.w400),
        color: bodyColor,
        letterSpacing: 0.25,
        height: 1.43,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: bump(FontWeight.w400),
        color: mutedColor,
        letterSpacing: 0.4,
        height: 1.33,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: bump(FontWeight.w700),
        color: bodyColor,
        letterSpacing: 0.1,
        height: 1.43,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: bump(FontWeight.w600),
        color: bodyColor,
        letterSpacing: 0.5,
        height: 1.33,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: bump(FontWeight.w600),
        color: mutedColor,
        letterSpacing: 0.5,
        height: 1.45,
      ),
    );
  }
}
